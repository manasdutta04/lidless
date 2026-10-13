import Foundation

/// Result of reading the session file. "Unreadable" is distinct from
/// "absent" so a corrupt file is never mistaken for "no session".
public enum SessionRead: Sendable, Equatable {
    case none
    case some(Session)
    case unreadable(String)
}

/// Reads and writes the state files. Callers that read-then-write must hold
/// the lock (`withLock`).
public struct Store: Sendable {
    public let paths: LidlessPaths

    public init(paths: LidlessPaths) {
        self.paths = paths
    }

    public func withLock<T>(timeout: TimeInterval = 30, _ body: () throws -> T) throws -> T {
        try paths.ensureHome()
        return try FileLock.withLock(paths.lock, timeout: timeout, body)
    }

    // MARK: Session

    public func readSession() -> SessionRead {
        do {
            guard let data = try OwnerOnlyFile.read(paths.session) else { return .none }
            return .some(try LidlessJSON.decoder().decode(Session.self, from: data))
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    public func writeSession(_ session: Session) throws {
        try paths.ensureHome()
        try OwnerOnlyFile.write(try LidlessJSON.encoder().encode(session), to: paths.session)
    }

    public func removeSession() throws {
        if unlink(paths.session.path) != 0 && errno != ENOENT {
            throw POSIXError.current("unlink \(paths.session.path)")
        }
    }

    /// Renames an unreadable session file aside (never deletes it).
    @discardableResult
    public func quarantineSession(now: Date = Date()) throws -> URL {
        let dest = paths.home.appendingPathComponent("session.json.unreadable-\(Int(now.timeIntervalSince1970))")
        guard rename(paths.session.path, dest.path) == 0 else {
            throw POSIXError.current("rename \(paths.session.path)")
        }
        return dest
    }

    // MARK: Journal

    /// Missing file → empty journal. Unreadable file → throws, so a damaged
    /// journal is never treated as clean.
    public func readJournal() throws -> Journal {
        guard let data = try OwnerOnlyFile.read(paths.journal) else { return Journal() }
        do {
            return try LidlessJSON.decoder().decode(Journal.self, from: data)
        } catch {
            throw LidlessError.system("The recovery journal at \(paths.journal.path) could not be read (\(error)). It was left in place; inspect it before removing.")
        }
    }

    public func writeJournal(_ journal: Journal, now: Date = Date()) throws {
        try paths.ensureHome()
        var j = journal
        j.updatedAt = now
        try OwnerOnlyFile.write(try LidlessJSON.encoder().encode(j), to: paths.journal)
    }

    // MARK: Config

    public func readConfig() -> Config {
        guard let data = try? OwnerOnlyFile.read(paths.config),
              let config = try? LidlessJSON.decoder().decode(Config.self, from: data) else {
            return Config()
        }
        return config.normalized()
    }

    public func writeConfig(_ config: Config) throws {
        try paths.ensureHome()
        try OwnerOnlyFile.write(try LidlessJSON.encoder().encode(config.normalized()), to: paths.config)
    }

    // MARK: Last end

    public func readLastEnd() -> LastEnd? {
        guard let data = try? OwnerOnlyFile.read(paths.lastEnd) else { return nil }
        return try? LidlessJSON.decoder().decode(LastEnd.self, from: data)
    }

    public func writeLastEnd(_ lastEnd: LastEnd) throws {
        try paths.ensureHome()
        try OwnerOnlyFile.write(try LidlessJSON.encoder().encode(lastEnd), to: paths.lastEnd)
    }
}
