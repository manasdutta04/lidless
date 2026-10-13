//! Lidless tray app for Windows and Linux (Tauri 2). On macOS it builds as a
//! design preview against the core's fake engine.

#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

mod commands;
mod engine;
mod persist;
mod tray;
mod worker;

use std::sync::atomic::Ordering;
use std::sync::Arc;

use lidless_core::engine::Engine;
use lidless_core::log;
use lidless_core::model::EndReason;
use lidless_core::paths::Paths;
use lidless_core::process::{ProcessInspector, SystemProcessInspector};
use lidless_core::store::Store;
use tauri::{Manager, RunEvent, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

use worker::{Ctx, Request};

fn main() {
    let paths = Paths::resolve();
    let _ = paths.ensure_home();
    log::configure(paths.log(), false);
    let engine: &'static dyn Engine = Box::leak(engine::make());
    let inspector: &'static dyn ProcessInspector = Box::leak(Box::new(SystemProcessInspector));
    let store = Store::new(paths);
    let (tx, rx) = std::sync::mpsc::channel::<Request>();
    let ctx = Arc::new(Ctx::new(engine, inspector, store, tx));
    let rx = std::sync::Mutex::new(Some(rx));

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_positioner::init())
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_opener::init())
        .manage(ctx.clone())
        .invoke_handler(tauri::generate_handler![
            commands::get_status,
            commands::parse_duration,
            commands::start,
            commands::confirm_start,
            commands::cancel_start,
            commands::extend,
            commands::stop,
            commands::dismiss_error,
            commands::get_stats,
            commands::get_history,
            commands::get_config,
            commands::set_config,
            commands::get_readiness,
            commands::setup,
            commands::uninstall,
            commands::check_updates,
            commands::download_update,
            commands::reveal_download,
            commands::open_url,
            commands::open_log,
            commands::open_panel,
            commands::close_panel,
            commands::resize_panel,
            commands::open_window,
            commands::hide_window,
            commands::quit,
            commands::set_autostart,
            commands::version,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            tray::install(&handle)?;

            {
                let ctx = handle.state::<Arc<Ctx>>();
                ctx.shared.lock().unwrap().autostart =
                    handle.autolaunch().is_enabled().unwrap_or(false);
                #[cfg(target_os = "macos")]
                {
                    let show = ctx.shared.lock().unwrap().config.show_in_dock;
                    let _ = handle.set_dock_visibility(show);
                }
            }

            // The session thread.
            let rx = rx.lock().unwrap().take().expect("worker receiver");
            let ctx2 = handle.state::<Arc<Ctx>>().inner().clone();
            let h2 = handle.clone();
            std::thread::Builder::new()
                .name("lidless-owner".into())
                .spawn(move || worker::run(h2, ctx2, rx))?;

            // SIGTERM / console close: end the session, then exit (Hard rule 6).
            let h3 = handle.clone();
            let _ = ctrlc::set_handler(move || tray::quit(&h3));

            // First launch, or setup still needed: open the window.
            let ctx = handle.state::<Arc<Ctx>>().inner().clone();
            let first = !ctx.app_state.lock().unwrap().launched_before;
            let ready = engine.readiness().ready();
            if first || !ready {
                tray::show_window(&handle, Some(if ready { "overview" } else { "setup" }));
            }
            if first {
                let mut st = ctx.app_state.lock().unwrap();
                st.launched_before = true;
                st.save(&ctx.store.paths);
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            let app = window.app_handle();
            match (window.label(), event) {
                ("main", WindowEvent::CloseRequested { api, .. }) => {
                    // Closing the window never quits.
                    api.prevent_close();
                    let _ = window.hide();
                    app.state::<Arc<Ctx>>().save_app_state();
                }
                ("main", WindowEvent::Resized(size)) => {
                    if let Ok(scale) = window.scale_factor() {
                        let logical = size.to_logical::<f64>(scale);
                        if logical.width > 0.0
                            && logical.height > 0.0
                            && window.is_visible().unwrap_or(false)
                        {
                            tray::remember_window_size(app, logical.width, logical.height);
                        }
                    }
                }
                ("panel", WindowEvent::Focused(false)) => tray::panel_lost_focus(app),
                ("panel", WindowEvent::CloseRequested { api, .. }) => {
                    api.prevent_close();
                    tray::hide_panel(app);
                }
                _ => {}
            }
        })
        .build(tauri::generate_context!())
        .expect("Lidless could not start");

    app.run(move |app, event| {
        if let RunEvent::ExitRequested { api, code, .. } = event {
            let ctx = app.state::<Arc<Ctx>>();
            // Hard rule 6: no exit path skips ending the session.
            if code.is_none() && !ctx.shutting_down.load(Ordering::SeqCst) {
                api.prevent_exit();
                tray::quit(app);
            } else if !ctx.shutting_down.swap(true, Ordering::SeqCst) {
                ctx.end_for_exit(EndReason::Quit);
            }
        }
    });
}
