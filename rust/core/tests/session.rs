//! Session lifecycle and crash recovery against the fake engine.

use std::sync::atomic::Ordering;
use std::sync::Arc;

use chrono::Duration;
use lidless_core::control;
use lidless_core::engine::Engine;
use lidless_core::error::LidlessError;
use lidless_core::floors::ThermalLevel;
use lidless_core::model::{BoolEntry, EndReason, Journal, OwnerKind, Session};
use lidless_core::owner::{OwnerEnv, SessionOwner, VERIFY_EVERY_TICKS};
use lidless_core::recovery::{self, RecoveryAction};
use lidless_core::store::SessionRead;
use lidless_core::testing::*;

struct H {
    home: TempHome,
    engine: FakeEngine,
    inspector: FakeInspector,
    notifier: FakeNotifier,
    clock: Arc<FakeClock>,
}

impl H {
    fn new() -> Self {
        H {
            home: TempHome::new(),
            engine: FakeEngine::new(),
            inspector: FakeInspector::new(),
            notifier: FakeNotifier::default(),
            clock: FakeClock::new(),
        }
    }

    fn owner(&self) -> SessionOwner<'_> {
        let clock = self.clock.clone();
        SessionOwner::new(OwnerEnv {
            engine: &self.engine,
            store: self.home.store.clone(),
            inspector: &self.inspector,
            notifier: &self.notifier,
            now: Arc::new(move || clock.now()),
            sleep: Arc::new(|_| {}),
        })
    }

    fn journal(&self) -> Journal {
        self.home.store.read_journal().unwrap()
    }
}

#[test]
fn start_engages_verifies_and_end_restores() {
    let h = H::new();
    let mut o = h.owner();
    let s = o.start(3600.0, OwnerKind::App, None).unwrap();
    assert!(h.engine.sleep_disabled.load(Ordering::SeqCst));
    assert!(h.engine.holds_alive.load(Ordering::SeqCst));
    assert!(!h.journal().macos.sleep_disabled.as_ref().unwrap().original);
    assert!(
        matches!(h.home.store.read_session(), SessionRead::Some(on_disk) if on_disk.id == s.id)
    );
    // Journal was written before the change.
    let calls = h.engine.calls();
    assert!(
        calls.iter().position(|c| c == "journaled sleep")
            < calls.iter().position(|c| c == "disablesleep 1")
    );

    let le = o.end(EndReason::Stopped, None);
    assert!(le.restore_complete);
    assert!(!h.engine.sleep_disabled.load(Ordering::SeqCst));
    assert!(!h.engine.holds_alive.load(Ordering::SeqCst));
    assert!(h.journal().is_empty());
    assert_eq!(h.home.store.read_session(), SessionRead::None);
    assert_eq!(
        h.home.store.read_last_end().unwrap().reason,
        EndReason::Stopped
    );
    assert_eq!(lidless_core::history::read(&h.home.store).len(), 1);
}

#[test]
fn refuses_when_recovery_not_armed() {
    let h = H::new();
    h.engine.armed.store(false, Ordering::SeqCst);
    let mut o = h.owner();
    let e = o.start(600.0, OwnerKind::App, None).unwrap_err();
    assert_eq!(e.exit_code(), 3);
    assert!(!h.engine.calls().contains(&"disablesleep 1".to_string()));
    assert_eq!(h.home.store.read_session(), SessionRead::None);
}

#[test]
fn reverted_setting_fails_start_and_restores() {
    let h = H::new();
    h.engine.revert_after_engage.store(true, Ordering::SeqCst);
    let mut o = h.owner();
    let e = o.start(600.0, OwnerKind::App, None).unwrap_err();
    assert_eq!(e.exit_code(), 4);
    assert_eq!(h.home.store.read_session(), SessionRead::None);
    assert!(h.journal().is_empty());
    assert_eq!(
        h.home.store.read_last_end().unwrap().reason,
        EndReason::StartFailed
    );
    assert!(!h.engine.holds_alive.load(Ordering::SeqCst));
}

