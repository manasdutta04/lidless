//! The session owner: engage → verify → tick → floors → restore
//! (spec/session.md rule 3). One owner per session, running in the process
//! that started it (the tray app, a detached `lidless start` holder, or
//! `lidless run`).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, Utc};

use crate::engine::{AwakeHold, Engine};
use crate::error::{LidlessError, Result};
use crate::floors::{self, ThermalLevel};
use crate::history;
use crate::log;
use crate::model::{Config, EndReason, HistoryEntry, LastEnd, OwnerKind, Session};
use crate::notify::Notifier;
use crate::process::ProcessInspector;
use crate::recovery;
use crate::store::{SessionRead, Store};

pub type Clock = Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>;
pub type Sleeper = Arc<dyn Fn(f64) + Send + Sync>;

pub struct OwnerEnv<'a> {
    pub engine: &'a dyn Engine,
    pub store: Store,
    pub inspector: &'a dyn ProcessInspector,
    pub notifier: &'a dyn Notifier,
    pub now: Clock,
    pub sleep: Sleeper,
}

impl<'a> OwnerEnv<'a> {
    pub fn live(
        engine: &'a dyn Engine,
        store: Store,
        inspector: &'a dyn ProcessInspector,
        notifier: &'a dyn Notifier,
    ) -> Self {
        OwnerEnv {
            engine,
            store,
            inspector,
            notifier,
            now: Arc::new(Utc::now),
            sleep: Arc::new(|s: f64| std::thread::sleep(StdDuration::from_secs_f64(s.max(0.0)))),
        }
    }
}

pub const FLOOR_EVERY_TICKS: u64 = 15;
pub const VERIFY_EVERY_TICKS: u64 = 60;
pub const LID_DEBOUNCE_TICKS: u32 = 2;

pub struct SessionOwner<'a> {
    pub env: OwnerEnv<'a>,
    config: Config,
    session: Option<Session>,
    hold: Option<Box<dyn AwakeHold>>,
    tick_count: u64,
    unreadable_battery: u32,
    pub lid_closed: Option<bool>,
    lid_candidate: Option<bool>,
    lid_candidate_ticks: u32,
    pub low_power_active: bool,
    lid_closed_since: Option<DateTime<Utc>>,
    closed_lid_seconds: f64,
    low_power_failure_notified: bool,
    pub last_end: Option<LastEnd>,
}

impl<'a> SessionOwner<'a> {
    pub fn new(env: OwnerEnv<'a>) -> Self {
        SessionOwner {
            env,
            config: Config::default(),
            session: None,
            hold: None,
            tick_count: 0,
            unreadable_battery: 0,
            lid_closed: None,
            lid_candidate: None,
            lid_candidate_ticks: 0,
            low_power_active: false,
            lid_closed_since: None,
            closed_lid_seconds: 0.0,
            low_power_failure_notified: false,
            last_end: None,
        }
    }

    pub fn session(&self) -> Option<&Session> {
        self.session.as_ref()
    }

    fn now(&self) -> DateTime<Utc> {
        (self.env.now)()
    }

    fn notify(&self, title: &str, body: &str) {
        if self.config.notifications {
            self.env.notifier.notify(title, body);
        }
    }

