import AppKit

// Plain AppKit lifecycle: a status item with our own rounded panel, plus a
// Dock icon (optional) and a standard app menu.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
