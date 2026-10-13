import Foundation
import IOKit.pwr_mgt

/// Everything the session owner touches outside its own memory. Tests swap in
/// fakes so no real power setting is ever changed.
public struct OwnerEnvironment: Sendable {
    public var store: Store
    public var power: PowerControlling
    public var sensors: SystemSensing
    public var inspector: ProcessInspecting
    public var readiness: Readiness
    public var notifier: Notifying
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async -> Void
    /// Holds an idle-sleep assertion; returns a release closure.
    public var holdAssertion: @Sendable (String) -> (@Sendable () -> Void)?
    public var tickInterval: TimeInterval
    public var watchNetwork: Bool

    public init(
        store: Store,
        power: PowerControlling,
        sensors: SystemSensing,
        inspector: ProcessInspecting,
        readiness: Readiness,
        notifier: Notifying,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
        holdAssertion: @escaping @Sendable (String) -> (@Sendable () -> Void)? = IdleSleepAssertion.hold,
        tickInterval: TimeInterval = 1,
        watchNetwork: Bool = true
    ) {
        self.store = store
        self.power = power
        self.sensors = sensors
        self.inspector = inspector
        self.readiness = readiness
        self.notifier = notifier
        self.now = now
        self.sleep = sleep
        self.holdAssertion = holdAssertion
        self.tickInterval = tickInterval
        self.watchNetwork = watchNetwork
    }

    /// The real macOS environment.
    public static func live(paths: LidlessPaths = .resolve(), notifier: Notifying) -> OwnerEnvironment {
        let runner = ProcessCommandRunner()
        let power = PmsetPowerControl(runner: runner)
        return OwnerEnvironment(
            store: Store(paths: paths),
            power: power,
            sensors: SystemSensors(),
            inspector: SystemProcessInspector(),
            readiness: Readiness(power: power, agent: LaunchdRecoveryAgentChecker(runner: runner)),
            notifier: notifier
        )
    }

    public var changes: JournaledChanges {
        JournaledChanges(store: store, power: power, now: now)
    }

    public var recovery: Recovery {
        Recovery(changes: changes, sensors: sensors, inspector: inspector)
    }
}

public enum IdleSleepAssertion {
    /// `PreventUserIdleSystemSleep` covers idle sleep with the lid open; it
    /// dies with the process, so a crash cannot leak it.
    public static let hold: @Sendable (String) -> (@Sendable () -> Void)? = { reason in
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard r == kIOReturnSuccess else {
            Log.warn("IOPMAssertionCreateWithName failed (\(r))")
            return nil
        }
        let assertionID = id
        return { IOPMAssertionRelease(assertionID) }
    }
}

/// Owns one session at a time (spec/session.md rule 3). Runs on the main actor
/// in both the menu bar app and the CLI holder.
@MainActor
public final class SessionOwner {
    public enum State: Equatable {
        case idle
        case starting
        case active(Session)
        case ending
    }

    public private(set) var state: State = .idle {
        didSet { onChange?() }
    }
    public private(set) var lastEnd: LastEnd?
    public private(set) var lidClosed: Bool?
    public private(set) var networkLost = false
    public private(set) var lowPowerActive = false
    public private(set) var warnings: [String] = []

    /// Called on every state change and tick.
    public var onChange: (@MainActor () -> Void)?
    /// `lidless run` sets this to end the session when the wrapped command exits.
    public var externalEndCheck: (@MainActor () -> EndReason?)?

    public let env: OwnerEnvironment
    private var config = Config()
    private var sleepOutcome: SleepEngageOutcome?
    private var releaseAssertion: (@Sendable () -> Void)?
    private var tickTask: Task<Void, Never>?
    private var endWaiters: [CheckedContinuation<LastEnd, Never>] = []
    private var tickCount = 0
    private var unreadableBattery = 0
    private var lidCandidate: Bool?
    private var lidCandidateTicks = 0
    private var lowPowerFailureNotified = false
    private var network: NetworkWatcher?
    private var lidClosedSince: Date?
    private var closedLidSeconds: TimeInterval = 0

    static let floorEveryTicks = 15
    static let verifyEveryTicks = 60
    static let lidDebounceTicks = 2

    public init(env: OwnerEnvironment) {
        self.env = env
    }

    public var session: Session? {
        if case .active(let s) = state { return s }
        return nil
    }

