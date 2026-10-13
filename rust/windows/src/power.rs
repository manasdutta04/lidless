//! Power Management API: active scheme, lid-close action, power requests,
//! battery, display off. Pure-Rust fallbacks keep the crate compiling on
//! other hosts for `cargo check`.

use lidless_core::engine::AwakeHold;
use lidless_core::error::{LidlessError, Result};
use lidless_core::floors::BatteryReading;
use lidless_core::paths::Paths;
use lidless_core::store::write_atomic;
use serde::{Deserialize, Serialize};

/// Written by the engine and read by the elevated `_lidaction` task.
#[derive(Debug, Serialize, Deserialize)]
pub struct LidActionRequest {
    pub scheme: String,
    pub ac: u32,
    pub dc: u32,
}

pub fn request_path() -> std::path::PathBuf {
    Paths::resolve().home.join("lid-action-request.json")
}

pub fn result_path() -> std::path::PathBuf {
    Paths::resolve().home.join("lid-action-result.json")
}

/// Entry point of the `_lidaction` hidden command (runs elevated).
pub fn apply_from_request_file() -> i32 {
    let outcome: std::result::Result<(), String> = (|| {
        let data = std::fs::read(request_path()).map_err(|e| format!("no request: {e}"))?;
        let req: LidActionRequest =
            serde_json::from_str(&String::from_utf8_lossy(&data)).map_err(|e| e.to_string())?;
        write_lid_action(&req.scheme, req.ac, req.dc).map_err(|e| e.to_string())
    })();
    let result = match &outcome {
        Ok(()) => serde_json::json!({"ok": true}),
        Err(e) => serde_json::json!({"ok": false, "error": e}),
    };
    let _ = write_atomic(&result_path(), result.to_string().as_bytes());
    if outcome.is_ok() {
        0
    } else {
        1
    }
}

pub fn is_access_denied(e: &LidlessError) -> bool {
    e.to_string().contains("ACCESS_DENIED")
        || e.to_string().contains("(0x80070005)")
        || e.to_string().contains("os error 5")
}

#[cfg(windows)]
mod imp {
    use super::*;
    use windows::core::GUID;
    use windows::Win32::Foundation::{
        CloseHandle, LocalFree, HANDLE, HLOCAL, LPARAM, WIN32_ERROR, WPARAM,
    };
    use windows::Win32::System::Power::{
        GetSystemPowerStatus, PowerClearRequest, PowerCreateRequest, PowerGetActiveScheme,
        PowerReadACValueIndex, PowerReadDCValueIndex, PowerRequestSystemRequired,
        PowerSetActiveScheme, PowerSetRequest, PowerWriteACValueIndex, PowerWriteDCValueIndex,
        SYSTEM_POWER_STATUS,
    };
    use windows::Win32::System::Registry::HKEY;
    use windows::Win32::System::SystemServices::{
        GUID_LIDCLOSE_ACTION, GUID_SYSTEM_BUTTON_SUBGROUP,
    };
    use windows::Win32::System::Threading::{
        POWER_REQUEST_CONTEXT_SIMPLE_STRING, REASON_CONTEXT, REASON_CONTEXT_0,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        SendMessageTimeoutW, HWND_BROADCAST, SC_MONITORPOWER, SMTO_ABORTIFHUNG, WM_SYSCOMMAND,
    };

    const ERROR_SUCCESS: u32 = 0;
    const ERROR_ACCESS_DENIED: u32 = 5;

    /// Some powrprof functions return `WIN32_ERROR`, others a bare `u32`.
    trait Win32Code {
        fn code(self) -> u32;
    }
    impl Win32Code for WIN32_ERROR {
        fn code(self) -> u32 {
            self.0
        }
    }
    impl Win32Code for u32 {
        fn code(self) -> u32 {
            self
        }
    }

