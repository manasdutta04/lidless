//! Battery, thermal and lid readings from sysfs and procfs.

use std::path::Path;

use lidless_core::floors::{BatteryReading, ThermalLevel};

fn read_trim(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
}

pub fn battery() -> BatteryReading {
    let Ok(entries) = std::fs::read_dir("/sys/class/power_supply") else {
        return BatteryReading::none();
    };
    let mut has_battery = false;
    let mut percent = None;
    let mut discharging = None;
    let mut mains_online = None;
    for entry in entries.flatten() {
        let p = entry.path();
        match read_trim(&p.join("type")).as_deref() {
            Some("Battery") => {
                // Ignore batteries that are not the system's (mice, keyboards).
                if read_trim(&p.join("scope")).as_deref() == Some("Device") {
                    continue;
                }
                has_battery = true;
                if percent.is_none() {
                    percent = read_trim(&p.join("capacity")).and_then(|v| v.parse::<i64>().ok());
                }
                if let Some(status) = read_trim(&p.join("status")) {
                    discharging = Some(status == "Discharging");
                }
            }
            Some("Mains") | Some("USB") => {
                if let Some(v) = read_trim(&p.join("online")) {
                    mains_online = Some(mains_online.unwrap_or(false) || v == "1");
                }
            }
            _ => {}
        }
    }
    if !has_battery {
        return BatteryReading::none();
    }
    let on_battery = match (mains_online, discharging) {
        (Some(online), _) => !online,
        (None, Some(d)) => d,
        (None, None) => false,
    };
    BatteryReading {
        has_battery: true,
        on_battery,
        percent,
    }
}

/// Hottest thermal zone, mapped to coarse levels. Thresholds are
/// conservative defaults for laptop package sensors.
pub fn thermal() -> ThermalLevel {
    let Ok(zones) = std::fs::read_dir("/sys/class/thermal") else {
        return ThermalLevel::Nominal;
    };
    let mut max_milli = 0i64;
    for z in zones.flatten() {
        let name = z.file_name().to_string_lossy().to_string();
        if !name.starts_with("thermal_zone") {
            continue;
        }
        if let Some(v) = read_trim(&z.path().join("temp")).and_then(|v| v.parse::<i64>().ok()) {
            max_milli = max_milli.max(v);
        }
    }
    match max_milli {
        t if t >= 95_000 => ThermalLevel::Critical,
        t if t >= 85_000 => ThermalLevel::Serious,
        t if t >= 75_000 => ThermalLevel::Fair,
        _ => ThermalLevel::Nominal,
    }
}

pub fn lid_closed() -> Option<bool> {
    let dir = std::fs::read_dir("/proc/acpi/button/lid").ok()?;
    for entry in dir.flatten() {
        if let Some(state) = read_trim(&entry.path().join("state")) {
            if state.contains("closed") {
                return Some(true);
            }
            if state.contains("open") {
                return Some(false);
            }
        }
    }
    None
}
