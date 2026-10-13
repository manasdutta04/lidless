//! Operations any Lidless process may perform on the current session without
//! owning it: extend and stop edit `session.json` under the lock and never
//! signal the owner (spec/session.md rule 5).

use chrono::{DateTime, Duration, Utc};
use uuid::Uuid;

use crate::error::{LidlessError, Result};
use crate::log;
use crate::model::{Extension, LastEnd, Session};
use crate::process::ProcessInspector;
use crate::store::{SessionRead, Store};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StopRequest {
    /// The live owner will end the session on its next tick.
    Requested(Uuid),
    /// The owner is gone; the caller should run recovery.
    OwnerDead(Uuid),
}

pub fn extend(store: &Store, seconds: f64, now: DateTime<Utc>) -> Result<(Session, bool)> {
    if seconds <= 0.0 {
        return Err(LidlessError::Usage(
            "Extension must be greater than zero.".into(),
        ));
    }
    let config = store.read_config();
    store.with_lock(|| {
        let SessionRead::Some(mut s) = store.read_session() else {
            return Err(LidlessError::NoSession);
        };
        if s.stop_requested.is_some() {
            return Err(LidlessError::NoSession);
        }
        let cap = now + Duration::milliseconds((config.max_duration_seconds * 1000.0) as i64);
        let wanted = s.ends_at.max(now) + Duration::milliseconds((seconds * 1000.0) as i64);
        let new_end = wanted.min(cap);
        let added = (new_end - s.ends_at).num_milliseconds() as f64 / 1000.0;
        if added <= 0.0 {
            return Err(LidlessError::Usage(format!(
                "The session already ends at the {} maximum.",
                crate::duration::format(config.max_duration_seconds)
            )));
        }
        s.ends_at = new_end;
        s.extensions.push(Extension {
            at: now,
            seconds: added,
        });
        store.write_session(&s)?;
        log::info(&format!(
            "session {} extended by {} to {}",
            s.id,
            crate::duration::format(added),
            new_end.to_rfc3339()
        ));
        Ok((s, wanted > cap))
    })
}

pub fn request_stop(
    store: &Store,
    inspector: &dyn ProcessInspector,
    reason: &str,
) -> Result<StopRequest> {
    store.with_lock(|| match store.read_session() {
        SessionRead::None => Err(LidlessError::NoSession),
        SessionRead::Unreadable(_) => Ok(StopRequest::OwnerDead(Uuid::nil())),
        SessionRead::Some(mut s) => {
            if !inspector.is_alive(&s.owner) {
                return Ok(StopRequest::OwnerDead(s.id));
            }
            s.stop_requested = Some(reason.to_string());
            store.write_session(&s)?;
            Ok(StopRequest::Requested(s.id))
        }
    })
}

/// Polls until the session file no longer holds `id`, then returns the
/// matching last-end record (None on timeout).
pub fn wait_for_end(store: &Store, id: Uuid, timeout: std::time::Duration) -> Option<LastEnd> {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        let gone = !matches!(store.read_session(), SessionRead::Some(s) if s.id == id);
        if gone {
            if let Some(le) = store.read_last_end() {
                if le.session_id == Some(id) {
                    return Some(le);
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    None
}
