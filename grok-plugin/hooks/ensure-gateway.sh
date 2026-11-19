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
DIR="${HITCH_DIR:-$HOME/.hitch}"

export HITCH_BIN="$BIN"
export CURSOR_SDK2API_ZIG_BIN="$BIN"
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"

# hitch picks its own port (PORT, then the next free ones, then OS-assigned)
# and publishes it to $DIR/endpoint.json and $DIR/port after binding.
hitch_port() {
  local p=""
  [[ -f "$DIR/port" ]] && p="$(tr -dc '0-9' <"$DIR/port" 2>/dev/null || true)"
  echo "${p:-${PORT:-8080}}"
}

# ok when the published (else configured) port answers /health as hitch,
# status ok, inference sdk-bridge. A published instance_id must match so a
# stale file never vouches for whatever reuses the port. $1 = required pid.
healthy() {
  python3 - "$DIR" "${PORT:-8080}" "${1:-}" >/dev/null 2>&1 <<'PY'
import json, os, sys, urllib.request
d, port, want_pid = sys.argv[1], sys.argv[2], sys.argv[3]
iid = None
try:
    ep = json.load(open(os.path.join(d, "endpoint.json")))
    port, iid = str(int(ep["port"])), ep.get("instance_id")
    if want_pid and str(ep.get("pid")) != want_pid:
        sys.exit(1)
except (OSError, ValueError, KeyError, TypeError):
    if want_pid:
        sys.exit(1)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
h = json.load(opener.open(f"http://127.0.0.1:{port}/health", timeout=1))
ok = h.get("service") == "hitch" and h.get("status") == "ok" and (h.get("cursor") or {}).get("inference") == "sdk-bridge"
sys.exit(0 if ok and (iid is None or h.get("instance_id") == iid) else 1)
PY
}

# First listener on the hitch port whose command is hitch.
hitch_listener_pid() {
  local p
  for p in $(lsof -nP -t -iTCP@127.0.0.1:"$(hitch_port)" -sTCP:LISTEN 2>/dev/null); do
    case "$(ps -p "$p" -o comm= 2>/dev/null)" in
      *hitch*|*cursor-sdk2api-zig*) echo "$p"; return 0 ;;
    esac
  done
  return 1
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
  hitch_listener_pid >/dev/null
}

{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) event=${GROK_HOOK_EVENT:-?} bin=$BIN"
  if healthy; then
    echo "already healthy port=$(hitch_port)"
  elif process_running; then
    echo "hitch process already running; not starting another"
  elif [[ ! -x "$BIN" ]]; then
    echo "missing compiled plugin binary $BIN"
  elif [[ -x "$START" ]]; then
    bash "$START" || echo "start.sh exit $?"
    if healthy; then echo "healthy after start port=$(hitch_port)"; else echo "still down after start"; fi
  else
    echo "missing $START"
  fi
} >>"$LOG" 2>&1 || true
if [[ "$LOG" != "$STABLE_LOG" ]]; then
  cp "$LOG" "$STABLE_LOG" 2>/dev/null || true
fi
exit 0
