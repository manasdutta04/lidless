//! The `lidless` command for Windows and Linux. (macOS ships its own Swift
//! CLI inside Lidless.app; this binary runs there only as a preview against
//! a fake engine.)

use lidless_core::engine::Engine;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    #[cfg(windows)]
    {
        if let Some(code) = lidless_windows::WindowsEngine::handle_hidden_command(&args) {
            std::process::exit(code);
        }
    }

    let engine = make_engine();
    let code = lidless_core::cli::run(engine.as_ref(), args);
    std::process::exit(code);
}

#[cfg(windows)]
fn make_engine() -> Box<dyn Engine> {
    Box::new(lidless_windows::WindowsEngine::new())
}

#[cfg(target_os = "linux")]
fn make_engine() -> Box<dyn Engine> {
    Box::new(lidless_linux::LinuxEngine::new())
}

#[cfg(not(any(windows, target_os = "linux")))]
fn make_engine() -> Box<dyn Engine> {
    eprintln!("lidless: this build has no engine for {}; using a preview that changes nothing. On macOS, install Lidless.app.", std::env::consts::OS);
    Box::new(lidless_core::testing::FakeEngine::new())
}