    /// Starts a session and returns once the closed-lid awake state is
    /// verified. On any failure, restores and returns the error.
    pub fn start(
        &mut self,
        duration_seconds: f64,
        kind: OwnerKind,
        command: Option<Vec<String>>,
    ) -> Result<Session> {
        if self.session.is_some() {
            return Err(LidlessError::SessionActive);
        }
        self.config = self.env.store.read_config();
        if duration_seconds <= 0.0 {
            return Err(LidlessError::Usage(
                "Duration must be greater than zero.".into(),
            ));
        }
        if duration_seconds > self.config.max_duration_seconds {
            return Err(LidlessError::Usage(format!(
                "The longest session is {}.",
                crate::duration::format(self.config.max_duration_seconds)
            )));
        }
        if self.config.thermal_rules && self.env.engine.thermal() == ThermalLevel::Critical {
            return Err(LidlessError::NotReady(
                ThermalLevel::Critical.start_warning().unwrap().into(),
            ));
        }

        // Hard rule 2: never start unless recovery is armed.
        let readiness = self.env.engine.readiness();
        if let Some(e) = readiness.not_ready_error(&self.env.engine.fix_hint()) {
            return Err(e);
        }

        // Clear up anything a crashed earlier owner left behind.
        let prior = recovery::run(
            self.env.engine,
            &self.env.store,
            self.env.inspector,
            self.now(),
            Some(EndReason::OwnerLost),
        );
        if prior.action != recovery::RecoveryAction::Nothing {
            log::info(&format!("before start: {}", prior.message));
        }

        let now = self.now();
        let session = Session::new(
            now,
            now + Duration::milliseconds((duration_seconds * 1000.0) as i64),
            self.env.inspector.current_identity(kind),
            command,
        );
        let store = self.env.store.clone();
        let inspector = self.env.inspector;
        let s2 = session.clone();
        store.with_lock(|| {
            match store.read_session() {
                SessionRead::Some(existing) if inspector.is_alive(&existing.owner) => return Err(LidlessError::SessionActive),
                SessionRead::Some(_) | SessionRead::Unreadable(_) => {
                    return Err(LidlessError::System(
                        "A previous session could not be cleaned up. Run `lidless status` for details.".into(),
                    ))
                }
                SessionRead::None => {}
            }
            if !store.read_journal()?.is_empty() {
                return Err(LidlessError::RestoreIncomplete(
                    "Settings from an earlier session are still waiting to be restored, so Lidless will not start a new one. Run `lidless recover` or `lidless doctor`.".into(),
                ));
            }
            store.write_session(&s2)
        })?;
        log::info(&format!(
            "session {} starting for {}, owner {:?} pid {}",
            session.id,
            crate::duration::format(duration_seconds),
            kind,
            session.owner.pid
        ));

        let engaged = self.engage_and_verify();
        if let Err(e) = engaged {
            self.abort_start(&session, &e);
            return Err(e);
        }
        self.session = Some(session.clone());
        self.begin_watching();
        self.notify(
            "Lidless is on",
            &format!(
                "Your computer stays awake with the lid closed until {}. Keep it on a ventilated surface, not in a bag.",
                session.ends_at.with_timezone(&chrono::Local).format("%H:%M")
            ),
        );
        Ok(session)
    }

    fn engage_and_verify(&mut self) -> Result<()> {
        let hold = self.env.engine.engage(&self.env.store, self.now())?;
        // Hard rule 3: read back after a settle delay.
        (self.env.sleep)(self.config.verify_settle_seconds);
        match self.env.engine.verify() {
            Ok(true) => {
                self.hold = Some(hold);
                log::info("session engaged and verified");
                Ok(())
            }
            Ok(false) => Err(LidlessError::VerificationFailed(format!(
                "The system turned closed-lid sleep back on within {} s, so closing the lid would still sleep this computer. Settings were restored.",
                self.config.verify_settle_seconds as i64
            ))),
            Err(e) => Err(LidlessError::VerificationFailed(format!(
                "Lidless could not read the closed-lid setting back after enabling it ({e}), so it cannot promise the computer will stay awake. Settings were restored."
            ))),
        }
    }

    fn abort_start(&mut self, session: &Session, error: &LidlessError) {
        log::error(&format!("session {} failed to start: {error}", session.id));
        self.hold = None;
        let store = self.env.store.clone();
        let id = session.id;
        let _ = store.with_lock(|| {
            if let SessionRead::Some(cur) = store.read_session() {
                if cur.id == id {
                    store.remove_session()?;
                }
            }
            Ok(())
        });
        let report = self.restore_all();
        let le = LastEnd {
            session_id: Some(session.id),
            reason: EndReason::StartFailed,
            at: self.now(),
            restore_complete: report.complete(),
            detail: Some(format!(
                "{error}{}",
                if report.complete() {
                    String::new()
                } else {
                    format!(" Restore incomplete: {}", report.failures.join("; "))
                }
            )),
        };
        let _ = self.env.store.write_last_end(&le);
        self.last_end = Some(le);
    }

    fn restore_all(&self) -> crate::engine::RestoreReport {
        let store = self.env.store.clone();
        let now = self.now();
        let engine = self.env.engine;
        store
            .with_lock(|| Ok(engine.restore_all_locked(&store, now)))
            .unwrap_or_else(|e| crate::engine::RestoreReport {
                restored: vec![],
                failures: vec![e.to_string()],
            })
    }

