//! Recovery policy (spec/journal.md "Recovery job", spec/session.md rule 7).

use chrono::{DateTime, Utc};

use crate::engine::{Engine, RestoreReport};
use crate::floors::{self, BatteryReading, ThermalLevel};
use crate::history;
use crate::log;
use crate::model::{Config, EndReason, HistoryEntry, LastEnd};
use crate::process::ProcessInspector;
use crate::store::{SessionRead, Store};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryAction {
    Nothing,
    KeepOrphan,
    EndSession(EndReason),
    QuarantineAndRestore,
    RestoreJournal,
}

#[allow(clippy::too_many_arguments)]
pub fn decide(
    session: &SessionRead,
    journal_empty: bool,
    owner_alive: bool,
    same_boot: bool,
    now: DateTime<Utc>,
    battery: BatteryReading,
    thermal: ThermalLevel,
    config: &Config,
) -> RecoveryAction {
    match session {
        SessionRead::Unreadable(_) => RecoveryAction::QuarantineAndRestore,
        SessionRead::None => {
            if journal_empty {
                RecoveryAction::Nothing
            } else {
                RecoveryAction::RestoreJournal
            }
        }
        SessionRead::Some(s) => {
            if owner_alive {
                return RecoveryAction::Nothing;
            }
            if !same_boot {
                return RecoveryAction::EndSession(EndReason::Rebooted);
            }
            if s.stop_requested.is_some() {
                return RecoveryAction::EndSession(EndReason::Stopped);
            }
            if s.is_expired(now) {
                return RecoveryAction::EndSession(EndReason::Expired);
            }
            let d = floors::decide(
                battery.has_battery && battery.on_battery,
                battery.percent,
                if battery.percent.is_none() { 1 } else { 0 },
                thermal,
                false,
                config,
            );
            match d.end {
                Some(reason) => RecoveryAction::EndSession(reason),
                None => RecoveryAction::KeepOrphan,
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RecoveryOutcome {
    pub action: RecoveryAction,
    pub report: RestoreReport,
    pub message: String,
}

/// Runs the recovery decision and carries it out under the state lock.
/// `force_end` ends an orphaned session even with time left (`lidless stop`).
pub fn run(
    engine: &dyn Engine,
    store: &Store,
    inspector: &dyn ProcessInspector,
    now: DateTime<Utc>,
    force_end: Option<EndReason>,
) -> RecoveryOutcome {
    let result = store.with_lock(|| {
        let session = store.read_session();
        let journal = match store.read_journal() {
            Ok(j) => j,
            Err(e) => {
                return Ok(RecoveryOutcome {
                    action: RecoveryAction::Nothing,
                    report: RestoreReport::default(),
                    message: e.to_string(),
                })
            }
        };
        let (owner_alive, same_boot) = match &session {
            SessionRead::Some(s) => (
                inspector.is_alive(&s.owner),
                s.owner.boot_session == inspector.boot_session(),
            ),
            _ => (false, true),
        };
        let mut action = decide(
            &session,
            journal.is_empty(),
            owner_alive,
            same_boot,
            now,
            engine.battery(),
            engine.thermal(),
            &store.read_config(),
        );
        if let (Some(force), RecoveryAction::KeepOrphan) = (force_end, &action) {
            action = RecoveryAction::EndSession(force);
        }
        Ok(perform(engine, store, action, session, now))
    });
    result.unwrap_or_else(|e| RecoveryOutcome {
        action: RecoveryAction::Nothing,
        report: RestoreReport::default(),
        message: format!("Recovery could not run: {e}"),
    })
}

fn perform(
    engine: &dyn Engine,
    store: &Store,
    action: RecoveryAction,
    session: SessionRead,
    now: DateTime<Utc>,
) -> RecoveryOutcome {
    match action {
        RecoveryAction::Nothing => RecoveryOutcome {
            action,
            report: RestoreReport::default(),
            message: "Nothing to recover.".into(),
        },
        RecoveryAction::KeepOrphan => {
            let mut msg = "The Lidless process that owned the session is gone; keeping the computer awake until the session ends.".to_string();
            if let SessionRead::Some(s) = &session {
                msg.push_str(&format!(" Ends at {}.", s.ends_at.to_rfc3339()));
            }
            RecoveryOutcome {
                action,
                report: RestoreReport::default(),
                message: msg,
            }
        }
        RecoveryAction::QuarantineAndRestore => {
            let msg = match store.quarantine_session(now) {
                Ok(dest) => format!("Session file was unreadable; moved to {}.", dest.display()),
                Err(e) => format!("Session file was unreadable and could not be moved aside: {e}."),
            };
            let report = engine.restore_all_locked(store, now);
            let _ = store.write_last_end(&LastEnd {
                session_id: None,
                reason: EndReason::OwnerLost,
                at: now,
                restore_complete: report.complete(),
                detail: Some(msg.clone()),
            });
            log::warn(&format!(
                "recovery: {msg} restore complete={}",
                report.complete()
            ));
            RecoveryOutcome {
                action,
                report,
                message: msg,
            }
        }
        RecoveryAction::RestoreJournal => {
            let report = engine.restore_all_locked(store, now);
            let msg = if report.complete() {
                "Restored settings left over from an earlier session.".to_string()
            } else {
                format!(
                    "Some settings could not be restored yet: {}",
                    report.failures.join("; ")
                )
            };
            log::info(&format!("recovery: {msg}"));
            RecoveryOutcome {
                action,
                report,
                message: msg,
            }
        }
        RecoveryAction::EndSession(reason) => {
            let s = match &session {
                SessionRead::Some(s) => Some(s.clone()),
                _ => None,
            };
            // Remove the session first: a crash after this leaves
            // "no session + journal entries", which the next run restores.
            if let Err(e) = store.remove_session() {
                let msg = format!("Could not remove the session file: {e}");
                log::error(&format!("recovery: {msg}"));
                return RecoveryOutcome {
                    action,
                    report: RestoreReport::default(),
                    message: msg,
                };
            }
            let report = engine.restore_all_locked(store, now);
            let detail = if report.complete() {
                None
            } else {
                Some(report.failures.join("; "))
            };
            let _ = store.write_last_end(&LastEnd {
                session_id: s.as_ref().map(|s| s.id),
                reason,
                at: now,
                restore_complete: report.complete(),
                detail: detail.clone(),
            });
            if let Some(s) = &s {
                history::append_locked(
                    HistoryEntry {
                        id: s.id,
                        started_at: s.started_at,
                        ended_at: now.min(s.ends_at),
                        reason,
                        closed_lid_seconds: 0.0,
                        owner: s.owner.kind,
                        command: s.command.clone(),
                        restore_complete: report.complete(),
                    },
                    store,
                );
            }
            let msg = format!(
                "Ended the session ({}): {}{}",
                reason.raw(),
                reason.summary(),
                if report.complete() {
                    String::new()
                } else {
                    format!(" Restore incomplete: {}", detail.unwrap_or_default())
                }
            );
            log::info(&format!("recovery: {msg}"));
            RecoveryOutcome {
                action,
                report,
                message: msg,
            }
        }
    }
}
