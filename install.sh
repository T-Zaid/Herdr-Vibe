#!/usr/bin/env bash
# Install the Herdr-Vibe integration for the Vibe CLI.
#
# - copies hooks/herdr.py to ~/.vibe/hooks/herdr.py
# - appends the herdr-vibe hook block to ~/.vibe/hooks.toml (idempotent,
#   preserving any existing hooks), rewriting @PYTHON@ to a detected python3
#
# Works on Git Bash (Windows), macOS and Linux. Run from the repo root:
#   ./install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIBE_HOME="${VIBE_HOME:-$HOME/.vibe}"
HOOKS_DIR="$VIBE_HOME/hooks"
HOOK_SCRIPT="$HOOKS_DIR/herdr.py"
HOOKS_TOML="$VIBE_HOME/hooks.toml"
BEGIN_MARKER="# >>> herdr-vibe >>>"
END_MARKER="# <<< herdr-vibe <<<"

echo "Herdr-Vibe installer"
echo "  VIBE_HOME : $VIBE_HOME"

# --- checks -----------------------------------------------------------------

if ! command -v herdr >/dev/null 2>&1 && [ -z "${HERDR_BIN_PATH:-}" ]; then
  echo "error: herdr CLI not found on PATH and HERDR_BIN_PATH is not set." >&2
  echo "       Install Herdr (https://herdr.dev) or run this from a Herdr pane." >&2
  exit 1
fi

if [ "${HERDR_ENV:-}" != "1" ]; then
  echo "note: not running inside a Herdr pane (HERDR_ENV!=1); installing anyway —"
  echo "      the hook is a no-op outside Herdr, so that is safe."
fi

PYTHON=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      PYTHON="$candidate"
      break
    fi
  fi
done
if [ -z "$PYTHON" ]; then
  echo "error: no Python 3.8+ interpreter found (tried python3, python, py)." >&2
  exit 1
fi
echo "  python    : $PYTHON ($($PYTHON --version 2>&1))"

# --- files ------------------------------------------------------------------

mkdir -p "$HOOKS_DIR"
cp "$REPO_DIR/hooks/herdr.py" "$HOOK_SCRIPT"
chmod +x "$HOOK_SCRIPT" 2>/dev/null || true
echo "  installed : $HOOK_SCRIPT"

if [ ! -f "$HOOKS_TOML" ]; then
  : > "$HOOKS_TOML"
fi

if grep -q "$BEGIN_MARKER" "$HOOKS_TOML"; then
  # Already installed: refresh the block in place (upgrade path).
  TMP_TOML="$(mktemp)"
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    skip == 0   { print }
  ' "$HOOKS_TOML" > "$TMP_TOML"
  cat "$TMP_TOML" > "$HOOKS_TOML"
  rm -f "$TMP_TOML"
  echo "  updated   : replaced existing herdr-vibe block in $HOOKS_TOML"
else
  # Make sure the file ends with a newline before appending.
  [ -s "$HOOKS_TOML" ] && [ -n "$(tail -c 1 "$HOOKS_TOML")" ] && echo >> "$HOOKS_TOML"
  echo "  added     : herdr-vibe hook block in $HOOKS_TOML"
fi

{
  echo "$BEGIN_MARKER"
  sed "s|@PYTHON@|$PYTHON|g" "$REPO_DIR/hooks.toml"
  echo "$END_MARKER"
} >> "$HOOKS_TOML"

echo
echo "Done. Restart Vibe (or run /reload-ish: just start a new session) and the"
echo "pane lifecycle — idle / working / blocked / release — is reported to Herdr."
echo "Reports are self-serialized (seq + source), so overlapping reporters are safe."
