//! Picks the platform engine. On macOS the app is a design preview only and
//! runs against the core's `FakeEngine`, which never touches power settings.

use lidless_core::engine::Engine;

#[cfg(target_os = "windows")]
pub fn make() -> Box<dyn Engine> {
    Box::new(lidless_windows::WindowsEngine::new())
}

#[cfg(target_os = "linux")]
pub fn make() -> Box<dyn Engine> {
    Box::new(lidless_linux::LinuxEngine::new())
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
pub fn make() -> Box<dyn Engine> {
    Box::new(lidless_core::testing::FakeEngine::new())
}

/// The bundled CLI: beside the app binary, or on the Linux system path.
pub fn cli_path() -> std::path::PathBuf {
    let name = if cfg!(windows) {
        "lidless.exe"
    } else {
        "lidless"
    };
    let beside = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join(name)));
    if let Some(p) = &beside {
        if p.exists() {
            return p.clone();
        }
    }
    #[cfg(target_os = "linux")]
    for candidate in ["/usr/bin/lidless", "/usr/local/bin/lidless"] {
        if std::path::Path::new(candidate).exists() {
            return candidate.into();
        }
    }
    beside.unwrap_or_else(|| name.into())
}
