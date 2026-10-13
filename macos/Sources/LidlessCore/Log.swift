import Foundation

/// Owner-only append log, rotated at 1 MiB with one previous file kept.
/// Logs may contain process and network names: warn before sharing.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "lidless.log")
    private var url: URL?
    private let maxBytes = 1 << 20
    public var echoToStderr = false

    public func configure(paths: LidlessPaths) {
        queue.sync { self.url = paths.log }
    }

    public static func info(_ message: String) { shared.write("INFO", message) }
    public static func warn(_ message: String) { shared.write("WARN", message) }
    public static func error(_ message: String) { shared.write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let line = "\(LidlessJSON.string(Date())) [\(getpid())] \(level) \(message)\n"
        if echoToStderr {
            FileHandle.standardError.write(Data(line.utf8))
        }
        queue.async {
            guard let url = self.url else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            self.rotateIfNeeded(url)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let data = Array(line.utf8)
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_size > maxBytes else { return }
        let old = url.appendingPathExtension("1")
        unlink(old.path)
        rename(url.path, old.path)
    }

    /// Blocks until queued writes are on disk (call before exit).
    public func flush() {
        queue.sync {}
    }
}
