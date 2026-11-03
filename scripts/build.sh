#!/usr/bin/env bash
# Builds the app for the iOS Simulator without code signing, into .build/DerivedData.
#
#   ./scripts/build.sh
#   DESTINATION='platform=iOS Simulator,id=<udid>' ./scripts/build.sh     # a specific simulator
#
# Extra arguments are passed on to xcodebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d NoSlop.xcodeproj ]; then
  ./scripts/bootstrap.sh
fi

xcodebuild \
  -project NoSlop.xcodeproj \
  -scheme NoSlop \
  -destination "${DESTINATION:-generic/platform=iOS Simulator}" \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build -quiet "$@"
