#!/usr/bin/env bash
# Build and capture the actual first screen on one explicitly chosen simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
UDID="${GENBOOKS_SIMULATOR_UDID:?Set GENBOOKS_SIMULATOR_UDID to a chosen simulator UUID}"
[[ "$UDID" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || exit 2
./scripts/preflight.sh
source "$ROOT/scripts/sim_lock.sh"
sim_lock_acquire "$UDID"
mkdir -p artifacts
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcodebuild -project LivingReader.xcodeproj -scheme LivingReader \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath artifacts/DerivedData \
  build > artifacts/smoke-build.log 2>&1
APP_PATH="$ROOT/artifacts/DerivedData/Build/Products/Debug-iphonesimulator/LivingReader.app"
xcrun simctl terminate "$UDID" com.jarvis.livingreader 2>/dev/null || true
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl launch "$UDID" com.jarvis.livingreader
sleep 2
xcrun simctl io "$UDID" screenshot "$ROOT/artifacts/smoke-library.png"
echo "Captured artifacts/smoke-library.png. This smoke check is not the full test suite."
