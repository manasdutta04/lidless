<p align="center"><img src="public/lidless-icon.png" width="128" alt="Lidless icon"></p>

<h1 align="center">Lidless</h1>

<p align="center"><strong>Close the lid. Your agent keeps working.</strong></p>

<p align="center">
  <a href="https://github.com/manasdutta04/lidless/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/manasdutta04/lidless?label=release&color=2f5640"></a>
  <a href="https://github.com/manasdutta04/lidless/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/manasdutta04/lidless/total?color=2f5640"></a>
  <a href="https://github.com/manasdutta04/lidless/actions/workflows/ci.yml"><img alt="macOS CI" src="https://img.shields.io/github/actions/workflow/status/manasdutta04/lidless/ci.yml?label=macOS"></a>
  <a href="https://github.com/manasdutta04/lidless/actions/workflows/rust.yml"><img alt="Windows and Linux CI" src="https://img.shields.io/github/actions/workflow/status/manasdutta04/lidless/rust.yml?label=Windows%20%2B%20Linux"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-2f5640"></a>
</p>

<p align="center">
  <a href="https://github.com/manasdutta04/lidless/releases/latest"><img alt="Download for macOS" src="https://img.shields.io/badge/macOS_14+-Download_.dmg-141a16?logo=apple&logoColor=white"></a>
  <a href="https://github.com/manasdutta04/lidless/releases/latest"><img alt="Download for Windows" src="https://img.shields.io/badge/Windows_10%2F11-Download_.msi-141a16?logo=windows&logoColor=white"></a>
  <a href="https://github.com/manasdutta04/lidless/releases/latest"><img alt="Download for Linux" src="https://img.shields.io/badge/Linux-AppImage_%2F_.deb-141a16?logo=linux&logoColor=white"></a>
</p>

<p align="center">
  <a href="https://lidless.app">Website</a> ·
  <a href="https://lidless.app/docs">Docs &amp; help</a> ·
  <a href="https://github.com/manasdutta04/lidless/releases">Releases</a> ·
  <a href="https://github.com/manasdutta04/lidless/issues/new">Report an issue</a>
</p>

---

## What it is

Lidless is a small menu bar / tray app and a command-line tool that keeps your
laptop **awake, with everything still running, after you close the lid**, for
exactly as long as you choose. When the time is up, or the command you wrapped
finishes, it puts every setting back the way it was.

It is not a power manager and it has no "awake forever" switch. It does one
thing, checks that it worked, and cleans up after itself.

## What it solves

Coding agents such as **Claude Code** and **Codex** now run for hours. You
start one, want to walk away, and close the lid. On every laptop that means
sleep: the agent freezes, your SSH session drops, remote control from your
phone stops answering.

The usual fixes are blunt. "Never sleep" leaves the machine running until you
remember to switch it back. Caffeine-style utilities keep the display on with
the lid open. Editing power settings by hand is easy to forget and easy to get
wrong on battery.

Lidless gives you the one behaviour you want (**lid closed, agent running,
reachable from your phone**) with the safety you'd add yourself if you had
time: a timer, a battery floor, a heat floor, and a guaranteed restore.

## What it does

1. **Journals** the original value of each setting it is about to change,
   writing it to disk before touching anything.
2. **Engages** closed-lid awake mode for the OS you are on (`pmset
   disablesleep` on macOS, the lid-close power action on Windows, a logind
   inhibitor on Linux) and holds a system-level "stay awake" request.
3. **Verifies** by reading the setting back 5 seconds later, and again every
   minute. If the OS reverts it, Lidless restores, ends the session and tells
   you, instead of claiming success.
4. **Watches** the battery, temperature, lid and network for the whole
   session, and applies the floors.
5. **Restores** everything when the timer ends, when you stop, when the wrapped
   command exits, when you quit the app, after a crash, and after a reboot.

## Features

- **Always timed.** 30 minutes to 30 days, never "forever". Extend from the
  panel or with `lidless extend 1h`.
