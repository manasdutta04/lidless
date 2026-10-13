# Lidless tray app (Windows / Linux)

A Tauri 2 app: Rust backend in `src-tauri/`, plain HTML/CSS/JS frontend in
`src/` (no framework, no bundler, no npm dependencies at runtime). It is the
Windows and Linux counterpart of the macOS menu bar app and follows the same
layout, copy and behaviour.

- **Tray panel** (`src/panel.html`): the only place a session starts. Presets,
  custom duration, ventilation checkpoint, extend/stop, status rows.
- **Desktop window** (`src/index.html`): Overview (tips, stats, charts), History,
  Settings, Setup, About & Updates. Read-only for sessions.
- **Backend** (`src-tauri/src/`): `worker.rs` owns the `SessionOwner` on one
  thread with a 1 s tick and emits the full `state` snapshot to both windows;
  `commands.rs` exposes the Tauri commands; `tray.rs` builds the tray icon,
  its menu and places the panel; `engine.rs` picks the platform engine.

## Engine per platform

| Target | Engine |
|---|---|
| Windows | `lidless_windows::WindowsEngine` |
| Linux | `lidless_linux::LinuxEngine` |
| macOS (design preview only) | `lidless_core::testing::FakeEngine` (never touches power settings) |

## Build

Prerequisites: Rust stable, Node (only for the Tauri CLI via `npx`), and the
Tauri 2 system packages for your OS (WebView2 is preinstalled on Windows 10/11;
on Debian/Ubuntu: `libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev
librsvg2-dev patchelf`).

```sh
# Type-check
cd rust && cargo check -p lidless-app

# Debug binary without installers
cd rust/app && npx --yes @tauri-apps/cli@2 build --debug --no-bundle
# -> rust/target/debug/lidless-app

# Installers (msi + nsis on Windows, AppImage + deb on Linux)
cd rust/app && npx --yes @tauri-apps/cli@2 build
# -> rust/target/release/bundle/
```

`tauri.conf.json` lists all four bundle targets; the Tauri CLI only builds the
ones that apply to the host OS.

The CLI (`rust/cli`, binary `lidless`) is **not** bundled by this config. The
app looks for it beside its own executable (`lidless.exe` next to
`lidless-app.exe` on Windows, `lidless` next to `lidless-app` or in
`/usr/bin` / `/usr/local/bin` on Linux) when it runs setup, because the
recovery job runs `lidless recover`. The release workflow should build
`lidless` and place it next to the app binary before bundling (for example by
adding it to `bundle.resources`, or to the NSIS/deb packaging step).

## Icons

`src-tauri/icons/` was generated with
`npx @tauri-apps/cli@2 icon --fit contain ../../public/lidless-icon.png` from
`src-tauri/`. The tray icons are derived from the same master:
`tray.png` (colour), `tray-awake.png` (colour with an accent dot, shown while a
session is active) and `tray-template.png` (monochrome glyph used as a macOS
template image in the preview build). `src/brand.png` is the in-app mark.

## Running the preview on macOS

```sh
LIDLESS_HOME=$(mktemp -d) ./rust/target/debug/lidless-app
```

The tray icon appears in the menu bar; a left click opens the panel, a right
click the menu. Nothing in the preview changes real power settings.

## State

The app reads and writes the same state directory as the CLI
(`Paths::resolve()`, overridable with `LIDLESS_HOME`), plus its own small
`app-state.json` (first-launch flag, last update check, window size).
