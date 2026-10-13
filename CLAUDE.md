# CLAUDE.md: Lidless

This file is the source of truth for what Lidless is, how it must behave, and
what to build next. Read it fully before making changes. Update the **Status**
and **Decision log** sections whenever work lands or a decision changes.

---

## 0. Repository hygiene (binding)

- Lidless is an original open-source project. Do **not** add notes about where
  ideas came from, "inspired by" or "based on" text, or links to other
  projects that do similar things. This applies to code, comments, docs,
  commit messages, PR descriptions and issues.
- Write all code from scratch. Do not paste code or prose from other
  repositories.
- Private working notes do not belong in the repo. Keep them outside the
  working tree.

---

## 1. What Lidless is

Lidless keeps a laptop awake, with its processes running, **after the lid is
closed**, for a length of time the user chooses. The main use case: start a
long-running coding agent (Claude Code, Codex, etc.), close the lid, and let the
agent keep working. The user can then reach it through remote control, SSH or
a phone.

It is a small menu bar / tray app plus a CLI (`lidless`). It is **not** a
general-purpose power manager.

Platform order: **macOS first**, then Windows, then Linux.

**Name:** "Lidless", CLI `lidless`. Trademark, domain and package names are
**not yet checked**.

---

## 2. Product principles

1. **Sessions are always timed.** No "awake forever" toggle. Default max is 30
   days, configurable.
2. **Agents come first.** Lidless protects agent processes. It never freezes,
   throttles or signals them.
3. **Leave the machine as you found it.** Every change is undone at session
   end, on quit, after a crash and after a reboot.
4. **Fail safe and fail loud.** If we can't verify the machine will stay awake,
   say so and roll back. Never claim success we haven't checked.
5. **The CLI and the app are equal.** Anything the app can do, the CLI can do,
   with machine-readable output (`--json`) so agents can script it.

---

## 3. Hard rules (binding, every change)

1. **Journal before change.** Write the journal entry to disk (atomic write +
   fsync) *before* making the system change. A crash must never leave an
   unrecorded change.
2. **A session never starts unless recovery is armed.** If the recovery job
   can't be installed or verified, refuse to start and show the error.
3. **Verify after engaging.** After asking for "stay awake with the lid
   closed", read the setting back after a settle delay (5 s to start). If it was
   reverted or can't be read: end the attempt, restore, report.
4. **Restore only what we changed.** Record the original value of every
   setting before changing it. Never "restore" a value we didn't record.
5. **Never signal or modify a process we can't prove we own** (or that the
   user didn't explicitly opt in).
6. **Quitting always ends the session.** No "keep awake after quit".
7. **Minimal privilege.** Only the narrow operations that need root run
   elevated. List every elevated command in the README.
8. **Tests never touch real power settings.** Use fakes and temp directories.
   Never run `pmset` / `powercfg` / logind changes during development. If a
   manual check is needed, tell the human the exact command to run.
9. **Heat warning.** README and first-run UI must tell users to use a
   ventilated surface, never a closed bag.

---

## 4. Architecture

One repo, one product, a native engine per OS, and a shared written spec.

- **macOS:** Swift 6.x, SwiftUI hosted in an `NSStatusItem` menu bar app, built
  as a Swift Package (no Xcode project). Targets: app, CLI, core library, tests.
- **Windows / Linux:** Rust. A shared core crate (sessions, floors, journal, CLI
  parsing) plus a thin per-OS layer.
- **Windows/Linux UI:** Tauri tray app (proposed, confirm before committing to
  it). Linux ships daemon + CLI first.
- **`spec/` is the contract.** Swift and Rust must behave identically. If they
  diverge, fix the spec first, then both implementations.

```
lidless/
├── CLAUDE.md          # this file
├── README.md
├── LICENSE
├── spec/              # behavior spec, journal JSON schema, CLI contract, test vectors
├── macos/             # Swift package: LidlessCore, LidlessApp, lidless CLI, recovery, installer
├── rust/
│   ├── core/          # shared: sessions, floors, journal, CLI parsing
│   ├── windows/       # Win32 power control, Task Scheduler recovery
│   ├── linux/         # logind inhibitor via D-Bus (zbus)
│   └── app/           # Tauri tray UI
└── docs/              # release-validation.md, findings notes, privilege docs
```

---

## 5. The spec (`spec/`), written first (M0)

1. **Session model:** `id`, `startedAt`, `endsAt`, `extensions[]`, `endReason`,
   `owner` (`app` | `cli` | `run`), optional `wrappedPid` for `lidless run`.
   Only `endsAt` decides whether the machine stays awake. Max duration is
   configurable, default 30 days.
