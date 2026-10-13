# Lidless behavior spec

This folder is the contract every Lidless implementation follows (Swift on
macOS, Rust on Windows and Linux). If an implementation and this spec
disagree, fix the spec first, then the implementations.

- [session.md](session.md): session model, ownership, end reasons
- [journal.md](journal.md): the recovery journal and the restore algorithm
- [floors.md](floors.md): battery and thermal safety floors
- [cli.md](cli.md): the `lidless` command-line contract
- [journal.schema.json](journal.schema.json): JSON Schema for `journal.json`
- [vectors/](vectors/): shared test vectors loaded by every test suite

## State directory

All state lives in one owner-only directory (mode `0700`, files `0600`):

| OS | Path |
|---|---|
| macOS | `~/Library/Application Support/Lidless/` |
| Windows | `%LOCALAPPDATA%\Lidless\` |
| Linux | `$XDG_STATE_HOME/lidless/` (default `~/.local/state/lidless/`) |

The environment variable `LIDLESS_HOME` overrides the path. Tests always set
it to a temporary directory.

| File | Purpose |
|---|---|
| `session.json` | The active session, if any. Absent means no session. |
| `journal.json` | Every system change Lidless made and must undo. |
| `config.json` | User settings. Missing keys take defaults. |
| `last-end.json` | How the most recent session ended (for `status` and the UI). |
| `lock` | Advisory lock file. Held while reading-then-writing state or changing the system. |
| `lidless.log` | Owner-only log, rotated at 1 MiB (one previous file kept). |

All JSON writes are atomic: write to a temp file in the same directory, fsync,
rename over the target.