#[test]
fn failed_engage_leaves_no_journal_behind() {
    let h = H::new();
    h.engine.fail_engage.store(true, Ordering::SeqCst);
    let mut o = h.owner();
    assert!(o.start(600.0, OwnerKind::App, None).is_err());
    assert!(h.journal().is_empty());
    assert!(!h.engine.calls().contains(&"disablesleep 0".to_string()));
}

#[test]
fn already_disabled_by_someone_else_is_not_restored() {
    let h = H::new();
    h.engine.sleep_disabled.store(true, Ordering::SeqCst);
    let mut o = h.owner();
    o.start(600.0, OwnerKind::App, None).unwrap();
    assert!(h.journal().macos.sleep_disabled.is_none());
    o.end(EndReason::Stopped, None);
    assert!(
        h.engine.sleep_disabled.load(Ordering::SeqCst),
        "must not restore a value we did not change"
    );
}

#[test]
fn expiry_and_external_stop_and_extend() {
    let h = H::new();
    let mut o = h.owner();
    let s = o.start(60.0, OwnerKind::App, None).unwrap();
    assert!(o.tick(None).is_none());

    let (extended, clamped) = control::extend(&h.home.store, 3600.0, h.clock.now()).unwrap();
    assert!(!clamped);
    h.clock.advance(120);
    assert!(o.tick(None).is_none());
    assert_eq!(o.session().unwrap().ends_at, extended.ends_at);

    assert_eq!(
        control::request_stop(&h.home.store, &h.inspector, "user").unwrap(),
        control::StopRequest::Requested(s.id)
    );
    assert_eq!(o.tick(None).unwrap().0, EndReason::Stopped);
    o.end(EndReason::Stopped, None);

    let mut o2 = h.owner();
    o2.start(60.0, OwnerKind::Cli, None).unwrap();
    h.clock.advance(61);
    assert_eq!(o2.tick(None).unwrap().0, EndReason::Expired);
}

#[test]
fn extend_is_capped() {
    let h = H::new();
    let mut o = h.owner();
    o.start(29.0 * 86_400.0, OwnerKind::App, None).unwrap();
    let (s, clamped) = control::extend(&h.home.store, 5.0 * 86_400.0, h.clock.now()).unwrap();
    assert!(clamped);
    assert_eq!(s.ends_at, h.clock.now() + Duration::days(30));
}

#[test]
fn second_session_refused_while_first_live() {
    let h = H::new();
    let mut first = h.owner();
    first.start(600.0, OwnerKind::App, None).unwrap();
    let mut second = h.owner();
    assert_eq!(
        second.start(600.0, OwnerKind::Cli, None).unwrap_err(),
        LidlessError::SessionActive
    );
    assert!(h.engine.sleep_disabled.load(Ordering::SeqCst));
}

#[test]
fn battery_floor_ends_session() {
    let h = H::new();
    let mut o = h.owner();
    o.start(600.0, OwnerKind::App, None).unwrap();
    h.engine.set_battery(true, Some(5));
    assert_eq!(o.tick(None).unwrap().0, EndReason::BatteryFloor);
}

#[test]
fn lid_close_turns_display_off_and_low_power_on_battery() {
    let h = H::new();
    h.engine.set_battery(true, Some(80));
    let mut o = h.owner();
    o.start(3600.0, OwnerKind::App, None).unwrap();
    o.tick(None);
    assert!(!h.engine.low_power.load(Ordering::SeqCst));
    h.engine.set_lid(true);
    o.tick(None);
    o.tick(None);
    assert_eq!(o.lid_closed, Some(true));
    assert!(h.engine.calls().contains(&"displayoff".to_string()));
    assert!(h.engine.low_power.load(Ordering::SeqCst));
    h.clock.advance(600);
    h.engine.set_lid(false);
    o.tick(None);
    o.tick(None);
    assert!(!h.engine.low_power.load(Ordering::SeqCst));
    o.end(EndReason::Stopped, None);
    let hist = lidless_core::history::read(&h.home.store);
    assert_eq!(hist[0].closed_lid_seconds, 600.0);
}

