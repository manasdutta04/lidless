import Foundation

/// Operations any Lidless process may perform on the current session without
/// being its owner. They edit `session.json` under the lock and never signal
/// the owner (spec/session.md rule 5).
public struct SessionControl: Sendable {
    public let store: Store
    public let inspector: ProcessInspecting
    public let now: @Sendable () -> Date

    public init(store: Store, inspector: ProcessInspecting, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.inspector = inspector
        self.now = now
    }

    /// Adds time, capped at the configured maximum from now.
    public func extend(by seconds: TimeInterval) throws -> (Session, clamped: Bool) {
        guard seconds > 0 else { throw LidlessError.usage("Extension must be greater than zero.") }
        let config = store.readConfig()
        return try store.withLock {
            guard case .some(var s) = store.readSession() else { throw LidlessError.noSession }
            guard s.stopRequested == nil else { throw LidlessError.noSession }
            let now = now()
            let cap = now.addingTimeInterval(config.maxDurationSeconds)
            let wanted = max(s.endsAt, now).addingTimeInterval(seconds)
            let newEnd = min(wanted, cap)
            let added = newEnd.timeIntervalSince(s.endsAt)
            guard added > 0 else {
                throw LidlessError.usage("The session already ends at the \(DurationParser.format(config.maxDurationSeconds)) maximum.")
            }
            s.endsAt = newEnd
            s.extensions.append(Extension(at: now, seconds: added))
            try store.writeSession(s)
            Log.info("session \(s.id) extended by \(DurationParser.format(added)) to \(LidlessJSON.string(newEnd))")
            return (s, wanted > cap)
        }
    }

    public enum StopRequest: Sendable, Equatable {
        /// The live owner will end the session on its next tick.
        case requested(sessionID: UUID)
        /// The owner is gone; the caller should run recovery.
        case ownerDead(sessionID: UUID)
    }

    public func requestStop(reason: String = "user") throws -> StopRequest {
        try store.withLock {
            switch store.readSession() {
            case .none:
                throw LidlessError.noSession
            case .unreadable:
                return .ownerDead(sessionID: UUID())
            case .some(var s):
                guard inspector.isAlive(s.owner) else { return .ownerDead(sessionID: s.id) }
                s.stopRequested = reason
                try store.writeSession(s)
                return .requested(sessionID: s.id)
            }
        }
    }

    /// Polls until the session file no longer holds `sessionID`, then returns
    /// the matching last-end record (nil on timeout).
    public func waitForEnd(sessionID: UUID, timeout: TimeInterval) async -> LastEnd? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var gone = true
            if case .some(let s) = store.readSession(), s.id == sessionID { gone = false }
            if gone, let le = store.readLastEnd(), le.sessionID == sessionID { return le }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}
