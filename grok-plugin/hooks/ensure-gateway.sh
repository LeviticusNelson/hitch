#!/usr/bin/env bash
# Start the prebuilt hitch gateway if it is not already healthy. Never compile.
set -u
# Grok keeps hook stdin open until the process exits. Reading it deadlocks
# SessionStart/UserPromptSubmit (30s timeout, hitch never starts).
exec 0</dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
if command -v realpath >/dev/null 2>&1; then
  HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
fi
PLUGIN_ROOT="${GROK_PLUGIN_ROOT:-$(cd "$HERE/.." && pwd)}"
BIN="$PLUGIN_ROOT/bin/hitch"
START="${HITCH_START:-$HOME/.hitch/start.sh}"
DATA="${GROK_PLUGIN_DATA:-$HOME/.hitch/plugin}"
mkdir -p "$DATA" "$HOME/.hitch/plugin"
LOG="$DATA/ensure.log"
STABLE_LOG="$HOME/.hitch/plugin/ensure.log"

export HITCH_BIN="$BIN"
export CURSOR_SDK2API_ZIG_BIN="$BIN"
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"

healthy() {
  curl -fsS -m 1 http://127.0.0.1:8080/health 2>/dev/null | python3 -c 'import sys,json; h=json.load(sys.stdin); sys.exit(0 if h.get("status")=="ok" and (h.get("cursor") or {}).get("inference")=="sdk-bridge" else 1)' 2>/dev/null
}

{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) event=${GROK_HOOK_EVENT:-?} bin=$BIN"
  if healthy; then
    echo "already healthy"
  elif [[ ! -x "$BIN" ]]; then
    echo "missing compiled plugin binary $BIN"
  elif [[ -x "$START" ]]; then
    bash "$START" || echo "start.sh exit $?"
    if healthy; then echo "healthy after start"; else echo "still down after start"; fi
  else
    echo "missing $START"
  fi
} >>"$LOG" 2>&1 || true
if [[ "$LOG" != "$STABLE_LOG" ]]; then
  cp "$LOG" "$STABLE_LOG" 2>/dev/null || true
fi
exit 0
