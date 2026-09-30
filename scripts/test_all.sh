#!/bin/bash
# Runs the core test suite and builds the app (Debug) with warnings treated as failures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The live Parakeet test runs when a downloaded model is around (the app's, or a dev profile's).
if [[ -z "${TANDEM_PARAKEET_MODELS:-}" ]]; then
  for dir in "$HOME/Library/Application Support/Tandem/Models" "$HOME/Library/Application Support/Tandem/Profiles/B/Models"; do
    [[ -d "$dir/parakeet-tdt-0.6b-v2" ]] && { export TANDEM_PARAKEET_MODELS="$dir"; break; }
  done
fi
echo "▸ Core tests"
(cd "$ROOT/Core" && swift test 2>&1 | tee /tmp/tandem-core-tests.log | grep -E "Executed [0-9]+ tests|error:|failed \(" | tail -3)
grep -q "with 0 failures" /tmp/tandem-core-tests.log || { echo "Core tests failed"; exit 1; }
echo "▸ App build"
(cd "$ROOT/App" && xcodegen generate >/dev/null)
xcodebuild -project "$ROOT/App/Tandem.xcodeproj" -scheme Tandem -configuration Debug \
  -derivedDataPath "$ROOT/build/DerivedData.noindex" -destination 'platform=macOS' build 2>&1 \
  | tee /tmp/tandem-app-build.log | grep -E "warning:|error:|BUILD" | grep -v appintents || true
grep -q "BUILD SUCCEEDED" /tmp/tandem-app-build.log || { echo "App build failed"; exit 1; }
if grep -E "\.swift:[0-9]+:[0-9]+: warning:" /tmp/tandem-app-build.log >/dev/null; then echo "App build has warnings"; exit 1; fi
echo "▸ App tests"
xcodebuild -project "$ROOT/App/Tandem.xcodeproj" -scheme Tandem -derivedDataPath "$ROOT/build/DerivedData.noindex" \
  -destination 'platform=macOS' test 2>&1 | tee /tmp/tandem-app-tests.log | grep -E "Executed [0-9]+ tests|error:|TEST (SUCCEEDED|FAILED)" | tail -2
grep -q "TEST SUCCEEDED" /tmp/tandem-app-tests.log || { echo "App tests failed"; exit 1; }
# Keep the development build out of LaunchServices so opening "Tandem" finds the installed app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$ROOT/build/DerivedData.noindex/Build/Products/Debug/Tandem.app" 2>/dev/null || true
echo "✓ All tests passed and the app builds cleanly"
