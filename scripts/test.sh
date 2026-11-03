#!/usr/bin/env bash
# Runs the NoSlopKit unit tests (they run on macOS, no simulator needed). Extra arguments go to `swift test`,
# for example: ./scripts/test.sh --filter ContentFilter
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --package-path NoSlopKit "$@"
