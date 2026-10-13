import Foundation

/// One finished session, recorded when it ends (by the owner or by recovery).
/// Stored in `history.json`, newest last, capped at `History.limit` entries.
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var reason: EndReason
    /// Seconds the lid was closed during the session (0 when unknown, e.g. a
    /// session ended by recovery after its owner crashed).
    public var closedLidSeconds: TimeInterval
    public var owner: OwnerIdentity.Kind
    public var command: [String]?
    public var restoreComplete: Bool

    public init(id: UUID, startedAt: Date, endedAt: Date, reason: EndReason, closedLidSeconds: TimeInterval,
                owner: OwnerIdentity.Kind, command: [String]?, restoreComplete: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
        self.closedLidSeconds = closedLidSeconds
        self.owner = owner
        self.command = command
        self.restoreComplete = restoreComplete
    }

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

public enum History {
    public static let limit = 1_000

    /// Reads the history; a missing or damaged file reads as empty (history is
    /// informational and never affects what gets restored).
    public static func read(_ store: Store) -> [HistoryEntry] {
        guard let data = try? OwnerOnlyFile.read(store.paths.history),
              let entries = try? LidlessJSON.decoder().decode([HistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Appends an entry. The caller must hold the state lock.
    public static func appendLocked(_ entry: HistoryEntry, store: Store) {
        var entries = read(store)
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        do {
            try store.paths.ensureHome()
            try OwnerOnlyFile.write(try LidlessJSON.encoder().encode(entries), to: store.paths.history)
        } catch {
            Log.warn("could not record session history: \(error)")
        }
    }

    public static func append(_ entry: HistoryEntry, store: Store) {
        do {
            try store.withLock { appendLocked(entry, store: store) }
        } catch {
            Log.warn("could not record session history: \(error)")
        }
    }
}

/// Totals shown on the Overview page and by `lidless stats`.
public struct UsageStats: Codable, Sendable, Equatable {
    public struct Day: Codable, Sendable, Equatable {
        public var start: Date
        public var awakeSeconds: TimeInterval
    }

    public var sessions: Int
    public var totalAwakeSeconds: TimeInterval
    public var closedLidSeconds: TimeInterval
    public var longestSeconds: TimeInterval
    public var averageSeconds: TimeInterval
    public var thisWeekSeconds: TimeInterval
    public var cleanRestorePercent: Int?
    public var endedBySafety: Int
    public var commandSessions: Int
    /// Awake time for each of the last 7 days, oldest first (today last).
    public var lastSevenDays: [Day]
    public var firstSession: Date?

    /// Awake seconds for each of the last `days` days, oldest first (today
    /// last). A session spanning midnight counts toward both days.
    public static func daily(_ entries: [HistoryEntry], days count: Int, now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { back in
            let start = calendar.date(byAdding: .day, value: -back, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let seconds = entries.reduce(0.0) { sum, e in
                let overlap = min(e.endedAt, end).timeIntervalSince(max(e.startedAt, start))
                return sum + max(0, overlap)
            }
            return Day(start: start, awakeSeconds: seconds)
        }
    }

    /// Awake seconds by hour of day (0–23), summed over all sessions.
    public static func hourOfDay(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [TimeInterval] {
        var hours = [TimeInterval](repeating: 0, count: 24)
        for e in entries {
            var t = e.startedAt
            while t < e.endedAt {
                let hourStart = calendar.dateInterval(of: .hour, for: t)!.start
                let next = min(e.endedAt, hourStart.addingTimeInterval(3_600))
                hours[calendar.component(.hour, from: t)] += next.timeIntervalSince(t)
                t = next
            }
        }
        return hours
    }

    public static func compute(_ entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> UsageStats {
        let durations = entries.map(\.duration)
        let total = durations.reduce(0, +)
        let days = daily(entries, days: 7, now: now, calendar: calendar)
        let safetyReasons: Set<EndReason> = [.batteryFloor, .thermalFloor, .batteryUnreadable]
        return UsageStats(
            sessions: entries.count,
            totalAwakeSeconds: total,
            closedLidSeconds: entries.map(\.closedLidSeconds).reduce(0, +),
            longestSeconds: durations.max() ?? 0,
            averageSeconds: entries.isEmpty ? 0 : total / Double(entries.count),
            thisWeekSeconds: days.map(\.awakeSeconds).reduce(0, +),
            cleanRestorePercent: entries.isEmpty ? nil
                : Int((Double(entries.filter(\.restoreComplete).count) / Double(entries.count) * 100).rounded()),
            endedBySafety: entries.filter { safetyReasons.contains($0.reason) }.count,
            commandSessions: entries.filter { $0.command != nil }.count,
            lastSevenDays: days,
            firstSession: entries.map(\.startedAt).min()
        )
    }
}

extension History {
    /// One-time import of sessions recorded in the log before history existed.
    /// Runs only when `history.json` does not exist yet.
    public static func backfillFromLogIfNeeded(_ store: Store) {
        guard !FileManager.default.fileExists(atPath: store.paths.history.path) else { return }
        let logs = [store.paths.log.appendingPathExtension("1"), store.paths.log]
        let text = logs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let entries = parseLog(text)
        do {
            try store.withLock {
                guard !FileManager.default.fileExists(atPath: store.paths.history.path) else { return }
                try store.paths.ensureHome()
                try OwnerOnlyFile.write(try LidlessJSON.encoder().encode(entries), to: store.paths.history)
            }
            if !entries.isEmpty { Log.info("imported \(entries.count) earlier sessions from the log into history") }
        } catch {
            Log.warn("could not import history from the log: \(error)")
        }
    }

    /// Rebuilds finished sessions from log lines: "session <id> starting for
    /// …, owner <kind>", "engaged and verified", "lid closed/opened" (same
    /// pid) and "session <id> ended: <reason>; restore complete=<bool>".
    static func parseLog(_ text: String) -> [HistoryEntry] {
        struct Open {
            var engagedAt: Date?
            var owner: OwnerIdentity.Kind
            var pid: String
            var lidSince: Date?
            var lidSeconds: TimeInterval = 0
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var open: [String: Open] = [:]
        var result: [HistoryEntry] = []

        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let at = iso.date(from: String(parts[0])) else { continue }
            let pid = String(parts[1])
            let message = String(parts[3])
            let words = message.split(separator: " ").map(String.init)

            if words.count >= 3, words[0] == "session" {
                let id = words[1]
                if words[2] == "starting", let ownerIndex = words.firstIndex(of: "owner"), ownerIndex + 1 < words.count,
                   let kind = OwnerIdentity.Kind(rawValue: words[ownerIndex + 1]) {
                    open[id] = Open(owner: kind, pid: pid)
                } else if words[2] == "engaged" {
                    open[id]?.engagedAt = at
                } else if words[2] == "ended:", let o = open[id], let engaged = o.engagedAt, let uuid = UUID(uuidString: id) {
                    let reasonWord = words.count > 3 ? words[3].trimmingCharacters(in: CharacterSet(charactersIn: ";")) : ""
                    var lid = o.lidSeconds
                    if let since = o.lidSince { lid += at.timeIntervalSince(since) }
                    result.append(HistoryEntry(
                        id: uuid, startedAt: engaged, endedAt: at,
                        reason: EndReason(rawValue: reasonWord) ?? .stopped,
                        closedLidSeconds: lid, owner: o.owner, command: o.owner == .run ? ["(command)"] : nil,
                        restoreComplete: message.hasSuffix("restore complete=true")
                    ))
                    open[id] = nil
                }
            } else if message == "lid closed" || message == "lid opened" {
                for (id, o) in open where o.pid == pid && o.engagedAt != nil {
                    var updated = o
                    if message == "lid closed" {
                        updated.lidSince = at
                    } else if let since = o.lidSince {
                        updated.lidSeconds += at.timeIntervalSince(since)
                        updated.lidSince = nil
                    }
                    open[id] = updated
                }
            }
        }
        return result.sorted { $0.startedAt < $1.startedAt }
    }
}
