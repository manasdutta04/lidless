//! Battery and thermal safety floors (spec/floors.md), pure and vector-tested.

use serde::{Deserialize, Serialize};

use crate::model::{Config, EndReason};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ThermalLevel {
    #[default]
    Nominal,
    Fair,
    Serious,
    Critical,
}

impl ThermalLevel {
    pub fn is_warm(&self) -> bool {
        *self >= ThermalLevel::Fair
    }

    /// Plain-language heat warning for the start flow, or None when cool.
    pub fn start_warning(&self) -> Option<&'static str> {
        match self {
            ThermalLevel::Nominal => None,
            ThermalLevel::Fair => Some("Your computer is already warm. Closing the lid holds in more heat, so keep it on a hard, open surface."),
            ThermalLevel::Serious => Some("Your computer is running hot. Closing the lid holds in more heat. Make sure it has open air around it, and consider waiting until it cools down."),
            ThermalLevel::Critical => Some("Your computer is too hot to keep running with the lid closed. Let it cool down first."),
        }
    }

    pub fn raw(&self) -> &'static str {
        match self {
            ThermalLevel::Nominal => "nominal",
            ThermalLevel::Fair => "fair",
            ThermalLevel::Serious => "serious",
            ThermalLevel::Critical => "critical",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct BatteryReading {
    /// False on desktops.
    pub has_battery: bool,
    pub on_battery: bool,
    /// None when a battery exists but its level could not be read.
    pub percent: Option<i64>,
}

impl BatteryReading {
    pub fn none() -> Self {
        BatteryReading {
            has_battery: false,
            on_battery: false,
            percent: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FloorDecision {
    pub end: Option<EndReason>,
    pub want_low_power: bool,
}

pub fn decide(
    on_battery: bool,
    percent: Option<i64>,
    unreadable_count: u32,
    thermal: ThermalLevel,
    lid_closed: bool,
    config: &Config,
) -> FloorDecision {
    let c = config.normalized();
    let mut end = None;
    let mut want_low_power = false;

    if on_battery {
        match percent {
            Some(p) => {
                if p < c.low_power_below_percent {
                    want_low_power = true;
                }
                if c.end_below_percent > 0 && p < c.end_below_percent {
                    end = Some(EndReason::BatteryFloor);
                }
            }
            None => {
                if unreadable_count >= 2 {
                    end = Some(EndReason::BatteryUnreadable);
                }
            }
        }
        if lid_closed && c.low_power_on_lid_close {
            want_low_power = true;
        }
        if c.thermal_rules && thermal >= ThermalLevel::Serious {
            want_low_power = true;
        }
    }

    if c.thermal_rules && thermal == ThermalLevel::Critical && end.is_none() {
        end = Some(EndReason::ThermalFloor);
    }
    FloorDecision {
        end,
        want_low_power,
    }
}
