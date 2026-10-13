//! App-wide state and the session thread.
//!
//! The app is the owner of the sessions it starts (`SessionOwner`), driven by
//! a 1 s tick on one background thread. Everything the pages show lives in
//! `Shared`; every tick (and after every action) the full `Snapshot` is sent
//! to both windows as the `state` event.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::Utc;
use lidless_core::agents::{self, DetectedAgent};
use lidless_core::control::{self, StopRequest};
use lidless_core::engine::{Elevation, Engine, ReadinessReport};
use lidless_core::floors::ThermalLevel;
use lidless_core::model::{Config, EndReason, OwnerKind};
use lidless_core::notify::{DesktopNotifier, Notifier};
use lidless_core::owner::{OwnerEnv, SessionOwner};
use lidless_core::process::ProcessInspector;
use lidless_core::status::{self, StatusSnapshot};
use lidless_core::store::Store;
use lidless_core::update::{self, ReleaseInfo, UpdateCheck};
use lidless_core::{log, recovery, VERSION};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::persist::AppState;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum UpdateState {
    Idle,
    Checking,
    UpToDate { version: String },
    NoReleases,
    Available { release: ReleaseInfo },
    Downloading { release: ReleaseInfo },
    Downloaded { release: ReleaseInfo, path: PathBuf },
    Failed { message: String },
}

impl UpdateState {
    pub fn release(&self) -> Option<&ReleaseInfo> {
        match self {
            UpdateState::Available { release }
            | UpdateState::Downloading { release }
            | UpdateState::Downloaded { release, .. } => Some(release),
            _ => None,
        }
    }
}

/// Everything the UI shows. Serialised as-is inside `Snapshot`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Shared {
    pub status: Option<StatusSnapshot>,
    pub agents: Vec<DetectedAgent>,
    pub readiness: Option<ReadinessReport>,
    pub config: Config,
    pub thermal: ThermalLevel,
    pub online: bool,
    pub pending_start: Option<f64>,
    pub busy: Option<String>,
    pub error: Option<String>,
    pub setup_message: Option<String>,
    pub setup_running: bool,
    pub update: UpdateState,
    pub first_run_acknowledged: bool,
    pub low_power_active: bool,
    pub owned_here: bool,
    pub autostart: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot<'a> {
    #[serde(flatten)]
    pub shared: &'a Shared,
    pub version: &'static str,
    pub platform: &'static str,
    pub privileged_operations: Vec<String>,
    pub history_version: u64,
    /// Milliseconds since the epoch, so the pages can count down between events.
    pub now: i64,
}

pub enum Request {
    Start {
        seconds: f64,
    },
    Stop,
    /// Ends the session this app owns (quit, SIGTERM). Replies when done.
    End {
        reason: EndReason,
        reply: SyncSender<()>,
    },
    Refresh,
    RefreshReadiness,
}

pub struct Ctx {
    pub engine: &'static dyn Engine,
    pub inspector: &'static dyn ProcessInspector,
    pub store: Store,
    pub shared: Mutex<Shared>,
    pub tx: Sender<Request>,
    pub app_state: Mutex<AppState>,
    pub history_version: AtomicU64,
    pub shutting_down: AtomicBool,
    pub last_panel_close: Mutex<Instant>,
    pub panel_shown_at: Mutex<Instant>,
}

impl Ctx {
    pub fn new(
        engine: &'static dyn Engine,
        inspector: &'static dyn ProcessInspector,
        store: Store,
        tx: Sender<Request>,
    ) -> Ctx {
        let config = store.read_config();
        let first_run_acknowledged = store.paths.first_run_marker().exists();
        let app_state = AppState::load(&store.paths);
        Ctx {
            engine,
            inspector,
            store,
            shared: Mutex::new(Shared {
                status: None,
                agents: Vec::new(),
                readiness: None,
                config,
                thermal: ThermalLevel::Nominal,
                online: true,
                pending_start: None,
                busy: None,
                error: None,
                setup_message: None,
                setup_running: false,
                update: UpdateState::Idle,
                first_run_acknowledged,
                low_power_active: false,
                owned_here: false,
                autostart: false,
            }),
            tx,
            app_state: Mutex::new(app_state),
            history_version: AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
            last_panel_close: Mutex::new(Instant::now() - Duration::from_secs(10)),
            panel_shown_at: Mutex::new(Instant::now() - Duration::from_secs(10)),
        }
    }

