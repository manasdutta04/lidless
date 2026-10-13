//! User notifications.

pub trait Notifier: Send + Sync {
    fn notify(&self, title: &str, body: &str);
}

pub struct NoopNotifier;
impl Notifier for NoopNotifier {
    fn notify(&self, _title: &str, _body: &str) {}
}

/// Native desktop notification (D-Bus on Linux, toast on Windows, Notification
/// Center on macOS). Failures are ignored: a notification is never critical.
pub struct DesktopNotifier;
impl Notifier for DesktopNotifier {
    fn notify(&self, title: &str, body: &str) {
        let _ = notify_rust::Notification::new()
            .summary(title)
            .body(body)
            .appname("Lidless")
            .show();
    }
}
