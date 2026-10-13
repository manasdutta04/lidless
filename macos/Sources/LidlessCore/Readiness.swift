import Foundation

public struct ReadinessReport: Sendable, Equatable, Codable {
    public var privilege: Bool
    public var recoveryArmed: Bool
    public var recoveryDetail: String

    public var ready: Bool { privilege && recoveryArmed }

    public init(privilege: Bool, recoveryArmed: Bool, recoveryDetail: String) {
        self.privilege = privilege
        self.recoveryArmed = recoveryArmed
        self.recoveryDetail = recoveryDetail
    }

    /// The error to show when a session must not start (Hard rule 2).
    public var notReadyError: LidlessError? {
        var problems: [String] = []
        if !privilege {
            problems.append("the sudoers rule for pmset is not installed (sudo would ask for a password)")
        }
        if !recoveryArmed {
            problems.append("the recovery agent is not armed (\(recoveryDetail))")
        }
        guard !problems.isEmpty else { return nil }
        return .notReady("Lidless will not start because " + problems.joined(separator: " and ") + ". Run macos/scripts/install.sh, then `lidless doctor`.")
    }
}

/// Checks that the launchd recovery agent is installed and loaded.
public protocol RecoveryAgentChecking: Sendable {
    func check() async -> (armed: Bool, detail: String)
}

public struct LaunchdRecoveryAgentChecker: RecoveryAgentChecking {
    let runner: CommandRunning

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func check() async -> (armed: Bool, detail: String) {
        let plist = LaunchAgentInfo.plistURL
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else {
            return (false, "\(plist.path) is missing")
        }
        guard let args = dict["ProgramArguments"] as? [String], let program = args.first,
              FileManager.default.isExecutableFile(atPath: program) else {
            return (false, "the program in \(plist.lastPathComponent) does not exist")
        }
        guard args.dropFirst().first == "recover" else {
            return (false, "\(plist.lastPathComponent) does not run `lidless recover`")
        }
        let r = await runner.run("/bin/launchctl", ["print", "gui/\(getuid())/\(LaunchAgentInfo.label)"], timeout: 10)
        guard r.succeeded else {
            return (false, "launchd has not loaded \(LaunchAgentInfo.label)")
        }
        return (true, "loaded; runs \(program) recover every 60 s")
    }
}

public struct Readiness: Sendable {
    let power: PowerControlling
    let agent: RecoveryAgentChecking

    public init(power: PowerControlling, agent: RecoveryAgentChecking) {
        self.power = power
        self.agent = agent
    }

    public func check() async -> ReadinessReport {
        async let privilege = power.privilegeReady()
        async let agentStatus = agent.check()
        let (p, a) = await (privilege, agentStatus)
        return ReadinessReport(privilege: p, recoveryArmed: a.armed, recoveryDetail: a.detail)
    }
}
