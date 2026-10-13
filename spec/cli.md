# CLI contract

Identical on every OS. Every command accepts `--json`, which prints exactly one
JSON object on stdout (human text goes to stderr in that mode).

| Command | Behavior |
|---|---|
| `lidless start <duration>` | Start a session owned by a detached holder process. Returns once the awake state is verified (or failed). |
| `lidless extend <duration>` | Add time to the live session (capped at max duration from now). |
| `lidless stop` | Ask the owner to end the session; wait up to 30 s for the restore to finish. If the owner is dead, run recovery directly. |
| `lidless status` | Show session, owner, remaining time, journal, warnings. |
| `lidless run [--duration <d>] -- <cmd...>` | Start a session owned by this process, run `cmd` with inherited stdio, end the session when it exits. Exit code = the command's exit code. Default duration: `runDefaultDuration` (24 h). If the duration ends first, the session ends and the command keeps running. |
| `lidless doctor` | Check privilege setup, recovery job, state directory, current power state. Exit 0 only if a session could start. |
| `lidless recover` | Run the recovery algorithm once (what the scheduler job runs). |
| `lidless config [key [value]]` | Show or set a config key. |
| `lidless agents` | List detected coding-agent processes. |
| `lidless version` | Print version. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic failure |
| 2 | Usage error (bad arguments or duration) |
| 3 | Not ready: privilege or recovery job missing (Hard rule 2) |
| 4 | Verification failed: the OS reverted or refused the awake state (Hard rule 3) |
| 5 | No active session (for `extend` / `stop`) |
| 6 | A session is already active (for `start` / `run`) |
| 7 | Restore incomplete: journal entries remain |

`run` returns the wrapped command's exit code on success, or 128+signal if it
was killed by a signal, and one of the codes above if the session could not
start (the command is then **not** run).

## `status --json` shape

```jsonc
{
  "active": true,
  "session": { "id": "...", "startedAt": "...", "endsAt": "...", "remainingSeconds": 3600,
               "owner": { "kind": "cli", "pid": 4242, "alive": true }, "command": null },
  "journal": { "sleepDisabled": true, "lowPowerMode": false },
  "lidClosed": false,
  "power": { "onBattery": true, "percent": 73, "thermal": "nominal" },
  "lastEnd": { "reason": "expired", "at": "...", "restoreComplete": true },
  "warnings": ["..."],
  "ready": { "privilege": true, "recoveryArmed": true }
}
```
