import Foundation

/// One-time setup and removal: the recovery LaunchAgent, the narrow sudoers
/// rule, and the `~/.local/bin/lidless` link. Used by the app's "Set Up"
/// button and by `lidless setup` / `lidless uninstall`.
public enum Installer {
    public static let sudoersPath = "/etc/sudoers.d/lidless"
    public static var cliLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lidless")
    }

    /// How to run the one root step.
    public enum Elevation: Sendable {
        /// The standard macOS administrator password dialog (the app).
        case passwordDialog(prompt: String)
        /// `sudo` in the current terminal (the CLI).
        case terminalSudo
    }

    public struct Report: Sendable, Equatable {
        public var steps: [String] = []
        public var warnings: [String] = []
    }

    // MARK: sudoers

    public static func currentUserName() -> String {
        NSUserName()
    }

    /// Conservative: only names that need no quoting in sudoers or sh.
    public static func isSafeUserName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty, name.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let firstAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        return firstAllowed.contains(first) && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The complete sudoers file: exactly the four pmset commands, for one user.
    public static func sudoersLines(user: String) -> [String] {
        let commands = PmsetPowerControl.allowedPrivilegedArguments
            .map { ([PmsetPowerControl.pmset] + $0).joined(separator: " ") }
            .joined(separator: ", ")
        return [
            "# Installed by Lidless. Lets \(user) turn closed-lid sleep and battery Low Power Mode",
            "# on and off without a password. Nothing else. Remove with: lidless uninstall",
            "\(user) ALL=(root) NOPASSWD: \(commands)",
        ]
    }

    /// Root shell script that writes the sudoers file from fixed text (never
    /// from a file another user process could swap), validates it with
    /// visudo, and installs it 0440 root:wheel.
    public static func sudoersInstallScript(user: String) throws -> String {
        guard isSafeUserName(user) else {
            throw LidlessError.system("The user name \"\(user)\" cannot be used in a sudoers rule safely.")
        }
        let quoted = sudoersLines(user: user).map { "'\($0)'" }.joined(separator: " ")
        return [
            "set -e",
            "umask 077",
            "/bin/mkdir -p /private/etc/sudoers.d",
            "T=$(/usr/bin/mktemp /private/tmp/lidless-sudoers.XXXXXX)",
            "trap '/bin/rm -f \"$T\"' EXIT",
            "/usr/bin/printf '%s\\n' \(quoted) > \"$T\"",
            "/usr/sbin/visudo -cf \"$T\" >/dev/null",
            "/usr/bin/install -m 0440 -o root -g wheel \"$T\" \(sudoersPath)",
        ].joined(separator: "\n")
    }

    public static let sudoersRemoveScript = "/bin/rm -f \(sudoersPath)"

    /// AppleScript string literal escaping.
    static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs `script` as root. Throws `.system` with a readable message, or
    /// `.usage("cancelled")` when the user cancels the password dialog.
    public static func runAsRoot(_ script: String, elevation: Elevation) async throws {
        switch elevation {
        case .passwordDialog(let prompt):
            let source = "do shell script \(appleScriptQuoted(script)) with prompt \(appleScriptQuoted(prompt)) with administrator privileges"
            let r = await ProcessCommandRunner().run("/usr/bin/osascript", ["-e", source], timeout: 300)
            if r.succeeded { return }
            if r.stderr.contains("-128") || r.stderr.localizedCaseInsensitiveContains("cancel") {
                throw LidlessError.usage("Setup was cancelled.")
            }
            throw LidlessError.system("The administrator step failed: \(r.stderr.trimmed)")
        case .terminalSudo:
            // Inherit the terminal so sudo can ask for the password.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["/bin/sh", "-c", script]
            p.standardInput = FileHandle.standardInput
            p.standardOutput = FileHandle.standardError
            p.standardError = FileHandle.standardError
            try p.run()
            await Task.detached { p.waitUntilExit() }.value
            guard p.terminationStatus == 0 else {
                throw LidlessError.system("sudo exited with status \(p.terminationStatus).")
            }
        }
    }

    // MARK: LaunchAgent

    public static func launchAgentPlist(cliPath: String) throws -> Data {
        let dict: [String: Any] = [
            "Label": LaunchAgentInfo.label,
            "ProgramArguments": [cliPath, "recover"],
            "StartInterval": 60,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public static func installLaunchAgent(cliPath: String, runner: CommandRunning = ProcessCommandRunner()) async throws {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw LidlessError.system("The lidless helper is missing at \(cliPath).")
        }
        let plist = LaunchAgentInfo.plistURL
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try launchAgentPlist(cliPath: cliPath).write(to: plist, options: .atomic)
        chmod(plist.path, 0o644)
        let domain = "gui/\(getuid())"
        _ = await runner.run("/bin/launchctl", ["bootout", "\(domain)/\(LaunchAgentInfo.label)"], timeout: 15)
        let boot = await runner.run("/bin/launchctl", ["bootstrap", domain, plist.path], timeout: 15)
        let check = await runner.run("/bin/launchctl", ["print", "\(domain)/\(LaunchAgentInfo.label)"], timeout: 10)
        guard check.succeeded else {
            throw LidlessError.system("launchd did not load the recovery agent: \(boot.stderr.trimmed)")
        }
    }

    public static func removeLaunchAgent(runner: CommandRunning = ProcessCommandRunner()) async {
        _ = await runner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(LaunchAgentInfo.label)"], timeout: 15)
        try? FileManager.default.removeItem(at: LaunchAgentInfo.plistURL)
    }

    // MARK: CLI link

    /// Links ~/.local/bin/lidless to the bundled CLI. Never replaces a real
    /// file, only a missing entry or an older symlink.
    @discardableResult
    public static func linkCLI(cliPath: String) throws -> URL {
        let link = cliLink
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if existing == cliPath { return link }
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw LidlessError.system("\(link.path) exists and is not a link; left it alone.")
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: cliPath)
        return link
    }

    public static func unlinkCLI() {
        let link = cliLink
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), dest.hasSuffix("/lidless") {
            try? FileManager.default.removeItem(at: link)
        }
    }

    public static func isOnPath(_ dir: URL) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == dir.path }
    }

    // MARK: Whole flows

    /// Installs everything missing. Safe to run again.
    public static func setup(cliPath: String, power: PowerControlling, elevation: Elevation) async throws -> Report {
        var report = Report()
        try await installLaunchAgent(cliPath: cliPath)
        report.steps.append("Recovery agent installed and loaded")

        do {
            let link = try linkCLI(cliPath: cliPath)
            report.steps.append("Command-line tool linked at \(link.path)")
        } catch {
            report.warnings.append("Could not link the command-line tool: \(error)")
        }

        if await power.privilegeReady() {
            report.steps.append("Permission to toggle sleep already installed")
        } else {
            try await runAsRoot(try sudoersInstallScript(user: currentUserName()), elevation: elevation)
            guard await power.privilegeReady() else {
                throw LidlessError.system("The permission was installed but sudo still asks for a password. Check that /etc/sudoers includes /etc/sudoers.d.")
            }
            report.steps.append("Permission to toggle sleep installed (\(sudoersPath))")
        }
        Log.info("setup: \(report.steps.joined(separator: "; "))")
        return report
    }

    /// Restores settings first (via recovery), then removes the agent, the
    /// sudoers rule and the CLI link. Refuses while anything is unrestored.
    public static func uninstall(env: OwnerEnvironment, elevation: Elevation) async throws -> Report {
        var report = Report()
        if case .some(let s) = env.store.readSession(), env.inspector.isAlive(s.owner) {
            throw LidlessError.sessionActive
        }
        let outcome = await env.recovery.run(forceEndReason: .stopped)
        let journalClean = try env.store.readJournal().isEmpty
        if !outcome.report.complete || !journalClean {
            throw LidlessError.restoreIncomplete("Settings are still waiting to be restored, so Lidless was not removed: \(outcome.message)")
        }
        await removeLaunchAgent()
        report.steps.append("Recovery agent removed")
        if FileManager.default.fileExists(atPath: sudoersPath) {
            try await runAsRoot(sudoersRemoveScript, elevation: elevation)
            report.steps.append("Permission removed (\(sudoersPath))")
        }
        unlinkCLI()
        report.steps.append("Command-line link removed")
        Log.info("uninstall: \(report.steps.joined(separator: "; "))")
        return report
    }
}
