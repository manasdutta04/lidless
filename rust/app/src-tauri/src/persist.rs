//! The app's own small state file (`app-state.json` in the state directory):
//! things the core does not care about.

use chrono::{DateTime, Utc};
use lidless_core::paths::Paths;
use lidless_core::store::{read_optional, write_atomic};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppState {
    pub launched_before: bool,
    pub last_update_check: Option<DateTime<Utc>>,
    pub window_width: Option<f64>,
    pub window_height: Option<f64>,
}

impl AppState {
    pub fn load(paths: &Paths) -> AppState {
        read_optional(&paths.home.join("app-state.json"))
            .ok()
            .flatten()
            .and_then(|d| serde_json::from_slice(&d).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, paths: &Paths) {
        let _ = paths.ensure_home();
        if let Ok(data) = serde_json::to_vec_pretty(self) {
            let _ = write_atomic(&paths.home.join("app-state.json"), &data);
        }
    }
}
