//! Lidless engine for Linux.
//!
//! How it keeps the machine awake with the lid closed: a systemd-logind
//! inhibitor lock for `handle-lid-switch`, `sleep` and `idle` in `block`
//! mode, held for the life of the session. The kernel closes the lock's
//! file descriptor when the owning process exits, so a crash can never leave
//! it behind, and nothing in `logind.conf` is edited. The power profile
//! (power-profiles-daemon) is the only journaled change.
//!
//! Open question (CLAUDE.md §13): desktops that handle the lid themselves
//! (notably GNOME's settings daemon) may not honour a logind inhibitor.
//! `verify()` confirms logind lists the lock; a desktop that bypasses logind
//! shows up as the Mac sleeping anyway, which the real-machine checklist in
//! docs/release-validation.md is for.

#![cfg_attr(
    not(target_os = "linux"),
    allow(dead_code, unused_imports, unused_variables)
)]

mod sensors;
mod systemd;

use std::path::Path;
use std::process::{Command, Stdio};

use chrono::{DateTime, Utc};
use lidless_core::engine::{AwakeHold, Elevation, Engine, ReadinessReport, RestoreReport};
use lidless_core::error::{LidlessError, Result};
use lidless_core::floors::{BatteryReading, ThermalLevel};
use lidless_core::log;
use lidless_core::model::StringEntry;
use lidless_core::store::Store;

pub const INHIBIT_WHAT: &str = "handle-lid-switch:sleep:idle";
pub const INHIBIT_WHO: &str = "Lidless";
pub const POWER_SAVER: &str = "power-saver";

#[derive(Default)]
pub struct LinuxEngine;

impl LinuxEngine {
    pub fn new() -> Self {
        LinuxEngine
    }
}

