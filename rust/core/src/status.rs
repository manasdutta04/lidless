//! The `status --json` shape from spec/cli.md.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::engine::{Engine, ReadinessReport};
use crate::floors::ThermalLevel;
use crate::model::{LastEnd, OwnerKind};
use crate::process::ProcessInspector;
use crate::store::{SessionRead, Store};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnerInfo {
    pub kind: OwnerKind,
    pub pid: u32,
    pub alive: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub id: Uuid,
    pub started_at: DateTime<Utc>,
    pub ends_at: DateTime<Utc>,
    pub remaining_seconds: i64,
    pub owner: OwnerInfo,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_requested: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JournalInfo {
    /// Any closed-lid change is pending restore (macOS SleepDisabled, Windows lid action).
    pub sleep_disabled: bool,
    pub low_power_mode: bool,
    pub readable: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PowerInfo {
    pub has_battery: bool,
    pub on_battery: bool,
    pub percent: Option<i64>,
    pub thermal: ThermalLevel,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusSnapshot {
    pub active: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionInfo>,
    pub journal: JournalInfo,
    pub lid_closed: Option<bool>,
    pub power: PowerInfo,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_end: Option<LastEnd>,
    pub warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready: Option<ReadinessReport>,
}

pub fn collect(
    engine: &dyn Engine,
    store: &Store,
    inspector: &dyn ProcessInspector,
    ready: Option<ReadinessReport>,
    now: DateTime<Utc>,
) -> StatusSnapshot {
    let mut warnings = Vec::new();
    let mut session_info = None;
    match store.read_session() {
        SessionRead::None => {}
        SessionRead::Unreadable(why) => warnings.push(format!(
            "The session file is unreadable ({why}). The recovery job will move it aside and restore settings."
        )),
        SessionRead::Some(s) => {
            let alive = inspector.is_alive(&s.owner);
            session_info = Some(SessionInfo {
                id: s.id,
                started_at: s.started_at,
                ends_at: s.ends_at,
                remaining_seconds: s.remaining(now).ceil() as i64,
                owner: OwnerInfo { kind: s.owner.kind, pid: s.owner.pid, alive },
                command: s.command.clone(),
                stop_requested: s.stop_requested.clone(),
            });
            if !alive {
                warnings.push(format!(
                    "The process that started this session quit unexpectedly. The computer stays awake until {}, with the battery and heat limits still enforced. Stop ends it now.",
                    s.ends_at.with_timezone(&chrono::Local).format("%H:%M")
                ));
            }
        }
    }

    let mut journal = JournalInfo {
        sleep_disabled: false,
        low_power_mode: false,
        readable: true,
    };
    match store.read_journal() {
        Ok(j) => {
            journal.sleep_disabled =
                j.macos.sleep_disabled.is_some() || j.windows.lid_action.is_some();
            journal.low_power_mode =
                j.macos.low_power_mode.is_some() || j.linux.power_profile.is_some();
            if session_info.is_none() && !j.is_empty() {
                warnings.push("Settings from an earlier session are waiting to be restored. The recovery job retries every minute; `lidless recover` runs it now.".into());
            }
        }
        Err(e) => {
            journal.readable = false;
            warnings.push(e.to_string());
        }
    }

    let last_end = store.read_last_end();
    if let Some(le) = &last_end {
        if !le.restore_complete && session_info.is_none() {
            warnings.push(format!(
                "The last session did not restore everything: {}.",
                le.detail.clone().unwrap_or_else(|| "unknown error".into())
            ));
        }
    }
    if let Some(r) = &ready {
        if let Some(e) = r.not_ready_error(&engine.fix_hint()) {
            warnings.push(e.to_string());
        }
    }

    let b = engine.battery();
    StatusSnapshot {
        active: session_info.is_some(),
        session: session_info,
        journal,
        lid_closed: engine.lid_closed(),
        power: PowerInfo {
            has_battery: b.has_battery,
            on_battery: b.has_battery && b.on_battery,
            percent: b.percent,
            thermal: engine.thermal(),
        },
        last_end,
        warnings,
        ready,
    }
}
