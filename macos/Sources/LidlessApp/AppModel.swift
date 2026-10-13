import AppKit
import LidlessCore
import Network
import Observation
import ServiceManagement
import UserNotifications

/// Posts through UserNotifications when running as a bundled app, and falls
/// back to osascript when run unbundled (e.g. `swift run LidlessApp`).
struct AppNotifier: Notifying {
    func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            OSAScriptNotifier().notify(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

enum WindowPage: String, CaseIterable, Identifiable {
    case overview, history, settings, setup, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .history: return "History"
        case .settings: return "Settings"
        case .setup: return "Setup"
        case .about: return "About & Updates"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        case .setup: return "lock.shield"
        case .about: return "arrow.down.circle"
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case noReleases
    case available(ReleaseInfo)
    case downloading(ReleaseInfo)
    case downloaded(ReleaseInfo, URL)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    let owner: SessionOwner
    let env: OwnerEnvironment
    let control: SessionControl

    private(set) var snapshot: StatusSnapshot?
    private(set) var readiness: ReadinessReport?
    private(set) var agents: [DetectedAgent] = []
    private(set) var busy = false
    private(set) var busyText = ""
    private(set) var errorText: String?
    private(set) var now = Date()
    private(set) var online = true
    private(set) var setupRunning = false
    private(set) var setupMessage: String?
    /// 0..<1, advances while the breathing animation runs.
    private(set) var pulsePhase: Double = 0
    /// A start waiting for the ventilation confirmation (first start, or warm Mac).
    private(set) var pendingStart: TimeInterval?
    private(set) var history: [HistoryEntry] = []
    private(set) var stats = UsageStats.compute([])
    private(set) var update: UpdateState = .idle
    var windowPage: WindowPage = .overview
    var tipIndex = 0
    private(set) var copiedAt: Date?
    var config: Config
    var showHeatNotice: Bool
    // View state lives here: the Command Line Tools have no SwiftUIMacros
    // plugin, so `@State` cannot be used in views.
    var customDuration = ""
    @ObservationIgnored var onDockSettingChanged: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onOpenPanel: (() -> Void)?

    private var timer: Timer?
    private var pulseTimer: Timer?
    private var tick = 0
    private var pathMonitor: NWPathMonitor?

    init() {
        let paths = LidlessPaths.resolve()
        Log.shared.configure(paths: paths)
        env = OwnerEnvironment.live(paths: paths, notifier: AppNotifier())
        owner = SessionOwner(env: env)
        control = SessionControl(store: env.store, inspector: env.inspector)
        config = env.store.readConfig()
        showHeatNotice = !FileManager.default.fileExists(atPath: paths.firstRunMarker.path)
        owner.onChange = { [weak self] in self?.refresh() }

        AppNotifier.requestPermission()
        startNetworkMonitor()
        Task { await self.launch() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
    }

    private func launch() async {
        // Finish anything a crashed earlier run left behind.
        let outcome = await env.recovery.run()
        if outcome.action != .nothing { Log.info("app launch recovery: \(outcome.message)") }
        History.backfillFromLogIfNeeded(env.store)
        reloadHistory()
        autoCheckForUpdates()
        await refreshReadiness()
        refreshAgents()
        refresh()
    }

    private func timerFired() {
        now = Date()
        tick += 1
        if tick % 2 == 0 { refresh() }
        if tick % 5 == 0 { refreshAgents() }
        if tick % 12 == 0 { tipIndex += 1 }
        if tick % 30 == 0 { Task { await refreshReadiness() } }
    }

    func reloadHistory() {
        history = History.read(env.store).reversed()
        stats = UsageStats.compute(history)
    }

    func refresh() {
        let wasActive = snapshot?.session != nil
        now = Date()
        snapshot = StatusSnapshot.collect(store: env.store, sensors: env.sensors, inspector: env.inspector, readiness: readiness, now: now)
        if wasActive && snapshot?.session == nil { reloadHistory() }
        updatePulse()
    }

    func refreshReadiness() async {
        readiness = await env.readiness.check()
        refresh()
    }

    func refreshAgents() {
        agents = AgentDetector.detect(extraNames: config.extraAgentNames)
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.online = ok }
        }
        monitor.start(queue: DispatchQueue(label: "lidless.app.network"))
        pathMonitor = monitor
    }

    // MARK: Pulse animation

    /// Breathes only while awake with the lid open: no point animating a
    /// closed laptop, and it saves power during the session.
    private var shouldPulse: Bool {
        isActive && config.animateMenuBarIcon && snapshot?.lidClosed != true
    }

    private func updatePulse() {
        if shouldPulse, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pulsePhase = (self.pulsePhase + 1.0 / 36.0).truncatingRemainder(dividingBy: 1)  // 3 s cycle
                }
            }
        } else if !shouldPulse, let t = pulseTimer {
            t.invalidate()
            pulseTimer = nil
            pulsePhase = 0.35
        }
    }

    // MARK: Derived state

    var isActive: Bool { snapshot?.session != nil }
    var ownedHere: Bool { owner.session != nil }
    var isReady: Bool { readiness?.ready == true }
    var needsSetup: Bool { readiness.map { !$0.ready } ?? false }

    var remaining: TimeInterval {
        guard let s = snapshot?.session else { return 0 }
        return max(0, s.endsAt.timeIntervalSince(now))
    }

    /// Fraction of the session still left (1 → 0).
    var remainingFraction: Double {
        guard let s = snapshot?.session else { return 0 }
        let total = s.endsAt.timeIntervalSince(s.startedAt)
        return total > 0 ? min(1, max(0, remaining / total)) : 0
    }

    var menuBarText: String? {
        guard isActive else { return nil }
        let r = remaining
        if r >= 86_400 { return "\(Int(r / 86_400))d" }
        if r >= 3_600 { return "\(Int(r / 3_600)):\(String(format: "%02d", Int(r.truncatingRemainder(dividingBy: 3_600) / 60)))" }
        return "\(Int((r / 60).rounded(.up)))m"
    }

    var menuBarImage: NSImage {
        MenuBarGlyph.image(active: isActive, phase: isActive ? (pulseTimer != nil ? pulsePhase : 0.35) : nil)
    }

    var bundledCLIPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lidless").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: Session actions

    func start(_ raw: String) {
        do {
            start(seconds: try DurationParser.parse(raw))
            customDuration = ""
        } catch {
            errorText = "\(error)"
        }
    }

    /// Current thermal state (live, not cached).
    var thermal: ThermalLevel { env.sensors.thermal() }

    /// Every start goes through here. The ventilation warning is shown before
    /// the first session ever, and again whenever the Mac is already warm.
    func start(seconds: TimeInterval) {
        guard !busy else { return }
        errorText = nil
        let heat = thermal
        if config.thermalRules && heat == .critical {
            errorText = heat.startWarning
            return
        }
        if showHeatNotice || heat.isWarm {
            pendingStart = seconds
            return
        }
        beginSession(seconds)
    }

    func confirmStart() {
        guard let seconds = pendingStart else { return }
        pendingStart = nil
        if showHeatNotice { acknowledgeHeatNotice() }
        if config.thermalRules && thermal == .critical {
            errorText = ThermalLevel.critical.startWarning
            return
        }
        beginSession(seconds)
    }

    func cancelStart() {
        pendingStart = nil
    }

    private func beginSession(_ seconds: TimeInterval) {
        busy = true
        busyText = "Turning on…"
        Task {
            defer { busy = false; refresh() }
            do {
                try await owner.start(duration: seconds, kind: .app)
            } catch {
                errorText = "\(error)"
                await refreshReadiness()
            }
        }
    }

    func extend(_ seconds: TimeInterval) {
        errorText = nil
        do {
            if ownedHere {
                try owner.extend(by: seconds)
            } else {
                _ = try control.extend(by: seconds)
            }
        } catch {
            errorText = "\(error)"
        }
        refresh()
    }

    func stop() {
        guard !busy else { return }
        errorText = nil
        busy = true
        busyText = "Restoring normal sleep…"
        Task {
            defer { busy = false; refresh() }
            if ownedHere {
                await owner.end(.stopped)
                return
            }
            do {
                switch try control.requestStop() {
                case .requested(let id):
                    if await control.waitForEnd(sessionID: id, timeout: 45) == nil {
                        errorText = "The session owner did not finish in time. The recovery agent will finish the job."
                    }
                case .ownerDead:
                    let outcome = await env.recovery.run(forceEndReason: .stopped)
                    if !outcome.report.complete { errorText = outcome.message }
                }
            } catch {
                errorText = "\(error)"
            }
        }
    }

    func dismissError() { errorText = nil }

    #if DEBUG
    func debugSetPending(_ seconds: TimeInterval?) {
        pendingStart = seconds
    }

    func debugSetBusy(_ on: Bool) {
        busy = on
        busyText = "Turning on…"
    }
    #endif

    /// Hard rule 6: quitting always ends the session this app owns.
    func endForQuit() async {
        if ownedHere {
            await owner.end(.quit)
        }
        Log.shared.flush()
    }

    // MARK: Setup

    func runSetup() {
        guard !setupRunning else { return }
        guard let cli = bundledCLIPath else {
            setupMessage = "Setup needs the installed Lidless.app (the command-line helper inside it was not found)."
            return
        }
        setupRunning = true
        setupMessage = nil
        Task {
            defer { setupRunning = false }
            do {
                let report = try await Installer.setup(
                    cliPath: cli,
                    power: env.power,
                    elevation: .passwordDialog(prompt: "Lidless needs your password once to allow it to turn closed-lid sleep on and off.")
                )
                setupMessage = report.warnings.first
            } catch LidlessError.usage(let m) {
                setupMessage = m
            } catch {
                setupMessage = "\(error)"
            }
            await refreshReadiness()
        }
    }

    func runUninstall() {
        guard !setupRunning, !isActive else {
            setupMessage = "Stop the current session first."
            return
        }
        setupRunning = true
        setupMessage = nil
        Task {
            defer { setupRunning = false }
            do {
                _ = try await Installer.uninstall(env: env, elevation: .passwordDialog(prompt: "Lidless needs your password to remove its sleep permission."))
                setupMessage = "Lidless was removed from this Mac. Move Lidless.app to the Trash to finish."
            } catch LidlessError.usage(let m) {
                setupMessage = m
            } catch {
                setupMessage = "\(error)"
            }
            await refreshReadiness()
        }
    }

    // MARK: Misc

    func acknowledgeHeatNotice() {
        showHeatNotice = false
        try? env.store.paths.ensureHome()
        try? OwnerOnlyFile.write(Data(LidlessJSON.string(Date()).utf8), to: env.store.paths.firstRunMarker)
    }

    func saveConfig() {
        do {
            let dockChanged = env.store.readConfig().showInDock != config.showInDock
            try env.store.writeConfig(config)
            let saved = env.store.readConfig()
            if saved != config { config = saved }
            updatePulse()
            if dockChanged { onDockSettingChanged?() }
        } catch {
            errorText = "Could not save settings: \(error)"
        }
    }

    func openLog() {
        NSWorkspace.shared.open(env.store.paths.log)
    }

    /// The docs page on the website; mirrors `docs/HELP.md` in the repository.
    static let docsURL = "https://lidless.app/docs"

    func openHelp() {
        if let url = URL(string: Self.docsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettings() { onOpenSettings?() }
    func openPanel() { onOpenPanel?() }

    func nextTip() { tipIndex += 1 }

    func showCopied() { copiedAt = Date() }

    // MARK: Updates

    private static let lastCheckKey = "lastUpdateCheck"

    private func autoCheckForUpdates() {
        guard config.checkForUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool = true) {
        if case .checking = update { return }
        if case .downloading = update { return }
        update = .checking
        Task {
            do {
                let result = try await UpdateChecker.check()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                switch result {
                case .upToDate(let v): update = .upToDate(v)
                case .noReleases: update = .noReleases
                case .available(let r):
                    update = .available(r)
                    if !userInitiated {
                        env.notifier.notify(title: "Lidless \(r.version) is available", body: "Open Lidless → About & Updates to download it.")
                    }
                }
            } catch {
                update = userInitiated ? .failed("Could not reach GitHub. Check your connection and try again.") : .idle
            }
        }
    }

    var availableRelease: ReleaseInfo? {
        switch update {
        case .available(let r), .downloading(let r), .downloaded(let r, _): return r
        default: return nil
        }
    }

    /// Downloads the DMG to ~/Downloads and opens it.
    func downloadUpdate() {
        guard case .available(let release) = update else { return }
        guard release.downloadURL != nil else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        update = .downloading(release)
        Task {
            do {
                let file = try await UpdateChecker.download(release)
                update = .downloaded(release, file)
                NSWorkspace.shared.open(file)
            } catch {
                update = .failed("The download failed: \(error.localizedDescription)")
            }
        }
    }

    func revealDownload() {
        if case .downloaded(_, let url) = update {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(availableRelease?.pageURL ?? UpdateChecker.releasesPage)
    }

    func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    /// Fresh readings each time the panel opens.
    func panelWillOpen() {
        errorText = nil
        pendingStart = nil
        reloadHistory()
        refresh()
        refreshAgents()
        Task { await refreshReadiness() }
    }

    var loginItemAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorText = "Could not change the login item: \(error.localizedDescription)"
            }
        }
    }
}