    fn begin_watching(&mut self) {
        self.tick_count = 0;
        self.unreadable_battery = 0;
        self.lid_closed = self.env.engine.lid_closed();
        self.lid_candidate = self.lid_closed;
        self.lid_candidate_ticks = 0;
        self.closed_lid_seconds = 0.0;
        self.lid_closed_since = if self.lid_closed == Some(true) {
            Some(self.now())
        } else {
            None
        };
        self.low_power_failure_notified = false;
        self.low_power_active = false;
    }

    /// One owner tick (call once per second). Returns a reason when the
    /// session must end. `external_end` lets `lidless run` end the session
    /// when its command exits.
    pub fn tick(&mut self, external_end: Option<EndReason>) -> Option<(EndReason, Option<String>)> {
        let mut s = self.session.clone()?;
        self.tick_count += 1;
        let now = self.now();

        // Pick up `extend` / `stop` written by other processes.
        match self.env.store.read_session() {
            SessionRead::None => {
                return Some((
                    EndReason::Stopped,
                    Some("The session file was removed.".into()),
                ))
            }
            SessionRead::Unreadable(why) => {
                return Some((
                    EndReason::Stopped,
                    Some(format!("The session file became unreadable: {why}")),
                ))
            }
            SessionRead::Some(fresh) => {
                if fresh.id != s.id {
                    return Some((
                        EndReason::OwnerLost,
                        Some("Another session replaced this one.".into()),
                    ));
                }
                if fresh != s {
                    s = fresh;
                    self.session = Some(s.clone());
                }
            }
        }
        if s.stop_requested.is_some() {
            return Some((EndReason::Stopped, None));
        }
        if s.is_expired(now) {
            return Some((EndReason::Expired, None));
        }
        if let Some(r) = external_end {
            return Some((r, None));
        }

        let mut run_floors = self.tick_count % FLOOR_EVERY_TICKS == 1;
        if self.update_lid() {
            run_floors = true;
            if self.lid_closed == Some(true) {
                self.lid_closed_since = Some(now);
                log::info("lid closed");
                if self.config.sleep_display_on_lid_close {
                    self.env.engine.display_off();
                }
            } else {
                if let Some(since) = self.lid_closed_since.take() {
                    self.closed_lid_seconds += (now - since).num_milliseconds() as f64 / 1000.0;
                }
                log::info("lid opened");
            }
        }
        if run_floors {
            if let Some(reason) = self.apply_floors() {
                return Some((reason, None));
            }
        }
        if self.tick_count.is_multiple_of(VERIFY_EVERY_TICKS) {
            if let Some(failure) = self.reverify() {
                return Some((EndReason::VerificationFailed, Some(failure)));
            }
        }
        None
    }

    fn update_lid(&mut self) -> bool {
        let raw = self.env.engine.lid_closed();
        if raw == self.lid_candidate {
            self.lid_candidate_ticks += 1;
        } else {
            self.lid_candidate = raw;
            self.lid_candidate_ticks = 1;
        }
        if self.lid_candidate != self.lid_closed && self.lid_candidate_ticks >= LID_DEBOUNCE_TICKS {
            self.lid_closed = self.lid_candidate;
            return true;
        }
        false
    }

    fn apply_floors(&mut self) -> Option<EndReason> {
        let battery = self.env.engine.battery();
        let on_battery = battery.has_battery && battery.on_battery;
        self.unreadable_battery = if on_battery && battery.percent.is_none() {
            self.unreadable_battery + 1
        } else {
            0
        };
        let d = floors::decide(
            on_battery,
            battery.percent,
            self.unreadable_battery,
            self.env.engine.thermal(),
            self.lid_closed == Some(true),
            &self.config,
        );
        if let Some(end) = d.end {
            return Some(end);
        }
        if d.want_low_power && !self.low_power_active {
            match self
                .env
                .engine
                .enable_low_power(&self.env.store, self.now())
            {
                Ok(owned) => {
                    self.low_power_active = owned;
                    if owned {
                        log::info("low-power mode on (floor or lid rule)");
                    }
                }
                Err(e) => {
                    log::error(&format!("could not enable low-power mode: {e}"));
                    if !self.low_power_failure_notified {
                        self.low_power_failure_notified = true;
                        self.notify("Low-power mode not enabled", &e.to_string());
                    }
                }
            }
        } else if !d.want_low_power && self.low_power_active {
            match self
                .env
                .engine
                .release_low_power(&self.env.store, self.now())
            {
                Ok(report) => {
                    self.low_power_active = !report.complete();
                    if report.complete() {
                        log::info("low-power mode released");
                    }
                }
                Err(e) => log::error(&format!("could not release low-power mode: {e}")),
            }
        }
        None
    }

