//! Session history and usage stats (same file format as the macOS app).

use chrono::{DateTime, Datelike, Duration, Local, TimeZone, Timelike, Utc};
use serde::{Deserialize, Serialize};

use crate::log;
use crate::model::HistoryEntry;
use crate::store::{read_optional, write_atomic, Store};

pub const LIMIT: usize = 1_000;

pub fn read(store: &Store) -> Vec<HistoryEntry> {
    read_optional(&store.paths.history())
        .ok()
        .flatten()
        .and_then(|d| serde_json::from_slice(&d).ok())
        .unwrap_or_default()
}

/// Appends an entry. The caller must hold the state lock.
pub fn append_locked(entry: HistoryEntry, store: &Store) {
    let mut entries = read(store);
    if entries.iter().any(|e| e.id == entry.id) {
        return;
    }
    entries.push(entry);
    if entries.len() > LIMIT {
        let excess = entries.len() - LIMIT;
        entries.drain(..excess);
    }
    let result = store
        .paths
        .ensure_home()
        .map_err(|e| e.to_string())
        .and_then(|_| serde_json::to_vec_pretty(&entries).map_err(|e| e.to_string()))
        .and_then(|d| write_atomic(&store.paths.history(), &d).map_err(|e| e.to_string()));
    if let Err(e) = result {
        log::warn(&format!("could not record session history: {e}"));
    }
}

pub fn append(entry: HistoryEntry, store: &Store) {
    match store.with_lock(|| {
        append_locked(entry, store);
        Ok(())
    }) {
        Ok(()) => {}
        Err(e) => log::warn(&format!("could not record session history: {e}")),
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Day {
    pub start: DateTime<Utc>,
    pub awake_seconds: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageStats {
    pub sessions: usize,
    pub total_awake_seconds: f64,
    pub closed_lid_seconds: f64,
    pub longest_seconds: f64,
    pub average_seconds: f64,
    pub this_week_seconds: f64,
    pub clean_restore_percent: Option<i64>,
    pub ended_by_safety: usize,
    pub command_sessions: usize,
    pub last_seven_days: Vec<Day>,
    pub first_session: Option<DateTime<Utc>>,
}

fn overlap(e: &HistoryEntry, start: DateTime<Utc>, end: DateTime<Utc>) -> f64 {
    let s = e.started_at.max(start);
    let f = e.ended_at.min(end);
    ((f - s).num_milliseconds().max(0)) as f64 / 1000.0
}

/// Awake seconds for each of the last `count` local days, oldest first.
pub fn daily(entries: &[HistoryEntry], count: i64, now: DateTime<Utc>) -> Vec<Day> {
    let local_now = now.with_timezone(&Local);
    let today = Local
        .with_ymd_and_hms(
            local_now.year(),
            local_now.month(),
            local_now.day(),
            0,
            0,
            0,
        )
        .single()
        .unwrap_or(local_now);
    (0..count)
        .rev()
        .map(|back| {
            let start = (today - Duration::days(back)).with_timezone(&Utc);
            let end = start + Duration::days(1);
            Day {
                start,
                awake_seconds: entries.iter().map(|e| overlap(e, start, end)).sum(),
            }
        })
        .collect()
}

/// Awake seconds by local hour of day (0–23).
pub fn hour_of_day(entries: &[HistoryEntry]) -> [f64; 24] {
    let mut hours = [0.0; 24];
    for e in entries {
        let mut t = e.started_at;
        while t < e.ended_at {
            let local = t.with_timezone(&Local);
            let hour_start = local
                .with_minute(0)
                .and_then(|x| x.with_second(0))
                .and_then(|x| x.with_nanosecond(0))
                .unwrap_or(local)
                .with_timezone(&Utc);
            let next = (hour_start + Duration::hours(1)).min(e.ended_at);
            hours[local.hour() as usize] += (next - t).num_milliseconds().max(0) as f64 / 1000.0;
            t = next;
        }
    }
    hours
}

pub fn compute(entries: &[HistoryEntry], now: DateTime<Utc>) -> UsageStats {
    let durations: Vec<f64> = entries.iter().map(|e| e.duration()).collect();
    let total: f64 = durations.iter().sum();
    let days = daily(entries, 7, now);
    UsageStats {
        sessions: entries.len(),
        total_awake_seconds: total,
        closed_lid_seconds: entries.iter().map(|e| e.closed_lid_seconds).sum(),
        longest_seconds: durations.iter().cloned().fold(0.0, f64::max),
        average_seconds: if entries.is_empty() {
            0.0
        } else {
            total / entries.len() as f64
        },
        this_week_seconds: days.iter().map(|d| d.awake_seconds).sum(),
        clean_restore_percent: if entries.is_empty() {
            None
        } else {
            Some(
                ((entries.iter().filter(|e| e.restore_complete).count() as f64
                    / entries.len() as f64)
                    * 100.0)
                    .round() as i64,
            )
        },
        ended_by_safety: entries.iter().filter(|e| e.reason.is_safety()).count(),
        command_sessions: entries.iter().filter(|e| e.command.is_some()).count(),
        last_seven_days: days,
        first_session: entries.iter().map(|e| e.started_at).min(),
    }
}
