//! Tray icon, its right-click menu, and the two windows (the tray panel and
//! the desktop window).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use lidless_core::duration;
use lidless_core::model::EndReason;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, WebviewWindow};
use tauri_plugin_positioner::{Position, WindowExt};

use crate::worker::Ctx;

pub const PANEL_WIDTH: f64 = 320.0;
pub const WINDOW_MIN: (f64, f64) = (1000.0, 680.0);
const TRAY_ID: &str = "main";

/// Menu handles the worker updates once a second.
pub struct TrayState {
    status_item: Mutex<Option<MenuItem<tauri::Wry>>>,
    active: AtomicBool,
    tooltip: Mutex<String>,
}

fn icon(active: bool) -> Image<'static> {
    let bytes: &'static [u8] = if cfg!(target_os = "macos") {
        include_bytes!("../icons/tray-template.png")
    } else if active {
        include_bytes!("../icons/tray-awake.png")
    } else {
        include_bytes!("../icons/tray.png")
    };
    Image::from_bytes(bytes).expect("tray icon")
}

fn status_text(active: bool, remaining: i64) -> String {
    if active {
        format!("Awake · {} left", duration::clock(remaining as f64))
    } else {
        "Sleeps normally".to_string()
    }
}

fn build_menu(
    app: &AppHandle,
    active: bool,
    remaining: i64,
) -> tauri::Result<(Menu<tauri::Wry>, MenuItem<tauri::Wry>)> {
    let status = MenuItem::with_id(
        app,
        "status",
        status_text(active, remaining),
        false,
        None::<&str>,
    )?;
    let open_panel = MenuItem::with_id(app, "open_panel", "Open tray panel", true, None::<&str>)?;
    let stop = MenuItem::with_id(app, "stop", "Stop session", true, None::<&str>)?;
    let open = MenuItem::with_id(app, "open", "Open Lidless", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Lidless", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let menu = if active {
        Menu::with_items(app, &[&status, &open_panel, &stop, &open, &sep, &quit])?
    } else {
        Menu::with_items(app, &[&status, &open_panel, &open, &sep, &quit])?
    };
    Ok((menu, status))
}

pub fn install(app: &AppHandle) -> tauri::Result<()> {
    let (menu, status) = build_menu(app, false, 0)?;
    app.manage(TrayState {
        status_item: Mutex::new(Some(status)),
        active: AtomicBool::new(false),
        tooltip: Mutex::new(String::new()),
    });
    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon(false))
        .icon_as_template(cfg!(target_os = "macos"))
        .tooltip("Lidless · Sleeps normally")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open_panel" => show_panel(app),
            "stop" => {
                let ctx = app.state::<Arc<Ctx>>();
                ctx.stop(app);
            }
            "open" => show_window(app, None),
            "quit" => quit(app),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            let app = tray.app_handle();
            tauri_plugin_positioner::on_tray_event(app, &event);
            match event {
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                } => toggle_panel(app),
                TrayIconEvent::DoubleClick {
                    button: MouseButton::Left,
                    ..
                } => show_window(app, None),
                _ => {}
            }
        })
        .build(app)?;
    Ok(())
}

/// Called by the worker every tick; only touches the tray when something changed.
pub fn sync(app: &AppHandle, active: bool, remaining: i64, active_changed: bool) {
    let Some(state) = app.try_state::<TrayState>() else {
        return;
    };
    let text = status_text(active, remaining);
    let tooltip = format!("Lidless · {text}");
    {
        let mut last = state.tooltip.lock().unwrap();
        if *last == tooltip && !active_changed {
            return;
        }
        *last = tooltip.clone();
    }
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        let state = app2.state::<TrayState>();
        let Some(tray) = app2.tray_by_id(TRAY_ID) else {
            return;
        };
        let _ = tray.set_tooltip(Some(&tooltip));
        if active_changed || state.active.load(Ordering::SeqCst) != active {
            state.active.store(active, Ordering::SeqCst);
            if let Ok((menu, status)) = build_menu(&app2, active, remaining) {
                let _ = tray.set_menu(Some(menu));
                *state.status_item.lock().unwrap() = Some(status);
            }
            let _ = tray.set_icon(Some(icon(active)));
            let _ = tray.set_icon_as_template(cfg!(target_os = "macos"));
        } else if let Some(item) = state.status_item.lock().unwrap().as_ref() {
            let _ = item.set_text(&text);
        }
    });
}

