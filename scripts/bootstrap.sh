#!/usr/bin/env bash
# One-time (and after pulling changes to project.yml) setup: generates NoSlop.xcodeproj with XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate

if [ ! -f Config/Local.xcconfig ]; then
  cat <<'MSG'

Optional, to run on a physical device: set your signing team.
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  # then edit Config/Local.xcconfig and replace YOURTEAMID with your Apple Developer Team ID
The simulator builds without it.
MSG
fi

echo
echo "Done. Open NoSlop.xcodeproj in Xcode 26.2 or newer."
