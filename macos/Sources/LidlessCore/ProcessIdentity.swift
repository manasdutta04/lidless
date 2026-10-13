import Foundation

/// Proves a pid is the same process we recorded: pid + start time + boot.
public protocol ProcessInspecting: Sendable {
    func startTime(of pid: Int32) -> Int64?
    func bootSession() -> String
    func currentIdentity(kind: OwnerIdentity.Kind) -> OwnerIdentity
}

extension ProcessInspecting {
    public func isAlive(_ owner: OwnerIdentity) -> Bool {
        guard owner.bootSession == bootSession() else { return false }
        guard let start = startTime(of: owner.pid) else { return false }
        return start == owner.startTime
    }

    public func currentIdentity(kind: OwnerIdentity.Kind) -> OwnerIdentity {
        let pid = getpid()
        return OwnerIdentity(kind: kind, pid: pid, startTime: startTime(of: pid) ?? 0, bootSession: bootSession())
    }
}

public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func startTime(of pid: Int32) -> Int64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // A zombie still has a start time but is not doing anything for us.
        if info.kp_proc.p_stat == SZOMB { return nil }
        let tv = info.kp_proc.p_starttime
        return Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
    }

    public func bootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return bootTimeFallback()
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else {
            return bootTimeFallback()
        }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func bootTimeFallback() -> String {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&mib, 2, &tv, &size, nil, 0)
        return "boottime-\(tv.tv_sec)"
    }
}
