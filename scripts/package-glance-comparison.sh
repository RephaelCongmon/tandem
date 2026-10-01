#!/bin/bash
# Package the signed Release build without changing the version or installing it.
set -euo pipefail
glance_root="$(cd "$(dirname "$0")/.." && pwd)"
glance_app="$glance_root/build/Release.noindex/Build/Products/Release/Tandem.app"
glance_stage="$glance_root/dist/Glance Inject Codex"
codesign --verify --deep --strict "$glance_app"
mkdir -p "$glance_stage"
ditto "$glance_app" "$glance_stage/Tandem.app"
cp "$glance_root/scripts/launch-glance-comparison.command" "$glance_stage/Launch Glance Inject Codex.command"
cp "$glance_root/docs/GLANCE_INJECT_COMPARISON.md" "$glance_stage/README.md"
chmod +x "$glance_stage/Launch Glance Inject Codex.command"
ditto -c -k --keepParent "$glance_stage" "$glance_root/dist/Tandem-Glance-Inject-Codex.zip"
echo "Packaged: $glance_root/dist/Tandem-Glance-Inject-Codex.zip"
