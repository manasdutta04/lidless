//! Recovery via a systemd user timer: `lidless recover` one minute after
//! login and every minute after that. Runs as the user; nothing is elevated.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use lidless_core::error::{LidlessError, Result};

pub const SERVICE: &str = "lidless-recover.service";
pub const TIMER: &str = "lidless-recover.timer";

fn unit_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".config"))
        .join("systemd/user")
}

fn systemctl(args: &[&str]) -> Result<(bool, String)> {
    let out = Command::new("systemctl")
        .arg("--user")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| LidlessError::System(format!("systemctl: {e}")))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    Ok((out.status.success(), text.trim().to_string()))
}

pub fn recovery_status() -> (bool, String) {
    match systemctl(&["is-active", TIMER]) {
        Ok((true, _)) => (true, format!("{TIMER} runs `lidless recover` every minute")),
        Ok((false, state)) => (
            false,
            format!(
                "{TIMER} is {}",
                if state.is_empty() {
                    "not installed".into()
                } else {
                    state
                }
            ),
        ),
        Err(e) => (false, e.to_string()),
    }
}

pub fn install(cli: &Path) -> Result<Vec<String>> {
    let dir = unit_dir();
    std::fs::create_dir_all(&dir)?;
    let service = format!(
        "[Unit]\nDescription=Lidless recovery: restores power settings if the app stopped unexpectedly\n\n[Service]\nType=oneshot\nExecStart={} recover\n",
        cli.display()
    );
    let timer = format!(
        "[Unit]\nDescription=Run Lidless recovery every minute\n\n[Timer]\nOnBootSec=1min\nOnStartupSec=30s\nOnUnitActiveSec=1min\nAccuracySec=10s\nUnit={SERVICE}\n\n[Install]\nWantedBy=timers.target\n"
    );
    std::fs::write(dir.join(SERVICE), service)?;
    std::fs::write(dir.join(TIMER), timer)?;
    let (ok, text) = systemctl(&["daemon-reload"])?;
    if !ok {
        return Err(LidlessError::System(format!(
            "systemctl daemon-reload: {text}"
        )));
    }
    let (ok, text) = systemctl(&["enable", "--now", TIMER])?;
    if !ok {
        return Err(LidlessError::System(format!(
            "Could not enable {TIMER}: {text}"
        )));
    }
    let (active, _) = systemctl(&["is-active", TIMER])?;
    if !active {
        return Err(LidlessError::System(format!("{TIMER} did not start")));
    }
    Ok(vec![format!(
        "Recovery timer installed and running ({})",
        dir.join(TIMER).display()
    )])
}

pub fn uninstall() -> Result<Vec<String>> {
    let mut steps = Vec::new();
    let _ = systemctl(&["disable", "--now", TIMER]);
    let dir = unit_dir();
    for unit in [TIMER, SERVICE] {
        let p = dir.join(unit);
        if p.exists() {
            std::fs::remove_file(&p)?;
            steps.push(format!("Removed {}", p.display()));
        }
    }
    let _ = systemctl(&["daemon-reload"]);
    if steps.is_empty() {
        steps.push("Recovery timer was not installed".into());
    }
    Ok(steps)
}
