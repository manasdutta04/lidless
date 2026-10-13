//! Lidless engine for Windows.
//!
//! How it keeps the machine awake with the lid closed:
//! 1. The lid-close action of the active power scheme is set to "Do nothing"
//!    (AC and battery), after journaling the original values. Written with
//!    the Power Management API; if that is refused for a standard user, the
//!    change is applied by a Task Scheduler task that setup registered to run
//!    with highest privileges (the one elevated path, like the sudoers rule
//!    on macOS).
//! 2. A power request (`PowerRequestSystemRequired`) is held for the life of
//!    the session so idle sleep does not kick in. It dies with the process.
//!
//! Open questions (CLAUDE.md §13) that only a real laptop can answer: whether
//! the direct write works without elevation, and whether Modern Standby
//! throttles background work with the lid closed. Every step here verifies
//! by reading back, so a failure is reported instead of assumed away.

#![cfg_attr(not(windows), allow(dead_code, unused_imports, unused_variables))]

mod lid;
mod power;
mod tasks;

use std::path::Path;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use lidless_core::engine::{AwakeHold, Elevation, Engine, ReadinessReport, RestoreReport};
use lidless_core::error::{LidlessError, Result};
use lidless_core::floors::{BatteryReading, ThermalLevel};
use lidless_core::log;
use lidless_core::model::LidActionEntry;
use lidless_core::store::Store;

/// Lid-close action values (Power Management API).
pub const LID_DO_NOTHING: u32 = 0;

pub struct WindowsEngine {
    lid: Mutex<Option<lid::LidWatcher>>,
}

impl Default for WindowsEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl WindowsEngine {
    pub fn new() -> Self {
        WindowsEngine {
            lid: Mutex::new(None),
        }
    }

    /// Handles the hidden commands the elevated scheduled tasks run:
    /// `_lidaction apply` (reads a request file, writes the lid action,
    /// writes a result file) and `_install-elevated <cli-path>`.
    /// Returns None when `args` is not one of them.
    pub fn handle_hidden_command(args: &[String]) -> Option<i32> {
        match args.first().map(String::as_str) {
            Some("_lidaction") => Some(power::apply_from_request_file()),
            Some("_install-elevated") => {
                let cli = args.get(1).map(Path::new)?;
                Some(match tasks::install_elevated(cli) {
                    Ok(()) => 0,
                    Err(e) => {
                        eprintln!("lidless: {e}");
                        1
                    }
                })
            }
            _ => None,
        }
    }

    /// Writes the lid action directly, or through the elevated task when the
    /// direct write is refused. Verifies by reading back.
    fn set_lid_action(&self, scheme: &str, ac: u32, dc: u32) -> Result<()> {
        match power::write_lid_action(scheme, ac, dc) {
            Ok(()) => {}
            Err(e) if power::is_access_denied(&e) => {
                log::info("direct lid-action write refused; using the elevated task");
                tasks::run_lid_action_task(scheme, ac, dc)?;
            }
            Err(e) => return Err(e),
        }
        let (got_ac, got_dc) = power::read_lid_action(scheme)?;
        if got_ac != ac || got_dc != dc {
            return Err(LidlessError::VerificationFailed(format!(
                "The lid-close action did not change (AC {got_ac}, battery {got_dc}). Windows may be managed by a policy that locks power settings."
            )));
        }
        Ok(())
    }
}