- **Wrap your agent.** `lidless run -- claude` stays awake exactly as long as
  the command runs, then restores. Exit codes pass through, Ctrl‑C included.
- **Verified, not assumed.** Every change is read back and re-checked every
  60 seconds.
- **Safe on battery.** Low Power Mode below 40 %, session ends below 10 %,
  refuses to start when the machine is critically hot. All configurable.
- **Crash-proof restore.** A tiny background job (LaunchAgent, Task Scheduler
  or systemd user timer) runs every minute and at login, reads only the
  journal, and undoes anything left behind, even if the app is gone.
- **Agent aware.** Shows which coding agents are running (Claude Code, Codex,
  Gemini CLI, Aider, Cursor Agent, Copilot CLI and more). Read-only; it never
  signals a process.
- **Stays reachable.** Warns the moment the network drops, so remote control
  and SSH keep working.
- **Closed-lid power saving.** Display off and Low Power Mode on battery while
  the lid is closed, reversed when you open it.
- **Menu bar panel and a desktop window.** Quick start/extend/stop from the
  menu bar; stats, a 12‑week activity heatmap, history, settings and updates
  in the window.
- **A real CLI.** Everything the app can do, with `--json` output so your
  agents can script it.
- **Nothing leaves your machine.** No accounts, no telemetry. State lives in
  one owner-only folder.
- **Open source, MIT.** Swift on macOS, Rust on Windows and Linux, one shared
  behaviour spec in [`spec/`](spec/).

> **⚠️ Heat:** with the lid closed your laptop keeps running and can get warm.
> Leave it on a hard, ventilated surface. **Never run it in a bag or sleeve.**
> Lidless asks you to confirm this before your first session and again whenever
> the machine is already warm, and refuses to start while it is critically hot.

## How to use it

1. **Install** Lidless (below) and click **Set Up…** once. That installs the
   narrow permission it needs and the recovery job.
2. **Start your agent** in a terminal. For remote control from a phone, start
   it inside `tmux` so a dropped connection does not end it.
3. **Pick a duration** in the menu bar panel, or run
   `lidless start 4h` / `lidless run -- claude`.
4. **Close the lid.** The display turns off, the machine stays awake and on
   the network. Reach it with Claude Code / Codex remote control, SSH,
   VS Code Remote‑SSH or Cursor.
5. **Done?** Open the lid, or let the timer end, or run `lidless stop`. Normal
   sleep behaviour comes back immediately.

```bash
lidless start 2h              # stay awake for 2 hours (also 90m, 1d2h, "1h 30m")
lidless run -- claude         # stay awake while claude runs, then restore
lidless run -d 8h -- codex    # same, but never longer than 8 hours
lidless extend 1h             # add time
lidless status                # what is going on (add --json for scripts)
lidless stop                  # end now and restore normal sleep
lidless doctor                # check setup
lidless agents                # list detected coding agents
lidless stats                 # your usage: time awake, closed-lid time, sessions
lidless update                # check for a newer release
lidless config                # show settings; `lidless config endBelowPercent 15` to change
lidless setup                 # one-time setup (same as the Set Up button)
lidless uninstall             # restore and remove the permission and helper
```

`lidless start` hands the session to a small background process, so you can
close the terminal. `lidless run` keeps the session in the foreground and ends
it when your command exits.

## Where it works

| Platform | Status | How it stays awake |
|---|---|---|
| **macOS 14+** (Apple silicon and Intel) | Validated on real hardware | `pmset disablesleep` via a four-command sudoers rule, plus an IOPM assertion |
| **Windows 10 / 11** (x64) | Built and CI-tested; not yet validated on a real laptop | Lid-close action set to *Do nothing* (journaled) plus a power request |
| **Linux** (systemd, x64 and arm64) | Built and CI-tested; not yet validated on a real laptop | logind inhibitor for `handle-lid-switch`, `sleep`, `idle` |

Same commands, same panel, same window everywhere. Windows and Linux test
checklist: [docs/windows-linux-validation.md](docs/windows-linux-validation.md).

