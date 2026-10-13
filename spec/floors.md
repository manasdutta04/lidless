# Safety floors

Evaluated by the owner every 15 s and on every power-source or thermal change,
and by the recovery job every run when the owner is dead.

| Config key | Default | Rule |
|---|---|---|
| `lowPowerBelowPercent` | 40 | On battery and level < this → request low-power mode |
| `endBelowPercent` | 10 | On battery and level < this → end session (`batteryFloor`). `0` disables. |
| `thermalRules` | true | Thermal `serious` → request low-power mode. `critical` → end (`thermalFloor`). |
| `lowPowerOnLidClose` | true | Lid closed and on battery → request low-power mode |

- Battery floors and every low-power request apply **on battery** only (on
  macOS, low-power mode is set on the battery profile with `pmset -b`). On AC,
  battery level is ignored. The thermal `critical` end applies on AC too.
- A machine with no battery has no battery floor.
- Battery present but unreadable on 2 consecutive reads while on battery →
  end (`batteryUnreadable`). One failed read is tolerated.
- `endBelowPercent` must be below `lowPowerBelowPercent`; if config breaks
  this, `lowPowerBelowPercent` is raised to `endBelowPercent + 1` at load.
- Low-power mode is released when no rule requests it any more (lid open, on
  AC, level recovered, thermal back to nominal/fair) — but only if Lidless
  turned it on (journal entry present).

Decision function (pure, tested by `vectors/floors.json`):

```
decide(onBattery, percent?, unreadableCount, thermal, lidClosed, config)
  -> { end: reason | null, wantLowPower: bool }
```

## Starting while warm

- A session never **starts** in the `critical` thermal state (when
  `thermalRules` is on); the start is refused with a "let it cool down" error.
- Starting in `fair` or `serious` is allowed but always warns first (the app
  asks for confirmation, the CLI prints the warning).
- Before the very first session, the ventilation warning is always shown and
  must be confirmed.