2. **Journal schema:** versioned JSON listing everything Lidless changed and
   must undo, with each original value. Neutral fields plus a per-OS section.
   - macOS: `sleepDisabledByUs`, `lowPowerModeSetByUs` + original value, saved
     display/keyboard brightness, saved mute state, list of PIDs we
     `SIGSTOP`ped (with process start time, so PID reuse is caught).
   - Windows: original lid-close action (AC + DC) per power scheme, any other
     power values changed, power-request handles.
   - Linux: inhibitor lock details (lock is released when its fd closes, which
     needs confirming).
3. **Safety floors and defaults:** start with Low Power Mode below 40%
   battery, end the session below 10%, thermal rules on. Tune after real
   testing.
4. **CLI contract (same on every OS):**
   - `lidless start <duration>`, e.g. `2h`, `90m`, `1d2h`
   - `lidless extend <duration>`
   - `lidless stop`
   - `lidless status [--json]`
   - `lidless run [--duration <d>] [--grace <d>] -- <command...>`: stay awake
     while the command runs, then restore (also on failure / Ctrl-C).
     The exit code passes through.
   - `lidless doctor`: checks privilege setup, recovery agent, journal,
     current power state.
   - `lidless install` / `lidless uninstall`
   - Exit codes and `--json` output shapes are part of the spec.
5. **Shared test vectors:** JSON cases (input → expected state) that both the
   Swift and Rust test suites load: duration parsing, session math, floor
   decisions, journal replay.

---

## 6. macOS engine (M1)

- **Engage:** `sudo -n /usr/bin/pmset -a disablesleep 1`, then read back with
  `pmset -g` after ~5 s. Some macOS releases silently revert this, so
  verification is mandatory (rule 3). Re-check periodically during the session
  too, not just once.
- **Also hold an IOPM assertion** (`IOPMAssertionCreateWithName`,
  `PreventUserIdleSystemSleep`) while a session is active, so idle sleep is
  covered even with the lid open. Assertions die with the process, so they are
  crash-safe.
- **Restore:** `pmset -a disablesleep 0`, but only if the journal says we set it.
- **Lid events:** IOKit interest notification on `IOPMrootDomain`, read
  `AppleClamshellState`, debounce ~2 s.
- **Battery / thermal:** `IOPSNotificationCreateRunLoopSource`,
  `ProcessInfo.thermalStateDidChangeNotification`.
- **Recovery:** a per-user launchd agent runs a standalone recovery script every
  60 s and at login/boot. It reads only the journal (no dependency on the app)
  and undoes changes if the owning process is gone or the session has expired.
- **Privilege (MVP):** a sudoers drop-in allowing *exactly*
  `pmset -a disablesleep 0|1` and `pmset -b lowpowermode 0|1`, validated with
  `visudo -c` before install. Known weakness: any process running as the user
  can use it. Later: signed privileged helper via `SMAppService`.
- **Closed-lid power saving (optional, journaled, reversed on lid open):**
  display off, keyboard backlight off, Low Power Mode, mute. Brightness control
  uses private frameworks: gate it by measured OS versions, or leave it out of
  the MVP.
- **Docs note:** on Apple silicon / T2 Macs, closing the lid cuts the built-in
  mic in hardware, which affects voice tools.
- **Distribution:** Developer ID signing + notarization later. Until then,
  expect Gatekeeper friction.

---

## 7. Where Lidless goes further (differentiators)

Build these on top of a solid core:

1. **Protect list.** Built-in list Lidless never touches: agent CLIs
   (`claude`, `codex`, `aider`, `gemini`, `cursor-agent`, `node`/`python`
   children of them), terminals, `tmux`/`screen`, `ssh`/`sshd`, `mosh`,
   Tailscale/VPN daemons. User-editable. Any power-saving action skips it.
2. **Command wrapper:** `lidless run -- claude`. Session ends when the command
   exits, with an optional grace period.
3. **Agent-aware status.** Menu bar shows which known agents are running and
   how long the session has left. `lidless status --json` for scripts.
4. **Agent hooks.** If Claude Code / Codex hooks expose a stop/finish event,
   ship a snippet that runs `lidless stop` (or "end in N min") when the agent
   finishes. **Check current hook docs before building.**
5. **Stay online.** Remote control needs a network. First: detect and notify on
   connectivity loss. Later: optional fallback to a saved hotspot (password in
   Keychain, never in config or argv).
6. **Better recovery.** The recovery agent should also enforce the critical
   battery floor and thermal floor, so a crashed app can't leave a closed
   laptop draining or overheating.
