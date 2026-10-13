import Foundation

public enum RecoveryAction: Sendable, Equatable {
    /// Nothing to do (no session and clean journal, or a live owner).
    case nothing
    /// Owner is dead but the session is still valid: stay awake until it expires.
    case keepOrphan
    /// End the session now and restore the journal.
    case endSession(EndReason)
    /// The session file is unreadable: rename it aside and restore.
    case quarantineAndRestore
    /// No session, but the journal still has entries.
    case restoreJournal
}

/// Pure recovery decision (spec/journal.md "Recovery job", spec/session.md rule 7).
public enum RecoveryPolicy {
    public static func decide(
        session: SessionRead,
        journalEmpty: Bool,
        ownerAlive: Bool,
        sameBoot: Bool,
        now: Date,
        battery: BatteryReading,
        thermal: ThermalLevel,
        config: Config
    ) -> RecoveryAction {
        switch session {
        case .unreadable:
            return .quarantineAndRestore
        case .none:
            return journalEmpty ? .nothing : .restoreJournal
        case .some(let s):
            if ownerAlive { return .nothing }
            if !sameBoot { return .endSession(.rebooted) }
            if s.stopRequested != nil { return .endSession(.stopped) }
            if s.isExpired(at: now) { return .endSession(.expired) }
            let floors = FloorRules.decide(
                onBattery: battery.hasBattery && battery.onBattery,
                percent: battery.percent,
                // The recovery job reads once per run; one unreadable read is tolerated.
                unreadableCount: battery.percent == nil ? 1 : 0,
                thermal: thermal,
                lidClosed: false,
                config: config
            )
            if let end = floors.end { return .endSession(end) }
            return .keepOrphan
        }
    }
}

public struct RecoveryOutcome: Sendable, Equatable {
    public var action: RecoveryAction
    public var report: RestoreReport
    public var message: String
}

/// Runs the recovery decision and carries it out under the state lock. Used by
/// the launchd job (`lidless recover`), by `lidless stop` when the owner is
/// dead, and by the app at launch.
public struct Recovery: Sendable {
    public let changes: JournaledChanges
    public let sensors: SystemSensing
    public let inspector: ProcessInspecting

    public init(changes: JournaledChanges, sensors: SystemSensing, inspector: ProcessInspecting) {
        self.changes = changes
        self.sensors = sensors
        self.inspector = inspector
    }

    var store: Store { changes.store }

    /// `forceEndReason` ends an orphaned session even if it has time left
    /// (used by `lidless stop`). It never ends a session whose owner is alive.
    public func run(forceEndReason: EndReason? = nil) async -> RecoveryOutcome {
        do {
            return try await changes.withStateLock {
                let now = changes.now()
                let session = store.readSession()
                let journal: Journal
                do {
                    journal = try store.readJournal()
                } catch {
                    return RecoveryOutcome(action: .nothing, report: RestoreReport(), message: "\(error)")
                }
                var ownerAlive = false
                var sameBoot = true
                if case .some(let s) = session {
                    ownerAlive = inspector.isAlive(s.owner)
                    sameBoot = s.owner.bootSession == inspector.bootSession()
                }
                var action = RecoveryPolicy.decide(
                    session: session,
                    journalEmpty: journal.isEmpty,
                    ownerAlive: ownerAlive,
                    sameBoot: sameBoot,
                    now: now,
                    battery: sensors.battery(),
                    thermal: sensors.thermal(),
                    config: store.readConfig()
                )
                if let force = forceEndReason, action == .keepOrphan {
                    action = .endSession(force)
                }
                return await perform(action, session: session, now: now)
            }
        } catch {
            return RecoveryOutcome(action: .nothing, report: RestoreReport(), message: "Recovery could not run: \(error)")
        }
    }

    private func perform(_ action: RecoveryAction, session: SessionRead, now: Date) async -> RecoveryOutcome {
        switch action {
        case .nothing:
            return RecoveryOutcome(action: action, report: RestoreReport(), message: "Nothing to recover.")
        case .keepOrphan:
            var msg = "The Lidless process that owned the session is gone; keeping the Mac awake until the session ends."
            if case .some(let s) = session {
                msg += " Ends at \(LidlessJSON.string(s.endsAt))."
            }
            return RecoveryOutcome(action: action, report: RestoreReport(), message: msg)
        case .quarantineAndRestore:
            var msg: String
            do {
                let dest = try store.quarantineSession(now: now)
                msg = "Session file was unreadable; moved to \(dest.path)."
            } catch {
                msg = "Session file was unreadable and could not be moved aside: \(error)."
            }
            let report = await changes.restoreAllLocked()
            try? store.writeLastEnd(LastEnd(sessionID: nil, reason: .ownerLost, at: now, restoreComplete: report.complete, detail: msg))
            Log.warn("recovery: \(msg) restore complete=\(report.complete)")
            return RecoveryOutcome(action: action, report: report, message: msg)
        case .restoreJournal:
            let report = await changes.restoreAllLocked()
            let msg = report.complete ? "Restored settings left over from an earlier session." : "Some settings could not be restored yet: \(report.failures.joined(separator: "; "))"
            Log.info("recovery: \(msg)")
            return RecoveryOutcome(action: action, report: report, message: msg)
        case .endSession(let reason):
            var sessionID: UUID?
            if case .some(let s) = session { sessionID = s.id }
            // Remove the session first: if we crash after this, the next run
            // sees "no session + journal entries" and restores.
            do {
                try store.removeSession()
            } catch {
                let msg = "Could not remove the session file: \(error)"
                Log.error("recovery: \(msg)")
                return RecoveryOutcome(action: action, report: RestoreReport(), message: msg)
            }
            let report = await changes.restoreAllLocked()
            let detail = report.complete ? nil : report.failures.joined(separator: "; ")
            try? store.writeLastEnd(LastEnd(sessionID: sessionID, reason: reason, at: now, restoreComplete: report.complete, detail: detail))
            let msg = "Ended the session (\(reason.rawValue)): \(reason.summary)" + (report.complete ? "" : " Restore incomplete: \(detail ?? "")")
            Log.info("recovery: \(msg)")
            return RecoveryOutcome(action: action, report: report, message: msg)
        }
    }
}