// MARK: Panel

fn panel(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("panel")
}

pub fn toggle_panel(app: &AppHandle) {
    let ctx = app.state::<Arc<Ctx>>();
    if panel(app)
        .map(|p| p.is_visible().unwrap_or(false))
        .unwrap_or(false)
    {
        hide_panel(app);
    } else if ctx.last_panel_close.lock().unwrap().elapsed() > Duration::from_millis(300) {
        // Clicking the icon first takes focus away (closing the panel);
        // don't reopen it on the same click.
        show_panel(app);
    }
}

pub fn show_panel(app: &AppHandle) {
    let Some(win) = panel(app) else { return };
    let ctx = app.state::<Arc<Ctx>>();
    *ctx.panel_shown_at.lock().unwrap() = Instant::now();
    let _ = win.emit("panel-will-open", ());
    ctx.emit(app);
    place_panel(&win);
    let _ = win.show();
    let _ = win.set_focus();
}

pub fn hide_panel(app: &AppHandle) {
    let Some(win) = panel(app) else { return };
    if win.is_visible().unwrap_or(false) {
        let ctx = app.state::<Arc<Ctx>>();
        *ctx.last_panel_close.lock().unwrap() = Instant::now();
        let _ = win.hide();
    }
}

/// Focus loss closes the panel, except in the first moments after opening
/// (some window managers report a spurious blur while the window maps).
pub fn panel_lost_focus(app: &AppHandle) {
    let ctx = app.state::<Arc<Ctx>>();
    if ctx.panel_shown_at.lock().unwrap().elapsed() > Duration::from_millis(250) {
        hide_panel(app);
    }
}

/// Next to the tray icon: above it on Windows and Linux (taskbar at the
/// bottom), below it on macOS. Without a tray rect (some Linux desktops)
/// the panel sits in the bottom-right corner of the screen.
fn place_panel(win: &WebviewWindow) {
    let w = win.as_ref().window();
    let preferred = if cfg!(target_os = "macos") {
        Position::TrayBottomCenter
    } else {
        Position::TrayCenter
    };
    if w.move_window_constrained(preferred).is_err() {
        let _ = w.move_window(Position::BottomRight);
    }
}

/// The page reports its content height; the window follows it.
pub fn resize_panel(app: &AppHandle, height: f64) {
    let Some(win) = panel(app) else { return };
    let height = height.clamp(120.0, 900.0);
    if cfg!(debug_assertions) {
        lidless_core::log::info(&format!("panel content height {height}"));
    }
    let _ = win.set_size(LogicalSize::new(PANEL_WIDTH, height));
    place_panel(&win);
}

// MARK: Desktop window

pub fn show_window(app: &AppHandle, page: Option<&str>) {
    let Some(win) = app.get_webview_window("main") else {
        return;
    };
    if let Some(page) = page {
        let _ = win.emit("navigate", page);
    }
    if !win.is_visible().unwrap_or(false) {
        let ctx = app.state::<Arc<Ctx>>();
        let st = ctx.app_state.lock().unwrap();
        if let (Some(w), Some(h)) = (st.window_width, st.window_height) {
            let _ = win.set_size(LogicalSize::new(w.max(WINDOW_MIN.0), h.max(WINDOW_MIN.1)));
        }
    }
    hide_panel(app);
    let _ = win.show();
    let _ = win.unminimize();
    let _ = win.set_focus();
}

pub fn remember_window_size(app: &AppHandle, width: f64, height: f64) {
    let ctx = app.state::<Arc<Ctx>>();
    let mut st = ctx.app_state.lock().unwrap();
    st.window_width = Some(width.max(WINDOW_MIN.0));
    st.window_height = Some(height.max(WINDOW_MIN.1));
}

// MARK: Quit

/// Ends the session this app owns, then exits. Safe to call more than once.
pub fn quit(app: &AppHandle) {
    let ctx = app.state::<Arc<Ctx>>().inner().clone();
    if ctx.shutting_down.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        ctx.end_for_exit(EndReason::Quit);
        app.exit(0);
    });
}
