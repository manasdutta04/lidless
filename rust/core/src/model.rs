//! Session, journal, config and history models (spec/session.md, spec/journal.md).
//! JSON shapes match the macOS implementation exactly, so a state directory
//! is readable by both.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OwnerKind {
    App,
    Cli,
    Run,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnerIdentity {
    pub kind: OwnerKind,
    pub pid: u32,
    /// Process start time, microseconds since the Unix epoch.
    pub start_time: i64,
    pub boot_session: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Extension {
    pub at: DateTime<Utc>,
    pub seconds: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub version: u32,
    pub id: Uuid,
    pub started_at: DateTime<Utc>,
    pub ends_at: DateTime<Utc>,
    pub extensions: Vec<Extension>,
    pub owner: OwnerIdentity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_requested: Option<String>,
}

impl Session {
    pub fn new(
        started_at: DateTime<Utc>,
        ends_at: DateTime<Utc>,
        owner: OwnerIdentity,
        command: Option<Vec<String>>,
    ) -> Self {
        Session {
            version: 1,
            id: Uuid::new_v4(),
            started_at,
            ends_at,
            extensions: Vec::new(),
            owner,
            command,
            stop_requested: None,
        }
    }

    pub fn remaining(&self, now: DateTime<Utc>) -> f64 {
        (self.ends_at - now).num_milliseconds().max(0) as f64 / 1000.0
    }

    pub fn is_expired(&self, now: DateTime<Utc>) -> bool {
        now >= self.ends_at
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EndReason {
    Expired,
    Stopped,
    Quit,
    CommandExited,
    BatteryFloor,
    ThermalFloor,
    BatteryUnreadable,
    VerificationFailed,
    OwnerTerminated,
    Rebooted,
    OwnerLost,
    StartFailed,
}

impl EndReason {
    pub fn raw(&self) -> &'static str {
        match self {
            EndReason::Expired => "expired",
            EndReason::Stopped => "stopped",
            EndReason::Quit => "quit",
            EndReason::CommandExited => "commandExited",
            EndReason::BatteryFloor => "batteryFloor",
            EndReason::ThermalFloor => "thermalFloor",
            EndReason::BatteryUnreadable => "batteryUnreadable",
            EndReason::VerificationFailed => "verificationFailed",
            EndReason::OwnerTerminated => "ownerTerminated",
            EndReason::Rebooted => "rebooted",
            EndReason::OwnerLost => "ownerLost",
            EndReason::StartFailed => "startFailed",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        serde_json::from_value(serde_json::Value::String(raw.to_string())).ok()
    }

    pub fn summary(&self) -> &'static str {
        match self {
            EndReason::Expired => "Time ran out.",
            EndReason::Stopped => "Stopped.",
            EndReason::Quit => "Lidless quit.",
            EndReason::CommandExited => "The wrapped command finished.",
            EndReason::BatteryFloor => "Battery fell below the safety floor.",
            EndReason::ThermalFloor => "The computer got too hot (critical thermal state).",
            EndReason::BatteryUnreadable => "The battery level could not be read twice in a row.",
            EndReason::VerificationFailed => "The system turned closed-lid sleep back on.",
            EndReason::OwnerTerminated => "The Lidless session process was terminated.",
            EndReason::Rebooted => "The computer restarted during the session.",
            EndReason::OwnerLost => {
                "The Lidless process that owned the session stopped unexpectedly."
            }
            EndReason::StartFailed => "The session could not start.",
        }
    }

    pub fn is_safety(&self) -> bool {
        matches!(
            self,
            EndReason::BatteryFloor | EndReason::ThermalFloor | EndReason::BatteryUnreadable
        )
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LastEnd {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<Uuid>,
    pub reason: EndReason,
    pub at: DateTime<Utc>,
    pub restore_complete: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

// MARK: Journal

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoolEntry {
    pub original: bool,
    pub recorded_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MacJournal {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sleep_disabled: Option<BoolEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub low_power_mode: Option<BoolEntry>,
}

/// Windows: the lid-close action we changed (0 = do nothing, 1 = sleep,
/// 2 = hibernate, 3 = shut down) on the active power scheme, AC and battery.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LidActionEntry {
    pub scheme: String,
    #[serde(rename = "originalAC")]
    pub original_ac: u32,
    #[serde(rename = "originalDC")]
    pub original_dc: u32,
    pub recorded_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowsJournal {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lid_action: Option<LidActionEntry>,
}

/// Linux: the power profile we switched (power-profiles-daemon), if any.
/// The logind inhibitor needs no journal entry: it is released by the kernel
/// when the owning process exits.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StringEntry {
    pub original: String,
    pub recorded_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinuxJournal {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub power_profile: Option<StringEntry>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Journal {
    pub version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub macos: MacJournal,
    #[serde(default)]
    pub windows: WindowsJournal,
    #[serde(default)]
    pub linux: LinuxJournal,
}

impl Default for Journal {
    fn default() -> Self {
        Journal {
            version: 1,
            updated_at: None,
            macos: MacJournal::default(),
            windows: WindowsJournal::default(),
            linux: LinuxJournal::default(),
        }
    }
}

impl Journal {
    pub fn is_empty(&self) -> bool {
        self.macos.sleep_disabled.is_none()
            && self.macos.low_power_mode.is_none()
            && self.windows.lid_action.is_none()
            && self.linux.power_profile.is_none()
    }
}

// MARK: Config

fn t() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Config {
    pub low_power_below_percent: i64,
    pub end_below_percent: i64,
    #[serde(default = "t")]
    pub thermal_rules: bool,
    #[serde(default = "t")]
    pub low_power_on_lid_close: bool,
    #[serde(default = "t")]
    pub sleep_display_on_lid_close: bool,
    pub max_duration_seconds: f64,
    pub run_default_duration_seconds: f64,
    pub verify_settle_seconds: f64,
    #[serde(default = "t")]
    pub warn_on_network_loss: bool,
    #[serde(default = "t")]
    pub notifications: bool,
    #[serde(default = "t")]
    pub animate_menu_bar_icon: bool,
    #[serde(default = "t")]
    pub show_in_dock: bool,
    #[serde(default = "t")]
    pub check_for_updates: bool,
    pub extra_agent_names: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            low_power_below_percent: 40,
            end_below_percent: 10,
            thermal_rules: true,
            low_power_on_lid_close: true,
            sleep_display_on_lid_close: true,
            max_duration_seconds: 30.0 * 86_400.0,
            run_default_duration_seconds: 24.0 * 3_600.0,
            verify_settle_seconds: 5.0,
            warn_on_network_loss: true,
            notifications: true,
            animate_menu_bar_icon: true,
            show_in_dock: true,
            check_for_updates: true,
            extra_agent_names: Vec::new(),
        }
    }
}

impl Config {
    /// Clamps values into safe ranges (spec/floors.md).
    pub fn normalized(&self) -> Config {
        let mut c = self.clone();
        c.end_below_percent = c.end_below_percent.clamp(0, 50);
        c.low_power_below_percent = c.low_power_below_percent.clamp(0, 100);
        if c.end_below_percent > 0 && c.low_power_below_percent <= c.end_below_percent {
            c.low_power_below_percent = c.end_below_percent + 1;
        }
        c.max_duration_seconds = c.max_duration_seconds.clamp(60.0, 30.0 * 86_400.0);
        c.run_default_duration_seconds = c
            .run_default_duration_seconds
            .clamp(60.0, c.max_duration_seconds);
        c.verify_settle_seconds = c.verify_settle_seconds.clamp(0.0, 30.0);
        c
    }
}

// MARK: History

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: Uuid,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub reason: EndReason,
    pub closed_lid_seconds: f64,
    pub owner: OwnerKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Vec<String>>,
    pub restore_complete: bool,
}

impl HistoryEntry {
    pub fn duration(&self) -> f64 {
        (self.ended_at - self.started_at).num_milliseconds().max(0) as f64 / 1000.0
    }
}