    pub fn snapshot_json(&self) -> serde_json::Value {
        let shared = self.shared.lock().unwrap();
        let snap = Snapshot {
            shared: &shared,
            version: VERSION,
            platform: self.engine.platform(),
            privileged_operations: self.engine.privileged_operations(),
            history_version: self.history_version.load(Ordering::SeqCst),
            now: Utc::now().timestamp_millis(),
        };
        serde_json::to_value(snap).unwrap_or(serde_json::Value::Null)
    }

    /// Sends the full state to every window.
    pub fn emit(&self, app: &AppHandle) {
        let _ = app.emit("state", self.snapshot_json());
    }

    pub fn bump_history(&self) {
        self.history_version.fetch_add(1, Ordering::SeqCst);
    }

    pub fn save_app_state(&self) {
        self.app_state.lock().unwrap().save(&self.store.paths);
    }

    // MARK: Session actions (quick parts run here; slow parts on the worker)

    /// Every start goes through here: the ventilation checkpoint is shown
    /// before the first session ever and whenever the computer is warm.
    pub fn request_start(&self, app: &AppHandle, seconds: f64) {
        {
            let mut sh = self.shared.lock().unwrap();
            if sh.busy.is_some() {
                return;
            }
            sh.error = None;
            let heat = self.engine.thermal();
            sh.thermal = heat;
            if sh.config.thermal_rules && heat == ThermalLevel::Critical {
                sh.error = heat.start_warning().map(str::to_string);
                drop(sh);
                self.emit(app);
                return;
            }
            if !sh.first_run_acknowledged || heat.is_warm() {
                sh.pending_start = Some(seconds);
                drop(sh);
                self.emit(app);
                return;
            }
        }
        self.begin(app, seconds);
    }

    pub fn confirm_start(&self, app: &AppHandle) {
        let seconds = {
            let mut sh = self.shared.lock().unwrap();
            let Some(seconds) = sh.pending_start.take() else {
                return;
            };
            if !sh.first_run_acknowledged {
                let _ = self.store.paths.ensure_home();
                let _ = lidless_core::store::write_atomic(
                    &self.store.paths.first_run_marker(),
                    Utc::now().to_rfc3339().as_bytes(),
                );
                sh.first_run_acknowledged = true;
            }
            let heat = self.engine.thermal();
            sh.thermal = heat;
            if sh.config.thermal_rules && heat == ThermalLevel::Critical {
                sh.error = heat.start_warning().map(str::to_string);
                drop(sh);
                self.emit(app);
                return;
            }
            seconds
        };
        self.begin(app, seconds);
    }

    pub fn cancel_start(&self, app: &AppHandle) {
        self.shared.lock().unwrap().pending_start = None;
        self.emit(app);
    }

    fn begin(&self, app: &AppHandle, seconds: f64) {
        {
            let mut sh = self.shared.lock().unwrap();
            sh.busy = Some("Turning on…".into());
        }
        self.emit(app);
        let _ = self.tx.send(Request::Start { seconds });
    }

    pub fn extend(&self, app: &AppHandle, seconds: f64) {
        {
            let mut sh = self.shared.lock().unwrap();
            sh.error = None;
            // The owner (this app or another process) picks the new end up on its next tick.
            if let Err(e) = control::extend(&self.store, seconds, Utc::now()) {
                sh.error = Some(e.to_string());
            }
        }
        let _ = self.tx.send(Request::Refresh);
        self.emit(app);
    }