    /// The setting has been seen reverting on some systems; check it during
    /// the session too, re-apply once, then give up.
    fn reverify(&mut self) -> Option<String> {
        match self.env.engine.verify() {
            Err(_) => None, // a single failed read is not proof of a revert
            Ok(true) => None,
            Ok(false) => {
                log::warn("closed-lid setting reverted during the session; re-applying once");
                match self.env.engine.engage(&self.env.store, self.now()) {
                    Ok(hold) => {
                        self.hold = Some(hold);
                        (self.env.sleep)(self.config.verify_settle_seconds);
                        match self.env.engine.verify() {
                            Ok(true) => None,
                            _ => Some("The system turned closed-lid sleep back on and kept it on after Lidless re-applied it.".into()),
                        }
                    }
                    Err(e) => Some(format!("The system turned closed-lid sleep back on and Lidless could not re-apply it: {e}")),
                }
            }
        }
    }

    /// Ends the session and restores everything. Safe to call when idle.
    pub fn end(&mut self, reason: EndReason, detail: Option<String>) -> LastEnd {
        let Some(s) = self.session.take() else {
            return self.last_end.clone().unwrap_or(LastEnd {
                session_id: None,
                reason,
                at: self.now(),
                restore_complete: true,
                detail: None,
            });
        };
        self.hold = None; // releases the OS hold
        let store = self.env.store.clone();
        let id = s.id;
        if let Err(e) = store.with_lock(|| {
            if let SessionRead::Some(cur) = store.read_session() {
                if cur.id == id {
                    store.remove_session()?;
                }
            }
            Ok(())
        }) {
            log::error(&format!("could not remove session file: {e}"));
        }
        let report = self.restore_all();
        let now = self.now();
        if let Some(since) = self.lid_closed_since.take() {
            self.closed_lid_seconds += (now - since).num_milliseconds() as f64 / 1000.0;
        }
        let failure_text = report.failures.join("; ");
        let mut detail_parts: Vec<String> = Vec::new();
        if let Some(d) = &detail {
            detail_parts.push(d.clone());
        }
        if !report.complete() {
            detail_parts.push(format!("Restore incomplete: {failure_text}"));
        }
        let le = LastEnd {
            session_id: Some(s.id),
            reason,
            at: now,
            restore_complete: report.complete(),
            detail: if detail_parts.is_empty() {
                None
            } else {
                Some(detail_parts.join(" "))
            },
        };
        let _ = self.env.store.write_last_end(&le);
        history::append(
            HistoryEntry {
                id: s.id,
                started_at: s.started_at,
                ended_at: now,
                reason,
                closed_lid_seconds: self.closed_lid_seconds,
                owner: s.owner.kind,
                command: s.command.clone(),
                restore_complete: report.complete(),
            },
            &self.env.store,
        );
        log::info(&format!(
            "session {} ended: {}; restore complete={}",
            s.id,
            reason.raw(),
            report.complete()
        ));
        self.low_power_active = false;
        self.lid_closed = None;
        self.last_end = Some(le.clone());
        if report.complete() {
            self.notify(
                "Lidless is off",
                &format!("{} Normal sleep is back.", reason.summary()),
            );
        } else {
            self.notify(
                "Lidless could not restore everything",
                &format!("{failure_text} The recovery job will keep retrying every minute."),
            );
        }
        le
    }

    /// Ticks once per second until the session ends, `stop` is set
    /// (SIGTERM/Ctrl-C → ownerTerminated), or `external` returns a reason.
    pub fn run_until_end(
        &mut self,
        stop: &AtomicBool,
        mut external: impl FnMut() -> Option<EndReason>,
    ) -> LastEnd {
        loop {
            if stop.load(Ordering::SeqCst) {
                return self.end(EndReason::OwnerTerminated, None);
            }
            if let Some((reason, detail)) = self.tick(external()) {
                return self.end(reason, detail);
            }
            (self.env.sleep)(1.0);
        }
    }
}
