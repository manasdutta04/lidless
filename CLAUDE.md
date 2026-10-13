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
- **Windows/Linux UI:** Tauri 2 tray app in `rust/app` (vanilla HTML/CSS/JS
  frontend, same design language as the macOS app).
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
  - [x] App icon from the master artwork `public/lidless-icon.png` (`macos/scripts/make-icon.swift`
        builds AppIcon.icns, AppIcon-1024.png and LidlessMark.png from it), animated template
        menu bar glyph, own rounded panel (`StatusPanel.swift`: NSStatusItem + borderless
        NSPanel, continuous corners on all sides, sized from the content via
        `onGeometryChange`, top-anchored), desktop Settings window (`SettingsWindow.swift`),
        Dock icon (optional) with standard app menu
  - [x] In-app **Set Up…** (admin password dialog) and `lidless setup` / `lidless uninstall`
  - [x] Release pipeline: `package-release.sh` (universal DMG + zip + SHA256SUMS),
        `.github/workflows/ci.yml` and `release.yml` (tag `vX.Y.Z`)
  - [x] **v0.1.0 released 2026-10-13** (DMG + zip + checksums via the Release workflow).
  - [ ] Developer ID signing + notarization (needs a paid Apple account). Until then
        users run `xattr -cr /Applications/Lidless.app` once.
- [x] **M2/M3/M6 code: Rust workspace `rust/`** (2026-10-13), compile-checked for
      x86_64-pc-windows-msvc, x86_64/aarch64-unknown-linux-gnu; core tested on macOS.
  - [x] `rust/core` (`lidless-core`): durations, models (JSON identical to the Swift
        app), store + lock, floors, history + stats, recovery, session owner, control,
        status, agents, update check, CLI. 24 tests incl. the shared `spec/vectors`.
  - [x] `rust/windows`: lid-close action via Power API (journaled, read back), elevated
        Task Scheduler fallback (`Lidless\LidAction`), power request hold, lid state via
        power-setting notifications, battery via `GetSystemPowerStatus`, recovery tasks.
  - [x] `rust/linux`: logind inhibitor hold (verified via `ListInhibitors`), power-profiles
        journaled switch, sysfs battery/thermal/lid, systemd user timer recovery.
  - [x] `rust/cli`: `lidless` binary, same commands/exit codes as macOS.
  - [x] `rust/app`: Tauri 2 tray app (panel + window, same design) — see rust/app/README.md.
  - [x] CI `.github/workflows/rust.yml`; release `.github/workflows/release-windows-linux.yml`
        (MSI/NSIS, AppImage/.deb, CLI archives, attached to the same `vX.Y.Z` release).
  - [x] **v0.1.0 released 2026-10-13**: GitHub Actions built the Tauri app and CLI natively on
        Windows x64, Linux x64 and Linux arm64 (first native compile of the engines) and
        attached MSI/NSIS, AppImage/.deb and CLI archives beside the macOS DMG.
  - [ ] **Not validated on real Windows/Linux hardware.** Checklist and the open
        questions to answer: `docs/windows-linux-validation.md`.
- [ ] M4 remainder (agent hooks), M5 polish

### Rust code map

| Crate / file | Role |
|---|---|
| `core/src/engine.rs` | `Engine` trait every platform implements; `AwakeHold` (released on drop/crash). |
| `core/src/owner.rs` | `SessionOwner`: start → engage → settle → verify → tick loop (floors every 15 s, re-verify every 60 s, lid debounce 2) → end. Blocking, one thread. |
| `core/src/recovery.rs`, `control.rs`, `status.rs`, `history.rs` | Same semantics as the Swift files of the same names. |
| `core/src/cli.rs` | All CLI commands; platform binaries call `cli::run(engine, args)`. `start` spawns a detached `_hold` process. |
| `core/src/testing.rs` | `FakeEngine`, fakes for tests and the app's macOS preview. |
| `windows/src/{power,lid,tasks}.rs` | Win32 bindings (`windows` 0.58), lid watcher thread, `schtasks` integration. |
| `linux/src/{lib,sensors,systemd}.rs` | zbus logind/power-profiles, sysfs sensors, user timer. |

