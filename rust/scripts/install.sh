#!/bin/bash
# Linux: builds the `lidless` CLI from source, installs it to ~/.local/bin,
# and runs `lidless setup` (systemd user timer; nothing runs as root).
# For the tray app, download the AppImage/.deb from GitHub Releases, or see
# rust/app/README.md to build it.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v cargo >/dev/null; then
  echo "Rust is required: https://rustup.rs" >&2
  exit 1
fi

echo "Building lidless (release)…"
cargo build -p lidless --release

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
install -m 755 target/release/lidless "$BIN_DIR/lidless"
echo "✓ Installed $BIN_DIR/lidless"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  Note: $BIN_DIR is not on your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

"$BIN_DIR/lidless" setup
echo
"$BIN_DIR/lidless" doctor || true
echo
echo "Try: lidless start 2h   (keep the computer on a ventilated surface while the lid is closed)"
