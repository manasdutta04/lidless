//! The `lidless` command (spec/cli.md), identical on every platform. The
//! platform binary passes its engine in.

use std::io::{BufRead, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use chrono::{Local, Utc};
use serde::Serialize;

use crate::agents;
use crate::control;
use crate::duration;
use crate::engine::{Elevation, Engine};
use crate::error::{LidlessError, Result};
use crate::history;
use crate::log;
use crate::model::{EndReason, OwnerKind};
use crate::notify::{DesktopNotifier, NoopNotifier, Notifier};
use crate::owner::{OwnerEnv, SessionOwner};
use crate::paths::Paths;
use crate::process::{ProcessInspector, SystemProcessInspector};
use crate::recovery;
use crate::status;
use crate::store::Store;
use crate::update;

pub const USAGE: &str = "lidless: keep your computer awake with the lid closed while your coding agents work.

Usage:
  lidless start <duration>               Start a session (e.g. 2h, 90m, 1d2h)
  lidless run [--duration <d>] -- <cmd>  Stay awake while <cmd> runs, then restore
  lidless extend <duration>              Add time to the current session
  lidless stop                           End the session and restore settings
  lidless status                         Show the current session and warnings
  lidless doctor                         Check that everything is set up
  lidless agents                         List detected coding agents
  lidless stats                          Your usage: time awake, closed-lid time, sessions
  lidless update                         Check GitHub for a newer release
  lidless config [<key> [<value>]]       Show or change settings
  lidless setup                          One-time setup: recovery job + lid-close permission
  lidless uninstall                      Restore settings and remove the job and permission
  lidless recover                        Run recovery once (the scheduled job does this every minute)
  lidless version

Add --json to any command for machine-readable output.
Use a ventilated surface while the lid is closed. Never put a running laptop in a bag.";

struct Ctx<'a> {
    engine: &'a dyn Engine,
    store: Store,
    inspector: SystemProcessInspector,
    json: bool,
}

impl<'a> Ctx<'a> {
    fn say(&self, s: &str) {
        if self.json {
            eprintln!("{s}");
        } else {
            println!("{s}");
        }
    }

    fn emit<T: Serialize>(&self, value: &T) {
        if self.json {
            println!(
                "{}",
                serde_json::to_string_pretty(value).unwrap_or_default()
            );
        }
    }

    fn fail(&self, e: &LidlessError) -> i32 {
        if self.json {
            self.emit(&ErrorJson {
                ok: false,
                error: e.to_string(),
                code: e.exit_code(),
            });
        } else {
            eprintln!("lidless: {e}");
        }
        e.exit_code()
    }
}

#[derive(Serialize)]
struct ErrorJson {
    ok: bool,
    error: String,
    code: i32,
}

fn time_string(t: chrono::DateTime<Utc>) -> String {
    let local = t.with_timezone(&Local);
    if local.date_naive() == Local::now().date_naive() {
        local.format("%H:%M").to_string()
    } else {
        local.format("%b %-d, %H:%M").to_string()
    }
}

/// Entry point for the platform binaries. Returns the exit code.
pub fn run(engine: &dyn Engine, raw_args: Vec<String>) -> i32 {
    let mut args = raw_args;
    let sep = args.iter().position(|a| a == "--").unwrap_or(args.len());
    let json = args[..sep].iter().any(|a| a == "--json");
    if json {
        let i = args[..sep].iter().position(|a| a == "--json").unwrap();
        args.remove(i);
    }
    let paths = Paths::resolve();
    log::configure(paths.log(), false);
    let ctx = Ctx {
        engine,
        store: Store::new(paths),
        inspector: SystemProcessInspector,
        json,
    };

    let Some(command) = args.first().cloned() else {
        println!("{USAGE}");
        return 2;
    };
    let rest: Vec<String> = args[1..].to_vec();
    let result: std::result::Result<i32, LidlessError> = match command.as_str() {
        "start" => cmd_start(&ctx, &rest),
        "_hold" => cmd_hold(&ctx, &rest),
        "run" => cmd_run(&ctx, &rest),
        "extend" => cmd_extend(&ctx, &rest),
        "stop" => cmd_stop(&ctx),
        "status" => cmd_status(&ctx),
        "doctor" => cmd_doctor(&ctx),
        "recover" => cmd_recover(&ctx),
        "agents" => cmd_agents(&ctx),
        "stats" => cmd_stats(&ctx),
        "update" => cmd_update(&ctx),
        "config" => cmd_config(&ctx, &rest),
        "setup" | "install" => cmd_setup(&ctx),
        "uninstall" => cmd_uninstall(&ctx),
        "version" | "--version" | "-v" => {
            println!("lidless {}", update::VERSION);
            Ok(0)
        }
        "help" | "--help" | "-h" => {
            println!("{USAGE}");
            Ok(0)
        }
        other => {
            eprintln!("lidless: unknown command {other}\n\n{USAGE}");
            Ok(2)
        }
    };
    match result {
        Ok(code) => code,
        Err(e) => ctx.fail(&e),
    }
}