Rust gotchas: the Tauri app cannot be cross-checked for Windows/Linux from macOS
(`tauri-winres` needs a Windows resource compiler; Linux needs gtk/webkit via
pkg-config), so only CI's native runners compile `lidless-app` with the real engines;
the engine crates and the CLI *can* be cross-checked. `lidless-core` default feature `updates` pulls `ureq`/`ring` (C code);
cross-target `cargo check` from macOS needs `--no-default-features` on the CLI or
checking the engine crates directly (they depend on core without defaults). Some
`powrprof` functions in `windows` 0.58 return `WIN32_ERROR`, others bare `u32`
(see `Win32Code` in `power.rs`). The constants `GUID_LIDCLOSE_ACTION`,
`GUID_SYSTEM_BUTTON_SUBGROUP`, `GUID_LIDSWITCH_STATE_CHANGE` live in
`Win32::System::SystemServices`.

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

- The app uses a plain AppKit lifecycle (`Sources/LidlessApp/main.swift`), not a SwiftUI `App`.
- There is no `SwiftUIMacros` plugin, so **`@State` cannot be used** in views. Keep
  view state on the `@Observable` `AppModel` instead. `@Observable` works.
- The Swift Testing macro plugin fails at random under parallel builds
  ("plugin for module 'TestingMacros' not found"). Use `macos/scripts/test.sh`,
  which retries the build. `@Suite` is avoided for the same reason.
- `@Environment` works in views (it is not a macro); `@State` does not.
- On macOS 26+ the Finder/Dock icon follows the user's icon style (Clear/Tinted can
  render it monochrome). In-app branding uses the bundled full-colour
  `Resources/LidlessMark.png`, not `NSApp.applicationIconImage`.
