# Release validation (real Mac)

Unit tests use fakes. Before each release, run these on a real MacBook and
record the result. Use a ventilated surface. Start every check from a clean
state: `lidless status` shows no session and no pending restore, and
`pmset -g | grep SleepDisabled` prints nothing.

Record: date, Lidless version, macOS version and build, Mac model, result.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Install | `./macos/scripts/install.sh` | `lidless doctor` all ✓ |
| 2 | Start + read-back | `lidless start 5m` | Returns after ~5 s; `pmset -g` shows `SleepDisabled 1` |
| 3 | Lid closed, stays awake | Start, close lid 2 min, SSH in or watch a `ping` from another machine | Mac answers the whole time |
| 4 | Display off on close | Close lid with an external display unplugged | Internal display goes dark |
| 5 | Low Power Mode on battery | Unplug, close lid | `pmset -g` shows `lowpowermode 1`; back to 0 after opening |
| 6 | Normal expiry | `lidless start 2m`, wait | Notification; `SleepDisabled` line gone |
| 7 | Stop | `lidless start 1h`, `lidless stop` | Restored within a few seconds |
| 8 | Extend | `lidless extend 30m` | `status` shows new end time |
| 9 | `run` exit | `lidless run -- sleep 20` | Restored after 20 s; exit code 0 |
| 10 | `run` Ctrl-C | `lidless run -- sleep 600`, press Ctrl-C | Restored; exit code 130 |
| 11 | `run` failure code | `lidless run -- sh -c 'exit 3'` | Exit code 3; restored |
| 12 | App quit ends session | Start from menu, Quit | Restored before exit |
| 13 | Force-quit → orphan | Start 3m from menu, `kill -9` the app | `status` shows orphan; restored by the recovery agent within ~1 min after expiry |
| 14 | Holder killed | `lidless start 3m`, `kill -9` the holder pid from `status` | Same as 13 |
| 15 | Reboot mid-session | Start 1h, restart | Restored within ~1 min of login |
| 16 | Battery floor | `lidless config endBelowPercent 50` on battery under 50% | Session ends with `batteryFloor` |
| 17 | Not ready refuses | Temporarily `launchctl bootout gui/$UID/io.github.manasdutta04.lidless.recovery`, then `lidless start 5m` | Exit 3, nothing changed; reload the agent afterwards |
| 18 | Revert detection | Start 10m, run `sudo pmset -a disablesleep 0` | Within ~60 s Lidless re-applies it; if it cannot, the session ends with `verificationFailed` |
| 19 | Already disabled by someone else | `sudo pmset -a disablesleep 1`, `lidless start 2m`, wait | After the end, `SleepDisabled 1` is still set (not ours); then `sudo pmset -a disablesleep 0` |
| 20 | Network warning | Start, turn Wi-Fi off for 40 s | "Network lost" notification, then "Network back" |
| 21 | Uninstall | `./macos/scripts/uninstall.sh` | Sudoers rule, agent, app removed; settings normal |

## Results

| Date | Version | macOS | Mac | Result / notes |
|---|---|---|---|---|
| 2026-10-13 | 0.1.0 | 27.0.1 (26A434) | MacBook Air (Apple silicon) | **#1 install ✓, #2 start + read-back ✓ (verified 5 s after engage), #3 lid closed ~9.5 min on battery: heartbeat every 5 s with no gaps, network up throughout ✓, #4 display off on close ✓ (powerd released its display assertion at close), #5 Low Power Mode on at close and off at open ✓, #7 stop restored everything ✓, #13 force-quit (`pkill -9`) mid-session: session kept as orphan with SleepDisabled 1 and a clear warning, then `lidless stop` restored everything ✓, #6 expiry (`start 2m`) ended with "Time ran out" ✓, #9 `run -- sleep 20` restored on exit ✓, #10 Ctrl-C during `run` restored, exit code 130 ✓.** After the first change, `pmset -g` prints `SleepDisabled 0` explicitly (before any change it omitted the line); the parser handles both. Remaining: #8, #11, #12, #14–#21 (and #13's unattended expiry path). |