fn warn_if_warm(ctx: &Ctx) {
    let heat = ctx.engine.thermal();
    if heat.is_warm() && heat != crate::floors::ThermalLevel::Critical {
        if let Some(w) = heat.start_warning() {
            eprintln!("lidless: ⚠︎ {w}");
        }
    }
}

fn self_exe() -> Result<std::path::PathBuf> {
    std::env::current_exe()
        .map_err(|e| LidlessError::system("Cannot find the lidless executable", e))
}

// MARK: start / _hold

#[derive(Serialize)]
struct StartedJson {
    ok: bool,
    session: crate::model::Session,
}

fn cmd_start(ctx: &Ctx, args: &[String]) -> Result<i32> {
    if args.len() != 1 {
        return Err(LidlessError::Usage(
            "Usage: lidless start <duration>".into(),
        ));
    }
    let seconds = duration::parse(&args[0])?;
    warn_if_warm(ctx);
    ctx.say("Engaging and verifying (this takes a few seconds)…");
    let _ = std::io::stdout().flush();

    let mut cmd = Command::new(self_exe()?);
    cmd.arg("_hold").arg("--seconds").arg(seconds.to_string());
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    detach(&mut cmd);
    let mut child = cmd
        .spawn()
        .map_err(|e| LidlessError::system("Could not start the session process", e))?;
    let stdout = child.stdout.take().unwrap();
    let mut line = String::new();
    std::io::BufReader::new(stdout).read_line(&mut line).ok();
    let obj: serde_json::Value =
        serde_json::from_str(line.trim()).unwrap_or(serde_json::Value::Null);
    if obj["ok"].as_bool() == Some(true) {
        if let crate::store::SessionRead::Some(s) = ctx.store.read_session() {
            ctx.emit(&StartedJson {
                ok: true,
                session: s.clone(),
            });
            ctx.say(&format!(
                "Lidless is on until {} ({}). You can close the lid.",
                time_string(s.ends_at),
                duration::format(s.remaining(Utc::now()))
            ));
            ctx.say("Stop with `lidless stop`, add time with `lidless extend 1h`. Keep the computer on a ventilated surface.");
        }
        return Ok(0);
    }
    let code = obj["code"].as_i64().unwrap_or(1) as i32;
    let message = obj["error"]
        .as_str()
        .unwrap_or("The session process exited without reporting. See the log.")
        .to_string();
    if ctx.json {
        ctx.emit(&ErrorJson {
            ok: false,
            error: message,
            code,
        });
    } else {
        eprintln!("lidless: {message}");
    }
    Ok(code)
}

#[cfg(unix)]
fn detach(cmd: &mut Command) {
    use std::os::unix::process::CommandExt;
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            libc::signal(libc::SIGHUP, libc::SIG_IGN);
            Ok(())
        });
    }
}

#[cfg(windows)]
fn detach(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
}

fn install_stop_flag() -> Arc<AtomicBool> {
    let flag = Arc::new(AtomicBool::new(false));
    let f = flag.clone();
    let _ = ctrlc::set_handler(move || f.store(true, Ordering::SeqCst));
    flag
}