    // MARK: Start

    /// Starts a session and returns once the closed-lid awake state is
    /// verified. Throws (after restoring) if anything is not right.
    @discardableResult
    public func start(duration: TimeInterval, kind: OwnerIdentity.Kind, command: [String]? = nil) async throws -> Session {
        guard state == .idle else { throw LidlessError.sessionActive }
        state = .starting
        do {
            let session = try await engage(duration: duration, kind: kind, command: command)
            state = .active(session)
            beginWatching()
            notify("Lidless is on", "Your Mac stays awake with the lid closed until \(Self.timeString(session.endsAt)). Keep it on a ventilated surface, not in a bag.")
            return session
        } catch {
            state = .idle
            throw error
        }
    }

    private func engage(duration: TimeInterval, kind: OwnerIdentity.Kind, command: [String]?) async throws -> Session {
        config = env.store.readConfig()
        guard duration > 0 else { throw LidlessError.usage("Duration must be greater than zero.") }
        guard duration <= config.maxDurationSeconds else {
            throw LidlessError.usage("The longest session is \(DurationParser.format(config.maxDurationSeconds)).")
        }

        // Never start into a critical thermal state: the floor would end the
        // session at once, and closing the lid would trap more heat.
        if config.thermalRules && env.sensors.thermal() == .critical {
            throw LidlessError.notReady(ThermalLevel.critical.startWarning!)
        }

        // Hard rule 2: never start unless recovery is armed.
        let readiness = await env.readiness.check()
        if let error = readiness.notReadyError { throw error }

        // Clear up anything an earlier crashed owner left behind.
        let prior = await env.recovery.run(forceEndReason: .ownerLost)
        if prior.action != .nothing {
            Log.info("before start: \(prior.message)")
        }

        let now = env.now()
        let session = Session(
            startedAt: now,
            endsAt: now.addingTimeInterval(duration),
            owner: env.inspector.currentIdentity(kind: kind),
            command: command
        )
        try env.store.withLock {
            switch env.store.readSession() {
            case .some(let existing) where env.inspector.isAlive(existing.owner):
                throw LidlessError.sessionActive
            case .some, .unreadable:
                throw LidlessError.system("A previous session could not be cleaned up. Run `lidless status` for details.")
            case .none:
                break
            }
            if !(try env.store.readJournal().isEmpty) {
                throw LidlessError.restoreIncomplete("Settings from an earlier session are still waiting to be restored, so Lidless will not start a new one. Run `lidless recover` or `lidless doctor`.")
            }
            try env.store.writeSession(session)
        }
        Log.info("session \(session.id) starting for \(DurationParser.format(duration)), owner \(kind.rawValue) pid \(session.owner.pid)")

        do {
            sleepOutcome = try await env.changes.disableSleep()
            // Hard rule 3: read back after a settle delay.
            await env.sleep(config.verifySettleSeconds)
            let engaged = try? await env.power.readSleepDisabled()
            guard engaged == true else {
                throw LidlessError.verificationFailed(engaged == nil
                    ? "Lidless could not read the sleep setting back after enabling it, so it cannot promise the Mac will stay awake. Settings were restored."
                    : "macOS turned closed-lid sleep back on within \(Int(config.verifySettleSeconds)) s, so closing the lid would still sleep this Mac. Settings were restored.")
            }
        } catch {
            await abortStart(session, error: error)
            throw error
        }

        releaseAssertion = env.holdAssertion("Lidless session until \(LidlessJSON.string(session.endsAt))")
        Log.info("session \(session.id) engaged and verified (\(sleepOutcome == .alreadyDisabled ? "sleep was already disabled by something else" : "SleepDisabled set by Lidless"))")
        return session
    }

    private func abortStart(_ session: Session, error: Error) async {
        Log.error("session \(session.id) failed to start: \(error)")
        try? env.store.withLock {
            if case .some(let cur) = env.store.readSession(), cur.id == session.id {
                try env.store.removeSession()
            }
        }
        let report = await env.changes.restoreAll()
        sleepOutcome = nil
        let le = LastEnd(sessionID: session.id, reason: .startFailed, at: env.now(), restoreComplete: report.complete,
                         detail: "\(error)" + (report.complete ? "" : " Restore incomplete: \(report.failures.joined(separator: "; "))"))
        try? env.store.writeLastEnd(le)
        lastEnd = le
    }