impl Engine for WindowsEngine {
    fn platform(&self) -> &'static str {
        "windows"
    }

    fn fix_hint(&self) -> String {
        "Open Lidless and click Set Up, or run `lidless setup` (Windows will ask for administrator approval once).".into()
    }

    fn engage(&self, store: &Store, now: DateTime<Utc>) -> Result<Box<dyn AwakeHold>> {
        let scheme = power::active_scheme()?;
        let (ac, dc) = power::read_lid_action(&scheme)?;
        let mut journal = store.read_journal()?;
        if journal.windows.lid_action.is_none() && (ac != LID_DO_NOTHING || dc != LID_DO_NOTHING) {
            // Hard rule 1: journal first.
            journal.windows.lid_action = Some(LidActionEntry {
                scheme: scheme.clone(),
                original_ac: ac,
                original_dc: dc,
                recorded_at: now,
            });
            store.write_journal(&journal, now)?;
            log::info(&format!(
                "journaled lidAction(original AC={ac} DC={dc}); setting Do nothing"
            ));
            self.set_lid_action(&scheme, LID_DO_NOTHING, LID_DO_NOTHING)?;
        } else if journal.windows.lid_action.is_none() {
            log::warn("lid-close action was already Do nothing before this session; leaving ownership with whoever set it");
        }
        let hold =
            power::PowerRequest::new("Lidless keeps this computer awake with the lid closed")?;
        Ok(Box::new(hold))
    }

    fn verify(&self) -> Result<bool> {
        let scheme = power::active_scheme()?;
        let (ac, dc) = power::read_lid_action(&scheme)?;
        Ok(ac == LID_DO_NOTHING && dc == LID_DO_NOTHING)
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
        if let Some(entry) = journal.windows.lid_action.clone() {
            let current = power::read_lid_action(&entry.scheme).ok();
            if current == Some((entry.original_ac, entry.original_dc)) {
                journal.windows.lid_action = None;
                let _ = store.write_journal(&journal, now);
                report.restored.push("lidAction (already original)".into());
            } else {
                match self.set_lid_action(&entry.scheme, entry.original_ac, entry.original_dc) {
                    Ok(()) => {
                        journal.windows.lid_action = None;
                        let _ = store.write_journal(&journal, now);
                        report.restored.push(format!(
                            "lidAction → AC {} DC {}",
                            entry.original_ac, entry.original_dc
                        ));
                        log::info("restored lid-close action");
                    }
                    Err(e) => {
                        let msg = format!("Could not restore the lid-close action: {e}");
                        log::error(&msg);
                        report.failures.push(msg);
                    }
                }
            }
        }
        report
    }

    fn enable_low_power(&self, _store: &Store, _now: DateTime<Utc>) -> Result<bool> {
        // Windows' Battery saver cannot be toggled by a standard user without
        // changing the saver threshold policy; Lidless leaves it alone.
        Ok(false)
    }

    fn release_low_power(&self, _store: &Store, _now: DateTime<Utc>) -> Result<RestoreReport> {
        Ok(RestoreReport::default())
    }

    fn display_off(&self) {
        power::display_off();
    }

    fn battery(&self) -> BatteryReading {
        power::battery()
    }

    fn thermal(&self) -> ThermalLevel {
        // Windows has no public, unprivileged thermal-state API; the battery
        // floor and the user's judgement cover heat here.
        ThermalLevel::Nominal
    }

    fn lid_closed(&self) -> Option<bool> {
        let mut guard = self.lid.lock().unwrap();
        if guard.is_none() {
            *guard = lid::LidWatcher::start();
        }
        guard.as_ref().and_then(|w| w.closed())
    }

    fn readiness(&self) -> ReadinessReport {
        let (armed, detail) = tasks::recovery_status();
        ReadinessReport {
            privilege: power::can_write_lid_action() || tasks::lid_action_task_exists(),
            recovery_armed: armed,
            recovery_detail: detail,
        }
    }

    fn install(&self, cli_path: &Path, _elevation: Elevation) -> Result<Vec<String>> {
        tasks::install_via_uac(cli_path)
    }

    fn uninstall(&self, _elevation: Elevation) -> Result<Vec<String>> {
        tasks::uninstall()
    }

    fn privileged_operations(&self) -> Vec<String> {
        vec![
            "Task Scheduler task Lidless\\LidAction (highest privileges): sets the active power scheme's lid-close action to the value in a request file Lidless writes, and nothing else".into(),
            "Task Scheduler tasks Lidless\\Recovery (every minute) and Lidless\\RecoveryLogon: run `lidless recover` as you".into(),
        ]
    }
}
