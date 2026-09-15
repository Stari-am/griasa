#!/bin/bash
# Regenerates the screenshots on the site and in the README, from an invented
# team rather than from whatever is on this Mac.
#
#   ./build.sh && Support/shoot-docs.sh
#
# The app reads its stores from $GRIASA_STORE, so nothing real is moved out of
# the way and nothing has to be put back. A shot run also declines to claim the
# hotkeys, bind the MCP port or start a speech server, so it can be taken while
# the real Griasa is running.
set -euo pipefail
cd "$(dirname "$0")/.."

STORE="${GRIASA_STORE:-/tmp/griasa-demo}"
APP="Griasa Dev.app/Contents/MacOS/Griasa"
[ -x "$APP" ] || { echo "build it first: ./build.sh"; exit 1; }

python3 Support/demo-store.py "$STORE"

shoot() {  # shoot <tab> <WxH> <file> [extra args…]
  local tab="$1" size="$2" out="$3"; shift 3
  GRIASA_STORE="$STORE" "$APP" --open "$tab" --size "$size" \
      --shoot "docs/$out" "$@" > /dev/null
  echo "  docs/$out"
}

shoot history     1280x880  screenshot-history.png
shoot commitments 1080x1520 screenshot-commitments.png
shoot people      1080x820  screenshot-people.png
shoot prep        1000x1000 screenshot-prep.png --demo-brief