    pub fn stop(&self, app: &AppHandle) {
        {
            let mut sh = self.shared.lock().unwrap();
            if sh.busy.is_some() {
                return;
            }
            sh.error = None;
            sh.busy = Some("Restoring normal sleep…".into());
        }
        self.emit(app);
        let _ = self.tx.send(Request::Stop);
    }

    /// Hard rule 6: quitting always ends the session this app owns. Blocks
    /// until the owner has restored everything (or 90 s).
    pub fn end_for_exit(&self, reason: EndReason) {
        let (reply, done) = std::sync::mpsc::sync_channel(1);
        if self.tx.send(Request::End { reason, reply }).is_ok() {
            let _ = done.recv_timeout(Duration::from_secs(90));
        }
        self.save_app_state();
    }

    pub fn set_config(&self, app: &AppHandle, config: Config) -> Result<(), String> {
        self.store
            .write_config(&config)
            .map_err(|e| e.to_string())?;
        self.shared.lock().unwrap().config = config.normalized();
        self.emit(app);
        Ok(())
    }

    // MARK: Setup

    pub fn run_setup(self: &Arc<Self>, app: AppHandle) {
        {
            let mut sh = self.shared.lock().unwrap();
            if sh.setup_running {
                return;
            }
            sh.setup_running = true;
            sh.setup_message = None;
        }
        self.emit(&app);
        let ctx = self.clone();
        std::thread::spawn(move || {
            let result = ctx
                .engine
                .install(&crate::engine::cli_path(), Elevation::Prompt);
            {
                let mut sh = ctx.shared.lock().unwrap();
                sh.setup_running = false;
                sh.setup_message = match result {
                    Ok(steps) => {
                        log::info(&format!("setup: {}", steps.join("; ")));
                        None
                    }
                    Err(e) => Some(e.to_string()),
                };
            }
            let _ = ctx.tx.send(Request::RefreshReadiness);
            ctx.emit(&app);
        });
    }

    pub fn run_uninstall(self: &Arc<Self>, app: AppHandle) {
        {
            let mut sh = self.shared.lock().unwrap();
            if sh.setup_running {
                return;
            }
            if sh.status.as_ref().map(|s| s.active).unwrap_or(false) {
                sh.setup_message = Some("Stop the current session first.".into());
                drop(sh);
                self.emit(&app);
                return;
            }
            sh.setup_running = true;
            sh.setup_message = None;
        }
        self.emit(&app);
        let ctx = self.clone();
        std::thread::spawn(move || {
            let result = ctx.engine.uninstall(Elevation::Prompt);
            {
                let mut sh = ctx.shared.lock().unwrap();
                sh.setup_running = false;
                sh.setup_message = Some(match result {
                    Ok(steps) => {
                        format!("Removed: {}. You can now delete Lidless.", steps.join(", "))
                    }
                    Err(e) => e.to_string(),
                });
            }
            let _ = ctx.tx.send(Request::RefreshReadiness);
            ctx.emit(&app);
        });
    }

    // MARK: Updates

    pub fn check_updates(self: &Arc<Self>, app: AppHandle) {
        {
            let mut sh = self.shared.lock().unwrap();
            if matches!(
                sh.update,
                UpdateState::Checking | UpdateState::Downloading { .. }
            ) {
                return;
            }
            sh.update = UpdateState::Checking;
        }
        self.emit(&app);
        let ctx = self.clone();
        std::thread::spawn(move || {
            let result = update::check(VERSION);
            {
                let mut sh = ctx.shared.lock().unwrap();
                sh.update = match result {
                    Ok(UpdateCheck::UpToDate(v)) => UpdateState::UpToDate { version: v },
                    Ok(UpdateCheck::Available(r)) => UpdateState::Available { release: r },
                    Ok(UpdateCheck::NoReleases) => UpdateState::NoReleases,
                    Err(e) => UpdateState::Failed {
                        message: e.to_string(),
                    },
                };
            }
            {
                let mut st = ctx.app_state.lock().unwrap();
                st.last_update_check = Some(Utc::now());
                st.save(&ctx.store.paths);
            }
            ctx.emit(&app);
        });
    }

