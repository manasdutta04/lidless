#!/bin/bash
# Runs the test suite. Tests use fakes and temporary directories only; they
# never change real power settings.
#
# The Command Line Tools build of Swift Testing sometimes fails to load its
# macro plugin ("plugin for module 'TestingMacros' not found") under parallel
# builds. Incremental rebuilds succeed, so retry the build a few times.
set -euo pipefail
cd "$(dirname "$0")/.."

for attempt in 1 2 3 4 5; do
  if swift build --build-tests >/tmp/lidless-test-build.$$ 2>&1; then
    rm -f /tmp/lidless-test-build.$$
    exec swift test --skip-build "$@"
  fi
  if ! grep -q "plugin for module 'TestingMacros' not found" /tmp/lidless-test-build.$$; then
    cat /tmp/lidless-test-build.$$
    rm -f /tmp/lidless-test-build.$$
    exit 1
  fi
  echo "test build: Swift Testing macro plugin flake, retrying ($attempt)…" >&2
done
cat /tmp/lidless-test-build.$$
rm -f /tmp/lidless-test-build.$$
exit 1