Works with anything that keeps running in a terminal: Claude Code, OpenAI
Codex, Gemini CLI, Aider, Cursor Agent, Copilot CLI, builds, model training,
downloads, Jupyter, Ollama. Remote access: SSH + tmux, Tailscale, VS Code
Remote‑SSH, Cursor, screen sharing.

## Install

### macOS

1. Download **Lidless-x.y.z.dmg** from the
   [latest release](https://github.com/manasdutta04/lidless/releases/latest)
   and drag **Lidless** into **Applications**.
2. Lidless is not notarized by Apple yet, so run this **once**:

   ```bash
   xattr -cr /Applications/Lidless.app
   ```

   (Or right-click the app, choose **Open**, and confirm.)
3. Open **Lidless**, click **Set Up…** and enter your password once. That
   installs permission for [four exact `pmset` commands](#privileged-operations)
   and the recovery job, and links the `lidless` command to
   `~/.local/bin/lidless`.

Sessions start from the **menu bar panel**. Opening Lidless from the Dock (or
⌘,) shows the window: Overview, History, Settings, Setup, About & Updates. The
window can stop a session but never starts one. Closing the window keeps
Lidless running; **Quit** always ends the session and restores your settings.

From the command line: `/Applications/Lidless.app/Contents/Helpers/lidless setup`.

Build from source (Swift 6: Xcode or `xcode-select --install`):

```bash
git clone https://github.com/manasdutta04/lidless.git
cd lidless
./macos/scripts/install.sh
```

Uninstall: Settings → **Uninstall…** (or `lidless uninstall`), then trash the
app. From a checkout, `./macos/scripts/uninstall.sh` (`--purge` also deletes
logs and state).

### Windows

1. Download **Lidless-x.y.z-windows-x64.msi** from the
   [latest release](https://github.com/manasdutta04/lidless/releases/latest)
   and run it. SmartScreen may warn because it is not code-signed yet: choose
   **More info → Run anyway**.
2. Open **Lidless** (in the tray). Click **Set Up…** and approve the one UAC
   prompt. That registers the recovery tasks and, only if your account cannot
   change power plans directly, one elevated task that applies the lid-close
   action. See [Privileged operations](#privileged-operations).

From source (Rust installed): `rust\scripts\install.ps1` in PowerShell.

### Linux

1. Download **Lidless-x.y.z-linux-x64.AppImage** (or `.deb`, or the arm64
   variant) from the
   [latest release](https://github.com/manasdutta04/lidless/releases/latest).
   `chmod +x` the AppImage and run it.
2. Open **Lidless** (tray icon; GNOME needs the AppIndicator extension). Click
   **Set Up…**. Nothing runs as root: it installs a systemd user timer that
   runs `lidless recover` every minute.

On battery with the lid closed, the power profile is switched to *power-saver*
(journaled and restored). Desktops that handle the lid themselves may ignore
the inhibitor; that is the first thing the validation checklist tests.

From source (Rust installed): `./rust/scripts/install.sh`.

## Help

Something not working? Read [docs/HELP.md](docs/HELP.md), also published at
[lidless.app/docs](https://lidless.app/docs): install problems, "it still
slept", reaching the laptop remotely, recovery after a crash, where the files
are, and what to include in a bug report. In the app: **Help → Lidless Help**.

## What happens when the lid closes

- The machine stays awake: processes, network and SSH keep running.
- The display is turned off.
- On battery, Low Power Mode (macOS) / power-saver (Linux) is switched on,
  only if it was off, and switched back when the lid opens or you plug in.
- If the network drops, you get a notification.
- On Apple silicon and T2 Macs, closing the lid disconnects the built-in
  microphone in hardware. Voice tools need an external mic.

## When a session ends

| Trigger | Default |
|---|---|
| Time runs out | always |
| You stop it, or quit the app that started it | always |
| `lidless run` command exits | always |
| Battery below 10 % (on battery) | `endBelowPercent`, 0 turns it off |
| Battery level unreadable twice in a row (on battery) | always |
| Critical thermal state | `thermalRules` |
| The OS turns closed-lid sleep back on and re-applying fails | always |
| The machine restarts | always |

Low Power Mode is requested on battery below 40 % (`lowPowerBelowPercent`),
on serious thermal state, and while the lid is closed (`lowPowerOnLidClose`).

## How recovery works

Before Lidless changes a setting, it writes the original value to
`journal.json` in its state folder. Restoring only ever writes back a journaled
original, never a guess.

The recovery job runs `lidless recover` every minute and at login. It needs
only the state folder, not the app. It:

- does nothing while the process that owns the session is alive;
- if that process died (crash, force-quit): keeps the machine awake until the
  session's end time so your agent can keep working, **and still enforces the
  battery and thermal floors**, then restores;
- after a restart: restores at once;
- retries every minute if a restore fails, and keeps the journal until it
  succeeds;
- moves an unreadable session file aside (never deletes it) and restores.

`lidless status` and the menu show anything still waiting to be restored.

## Privileged operations

### macOS

Lidless runs exactly these commands as root, through `sudo -n`, allowed by
`/etc/sudoers.d/lidless` for your user only. Setup writes that file from
fixed text, checks it with `visudo`, and installs it as `root:wheel 0440`:

```
/usr/bin/pmset -a disablesleep 1    # keep running with the lid closed
/usr/bin/pmset -a disablesleep 0    # restore
/usr/bin/pmset -b lowpowermode 1    # battery Low Power Mode on
/usr/bin/pmset -b lowpowermode 0    # restore
```

Nothing else runs elevated. Unprivileged commands it uses: `pmset -g`,
`pmset -g custom` (read settings), `pmset displaysleepnow` (display off),
`launchctl print` (check the recovery agent).

Known limitation: any process running as your user can also run those four
commands without a password. They can only toggle sleep and Low Power Mode. A
signed privileged helper will replace the sudoers rule in a later release.

### Windows

Nothing runs elevated during a session. Setup registers, with one UAC
approval, the Task Scheduler task `Lidless\LidAction` (highest privileges)
which does exactly one thing: apply the lid-close action values from a request
file Lidless wrote. It is only registered when your account cannot change
power settings directly. Recovery tasks run as you.

### Linux

Nothing. The logind inhibitor and the systemd user timer run as your user.

## Privacy and files

Everything stays on your machine. No telemetry, no accounts. The only network
request is the update check: a plain GET of this repository's latest release
on GitHub, once a day (turn it off in About & Updates). Updates are never
installed silently: **Download** saves the new installer to Downloads and
opens it.

State lives in `~/Library/Application Support/Lidless/` (macOS),
`%LOCALAPPDATA%\Lidless\` (Windows) or `~/.local/state/lidless/` (Linux);
folder `0700`, files `0600`: `session.json`, `journal.json`, `config.json`,
`last-end.json`, `history.json`, `lidless.log`. The log can contain process
names. Check it before sharing.

## Development

Rust (Windows and Linux; the shared core also runs on macOS for tests):

```bash
cd rust
cargo test -p lidless-core          # core against spec/vectors, fakes only
cargo build -p lidless --release    # the CLI for this platform
cd app && npx tauri build           # the tray app (see rust/app/README.md)
```

macOS:

```bash
cd macos
./scripts/test.sh             # unit tests (fakes only, never touch real settings)
swift build                   # debug build of the CLI and the app
./scripts/build-app.sh        # dist/Lidless.app, ad-hoc signed, not installed
./scripts/package-release.sh  # universal DMG + zip + SHA256SUMS in dist/
swift scripts/make-icon.swift # rebuild all icons from public/lidless-icon.png
```

Releases: bump `Sources/LidlessCore/Version.swift` and `rust/Cargo.toml`, then
push a tag `vX.Y.Z`. GitHub Actions tests, builds every platform and publishes
the release.

The behaviour contract shared by every platform lives in [`spec/`](spec/); the
Swift and Rust test suites both load `spec/vectors`. Real-machine checks before
a release: [`docs/release-validation.md`](docs/release-validation.md).

## License

[MIT](LICENSE)