- `swift build --arch arm64 --arch x86_64` works with the CLT and outputs to
  `.build/out/Products/<Config>`; `build-app.sh` reads `--show-bin-path`.
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
| 2026-10-13 | Distribution: unsigned (ad-hoc) universal DMG + zip on GitHub Releases; users run `xattr -cr` once. Setup moved into the app ("Set Up…") and `lidless setup`; `install.sh` is now build-from-source only. |
| 2026-10-13 | The sudoers file is written by the root script itself from fixed text (no user-writable temp file), validated with `visudo -cf`, installed `0440 root:wheel`. |
| 2026-10-13 | Visual language (Claude-like): warm ivory `#FAF9F5` / warm charcoal `#262624` solid panel, white / `#30302E` cards with 1 px borders, one terracotta accent (`#C96442` light, `#D97757` dark). Type: New York serif (`Theme.display`) for headlines and the countdown, SF for UI. Thin monochrome SF Symbols, outlined secondary buttons, solid primary. Flat: **no gradients, no blur/scale effects, no implicit layout animation**. Colours live only in `Theme.swift` (adaptive light/dark). Anthropic's own typefaces are proprietary and are not bundled. |
| 2026-10-13 | Replaced SwiftUI `MenuBarExtra` with `NSStatusItem` + our own borderless `NSPanel` (material background clipped to a continuous rounded rect). `MenuBarExtra`'s window had square bottom corners and resized from the wrong anchor, making content drift. |
| 2026-10-13 | Brand: `public/lidless-icon.png` (open laptop forming an "L") is the master for every icon. The menu bar template glyph redraws the same "L" in code; while awake, two signal arcs pulse from inside it. |
| 2026-10-13 | Heat warning (Hard rule 9) is a start checkpoint, not a dismissible card: confirmation before the first session ever and before every start while thermal ≥ `fair`; start refused at `critical` (enforced in `SessionOwner`, so CLI too); a ventilation line is always visible on the start screen; CLI prints the warning when warm. |
| 2026-10-13 | Desktop window: opens at 1000×680, resizable and zoomable up to the screen (full screen allowed) but never smaller than 1000×680 (`contentMinSize`/`minSize` plus `windowWillResize` clamp; capped to the screen if it is smaller). Content centred at max 980 pt wide. Overview leads with a featured tip banner (solid deep surface, serif headline, action button, Next tip, paging dots, auto-advance every 12 s, icon cluster on the right edge; context-aware tips first). Sidebar with Overview (read-only: greeting, live status, 6 stat tiles, 12-week heatmap, week chart, hour-of-day chart, context-aware tips), History, Settings, Setup, About & Updates. **Sessions start only from the menu bar panel**; the window, main menu and Dock menu can open the panel or stop a session, never start one. Main menu: Lidless, Session (Open Menu Bar Panel ⇧⌘L, Stop ⌘.), Edit, View (⌥⌘1–5 pages), Window, Help. |
| 2026-10-13 | Session history (`history.json`, ≤1000 entries) is appended by the owner (with closed-lid seconds) and by recovery; on first read it is backfilled from `lidless.log`. `UsageStats` powers the Overview and `lidless stats`. |
| 2026-10-13 | Updates: `UpdateChecker` GETs the GitHub latest-release API (daily if `checkForUpdates`, or on demand); Download saves the DMG to ~/Downloads via URLSession (no quarantine flag, so no xattr needed) and opens it. Never installs silently. `lidless update` reports the same. |
| 2026-10-13 | Rust engine contract: `engage()` journals + changes and returns an `AwakeHold`; the owner verifies after the settle delay. Windows: lid action "Do nothing" (journaled) + `PowerRequestSystemRequired`; thermal unknown → nominal; Battery saver untouched. Linux: logind `handle-lid-switch:sleep:idle` block inhibitor (not journaled, kernel-released) + journaled power-profile switch; thermal from the hottest `thermal_zone` at 75/85/95 °C. |
| 2026-10-13 | Windows elevation: no sudoers equivalent, so setup registers (one UAC prompt) a highest-privilege Task Scheduler task that applies lid-action values from a request file; used only when the direct Power API write is refused. Same trade-off as the macOS sudoers rule, documented in the README. |
| 2026-10-13 | Recovery jobs: Windows `schtasks` MINUTE + ONLOGON tasks; Linux systemd user timer `lidless-recover.timer`. Both run `lidless recover` as the user. |
| 2026-10-13 | Release workflows: the macOS workflow creates the GitHub release on a `vX.Y.Z` tag; the Windows/Linux workflow waits for it and uploads its assets, and also accepts `workflow_dispatch` with a `tag` input so a fixed workflow can rebuild an existing tag without moving it. Clippy lints that only trigger on native targets are caught with `cargo clippy -p <engine> --target <triple>` from macOS. |
| 2026-10-13 | App shows in the Dock by default (`showInDock`). The menu bar panel holds quick controls only. Dock click, launching from Finder/Launchpad, ⌘, and the panel's Settings button open the desktop Settings window; a login-item launch stays in the menu bar. Closing the window never quits; Quit always ends the session first. |
| 2026-10-13 | Panel sizing: the content keeps its natural height (`fixedSize`), reports it via `onGeometryChange` on every change (also while open), and is pinned to the top of the window, so it is never centred or clipped at the top. `open()` forces a synchronous layout first so the panel opens at the right size. The window resizes with its top edge fixed. Verified live with the DEBUG `LIDLESS_PANEL_CHECK` run (open → busy → idle → taller → shorter → reopen). Earlier attempts (GeometryReader-only, `invalidateIntrinsicContentSize`) missed changes and clipped or gapped the panel. |
| 2026-10-13 | Landing site (private submodule `landing/`, https://lidless.manasdutta.com): Vite + React 19 + TypeScript + Framer Motion, plain CSS, static `dist/` on Vercel. `/docs` mirrors `docs/HELP.md`; both desktop apps' Help opens it. |
