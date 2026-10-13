//! Owner-only append log, rotated at 1 MiB with one previous file kept.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use chrono::Utc;

use crate::paths::tighten_file;

static TARGET: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();
static ECHO: OnceLock<bool> = OnceLock::new();

pub fn configure(path: PathBuf, echo_to_stderr: bool) {
    let cell = TARGET.get_or_init(|| Mutex::new(None));
    *cell.lock().unwrap() = Some(path);
    let _ = ECHO.set(echo_to_stderr);
}

pub fn info(msg: &str) {
    write("INFO", msg)
}
pub fn warn(msg: &str) {
    write("WARN", msg)
}
pub fn error(msg: &str) {
    write("ERROR", msg)
}

fn write(level: &str, msg: &str) {
    let line = format!(
        "{} [{}] {} {}\n",
        Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        std::process::id(),
        level,
        msg
    );
    if ECHO.get().copied().unwrap_or(false) {
        eprint!("{line}");
    }
    let Some(cell) = TARGET.get() else { return };
    let guard = cell.lock().unwrap();
    let Some(path) = guard.as_ref() else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(meta) = std::fs::metadata(path) {
        if meta.len() > (1 << 20) {
            let old = path.with_extension("log.1");
            let _ = std::fs::remove_file(&old);
            let _ = std::fs::rename(path, &old);
        }
    }
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = f.write_all(line.as_bytes());
        tighten_file(path);
    }
}
