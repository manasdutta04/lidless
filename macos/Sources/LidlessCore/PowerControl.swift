import Foundation

/// The only operations Lidless performs on macOS power settings. The real
/// implementation shells out to `pmset`; tests use a fake.
public protocol PowerControlling: Sendable {
    /// `SleepDisabled` from `pmset -g`. Throws when it cannot be read.
    func readSleepDisabled() async throws -> Bool
    /// `sudo -n pmset -a disablesleep 0|1`.
    func setSleepDisabled(_ disabled: Bool) async -> CommandResult
    /// Battery-profile `lowpowermode` from `pmset -g custom`.
    func readLowPowerMode() async throws -> Bool
    /// `sudo -n pmset -b lowpowermode 0|1`.
    func setLowPowerMode(_ on: Bool) async -> CommandResult
    /// `pmset displaysleepnow` (no privilege needed, nothing to restore).
    func sleepDisplayNow() async
    /// Whether the narrow sudoers rule lets us run the pmset commands without a password.
    func privilegeReady() async -> Bool
}

public enum PmsetParser {
    /// `pmset -g` prints " SleepDisabled  1" only while sleep is disabled;
    /// macOS 27 omits the line entirely when it is 0.
    public static func sleepDisabled(fromPmsetG output: String) -> Bool? {
        guard output.contains("System-wide power settings") || output.contains("Currently in use") else {
            return nil
        }
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                switch parts[1] {
                case "1": return true
                case "0": return false
                default: return nil
                }
            }
        }
        return false
    }

    /// Reads `lowpowermode` from the "Battery Power:" section of `pmset -g custom`.
    public static func batteryLowPowerMode(fromPmsetCustom output: String) -> Bool? {
        var inBattery = false
        for line in output.split(separator: "\n") {
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inBattery = line.hasPrefix("Battery Power")
                continue
            }
            guard inBattery else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "lowpowermode" {
                switch parts[1] {
                case "1": return true
                case "0": return false
                default: return nil
                }
            }
        }
        return nil
    }
}

public struct PmsetPowerControl: PowerControlling {
    public static let pmset = "/usr/bin/pmset"
    public static let sudo = "/usr/bin/sudo"
    /// Privileged commands get 20 s, then SIGTERM (never SIGKILL).
    public static let privilegedTimeout: TimeInterval = 20

    /// Exactly the commands the sudoers rule allows (`Installer.sudoersLines`
    /// is built from this list). Keep the README's "Privileged commands" in sync.
    public static let allowedPrivilegedArguments: [[String]] = [
        ["-a", "disablesleep", "1"],
        ["-a", "disablesleep", "0"],
        ["-b", "lowpowermode", "1"],
        ["-b", "lowpowermode", "0"],
    ]

    let runner: CommandRunning

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func readSleepDisabled() async throws -> Bool {
        let r = await runner.run(Self.pmset, ["-g"], timeout: 10)
        guard r.succeeded, let value = PmsetParser.sleepDisabled(fromPmsetG: r.stdout) else {
            throw LidlessError.system("Could not read SleepDisabled from `pmset -g` (status \(r.status)): \(r.stderr.trimmed)")
        }
        return value
    }

    public func setSleepDisabled(_ disabled: Bool) async -> CommandResult {
        await privileged(["-a", "disablesleep", disabled ? "1" : "0"])
    }

    public func readLowPowerMode() async throws -> Bool {
        let r = await runner.run(Self.pmset, ["-g", "custom"], timeout: 10)
        guard r.succeeded, let value = PmsetParser.batteryLowPowerMode(fromPmsetCustom: r.stdout) else {
            throw LidlessError.system("Could not read battery lowpowermode from `pmset -g custom` (status \(r.status)).")
        }
        return value
    }

    public func setLowPowerMode(_ on: Bool) async -> CommandResult {
        await privileged(["-b", "lowpowermode", on ? "1" : "0"])
    }

    public func sleepDisplayNow() async {
        _ = await runner.run(Self.pmset, ["displaysleepnow"], timeout: 10)
    }

    public func privilegeReady() async -> Bool {
        // `sudo -n -l <cmd>` exits 0 only if that exact command may run without a password.
        let r = await runner.run(Self.sudo, ["-n", "-l", Self.pmset, "-a", "disablesleep", "1"], timeout: 10)
        return r.succeeded
    }

    private func privileged(_ args: [String]) async -> CommandResult {
        precondition(Self.allowedPrivilegedArguments.contains(args), "unexpected privileged command")
        return await runner.run(Self.sudo, ["-n", Self.pmset] + args, timeout: Self.privilegedTimeout)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
