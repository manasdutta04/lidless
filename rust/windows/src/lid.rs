//! Lid state via power-setting notifications. Windows has no polling API for
//! the lid, so a message-only window on a background thread registers for
//! `GUID_LIDSWITCH_STATE_CHANGE`; the current state is delivered right after
//! registration, then on every change.

use std::sync::atomic::{AtomicI8, Ordering};
use std::sync::Arc;

pub struct LidWatcher {
    /// -1 unknown, 0 open, 1 closed.
    state: Arc<AtomicI8>,
}

impl LidWatcher {
    pub fn closed(&self) -> Option<bool> {
        match self.state.load(Ordering::SeqCst) {
            1 => Some(true),
            0 => Some(false),
            _ => None,
        }
    }
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::sync::OnceLock;
    use windows::core::w;
    use windows::Win32::Foundation::{HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::System::Power::{RegisterPowerSettingNotification, POWERBROADCAST_SETTING};
    use windows::Win32::System::SystemServices::GUID_LIDSWITCH_STATE_CHANGE;
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, RegisterClassW,
        TranslateMessage, DEVICE_NOTIFY_WINDOW_HANDLE, HMENU, HWND_MESSAGE, MSG,
        PBT_POWERSETTINGCHANGE, WINDOW_EX_STYLE, WINDOW_STYLE, WM_POWERBROADCAST, WNDCLASSW,
    };

    static STATE: OnceLock<Arc<AtomicI8>> = OnceLock::new();

    unsafe extern "system" fn wndproc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        if msg == WM_POWERBROADCAST && wparam.0 as u32 == PBT_POWERSETTINGCHANGE {
            let setting = &*(lparam.0 as *const POWERBROADCAST_SETTING);
            if setting.PowerSetting == GUID_LIDSWITCH_STATE_CHANGE && setting.DataLength >= 1 {
                // Data[0]: 0 = closed, 1 = open.
                let closed = setting.Data[0] == 0;
                if let Some(state) = STATE.get() {
                    state.store(if closed { 1 } else { 0 }, Ordering::SeqCst);
                }
            }
            return LRESULT(1);
        }
        DefWindowProcW(hwnd, msg, wparam, lparam)
    }

    impl LidWatcher {
        pub fn start() -> Option<LidWatcher> {
            let state = STATE.get_or_init(|| Arc::new(AtomicI8::new(-1))).clone();
            let s2 = state.clone();
            std::thread::Builder::new()
                .name("lidless-lid".into())
                .spawn(move || unsafe {
                    let module = GetModuleHandleW(None).unwrap_or_default();
                    let instance = HINSTANCE(module.0);
                    let class = WNDCLASSW {
                        lpfnWndProc: Some(wndproc),
                        hInstance: instance,
                        lpszClassName: w!("LidlessLidWatcher"),
                        ..Default::default()
                    };
                    RegisterClassW(&class);
                    let hwnd = CreateWindowExW(
                        WINDOW_EX_STYLE(0),
                        w!("LidlessLidWatcher"),
                        w!("Lidless"),
                        WINDOW_STYLE(0),
                        0,
                        0,
                        0,
                        0,
                        HWND_MESSAGE,
                        HMENU::default(),
                        instance,
                        None,
                    );
                    let Ok(hwnd) = hwnd else { return };
                    if RegisterPowerSettingNotification(
                        HANDLE(hwnd.0),
                        &GUID_LIDSWITCH_STATE_CHANGE,
                        DEVICE_NOTIFY_WINDOW_HANDLE,
                    )
                    .is_err()
                    {
                        s2.store(-1, Ordering::SeqCst);
                        return;
                    }
                    let mut msg = MSG::default();
                    while GetMessageW(&mut msg, HWND::default(), 0, 0).as_bool() {
                        let _ = TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    }
                })
                .ok()?;
            // Give the registration a moment to deliver the initial state.
            std::thread::sleep(std::time::Duration::from_millis(150));
            Some(LidWatcher { state })
        }
    }
}

#[cfg(not(windows))]
impl LidWatcher {
    pub fn start() -> Option<LidWatcher> {
        None
    }
}
