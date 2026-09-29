#!/bin/bash
# Runs a Source (profile A) and a Studio (profile B) side by side on one Mac for
# development: they pair automatically over loopback and the Source streams a
# synthetic test pattern (no Screen Recording permission needed).
#   scripts/dev-two-macs.sh [--mock-ai PORT]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/Tandem.app"
AI_PORT="${2:-18765}"

pkill -f "Tandem.app/Contents/MacOS/Tandem -TandemProfile" 2>/dev/null || true
sleep 1
if [[ "${1:-}" == "--mock-ai" ]]; then
  if ! curl -s -m 1 "http://127.0.0.1:$AI_PORT/v1/models" >/dev/null; then
    python3 "$ROOT/scripts/mock_ai_server.py" "$AI_PORT" >/tmp/tandem-mock-ai.log 2>&1 &
    sleep 1
  fi
fi
open -n "$APP" --env TANDEM_AUTO_APPROVE_PAIRING=1 --args -TandemProfile A -TandemRole source -TandemTestPattern YES -TandemIgnoreLock YES
sleep 2
open -n "$APP" --env TANDEM_AI_BASE_URL="http://127.0.0.1:$AI_PORT/v1/" --args -TandemProfile B -TandemRole studio -TandemAutoPair YES -TandemIgnoreOcclusion YES
echo "Source pid: $(pgrep -f 'TandemProfile A' | head -1)  Studio pid: $(pgrep -f 'TandemProfile B' | head -1)"
