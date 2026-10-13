import Darwin
import Foundation
import LidlessCore

// MARK: - Argument handling

var arguments = Array(CommandLine.arguments.dropFirst())
// Global flags apply only before a `--` separator (so `run -- cmd --json` passes through).
let separatorIndex = arguments.firstIndex(of: "--") ?? arguments.count
let jsonOutput = arguments[..<separatorIndex].contains("--json")
if jsonOutput {
    arguments.remove(at: arguments[..<separatorIndex].firstIndex(of: "--json")!)
}

let paths = LidlessPaths.resolve()
Log.shared.configure(paths: paths)
let store = Store(paths: paths)
let inspector = SystemProcessInspector()
let sensors = SystemSensors()
let runner = ProcessCommandRunner()
let power = PmsetPowerControl(runner: runner)
let readiness = Readiness(power: power, agent: LaunchdRecoveryAgentChecker(runner: runner))
let control = SessionControl(store: store, inspector: inspector)

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// Human text goes to stdout normally, stderr in --json mode.
func say(_ s: String) {
    if jsonOutput { eprint(s) } else { print(s) }
}

func emitJSON<T: Encodable>(_ value: T) {
    guard jsonOutput else { return }
    if let data = try? LidlessJSON.encoder().encode(value) {
        print(String(decoding: data, as: UTF8.self))
    }
}

struct ErrorJSON: Encodable {
    var ok = false
    var error: String
    var code: Int32
}

func fail(_ error: Error) -> Never {
    let e = (error as? LidlessError) ?? .system("\(error)")
    if jsonOutput {
        emitJSON(ErrorJSON(error: e.description, code: e.exitCode))
    } else {
        eprint("lidless: \(e.description)")
    }
    Log.shared.flush()
    exit(e.exitCode)
}

func finish(_ code: Int32 = 0) -> Never {
    Log.shared.flush()
    exit(code)
}

func timeString(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
    f.timeStyle = .short
    return f.string(from: date)
}

let usage = """
lidless: keep your Mac awake with the lid closed while your coding agents work.

Usage:
  lidless start <duration>               Start a session (e.g. 2h, 90m, 1d2h)
  lidless run [--duration <d>] -- <cmd>  Stay awake while <cmd> runs, then restore
  lidless extend <duration>              Add time to the current session
  lidless stop                           End the session and restore settings
  lidless status                         Show the current session and warnings
  lidless doctor                         Check that everything is set up
  lidless agents                         List detected coding agents
  lidless stats                          Your usage: time awake, closed-lid time, sessions
  lidless update                         Check GitHub for a newer release
  lidless config [<key> [<value>]]       Show or change settings
  lidless setup                          One-time setup: recovery agent + sleep permission (asks for your password)
  lidless uninstall                      Restore settings and remove the agent, permission and CLI link
  lidless recover                        Run recovery once (the launchd agent does this every minute)
  lidless version

Add --json to any command for machine-readable output.
Use a ventilated surface while the lid is closed. Never put a running laptop in a bag.
"""

// MARK: - Commands

struct StartedJSON: Encodable {
    var ok = true
    var session: Session
}

/// `start`: spawn a detached holder that owns the session, wait for its verdict.
/// Heat reminder before every start; a critical state is refused by the core.
func warnIfWarm() {
    let heat = sensors.thermal()
    if heat.isWarm, heat != .critical, let warning = heat.startWarning {
        eprint("lidless: ⚠︎ \(warning)")
    }
}

