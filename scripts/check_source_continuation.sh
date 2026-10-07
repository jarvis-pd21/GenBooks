#!/usr/bin/env bash
# Dedicated offline-source UI gate. Run only after the canonical gate releases
# its simulator lock; this phase acquires that same lock independently.
# Usage: bash check_source_continuation.sh --prepare-only|--run CHECKOUT SIMULATOR_UDID
set -euo pipefail

MODE="${1:-}"
[[ "$MODE" == "--prepare-only" || "$MODE" == "--run" ]] || {
  echo "Usage: $0 --prepare-only|--run CHECKOUT SIMULATOR_UDID" >&2; exit 2;
}
[[ $# == 3 ]] || { echo "Expected checkout path and explicit simulator UDID" >&2; exit 2; }
ROOT="$(cd "$2" && pwd -P)"
[[ -f "$ROOT/project.yml" && -f "$ROOT/scripts/sim_lock.sh" ]] || exit 2
UDID="$3"
[[ "$UDID" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || {
  echo "Expected a simulator UUID" >&2; exit 2;
}
BUNDLE="com.jarvis.livingreader.codex.sourcecontinuation"

# Resolve the checkout first; do not resolve away an escaping artifacts symlink.
ARTIFACTS_DIR="$(python3 - "$ROOT" "${ARTIFACTS_DIR:-$ROOT/artifacts/ui}" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve(strict=True)
allowed = root / "artifacts"
raw = Path(sys.argv[2])
if not raw.is_absolute():
    raise SystemExit("ARTIFACTS_DIR must be absolute")
destination = raw.resolve()
if not destination.is_relative_to(allowed):
    raise SystemExit("ARTIFACTS_DIR must stay under this checkout's artifacts directory")
destination.mkdir(parents=True, exist_ok=True)
print(destination)
PY
)"
export ARTIFACTS_DIR
export TEST_RUNNER_ARTIFACTS_DIR="$ARTIFACTS_DIR"
export TEST_RUNNER_SOURCE_CONTINUATION_OFFLINE_ACCEPTANCE=1
RUN_DIR="$(mktemp -d "$ARTIFACTS_DIR/source-continuation.XXXXXX")"
echo "Isolated source-continuation evidence: $RUN_DIR"

# Dumping preserves the current project definition without a YAML dependency.
# All generated files and the Xcode project stay in RUN_DIR; source refs stay in ROOT.
xcodegen dump --spec "$ROOT/project.yml" --project-root "$ROOT" \
  --type json --no-env --file "$RUN_DIR/base.json"
python3 - "$ROOT" "$RUN_DIR" "$BUNDLE" <<'PY'
import json
from pathlib import Path
import sys
root, run, bundle = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
spec = json.loads((run / "base.json").read_text())
ids = {
    "LivingReader": bundle,
    "GenBooksShare": bundle + ".share",
    "LivingReaderTests": bundle + ".tests",
    "LivingReaderUITests": bundle + ".uitests",
}
if set(spec["targets"]) != set(ids):
    raise SystemExit("Target inventory changed; review isolated identities before running")
for name, target in spec["targets"].items():
    for source in target["sources"]:
        source["path"] = str((root / source["path"]).resolve(strict=True))
    settings = target.setdefault("settings", {}).setdefault("base", {})
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = ids[name]
    for section, setting, suffix in [
        ("info", "INFOPLIST_FILE", "Info.plist"),
        ("entitlements", "CODE_SIGN_ENTITLEMENTS", "entitlements"),
    ]:
        if section in target:
            path = str(run / (name + "." + suffix))
            target[section]["path"] = path
            settings[setting] = path
    if "entitlements" in target:
        target["entitlements"]["properties"]["com.apple.security.application-groups"] = [
            "group." + bundle
        ]
app = spec["targets"]["LivingReader"]
app["settings"]["base"]["INFOPLIST_KEY_CFBundleDisplayName"] = "GenBooks Source Test"
app["info"]["properties"]["CFBundleDisplayName"] = "GenBooks Source Test"
for url_type in app["info"]["properties"].get("CFBundleURLTypes", []):
    url_type["CFBundleURLName"] = bundle
    url_type["CFBundleURLSchemes"] = ["genbooks-source-continuation"]
(run / "isolated.json").write_text(json.dumps(spec, indent=2) + "\n")
PY
xcodegen generate --spec "$RUN_DIR/isolated.json" \
  --project-root "$RUN_DIR" --project "$RUN_DIR" --no-env

if [[ "$MODE" == "--prepare-only" ]]; then
  echo "Prepared only; no build or simulator action. Project: $RUN_DIR/LivingReader.xcodeproj"
  exit 0
fi

# check.sh must release its parent lock before calling this child. There is no
# nested-lock bypass; a standalone invocation locks its explicitly named simulator.
source "$ROOT/scripts/sim_lock.sh"
unset LIVINGREADER_SKIP_SIM_LOCK
sim_lock_acquire "$UDID"

# This phase never uninstalls the canonical app, changes its preferences, or
# targets a physical device. Fresh UUID fixtures make cleanup unnecessary.
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
TEST1="testSourceContinuationReviewRetryRelaunchPublishReopenAndRestore"
TEST2="testSourceContinuationStartNewArchivesTheFailedCandidateWithoutAIReplay"
RESULT="$RUN_DIR/SourceContinuation.xcresult"
set +e
xcodebuild -project "$RUN_DIR/LivingReader.xcodeproj" -scheme LivingReader \
  -configuration Debug -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$RUN_DIR/DerivedData" -resultBundlePath "$RESULT" \
  -only-testing:"LivingReaderUITests/LaunchUITests/$TEST1" \
  -only-testing:"LivingReaderUITests/LaunchUITests/$TEST2" \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 420 test | tee "$RUN_DIR/check.log"
STATUS=${PIPESTATUS[0]}
set -e
[[ $STATUS == 0 ]] || exit "$STATUS"

# A successful xcodebuild with skipped tests is insufficient. Require both exact
# journeys to pass and the report to name only the assigned simulator.
xcrun xcresulttool get test-results tests --path "$RESULT" > "$RUN_DIR/tests.json"
xcrun xcresulttool get test-results summary --path "$RESULT" > "$RUN_DIR/summary.json"
python3 - "$RUN_DIR" "$UDID" "$TEST1" "$TEST2" <<'PY'
import json
from pathlib import Path
import sys
run, udid = Path(sys.argv[1]), sys.argv[2]
expected = set(sys.argv[3:])
summary = json.loads((run / "summary.json").read_text())
if (summary.get("result") != "Passed" or summary.get("totalTestCount") != 2
        or summary.get("passedTests") != 2 or summary.get("skippedTests") != 0
        or summary.get("failedTests") != 0):
    raise SystemExit("Expected exactly two passed tests with zero skips/failures")
tests = json.loads((run / "tests.json").read_text())
if {d["deviceId"] for d in tests["devices"]} != {udid}:
    raise SystemExit("Unexpected test device")
cases = []
def walk(nodes):
    for node in nodes:
        if node["nodeType"] == "Test Case":
            cases.append(node)
        walk(node.get("children", []))
walk(tests["testNodes"])
if (len(cases) != 2 or {c["name"].removesuffix("()") for c in cases} != expected
        or any(c.get("result") != "Passed" for c in cases)):
    raise SystemExit("Expected both named source-continuation journeys to execute and pass")
print("OK: both isolated offline source-continuation journeys executed and passed")
PY
