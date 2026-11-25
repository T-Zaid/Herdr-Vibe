#!/usr/bin/env bash
# End-to-end test of the Herdr-Vibe reporter against the live Herdr server.
# Run from any Herdr pane:  ./test.sh
#
# Uses a fake session id; safe to re-run (reports are seq-serialized and the
# final step releases the pane's registration). Verify states with:
#   herdr agent get "$HERDR_PANE_ID"
set -euo pipefail

SCRIPT="${HERDR_VIBE_SCRIPT:-$HOME/.vibe/hooks/herdr.py}"
if [ ! -f "$SCRIPT" ]; then
  echo "error: $SCRIPT not found — run ./install.sh first, or point" >&2
  echo "       HERDR_VIBE_SCRIPT at hooks/herdr.py in the repo." >&2
  exit 1
fi

report() { # report <event> <json>
  echo "$2" | python "$SCRIPT" "$1"
}

if [ "${HERDR_ENV:-}" != "1" ] || [ -z "${HERDR_PANE_ID:-}" ]; then
  echo "error: run this inside a Herdr pane (HERDR_ENV=1, HERDR_PANE_ID set)." >&2
  exit 1
fi

echo "Testing on pane $HERDR_PANE_ID with fake session 'herdr-vibe-selftest'."

echo "[1/5] session_start -> idle"
report start '{"session_id":"herdr-vibe-selftest","transcript_path":"","cwd":"'"$PWD"'"}'
herdr agent get "$HERDR_PANE_ID"

echo "[2/5] pre_agent -> working"
report working '{"session_id":"herdr-vibe-selftest","prompt":"selftest"}'
herdr agent get "$HERDR_PANE_ID"

echo "[3/5] approval_requested -> blocked"
report notify '{"session_id":"herdr-vibe-selftest","notification_type":"approval_requested","message":"selftest approval"}'
herdr agent get "$HERDR_PANE_ID"

echo "[4/5] turn_completed -> idle"
report notify '{"session_id":"herdr-vibe-selftest","notification_type":"turn_completed"}'
herdr agent get "$HERDR_PANE_ID"

echo "[5/5] session_end(exit) -> release"
report end '{"session_id":"herdr-vibe-selftest","reason":"exit"}'
if herdr agent get "$HERDR_PANE_ID" >/dev/null 2>&1; then
  echo "note: pane still has an agent (it may be a real one Herdr detected);"
  echo "      check `herdr agent get $HERDR_PANE_ID` — it should no longer be source vibe-hooks."
else
  echo "released OK"
fi

echo "All steps ran. states above should read idle -> working -> blocked -> idle."
