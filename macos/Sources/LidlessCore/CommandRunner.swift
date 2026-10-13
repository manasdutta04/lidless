import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    /// The command did not finish within its limit and was sent SIGTERM.
    public var timedOut: Bool
    /// After SIGTERM and a grace period it was still running (we never SIGKILL).
    public var stillRunningPid: Int32?

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false, stillRunningPid: Int32? = nil) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stillRunningPid = stillRunningPid
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Every external command goes through this, so tests can fake all of them.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // A minimal, predictable environment for system tools.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]

        let outBuffer = DataBox()
        let errBuffer = DataBox()
        out.fileHandleForReading.readabilityHandler = { h in outBuffer.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errBuffer.append(h.availableData) }

        let state = RunState()
        let status: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { p in
                state.finish { cont.resume(returning: p.terminationStatus) }
            }
            do {
                try process.run()
            } catch {
                errBuffer.append(Data("\(error)".utf8))
                state.finish { cont.resume(returning: 127) }
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !state.isFinished else { return }
                state.markTimedOut()
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    state.finish {
                        state.stillRunning = pid
                        cont.resume(returning: -1)
                    }
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if state.stillRunning == nil {
            outBuffer.append(out.fileHandleForReading.readDataToEndOfFile())
            errBuffer.append(err.fileHandleForReading.readDataToEndOfFile())
        }
        return CommandResult(
            status: status,
            stdout: outBuffer.string,
            stderr: errBuffer.string,
            timedOut: state.timedOut,
            stillRunningPid: state.stillRunning
        )
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private(set) var timedOut = false
    var stillRunning: Int32?

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    /// Runs `body` exactly once across all callers.
    func finish(_ body: () -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        body()
    }
}
