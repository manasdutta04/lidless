import Foundation
import Testing
@testable import LidlessCore

struct RecoveryPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let healthy = BatteryReading(hasBattery: true, onBattery: true, percent: 80)

    func session(endsIn: TimeInterval, stop: String? = nil) -> Session {
        var s = Session(startedAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(endsIn),
                        owner: OwnerIdentity(kind: .cli, pid: 99999, startTime: 1, bootSession: "boot-A"))
        s.stopRequested = stop
        return s
    }

    func decide(_ read: SessionRead, journalEmpty: Bool = false, alive: Bool = false, sameBoot: Bool = true,
                battery: BatteryReading? = nil, thermal: ThermalLevel = .nominal) -> RecoveryAction {
        RecoveryPolicy.decide(session: read, journalEmpty: journalEmpty, ownerAlive: alive, sameBoot: sameBoot,
                              now: now, battery: battery ?? healthy, thermal: thermal, config: Config())
    }

    @Test func cleanStateDoesNothing() {
        #expect(decide(.none, journalEmpty: true) == .nothing)
    }

    @Test func leftoverJournalIsRestored() {
        #expect(decide(.none, journalEmpty: false) == .restoreJournal)
    }

    @Test func liveOwnerIsLeftAlone() {
        #expect(decide(.some(session(endsIn: -100)), alive: true) == .nothing)
    }

    @Test func deadOwnerWithTimeLeftKeepsAwake() {
        #expect(decide(.some(session(endsIn: 600))) == .keepOrphan)
    }

    @Test func deadOwnerExpired() {
        #expect(decide(.some(session(endsIn: -1))) == .endSession(.expired))
    }

    @Test func rebootEndsImmediately() {
        #expect(decide(.some(session(endsIn: 600)), sameBoot: false) == .endSession(.rebooted))
    }

    @Test func pendingStopIsHonoured() {
        #expect(decide(.some(session(endsIn: 600, stop: "user"))) == .endSession(.stopped))
    }

    @Test func orphanBatteryFloorEnforced() {
        let low = BatteryReading(hasBattery: true, onBattery: true, percent: 4)
        #expect(decide(.some(session(endsIn: 600)), battery: low) == .endSession(.batteryFloor))
    }

    @Test func orphanThermalFloorEnforced() {
        #expect(decide(.some(session(endsIn: 600)), thermal: .critical) == .endSession(.thermalFloor))
    }

    @Test func unreadableSessionIsQuarantined() {
        #expect(decide(.unreadable("bad json")) == .quarantineAndRestore)
    }
}

struct RecoveryRunTests {
    func recovery(_ h: Harness) -> Recovery {
        h.env().recovery
    }

    /// Owner crashed after engaging: journal + session with a dead pid.
    func simulateCrash(_ h: Harness, endsIn: TimeInterval, boot: String = "boot-A") throws -> Session {
        h.power.sleepDisabled = true
        var j = Journal()
        j.macos.sleepDisabled = BoolEntry(original: false, recordedAt: h.clock.now)
        try h.store.writeJournal(j)
        let s = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(endsIn),
                        owner: OwnerIdentity(kind: .app, pid: 99999, startTime: 42, bootSession: boot))
        try h.store.writeSession(s)
        return s
    }

    @Test func crashedExpiredSessionIsRestored() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let s = try simulateCrash(h, endsIn: -5)
        let out = await recovery(h).run()
        #expect(out.action == .endSession(.expired))
        #expect(out.report.complete)
        #expect(!h.power.sleepDisabled)
        #expect(h.journal().isEmpty)
        #expect(h.store.readSession() == .none)
        #expect(h.store.readLastEnd()?.sessionID == s.id)
    }

    @Test func crashedLiveSessionKeepsAwakeUntilExpiry() async throws {
        let h = Harness()
        defer { h.cleanup() }
        _ = try simulateCrash(h, endsIn: 600)
        let out = await recovery(h).run()
        #expect(out.action == .keepOrphan)
        #expect(h.power.sleepDisabled)
        #expect(!h.journal().isEmpty)

        h.clock.advance(601)
        let later = await recovery(h).run()
        #expect(later.action == .endSession(.expired))
        #expect(!h.power.sleepDisabled)
    }

    @Test func stopForcesOrphanEnd() async throws {
        let h = Harness()
        defer { h.cleanup() }
        _ = try simulateCrash(h, endsIn: 600)
        let out = await recovery(h).run(forceEndReason: .stopped)
        #expect(out.action == .endSession(.stopped))
        #expect(!h.power.sleepDisabled)
    }

    @Test func rebootRestoresImmediately() async throws {
        let h = Harness()
        defer { h.cleanup() }
        _ = try simulateCrash(h, endsIn: 600, boot: "boot-OLD")
        let out = await recovery(h).run()
        #expect(out.action == .endSession(.rebooted))
        #expect(!h.power.sleepDisabled)
    }

    @Test func crashMidRestoreIsFinished() async throws {
        // Owner removed the session file, then died before restoring.
        let h = Harness()
        defer { h.cleanup() }
        _ = try simulateCrash(h, endsIn: 600)
        try h.store.removeSession()
        let out = await recovery(h).run()
        #expect(out.action == .restoreJournal)
        #expect(!h.power.sleepDisabled)
        #expect(h.journal().isEmpty)
    }

    @Test func unreadableSessionMovedAsideNotDeleted() async throws {
        let h = Harness()
        defer { h.cleanup() }
        _ = try simulateCrash(h, endsIn: 600)
        try OwnerOnlyFile.write(Data("{not json".utf8), to: h.paths.session)
        let out = await recovery(h).run()
        #expect(out.action == .quarantineAndRestore)
        #expect(!h.power.sleepDisabled)
        let files = try FileManager.default.contentsOfDirectory(atPath: h.home.path)
        #expect(files.contains { $0.hasPrefix("session.json.unreadable-") })
        #expect(!files.contains("session.json"))
    }

    @Test func unreadableJournalIsNeverTreatedAsClean() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.power.sleepDisabled = true
        try OwnerOnlyFile.write(Data("garbage".utf8), to: h.paths.journal)
        let out = await recovery(h).run()
        #expect(out.action == .nothing)
        #expect(h.power.sleepDisabled, "must not guess what to restore")
        #expect(FileManager.default.fileExists(atPath: h.paths.journal.path))
    }

    @Test func failedRestoreIsRetriedNextRun() async throws {
        let h = Harness()
        defer { h.cleanup() }
        _ = try simulateCrash(h, endsIn: -1)
        h.power.failSetSleep = true
        let first = await recovery(h).run()
        #expect(!first.report.complete)
        #expect(!h.journal().isEmpty)

        h.power.failSetSleep = false
        let second = await recovery(h).run()
        #expect(second.action == .restoreJournal)
        #expect(second.report.complete)
        #expect(!h.power.sleepDisabled)
    }

    @Test func stopOnDeadOwnerReportsOwnerDead() throws {
        let h = Harness()
        defer { h.cleanup() }
        let s = try simulateCrash(h, endsIn: 600)
        let control = SessionControl(store: h.store, inspector: h.inspector)
        #expect(try control.requestStop() == .ownerDead(sessionID: s.id))
    }

    @Test func extendWithoutSessionFails() {
        let h = Harness()
        defer { h.cleanup() }
        let control = SessionControl(store: h.store, inspector: h.inspector)
        #expect(throws: LidlessError.noSession) { try control.extend(by: 60) }
    }
}