impl Engine for LinuxEngine {
    fn platform(&self) -> &'static str {
        "linux"
    }

    fn fix_hint(&self) -> String {
        "Run `lidless setup` (it installs a systemd user timer; no root needed), or click Set Up in the Lidless app.".into()
    }

    fn engage(&self, _store: &Store, _now: DateTime<Utc>) -> Result<Box<dyn AwakeHold>> {
        let hold = dbus::inhibit(
            "Keeping this computer awake with the lid closed so your agents keep working",
        )?;
        log::info("logind inhibitor taken (handle-lid-switch, sleep, idle)");
        Ok(Box::new(hold))
    }

    fn verify(&self) -> Result<bool> {
        dbus::has_our_inhibitor()
    }

    fn restore_all_locked(&self, store: &Store, now: DateTime<Utc>) -> RestoreReport {
        let mut report = RestoreReport::default();
        match self.release_low_power(store, now) {
            Ok(r) => report.merge(r),
            Err(e) => report.failures.push(e.to_string()),
        }
        report
    }

    fn enable_low_power(&self, store: &Store, now: DateTime<Utc>) -> Result<bool> {
        let mut journal = store.read_journal()?;
        if journal.linux.power_profile.is_some() {
            return Ok(true);
        }
        let Some(current) = dbus::active_power_profile() else {
            return Ok(false);
        };
        if current == POWER_SAVER {
            return Ok(false);
        }
        // Hard rule 1: journal first.
        journal.linux.power_profile = Some(StringEntry {
            original: current.clone(),
            recorded_at: now,
        });
        store.write_journal(&journal, now)?;
        log::info(&format!(
            "journaled powerProfile(original={current}); setting {POWER_SAVER}"
        ));
        dbus::set_power_profile(POWER_SAVER)?;
        Ok(true)
    }

    fn release_low_power(&self, store: &Store, now: DateTime<Utc>) -> Result<RestoreReport> {
        let mut report = RestoreReport::default();
        let mut journal = store.read_journal()?;
        let Some(entry) = journal.linux.power_profile.clone() else {
            return Ok(report);
        };
        if dbus::active_power_profile().as_deref() == Some(entry.original.as_str()) {
            journal.linux.power_profile = None;
            store.write_journal(&journal, now)?;
            report
                .restored
                .push("powerProfile (already original)".into());
            return Ok(report);
        }
        match dbus::set_power_profile(&entry.original) {
            Ok(()) => {
                journal.linux.power_profile = None;
                store.write_journal(&journal, now)?;
                report
                    .restored
                    .push(format!("powerProfile → {}", entry.original));
                log::info(&format!("restored power profile to {}", entry.original));
            }
            Err(e) => {
                let msg = format!(
                    "Could not restore the power profile to {}: {e}",
                    entry.original
                );
                log::error(&msg);
                report.failures.push(msg);
            }
        }
        Ok(report)
    }

    fn display_off(&self) {
        // X11 first, then the GNOME/KDE screensaver interfaces. Failures are
        // fine: the desktop's own lid handling usually blanks the panel.
        if std::env::var_os("DISPLAY").is_some() {
            let _ = Command::new("xset")
                .args(["dpms", "force", "off"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        dbus::screensaver_activate();
    }

    fn battery(&self) -> BatteryReading {
        sensors::battery()
    }

    fn thermal(&self) -> ThermalLevel {
        sensors::thermal()
    }

    fn lid_closed(&self) -> Option<bool> {
        sensors::lid_closed()
    }

    fn readiness(&self) -> ReadinessReport {
        let (armed, detail) = systemd::recovery_status();
        ReadinessReport {
            privilege: dbus::can_inhibit(),
            recovery_armed: armed,
            recovery_detail: detail,
        }
    }

    fn install(&self, cli_path: &Path, _elevation: Elevation) -> Result<Vec<String>> {
        let mut steps = systemd::install(cli_path)?;
        if !dbus::can_inhibit() {
            return Err(LidlessError::NotReady(
                "logind refused a lid-switch inhibitor for this session. Lidless needs an active local login session (polkit action org.freedesktop.login1.inhibit-handle-lid-switch).".into(),
            ));
        }
        steps.push("logind allows this session to inhibit lid handling".into());
        Ok(steps)
    }

    fn uninstall(&self, _elevation: Elevation) -> Result<Vec<String>> {
        systemd::uninstall()
    }

    fn privileged_operations(&self) -> Vec<String> {
        vec!["None. The logind inhibitor and the systemd user timer both run as your user; nothing runs as root.".into()]
    }
}

#[cfg(target_os = "linux")]
mod dbus {
    use super::*;
    use std::os::fd::OwnedFd;
    use zbus::blocking::{Connection, Proxy};
    use zbus::zvariant::OwnedFd as ZOwnedFd;

    pub struct Inhibitor(#[allow(dead_code)] OwnedFd);
    impl AwakeHold for Inhibitor {}

    fn login1(conn: &Connection) -> Result<Proxy<'_>> {
        Proxy::new(
            conn,
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
        )
        .map_err(|e| LidlessError::System(format!("logind: {e}")))
    }

    pub fn inhibit(reason: &str) -> Result<Inhibitor> {
        let conn =
            Connection::system().map_err(|e| LidlessError::System(format!("system bus: {e}")))?;
        let proxy = login1(&conn)?;
        let fd: ZOwnedFd = proxy
            .call("Inhibit", &(INHIBIT_WHAT, INHIBIT_WHO, reason, "block"))
            .map_err(|e| LidlessError::NotReady(format!("logind refused the inhibitor: {e}")))?;
        Ok(Inhibitor(fd.into()))
    }

    pub fn has_our_inhibitor() -> Result<bool> {
        let conn =
            Connection::system().map_err(|e| LidlessError::System(format!("system bus: {e}")))?;
        let proxy = login1(&conn)?;
        let list: Vec<(String, String, String, String, u32, u32)> = proxy
            .call("ListInhibitors", &())
            .map_err(|e| LidlessError::System(format!("ListInhibitors: {e}")))?;
        let me = std::process::id();
        Ok(list.iter().any(|(what, who, _, mode, _, pid)| {
            who == INHIBIT_WHO
                && mode == "block"
                && what.contains("handle-lid-switch")
                && *pid == me
        }))
    }

    /// Takes and immediately releases a test inhibitor.
    pub fn can_inhibit() -> bool {
        inhibit("Lidless setup check").is_ok()
    }

    fn profiles(conn: &Connection) -> Option<Proxy<'_>> {
        for (dest, path, iface) in [
            (
                "org.freedesktop.UPower.PowerProfiles",
                "/org/freedesktop/UPower/PowerProfiles",
                "org.freedesktop.UPower.PowerProfiles",
            ),
            (
                "net.hadess.PowerProfiles",
                "/net/hadess/PowerProfiles",
                "net.hadess.PowerProfiles",
            ),
        ] {
            if let Ok(p) = Proxy::new(conn, dest, path, iface) {
                if p.get_property::<String>("ActiveProfile").is_ok() {
                    return Some(p);
                }
            }
        }
        None
    }

    pub fn active_power_profile() -> Option<String> {
        let conn = Connection::system().ok()?;
        let proxy = profiles(&conn)?;
        proxy.get_property::<String>("ActiveProfile").ok()
    }

    pub fn set_power_profile(profile: &str) -> Result<()> {
        let conn =
            Connection::system().map_err(|e| LidlessError::System(format!("system bus: {e}")))?;
        let proxy = profiles(&conn)
            .ok_or_else(|| LidlessError::System("power-profiles-daemon is not running".into()))?;
        proxy
            .set_property("ActiveProfile", profile)
            .map_err(|e| LidlessError::System(format!("Could not set the power profile: {e}")))
    }

    pub fn screensaver_activate() {
        let Ok(conn) = Connection::session() else {
            return;
        };
        for (dest, path, iface) in [
            (
                "org.gnome.ScreenSaver",
                "/org/gnome/ScreenSaver",
                "org.gnome.ScreenSaver",
            ),
            (
                "org.freedesktop.ScreenSaver",
                "/org/freedesktop/ScreenSaver",
                "org.freedesktop.ScreenSaver",
            ),
        ] {
            if let Ok(p) = Proxy::new(&conn, dest, path, iface) {
                if p.call::<_, _, ()>("SetActive", &(true,)).is_ok() {
                    return;
                }
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod dbus {
    use super::*;
    const UNAVAILABLE: &str = "systemd-logind is not available on this platform.";
    pub struct Inhibitor;
    impl AwakeHold for Inhibitor {}
    pub fn inhibit(_reason: &str) -> Result<Inhibitor> {
        Err(LidlessError::System(UNAVAILABLE.into()))
    }
    pub fn has_our_inhibitor() -> Result<bool> {
        Err(LidlessError::System(UNAVAILABLE.into()))
    }
    pub fn can_inhibit() -> bool {
        false
    }
    pub fn active_power_profile() -> Option<String> {
        None
    }
    pub fn set_power_profile(_profile: &str) -> Result<()> {
        Err(LidlessError::System(UNAVAILABLE.into()))
    }
    pub fn screensaver_activate() {}
}
