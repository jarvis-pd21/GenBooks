#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== GenBooks (Living Reader) check (unit + UI) =="
./scripts/preflight.sh

export ARTIFACTS_DIR="$ROOT/artifacts/ui"
# xcodebuild forwards TEST_RUNNER_<VAR> to test runners with the prefix stripped.
# A plain shell export reaches xcodebuild, but not the simulator's UI-test runner.
export TEST_RUNNER_ARTIFACTS_DIR="$ARTIFACTS_DIR"
# The caller chooses one available simulator; never guess a shared device.
UDID="${GENBOOKS_SIMULATOR_UDID:?Set GENBOOKS_SIMULATOR_UDID to a chosen simulator UUID}"
[[ "$UDID" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || {
  echo "Expected a simulator UUID" >&2; exit 2;
}

# Serialize test runs that use the same simulator.
# shellcheck source=scripts/sim_lock.sh
source "$ROOT/scripts/sim_lock.sh"
sim_lock_acquire "$UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null || true
echo "Booted/using simulator UDID=$UDID; sibling simulators are left untouched"
# Sibling simulators are left untouched.
DESTINATION="platform=iOS Simulator,id=$UDID"
echo "Destination: $DESTINATION"

mkdir -p "$ARTIFACTS_DIR"
rm -rf artifacts/CheckResult.xcresult artifacts/CheckResult-unit.xcresult artifacts/CheckResult-ui.xcresult
# Refresh copied manuscript resources before the build.
for fixture in Resources/Fixtures/argentina_minimal.json Resources/Fixtures/quran_pickthall.json; do
  [[ ! -f "$fixture" ]] || touch "$fixture"
done
rm -f artifacts/DerivedData/Build/Products/*/LivingReader.app/argentina_minimal.json 2>/dev/null || true

# Stale app state from an earlier run changes which reader affordances appear.
# Start each UI run from a clean install unless a caller opts out.
if [[ "${LIVINGREADER_KEEP_SIM_APP_DATA:-0}" != "1" ]]; then
  xcrun simctl terminate "$UDID" com.jarvis.livingreader 2>/dev/null || true
  xcrun simctl uninstall "$UDID" com.jarvis.livingreader 2>/dev/null || true
fi

: > artifacts/check.log

# Unit and UI suites run as separate xcodebuild invocations: it keeps memory
# pressure down in a single test host and makes a failure attributable to one
# layer instead of one merged log.
run_phase() {
  local label="$1"; shift
  echo "-- $label"
  set +e
  xcodebuild "$@" | tee -a artifacts/check.log
  local status=${PIPESTATUS[0]}
  set -e
  if [[ $status -ne 0 ]]; then
    echo "FAIL: $label (xcodebuild exit $status)"
    exit "$status"
  fi
}

run_phase "unit tests (LivingReaderTests)" \
  -project LivingReader.xcodeproj \
  -scheme LivingReader \
  -destination "$DESTINATION" \
  -resultBundlePath artifacts/CheckResult-unit.xcresult \
  -only-testing:LivingReaderTests \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  test

# UI tests drive a real simulator app, so they get an execution-time allowance
# and one automatic retry. Retries are reported, never silently swallowed.
run_phase "UI tests (LivingReaderUITests)" \
  -project LivingReader.xcodeproj \
  -scheme LivingReader \
  -destination "$DESTINATION" \
  -resultBundlePath artifacts/CheckResult-ui.xcresult \
  -only-testing:LivingReaderUITests \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 420 \
  -retry-tests-on-failure \
  -test-iterations 2 \
  test

# Keep the historical single-bundle path pointing at the UI result.
cp -R artifacts/CheckResult-ui.xcresult artifacts/CheckResult.xcresult 2>/dev/null || true

RETRIES="$(grep -cE '^Test Case .* started \(Iteration ([2-9]|[1-9][0-9]+) of ' artifacts/check.log || true)"
if [[ "${RETRIES:-0}" -gt 0 ]]; then
  echo "WARN: $RETRIES UI retry attempt(s) occurred — see artifacts/check.log"
fi

# The offline source fixture requires its dedicated app identity. Its separate
# phase retains its own result bundle and requires both journeys to pass.
# Release this process's lock before the child reacquires the same simulator.
echo "-- isolated offline source-continuation UI tests"
sim_lock_release
"$ROOT/scripts/check_source_continuation.sh" --run "$ROOT" "$UDID"

echo "OK: check passed"
exit 0