#[test]
fn refuses_to_start_when_critical() {
    let h = H::new();
    h.engine.set_thermal(ThermalLevel::Critical);
    let mut o = h.owner();
    assert!(o.start(600.0, OwnerKind::App, None).is_err());
    assert!(!h.engine.calls().contains(&"disablesleep 1".to_string()));
}

#[test]
fn mid_session_revert_reapplied_once() {
    let h = H::new();
    let mut o = h.owner();
    o.start(7200.0, OwnerKind::App, None).unwrap();
    h.engine.sleep_disabled.store(false, Ordering::SeqCst);
    let mut result = None;
    for _ in 0..VERIFY_EVERY_TICKS {
        result = o.tick(None);
    }
    assert!(result.is_none());
    assert!(h.engine.sleep_disabled.load(Ordering::SeqCst));
    h.engine.sleep_disabled.store(false, Ordering::SeqCst);
    h.engine.revert_after_engage.store(true, Ordering::SeqCst);
    for _ in 0..VERIFY_EVERY_TICKS {
        result = o.tick(None);
    }
    assert_eq!(result.unwrap().0, EndReason::VerificationFailed);
}

#[test]
fn failed_restore_keeps_journal_entry() {
    let h = H::new();
    let mut o = h.owner();
    o.start(600.0, OwnerKind::App, None).unwrap();
    h.engine.fail_restore.store(true, Ordering::SeqCst);
    let le = o.end(EndReason::Stopped, None);
    assert!(!le.restore_complete);
    assert!(h.journal().macos.sleep_disabled.is_some());
    assert_eq!(h.home.store.read_session(), SessionRead::None);
}

// Crash recovery

fn simulate_crash(h: &H, ends_in: i64, boot: &str) -> Session {
    h.engine.sleep_disabled.store(true, Ordering::SeqCst);
    let mut j = Journal::default();
    j.macos.sleep_disabled = Some(BoolEntry {
        original: false,
        recorded_at: h.clock.now(),
    });
    h.home.store.write_journal(&j, h.clock.now()).unwrap();
    let mut owner = dead_owner(OwnerKind::App);
    owner.boot_session = boot.into();
    let s = Session::new(
        h.clock.now(),
        h.clock.now() + Duration::seconds(ends_in),
        owner,
        None,
    );
    h.home.store.write_session(&s).unwrap();
    s
}

fn recover(h: &H, force: Option<EndReason>) -> recovery::RecoveryOutcome {
    recovery::run(&h.engine, &h.home.store, &h.inspector, h.clock.now(), force)
}

#[test]
fn crashed_expired_session_is_restored() {
    let h = H::new();
    let s = simulate_crash(&h, -5, "boot-A");
    let out = recover(&h, None);
    assert_eq!(out.action, RecoveryAction::EndSession(EndReason::Expired));
    assert!(out.report.complete());
    assert!(!h.engine.sleep_disabled.load(Ordering::SeqCst));
    assert!(h.journal().is_empty());
    assert_eq!(h.home.store.read_last_end().unwrap().session_id, Some(s.id));
    assert_eq!(lidless_core::history::read(&h.home.store).len(), 1);
}

#[test]
fn crashed_live_session_keeps_awake_until_expiry() {
    let h = H::new();
    simulate_crash(&h, 600, "boot-A");
    assert_eq!(recover(&h, None).action, RecoveryAction::KeepOrphan);
    assert!(h.engine.sleep_disabled.load(Ordering::SeqCst));
    h.clock.advance(601);
    assert_eq!(
        recover(&h, None).action,
        RecoveryAction::EndSession(EndReason::Expired)
    );
    assert!(!h.engine.sleep_disabled.load(Ordering::SeqCst));
}