@MainActor func cmdStart(_ args: [String]) async -> Never {
    guard args.count == 1 else { fail(LidlessError.usage("Usage: lidless start <duration>")) }
    let seconds: TimeInterval
    do { seconds = try DurationParser.parse(args[0]) } catch { fail(error) }
    warnIfWarm()

    guard let exe = Bundle.main.executablePath else { fail(LidlessError.system("Cannot find the lidless executable path.")) }
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: exe)
    holder.arguments = ["_hold", "--seconds", String(Int(seconds))]
    let pipe = Pipe()
    holder.standardOutput = pipe
    holder.standardError = FileHandle.nullDevice
    holder.standardInput = FileHandle.nullDevice
    say("Engaging and verifying (this takes a few seconds)…")
    fflush(stdout)
    do { try holder.run() } catch { fail(LidlessError.system("Could not start the session process: \(error)")) }

    // The holder writes one JSON line, then detaches its stdout.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
          let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
        fail(LidlessError.system("The session process exited without reporting. See \(paths.log.path)."))
    }
    if obj["ok"] as? Bool == true, case .some(let s) = store.readSession() {
        emitJSON(StartedJSON(session: s))
        say("Lidless is on until \(timeString(s.endsAt)) (\(DurationParser.format(s.remaining(at: Date())))). You can close the lid.")
        say("Stop with `lidless stop`, add time with `lidless extend 1h`. Keep the Mac on a ventilated surface.")
        finish()
    }
    let code = Int32((obj["code"] as? Int) ?? 1)
    let message = (obj["error"] as? String) ?? "Unknown error"
    if jsonOutput {
        emitJSON(ErrorJSON(error: message, code: code))
    } else {
        eprint("lidless: \(message)")
    }
    finish(code)
}

/// Hidden: the detached session holder started by `lidless start`.
@MainActor func cmdHold(_ args: [String]) async -> Never {
    setsid()
    signal(SIGHUP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    guard args.count == 2, args[0] == "--seconds", let seconds = TimeInterval(args[1]) else { finish(2) }

    func report(_ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        // Detach from the starter so it sees EOF and exits.
        let devnull = open("/dev/null", O_RDWR)
        dup2(devnull, STDOUT_FILENO)
        dup2(devnull, STDERR_FILENO)
        close(devnull)
    }

    let owner = SessionOwner(env: .live(paths: paths, notifier: OSAScriptNotifier()))
    do {
        try await owner.start(duration: seconds, kind: .cli)
    } catch {
        let e = (error as? LidlessError) ?? .system("\(error)")
        report(["ok": false, "error": e.description, "code": Int(e.exitCode)])
        finish(e.exitCode)
    }
    report(["ok": true])

    let signals = installTerminationHandlers {
        Task { @MainActor in
            await owner.end(.ownerTerminated)
        }
    }
    let le = await owner.waitForEnd()
    _ = signals
    finish(le.restoreComplete ? 0 : 7)
}

/// Turns SIGTERM/SIGINT into a graceful end instead of an abrupt exit.
func installTerminationHandlers(_ handler: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { sig in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler(handler: handler)
        src.resume()
        return src
    }
}

final class ChildState: @unchecked Sendable {
    var exited = false
    var exitCode: Int32 = 0
}

/// `run`: own the session in this process while a command runs.
@MainActor func cmdRun(_ args: [String]) async -> Never {
    var rest = args
    var duration: TimeInterval = store.readConfig().runDefaultDurationSeconds
    while let first = rest.first, first != "--" {
        rest.removeFirst()
        if first == "--duration" || first == "-d", let value = rest.first {
            rest.removeFirst()
            do { duration = try DurationParser.parse(value) } catch { fail(error) }
        } else if first.hasPrefix("--duration=") {
            do { duration = try DurationParser.parse(String(first.dropFirst("--duration=".count))) } catch { fail(error) }
        } else {
            fail(LidlessError.usage("Usage: lidless run [--duration <d>] -- <command> [args...]"))
        }
    }
    guard rest.first == "--", rest.count >= 2 else {
        fail(LidlessError.usage("Usage: lidless run [--duration <d>] -- <command> [args...]"))
    }
    let command = Array(rest.dropFirst())

    let owner = SessionOwner(env: .live(paths: paths, notifier: OSAScriptNotifier()))
    let child = ChildState()
    owner.externalEndCheck = { child.exited ? .commandExited : nil }

    warnIfWarm()
    eprint("lidless: engaging and verifying…")
    do {
        try await owner.start(duration: duration, kind: .run, command: command)
    } catch {
        fail(error)  // Spec: the command is not run if the session cannot start.
    }
    if let s = owner.session {
        eprint("lidless: awake until \(timeString(s.endsAt)) or until `\(command.joined(separator: " "))` exits. You can close the lid.")
    }

    // posix_spawnp keeps the child in our process group, so it owns the
    // terminal like any foreground command and gets Ctrl-C directly.
    var pid: pid_t = 0
    let cArgs: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { cArgs.forEach { free($0) } }
    let spawnResult = posix_spawnp(&pid, command[0], nil, nil, cArgs, environ)
    guard spawnResult == 0 else {
        eprint("lidless: could not run \(command[0]): \(String(cString: strerror(spawnResult)))")
        await owner.end(.commandExited, detail: "The command could not be started.")
        finish(127)
    }

    // While the child runs, Ctrl-C belongs to it; we only forward TERM/HUP.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)
    let forwarders: [DispatchSourceSignal] = [SIGTERM, SIGHUP].map { sig in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { kill(pid, sig) }
        src.resume()
        return src
    }

    let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    let childPid = pid
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        exitSource.setEventHandler {
            var status: Int32 = 0
            while waitpid(childPid, &status, 0) < 0 && errno == EINTR {}
            let low = status & 0x7f
            child.exitCode = low == 0 ? (status >> 8) & 0xff : 128 + low
            child.exited = true
            exitSource.cancel()
            cont.resume()
        }
        exitSource.resume()
    }
    _ = forwarders

    if owner.session != nil {
        let le = await owner.end(.commandExited)
        if !le.restoreComplete { eprint("lidless: \(le.detail ?? "restore incomplete"); the recovery agent will retry.") }
    } else if let le = owner.lastEnd, le.reason != .commandExited {
        eprint("lidless: the awake session had already ended (\(le.reason.summary))")
    }
    eprint("lidless: normal sleep restored.")
    finish(child.exitCode)
}

