# Lidless

Close the lid. Your agent keeps working.

Lidless keeps your laptop awake, with everything still running, **after you
close the lid**, for as long as you choose. Start Claude Code, Codex or any
other long-running coding agent, close the lid, and keep reaching it through
remote control or SSH. When the time is up, or the agent finishes, Lidless puts
every setting back the way it was.

- **Always timed.** Sessions run for a duration you pick (up to 30 days),
  never "forever".
- **Wrap your agent:** `lidless run -- claude` keeps the Mac awake exactly as
  long as the command runs.
- **Safe by default.** Battery and temperature floors end the session before
  harm. Every change is journaled *before* it is made, and a recovery agent
  undoes it after a crash, a force-quit or a reboot.
- **Verified, not assumed.** After engaging, Lidless reads the setting back
  and re-checks it every minute. If macOS reverts it, you are told.
- **Menu bar app + CLI**, both with the same features. Every command has
  `--json` output for scripts and agents.

> **⚠️ Heat:** with the lid closed your laptop keeps running and can get warm.
> Leave it on a hard, ventilated surface. **Never run it in a bag or sleeve.**

Platforms: **macOS 14+** today. Windows and Linux are planned.

---

## Install (macOS)

Requirements: macOS 14 or later, and Swift 6 (Xcode or the Command Line Tools:
`xcode-select --install`).

```bash
git clone https://github.com/manasdutta04/lidless.git
cd lidless
./macos/scripts/install.sh
```

The installer:

1. builds `Lidless.app` and copies it to `~/Applications`,
2. links the CLI to `~/.local/bin/lidless`,
3. installs a narrow sudoers rule (asks for your password once, see
   [Privileged commands](#privileged-commands)),
4. installs the recovery agent (a per-user LaunchAgent), and
5. runs `lidless doctor` to confirm everything works.

Open **Lidless** from `~/Applications`. It lives in the menu bar (moon icon
when idle, sun and countdown while awake).

To uninstall (restores settings first, then removes everything):

```bash
./macos/scripts/uninstall.sh          # keep logs and state
./macos/scripts/uninstall.sh --purge  # remove those too
```

## Use

```bash
lidless start 2h              # stay awake for 2 hours (also 90m, 1d2h, "1h 30m")
lidless run -- claude         # stay awake while claude runs, then restore
lidless run -d 8h -- codex    # same, but never longer than 8 hours
lidless extend 1h             # add time
lidless status                # what is going on (add --json for scripts)
lidless stop                  # end now and restore normal sleep
lidless doctor                # check setup
lidless agents                # list detected coding agents
lidless config                # show settings; `lidless config endBelowPercent 15` to change
```

`lidless start` hands the session to a small background process, so you can
close the terminal. `lidless run` keeps the session in the foreground and ends
it when your command exits, including on failure or Ctrl-C. The exit code is
your command's.

### What happens when the lid closes

- The Mac stays awake: processes, network and SSH keep running.
- The display is turned off.
- On battery, Low Power Mode is switched on (only if it was off, and switched
  back off when the lid opens or you plug in).
- If the network drops, you get a notification (remote control needs it).
- On Apple silicon and T2 Macs, closing the lid disconnects the built-in
  microphone in hardware. Voice tools need an external mic.

### When a session ends

| Trigger | Default |
|---|---|
| Time runs out | always |
| You stop it, or quit the app that started it | always |
| `lidless run` command exits | always |
| Battery below 10% (on battery) | `endBelowPercent`, 0 turns it off |
| Battery level unreadable twice in a row (on battery) | always |
| Critical thermal state | `thermalRules` |
| macOS turns closed-lid sleep back on and re-applying fails | always |
| The Mac restarts | always |

Low Power Mode is requested on battery below 40% (`lowPowerBelowPercent`),
on serious thermal state, and while the lid is closed (`lowPowerOnLidClose`).

## How recovery works

Before Lidless changes a setting, it writes the original value to a journal in
`~/Library/Application Support/Lidless/journal.json`. Restoring only ever writes
back a journaled original, never a guess.

A LaunchAgent runs `lidless recover` every minute and at login. It needs only
that state folder, not the app. It:

- does nothing while the process that owns the session is alive;
- if that process died (crash, force-quit): keeps the Mac awake until the
  session's end time so your agent can keep working, **and still enforces the
  battery and thermal floors**, then restores;
- after a restart: restores at once;
- retries every minute if a restore fails, and keeps the journal until it
  succeeds;
- moves an unreadable session file aside (never deletes it) and restores.

`lidless status` and the menu show anything still waiting to be restored.

## Privileged commands

Lidless runs exactly these commands as root, through `sudo -n`, allowed by
`/etc/sudoers.d/lidless` for your user only:

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

## Privacy and files

Everything stays on your Mac. No telemetry, no accounts. State lives in
`~/Library/Application Support/Lidless/` (folder `0700`, files `0600`):
`session.json`, `journal.json`, `config.json`, `last-end.json`, `lidless.log`.
The log can contain process names. Check it before sharing.

## Development

```bash
cd macos
./scripts/test.sh         # unit tests (fakes only, never touch real settings)
swift build               # debug build of the CLI and the app
./scripts/build-app.sh    # dist/Lidless.app, ad-hoc signed, not installed
```

The behavior contract shared by every platform lives in [`spec/`](spec/).
Real-machine checks before a release: [`docs/release-validation.md`](docs/release-validation.md).

## License

[MIT](LICENSE)