    pub fn download_update(self: &Arc<Self>, app: AppHandle) {
        let release = {
            let mut sh = self.shared.lock().unwrap();
            let Some(r) = sh.update.release().cloned() else {
                return;
            };
            sh.update = UpdateState::Downloading { release: r.clone() };
            r
        };
        self.emit(&app);
        let ctx = self.clone();
        std::thread::spawn(move || {
            let result = update::download(&release);
            {
                let mut sh = ctx.shared.lock().unwrap();
                sh.update = match result {
                    Ok(path) => UpdateState::Downloaded { release, path },
                    Err(e) => UpdateState::Failed {
                        message: e.to_string(),
                    },
                };
            }
            ctx.emit(&app);
        });
    }

    /// Once a day when enabled.
    fn maybe_auto_check(self: &Arc<Self>, app: &AppHandle) {
        let enabled = self.shared.lock().unwrap().config.check_for_updates;
        if !enabled {
            return;
        }
        let due = {
            let st = self.app_state.lock().unwrap();
            st.last_update_check
                .map(|t| Utc::now() - t > chrono::Duration::hours(24))
                .unwrap_or(true)
        };
        if due {
            self.check_updates(app.clone());
        }
    }
}

/// True when a default route exists. `connect` on a UDP socket consults the
/// routing table without sending a packet, so this makes no network request.
fn online_now() -> bool {
    std::net::UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| s.connect("1.1.1.1:53").and_then(|_| s.local_addr()))
        .map(|a| !a.ip().is_loopback() && !a.ip().is_unspecified())
        .unwrap_or(false)
}