struct ExtendedJSON: Encodable {
    var ok = true
    var session: Session
    var clamped: Bool
}

@MainActor func cmdExtend(_ args: [String]) -> Never {
    guard args.count == 1 else { fail(LidlessError.usage("Usage: lidless extend <duration>")) }
    do {
        let seconds = try DurationParser.parse(args[0])
        let (s, clamped) = try control.extend(by: seconds)
        emitJSON(ExtendedJSON(session: s, clamped: clamped))
        say("Session now ends at \(timeString(s.endsAt)) (\(DurationParser.format(s.remaining(at: Date()))) left)\(clamped ? ", capped at the maximum session length" : "").")
        finish()
    } catch {
        fail(error)
    }
}

struct StoppedJSON: Encodable {
    var ok: Bool
    var lastEnd: LastEnd?
    var message: String
}

@MainActor func cmdStop() async -> Never {
    let request: SessionControl.StopRequest
    do { request = try control.requestStop() } catch { fail(error) }
    switch request {
    case .requested(let id):
        say("Stopping…")
        guard let le = await control.waitForEnd(sessionID: id, timeout: 45) else {
            fail(LidlessError.system("The session owner did not finish within 45 s. Check `lidless status`; the recovery agent will finish the job."))
        }
        emitJSON(StoppedJSON(ok: le.restoreComplete, lastEnd: le, message: le.restoreComplete ? "Stopped." : (le.detail ?? "")))
        if le.restoreComplete {
            say("Stopped. Normal sleep is back.")
            finish()
        }
        say("Stopped, but not everything was restored: \(le.detail ?? "")")
        finish(7)
    case .ownerDead:
        let env = OwnerEnvironment.live(paths: paths, notifier: NoopNotifier())
        let outcome = await env.recovery.run(forceEndReason: .stopped)
        emitJSON(StoppedJSON(ok: outcome.report.complete, lastEnd: store.readLastEnd(), message: outcome.message))
        say(outcome.message)
        finish(outcome.report.complete ? 0 : 7)
    }
}

