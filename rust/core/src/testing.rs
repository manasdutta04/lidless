//! Fakes for tests and for the tray app's preview mode. Nothing here touches
//! the real system (Hard rule 8).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, TimeZone, Utc};

use crate::engine::{AwakeHold, Elevation, Engine, ReadinessReport, RestoreReport};
use crate::error::{LidlessError, Result};
use crate::floors::{BatteryReading, ThermalLevel};
use crate::model::{BoolEntry, OwnerIdentity};
use crate::notify::Notifier;
use crate::paths::Paths;
use crate::process::ProcessInspector;
use crate::store::Store;

/// A fake OS: "sleep disabled" and "low power" flags, journaled through the
/// macOS section of the shared journal (the behaviour under test is the
/// core's, not any one platform's).
#[derive(Default)]
pub struct FakeEngine {
    pub sleep_disabled: AtomicBool,
    pub low_power: AtomicBool,
    pub fail_engage: AtomicBool,
    pub fail_restore: AtomicBool,
    pub revert_after_engage: AtomicBool,
    pub privilege: AtomicBool,
    pub armed: AtomicBool,
    pub battery: Mutex<BatteryReading>,
    pub thermal: Mutex<ThermalLevel>,
    pub lid: Mutex<Option<bool>>,
    pub calls: Mutex<Vec<String>>,
    pub holds_alive: Arc<AtomicBool>,
}

impl FakeEngine {
    pub fn new() -> Self {
        let e = FakeEngine::default();
        e.privilege.store(true, Ordering::SeqCst);
        e.armed.store(true, Ordering::SeqCst);
        *e.battery.lock().unwrap() = BatteryReading {
            has_battery: true,
            on_battery: false,
            percent: Some(90),
        };
        *e.thermal.lock().unwrap() = ThermalLevel::Nominal;
        *e.lid.lock().unwrap() = Some(false);
        e
    }

    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    fn record(&self, s: &str) {
        self.calls.lock().unwrap().push(s.to_string());
    }

    pub fn set_battery(&self, on_battery: bool, percent: Option<i64>) {
        *self.battery.lock().unwrap() = BatteryReading {
            has_battery: true,
            on_battery,
            percent,
        };
    }

    pub fn set_thermal(&self, t: ThermalLevel) {
        *self.thermal.lock().unwrap() = t;
    }

    pub fn set_lid(&self, closed: bool) {
        *self.lid.lock().unwrap() = Some(closed);
    }
}

struct FakeHold(Arc<AtomicBool>);
impl AwakeHold for FakeHold {}
impl Drop for FakeHold {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

impl Engine for FakeEngine {
    fn platform(&self) -> &'static str {
        "fake"
    }

    fn fix_hint(&self) -> String {
        "Run `lidless setup`.".into()
    }

    fn engage(&self, store: &Store, now: DateTime<Utc>) -> Result<Box<dyn AwakeHold>> {
        self.record("engage");
        if self.sleep_disabled.load(Ordering::SeqCst) {
            // Already disabled by someone else: not ours to restore.
            self.holds_alive.store(true, Ordering::SeqCst);
            return Ok(Box::new(FakeHold(self.holds_alive.clone())));
        }
        let mut journal = store.read_journal()?;
        if journal.macos.sleep_disabled.is_none() {
            journal.macos.sleep_disabled = Some(BoolEntry {
                original: false,
                recorded_at: now,
            });
        }
        store.write_journal(&journal, now)?;
        self.record("journaled sleep");
        if self.fail_engage.load(Ordering::SeqCst) {
            return Err(LidlessError::NotReady(
                "fake: sudo would ask for a password".into(),
            ));
        }
        self.record("disablesleep 1");
        self.sleep_disabled.store(
            !self.revert_after_engage.load(Ordering::SeqCst),
            Ordering::SeqCst,
        );
        self.holds_alive.store(true, Ordering::SeqCst);
        Ok(Box::new(FakeHold(self.holds_alive.clone())))
    }

    fn verify(&self) -> Result<bool> {
        self.record("verify");
        Ok(self.sleep_disabled.load(Ordering::SeqCst))
    }

    fn restore_all_locked(&self, store: &Store, now: DateTime<Utc>) -> RestoreReport {
        let mut report = RestoreReport::default();
        let mut journal = match store.read_journal() {
            Ok(j) => j,
            Err(e) => {
                report.failures.push(e.to_string());
                return report;
            }
        };
        if let Some(entry) = journal.macos.low_power_mode.clone() {
            self.record(&format!("lowpowermode {}", entry.original as u8));
            self.low_power.store(entry.original, Ordering::SeqCst);
            journal.macos.low_power_mode = None;
            let _ = store.write_journal(&journal, now);
            report.restored.push("lowPowerMode".into());
        }
        if let Some(entry) = journal.macos.sleep_disabled.clone() {
            if self.sleep_disabled.load(Ordering::SeqCst) == entry.original {
                journal.macos.sleep_disabled = None;
                let _ = store.write_journal(&journal, now);
                report.restored.push("sleepDisabled (already)".into());
            } else if self.fail_restore.load(Ordering::SeqCst) {
                report.failures.push("fake: disablesleep 0 failed".into());
            } else {
                self.record(&format!("disablesleep {}", entry.original as u8));
                self.sleep_disabled.store(entry.original, Ordering::SeqCst);
                journal.macos.sleep_disabled = None;
                let _ = store.write_journal(&journal, now);
                report.restored.push("sleepDisabled".into());
            }
        }
        report
    }

