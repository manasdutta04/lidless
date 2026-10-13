import Foundation

public protocol Notifying: Sendable {
    func notify(title: String, body: String)
}

public struct NoopNotifier: Notifying {
    public init() {}
    public func notify(title: String, body: String) {}
}

/// Used by the CLI holder, which has no app bundle for UserNotifications.
public struct OSAScriptNotifier: Notifying {
    public init() {}

    public func notify(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Pass text as argv, never interpolated into the script source.
        p.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e", "end run",
            title, body,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
