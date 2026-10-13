//! Finds running coding-agent processes. Read-only: never signals.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

pub const BUILT_IN: &[&str] = &[
    "claude",
    "codex",
    "aider",
    "gemini",
    "cursor-agent",
    "opencode",
    "goose",
    "amp",
    "qwen",
    "crush",
    "copilot",
    "droid",
    "cline",
    "kiro-cli",
    "auggie",
];

const INTERPRETERS: &[&str] = &["node", "bun", "deno", "python", "python3"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DetectedAgent {
    pub pid: u32,
    pub name: String,
}

fn base_name(path: &str) -> String {
    let p = path
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
        .to_ascii_lowercase();
    p.strip_suffix(".exe").map(str::to_string).unwrap_or(p)
}

/// Pure matcher: executable name + argv → agent name.
pub fn matches(executable: &str, arguments: &[String], names: &HashSet<String>) -> Option<String> {
    let exe = base_name(executable);
    if names.contains(&exe) {
        return Some(exe);
    }
    if !(INTERPRETERS.contains(&exe.as_str()) || exe.starts_with("python")) {
        return None;
    }
    for arg in arguments
        .iter()
        .skip(1)
        .take(3)
        .filter(|a| !a.starts_with('-'))
    {
        let base = base_name(arg);
        let stem = base
            .rsplit_once('.')
            .map(|(s, _)| s.to_string())
            .unwrap_or(base.clone());
        if names.contains(&base) {
            return Some(base);
        }
        if names.contains(&stem) {
            return Some(stem);
        }
        let norm = arg.replace('\\', "/");
        if norm.contains("/claude-code/") {
            return Some("claude".into());
        }
        if norm.contains("/@openai/codex/") {
            return Some("codex".into());
        }
        if norm.contains("/gemini-cli/") {
            return Some("gemini".into());
        }
    }
    None
}

pub fn detect(extra: &[String]) -> Vec<DetectedAgent> {
    let mut names: HashSet<String> = BUILT_IN.iter().map(|s| s.to_string()).collect();
    names.extend(extra.iter().map(|s| s.to_ascii_lowercase()));
    let mut system = sysinfo::System::new();
    system.refresh_processes_specifics(
        sysinfo::ProcessesToUpdate::All,
        true,
        sysinfo::ProcessRefreshKind::nothing()
            .with_cmd(sysinfo::UpdateKind::Always)
            .with_exe(sysinfo::UpdateKind::Always)
            .with_user(sysinfo::UpdateKind::Always),
    );
    let me = sysinfo::get_current_pid().ok();
    let my_uid = me
        .and_then(|p| system.process(p))
        .and_then(|p| p.user_id().cloned());
    let mut found = Vec::new();
    for (pid, proc_) in system.processes() {
        if let (Some(mine), Some(theirs)) = (&my_uid, proc_.user_id()) {
            if mine != theirs {
                continue;
            }
        }
        let exe = proc_
            .exe()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| proc_.name().to_string_lossy().to_string());
        let args: Vec<String> = proc_
            .cmd()
            .iter()
            .map(|a| a.to_string_lossy().to_string())
            .collect();
        if let Some(name) = matches(&exe, &args, &names) {
            found.push(DetectedAgent {
                pid: pid.as_u32(),
                name,
            });
        }
    }
    found.sort_by(|a, b| (&a.name, a.pid).cmp(&(&b.name, b.pid)));
    found
}
