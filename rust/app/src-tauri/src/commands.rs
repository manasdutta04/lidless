//! Tauri commands: thin wrappers over `Ctx`. Every command that changes
//! state ends with a `state` event, so the pages never poll.

use std::sync::Arc;

use chrono::Utc;
use lidless_core::engine::ReadinessReport;
use lidless_core::history::{self, UsageStats};
use lidless_core::model::{Config, HistoryEntry};
use lidless_core::{duration, VERSION};
use serde::Serialize;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_opener::OpenerExt;

use crate::tray;
use crate::worker::{Ctx, UpdateState};

type Shared<'a> = State<'a, Arc<Ctx>>;

#[tauri::command]
pub fn get_status(ctx: Shared) -> serde_json::Value {
    ctx.snapshot_json()
}

/// Parses a duration the way the CLI does ("2h", "90m", "1h 30m").
#[tauri::command]
pub fn parse_duration(raw: String) -> Result<f64, String> {
    duration::parse(&raw)
        .map(|s| s as f64)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn start(app: AppHandle, ctx: Shared, seconds: f64) {
    ctx.request_start(&app, seconds);
}

#[tauri::command]
pub fn confirm_start(app: AppHandle, ctx: Shared) {
    ctx.confirm_start(&app);
}

#[tauri::command]
pub fn cancel_start(app: AppHandle, ctx: Shared) {
    ctx.cancel_start(&app);
}

#[tauri::command]
pub fn extend(app: AppHandle, ctx: Shared, seconds: f64) {
    ctx.extend(&app, seconds);
}

#[tauri::command]
pub fn stop(app: AppHandle, ctx: Shared) {
    ctx.stop(&app);
}

#[tauri::command]
pub fn dismiss_error(app: AppHandle, ctx: Shared) {
    ctx.shared.lock().unwrap().error = None;
    ctx.emit(&app);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub stats: UsageStats,
    pub daily: Vec<history::Day>,
    pub hours: [f64; 24],
}

#[tauri::command]
pub fn get_stats(ctx: Shared) -> Stats {
    let entries = history::read(&ctx.store);
    let now = Utc::now();
    Stats {
        stats: history::compute(&entries, now),
        daily: history::daily(&entries, 84, now),
        hours: history::hour_of_day(&entries),
    }
}

/// Newest first.
#[tauri::command]
pub fn get_history(ctx: Shared) -> Vec<HistoryEntry> {
    let mut entries = history::read(&ctx.store);
    entries.reverse();
    entries
}

#[tauri::command]
pub fn get_config(ctx: Shared) -> Config {
    ctx.shared.lock().unwrap().config.clone()
}

#[tauri::command]
pub fn set_config(app: AppHandle, ctx: Shared, config: Config) -> Result<(), String> {
    ctx.set_config(&app, config)?;
    #[cfg(target_os = "macos")]
    {
        let show = ctx.shared.lock().unwrap().config.show_in_dock;
        let _ = app.set_dock_visibility(show);
    }
    Ok(())
}

#[tauri::command]
pub fn get_readiness(ctx: Shared) -> Option<ReadinessReport> {
    ctx.shared.lock().unwrap().readiness.clone()
}

#[tauri::command]
pub fn setup(app: AppHandle, ctx: Shared) {
    ctx.inner().run_setup(app);
}

#[tauri::command]
pub fn uninstall(app: AppHandle, ctx: Shared) {
    ctx.inner().run_uninstall(app);
}

#[tauri::command]
pub fn check_updates(app: AppHandle, ctx: Shared) {
    ctx.inner().check_updates(app);
}

#[tauri::command]
pub fn download_update(app: AppHandle, ctx: Shared) {
    ctx.inner().download_update(app);
}

#[tauri::command]
pub fn reveal_download(app: AppHandle, ctx: Shared) -> Result<(), String> {
    let path = match &ctx.shared.lock().unwrap().update {
        UpdateState::Downloaded { path, .. } => path.clone(),
        _ => return Err("Nothing has been downloaded yet.".into()),
    };
    app.opener()
        .reveal_item_in_dir(&path)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("Only web links can be opened.".into());
    }
    app.opener()
        .open_url(url, None::<&str>)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn open_log(app: AppHandle, ctx: Shared) -> Result<(), String> {
    let path = ctx.store.paths.log();
    if !path.exists() {
        let _ = ctx.store.paths.ensure_home();
        let _ = std::fs::write(&path, b"");
    }
    app.opener()
        .open_path(path.to_string_lossy().to_string(), None::<&str>)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn open_panel(app: AppHandle) {
    tray::show_panel(&app);
}

#[tauri::command]
pub fn close_panel(app: AppHandle) {
    tray::hide_panel(&app);
}

#[tauri::command]
pub fn resize_panel(app: AppHandle, height: f64) {
    tray::resize_panel(&app, height);
}

#[tauri::command]
pub fn open_window(app: AppHandle, page: Option<String>) {
    tray::show_window(&app, page.as_deref());
}

#[tauri::command]
pub fn hide_window(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.hide();
    }
}

#[tauri::command]
pub fn quit(app: AppHandle) {
    tray::quit(&app);
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, ctx: Shared, enabled: bool) -> Result<(), String> {
    let launcher = app.autolaunch();
    let result = if enabled {
        launcher.enable()
    } else {
        launcher.disable()
    };
    result.map_err(|e| e.to_string())?;
    ctx.shared.lock().unwrap().autostart = launcher.is_enabled().unwrap_or(enabled);
    ctx.emit(&app);
    Ok(())
}

#[tauri::command]
pub fn version() -> &'static str {
    VERSION
}
