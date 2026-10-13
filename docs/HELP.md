# Lidless help

Something not working? Start here. Every answer below is also at
[lidless.app/docs](https://lidless.app/docs). If none of it helps,
[open an issue](https://github.com/manasdutta04/lidless/issues/new) with the
output of `lidless doctor` and the last lines of your log (see
[Where things live](#where-things-live)).

## First check: `lidless doctor`

```bash
lidless doctor
```

It prints one line per requirement (sleep permission, recovery helper, journal,
current power state) and says exactly what is missing. The same information is
on the **Setup** page of the app window. Run `lidless doctor --json` if you want
to script it.

If `lidless` is "command not found", use the copy inside the app:

| OS | Command |
|---|---|
| macOS | `/Applications/Lidless.app/Contents/Helpers/lidless doctor` |
| Windows | `lidless.exe doctor` from the folder Lidless was installed to (the CLI sits next to the app) |
| Linux | `lidless doctor` (installed next to the app) |

Setup links the command for you (`~/.local/bin/lidless` on macOS/Linux); open a
new terminal afterwards.

## Install and first launch

### macOS says the app "is damaged" or "cannot be opened"

Lidless is free and open source and is not notarized by Apple yet, so macOS
blocks it on first launch. Run once:

```bash
xattr -cr /Applications/Lidless.app
```

Or right-click the app → **Open** → **Open**. You only need this once per
download.

### Set Up asks for my password. Why?

Keeping a Mac awake with the lid closed needs one system setting
(`pmset disablesleep`) that only root can change. Setup installs a sudoers rule
allowing **exactly four** commands, nothing else:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -b lowpowermode 1
/usr/bin/pmset -b lowpowermode 0
```

It also installs a LaunchAgent that runs `lidless recover` every minute so your
settings come back after a crash or reboot. Remove both any time with
**Settings → Uninstall…** or `lidless uninstall`.

On **Windows** the one UAC prompt registers Task Scheduler tasks (recovery, and
a single elevated task that applies the lid-close action if your account cannot
change power plans directly). On **Linux** nothing runs as root.

### Setup finished but doctor still says "not ready"

- macOS: `sudo -n /usr/bin/pmset -g` must run without a password prompt. If it
  asks, the sudoers file was not installed; run Setup again. If your Mac is
  managed (MDM), a policy may forbid `sudoers.d` drop-ins. Ask your admin, or
  run sessions from a terminal where you can `sudo` yourself.
- macOS: `launchctl print gui/$(id -u)/io.github.manasdutta04.lidless.recovery` should list the
  agent. If not, log out and in, or run Setup again.
- Windows: open Task Scheduler and look for the `Lidless` folder. Corporate
  policies can block user tasks.
- Linux: `systemctl --user status lidless-recover.timer` must be active. Your
  session needs a user systemd instance (most desktops have one).

## Starting a session

### "Not ready" or "recovery not armed"

A session never starts unless the recovery helper is installed and verified.
Run Setup (or `lidless setup`), then `lidless doctor`.

### "Refused: the computer is critically hot"

Lidless will not start while the OS reports a critical thermal state. Let the
laptop cool on a hard, open surface. Once it is back to normal, start again.
This is deliberate: a closed laptop cannot shed heat.

### The ventilation warning keeps appearing

It shows before your first session ever, and again before any start while the
machine is already warm. That is intended. Never run a closed-lid session in a
bag, sleeve or on a bed.

### "Duration too long"

Sessions are always timed. The default maximum is 30 days; change it with
`lidless config maxDurationSeconds <seconds>` or in Settings.

## The laptop still went to sleep

1. Run `lidless status`. If it says **verification failed**, macOS reverted the
   sleep setting after Lidless set it. Lidless noticed, restored, and ended the
   session rather than pretend. Try once more; if it repeats, open an issue with
   your macOS version. Some managed Macs enforce sleep by policy.
2. Check the floors. On battery the session **ends below 10%** (default) and
   on a critical thermal state. `lidless status` shows the reason the last
   session ended, and the app's **History** page keeps a list.
3. External display or dock? Lidless keeps the system awake; it does not change
   display behaviour beyond turning the built-in display off.
4. If you quit the app (or the terminal running `lidless run`), the session
   ends. That is by design: quitting always restores your settings. Use
   `lidless start <duration>` from a terminal if you want to close the terminal
   afterwards; it hands the session to a background holder.

## I can't reach the laptop while the lid is closed

- The laptop must stay **on a network**. Wi‑Fi normally stays up with the lid
  closed; if it drops, Lidless sends a notification. A VPN such as Tailscale
  gives you a stable address from anywhere.
- Remote control in Claude Code or Codex needs the agent session to still be
  running. Start it inside `tmux` (or `screen`) so a dropped SSH connection
  does not kill it.
- On Apple silicon and T2 Macs the **built-in microphone is cut in hardware**
  when the lid closes. Voice tools need an external mic.
- The display is off on purpose. Screen-sharing tools still work; the picture
  comes back when you open the lid.

## After a crash, force-quit or reboot

Nothing to do. Lidless wrote the original value of every setting to a journal
**before** changing it. The recovery helper runs every minute and at login:

- if the owning process died with time left, the machine stays awake until the
  planned end (your agent may still be working) while the battery and thermal
  floors stay enforced;
- after a reboot it restores immediately;
- if a restore fails it retries every minute and keeps the journal.

`lidless status` shows anything still waiting to be restored. To force it now:

```bash
lidless stop        # ends the session and restores
lidless recover     # what the helper runs
```

## Updating

The app checks GitHub for a newer release once a day (turn it off in **About &
Updates** or with `lidless config checkForUpdates false`). **Download** saves
the new installer to your Downloads folder and opens it; nothing is installed
silently. `lidless update` does the same check from the terminal.

## Uninstalling

**Settings → Uninstall…** or `lidless uninstall` ends any session, restores
your settings and removes the permission and the recovery helper. Then delete
the app. State files are kept unless you add `--purge` (or delete the folder
below yourself).

## Where things live

| | Path |
|---|---|
| macOS | `~/Library/Application Support/Lidless/` |
| Windows | `%LOCALAPPDATA%\Lidless\` |
| Linux | `~/.local/state/lidless/` |

Inside: `session.json`, `journal.json`, `config.json`, `history.json`,
`last-end.json` and `lidless.log`. **Help → Open Log** opens the log. It may
contain process names; check it before sharing.

## Command reference

```bash
lidless start 2h              # stay awake for 2 hours (90m, 1d2h, "1h 30m" also work)
lidless run -- claude         # stay awake while the command runs, then restore
lidless run -d 8h -- codex    # same, but never longer than 8 hours
lidless extend 1h             # add time to the running session
lidless status [--json]       # what is going on
lidless stop                  # end now and restore
lidless doctor [--json]       # check setup
lidless agents                # detected coding agents
lidless stats                 # time awake, closed-lid time, sessions
lidless update                # check for a newer release
lidless config [key value]    # show or change settings
lidless setup / uninstall     # one-time setup, or remove it
```

Exit codes: `0` ok, `1` general error, `2` bad arguments or duration, `3` not
ready (run Setup), `4` verification failed (the OS reverted the awake state),
`5` no active session, `6` a session is already active, `7` restore incomplete.
`lidless run` passes the wrapped command's exit code through (130 after
Ctrl‑C).

## Reporting a bug

Include:

1. `lidless doctor --json`
2. the last ~50 lines of `lidless.log`
3. your OS version and laptop model
4. what you expected and what happened

[github.com/manasdutta04/lidless/issues/new](https://github.com/manasdutta04/lidless/issues/new)
