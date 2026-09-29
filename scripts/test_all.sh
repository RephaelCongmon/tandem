#!/bin/bash
# Runs the core test suite and builds the app (Debug) with warnings treated as failures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "▸ Core tests"
(cd "$ROOT/Core" && swift test 2>&1 | tee /tmp/tandem-core-tests.log | grep -E "Executed [0-9]+ tests|error:|failed \(" | tail -3)
grep -q "with 0 failures" /tmp/tandem-core-tests.log || { echo "Core tests failed"; exit 1; }
echo "▸ App build"
(cd "$ROOT/App" && xcodegen generate >/dev/null)
xcodebuild -project "$ROOT/App/Tandem.xcodeproj" -scheme Tandem -configuration Debug \
  -derivedDataPath "$ROOT/build/DerivedData" -destination 'platform=macOS' build 2>&1 \
  | tee /tmp/tandem-app-build.log | grep -E "warning:|error:|BUILD" | grep -v appintents || true
grep -q "BUILD SUCCEEDED" /tmp/tandem-app-build.log || { echo "App build failed"; exit 1; }
if grep -E "\.swift:[0-9]+:[0-9]+: warning:" /tmp/tandem-app-build.log >/dev/null; then echo "App build has warnings"; exit 1; fi
echo "✓ All tests passed and the app builds cleanly"