7. **Notifications.** Notify on session start, verification failure, floor
   trips, and session end, so a remote user knows what happened.
8. **`lidless doctor`.** Explain clearly why staying awake might fail
   (sudoers missing, recovery not loaded, MDM restrictions, on battery, etc.).
9. **Auto-detect agents (opt-in).** Offer to start a session when a known agent
   is running.

---

## 8. Windows engine (M2 prototype → M3)

Needs a real-hardware prototype first. Likely approach, **unverified**:

- Journal, then set the lid-close action to "Do nothing" (AC + DC) on the
  active scheme via the power-settings APIs (`PowerWriteACValueIndex` /
  `PowerWriteDCValueIndex`) or `powercfg`. Restore from the journal.
- Hold a power request (`PowerCreateRequest` / `PowerSetRequest`) or
  `SetThreadExecutionState`. That alone does **not** stop lid-close sleep.
- Recovery: Task Scheduler job or a small service.
- Crates: `windows`, `windows-service`.

## 9. Linux engine (M6)

- systemd-logind inhibitor with `handle-lid-switch` (+ `sleep`) via `zbus`,
  run as a systemd user service. Do **not** edit `logind.conf` by default.
- CLI + daemon first. Tray later (KDE native, GNOME needs AppIndicator).
- Packaging TBD: AppImage / .deb / .rpm / Flatpak.

---

## 10. Security and privacy

- Journal, config, logs: owner-only (0600 files, 0700 dirs; matching ACLs on
  Windows). Logs may contain network names and process details, so warn before
  sharing.
- Secrets only in the OS credential store.
- No telemetry, no accounts.
- Releases ship with checksums, and ideally build provenance.

## 11. Testing

- Unit tests driven by `spec/` test vectors (durations, session math, floors,
  journal replay).
- A protocol-based **fake for every system call** (`pmset`, IOKit, power APIs,
  D-Bus). Tests use temp dirs only.
- Crash tests: kill mid-session and mid-restore, run recovery, assert originals
  return (against fakes).
- Real-machine checklist before each release, in
  `docs/release-validation.md`: normal end, expiry, force-quit → recovery,
  reboot mid-session, lid close/open, battery + thermal floors,
  install/upgrade/uninstall, `lidless run` exit paths.

---

## 12. Milestones

| # | Milestone | Output |
|---|---|---|
| M0 | Spec | `spec/`: session model, journal schema, CLI contract, test vectors |
| M1 | macOS MVP | Timed session, closed-lid awake with read-back, journal, launchd recovery, battery floor, install/uninstall, CLI, menu bar app |
| M2 | Windows prototype | Findings note answering the Windows open questions, then spec update |
| M3 | Windows core | Rust core + Windows engine, recovery task, installer, CLI parity |
| M4 | Agent features | Protect list, `lidless run`, network warning, hooks, notifications |
| M5 | Cross-platform UI | Tauri tray app on Windows |
| M6 | Linux | Daemon + CLI via logind, then UI + packaging |

(M4 items for macOS may be pulled forward into M1 once the core is stable,
especially `lidless run`.)

## 13. Open questions (test, don't assume)

1. Windows: can the lid action be changed without admin? Behavior on managed or
   corporate machines?
2. Windows: on Modern Standby, are processes throttled with the lid closed even
   when the action is "Do nothing"? Does a power request help?
3. macOS: does the `disablesleep` revert behavior still happen on the current
   release? Re-verify on every macOS release.
4. Claude Code / Codex: which hook events exist, and can one reliably signal
   "agent finished"? Which remote features need an always-on network?
5. Linux: is the `handle-lid-switch` inhibitor consistent across GNOME, KDE,
   others?
6. macOS privilege: when to move from sudoers to a signed `SMAppService`
   helper?
7. Name availability: trademark, domain, GitHub org, Homebrew, crates.io.

---

## 14. Working instructions for Claude

- Start with **M0**. Don't write platform code until the journal schema and CLI
  contract exist in `spec/`.
- Keep changes small and reviewable. One concern per commit.
- Follow the Hard rules (section 3) in every change.
- Never run commands that change real power settings. Use fakes. Hand manual
  checks to the human with exact commands.
- For anything in Open questions, write a small prototype/test and report what
  you observed. Don't guess.
- Keep this file current: update **Status** and **Decision log** as you go.

---

## 15. Status