@MainActor func cmdStatus() async -> Never {
    let ready = await readiness.check()
    let snap = StatusSnapshot.collect(store: store, sensors: sensors, inspector: inspector, readiness: ready)
    if jsonOutput {
        emitJSON(snap)
        finish()
    }
    if let s = snap.session {
        print("● Active: ends at \(timeString(s.endsAt)) (\(DurationParser.clock(TimeInterval(s.remainingSeconds))) left)")
        let ownerText = s.owner.kind == .app ? "menu bar app" : s.owner.kind == .run ? "lidless run" : "lidless start"
        print("  Owner: \(ownerText), pid \(s.owner.pid)\(s.owner.alive ? "" : " (gone)")")
        if let cmd = s.command { print("  Command: \(cmd.joined(separator: " "))") }
        if s.stopRequested != nil { print("  Stopping…") }
    } else {
        print("○ No active session")
        if let le = snap.lastEnd {
            print("  Last session ended \(timeString(le.at)): \(le.reason.summary)\(le.restoreComplete ? "" : " (restore incomplete)")")
        }
    }
    if let lid = snap.lidClosed { print("  Lid: \(lid ? "closed" : "open")") }
    let p = snap.power
    if p.hasBattery {
        print("  Power: \(p.onBattery ? "battery" : "AC")\(p.percent.map { ", \($0)%" } ?? ""), thermal \(p.thermal.rawValue)")
    } else {
        print("  Power: AC, thermal \(p.thermal.rawValue)")
    }
    if snap.journal.sleepDisabled || snap.journal.lowPowerMode {
        var changed: [String] = []
        if snap.journal.sleepDisabled { changed.append("sleep disabled") }
        if snap.journal.lowPowerMode { changed.append("Low Power Mode on") }
        print("  Changed by Lidless (will be restored): \(changed.joined(separator: ", "))")
    }
    for w in snap.warnings { print("  ⚠︎ \(w)") }
    finish()
}

struct DoctorCheck: Encodable {
    var name: String
    var ok: Bool
    var detail: String
}

struct DoctorJSON: Encodable {
    var ok: Bool
    var checks: [DoctorCheck]
}

