import AppKit
import LidlessCore
import SwiftUI

@main
struct LidlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["LIDLESS_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.snapshot(to: path) }
        }
        #endif
        // SIGTERM (logout, `kill`) must still restore settings (Hard rule 6).
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    #if DEBUG
    /// Development aid: renders the menu panel to a PNG and quits.
    private func snapshot(to path: String) {
        let view = NSHostingView(rootView: MenuContentView(model: model).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.ownedHere else { return .terminateNow }
        Task { @MainActor in
            await model.endForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if let text = model.menuBarText {
            HStack(spacing: 3) {
                Image(systemName: "sun.max.fill")
                Text(text).monospacedDigit()
            }
        } else {
            Image(systemName: hasWarning ? "exclamationmark.triangle" : "moon.zzz")
        }
    }

    private var hasWarning: Bool {
        guard let s = model.snapshot else { return false }
        return !s.warnings.isEmpty && model.readiness?.ready == true
    }
}