    fn check(name: &str, rc: impl Win32Code) -> Result<()> {
        let rc = WIN32_ERROR(rc.code());
        if rc.0 == ERROR_SUCCESS {
            Ok(())
        } else if rc.0 == ERROR_ACCESS_DENIED {
            Err(LidlessError::System(format!(
                "{name}: ACCESS_DENIED (os error 5)"
            )))
        } else {
            Err(LidlessError::System(format!(
                "{name}: Win32 error {}",
                rc.0
            )))
        }
    }

    fn guid_to_string(g: &GUID) -> String {
        format!(
            "{:08x}-{:04x}-{:04x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
            g.data1,
            g.data2,
            g.data3,
            g.data4[0],
            g.data4[1],
            g.data4[2],
            g.data4[3],
            g.data4[4],
            g.data4[5],
            g.data4[6],
            g.data4[7]
        )
    }

    /// Parses "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" without panicking on
    /// bad input (the `From<&str>` impl in windows-core panics).
    fn parse_guid(s: &str) -> Result<GUID> {
        let bad = || LidlessError::System(format!("bad power scheme id {s}"));
        let parts: Vec<&str> = s
            .trim_matches(|c| c == '{' || c == '}')
            .split('-')
            .collect();
        if parts.len() != 5
            || parts[0].len() != 8
            || parts[1].len() != 4
            || parts[2].len() != 4
            || parts[3].len() != 4
            || parts[4].len() != 12
        {
            return Err(bad());
        }
        let d1 = u32::from_str_radix(parts[0], 16).map_err(|_| bad())?;
        let d2 = u16::from_str_radix(parts[1], 16).map_err(|_| bad())?;
        let d3 = u16::from_str_radix(parts[2], 16).map_err(|_| bad())?;
        let tail = format!("{}{}", parts[3], parts[4]);
        let mut d4 = [0u8; 8];
        for (i, b) in d4.iter_mut().enumerate() {
            *b = u8::from_str_radix(&tail[i * 2..i * 2 + 2], 16).map_err(|_| bad())?;
        }
        Ok(GUID::from_values(d1, d2, d3, d4))
    }

    pub fn active_scheme() -> Result<String> {
        unsafe {
            let mut ptr: *mut GUID = std::ptr::null_mut();
            check(
                "PowerGetActiveScheme",
                PowerGetActiveScheme(HKEY::default(), &mut ptr),
            )?;
            if ptr.is_null() {
                return Err(LidlessError::System(
                    "PowerGetActiveScheme returned no scheme".into(),
                ));
            }
            let s = guid_to_string(&*ptr);
            let _ = LocalFree(HLOCAL(ptr as *mut _));
            Ok(s)
        }
    }

    pub fn read_lid_action(scheme: &str) -> Result<(u32, u32)> {
        let g = parse_guid(scheme)?;
        let mut ac = 0u32;
        let mut dc = 0u32;
        unsafe {
            check(
                "PowerReadACValueIndex",
                PowerReadACValueIndex(
                    HKEY::default(),
                    Some(&g),
                    Some(&GUID_SYSTEM_BUTTON_SUBGROUP),
                    Some(&GUID_LIDCLOSE_ACTION),
                    &mut ac,
                ),
            )?;
            check(
                "PowerReadDCValueIndex",
                PowerReadDCValueIndex(
                    HKEY::default(),
                    Some(&g),
                    Some(&GUID_SYSTEM_BUTTON_SUBGROUP),
                    Some(&GUID_LIDCLOSE_ACTION),
                    &mut dc,
                ),
            )?;
        }
        Ok((ac, dc))
    }

    pub fn write_lid_action(scheme: &str, ac: u32, dc: u32) -> Result<()> {
        let g = parse_guid(scheme)?;
        unsafe {
            check(
                "PowerWriteACValueIndex",
                PowerWriteACValueIndex(
                    HKEY::default(),
                    &g,
                    Some(&GUID_SYSTEM_BUTTON_SUBGROUP),
                    Some(&GUID_LIDCLOSE_ACTION),
                    ac,
                ),
            )?;
            check(
                "PowerWriteDCValueIndex",
                PowerWriteDCValueIndex(
                    HKEY::default(),
                    &g,
                    Some(&GUID_SYSTEM_BUTTON_SUBGROUP),
                    Some(&GUID_LIDCLOSE_ACTION),
                    dc,
                ),
            )?;
            // Re-activating the scheme makes the new value take effect.
            check(
                "PowerSetActiveScheme",
                PowerSetActiveScheme(HKEY::default(), Some(&g)),
            )?;
        }
        Ok(())
    }

