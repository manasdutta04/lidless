//! The shared spec vectors: the Rust core must agree with the Swift core.

use lidless_core::duration;
use lidless_core::floors::{self, ThermalLevel};
use lidless_core::model::Config;

fn load(name: &str) -> serde_json::Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../spec/vectors")
        .join(name);
    serde_json::from_slice(
        &std::fs::read(&path).unwrap_or_else(|_| panic!("missing {}", path.display())),
    )
    .unwrap()
}

#[test]
fn durations() {
    let v = load("durations.json");
    for c in v["valid"].as_array().unwrap() {
        let input = c["input"].as_str().unwrap();
        assert_eq!(
            duration::parse(input).unwrap(),
            c["seconds"].as_u64().unwrap(),
            "{input}"
        );
    }
    for input in v["invalid"].as_array().unwrap() {
        let input = input.as_str().unwrap();
        assert!(
            duration::parse(input).is_err(),
            "{input:?} should be invalid"
        );
    }
}

#[test]
fn floor_decisions() {
    let v = load("floors.json");
    let base = v["defaultConfig"].as_object().unwrap().clone();
    for c in v["cases"].as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        let mut merged = base.clone();
        if let Some(over) = c["config"].as_object() {
            for (k, val) in over {
                merged.insert(k.clone(), val.clone());
            }
        }
        let config: Config = serde_json::from_value(serde_json::Value::Object(merged)).unwrap();
        let thermal: ThermalLevel = serde_json::from_value(c["thermal"].clone()).unwrap();
        let d = floors::decide(
            c["onBattery"].as_bool().unwrap(),
            c["percent"].as_i64(),
            c["unreadable"].as_u64().unwrap() as u32,
            thermal,
            c["lidClosed"].as_bool().unwrap(),
            &config,
        );
        let expected_end = c["end"].as_str();
        assert_eq!(d.end.map(|e| e.raw()), expected_end, "{name}");
        assert_eq!(
            d.want_low_power,
            c["wantLowPower"].as_bool().unwrap(),
            "{name}"
        );
    }
}

#[test]
fn journal_format_matches_macos() {
    // A journal written by the macOS app must round-trip unchanged.
    let raw = r#"{"macos":{"sleepDisabled":{"original":false,"recordedAt":"2026-10-13T06:26:19.811Z"}},"updatedAt":"2026-10-13T06:26:19.811Z","version":1}"#;
    let j: lidless_core::model::Journal = serde_json::from_str(raw).unwrap();
    assert!(!j.is_empty());
    assert!(!j.macos.sleep_disabled.as_ref().unwrap().original);
    let back = serde_json::to_value(&j).unwrap();
    assert_eq!(back["macos"]["sleepDisabled"]["original"], false);
    assert!(back.get("windows").is_some());
}

#[test]
fn session_format_matches_macos() {
    let raw = r#"{"version":1,"id":"39474289-BD45-45F2-85D8-99F687996BC7","startedAt":"2026-10-13T06:26:19.800Z","endsAt":"2026-10-13T06:56:19.800Z","extensions":[],"owner":{"kind":"app","pid":21908,"startTime":1760336779800000,"bootSession":"ABC"}}"#;
    let s: lidless_core::model::Session = serde_json::from_str(raw).unwrap();
    assert_eq!(s.owner.pid, 21908);
    assert_eq!(serde_json::to_value(&s).unwrap()["owner"]["kind"], "app");
}
