# Windows and Linux: real-machine validation

The Rust core is tested against the shared `spec/vectors` on every push, and
the engines compile for their targets, but **nothing below has run on real
hardware yet**. These are the checks to run before the first Windows and Linux
release, plus the open questions they answer (CLAUDE.md §13). Record results
in the table at the bottom.

Start every check from a clean state: `lidless status` shows no session and
nothing pending.

## Both platforms

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Setup | `lidless setup`, then `lidless doctor` | All ✓, "Ready: sessions can start." |
| 2 | Start + read-back | `lidless start 5m` | Returns after ~5 s with "You can close the lid." |
| 3 | Lid closed, stays awake | Start 15m, close the lid 5 min, `ping` it from another device (or SSH in) | Answers the whole time; `lidless status` afterwards shows the session still active |
| 4 | Normal expiry | `lidless start 2m`, wait | Notification; `status` shows "Time ran out" |
| 5 | Stop / extend | `start 1h`, `extend 30m`, `stop` | New end time shown; stop restores within seconds |
| 6 | `run` exit paths | `lidless run -- sleep 20`; Ctrl-C during `run -- sleep 600`; `run -- sh -c 'exit 3'` (PowerShell: `cmd /c exit 3`) | Restores each time; exit codes 0 / 130 (Windows: non-zero) / 3 |
| 7 | Holder killed | `lidless start 3m`, kill the `lidless _hold` process | `status` shows the owner gone; recovery job restores within ~1 min of expiry |
| 8 | Reboot mid-session | Start 1h, reboot, log in | Within ~1 min: `status` shows "The computer restarted" and nothing pending |
| 9 | Battery floor | `lidless config endBelowPercent 50` on battery under 50% | Session ends with `batteryFloor` |
| 10 | Not ready refuses | Remove the recovery job (`schtasks /Delete /TN Lidless\Recovery` or `systemctl --user disable --now lidless-recover.timer`), `lidless start 5m` | Exit 3, nothing changed; re-run setup |
| 11 | Tray app | Start from the panel, close the lid, reopen, stop | Same as 3 and 5; the window's History shows the session with lid-closed time |
| 12 | Uninstall | `lidless uninstall` | Jobs and permission removed; settings normal |

## Windows only (open questions 1 and 2)

| # | Check | How | Expected / what we learn |
|---|---|---|---|
| W1 | Direct write as a standard user | On a non-admin account: `lidless setup` output | Either "can change the lid-close action directly" (no elevated task needed) or a UAC prompt and "Lidless\LidAction registered". Record which. |
| W2 | Lid action really changes | After `start`: `powercfg /Q SCHEME_CURRENT SUB_BUTTONS LIDACTION` | Current AC and DC index `0x00000000`; back to the originals after `stop` |
| W3 | Modern Standby | On a Modern Standby laptop (`powercfg /a` lists "Standby (S0 Low Power Idle)"): check 3 with a CPU-bound job, e.g. `lidless run -- powershell -c "1..1e9 | % { $_ }"` | Does the job keep running at full speed with the lid closed? If it is throttled, note it; the power request may need `PowerRequestExecutionRequired` added. |
| W4 | Managed device | On a device with a power policy (Intune/GPO) | `start` reports the policy clearly (verification failure), not success |
| W5 | Display off | Close the lid | Panel turns off within a second (SC_MONITORPOWER) |

## Linux only (open question 5)

| # | Check | How | Expected / what we learn |
|---|---|---|---|
| L1 | Inhibitor visible | After `start`: `systemd-inhibit --list` | A `Lidless` block on `handle-lid-switch:sleep:idle` |
| L2 | GNOME | Check 3 on GNOME (Wayland and X11) | Record whether gnome-settings-daemon suspends anyway. If it does, document the `org.gnome.settings-daemon.plugins.power` workaround and consider taking a `handle-lid-switch` delay inhibitor as well. |
| L3 | KDE Plasma | Check 3 on Plasma | Same |
| L4 | Power profile | On battery, close the lid; `powerprofilesctl get` | `power-saver`, back to the original on open |
| L5 | Lid state | `cat /proc/acpi/button/lid/*/state` closed/open | `lidless status` Lid row follows it (some laptops lack this node: then Lid shows nothing and lid-close actions do not run) |
| L6 | Thermal mapping | `cat /sys/class/thermal/thermal_zone*/temp` under load | `doctor` thermal level matches the 75/85/95 °C thresholds; tune if a machine's zone runs hot by design |

## Results

| Date | Version | OS | Machine | Result / notes |
|---|---|---|---|---|
| | | | | |