    /// A write of the current value back to itself: succeeds only if this
    /// process may change power settings directly.
    pub fn can_write_lid_action() -> bool {
        (|| -> Result<()> {
            let scheme = active_scheme()?;
            let (ac, dc) = read_lid_action(&scheme)?;
            write_lid_action(&scheme, ac, dc)
        })()
        .is_ok()
    }

    pub struct PowerRequest {
        handle: HANDLE,
        _reason: Vec<u16>,
    }
    unsafe impl Send for PowerRequest {}
    impl AwakeHold for PowerRequest {}

    impl PowerRequest {
        pub fn new(reason: &str) -> Result<Self> {
            let mut wide: Vec<u16> = reason.encode_utf16().chain(std::iter::once(0)).collect();
            let ctx = REASON_CONTEXT {
                Version: 0, // POWER_REQUEST_CONTEXT_VERSION
                Flags: POWER_REQUEST_CONTEXT_SIMPLE_STRING,
                Reason: REASON_CONTEXT_0 {
                    SimpleReasonString: windows::core::PWSTR(wide.as_mut_ptr()),
                },
            };
            unsafe {
                let handle = PowerCreateRequest(&ctx)
                    .map_err(|e| LidlessError::System(format!("PowerCreateRequest: {e}")))?;
                if let Err(e) = PowerSetRequest(handle, PowerRequestSystemRequired) {
                    let _ = CloseHandle(handle);
                    return Err(LidlessError::System(format!("PowerSetRequest: {e}")));
                }
                Ok(PowerRequest {
                    handle,
                    _reason: wide,
                })
            }
        }
    }

    impl Drop for PowerRequest {
        fn drop(&mut self) {
            unsafe {
                let _ = PowerClearRequest(self.handle, PowerRequestSystemRequired);
                let _ = CloseHandle(self.handle);
            }
        }
    }

    pub fn display_off() {
        unsafe {
            let _ = SendMessageTimeoutW(
                HWND_BROADCAST,
                WM_SYSCOMMAND,
                WPARAM(SC_MONITORPOWER as usize),
                LPARAM(2),
                SMTO_ABORTIFHUNG,
                1000,
                None,
            );
        }
    }

    pub fn battery() -> BatteryReading {
        let mut status = SYSTEM_POWER_STATUS::default();
        if unsafe { GetSystemPowerStatus(&mut status) }.is_err() {
            return BatteryReading::none();
        }
        if status.BatteryFlag & 128 != 0 {
            return BatteryReading::none();
        }
        BatteryReading {
            has_battery: true,
            on_battery: status.ACLineStatus == 0,
            percent: if status.BatteryLifePercent == 255 {
                None
            } else {
                Some(status.BatteryLifePercent as i64)
            },
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::*;

    const UNAVAILABLE: &str = "Windows power settings are not available on this platform.";

    pub fn active_scheme() -> Result<String> {
        Err(LidlessError::System(UNAVAILABLE.into()))
    }
    pub fn read_lid_action(_scheme: &str) -> Result<(u32, u32)> {
        Err(LidlessError::System(UNAVAILABLE.into()))
    }
    pub fn write_lid_action(_scheme: &str, _ac: u32, _dc: u32) -> Result<()> {
        Err(LidlessError::System(UNAVAILABLE.into()))
    }
    pub fn can_write_lid_action() -> bool {
        false
    }
    pub struct PowerRequest;
    impl AwakeHold for PowerRequest {}
    impl PowerRequest {
        pub fn new(_reason: &str) -> Result<Self> {
            Err(LidlessError::System(UNAVAILABLE.into()))
        }
    }
    pub fn display_off() {}
    pub fn battery() -> BatteryReading {
        BatteryReading::none()
    }
}

pub use imp::*;
