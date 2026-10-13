//! Task Scheduler integration through `schtasks.exe`:
//! - `Lidless\Recovery`: runs `lidless recover` every minute, as the user.
//! - `Lidless\RecoveryLogon`: the same at logon.
//! - `Lidless\LidAction`: runs `lidless _lidaction` with highest privileges.
//!   Standard users can start it on demand; it only applies the lid action
//!   from the request file Lidless wrote. Registered once by elevated setup.

use std::path::Path;
use std::process::{Command, Stdio};

use lidless_core::error::{LidlessError, Result};
use lidless_core::store::write_atomic;

use crate::power::{request_path, result_path, LidActionRequest};

pub const TASK_RECOVERY: &str = "Lidless\\Recovery";
pub const TASK_RECOVERY_LOGON: &str = "Lidless\\RecoveryLogon";
pub const TASK_LID_ACTION: &str = "Lidless\\LidAction";

fn schtasks(args: &[&str]) -> Result<(bool, String)> {
    let out = Command::new("schtasks.exe")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| LidlessError::System(format!("schtasks: {e}")))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    Ok((out.status.success(), text.trim().to_string()))
}

fn task_exists(name: &str) -> bool {
    schtasks(&["/Query", "/TN", name])
        .map(|(ok, _)| ok)
        .unwrap_or(false)
}

pub fn lid_action_task_exists() -> bool {
    task_exists(TASK_LID_ACTION)
}

pub fn recovery_status() -> (bool, String) {
    if task_exists(TASK_RECOVERY) {
        (
            true,
            format!("{TASK_RECOVERY} runs `lidless recover` every minute"),
        )
    } else {
        (
            false,
            format!("Task Scheduler task {TASK_RECOVERY} is missing"),
        )
    }
}

fn quoted(path: &Path) -> String {
    format!("\"{}\"", path.display())
}

/// Creates the unprivileged recovery tasks (as the current user).
fn install_recovery(cli: &Path) -> Result<()> {
    let tr = format!("{} recover", quoted(cli));
    let (ok, text) = schtasks(&[
        "/Create",
        "/F",
        "/TN",
        TASK_RECOVERY,
        "/TR",
        &tr,
        "/SC",
        "MINUTE",
        "/MO",
        "1",
    ])?;
    if !ok {
        return Err(LidlessError::System(format!(
            "Could not create {TASK_RECOVERY}: {text}"
        )));
    }
    let (ok, text) = schtasks(&[
        "/Create",
        "/F",
        "/TN",
        TASK_RECOVERY_LOGON,
        "/TR",
        &tr,
        "/SC",
        "ONLOGON",
    ])?;
    if !ok {
        return Err(LidlessError::System(format!(
            "Could not create {TASK_RECOVERY_LOGON}: {text}"
        )));
    }
    Ok(())
}

/// Runs elevated (via UAC): creates the highest-privilege lid-action task.
pub fn install_elevated(cli: &Path) -> Result<()> {
    let tr = format!("{} _lidaction", quoted(cli));
    let (ok, text) = schtasks(&[
        "/Create",
        "/F",
        "/TN",
        TASK_LID_ACTION,
        "/TR",
        &tr,
        "/SC",
        "ONCE",
        "/ST",
        "00:00",
        "/RL",
        "HIGHEST",
    ])?;
    if !ok {
        return Err(LidlessError::System(format!(
            "Could not create {TASK_LID_ACTION}: {text}"
        )));
    }
    Ok(())
}

/// Full setup: recovery tasks as the user, then the elevated step through a
/// UAC prompt (`runas`) unless direct power writes already work.
pub fn install_via_uac(cli: &Path) -> Result<Vec<String>> {
    let mut steps = Vec::new();
    install_recovery(cli)?;
    steps.push(format!(
        "Recovery tasks registered ({TASK_RECOVERY}, {TASK_RECOVERY_LOGON})"
    ));
    if crate::power::can_write_lid_action() {
        steps.push(
            "This account can change the lid-close action directly; no elevated task needed".into(),
        );
    } else if lid_action_task_exists() {
        steps.push(format!("{TASK_LID_ACTION} already registered"));
    } else {
        run_as_admin(cli, &["_install-elevated", &cli.display().to_string()])?;
        if !lid_action_task_exists() {
            return Err(LidlessError::NotReady(
                "Administrator approval was not given, so the lid-close permission is not set up."
                    .into(),
            ));
        }
        steps.push(format!(
            "{TASK_LID_ACTION} registered with administrator approval"
        ));
    }
    Ok(steps)
}