    // MARK: Watching

    private func beginWatching() {
        tickCount = 0
        unreadableBattery = 0
        lidClosed = env.sensors.lidClosed()
        lidCandidate = lidClosed
        closedLidSeconds = 0
        lidClosedSince = lidClosed == true ? env.now() : nil
        lowPowerFailureNotified = false
        networkLost = false
        warnings = []
        if env.watchNetwork && config.warnOnNetworkLoss {
            let watcher = NetworkWatcher { [weak self] lost in
                guard let self else { return }
                self.networkLost = lost
                if lost {
                    self.notify("Network lost", "This Mac is offline, so remote control cannot reach your agent. Lidless keeps it awake and will tell you when it is back.")
                } else {
                    self.notify("Network back", "This Mac is online again.")
                }
            }
            watcher.start()
            network = watcher
        }
        let interval = env.tickInterval
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if let reason = await self.tick() {
                    await self.end(reason.0, detail: reason.1)
                    return
                }
            }
        }
    }

    /// One owner tick. Returns a reason when the session must end.
    func tick() async -> (EndReason, String?)? {
        guard case .active(var s) = state else { return nil }
        tickCount += 1
        let now = env.now()

        // Pick up `extend` / `stop` written by other processes.
        switch env.store.readSession() {
        case .none:
            return (.stopped, "The session file was removed.")
        case .unreadable(let why):
            return (.stopped, "The session file became unreadable: \(why)")
        case .some(let fresh):
            guard fresh.id == s.id else { return (.ownerLost, "Another session replaced this one.") }
            if fresh != s {
                s = fresh
                state = .active(s)
            }
        }
        if s.stopRequested != nil { return (.stopped, nil) }
        if s.isExpired(at: now) { return (.expired, nil) }
        if let r = externalEndCheck?() { return (r, nil) }

        var runFloors = tickCount % Self.floorEveryTicks == 1
        if updateLid() {
            runFloors = true
            if lidClosed == true {
                lidClosedSince = now
                Log.info("lid closed")
                if config.sleepDisplayOnLidClose { await env.power.sleepDisplayNow() }
            } else {
                if let since = lidClosedSince { closedLidSeconds += now.timeIntervalSince(since) }
                lidClosedSince = nil
                Log.info("lid opened")
            }
        }
        if runFloors, let reason = await applyFloors() {
            return (reason, nil)
        }
        if tickCount % Self.verifyEveryTicks == 0, let failure = await reverify() {
            return (.verificationFailed, failure)
        }
        network?.tick(now: now)
        onChange?()
        return nil
    }

    /// Debounced lid state; returns true when it changed.
    private func updateLid() -> Bool {
        let raw = env.sensors.lidClosed()
        if raw == lidCandidate {
            lidCandidateTicks += 1
        } else {
            lidCandidate = raw
            lidCandidateTicks = 1
        }
        if lidCandidate != lidClosed && lidCandidateTicks >= Self.lidDebounceTicks {
            lidClosed = lidCandidate
            return true
        }
        return false
    }

    private func applyFloors() async -> EndReason? {
        let battery = env.sensors.battery()
        let onBattery = battery.hasBattery && battery.onBattery
        unreadableBattery = (onBattery && battery.percent == nil) ? unreadableBattery + 1 : 0
        let decision = FloorRules.decide(
            onBattery: onBattery,
            percent: battery.percent,
            unreadableCount: unreadableBattery,
            thermal: env.sensors.thermal(),
            lidClosed: lidClosed == true,
            config: config
        )
        if let end = decision.end { return end }

        if decision.wantLowPower && !lowPowerActive {
            do {
                lowPowerActive = try await env.changes.enableLowPower()
                if lowPowerActive { Log.info("Low Power Mode on (floor or lid rule)") }
            } catch {
                Log.error("could not enable Low Power Mode: \(error)")
                if !lowPowerFailureNotified {
                    lowPowerFailureNotified = true
                    notify("Low Power Mode not enabled", "\(error)")
                }
            }
        } else if !decision.wantLowPower && lowPowerActive {
            do {
                let report = try await env.changes.releaseLowPower()
                lowPowerActive = !report.complete
                if report.complete { Log.info("Low Power Mode released") }
            } catch {
                Log.error("could not release Low Power Mode: \(error)")
            }
        }
        return nil
    }

    /// macOS has been seen silently reverting SleepDisabled; check it during
    /// the session too, and re-apply once before giving up.
    private func reverify() async -> String? {
        guard let still = try? await env.power.readSleepDisabled() else {
            return nil  // a single failed read is not proof of a revert
        }
        if still { return nil }
        Log.warn("SleepDisabled reverted to 0 during the session; re-applying once")
        do {
            sleepOutcome = try await env.changes.disableSleep()
            await env.sleep(config.verifySettleSeconds)
            if try await env.power.readSleepDisabled() { return nil }
        } catch {
            return "macOS turned closed-lid sleep back on and Lidless could not re-apply it: \(error)"
        }
        return "macOS turned closed-lid sleep back on and kept it on after Lidless re-applied it."
    }

    // MARK: Extend / stop (owner-local)

    /// Extends the session. Other processes use `SessionControl.extend`.
    @discardableResult
    public func extend(by seconds: TimeInterval) throws -> (Session, clamped: Bool) {
        guard session != nil else { throw LidlessError.noSession }
        let result = try SessionControl(store: env.store, inspector: env.inspector, now: env.now).extend(by: seconds)
        state = .active(result.0)
        return result
    }

    // MARK: End

    /// Ends the session and restores everything. Safe to call more than once.
    @discardableResult
    public func end(_ reason: EndReason, detail: String? = nil) async -> LastEnd {
        switch state {
        case .ending:
            return await withCheckedContinuation { endWaiters.append($0) }
        case .idle, .starting:
            return lastEnd ?? LastEnd(sessionID: nil, reason: reason, at: env.now(), restoreComplete: true)
        case .active(let s):
            state = .ending
            tickTask?.cancel()
            tickTask = nil
            network?.stop()
            network = nil
            releaseAssertion?()
            releaseAssertion = nil

            // Remove the session first: a crash after this leaves
            // "no session + journal entries", which recovery restores.
            do {
                try env.store.withLock {
                    if case .some(let cur) = env.store.readSession(), cur.id == s.id {
                        try env.store.removeSession()
                    }
                }
            } catch {
                Log.error("could not remove session file: \(error)")
            }
            let report = await env.changes.restoreAll()
            let failureText = report.failures.joined(separator: "; ")
            let le = LastEnd(
                sessionID: s.id,
                reason: reason,
                at: env.now(),
                restoreComplete: report.complete,
                detail: [detail, report.complete ? nil : "Restore incomplete: \(failureText)"].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            )
            try? env.store.writeLastEnd(le)
            if let since = lidClosedSince { closedLidSeconds += le.at.timeIntervalSince(since) }
            lidClosedSince = nil
            History.append(HistoryEntry(
                id: s.id, startedAt: s.startedAt, endedAt: le.at, reason: reason,
                closedLidSeconds: closedLidSeconds, owner: s.owner.kind, command: s.command,
                restoreComplete: report.complete
            ), store: env.store)
            Log.info("session \(s.id) ended: \(reason.rawValue)\(detail.map { " (\($0))" } ?? ""); restore complete=\(report.complete)")
            sleepOutcome = nil
            lowPowerActive = false
            lidClosed = nil
            lastEnd = le
            state = .idle

            if report.complete {
                notify("Lidless is off", reason.summary + (detail.map { " \($0)" } ?? "") + " Normal sleep is back.")
            } else {
                notify("Lidless could not restore everything", "\(failureText) The recovery agent will keep retrying every minute.")
            }
            let waiters = endWaiters
            endWaiters = []
            waiters.forEach { $0.resume(returning: le) }
            return le
        }
    }

    /// Waits until the current session ends (returns at once when idle).
    public func waitForEnd() async -> LastEnd {
        if case .active = state {
            return await withCheckedContinuation { endWaiters.append($0) }
        }
        if case .ending = state {
            return await withCheckedContinuation { endWaiters.append($0) }
        }
        return lastEnd ?? LastEnd(sessionID: nil, reason: .stopped, at: env.now(), restoreComplete: true)
    }

    // MARK: Helpers

    private func notify(_ title: String, _ body: String) {
        guard config.notifications else { return }
        env.notifier.notify(title: title, body: body)
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
