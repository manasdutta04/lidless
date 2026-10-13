import AppKit
import LidlessCore
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
    var config: Config
    var showHeatNotice: Bool
    // View state lives here: the Command Line Tools have no SwiftUIMacros
    // plugin, so `@State` cannot be used in views.
    var customDuration = ""
    var showSettings = false

    private var timer: Timer?
    private var tick = 0

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
        Task { await self.launch() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
    }

    private func launch() async {
        // Finish anything a crashed earlier run left behind.
        let outcome = await env.recovery.run()
        if outcome.action != .nothing { Log.info("app launch recovery: \(outcome.message)") }
        await refreshReadiness()
        refreshAgents()
        refresh()
    }

    private func timerFired() {
        now = Date()
        tick += 1
        if tick % 2 == 0 { refresh() }
        if tick % 5 == 0 { refreshAgents() }
        if tick % 30 == 0 { Task { await refreshReadiness() } }
    }

    func refresh() {
        now = Date()
        snapshot = StatusSnapshot.collect(store: env.store, sensors: env.sensors, inspector: env.inspector, readiness: readiness, now: now)
    }

    func refreshReadiness() async {
        readiness = await env.readiness.check()
        refresh()
    }

    func refreshAgents() {
        agents = AgentDetector.detect(extraNames: config.extraAgentNames)
    }

    // MARK: Derived state

    var isActive: Bool { snapshot?.session != nil }
    var ownedHere: Bool { owner.session != nil }

    var remaining: TimeInterval {
        guard let s = snapshot?.session else { return 0 }
        return max(0, s.endsAt.timeIntervalSince(now))
    }

    var menuBarText: String? {
        guard isActive else { return nil }
        let r = remaining
        if r >= 86_400 { return "\(Int(r / 86_400))d" }
        if r >= 3_600 { return "\(Int(r / 3_600))h\(String(format: "%02d", Int(r.truncatingRemainder(dividingBy: 3_600) / 60)))" }
        return "\(Int(r / 60))m"
    }

    // MARK: Actions

    func start(_ raw: String) {
        do {
            let seconds = try DurationParser.parse(raw)
            start(seconds: seconds)
        } catch {
            errorText = "\(error)"
        }
    }

    func start(seconds: TimeInterval) {
        guard !busy else { return }
        errorText = nil
        busy = true
        busyText = "Engaging and verifying…"
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

    /// Hard rule 6: quitting always ends the session this app owns.
    func endForQuit() async {
        if ownedHere {
            await owner.end(.quit)
        }
        Log.shared.flush()
    }

    func acknowledgeHeatNotice() {
        showHeatNotice = false
        let url = env.store.paths.firstRunMarker
        try? env.store.paths.ensureHome()
        try? OwnerOnlyFile.write(Data(LidlessJSON.string(Date()).utf8), to: url)
    }

    func saveConfig() {
        do {
            try env.store.writeConfig(config)
            config = env.store.readConfig()
        } catch {
            errorText = "Could not save settings: \(error)"
        }
    }

    func openLog() {
        NSWorkspace.shared.open(env.store.paths.log)
    }

    // MARK: Login item

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
