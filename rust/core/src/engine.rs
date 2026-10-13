//! The per-OS engine: everything that touches the system. The core only ever
//! calls these; tests use `FakeEngine`.
//!
//! Contract (Hard rules): an engine journals before every change, verifies
//! after engaging, restores only what the journal says it changed, and
//! reports failures instead of claiming success.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{LidlessError, Result};
use crate::floors::{BatteryReading, ThermalLevel};
use crate::store::Store;

/// Something that keeps the machine awake only while it is alive (a Windows
/// power request, a logind inhibitor file descriptor, a macOS IOPM
/// assertion). Dropping it releases it; a crash releases it too.
pub trait AwakeHold: Send {}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestoreReport {
    pub restored: Vec<String>,
    pub failures: Vec<String>,
}

impl RestoreReport {
    pub fn complete(&self) -> bool {
        self.failures.is_empty()
    }
    pub fn merge(&mut self, other: RestoreReport) {
        self.restored.extend(other.restored);
        self.failures.extend(other.failures);
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadinessReport {
    pub privilege: bool,
    pub recovery_armed: bool,
    pub recovery_detail: String,
}

impl ReadinessReport {
    pub fn ready(&self) -> bool {
        self.privilege && self.recovery_armed
    }

    /// The error to show when a session must not start (Hard rule 2).
    pub fn not_ready_error(&self, fix_hint: &str) -> Option<LidlessError> {
        let mut problems = Vec::new();
        if !self.privilege {
            problems.push(
                "the permission to change the lid-close setting is not installed".to_string(),
            );
        }
        if !self.recovery_armed {
            problems.push(format!(
                "the recovery job is not armed ({})",
                self.recovery_detail
            ));
        }
        if problems.is_empty() {
            None
        } else {
            Some(LidlessError::NotReady(format!(
                "Lidless will not start because {}. {fix_hint}",
                problems.join(" and ")
            )))
        }
    }
}

/// How the one privileged step of setup is run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Elevation {
    /// The OS's own administrator prompt (UAC / polkit / password dialog).
    Prompt,
    /// `sudo` in the current terminal (Linux CLI).
    TerminalSudo,
}

pub trait Engine: Send + Sync {
    /// "windows", "linux", "macos".
    fn platform(&self) -> &'static str;

    /// One-line instruction for fixing a not-ready state.
    fn fix_hint(&self) -> String;

    /// Journals, then makes the system changes that keep the machine awake
    /// with the lid closed, and returns a hold that must live as long as the
    /// session. Must NOT verify; the owner verifies after a settle delay.
    fn engage(&self, store: &Store, now: DateTime<Utc>) -> Result<Box<dyn AwakeHold>>;

    /// Reads the closed-lid setting back: `Ok(true)` means engaged.
    fn verify(&self) -> Result<bool>;

    /// Undoes every journal entry it can. Caller holds the state lock.
    fn restore_all_locked(&self, store: &Store, now: DateTime<Utc>) -> RestoreReport;

    /// Turns the OS low-power mode on (journaled). Returns whether Lidless
    /// now owns it (false if it was already on, or unsupported).
    fn enable_low_power(&self, store: &Store, now: DateTime<Utc>) -> Result<bool>;

    /// Restores low-power mode only if Lidless turned it on.
    fn release_low_power(&self, store: &Store, now: DateTime<Utc>) -> Result<RestoreReport>;

    /// Turns the display off (unprivileged, nothing to restore).
    fn display_off(&self);

    fn battery(&self) -> BatteryReading;
    fn thermal(&self) -> ThermalLevel;
    /// None when the machine has no lid or the state cannot be read.
    fn lid_closed(&self) -> Option<bool>;

    fn readiness(&self) -> ReadinessReport;

    /// Installs the recovery job and the privilege needed to change the
    /// lid-close setting. Returns the steps performed.
    fn install(&self, cli_path: &std::path::Path, elevation: Elevation) -> Result<Vec<String>>;

    /// Removes what `install` added. Settings must already be restored.
    fn uninstall(&self, elevation: Elevation) -> Result<Vec<String>>;

    /// What runs with elevated rights, for the README and `doctor`.
    fn privileged_operations(&self) -> Vec<String>;
}

/// A hold that does nothing (for engines whose engage is purely a setting).
pub struct NoHold;
impl AwakeHold for NoHold {}