/// The session thread. Owns the `SessionOwner`; nothing else touches it.
pub fn run(app: AppHandle, ctx: Arc<Ctx>, rx: Receiver<Request>) {
    let notifier: &'static DesktopNotifier = Box::leak(Box::new(DesktopNotifier));
    let mut owner = SessionOwner::new(OwnerEnv::live(
        ctx.engine,
        ctx.store.clone(),
        ctx.inspector,
        notifier,
    ));

    // Finish anything a crashed earlier run left behind.
    let outcome = recovery::run(ctx.engine, &ctx.store, ctx.inspector, Utc::now(), None);
    if outcome.action != recovery::RecoveryAction::Nothing {
        log::info(&format!("app launch recovery: {}", outcome.message));
    }

    let mut tick: u64 = 0;
    let mut was_active = false;
    let mut next = Instant::now();
    refresh_readiness(&ctx);
    refresh_slow(&ctx, &mut was_active, notifier);
    refresh_status(&ctx, &owner, &mut was_active, &app);
    ctx.emit(&app);

    loop {
        let timeout = next.saturating_duration_since(Instant::now());
        match rx.recv_timeout(timeout) {
            Ok(Request::Start { seconds }) => {
                let result = owner.start(seconds, OwnerKind::App, None);
                {
                    let mut sh = ctx.shared.lock().unwrap();
                    sh.busy = None;
                    if let Err(e) = &result {
                        sh.error = Some(e.to_string());
                    }
                }
                if result.is_err() {
                    refresh_readiness(&ctx);
                }
                refresh_status(&ctx, &owner, &mut was_active, &app);
                ctx.emit(&app);
            }
            Ok(Request::Stop) => {
                stop(&ctx, &mut owner);
                ctx.shared.lock().unwrap().busy = None;
                refresh_status(&ctx, &owner, &mut was_active, &app);
                ctx.emit(&app);
            }
            Ok(Request::End { reason, reply }) => {
                if owner.session().is_some() {
                    owner.end(reason, None);
                    ctx.bump_history();
                }
                let _ = reply.send(());
                refresh_status(&ctx, &owner, &mut was_active, &app);
            }
            Ok(Request::Refresh) => {
                refresh_status(&ctx, &owner, &mut was_active, &app);
                ctx.emit(&app);
            }
            Ok(Request::RefreshReadiness) => {
                refresh_readiness(&ctx);
                refresh_status(&ctx, &owner, &mut was_active, &app);
                ctx.emit(&app);
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {
                tick += 1;
                next += Duration::from_secs(1);
                if next < Instant::now() {
                    next = Instant::now() + Duration::from_secs(1);
                }
                if owner.session().is_some() {
                    if let Some((reason, detail)) = owner.tick(None) {
                        owner.end(reason, detail);
                        ctx.bump_history();
                    }
                }
                if tick.is_multiple_of(5) {
                    refresh_slow(&ctx, &mut was_active, notifier);
                }
                if tick.is_multiple_of(30) {
                    refresh_readiness(&ctx);
                }
                if tick == 3 || tick.is_multiple_of(3600) {
                    ctx.maybe_auto_check(&app);
                }
                refresh_status(&ctx, &owner, &mut was_active, &app);
                ctx.emit(&app);
            }
        }
    }
}

fn stop(ctx: &Arc<Ctx>, owner: &mut SessionOwner<'static>) {
    if owner.session().is_some() {
        owner.end(EndReason::Stopped, None);
        ctx.bump_history();
        return;
    }
    let error = match control::request_stop(
        &ctx.store,
        ctx.inspector,
        "Stopped from the Lidless app",
    ) {
        Ok(StopRequest::Requested(id)) => match control::wait_for_end(
            &ctx.store,
            id,
            Duration::from_secs(45),
        ) {
            Some(_) => None,
            None => Some(
                "The session owner did not finish in time. The recovery job will finish the job."
                    .to_string(),
            ),
        },
        Ok(StopRequest::OwnerDead(_)) => {
            let outcome = recovery::run(
                ctx.engine,
                &ctx.store,
                ctx.inspector,
                Utc::now(),
                Some(EndReason::Stopped),
            );
            if outcome.report.complete() {
                None
            } else {
                Some(outcome.message)
            }
        }
        Err(e) => Some(e.to_string()),
    };
    ctx.bump_history();
    if let Some(e) = error {
        ctx.shared.lock().unwrap().error = Some(e);
    }
}

fn refresh_readiness(ctx: &Ctx) {
    let r = ctx.engine.readiness();
    ctx.shared.lock().unwrap().readiness = Some(r);
}

/// Agents, thermal state and connectivity: every 5 s.
fn refresh_slow(ctx: &Ctx, was_active: &mut bool, notifier: &dyn Notifier) {
    let extra = ctx.shared.lock().unwrap().config.extra_agent_names.clone();
    let agents = agents::detect(&extra);
    let thermal = ctx.engine.thermal();
    let online = online_now();
    let mut sh = ctx.shared.lock().unwrap();
    let dropped = sh.online && !online;
    sh.agents = agents;
    sh.thermal = thermal;
    sh.online = online;
    if dropped && *was_active && sh.config.warn_on_network_loss && sh.config.notifications {
        notifier.notify("Network dropped", "The connection went away while Lidless is keeping this computer awake. Remote access may not reach it.");
    }
}

fn refresh_status(
    ctx: &Ctx,
    owner: &SessionOwner<'static>,
    was_active: &mut bool,
    app: &AppHandle,
) {
    let readiness = ctx.shared.lock().unwrap().readiness.clone();
    let status = status::collect(ctx.engine, &ctx.store, ctx.inspector, readiness, Utc::now());
    let active = status.active;
    let remaining = status
        .session
        .as_ref()
        .map(|s| s.remaining_seconds)
        .unwrap_or(0);
    {
        let mut sh = ctx.shared.lock().unwrap();
        sh.status = Some(status);
        sh.low_power_active = owner.low_power_active;
        sh.owned_here = owner.session().is_some();
    }
    if *was_active && !active {
        ctx.bump_history();
    }
    crate::tray::sync(app, active, remaining, *was_active != active);
    *was_active = active;
}
