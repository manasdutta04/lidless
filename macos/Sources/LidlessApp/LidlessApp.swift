import AppKit
import LidlessCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = AppModel()
    private var panel: StatusPanelController?
    private var settings: SettingsWindowController?
    private var signalSources: [DispatchSourceSignal] = []
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A login-item launch should stay quietly in the menu bar.
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedAtLogin = event.eventID == AEEventID(kAEOpenApplication)
                && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockPolicy()
        NSApp.mainMenu = makeMainMenu()
        panel = StatusPanelController(model: model)
        settings = SettingsWindowController(model: model)
        model.onDockSettingChanged = { [weak self] in self?.applyDockPolicy() }
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.onOpenPanel = { [weak self] in self?.panel?.open() }

        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["LIDLESS_PANEL_CHECK"] {
            // Drives the real panel through content changes while it stays open
            // and captures its actual frame and pixels after each step.
            let steps: [(String, @MainActor () -> Void)] = [
                ("1-open", { self.panel?.open() }),
                ("2-busy", { self.model.debugSetBusy(true) }),
                ("3-idle-again", { self.model.debugSetBusy(false) }),
                ("4-ventilation", { self.model.debugSetPending(7_200) }),
                ("5-cancelled", { self.model.debugSetPending(nil) }),
                ("6-reopen", { self.panel?.close(); self.panel?.open() }),
            ]
            func run(_ i: Int) {
                guard i < steps.count else { exit(0) }
                steps[i].1()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    print(steps[i].0, terminator: ": ")
                    self.panel?.debugCapture(to: "\(path)-\(steps[i].0).png")
                    run(i + 1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run(0) }
            return
        }
        if let path = ProcessInfo.processInfo.environment["LIDLESS_WINDOW_CHECK"] {
            if let mode = ProcessInfo.processInfo.environment["LIDLESS_SNAPSHOT_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.settings?.show(page: .overview)
                @MainActor func capture(_ i: Int) {
                    guard i < WindowPage.allCases.count else {
                        // Resize limits: below the minimum is refused, larger is fine.
                        self.model.windowPage = .overview
                        self.settings?.debugResize(NSSize(width: 600, height: 400))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.settings?.debugResize(NSSize(width: 1400, height: 900))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                self.settings?.debugCapture(to: "\(path)-large.png")
                                exit(0)
                            }
                        }
                        return
                    }
                    self.model.windowPage = WindowPage.allCases[i]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.settings?.debugCapture(to: "\(path)-\(WindowPage.allCases[i].rawValue).png")
                        capture(i + 1)
                    }
                }
                capture(0)
            }
            return
        }
        if let path = ProcessInfo.processInfo.environment["LIDLESS_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.snapshot(to: path) }
            return
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

        // Opened by the user (Finder, Launchpad, Spotlight): show the window,
        // like any app. At login, stay in the menu bar unless setup is needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.launchedAtLogin || self.model.needsSetup { self.settings?.show() }
        }
    }

    /// Clicking the Dock icon opens the desktop window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show()
        return false
    }

    /// Closing the window never quits: Lidless keeps running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Hard rule 6: quitting (⌘Q, Dock → Quit, the panel's Quit) always ends
    /// the session this app owns, after restoring settings.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.ownedHere else { return .terminateNow }
        Task { @MainActor in
            await model.endForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Session menu items follow the session state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(stopSession): return model.isActive && !model.busy
        default: return true
        }
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(model.config.showInDock ? .regular : .accessory)
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        i.target = self
        i.tag = tag
        return i
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // Lidless
        let app = NSMenu(title: "Lidless")
        app.addItem(item("About Lidless", #selector(showAbout)))
        app.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(openSettings), ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Lidless", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Lidless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app))

        // Session: sessions start from the menu bar panel; here you can open
        // it, or stop a running session.
        let session = NSMenu(title: "Session")
        session.addItem(item("Open Menu Bar Panel", #selector(openPanel), "l", [.command, .shift]))
        session.addItem(.separator())
        session.addItem(item("Stop Session", #selector(stopSession), "."))
        main.addItem(submenu(session))

        // Edit: standard commands so ⌘C/⌘V/⌘A work in text fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        // View: the window's pages.
        let view = NSMenu(title: "View")
        for (i, page) in WindowPage.allCases.enumerated() {
            view.addItem(item(page.title, #selector(showPage(_:)), "\(i + 1)", [.command, .option], tag: i))
        }
        main.addItem(submenu(view))

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(item("Lidless Window", #selector(openSettings), "0"))
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        main.addItem(submenu(window))

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(item("Lidless Help", #selector(openHelp), "?"))
        help.addItem(item("Release Notes", #selector(openReleases)))
        help.addItem(item("Report an Issue…", #selector(reportIssue)))
        help.addItem(.separator())
        help.addItem(item("Open Log", #selector(openLog)))
        NSApp.helpMenu = help
        main.addItem(submenu(help))
        return main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    /// Dock icon right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let status = NSMenuItem(title: model.isActive ? "Awake · \(DurationParser.clock(model.remaining)) left" : "Sleeps normally",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Open Menu Bar Panel", #selector(openPanel)))
        if model.isActive { menu.addItem(item("Stop Session", #selector(stopSession))) }
        menu.addItem(item("Settings…", #selector(openSettings)))
        return menu
    }

    @objc private func openPanel() { panel?.open() }
    @objc private func openSettings() {
        panel?.close()
        settings?.show()
    }
    @objc private func showAbout() { settings?.show(page: .about) }
    @objc private func checkForUpdates() {
        settings?.show(page: .about)
        model.checkForUpdates()
    }
    @objc private func showPage(_ sender: NSMenuItem) {
        settings?.show(page: WindowPage.allCases[sender.tag])
    }
    @objc private func stopSession() { model.stop() }
    @objc private func openHelp() { model.openHelp() }
    @objc private func openReleases() { model.openURL("https://github.com/manasdutta04/lidless/releases") }
    @objc private func reportIssue() { model.openURL("https://github.com/manasdutta04/lidless/issues/new") }
    @objc private func openLog() { model.openLog() }

    #if DEBUG
    /// Development aid: renders the panel content to a PNG (with the real
    /// rounded material frame) and quits. LIDLESS_SNAPSHOT_PAGE=settings for
    /// the settings page.
    private func snapshot(to path: String) {
        let content: AnyView
        if let pending = ProcessInfo.processInfo.environment["LIDLESS_SNAPSHOT_PENDING"], let secs = TimeInterval(pending) {
            model.debugSetPending(secs)
        }
        if ProcessInfo.processInfo.environment["LIDLESS_SNAPSHOT_PAGE"] == "overview" {
            model.reloadHistory()
            content = AnyView(OverviewPage(model: model)
                .padding(36)
                .frame(width: SettingsWindowController.size.width - 237)
                .fixedSize(horizontal: false, vertical: true)
                .background(Theme.background)
                .foregroundStyle(Theme.text))
        } else if ProcessInfo.processInfo.environment["LIDLESS_SNAPSHOT_PAGE"] == "settings" {
            content = AnyView(DesktopView(model: model))
        } else {
            content = AnyView(PanelRootView(model: model, onHeight: { _ in })
                .frame(width: Theme.panelWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
                .background(Color(white: 0.5)))
        }
        let view = NSHostingView(rootView: content)
        if let mode = ProcessInfo.processInfo.environment["LIDLESS_SNAPSHOT_APPEARANCE"] {
            view.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
        }
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
    #endif
}