/// Hidden: the detached session holder started by `lidless start`.
fn cmd_hold(ctx: &Ctx, args: &[String]) -> Result<i32> {
    let seconds: f64 = match args {
        [flag, v] if flag == "--seconds" => v
            .parse()
            .map_err(|_| LidlessError::Usage("bad --seconds".into()))?,
        _ => return Ok(2),
    };
    let notifier = DesktopNotifier;
    let env = OwnerEnv::live(ctx.engine, ctx.store.clone(), &ctx.inspector, &notifier);
    let mut owner = SessionOwner::new(env);
    let report = |obj: serde_json::Value| {
        println!("{obj}");
        let _ = std::io::stdout().flush();
    };
    if let Err(e) = owner.start(seconds, OwnerKind::Cli, None) {
        report(serde_json::json!({"ok": false, "error": e.to_string(), "code": e.exit_code()}));
        return Ok(e.exit_code());
    }
    report(serde_json::json!({"ok": true}));
    let stop = install_stop_flag();
    let le = owner.run_until_end(&stop, || None);
    Ok(if le.restore_complete { 0 } else { 7 })
}

// MARK: run

fn cmd_run(ctx: &Ctx, args: &[String]) -> Result<i32> {
    let usage =
        || LidlessError::Usage("Usage: lidless run [--duration <d>] -- <command> [args...]".into());
    let mut rest = args.to_vec();
    let mut dur = ctx.store.read_config().run_default_duration_seconds;
    while let Some(first) = rest.first().cloned() {
        if first == "--" {
            break;
        }
        rest.remove(0);
        if first == "--duration" || first == "-d" {
            let v = rest.first().cloned().ok_or_else(usage)?;
            rest.remove(0);
            dur = duration::parse(&v)? as f64;
        } else if let Some(v) = first.strip_prefix("--duration=") {
            dur = duration::parse(v)? as f64;
        } else {
            return Err(usage());
        }
    }
    if rest.first().map(String::as_str) != Some("--") || rest.len() < 2 {
        return Err(usage());
    }
    let command: Vec<String> = rest[1..].to_vec();

    let notifier = DesktopNotifier;
    let env = OwnerEnv::live(ctx.engine, ctx.store.clone(), &ctx.inspector, &notifier);
    let mut owner = SessionOwner::new(env);
    warn_if_warm(ctx);
    eprintln!("lidless: engaging and verifying…");
    let session = owner.start(dur, OwnerKind::Run, Some(command.clone()))?; // not run if the session cannot start
    eprintln!(
        "lidless: awake until {} or until `{}` exits. You can close the lid.",
        time_string(session.ends_at),
        command.join(" ")
    );

    let mut child = match Command::new(&command[0]).args(&command[1..]).spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("lidless: could not run {}: {e}", command[0]);
            owner.end(
                EndReason::CommandExited,
                Some("The command could not be started.".into()),
            );
            return Ok(127);
        }
    };
    // Ctrl-C goes to the child (same console/process group); we just wait.
    let stop = install_stop_flag();
    let _ = &stop;
    let mut exit_code = 0;
    let mut exited = false;
    let le = owner.run_until_end(&AtomicBool::new(false), || {
        if exited {
            return Some(EndReason::CommandExited);
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                exited = true;
                exit_code = exit_status_code(&status);
                Some(EndReason::CommandExited)
            }
            _ => None,
        }
    });
    if !exited {
        // The session ended first (expiry, floor, stop): the command keeps running.
        eprintln!(
            "lidless: the awake session ended ({}); `{}` is still running.",
            le.reason.summary(),
            command[0]
        );
        let status = child.wait()?;
        exit_code = exit_status_code(&status);
    } else if !le.restore_complete {
        eprintln!(
            "lidless: {}; the recovery job will retry.",
            le.detail
                .clone()
                .unwrap_or_else(|| "restore incomplete".into())
        );
    }
    eprintln!("lidless: normal sleep restored.");
    Ok(exit_code)
}