pub fn uninstall() -> Result<Vec<String>> {
    let mut steps = Vec::new();
    for task in [TASK_RECOVERY, TASK_RECOVERY_LOGON, TASK_LID_ACTION] {
        if task_exists(task) {
            let (ok, text) = schtasks(&["/Delete", "/F", "/TN", task])?;
            if ok {
                steps.push(format!("Removed {task}"));
            } else if task == TASK_LID_ACTION {
                // Highest-privilege tasks need elevation to delete.
                if let Ok(exe) = std::env::current_exe() {
                    let _ = run_as_admin(&exe, &["_uninstall-elevated"]);
                }
                if task_exists(task) {
                    return Err(LidlessError::System(format!(
                        "Could not remove {task}: {text}"
                    )));
                }
                steps.push(format!("Removed {task} with administrator approval"));
            } else {
                return Err(LidlessError::System(format!(
                    "Could not remove {task}: {text}"
                )));
            }
        }
    }
    Ok(steps)
}

/// Asks the elevated task to apply `ac`/`dc`, then waits for its result.
pub fn run_lid_action_task(scheme: &str, ac: u32, dc: u32) -> Result<()> {
    if !lid_action_task_exists() {
        return Err(LidlessError::NotReady(
            "Changing the lid-close action needs administrator rights on this account. Run Lidless setup once to register the elevated task.".into(),
        ));
    }
    let _ = std::fs::remove_file(result_path());
    let req = LidActionRequest {
        scheme: scheme.to_string(),
        ac,
        dc,
    };
    write_atomic(&request_path(), serde_json::to_string(&req)?.as_bytes())?;
    let (ok, text) = schtasks(&["/Run", "/TN", TASK_LID_ACTION])?;
    if !ok {
        return Err(LidlessError::System(format!(
            "Could not start {TASK_LID_ACTION}: {text}"
        )));
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while std::time::Instant::now() < deadline {
        if let Ok(data) = std::fs::read(result_path()) {
            let v: serde_json::Value = serde_json::from_slice(&data).unwrap_or_default();
            let _ = std::fs::remove_file(request_path());
            return if v["ok"].as_bool() == Some(true) {
                Ok(())
            } else {
                Err(LidlessError::System(format!(
                    "The elevated task could not change the lid-close action: {}",
                    v["error"].as_str().unwrap_or("unknown")
                )))
            };
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    Err(LidlessError::System(
        "The elevated task did not report back within 20 s.".into(),
    ))
}

#[cfg(windows)]
fn run_as_admin(exe: &Path, args: &[&str]) -> Result<()> {
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;
    let params: String = args
        .iter()
        .map(|a| format!("\"{a}\""))
        .collect::<Vec<_>>()
        .join(" ");
    let verb = HSTRING::from("runas");
    let file = HSTRING::from(exe.display().to_string());
    let params_w = HSTRING::from(params);
    let h = unsafe {
        ShellExecuteW(
            HWND::default(),
            PCWSTR(verb.as_ptr()),
            PCWSTR(file.as_ptr()),
            PCWSTR(params_w.as_ptr()),
            PCWSTR::null(),
            SW_HIDE,
        )
    };
    // ShellExecuteW returns a value > 32 on success.
    if (h.0 as usize) <= 32 {
        return Err(LidlessError::NotReady(
            "Administrator approval was not given.".into(),
        ));
    }
    // Give the elevated process time to register the task.
    std::thread::sleep(std::time::Duration::from_secs(3));
    Ok(())
}

#[cfg(not(windows))]
fn run_as_admin(_exe: &Path, _args: &[&str]) -> Result<()> {
    Err(LidlessError::System("Not on Windows.".into()))
}
