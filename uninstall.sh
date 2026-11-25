#!/usr/bin/env bash
# Uninstall the Herdr-Vibe integration.
#
# - removes the herdr-vibe block from ~/.vibe/hooks.toml (between the
#   >>>/<<< herdr-vibe markers), preserving everything else
# - removes ~/.vibe/hooks/herdr.py (only if it is our copy)
set -euo pipefail

VIBE_HOME="${VIBE_HOME:-$HOME/.vibe}"
HOOKS_DIR="$VIBE_HOME/hooks"
HOOK_SCRIPT="$HOOKS_DIR/herdr.py"
HOOKS_TOML="$VIBE_HOME/hooks.toml"
BEGIN_MARKER="# >>> herdr-vibe >>>"
END_MARKER="# <<< herdr-vibe <<<"

echo "Herdr-Vibe uninstaller"

if [ -f "$HOOKS_TOML" ] && grep -q "$BEGIN_MARKER" "$HOOKS_TOML"; then
  TMP_TOML="$(mktemp)"
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    skip == 0   { print }
  ' "$HOOKS_TOML" > "$TMP_TOML"
  cat "$TMP_TOML" > "$HOOKS_TOML"
  rm -f "$TMP_TOML"
  echo "  removed hook block from $HOOKS_TOML"
else
  echo "  no herdr-vibe block found in $HOOKS_TOML (nothing to do)"
fi

# Only remove the script if it is the integration's copy, not a user fork.
if [ -f "$HOOK_SCRIPT" ] && grep -q "Report Vibe CLI lifecycle state to Herdr" "$HOOK_SCRIPT"; then
  rm -f "$HOOK_SCRIPT"
  echo "  removed $HOOK_SCRIPT"
elif [ -f "$HOOK_SCRIPT" ]; then
  echo "  left $HOOK_SCRIPT in place (it does not look like the integration's copy)"
fi

# Best-effort: release our agent registration on the current pane, if any.
if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  herdrbin="${HERDR_BIN_PATH:-herdr}"
  "$herdrbin" pane release-agent "$HERDR_PANE_ID" \
    --source vibe-hooks --agent vibe >/dev/null 2>&1 || true
  echo "  released agent registration on pane $HERDR_PANE_ID (if it was ours)"
fi

echo "Done. Restart Vibe sessions to stop reporting."