#[cfg(unix)]
fn exit_status_code(status: &std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

#[cfg(not(unix))]
fn exit_status_code(status: &std::process::ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

// MARK: extend / stop

#[derive(Serialize)]
struct ExtendedJson {
    ok: bool,
    session: crate::model::Session,
    clamped: bool,
}

fn cmd_extend(ctx: &Ctx, args: &[String]) -> Result<i32> {
    if args.len() != 1 {
        return Err(LidlessError::Usage(
            "Usage: lidless extend <duration>".into(),
        ));
    }
    let seconds = duration::parse(&args[0])? as f64;
    let (s, clamped) = control::extend(&ctx.store, seconds, Utc::now())?;
    ctx.emit(&ExtendedJson {
        ok: true,
        session: s.clone(),
        clamped,
    });
    ctx.say(&format!(
        "Session now ends at {} ({} left){}.",
        time_string(s.ends_at),
        duration::format(s.remaining(Utc::now())),
        if clamped {
            ", capped at the maximum session length"
        } else {
            ""
        }
    ));
    Ok(0)
}

#[derive(Serialize)]
struct StoppedJson {
    ok: bool,
    #[serde(rename = "lastEnd")]
    last_end: Option<crate::model::LastEnd>,
    message: String,
}

fn cmd_stop(ctx: &Ctx) -> Result<i32> {
    match control::request_stop(&ctx.store, &ctx.inspector, "user")? {
        control::StopRequest::Requested(id) => {
            ctx.say("Stopping…");
            let Some(le) =
                control::wait_for_end(&ctx.store, id, std::time::Duration::from_secs(45))
            else {
                return Err(LidlessError::System(
                    "The session owner did not finish within 45 s. Check `lidless status`; the recovery job will finish the job.".into(),
                ));
            };
            let ok = le.restore_complete;
            ctx.emit(&StoppedJson {
                ok,
                last_end: Some(le.clone()),
                message: if ok {
                    "Stopped.".into()
                } else {
                    le.detail.clone().unwrap_or_default()
                },
            });
            if ok {
                ctx.say("Stopped. Normal sleep is back.");
                Ok(0)
            } else {
                ctx.say(&format!(
                    "Stopped, but not everything was restored: {}",
                    le.detail.unwrap_or_default()
                ));
                Ok(7)
            }
        }
        control::StopRequest::OwnerDead(_) => {
            let outcome = recovery::run(
                ctx.engine,
                &ctx.store,
                &ctx.inspector,
                Utc::now(),
                Some(EndReason::Stopped),
            );
            ctx.emit(&StoppedJson {
                ok: outcome.report.complete(),
                last_end: ctx.store.read_last_end(),
                message: outcome.message.clone(),
            });
            ctx.say(&outcome.message);
            Ok(if outcome.report.complete() { 0 } else { 7 })
        }
    }
}

// MARK: status / doctor / recover

fn cmd_status(ctx: &Ctx) -> Result<i32> {
    let ready = ctx.engine.readiness();
    let snap = status::collect(
        ctx.engine,
        &ctx.store,
        &ctx.inspector,
        Some(ready),
        Utc::now(),
    );
    if ctx.json {
        ctx.emit(&snap);
        return Ok(0);
    }
    if let Some(s) = &snap.session {
        println!(
            "● Active: ends at {} ({} left)",
            time_string(s.ends_at),
            duration::clock(s.remaining_seconds as f64)
        );
        let owner = match s.owner.kind {
            OwnerKind::App => "tray app",
            OwnerKind::Run => "lidless run",
            OwnerKind::Cli => "lidless start",
        };
        println!(
            "  Owner: {owner}, pid {}{}",
            s.owner.pid,
            if s.owner.alive { "" } else { " (gone)" }
        );
        if let Some(cmd) = &s.command {
            println!("  Command: {}", cmd.join(" "));
        }
        if s.stop_requested.is_some() {
            println!("  Stopping…");
        }
    } else {
        println!("○ No active session");
        if let Some(le) = &snap.last_end {
            println!(
                "  Last session ended {}: {}{}",
                time_string(le.at),
                le.reason.summary(),
                if le.restore_complete {
                    ""
                } else {
                    " (restore incomplete)"
                }
            );
        }
    }
    if let Some(lid) = snap.lid_closed {
        println!("  Lid: {}", if lid { "closed" } else { "open" });
    }
    let p = &snap.power;
    if p.has_battery {
        println!(
            "  Power: {}{}, thermal {}",
            if p.on_battery { "battery" } else { "AC" },
            p.percent.map(|v| format!(", {v}%")).unwrap_or_default(),
            p.thermal.raw()
        );
    } else {
        println!("  Power: AC, thermal {}", p.thermal.raw());
    }
    if snap.journal.sleep_disabled || snap.journal.low_power_mode {
        let mut changed = Vec::new();
        if snap.journal.sleep_disabled {
            changed.push("closed-lid sleep off");
        }
        if snap.journal.low_power_mode {
            changed.push("low-power mode on");
        }
        println!(
            "  Changed by Lidless (will be restored): {}",
            changed.join(", ")
        );
    }
    for w in &snap.warnings {
        println!("  ⚠︎ {w}");
    }
    Ok(0)
}

#[derive(Serialize)]
struct DoctorCheck {
    name: String,
    ok: bool,
    detail: String,
}

#[derive(Serialize)]
struct DoctorJson {
    ok: bool,
    checks: Vec<DoctorCheck>,
}

fn cmd_doctor(ctx: &Ctx) -> Result<i32> {
    let mut checks = Vec::new();
    let ready = ctx.engine.readiness();
    checks.push(DoctorCheck {
        name: "privilege".into(),
        ok: ready.privilege,
        detail: if ready.privilege {
            "lid-close setting can be changed".into()
        } else {
            format!("not set up; {}", ctx.engine.fix_hint())
        },
    });
    checks.push(DoctorCheck {
        name: "recovery job".into(),
        ok: ready.recovery_armed,
        detail: ready.recovery_detail.clone(),
    });

    let home = &ctx.store.paths.home;
    let home_ok = ctx.store.paths.ensure_home().is_ok();
    checks.push(DoctorCheck {
        name: "state directory".into(),
        ok: home_ok,
        detail: home.display().to_string(),
    });

    match ctx.store.read_journal() {
        Ok(j) => checks.push(DoctorCheck {
            name: "journal".into(),
            ok: true,
            detail: if j.is_empty() {
                "clean".into()
            } else {
                "has entries waiting to be restored".into()
            },
        }),
        Err(e) => checks.push(DoctorCheck {
            name: "journal".into(),
            ok: false,
            detail: e.to_string(),
        }),
    }
    match ctx.engine.verify() {
        Ok(v) => checks.push(DoctorCheck {
            name: "closed-lid setting".into(),
            ok: true,
            detail: if v { "closed-lid sleep is currently OFF (a session is active, or something else changed it)".into() } else { "normal".into() },
        }),
        Err(e) => checks.push(DoctorCheck { name: "closed-lid setting".into(), ok: false, detail: e.to_string() }),
    }
    let b = ctx.engine.battery();
    checks.push(DoctorCheck {
        name: "power".into(),
        ok: true,
        detail: if b.has_battery {
            format!(
                "{}{}",
                if b.on_battery { "on battery" } else { "on AC" },
                b.percent
                    .map(|p| format!(", {p}%"))
                    .unwrap_or_else(|| ", level unreadable".into())
            )
        } else {
            "no battery".into()
        },
    });
    checks.push(DoctorCheck {
        name: "thermal".into(),
        ok: true,
        detail: ctx.engine.thermal().raw().into(),
    });
    let found = agents::detect(&ctx.store.read_config().extra_agent_names);
    checks.push(DoctorCheck {
        name: "agents".into(),
        ok: true,
        detail: if found.is_empty() {
            "none running".into()
        } else {
            found
                .iter()
                .map(|a| format!("{} ({})", a.name, a.pid))
                .collect::<Vec<_>>()
                .join(", ")
        },
    });
    checks.push(DoctorCheck {
        name: "platform".into(),
        ok: true,
        detail: format!("{} {}", std::env::consts::OS, std::env::consts::ARCH),
    });
    checks.push(DoctorCheck {
        name: "elevated operations".into(),
        ok: true,
        detail: ctx.engine.privileged_operations().join("; "),
    });

    let ok = ready.ready() && home_ok;
    if ctx.json {
        ctx.emit(&DoctorJson { ok, checks });
    } else {
        for c in &checks {
            println!("{} {}: {}", if c.ok { "✓" } else { "✗" }, c.name, c.detail);
        }
        println!(
            "{}",
            if ok {
                "\nReady: sessions can start."
            } else {
                "\nNot ready: fix the ✗ items above."
            }
        );
    }
    Ok(if ok { 0 } else { 3 })
}

#[derive(Serialize)]
struct RecoverJson {
    ok: bool,
    message: String,
}

fn cmd_recover(ctx: &Ctx) -> Result<i32> {
    let outcome = recovery::run(ctx.engine, &ctx.store, &ctx.inspector, Utc::now(), None);
    ctx.emit(&RecoverJson {
        ok: outcome.report.complete(),
        message: outcome.message.clone(),
    });
    if !ctx.json && outcome.action != recovery::RecoveryAction::Nothing {
        println!("{}", outcome.message);
    }
    if let recovery::RecoveryAction::EndSession(reason) = outcome.action {
        if reason != EndReason::Stopped {
            DesktopNotifier.notify(
                "Lidless session ended",
                &format!(
                    "{} {}",
                    reason.summary(),
                    if outcome.report.complete() {
                        "Normal sleep is back."
                    } else {
                        "Some settings could not be restored yet."
                    }
                ),
            );
        }
    }
    Ok(if outcome.report.complete() { 0 } else { 7 })
}

// MARK: agents / stats / update / config

fn cmd_agents(ctx: &Ctx) -> Result<i32> {
    let found = agents::detect(&ctx.store.read_config().extra_agent_names);
    if ctx.json {
        ctx.emit(&found);
    } else if found.is_empty() {
        println!("No coding agents detected.");
    } else {
        for a in found {
            println!("{}\tpid {}", a.name, a.pid);
        }
    }
    Ok(0)
}

fn cmd_stats(ctx: &Ctx) -> Result<i32> {
    let stats = history::compute(&history::read(&ctx.store), Utc::now());
    if ctx.json {
        ctx.emit(&stats);
        return Ok(0);
    }
    if stats.sessions == 0 {
        println!("No sessions yet. Start one with: lidless start 2h");
        return Ok(0);
    }
    let f = duration::format;
    println!("Sessions             {}", stats.sessions);
    println!("Time awake           {}", f(stats.total_awake_seconds));
    println!("With the lid closed  {}", f(stats.closed_lid_seconds));
    println!("This week            {}", f(stats.this_week_seconds));
    println!("Longest session      {}", f(stats.longest_seconds));
    println!("Average session      {}", f(stats.average_seconds));
    if let Some(p) = stats.clean_restore_percent {
        println!("Restored cleanly     {p}%");
    }
    if stats.ended_by_safety > 0 {
        println!("Ended by safety      {}", stats.ended_by_safety);
    }
    Ok(0)
}

#[derive(Serialize)]
struct UpdateJson {
    current: String,
    latest: Option<String>,
    #[serde(rename = "updateAvailable")]
    update_available: bool,
    #[serde(rename = "downloadURL")]
    download_url: Option<String>,
    #[serde(rename = "pageURL")]
    page_url: Option<String>,
}

fn cmd_update(ctx: &Ctx) -> Result<i32> {
    let current = update::VERSION.to_string();
    match update::check(&current)? {
        update::UpdateCheck::NoReleases => {
            ctx.emit(&UpdateJson {
                current: current.clone(),
                latest: None,
                update_available: false,
                download_url: None,
                page_url: None,
            });
            ctx.say(&format!(
                "Lidless {current}. No releases have been published yet."
            ));
        }
        update::UpdateCheck::UpToDate(latest) => {
            ctx.emit(&UpdateJson {
                current: current.clone(),
                latest: Some(latest),
                update_available: false,
                download_url: None,
                page_url: None,
            });
            ctx.say(&format!("Lidless {current} is up to date."));
        }
        update::UpdateCheck::Available(r) => {
            ctx.emit(&UpdateJson {
                current: current.clone(),
                latest: Some(r.version.clone()),
                update_available: true,
                download_url: r.download_url.clone(),
                page_url: Some(r.page_url.clone()),
            });
            ctx.say(&format!(
                "Lidless {} is available (you have {current}).",
                r.version
            ));
            ctx.say(&format!(
                "Download: {}",
                r.download_url.clone().unwrap_or(r.page_url.clone())
            ));
        }
    }
    Ok(0)
}

fn cmd_config(ctx: &Ctx, args: &[String]) -> Result<i32> {
    let config = ctx.store.read_config();
    let mut value = serde_json::to_value(&config)?;
    let map = value.as_object_mut().unwrap();
    let keys = || {
        let mut k: Vec<String> = serde_json::to_value(Config::default())
            .unwrap()
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        k.sort();
        k.join(", ")
    };
    match args {
        [] => {
            println!("{}", serde_json::to_string_pretty(&config)?);
        }
        [key] => {
            let v = map.get(key).ok_or_else(|| {
                LidlessError::Usage(format!("Unknown key {key}. Keys: {}", keys()))
            })?;
            println!("{v}");
        }
        [key, raw] => {
            let current = map.get(key).cloned().ok_or_else(|| {
                LidlessError::Usage(format!("Unknown key {key}. Keys: {}", keys()))
            })?;
            let new_value = match current {
                serde_json::Value::Array(_) => serde_json::Value::Array(
                    raw.split(',')
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(|s| serde_json::Value::String(s.into()))
                        .collect(),
                ),
                serde_json::Value::Bool(_) => {
                    serde_json::Value::Bool(match raw.to_ascii_lowercase().as_str() {
                        "true" | "yes" | "on" | "1" => true,
                        "false" | "no" | "off" | "0" => false,
                        _ => {
                            return Err(LidlessError::Usage(format!("{key} takes true or false.")))
                        }
                    })
                }
                serde_json::Value::Number(n) if n.is_i64() => {
                    let v = raw
                        .parse::<i64>()
                        .map_err(|_| LidlessError::Usage(format!("{key} takes a whole number.")))?;
                    serde_json::json!(v)
                }
                serde_json::Value::Number(_) => {
                    let n = if key.ends_with("Seconds") {
                        duration::parse(raw).map(|s| s as f64).or_else(|_| {
                            raw.parse::<f64>().map_err(|_| {
                                LidlessError::Usage(format!(
                                    "{key} takes a number or a duration like 2h."
                                ))
                            })
                        })?
                    } else {
                        raw.parse::<f64>()
                            .map_err(|_| LidlessError::Usage(format!("{key} takes a number.")))?
                    };
                    serde_json::json!(n)
                }
                _ => serde_json::Value::String(raw.clone()),
            };
            map.insert(key.clone(), new_value);
            let updated: Config = serde_json::from_value(serde_json::Value::Object(map.clone()))?;
            ctx.store.write_config(&updated)?;
            let saved = serde_json::to_value(ctx.store.read_config())?;
            println!("{key} = {}", saved[key]);
        }
        _ => {
            return Err(LidlessError::Usage(
                "Usage: lidless config [<key> [<value>]]".into(),
            ))
        }
    }
    Ok(0)
}

use crate::model::Config;

// MARK: setup / uninstall

#[derive(Serialize)]
struct InstallerJson {
    ok: bool,
    steps: Vec<String>,
}

fn cmd_setup(ctx: &Ctx) -> Result<i32> {
    let cli = self_exe()?;
    ctx.say("Setting up Lidless.");
    let steps = ctx.engine.install(&cli, Elevation::TerminalSudo)?;
    ctx.emit(&InstallerJson {
        ok: true,
        steps: steps.clone(),
    });
    for s in &steps {
        ctx.say(&format!("✓ {s}"));
    }
    let ready = ctx.engine.readiness();
    if ready.ready() {
        ctx.say("Ready. Try: lidless start 2h  (keep the computer on a ventilated surface)");
        Ok(0)
    } else {
        Err(ready
            .not_ready_error(&ctx.engine.fix_hint())
            .unwrap_or(LidlessError::NotReady("Setup did not complete.".into())))
    }
}

fn cmd_uninstall(ctx: &Ctx) -> Result<i32> {
    if let crate::store::SessionRead::Some(s) = ctx.store.read_session() {
        if ctx.inspector.is_alive(&s.owner) {
            return Err(LidlessError::SessionActive);
        }
    }
    let outcome = recovery::run(
        ctx.engine,
        &ctx.store,
        &ctx.inspector,
        Utc::now(),
        Some(EndReason::Stopped),
    );
    if !outcome.report.complete() || !ctx.store.read_journal()?.is_empty() {
        return Err(LidlessError::RestoreIncomplete(format!(
            "Settings are still waiting to be restored, so Lidless was not removed: {}",
            outcome.message
        )));
    }
    let steps = ctx.engine.uninstall(Elevation::TerminalSudo)?;
    ctx.emit(&InstallerJson {
        ok: true,
        steps: steps.clone(),
    });
    for s in &steps {
        ctx.say(&format!("✓ {s}"));
    }
    ctx.say(&format!(
        "Your state and logs stay in {}.",
        ctx.store.paths.home.display()
    ));
    let _ = NoopNotifier;
    Ok(0)
}
