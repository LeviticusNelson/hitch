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

# A live hitch process must not be replaced. Connection errors only start
# hitch when nothing is running.
process_running() {
  local pidfile="${HITCH_PID_FILE:-$HOME/.hitch/gateway.pid}"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(tr -d '[:space:]' <"$pidfile" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  local listen_pid cmd
  listen_pid="$(lsof -nP -t -iTCP:8080 -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  if [[ -n "$listen_pid" ]]; then
    cmd="$(ps -p "$listen_pid" -o comm= 2>/dev/null || true)"
    [[ "$cmd" == *hitch* ]]
    return
  fi
  return 1
}

{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) event=${GROK_HOOK_EVENT:-?} bin=$BIN"
  if healthy; then
    echo "already healthy"
  elif process_running; then
    echo "hitch process already running; not starting another"
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
