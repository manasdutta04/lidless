import Foundation
@testable import LidlessCore

/// Fake pmset. Never touches the real system.
final class FakePower: PowerControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleepDisabled = false
    private var _lowPower = false
    private var _calls: [String] = []

    var privilege = true
    var failSetSleep = false
    var failSetLowPower = false
    var failReadSleep = false
    /// Simulates macOS silently reverting `disablesleep 1`.
    var revertSleepAfterSet = false
    /// Called just before a privileged change runs (to assert journal-before-change).
    var beforeChange: (@Sendable (String) -> Void)?

    var sleepDisabled: Bool {
        get { lock.withLock { _sleepDisabled } }
        set { lock.withLock { _sleepDisabled = newValue } }
    }
    var lowPower: Bool {
        get { lock.withLock { _lowPower } }
        set { lock.withLock { _lowPower = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }

    private func record(_ c: String) { lock.withLock { _calls.append(c) } }

    func readSleepDisabled() async throws -> Bool {
        record("read sleep")
        if failReadSleep { throw LidlessError.system("fake read failure") }
        return sleepDisabled
    }

    func setSleepDisabled(_ disabled: Bool) async -> CommandResult {
        let c = "disablesleep \(disabled ? 1 : 0)"
        beforeChange?(c)
        record(c)
        if failSetSleep { return CommandResult(status: 1, stderr: "sudo: a password is required") }
        sleepDisabled = revertSleepAfterSet ? false : disabled
        return CommandResult(status: 0)
    }

    func readLowPowerMode() async throws -> Bool {
        record("read lowpower")
        return lowPower
    }

    func setLowPowerMode(_ on: Bool) async -> CommandResult {
        let c = "lowpowermode \(on ? 1 : 0)"
        beforeChange?(c)
        record(c)
        if failSetLowPower { return CommandResult(status: 1, stderr: "failed") }
        lowPower = on
        return CommandResult(status: 0)
    }

    func sleepDisplayNow() async { record("displaysleepnow") }

    func privilegeReady() async -> Bool { privilege }
}

final class FakeSensors: SystemSensing, @unchecked Sendable {
    private let lock = NSLock()
    private var _battery = BatteryReading(hasBattery: true, onBattery: false, percent: 90)
    private var _thermal = ThermalLevel.nominal
    private var _lid: Bool? = false

    var batteryReading: BatteryReading {
        get { lock.withLock { _battery } }
        set { lock.withLock { _battery = newValue } }
    }
    var thermalLevel: ThermalLevel {
        get { lock.withLock { _thermal } }
        set { lock.withLock { _thermal = newValue } }
    }
    var lid: Bool? {
        get { lock.withLock { _lid } }
        set { lock.withLock { _lid = newValue } }
    }

    func battery() -> BatteryReading { batteryReading }
    func thermal() -> ThermalLevel { thermalLevel }
    func lidClosed() -> Bool? { lid }
}

final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _alive: Set<Int32> = [getpid()]
    var boot = "boot-A"

    var alive: Set<Int32> {
        get { lock.withLock { _alive } }
        set { lock.withLock { _alive = newValue } }
    }

    func startTime(of pid: Int32) -> Int64? { alive.contains(pid) ? 42 : nil }
    func bootSession() -> String { boot }
}

struct FakeAgentChecker: RecoveryAgentChecking {
    var armed = true
    func check() async -> (armed: Bool, detail: String) { (armed, armed ? "fake armed" : "fake not armed") }
}

final class FakeNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    var sent: [String] { lock.withLock { _sent } }
    func notify(title: String, body: String) { lock.withLock { _sent.append(title) } }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

struct Harness {
    let home: URL
    let paths: LidlessPaths
    let store: Store
    let power = FakePower()
    let sensors = FakeSensors()
    let inspector = FakeInspector()
    let notifier = FakeNotifier()
    let clock = FakeClock()
    var agentArmed = true

    init() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidless-tests-\(UUID().uuidString)", isDirectory: true)
        paths = LidlessPaths(home: home)
        store = Store(paths: paths)
        try! paths.ensureHome()
        var cfg = Config()
        cfg.verifySettleSeconds = 0
        try! store.writeConfig(cfg)
    }

    func env() -> OwnerEnvironment {
        let clock = self.clock
        return OwnerEnvironment(
            store: store,
            power: power,
            sensors: sensors,
            inspector: inspector,
            readiness: Readiness(power: power, agent: FakeAgentChecker(armed: agentArmed)),
            notifier: notifier,
            now: { clock.now },
            sleep: { _ in },
            holdAssertion: { _ in { } },
            tickInterval: 3600,
            watchNetwork: false
        )
    }

    func journal() -> Journal { try! store.readJournal() }

    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

/// Repo-root `spec/vectors/<name>`.
func loadVector(_ name: String) throws -> Any {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LidlessCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // macos
        .deletingLastPathComponent()  // repo root
    let data = try Data(contentsOf: root.appendingPathComponent("spec/vectors/\(name)"))
    return try JSONSerialization.jsonObject(with: data)
}
