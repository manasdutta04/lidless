//! State directory layout (spec/README.md). `LIDLESS_HOME` overrides it;
//! tests always set it to a temporary directory.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Paths {
    pub home: PathBuf,
}

impl Paths {
    pub fn new(home: impl Into<PathBuf>) -> Self {
        Paths { home: home.into() }
    }

    pub fn resolve() -> Self {
        if let Ok(home) = std::env::var("LIDLESS_HOME") {
            if !home.is_empty() {
                return Paths::new(home);
            }
        }
        Paths::new(default_home())
    }

    pub fn session(&self) -> PathBuf {
        self.home.join("session.json")
    }
    pub fn journal(&self) -> PathBuf {
        self.home.join("journal.json")
    }
    pub fn config(&self) -> PathBuf {
        self.home.join("config.json")
    }
    pub fn last_end(&self) -> PathBuf {
        self.home.join("last-end.json")
    }
    pub fn history(&self) -> PathBuf {
        self.home.join("history.json")
    }
    pub fn lock(&self) -> PathBuf {
        self.home.join("lock")
    }
    pub fn log(&self) -> PathBuf {
        self.home.join("lidless.log")
    }
    pub fn first_run_marker(&self) -> PathBuf {
        self.home.join("first-run-acknowledged")
    }

    /// Creates the state directory, owner-only.
    pub fn ensure_home(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.home)?;
        tighten_dir(&self.home);
        Ok(())
    }
}

fn default_home() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("Library/Application Support/Lidless")
    }
    #[cfg(target_os = "windows")]
    {
        dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("Lidless")
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        dirs::state_dir()
            .or_else(|| dirs::home_dir().map(|h| h.join(".local/state")))
            .unwrap_or_else(|| PathBuf::from("."))
            .join("lidless")
    }
}

#[cfg(unix)]
pub fn tighten_dir(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
}

#[cfg(unix)]
pub fn tighten_file(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}

/// On Windows the per-user profile directory is already owner-only
/// (%LOCALAPPDATA% ACLs); nothing extra is needed.
#[cfg(not(unix))]
pub fn tighten_dir(_path: &Path) {}

#[cfg(not(unix))]
pub fn tighten_file(_path: &Path) {}
