# Session model

```jsonc
// session.json
{
  "version": 1,
  "id": "UUID",
  "startedAt": "2026-10-13T10:00:00Z",   // ISO-8601, UTC
  "endsAt":    "2026-10-13T12:00:00Z",   // the ONLY field that decides whether to stay awake
  "extensions": [ { "at": "...", "seconds": 1800 } ],
  "owner": {
    "kind": "app" | "cli" | "run",
    "pid": 4242,
    "startTime": 1760349600123456,       // process start time, microseconds since epoch
    "bootSession": "UUID"                // OS boot identifier
  },
  "command": ["claude"],                 // only for kind == "run"
  "stopRequested": null | "user" | "..." // set by `lidless stop`; the owner ends the session on its next tick
}
```

## Rules

1. **Always timed.** `endsAt - startedAt` and every extension are capped so
   that `endsAt <= now + maxDuration` (default 30 days). There is no
   indefinite mode.
2. **One session at a time.** Starting while a live session exists is an
   error (`extend` it instead).
3. **One owner.** Exactly one process owns a session. The owner holds the
   OS-level awake state, watches lid/battery/thermal, and is the only process
   that ends the session normally. The owner is:
   - the menu bar app, when started from the app;
   - a detached `lidless` holder process, when started by `lidless start`;
   - the `lidless run` process itself, for `lidless run`.
4. **Owner liveness** is `pid` alive **and** its start time equal to
   `owner.startTime` **and** the current boot equal to `owner.bootSession`.
   A pid alone never proves identity.
5. **Other processes never signal the owner.** `stop` and `extend` edit
   `session.json` under the lock; the owner re-reads it every tick (≤ 1 s).
6. **Quitting the owner ends the session.** A graceful exit (Quit, SIGTERM,
   SIGINT to a holder) restores everything before exiting.
7. **Owner crash.** If the owner is dead:
   - different boot → restore now (`rebooted`);
   - `endsAt` passed → restore now (`expired`);
   - a critical floor is tripped → restore now (`batteryFloor` / `thermalFloor`);
   - otherwise the machine stays awake until `endsAt` (the agent may still be
     working). The recovery job keeps enforcing the floors every minute.
8. **Unreadable session file** counts as expired. It is renamed to
   `session.json.unreadable-<epoch>` (never deleted) and the journal restored.

## End reasons

`expired`, `stopped`, `quit`, `commandExited`, `batteryFloor`,
`thermalFloor`, `batteryUnreadable`, `verificationFailed`, `ownerTerminated`,
`rebooted`, `ownerLost`, `startFailed`.

## Duration syntax

`<n><unit>` repeated, units `d`, `h`, `m`, `s`, in descending order, each at
most once, total > 0. A bare integer means minutes. Whitespace between parts
is allowed. Case-insensitive. Examples: `2h`, `90m`, `1d2h`, `1h 30m`, `45`.
Rejected: ``, `0m`, `2x`, `1m2h`, `1h1h`, `-5m`, `1.5h`.
See `vectors/durations.json`.
