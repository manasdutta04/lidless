//! Proves a pid is the same process we recorded: pid + start time + boot id.

use crate::model::{OwnerIdentity, OwnerKind};

pub trait ProcessInspector: Send + Sync {
    /// Process start time in microseconds since the epoch, None if gone.
    fn start_time(&self, pid: u32) -> Option<i64>;
    fn boot_session(&self) -> String;

    fn is_alive(&self, owner: &OwnerIdentity) -> bool {
        owner.boot_session == self.boot_session()
            && self
                .start_time(owner.pid)
                .map(|t| t == owner.start_time)
                .unwrap_or(false)
    }

    fn current_identity(&self, kind: OwnerKind) -> OwnerIdentity {
        let pid = std::process::id();
        OwnerIdentity {
            kind,
            pid,
            start_time: self.start_time(pid).unwrap_or(0),
            boot_session: self.boot_session(),
        }
    }
}

pub struct SystemProcessInspector;

#[cfg(target_os = "linux")]
impl ProcessInspector for SystemProcessInspector {
    fn start_time(&self, pid: u32) -> Option<i64> {
        // /proc/<pid>/stat field 22 is start time in clock ticks since boot.
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let after = stat.rsplit_once(')')?.1;
        let fields: Vec<&str> = after.split_whitespace().collect();
        let state = *fields.first()?;
        if state == "Z" {
            return None;
        }
        let ticks: i64 = fields.get(19)?.parse().ok()?;
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as i64;
        let btime = std::fs::read_to_string("/proc/stat")
            .ok()?
            .lines()
            .find_map(|l| {
                l.strip_prefix("btime ")
                    .and_then(|v| v.trim().parse::<i64>().ok())
            })?;
        Some(btime * 1_000_000 + ticks * 1_000_000 / hz)
    }

    fn boot_session(&self) -> String {
        std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| "unknown-boot".into())
    }
}

#[cfg(target_os = "macos")]
impl ProcessInspector for SystemProcessInspector {
    fn start_time(&self, pid: u32) -> Option<i64> {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        let got = unsafe {
            libc::proc_pidinfo(
                pid as i32,
                libc::PROC_PIDTBSDINFO,
                0,
                &mut info as *mut _ as *mut libc::c_void,
                size,
            )
        };
        if got != size || info.pbi_status == libc::SZOMB {
            return None;
        }
        Some(info.pbi_start_tvsec as i64 * 1_000_000 + info.pbi_start_tvusec as i64)
    }

    fn boot_session(&self) -> String {
        let mut size = 0usize;
        let name = c"kern.bootsessionuuid";
        unsafe {
            if libc::sysctlbyname(
                name.as_ptr(),
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            ) == 0
                && size > 0
            {
                let mut buf = vec![0u8; size];
                if libc::sysctlbyname(
                    name.as_ptr(),
                    buf.as_mut_ptr() as *mut libc::c_void,
                    &mut size,
                    std::ptr::null_mut(),
                    0,
                ) == 0
                {
                    return String::from_utf8_lossy(&buf)
                        .trim_end_matches('\0')
                        .to_string();
                }
            }
        }
        "unknown-boot".into()
    }
}

#[cfg(target_os = "windows")]
impl ProcessInspector for SystemProcessInspector {
    fn start_time(&self, pid: u32) -> Option<i64> {
        use windows::Win32::Foundation::{CloseHandle, FILETIME};
        use windows::Win32::System::Threading::{
            GetExitCodeProcess, GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        };
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
            let mut code = 0u32;
            let alive = GetExitCodeProcess(handle, &mut code).is_ok() && code == 259; // STILL_ACTIVE
            let mut creation = FILETIME::default();
            let mut exit = FILETIME::default();
            let mut kernel = FILETIME::default();
            let mut user = FILETIME::default();
            let ok =
                GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user).is_ok();
            let _ = CloseHandle(handle);
            if !ok || !alive {
                return None;
            }
            // FILETIME: 100 ns intervals since 1601-01-01.
            let ft = ((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64;
            const EPOCH_DIFF_100NS: u64 = 116_444_736_000_000_000;
            Some(((ft.saturating_sub(EPOCH_DIFF_100NS)) / 10) as i64)
        }
    }

    fn boot_session(&self) -> String {
        // Boot time to the nearest 10 seconds: stable across a boot, different after one.
        use windows::Win32::System::SystemInformation::GetTickCount64;
        let uptime_ms = unsafe { GetTickCount64() };
        let boot = chrono::Utc::now().timestamp() - (uptime_ms / 1000) as i64;
        format!("boot-{}", boot / 10 * 10)
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
impl ProcessInspector for SystemProcessInspector {
    fn start_time(&self, _pid: u32) -> Option<i64> {
        None
    }
    fn boot_session(&self) -> String {
        "unknown-boot".into()
    }
}
