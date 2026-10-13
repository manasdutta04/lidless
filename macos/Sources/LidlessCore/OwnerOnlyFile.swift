import Foundation

public enum OwnerOnlyFile {
    /// Atomically replaces `url` with `data`: write a 0600 temp file in the
    /// same directory, fsync it, rename it over the target, fsync the directory.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError.current("open \(tmp.path)") }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError.current("write \(tmp.path)")
                    }
                    offset += n
                }
            }
            guard fsync(fd) == 0 else { throw POSIXError.current("fsync \(tmp.path)") }
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        guard rename(tmp.path, url.path) == 0 else { throw POSIXError.current("rename \(url.path)") }
        ok = true
        let dfd = open(dir.path, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
    }

    /// Reads a file, returning nil when it does not exist. Any other failure
    /// throws, so callers never mistake "unreadable" for "absent".
    public static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Tightens an existing file to 0600.
    public static func tighten(_ url: URL) {
        chmod(url.path, 0o600)
    }
}

extension POSIXError {
    static func current(_ context: String) -> LidlessError {
        let code = errno
        return LidlessError.system("\(context): \(String(cString: strerror(code)))")
    }
}

public enum LidlessError: Error, CustomStringConvertible, Equatable, Sendable {
    case usage(String)
    case notReady(String)
    case verificationFailed(String)
    case noSession
    case sessionActive
    case restoreIncomplete(String)
    case system(String)
    case lockTimeout

    public var description: String {
        switch self {
        case .usage(let m): return m
        case .notReady(let m): return m
        case .verificationFailed(let m): return m
        case .noSession: return "No active Lidless session."
        case .sessionActive: return "A Lidless session is already active. Use `lidless extend` to add time."
        case .restoreIncomplete(let m): return m
        case .system(let m): return m
        case .lockTimeout: return "Timed out waiting for the Lidless state lock. Another Lidless process may be stuck; see `lidless status`."
        }
    }

    /// Exit codes from spec/cli.md.
    public var exitCode: Int32 {
        switch self {
        case .usage: return 2
        case .notReady: return 3
        case .verificationFailed: return 4
        case .noSession: return 5
        case .sessionActive: return 6
        case .restoreIncomplete: return 7
        case .system, .lockTimeout: return 1
        }
    }
}
