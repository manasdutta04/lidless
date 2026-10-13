//! Atomic, owner-only state files plus the advisory lock.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use fs2::FileExt;

use crate::error::{LidlessError, Result};
use crate::model::{Config, Journal, LastEnd, Session};
use crate::paths::{tighten_file, Paths};

/// Result of reading the session file. "Unreadable" is distinct from "absent"
/// so a corrupt file is never mistaken for "no session".
#[derive(Debug, Clone, PartialEq)]
pub enum SessionRead {
    None,
    Some(Session),
    Unreadable(String),
}

/// Atomically replaces `path` with `data`: temp file in the same directory,
/// fsync, rename over the target.
pub fn write_atomic(path: &Path, data: &[u8]) -> Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| LidlessError::System("bad path".into()))?;
    let mut tmp = tempfile::Builder::new()
        .prefix(".lidless-")
        .suffix(".tmp")
        .tempfile_in(dir)?;
    tmp.write_all(data)?;
    tmp.as_file().sync_all()?;
    tighten_file(tmp.path());
    tmp.persist(path)
        .map_err(|e| LidlessError::System(e.to_string()))?;
    tighten_file(path);
    if let Ok(d) = File::open(dir) {
        let _ = d.sync_all();
    }
    Ok(())
}

/// Reads a file, `Ok(None)` when it does not exist.
pub fn read_optional(path: &Path) -> Result<Option<Vec<u8>>> {
    match std::fs::read(path) {
        Ok(d) => Ok(Some(d)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Advisory lock on the state directory's lock file.
pub struct FileLock {
    file: File,
}

impl FileLock {
    pub fn acquire(path: &Path, timeout: Duration) -> Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)?;
        tighten_file(path);
        let deadline = Instant::now() + timeout;
        loop {
            match file.try_lock_exclusive() {
                Ok(()) => return Ok(FileLock { file }),
                Err(_) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(50))
                }
                Err(_) => return Err(LidlessError::LockTimeout),
            }
        }
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

#[derive(Debug, Clone)]
pub struct Store {
    pub paths: Paths,
}

impl Store {
    pub fn new(paths: Paths) -> Self {
        Store { paths }
    }

    /// Runs `body` while holding the state lock.
    pub fn with_lock<T>(&self, body: impl FnOnce() -> Result<T>) -> Result<T> {
        self.paths.ensure_home()?;
        let _lock = FileLock::acquire(&self.paths.lock(), Duration::from_secs(30))?;
        body()
    }

    pub fn lock(&self) -> Result<FileLock> {
        self.paths.ensure_home()?;
        FileLock::acquire(&self.paths.lock(), Duration::from_secs(30))
    }

    // Session

    pub fn read_session(&self) -> SessionRead {
        match read_optional(&self.paths.session()) {
            Ok(None) => SessionRead::None,
            Ok(Some(data)) => match serde_json::from_slice::<Session>(&data) {
                Ok(s) => SessionRead::Some(s),
                Err(e) => SessionRead::Unreadable(e.to_string()),
            },
            Err(e) => SessionRead::Unreadable(e.to_string()),
        }
    }

    pub fn write_session(&self, session: &Session) -> Result<()> {
        self.paths.ensure_home()?;
        write_atomic(&self.paths.session(), &serde_json::to_vec_pretty(session)?)
    }

    pub fn remove_session(&self) -> Result<()> {
        match std::fs::remove_file(self.paths.session()) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Renames an unreadable session file aside (never deletes it).
    pub fn quarantine_session(&self, now: DateTime<Utc>) -> Result<std::path::PathBuf> {
        let dest = self
            .paths
            .home
            .join(format!("session.json.unreadable-{}", now.timestamp()));
        std::fs::rename(self.paths.session(), &dest)?;
        Ok(dest)
    }

    // Journal

    /// Missing file → empty journal. Unreadable file → error, so a damaged
    /// journal is never treated as clean.
    pub fn read_journal(&self) -> Result<Journal> {
        match read_optional(&self.paths.journal())? {
            None => Ok(Journal::default()),
            Some(data) => serde_json::from_slice(&data).map_err(|e| {
                LidlessError::System(format!(
                    "The recovery journal at {} could not be read ({e}). It was left in place; inspect it before removing.",
                    self.paths.journal().display()
                ))
            }),
        }
    }

    pub fn write_journal(&self, journal: &Journal, now: DateTime<Utc>) -> Result<()> {
        self.paths.ensure_home()?;
        let mut j = journal.clone();
        j.updated_at = Some(now);
        write_atomic(&self.paths.journal(), &serde_json::to_vec_pretty(&j)?)
    }

    // Config

    pub fn read_config(&self) -> Config {
        read_optional(&self.paths.config())
            .ok()
            .flatten()
            .and_then(|d| serde_json::from_slice::<Config>(&d).ok())
            .map(|c| c.normalized())
            .unwrap_or_default()
    }

    pub fn write_config(&self, config: &Config) -> Result<()> {
        self.paths.ensure_home()?;
        write_atomic(
            &self.paths.config(),
            &serde_json::to_vec_pretty(&config.normalized())?,
        )
    }

    // Last end

    pub fn read_last_end(&self) -> Option<LastEnd> {
        read_optional(&self.paths.last_end())
            .ok()
            .flatten()
            .and_then(|d| serde_json::from_slice(&d).ok())
    }

    pub fn write_last_end(&self, last_end: &LastEnd) -> Result<()> {
        self.paths.ensure_home()?;
        write_atomic(
            &self.paths.last_end(),
            &serde_json::to_vec_pretty(last_end)?,
        )
    }
}