#[test]
fn stop_forces_orphan_end_and_reboot_restores() {
    let h = H::new();
    simulate_crash(&h, 600, "boot-A");
    assert_eq!(
        recover(&h, Some(EndReason::Stopped)).action,
        RecoveryAction::EndSession(EndReason::Stopped)
    );
    assert!(!h.engine.sleep_disabled.load(Ordering::SeqCst));

    simulate_crash(&h, 600, "boot-OLD");
    assert_eq!(
        recover(&h, None).action,
        RecoveryAction::EndSession(EndReason::Rebooted)
    );
}

#[test]
fn orphan_battery_floor_enforced() {
    let h = H::new();
    simulate_crash(&h, 600, "boot-A");
    h.engine.set_battery(true, Some(4));
    assert_eq!(
        recover(&h, None).action,
        RecoveryAction::EndSession(EndReason::BatteryFloor)
    );
}

#[test]
fn unreadable_session_moved_aside_and_bad_journal_never_treated_clean() {
    let h = H::new();
    simulate_crash(&h, 600, "boot-A");
    std::fs::write(h.home.store.paths.session(), b"{not json").unwrap();
    let out = recover(&h, None);
    assert_eq!(out.action, RecoveryAction::QuarantineAndRestore);
    assert!(!h.engine.sleep_disabled.load(Ordering::SeqCst));
    let names: Vec<String> = std::fs::read_dir(&h.home.store.paths.home)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    assert!(names
        .iter()
        .any(|n| n.starts_with("session.json.unreadable-")));

    h.engine.sleep_disabled.store(true, Ordering::SeqCst);
    std::fs::write(h.home.store.paths.journal(), b"garbage").unwrap();
    assert_eq!(recover(&h, None).action, RecoveryAction::Nothing);
    assert!(h.engine.sleep_disabled.load(Ordering::SeqCst));
}

#[test]
fn failed_restore_retried_next_run() {
    let h = H::new();
    simulate_crash(&h, -1, "boot-A");
    h.engine.fail_restore.store(true, Ordering::SeqCst);
    assert!(!recover(&h, None).report.complete());
    assert!(!h.journal().is_empty());
    h.engine.fail_restore.store(false, Ordering::SeqCst);
    let second = recover(&h, None);
    assert_eq!(second.action, RecoveryAction::RestoreJournal);
    assert!(second.report.complete());
}

#[test]
fn stats_and_hourly() {
    use lidless_core::history::{compute, hour_of_day};
    use lidless_core::model::HistoryEntry;
    let t0 = FakeClock::new().now();
    let e = |start: i64, len: i64, clean: bool, reason: EndReason| HistoryEntry {
        id: uuid::Uuid::new_v4(),
        started_at: t0 + Duration::seconds(start),
        ended_at: t0 + Duration::seconds(start + len),
        reason,
        closed_lid_seconds: 0.0,
        owner: OwnerKind::App,
        command: None,
        restore_complete: clean,
    };
    let entries = vec![
        e(0, 3600, true, EndReason::Expired),
        e(7200, 600, false, EndReason::BatteryFloor),
        e(9000, 1200, true, EndReason::Stopped),
    ];
    let s = compute(&entries, t0 + Duration::seconds(10_000));
    assert_eq!(s.sessions, 3);
    assert_eq!(s.total_awake_seconds, 5400.0);
    assert_eq!(s.longest_seconds, 3600.0);
    assert_eq!(s.clean_restore_percent, Some(67));
    assert_eq!(s.ended_by_safety, 1);
    assert!((hour_of_day(&entries).iter().sum::<f64>() - 5400.0).abs() < 0.001);
    assert!(lidless_core::update::is_newer("0.10.0", "0.9.3"));
    assert!(!lidless_core::update::is_newer("0.1.0", "0.1.0"));
    let _ = h_unused();
}

fn h_unused() -> usize {
    let e: &dyn Engine = &FakeEngine::new();
    e.privileged_operations().len()
}