- [x] Repo created (LICENSE, README stub)
- [x] CLAUDE.md written
- [x] **M0: spec** (`spec/`: session, journal + JSON schema, floors, CLI contract, test vectors)
- [~] **M1: macOS MVP**: code complete, 53 unit tests passing against fakes.
      **Not yet validated on real hardware**: the human runs `macos/scripts/install.sh`
      and the checklist in `docs/release-validation.md`.
  - [x] `LidlessCore`: journal, lock, session owner (engage → read-back → tick → restore),
        floors, recovery policy, readiness, agent detection, network watcher, status
  - [x] `lidless` CLI: start (detached holder), run, extend, stop, status, doctor,
        recover, agents, config, version, `--json` everywhere
  - [x] Menu bar app (SwiftUI `MenuBarExtra`): presets, custom duration, extend,
        stop, setup card, heat notice, settings, login item, notifications
  - [x] `scripts/`: build-app.sh, install.sh (sudoers + LaunchAgent), uninstall.sh, test.sh
  - [~] Real-Mac validation (docs/release-validation.md): install, start + read-back,
        ~9.5 min closed-lid run with no sleep gap and network up, display off, Low Power
        Mode on/off with the lid, stop + full restore, force-quit → orphan → stop, expiry, `run` normal exit and Ctrl-C (exit 130) all passed on 2026-10-13 (macOS 27.0.1,
        MacBook Air). Still to run: extend, `run` failure code, app Quit, unattended orphan expiry,
        holder kill, reboot, floors, revert detection, uninstall.
  - [ ] App icon, Developer ID signing + notarization
- [ ] M2–M6

### macOS code map

| File (macos/Sources/LidlessCore) | Role |
|---|---|
| `SessionOwner.swift` | The owner: start/verify/tick/floors/lid/re-verify/end. `@MainActor`. |
| `JournaledChanges.swift` | Every pmset change and restore (Hard rules 1 and 4). |
| `Recovery.swift` | Pure `RecoveryPolicy` + `Recovery.run` (launchd job, stop-orphan, app launch). |
| `SessionControl.swift` | Non-owner extend/stop via session.json under the lock. |
| `PowerControl.swift` | `pmset` wrapper + parsers; the 4 allowed privileged commands. |
| `Readiness.swift` | Hard rule 2 (sudoers + LaunchAgent checks). |
| `Store.swift`, `OwnerOnlyFile.swift`, `FileLock.swift`, `Paths.swift` | State files, atomic 0600 writes, flock. |
| `Sensors.swift`, `FloorRules.swift` | Battery/thermal/lid readings and the pure floor decision. |

### Toolchain gotchas (Command Line Tools, no Xcode)

- There is no `SwiftUIMacros` plugin, so **`@State` cannot be used** in views. Keep
  view state on the `@Observable` `AppModel` instead. `@Observable` works.
- The Swift Testing macro plugin fails at random under parallel builds
  ("plugin for module 'TestingMacros' not found"). Use `macos/scripts/test.sh`,
  which retries the build. `@Suite` is avoided for the same reason.
- `pmset -g` on macOS 27 omits the `SleepDisabled` line when it has never been
  changed, and prints `SleepDisabled 0` once it has. The parser treats "absent" as 0.

## 16. Decision log

| Date | Decision |
|---|---|
| 2026-10-13 | macOS first (Swift 6 / SwiftUI / SwiftPM), then Windows (Rust), then Linux (Rust). |
| 2026-10-13 | Sessions always timed; default max 30 days. |
| 2026-10-13 | macOS MVP privilege via a narrow sudoers rule; signed helper later. |
| 2026-10-13 | macOS: use `pmset disablesleep` *plus* an IOPM assertion during sessions. |
| 2026-10-13 | Recovery agent will also enforce critical battery/thermal floors. |
| 2026-10-13 | Owner model: exactly one owner process per session (app, detached `lidless start` holder, or `lidless run`). Others edit session.json; nobody signals the owner. |
| 2026-10-13 | Owner crash with time left: stay awake until `endsAt` (agent may still be working), recovery enforces floors. Reboot: restore at once. |
| 2026-10-13 | Low Power Mode is battery-profile only (`pmset -b`); all low-power requests apply on battery only. |
| 2026-10-13 | Display off on lid close via `pmset displaysleepnow` (public, unprivileged); no private brightness frameworks. Audio mute and keyboard backlight left out of the MVP. |
| 2026-10-13 | Lid state is polled once per second from `IOPMrootDomain`/`AppleClamshellState` with a 2-tick debounce instead of an IOKit notification. |
| 2026-10-13 | The recovery job is the `lidless recover` binary itself (shared Swift code), not a separate shell script. |
| 2026-10-13 | macOS minimum 14 (MenuBarExtra + Observation). |