@MainActor func cmdDoctor() async -> Never {
    var checks: [DoctorCheck] = []
    let ready = await readiness.check()
    checks.append(DoctorCheck(name: "privilege", ok: ready.privilege,
                              detail: ready.privilege ? "sudoers rule allows the pmset commands without a password" : "sudo would ask for a password; run `lidless setup` or click Set Up in the menu"))
    checks.append(DoctorCheck(name: "recovery agent", ok: ready.recoveryArmed, detail: ready.recoveryDetail))

    var homeOK = true
    var homeDetail = paths.home.path
    do {
        try paths.ensureHome()
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.home.path)
        let perms = (attrs[.posixPermissions] as? Int) ?? 0
        homeOK = perms & 0o077 == 0
        homeDetail += String(format: " (mode %o)", perms)
    } catch {
        homeOK = false
        homeDetail += ": \(error)"
    }
    checks.append(DoctorCheck(name: "state directory", ok: homeOK, detail: homeDetail))

    do {
        let j = try store.readJournal()
        checks.append(DoctorCheck(name: "journal", ok: true, detail: j.isEmpty ? "clean" : "has entries waiting to be restored"))
    } catch {
        checks.append(DoctorCheck(name: "journal", ok: false, detail: "\(error)"))
    }

    do {
        let disabled = try await power.readSleepDisabled()
        var detail = "SleepDisabled \(disabled ? 1 : 0)"
        if disabled, case .none = store.readSession() {
            detail += ": closed-lid sleep is disabled but not by a Lidless session. If you did not mean this, run: sudo pmset -a disablesleep 0"
        }
        checks.append(DoctorCheck(name: "pmset readable", ok: true, detail: detail))
    } catch {
        checks.append(DoctorCheck(name: "pmset readable", ok: false, detail: "\(error)"))
    }

    let b = sensors.battery()
    checks.append(DoctorCheck(name: "power", ok: true,
                              detail: b.hasBattery ? "\(b.onBattery ? "on battery" : "on AC")\(b.percent.map { ", \($0)%" } ?? ", level unreadable")" : "no battery"))
    let agents = AgentDetector.detect(extraNames: store.readConfig().extraAgentNames)
    checks.append(DoctorCheck(name: "agents", ok: true,
                              detail: agents.isEmpty ? "none running" : agents.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")))
    checks.append(DoctorCheck(name: "macOS", ok: true, detail: ProcessInfo.processInfo.operatingSystemVersionString))

    let ok = ready.ready && homeOK
    if jsonOutput {
        emitJSON(DoctorJSON(ok: ok, checks: checks))
    } else {
        for c in checks { print("\(c.ok ? "✓" : "✗") \(c.name): \(c.detail)") }
        print(ok ? "\nReady: sessions can start." : "\nNot ready: fix the ✗ items above.")
    }
    finish(ok ? 0 : 3)
}

struct RecoverJSON: Encodable {
    var ok: Bool
    var message: String
}

@MainActor func cmdRecover() async -> Never {
    let env = OwnerEnvironment.live(paths: paths, notifier: OSAScriptNotifier())
    let outcome = await env.recovery.run()
    emitJSON(RecoverJSON(ok: outcome.report.complete, message: outcome.message))
    if !jsonOutput && outcome.action != .nothing { print(outcome.message) }
    if case .endSession(let reason) = outcome.action, reason != .stopped {
        env.notifier.notify(title: "Lidless session ended", body: reason.summary + (outcome.report.complete ? " Normal sleep is back." : " Some settings could not be restored yet."))
    }
    finish(outcome.report.complete ? 0 : 7)
}

@MainActor func cmdAgents() -> Never {
    let agents = AgentDetector.detect(extraNames: store.readConfig().extraAgentNames)
    if jsonOutput {
        emitJSON(agents)
    } else if agents.isEmpty {
        print("No coding agents detected.")
    } else {
        for a in agents { print("\(a.name)\tpid \(a.pid)") }
    }
    finish()
}

@MainActor func cmdConfig(_ args: [String]) -> Never {
    let config = store.readConfig()
    guard var dict = (try? JSONSerialization.jsonObject(with: LidlessJSON.encoder().encode(config))) as? [String: Any] else {
        fail(LidlessError.system("Could not encode config."))
    }
    switch args.count {
    case 0:
        if let data = try? LidlessJSON.encoder().encode(config) { print(String(decoding: data, as: UTF8.self)) }
        finish()
    case 1:
        guard let value = dict[args[0]] else { fail(LidlessError.usage("Unknown key \(args[0]). Keys: \(dict.keys.sorted().joined(separator: ", "))")) }
        print(value)
        finish()
    case 2:
        let key = args[0], raw = args[1]
        guard let current = dict[key] else { fail(LidlessError.usage("Unknown key \(key). Keys: \(dict.keys.sorted().joined(separator: ", "))")) }
        if current is [Any] {
            dict[key] = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if let n = current as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            guard let b = Bool(raw.lowercased()) else { fail(LidlessError.usage("\(key) takes true or false.")) }
            dict[key] = b
        } else if current is NSNumber {
            if key.hasSuffix("Seconds"), let seconds = try? DurationParser.parse(raw) {
                dict[key] = seconds
            } else if let d = Double(raw) {
                dict[key] = d
            } else {
                fail(LidlessError.usage("\(key) takes a number\(key.hasSuffix("Seconds") ? " or a duration like 2h" : "")."))
            }
        } else {
            dict[key] = raw
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            let updated = try LidlessJSON.decoder().decode(Config.self, from: data)
            try store.writeConfig(updated)
            let saved = store.readConfig()
            let savedDict = (try? JSONSerialization.jsonObject(with: LidlessJSON.encoder().encode(saved))) as? [String: Any]
            print("\(key) = \(savedDict?[key] ?? "?")")
            finish()
        } catch {
            fail(error)
        }
    default:
        fail(LidlessError.usage("Usage: lidless config [<key> [<value>]]"))
    }
}

/// The real path of this binary (resolving the ~/.local/bin link).
func selfPath() -> String {
    let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
}

struct InstallerJSON: Encodable {
    var ok = true
    var steps: [String]
    var warnings: [String]
}

@MainActor func cmdSetup() async -> Never {
    let cli = selfPath()
    if cli.contains("/.build/") {
        eprint("lidless: note: setting up with a development build at \(cli). The recovery agent will point there.")
    }
    if await power.privilegeReady() {
        say("Setting up Lidless.")
    } else {
        say("Setting up Lidless. sudo will ask for your password once, to allow exactly four pmset commands.")
    }
    do {
        let report = try await Installer.setup(cliPath: cli, power: power, elevation: .terminalSudo)
        emitJSON(InstallerJSON(steps: report.steps, warnings: report.warnings))
        for s in report.steps { say("✓ \(s)") }
        for w in report.warnings { say("⚠︎ \(w)") }
        if !Installer.isOnPath(Installer.cliLink.deletingLastPathComponent()) {
            say("Note: ~/.local/bin is not on your PATH. Add to your shell profile: export PATH=\"$HOME/.local/bin:$PATH\"")
        }
        say("Ready. Try: lidless start 2h  (keep the Mac on a ventilated surface)")
        finish()
    } catch {
        fail(error)
    }
}

@MainActor func cmdUninstall() async -> Never {
    let env = OwnerEnvironment.live(paths: paths, notifier: NoopNotifier())
    do {
        let report = try await Installer.uninstall(env: env, elevation: .terminalSudo)
        emitJSON(InstallerJSON(steps: report.steps, warnings: report.warnings))
        for s in report.steps { say("✓ \(s)") }
        say("To finish, move Lidless.app to the Trash. Your state and logs stay in \(paths.home.path).")
        finish()
    } catch {
        fail(error)
    }
}

@MainActor func cmdStats() -> Never {
    History.backfillFromLogIfNeeded(store)
    let stats = UsageStats.compute(History.read(store))
    if jsonOutput {
        emitJSON(stats)
        finish()
    }
    guard stats.sessions > 0 else {
        print("No sessions yet. Start one with: lidless start 2h")
        finish()
    }
    let f = DurationParser.format
    print("Sessions             \(stats.sessions)")
    print("Time awake           \(f(stats.totalAwakeSeconds))")
    print("With the lid closed  \(f(stats.closedLidSeconds))")
    print("This week            \(f(stats.thisWeekSeconds))")
    print("Longest session      \(f(stats.longestSeconds))")
    print("Average session      \(f(stats.averageSeconds))")
    if let pct = stats.cleanRestorePercent { print("Restored cleanly     \(pct)%") }
    if stats.endedBySafety > 0 { print("Ended by safety      \(stats.endedBySafety)") }
    finish()
}

struct UpdateJSON: Encodable {
    var current: String
    var latest: String?
    var updateAvailable: Bool
    var downloadURL: String?
    var pageURL: String?
}

@MainActor func cmdUpdate() async -> Never {
    do {
        switch try await UpdateChecker.check() {
        case .noReleases:
            emitJSON(UpdateJSON(current: LidlessVersion.string, latest: nil, updateAvailable: false))
            say("Lidless \(LidlessVersion.string). No releases have been published yet.")
        case .upToDate(let latest):
            emitJSON(UpdateJSON(current: LidlessVersion.string, latest: latest, updateAvailable: false))
            say("Lidless \(LidlessVersion.string) is up to date.")
        case .available(let r):
            emitJSON(UpdateJSON(current: LidlessVersion.string, latest: r.version, updateAvailable: true,
                                downloadURL: r.downloadURL?.absoluteString, pageURL: r.pageURL.absoluteString))
            say("Lidless \(r.version) is available (you have \(LidlessVersion.string)).")
            say("Download: \((r.downloadURL ?? r.pageURL).absoluteString)")
            say("Or open the Lidless app and choose Lidless → Check for Updates…")
        }
        finish()
    } catch {
        fail(LidlessError.system("Could not check for updates: \(error.localizedDescription)"))
    }
}

// MARK: - Dispatch

guard let command = arguments.first else {
    print(usage)
    finish(2)
}
let rest = Array(arguments.dropFirst())

switch command {
case "start": await cmdStart(rest)
case "_hold": await cmdHold(rest)
case "run": await cmdRun(rest)
case "extend": cmdExtend(rest)
case "stop": await cmdStop()
case "status": await cmdStatus()
case "doctor": await cmdDoctor()
case "recover": await cmdRecover()
case "setup", "install": await cmdSetup()
case "uninstall": await cmdUninstall()
case "agents": cmdAgents()
case "stats": cmdStats()
case "update": await cmdUpdate()
case "config": cmdConfig(rest)
case "version", "--version", "-v":
    print("lidless \(LidlessVersion.string)")
    finish()
case "help", "--help", "-h":
    print(usage)
    finish()
default:
    eprint("lidless: unknown command \(command)\n")
    eprint(usage)
    finish(2)
}
