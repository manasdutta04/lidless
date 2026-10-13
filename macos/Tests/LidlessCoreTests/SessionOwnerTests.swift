import Foundation
import Testing
@testable import LidlessCore

@MainActor
struct SessionOwnerTests {
    @Test func startEngagesVerifiesAndEndRestores() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())

        let s = try await owner.start(duration: 3600, kind: .app)
        #expect(h.power.sleepDisabled)
        #expect(h.journal().macos.sleepDisabled?.original == false)
        guard case .some(let onDisk) = h.store.readSession() else { Issue.record("no session file"); return }
        #expect(onDisk.id == s.id)
        #expect(onDisk.endsAt == h.clock.now.addingTimeInterval(3600))

        let le = await owner.end(.stopped)
        #expect(le.restoreComplete)
        #expect(!h.power.sleepDisabled)
        #expect(h.journal().isEmpty)
        #expect(h.store.readSession() == .none)
        #expect(h.store.readLastEnd()?.reason == .stopped)
        #expect(owner.state == .idle)
    }

    @Test func journalIsWrittenBeforeEveryChange() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let store = h.store
        let seen = Box<[String]>([])
        h.power.beforeChange = { change in
            let j = try! store.readJournal()
            if change == "disablesleep 1" && j.macos.sleepDisabled == nil { seen.value.append("unjournaled \(change)") }
            if change == "lowpowermode 1" && j.macos.lowPowerMode == nil { seen.value.append("unjournaled \(change)") }
        }
        h.sensors.batteryReading = BatteryReading(hasBattery: true, onBattery: true, percent: 30)
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 600, kind: .cli)
        _ = await owner.tick()  // floors run on the first tick → Low Power Mode
        #expect(h.power.lowPower)
        #expect(seen.value.isEmpty, "\(seen.value)")
        await owner.end(.stopped)
        #expect(!h.power.lowPower)
    }

    @Test func refusesWhenRecoveryNotArmed() async {
        var h = Harness()
        h.agentArmed = false
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        await #expect(throws: LidlessError.self) { try await owner.start(duration: 600, kind: .app) }
        #expect(!h.power.calls.contains("disablesleep 1"))
        #expect(h.store.readSession() == .none)
    }

    @Test func refusesWithoutPrivilege() async {
        let h = Harness()
        defer { h.cleanup() }
        h.power.privilege = false
        let owner = SessionOwner(env: h.env())
        do {
            try await owner.start(duration: 600, kind: .app)
            Issue.record("should have thrown")
        } catch let e as LidlessError {
            #expect(e.exitCode == 3)
        } catch {
            Issue.record("\(error)")
        }
        #expect(h.power.calls.isEmpty || !h.power.calls.contains("disablesleep 1"))
    }

    @Test func revertedSettingFailsStartAndRestores() async {
        let h = Harness()
        defer { h.cleanup() }
        h.power.revertSleepAfterSet = true
        let owner = SessionOwner(env: h.env())
        do {
            try await owner.start(duration: 600, kind: .app)
            Issue.record("should have thrown")
        } catch let e as LidlessError {
            #expect(e.exitCode == 4)
        } catch {
            Issue.record("\(error)")
        }
        #expect(owner.state == .idle)
        #expect(h.store.readSession() == .none)
        #expect(h.journal().isEmpty)
        #expect(h.store.readLastEnd()?.reason == .startFailed)
    }

    @Test func failedEngageCommandLeavesNoJournalBehind() async {
        let h = Harness()
        defer { h.cleanup() }
        h.power.failSetSleep = true
        let owner = SessionOwner(env: h.env())
        await #expect(throws: LidlessError.self) { try await owner.start(duration: 600, kind: .app) }
        // The value never changed, so restore clears the entry without running anything.
        #expect(h.journal().isEmpty)
        #expect(!h.power.calls.contains("disablesleep 0"))
    }

    @Test func sleepAlreadyDisabledBySomeoneElseIsNotRestored() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.power.sleepDisabled = true
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 600, kind: .app)
        #expect(h.journal().macos.sleepDisabled == nil)
        await owner.end(.stopped)
        #expect(h.power.sleepDisabled, "Lidless must not restore a value it did not change")
        #expect(!h.power.calls.contains("disablesleep 0"))
    }

    @Test func expiryEndsSession() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 60, kind: .app)
        #expect(await owner.tick() == nil)
        h.clock.advance(61)
        let r = await owner.tick()
        #expect(r?.0 == .expired)
    }

    @Test func externalStopAndExtendArePickedUp() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        let s = try await owner.start(duration: 60, kind: .app)
        let clock = h.clock
        let control = SessionControl(store: h.store, inspector: h.inspector, now: { clock.now })

        let (extended, clamped) = try control.extend(by: 3600)
        #expect(!clamped)
        h.clock.advance(120)
        #expect(await owner.tick() == nil)
        #expect(owner.session?.endsAt == extended.endsAt)

        #expect(try control.requestStop() == .requested(sessionID: s.id))
        #expect(await owner.tick()?.0 == .stopped)
    }

    @Test func extendIsCappedAtMaximum() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 29 * 86_400, kind: .app)
        let clock = h.clock
        let control = SessionControl(store: h.store, inspector: h.inspector, now: { clock.now })
        let (s, clamped) = try control.extend(by: 5 * 86_400)
        #expect(clamped)
        #expect(s.endsAt == h.clock.now.addingTimeInterval(30 * 86_400))
    }

    @Test func refusesToStartWhenCritical() async {
        let h = Harness()
        defer { h.cleanup() }
        h.sensors.thermalLevel = .critical
        let owner = SessionOwner(env: h.env())
        await #expect(throws: LidlessError.self) { try await owner.start(duration: 600, kind: .app) }
        #expect(!h.power.calls.contains("disablesleep 1"))
    }

    @Test func thermalWarningsEscalate() {
        #expect(ThermalLevel.nominal.startWarning == nil)
        #expect(ThermalLevel.fair.isWarm && ThermalLevel.serious.isWarm)
        #expect(!ThermalLevel.nominal.isWarm)
        #expect(ThermalLevel.fair < ThermalLevel.critical)
    }

    @Test func tooLongDurationRejected() async {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        await #expect(throws: LidlessError.self) { try await owner.start(duration: 31 * 86_400, kind: .app) }
        #expect(h.power.calls.isEmpty)
    }

    @Test func secondSessionRefusedWhileFirstIsLive() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let first = SessionOwner(env: h.env())
        try await first.start(duration: 600, kind: .app)
        let second = SessionOwner(env: h.env())
        do {
            try await second.start(duration: 600, kind: .cli)
            Issue.record("should have thrown")
        } catch let e as LidlessError {
            #expect(e == .sessionActive)
        } catch {
            Issue.record("\(error)")
        }
        #expect(h.power.sleepDisabled, "the first session must be untouched")
    }

    @Test func batteryFloorEndsSession() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 600, kind: .app)
        h.sensors.batteryReading = BatteryReading(hasBattery: true, onBattery: true, percent: 5)
        #expect(await owner.tick()?.0 == .batteryFloor)
    }

    @Test func lidCloseSleepsDisplayAndEnablesLowPowerOnBattery() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.sensors.batteryReading = BatteryReading(hasBattery: true, onBattery: true, percent: 80)
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 600, kind: .app)
        _ = await owner.tick()  // first tick runs floors: lid open, 80% → no LPM
        #expect(!h.power.lowPower)

        h.sensors.lid = true
        _ = await owner.tick()  // debounce
        _ = await owner.tick()
        #expect(owner.lidClosed == true)
        #expect(h.power.calls.contains("displaysleepnow"))
        #expect(h.power.lowPower)
        #expect(h.journal().macos.lowPowerMode != nil)

        h.sensors.lid = false
        _ = await owner.tick()
        _ = await owner.tick()
        #expect(owner.lidClosed == false)
        #expect(!h.power.lowPower)
        #expect(h.journal().macos.lowPowerMode == nil)
    }

    @Test func userLowPowerModeIsNeverTurnedOff() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.power.lowPower = true  // the user already had it on
        h.sensors.batteryReading = BatteryReading(hasBattery: true, onBattery: true, percent: 20)
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 600, kind: .app)
        _ = await owner.tick()
        #expect(h.journal().macos.lowPowerMode == nil)
        await owner.end(.stopped)
        #expect(h.power.lowPower)
    }

    @Test func midSessionRevertIsReappliedOnce() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 7200, kind: .app)
        h.power.sleepDisabled = false  // macOS reverted it
        var result: (EndReason, String?)?
        for _ in 0..<SessionOwner.verifyEveryTicks { result = await owner.tick() }
        #expect(result == nil)
        #expect(h.power.sleepDisabled)

        h.power.sleepDisabled = false
        h.power.revertSleepAfterSet = true
        for _ in 0..<SessionOwner.verifyEveryTicks { result = await owner.tick() }
        #expect(result?.0 == .verificationFailed)
    }

    @Test func externalEndCheckEndsRunSession() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        let exited = Box(false)
        owner.externalEndCheck = { exited.value ? .commandExited : nil }
        try await owner.start(duration: 600, kind: .run, command: ["claude"])
        #expect(await owner.tick() == nil)
        exited.value = true
        #expect(await owner.tick()?.0 == .commandExited)
    }

    @Test func failedRestoreKeepsJournalEntry() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 600, kind: .app)
        h.power.failSetSleep = true
        let le = await owner.end(.stopped)
        #expect(!le.restoreComplete)
        #expect(h.journal().macos.sleepDisabled != nil)
        #expect(h.store.readSession() == .none)
    }

    @Test func stateFilesAreOwnerOnly() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = SessionOwner(env: h.env())
        try await owner.start(duration: 600, kind: .app)
        for url in [h.paths.session, h.paths.journal, h.paths.config] {
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
            #expect(perms == 0o600, "\(url.lastPathComponent)")
        }
        let dirPerms = try FileManager.default.attributesOfItem(atPath: h.home.path)[.posixPermissions] as! Int
        #expect(dirPerms == 0o700)
        await owner.end(.stopped)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
