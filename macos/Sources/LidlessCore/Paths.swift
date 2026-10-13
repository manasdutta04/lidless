import Foundation

/// Locations of every file Lidless reads or writes. `LIDLESS_HOME` overrides
/// the state directory; tests always set it to a temporary directory.
public struct LidlessPaths: Sendable, Equatable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> LidlessPaths {
        if let override = environment["LIDLESS_HOME"], !override.isEmpty {
            return LidlessPaths(home: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lidless", isDirectory: true)
        return LidlessPaths(home: base)
    }

    public var session: URL { home.appendingPathComponent("session.json") }
    public var journal: URL { home.appendingPathComponent("journal.json") }
    public var config: URL { home.appendingPathComponent("config.json") }
    public var lastEnd: URL { home.appendingPathComponent("last-end.json") }
    public var history: URL { home.appendingPathComponent("history.json") }
    public var lock: URL { home.appendingPathComponent("lock") }
    public var log: URL { home.appendingPathComponent("lidless.log") }
    public var firstRunMarker: URL { home.appendingPathComponent("first-run-acknowledged") }

    /// Creates the state directory owner-only (0700) and re-tightens it if
    /// something loosened it.
    public func ensureHome() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: home.path) {
            try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }
}

public enum LaunchAgentInfo {
    public static let label = "io.github.manasdutta04.lidless.recovery"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
}
