#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== Living Reader preflight =="
echo "Repo: $ROOT"
echo "Date (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"

command -v xcodebuild >/dev/null || { echo "FAIL: xcodebuild missing"; exit 1; }
command -v xcrun >/dev/null || { echo "FAIL: xcrun missing"; exit 1; }
command -v xcodegen >/dev/null || { echo "FAIL: xcodegen missing (brew install xcodegen)"; exit 1; }

echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "Swift: $(swift --version 2>&1 | head -1)"

if [[ ! -f project.yml ]]; then
  echo "FAIL: project.yml missing"
  exit 1
fi

echo "Generating Xcode project..."
xcodegen generate

if [[ ! -d LivingReader.xcodeproj ]]; then
  echo "FAIL: LivingReader.xcodeproj not generated"
  exit 1
fi

xcodebuild -list -project LivingReader.xcodeproj >/dev/null
echo "OK: preflight passed"
