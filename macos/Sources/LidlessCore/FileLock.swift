import Foundation

/// Advisory `flock` on the state directory's lock file. Every read-modify-write
/// of session or journal state, and every system change, happens while held.
public final class FileLock: @unchecked Sendable {
    private let url: URL
    private var fd: Int32 = -1

    public init(url: URL) {
        self.url = url
    }

    deinit {
        unlock()
    }

    /// Waits up to `timeout` seconds for the lock.
    public func lock(timeout: TimeInterval = 30) throws {
        precondition(fd < 0, "FileLock is not reentrant")
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError.current("open \(url.path)") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR {
                let err = POSIXError.current("flock \(url.path)")
                close(fd)
                throw err
            }
            if Date() >= deadline {
                close(fd)
                throw LidlessError.lockTimeout
            }
            usleep(50_000)
        }
        self.fd = fd
    }

    public func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// Runs `body` while holding the lock.
    public static func withLock<T>(_ url: URL, timeout: TimeInterval = 30, _ body: () throws -> T) throws -> T {
        let lock = FileLock(url: url)
        try lock.lock(timeout: timeout)
        defer { lock.unlock() }
        return try body()
    }
}
