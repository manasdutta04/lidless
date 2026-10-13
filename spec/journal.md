# Recovery journal

`journal.json` records every system change Lidless made that must be undone,
with the value it replaced. Schema: [journal.schema.json](journal.schema.json).

```jsonc
{
  "version": 1,
  "updatedAt": "2026-10-13T10:00:00Z",
  "macos": {
    "sleepDisabled": { "original": false, "recordedAt": "..." },
    "lowPowerMode":  { "original": false, "recordedAt": "..." }
  },
  "windows": {
    "lidAction": { "scheme": "GUID", "originalAC": 1, "originalDC": 1, "recordedAt": "..." }
  },
  "linux": {
    "powerProfile": { "original": "balanced", "recordedAt": "..." }
  }
}
```

Linux holds the machine awake with a logind inhibitor, which is not journaled:
the kernel releases it when the owning process exits, so there is nothing a
recovery job could restore. Windows journals the lid-close action it changed;
its power request is likewise released with the process.

An entry's presence means "Lidless may have changed this; put back
`original`". An empty journal (`{}` sections or no file) means nothing to undo.

## Change protocol (Hard rule 1)

1. Take the lock.
2. Read the current value. If it already equals the target, change nothing and
   write nothing. Lidless does not own a value it did not change.
3. Write the entry with `original` to the journal (atomic + fsync).
4. Run the change command.
5. Release the lock.

If step 4 fails, the entry stays. Restore will notice the value still equals
`original` and clear it without running anything.

## Restore algorithm (Hard rule 4)

For each entry, in reverse order of application (macOS: `lowPowerMode`, then
`sleepDisabled`):

1. Read the current value.
   - Equals `original` → clear the entry (nothing to do).
   - Unreadable → run the undo command anyway (it only ever sets `original`).
2. Run the undo command (set back to `original`).
3. Exit status 0 → clear the entry and save. Otherwise keep the entry, report
   the failure, try again on the next recovery run.

Never write a value that is not an entry's `original`. Never touch a setting
with no entry.

## Stuck commands

Privileged commands get a 20 s limit. On timeout the command is sent SIGTERM
(never SIGKILL, so a root process is never left half-done behind a journal that
moved on), the entry is kept, and the failure is reported.

## Recovery job

An OS scheduler job (macOS: launchd agent, every 60 s and at login) runs
`lidless recover`. It depends only on the state directory and the `lidless`
binary, never on the app being alive. Logic, under the lock:

1. Session file unreadable → rename aside; treat as no session.
2. Session present and owner alive → do nothing.
3. Session present, owner dead → apply session.md rule 7.
4. No session (or session ended) and journal non-empty → restore.
5. Write `last-end.json` when a session ends here.
