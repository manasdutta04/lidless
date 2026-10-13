import Darwin
import Foundation

public struct DetectedAgent: Sendable, Equatable, Codable {
    public var pid: Int32
    public var name: String
}

/// Finds running coding-agent processes so the UI can say what is being kept
/// alive, and so `lidless agents` can list them. Read-only: never signals.
public enum AgentDetector {
    public static let builtInNames: Set<String> = [
        "claude", "codex", "aider", "gemini", "cursor-agent", "opencode", "goose",
        "amp", "qwen", "crush", "copilot", "droid", "cline", "kiro-cli", "auggie",
    ]

    /// Interpreters whose script argument names the real tool.
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    /// Pure matcher, unit-tested: given an executable name and argv, returns
    /// the agent name or nil.
    public static func match(executable: String, arguments: [String], names: Set<String>) -> String? {
        let exe = (executable as NSString).lastPathComponent.lowercased()
        if names.contains(exe) { return exe }
        guard interpreters.contains(exe) || exe.hasPrefix("python") else { return nil }
        for arg in arguments.dropFirst().prefix(3) where !arg.hasPrefix("-") {
            let base = (arg as NSString).lastPathComponent.lowercased()
            let stem = (base as NSString).deletingPathExtension
            if names.contains(base) { return base }
            if names.contains(stem) { return stem }
            // e.g. .../node_modules/@anthropic-ai/claude-code/cli.js
            if arg.contains("/claude-code/") { return "claude" }
            if arg.contains("/@openai/codex/") { return "codex" }
            if arg.contains("/gemini-cli/") { return "gemini" }
        }
        return nil
    }

    public static func detect(extraNames: [String] = []) -> [DetectedAgent] {
        let names = builtInNames.union(extraNames.map { $0.lowercased() })
        let uid = getuid()
        var found: [DetectedAgent] = []
        for pid in allPids() where pid > 0 {
            guard ownerUID(of: pid) == uid else { continue }
            guard let path = executablePath(pid) else { continue }
            let args = arguments(of: pid) ?? []
            if let name = match(executable: path, arguments: args, names: names) {
                found.append(DetectedAgent(pid: pid, name: name))
            }
        }
        return found.sorted { ($0.name, $0.pid) < ($1.name, $1.pid) }
    }

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n)))
    }

    static func ownerUID(of pid: Int32) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// argv via KERN_PROCARGS2: [argc:int32][exec path\0][padding \0...][argv0\0argv1\0...]
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }  // exec path
        while i < size && buf[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while i < size && args.count < argc {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }
}
