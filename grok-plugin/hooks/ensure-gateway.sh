#!/usr/bin/env bash
# Start the prebuilt Zig gateway. Never compile.
set -u
cat >/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
if command -v realpath >/dev/null 2>&1; then
  HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
fi
PLUGIN_ROOT="${GROK_PLUGIN_ROOT:-$(cd "$HERE/.." && pwd)}"
BIN="$PLUGIN_ROOT/bin/hitch"
START="${HITCH_START:-$HOME/.hitch/start.sh}"
DATA="${GROK_PLUGIN_DATA:-$HOME/.hitch/plugin}"
mkdir -p "$DATA"
LOG="$DATA/ensure.log"

export CURSOR_SDK2API_ZIG_BIN="$BIN"
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"

{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ensure bin=$BIN"
  if [[ ! -x "$BIN" ]]; then
    echo "missing compiled plugin binary $BIN"
  elif [[ -x "$START" ]]; then
    bash "$START" || echo "start.sh exit $?"
  else
    echo "missing $START"
  fi
} >>"$LOG" 2>&1 || true
exit 0
