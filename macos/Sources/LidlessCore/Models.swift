import Foundation

// MARK: - Session (spec/session.md)

public struct OwnerIdentity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case app, cli, run
    }

    public var kind: Kind
    public var pid: Int32
    /// Process start time, microseconds since the Unix epoch.
    public var startTime: Int64
    public var bootSession: String

    public init(kind: Kind, pid: Int32, startTime: Int64, bootSession: String) {
        self.kind = kind
        self.pid = pid
        self.startTime = startTime
        self.bootSession = bootSession
    }
}

public struct Extension: Codable, Sendable, Equatable {
    public var at: Date
    public var seconds: TimeInterval
}

public struct Session: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var id: UUID
    public var startedAt: Date
    public var endsAt: Date
    public var extensions: [Extension]
    public var owner: OwnerIdentity
    public var command: [String]?
    public var stopRequested: String?

    public init(id: UUID = UUID(), startedAt: Date, endsAt: Date, owner: OwnerIdentity, command: [String]? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.extensions = []
        self.owner = owner
        self.command = command
        self.stopRequested = nil
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(now))
    }

    public func isExpired(at now: Date) -> Bool {
        now >= endsAt
    }
}

public enum EndReason: String, Codable, Sendable {
    case expired, stopped, quit, commandExited, batteryFloor, thermalFloor, batteryUnreadable
    case verificationFailed, ownerTerminated, rebooted, ownerLost, startFailed

    public var summary: String {
        switch self {
        case .expired: return "Time ran out."
        case .stopped: return "Stopped."
        case .quit: return "Lidless quit."
        case .commandExited: return "The wrapped command finished."
        case .batteryFloor: return "Battery fell below the safety floor."
        case .thermalFloor: return "The Mac got too hot (critical thermal state)."
        case .batteryUnreadable: return "The battery level could not be read twice in a row."
        case .verificationFailed: return "macOS turned closed-lid sleep back on."
        case .ownerTerminated: return "The Lidless session process was terminated."
        case .rebooted: return "The Mac restarted during the session."
        case .ownerLost: return "The Lidless process that owned the session stopped unexpectedly."
        case .startFailed: return "The session could not start."
        }
    }
}

public struct LastEnd: Codable, Sendable, Equatable {
    public var sessionID: UUID?
    public var reason: EndReason
    public var at: Date
    public var restoreComplete: Bool
    public var detail: String?

    public init(sessionID: UUID?, reason: EndReason, at: Date, restoreComplete: Bool, detail: String? = nil) {
        self.sessionID = sessionID
        self.reason = reason
        self.at = at
        self.restoreComplete = restoreComplete
        self.detail = detail
    }
}

// MARK: - Journal (spec/journal.md)

public struct BoolEntry: Codable, Sendable, Equatable {
    public var original: Bool
    public var recordedAt: Date

    public init(original: Bool, recordedAt: Date) {
        self.original = original
        self.recordedAt = recordedAt
    }
}

public struct MacJournal: Codable, Sendable, Equatable {
    public var sleepDisabled: BoolEntry?
    public var lowPowerMode: BoolEntry?

    public init(sleepDisabled: BoolEntry? = nil, lowPowerMode: BoolEntry? = nil) {
        self.sleepDisabled = sleepDisabled
        self.lowPowerMode = lowPowerMode
    }

    public var isEmpty: Bool { sleepDisabled == nil && lowPowerMode == nil }
}

public struct Journal: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var updatedAt: Date?
    public var macos: MacJournal

    public init(macos: MacJournal = MacJournal()) {
        self.macos = macos
    }

    public var isEmpty: Bool { macos.isEmpty }

    // Unknown sections (windows/linux) are ignored on macOS; decoding only
    // requires `version`.
    enum CodingKeys: String, CodingKey { case version, updatedAt, macos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        macos = try c.decodeIfPresent(MacJournal.self, forKey: .macos) ?? MacJournal()
    }
}

// MARK: - Config

public struct Config: Codable, Sendable, Equatable {
    public var lowPowerBelowPercent: Int = 40
    public var endBelowPercent: Int = 10
    public var thermalRules: Bool = true
    public var lowPowerOnLidClose: Bool = true
    public var sleepDisplayOnLidClose: Bool = true
    public var maxDurationSeconds: TimeInterval = 30 * 86_400
    public var runDefaultDurationSeconds: TimeInterval = 24 * 3_600
    public var verifySettleSeconds: TimeInterval = 5
    public var warnOnNetworkLoss: Bool = true
    public var notifications: Bool = true
    /// Breathing menu bar icon while awake (paused while the lid is closed).
    public var animateMenuBarIcon: Bool = true
    /// Show the app in the Dock (it always stays in the menu bar).
    public var showInDock: Bool = true
    /// Check GitHub once a day for a newer release (a plain GET, nothing sent).
    public var checkForUpdates: Bool = true
    /// Extra process names treated as coding agents (added to the built-in list).
    public var extraAgentNames: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every key is optional; missing keys keep their defaults.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        lowPowerBelowPercent = try c.decodeIfPresent(Int.self, forKey: .lowPowerBelowPercent) ?? d.lowPowerBelowPercent
        endBelowPercent = try c.decodeIfPresent(Int.self, forKey: .endBelowPercent) ?? d.endBelowPercent
        thermalRules = try c.decodeIfPresent(Bool.self, forKey: .thermalRules) ?? d.thermalRules
        lowPowerOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lowPowerOnLidClose) ?? d.lowPowerOnLidClose
        sleepDisplayOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .sleepDisplayOnLidClose) ?? d.sleepDisplayOnLidClose
        maxDurationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .maxDurationSeconds) ?? d.maxDurationSeconds
        runDefaultDurationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .runDefaultDurationSeconds) ?? d.runDefaultDurationSeconds
        verifySettleSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .verifySettleSeconds) ?? d.verifySettleSeconds
        warnOnNetworkLoss = try c.decodeIfPresent(Bool.self, forKey: .warnOnNetworkLoss) ?? d.warnOnNetworkLoss
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        animateMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .animateMenuBarIcon) ?? d.animateMenuBarIcon
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        extraAgentNames = try c.decodeIfPresent([String].self, forKey: .extraAgentNames) ?? d.extraAgentNames
    }

    /// Clamps values into safe ranges (spec/floors.md).
    public func normalized() -> Config {
        var c = self
        c.endBelowPercent = min(max(c.endBelowPercent, 0), 50)
        c.lowPowerBelowPercent = min(max(c.lowPowerBelowPercent, 0), 100)
        if c.endBelowPercent > 0 && c.lowPowerBelowPercent <= c.endBelowPercent {
            c.lowPowerBelowPercent = c.endBelowPercent + 1
        }
        c.maxDurationSeconds = min(max(c.maxDurationSeconds, 60), 30 * 86_400)
        c.runDefaultDurationSeconds = min(max(c.runDefaultDurationSeconds, 60), c.maxDurationSeconds)
        c.verifySettleSeconds = min(max(c.verifySettleSeconds, 0), 30)
        return c
    }
}

// MARK: - JSON coding

public enum LidlessJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func string(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}
