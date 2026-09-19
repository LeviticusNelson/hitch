#!/usr/bin/env bash
# Start the Zig cursor-sdk2api gateway (release binary) if it is not healthy.
# Never fail the Grok session: a down gateway is logged, not a blocked prompt.
set -u
cat >/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
if command -v realpath >/dev/null 2>&1; then
  HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
fi
PLUGIN_ROOT="${GROK_PLUGIN_ROOT:-$(cd "$HERE/.." && pwd)}"
SRC="$(cd "$PLUGIN_ROOT/.." && pwd)"
START="${CURSOR_SDK2API_ZIG_START:-$HOME/.cursor-sdk2api-zig/start.sh}"
DATA="${GROK_PLUGIN_DATA:-$HOME/.cursor-sdk2api-zig/plugin}"
mkdir -p "$DATA"
LOG="$DATA/ensure.log"

export CURSOR_SDK2API_ZIG_SRC="$SRC"
export CURSOR_SDK2API_ZIG_OPTIMIZE="${CURSOR_SDK2API_ZIG_OPTIMIZE:-ReleaseFast}"
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"

{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ensure src=$SRC"
  if [[ -x "$START" ]]; then
    bash "$START" || echo "start.sh exit $?"
  else
    echo "missing $START"
  fi
} >>"$LOG" 2>&1 || true
exit 0
