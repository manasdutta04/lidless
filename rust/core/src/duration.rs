//! Duration parsing and formatting per spec/session.md ("2h", "90m", "1d2h", "45").

use crate::error::{LidlessError, Result};

const UNITS: [(char, u64); 4] = [('d', 86_400), ('h', 3_600), ('m', 60), ('s', 1)];

/// Parses a duration into whole seconds.
pub fn parse(raw: &str) -> Result<u64> {
    let input = raw.trim().to_ascii_lowercase();
    if input.is_empty() {
        return Err(LidlessError::Usage(
            "Duration is empty. Try 2h, 90m or 1d2h.".into(),
        ));
    }
    if input.chars().all(|c| c.is_ascii_digit()) {
        let minutes: u64 = input.parse().map_err(|_| invalid(raw))?;
        if minutes == 0 {
            return Err(LidlessError::Usage(
                "Duration must be greater than zero.".into(),
            ));
        }
        return Ok(minutes * 60);
    }

    let mut total: u64 = 0;
    let mut number = String::new();
    let mut next_unit = 0usize;
    let mut saw_part = false;
    for ch in input.chars() {
        if ch.is_ascii_digit() {
            number.push(ch);
        } else if ch == ' ' {
            if !number.is_empty() {
                return Err(invalid(raw));
            }
        } else if let Some(idx) = UNITS.iter().position(|(u, _)| *u == ch) {
            if number.is_empty() || idx < next_unit {
                return Err(invalid(raw));
            }
            let n: u64 = number.parse().map_err(|_| invalid(raw))?;
            total = n
                .checked_mul(UNITS[idx].1)
                .and_then(|v| total.checked_add(v))
                .ok_or_else(|| invalid(raw))?;
            number.clear();
            next_unit = idx + 1;
            saw_part = true;
        } else {
            return Err(invalid(raw));
        }
    }
    if !number.is_empty() || !saw_part {
        return Err(invalid(raw));
    }
    if total == 0 {
        return Err(LidlessError::Usage(
            "Duration must be greater than zero.".into(),
        ));
    }
    Ok(total)
}

fn invalid(raw: &str) -> LidlessError {
    LidlessError::Usage(format!(
        "Invalid duration \"{raw}\". Use units d, h, m, s in that order, e.g. 2h, 90m, 1d2h, 1h 30m."
    ))
}

/// "1d 2h", "1h 30m", "45m", "30s".
pub fn format(seconds: f64) -> String {
    let mut s = seconds.round().max(0.0) as u64;
    if s == 0 {
        return "0s".into();
    }
    let d = s / 86_400;
    s %= 86_400;
    let h = s / 3_600;
    s %= 3_600;
    let m = s / 60;
    s %= 60;
    let mut parts = Vec::new();
    if d > 0 {
        parts.push(format!("{d}d"));
    }
    if h > 0 {
        parts.push(format!("{h}h"));
    }
    if m > 0 {
        parts.push(format!("{m}m"));
    }
    if s > 0 && d == 0 && h == 0 {
        parts.push(format!("{s}s"));
    }
    if parts.is_empty() {
        "0s".into()
    } else {
        parts.join(" ")
    }
}

/// Countdown clock: "1:02:03" or "2d 3:04:05".
pub fn clock(seconds: f64) -> String {
    let mut s = seconds.ceil().max(0.0) as u64;
    let d = s / 86_400;
    s %= 86_400;
    let h = s / 3_600;
    s %= 3_600;
    let m = s / 60;
    s %= 60;
    let hms = format!("{h}:{m:02}:{s:02}");
    if d > 0 {
        format!("{d}d {hms}")
    } else {
        hms
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats() {
        assert_eq!(format(5400.0), "1h 30m");
        assert_eq!(format(93600.0), "1d 2h");
        assert_eq!(format(30.0), "30s");
        assert_eq!(clock(3661.0), "1:01:01");
        assert_eq!(clock(90061.0), "1d 1:01:01");
    }
}
