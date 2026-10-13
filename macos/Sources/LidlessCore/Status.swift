import Foundation

/// The `status --json` shape from spec/cli.md, shared by the CLI and the app.
public struct StatusSnapshot: Codable, Sendable, Equatable {
    public struct OwnerInfo: Codable, Sendable, Equatable {
        public var kind: OwnerIdentity.Kind
        public var pid: Int32
        public var alive: Bool
    }

    public struct SessionInfo: Codable, Sendable, Equatable {
        public var id: UUID
        public var startedAt: Date
        public var endsAt: Date
        public var remainingSeconds: Int
        public var owner: OwnerInfo
        public var command: [String]?
        public var stopRequested: String?
    }

    public struct JournalInfo: Codable, Sendable, Equatable {
        public var sleepDisabled: Bool
        public var lowPowerMode: Bool
        public var readable: Bool
    }

    public struct PowerInfo: Codable, Sendable, Equatable {
        public var hasBattery: Bool
        public var onBattery: Bool
        public var percent: Int?
        public var thermal: ThermalLevel
    }

    public var active: Bool
    public var session: SessionInfo?
    public var journal: JournalInfo
    public var lidClosed: Bool?
    public var power: PowerInfo
    public var lastEnd: LastEnd?
    public var warnings: [String]
    public var ready: ReadinessReport?

    public static func collect(
        store: Store,
        sensors: SystemSensing,
        inspector: ProcessInspecting,
        readiness: ReadinessReport?,
        now: Date = Date()
    ) -> StatusSnapshot {
        var warnings: [String] = []
        var sessionInfo: SessionInfo?
        switch store.readSession() {
        case .none:
            break
        case .unreadable(let why):
            warnings.append("The session file is unreadable (\(why)). The recovery agent will move it aside and restore settings.")
        case .some(let s):
            let alive = inspector.isAlive(s.owner)
            sessionInfo = SessionInfo(
                id: s.id, startedAt: s.startedAt, endsAt: s.endsAt,
                remainingSeconds: Int(s.remaining(at: now).rounded(.up)),
                owner: OwnerInfo(kind: s.owner.kind, pid: s.owner.pid, alive: alive),
                command: s.command, stopRequested: s.stopRequested
            )
            if !alive {
                warnings.append("The process that started this session quit unexpectedly. The Mac stays awake until \(s.endsAt.formatted(date: .omitted, time: .shortened)), with the battery and heat limits still enforced. Stop ends it now.")
            }
        }

        var journalInfo = JournalInfo(sleepDisabled: false, lowPowerMode: false, readable: true)
        do {
            let j = try store.readJournal()
            journalInfo.sleepDisabled = j.macos.sleepDisabled != nil
            journalInfo.lowPowerMode = j.macos.lowPowerMode != nil
            if sessionInfo == nil && !j.isEmpty {
                warnings.append("Settings from an earlier session are waiting to be restored. The recovery agent retries every minute; `lidless recover` runs it now.")
            }
        } catch {
            journalInfo.readable = false
            warnings.append("\(error)")
        }

        let lastEnd = store.readLastEnd()
        if let le = lastEnd, !le.restoreComplete, sessionInfo == nil {
            warnings.append("The last session did not restore everything: \(le.detail ?? "unknown error").")
        }
        if let r = readiness, let e = r.notReadyError {
            warnings.append(e.description)
        }

        let b = sensors.battery()
        return StatusSnapshot(
            active: sessionInfo != nil,
            session: sessionInfo,
            journal: journalInfo,
            lidClosed: sensors.lidClosed(),
            power: PowerInfo(hasBattery: b.hasBattery, onBattery: b.hasBattery && b.onBattery, percent: b.percent, thermal: sensors.thermal()),
            lastEnd: lastEnd,
            warnings: warnings,
            ready: readiness
        )
    }
}