    fn enable_low_power(&self, store: &Store, now: DateTime<Utc>) -> Result<bool> {
        let mut journal = store.read_journal()?;
        if journal.macos.low_power_mode.is_some() {
            return Ok(true);
        }
        if self.low_power.load(Ordering::SeqCst) {
            return Ok(false);
        }
        journal.macos.low_power_mode = Some(BoolEntry {
            original: false,
            recorded_at: now,
        });
        store.write_journal(&journal, now)?;
        self.record("journaled lowpower");
        self.record("lowpowermode 1");
        self.low_power.store(true, Ordering::SeqCst);
        Ok(true)
    }

    fn release_low_power(&self, store: &Store, now: DateTime<Utc>) -> Result<RestoreReport> {
        let mut report = RestoreReport::default();
        let mut journal = store.read_journal()?;
        if let Some(entry) = journal.macos.low_power_mode.clone() {
            self.record(&format!("lowpowermode {}", entry.original as u8));
            self.low_power.store(entry.original, Ordering::SeqCst);
            journal.macos.low_power_mode = None;
            store.write_journal(&journal, now)?;
            report.restored.push("lowPowerMode".into());
        }
        Ok(report)
    }

    fn display_off(&self) {
        self.record("displayoff");
    }

    fn battery(&self) -> BatteryReading {
        *self.battery.lock().unwrap()
    }

    fn thermal(&self) -> ThermalLevel {
        *self.thermal.lock().unwrap()
    }

    fn lid_closed(&self) -> Option<bool> {
        *self.lid.lock().unwrap()
    }

    fn readiness(&self) -> ReadinessReport {
        let armed = self.armed.load(Ordering::SeqCst);
        ReadinessReport {
            privilege: self.privilege.load(Ordering::SeqCst),
            recovery_armed: armed,
            recovery_detail: if armed {
                "fake armed".into()
            } else {
                "fake not armed".into()
            },
        }
    }

    fn install(&self, _cli_path: &std::path::Path, _elevation: Elevation) -> Result<Vec<String>> {
        self.privilege.store(true, Ordering::SeqCst);
        self.armed.store(true, Ordering::SeqCst);
        Ok(vec!["fake installed".into()])
    }

    fn uninstall(&self, _elevation: Elevation) -> Result<Vec<String>> {
        self.privilege.store(false, Ordering::SeqCst);
        self.armed.store(false, Ordering::SeqCst);
        Ok(vec!["fake removed".into()])
    }

    fn privileged_operations(&self) -> Vec<String> {
        vec!["fake".into()]
    }
}

/// Process inspector with a fixed boot id and a controllable set of live pids.
pub struct FakeInspector {
    pub alive: Mutex<Vec<u32>>,
    pub boot: Mutex<String>,
}

impl FakeInspector {
    pub fn new() -> Self {
        FakeInspector {
            alive: Mutex::new(vec![std::process::id()]),
            boot: Mutex::new("boot-A".into()),
        }
    }
}

impl Default for FakeInspector {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessInspector for FakeInspector {
    fn start_time(&self, pid: u32) -> Option<i64> {
        if self.alive.lock().unwrap().contains(&pid) {
            Some(42)
        } else {
            None
        }
    }
    fn boot_session(&self) -> String {
        self.boot.lock().unwrap().clone()
    }
}

#[derive(Default)]
pub struct FakeNotifier {
    pub sent: Mutex<Vec<String>>,
}

impl Notifier for FakeNotifier {
    fn notify(&self, title: &str, _body: &str) {
        self.sent.lock().unwrap().push(title.to_string());
    }
}

/// Controllable clock.
pub struct FakeClock {
    now: Mutex<DateTime<Utc>>,
}

impl FakeClock {
    pub fn new() -> Arc<Self> {
        Arc::new(FakeClock {
            now: Mutex::new(Utc.timestamp_opt(1_800_000_000, 0).unwrap()),
        })
    }
    pub fn now(&self) -> DateTime<Utc> {
        *self.now.lock().unwrap()
    }
    pub fn advance(&self, seconds: i64) {
        *self.now.lock().unwrap() += chrono::Duration::seconds(seconds);
    }
}

/// Temporary state directory with a verify delay of 0.
pub struct TempHome {
    pub dir: tempfile::TempDir,
    pub store: Store,
}

impl TempHome {
    pub fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(Paths::new(dir.path()));
        let cfg = crate::model::Config {
            verify_settle_seconds: 0.0,
            ..Default::default()
        };
        store.write_config(&cfg).unwrap();
        TempHome { dir, store }
    }
}

impl Default for TempHome {
    fn default() -> Self {
        Self::new()
    }
}

pub fn dead_owner(kind: crate::model::OwnerKind) -> OwnerIdentity {
    OwnerIdentity {
        kind,
        pid: 99_999,
        start_time: 42,
        boot_session: "boot-A".into(),
    }
}
