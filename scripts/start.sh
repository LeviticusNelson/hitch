#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"
DIR="${HITCH_DIR:-$HOME/.hitch}"
LEGACY="$HOME/.cursor-sdk2api-zig"
mkdir -p "$DIR"
if [[ ! -e "$DIR/env" && -f "$LEGACY/env" ]]; then
  ln -sfn "$LEGACY/env" "$DIR/env"
  ln -sfn "$LEGACY/bridge" "$DIR/bridge" 2>/dev/null || true
  ln -sfn "$LEGACY/workspace" "$DIR/workspace" 2>/dev/null || true
  ln -sfn "$LEGACY/logs" "$DIR/logs" 2>/dev/null || true
fi
ENV_FILE="${HITCH_ENV:-$DIR/env}"
LOG_DIR="$DIR/logs"
PID_FILE="$DIR/gateway.pid"
LOCK_DIR="$DIR/gateway.lock.d"
SRC="${HITCH_SRC:-$HOME/hitch}"
if [[ -n "${HITCH_BIN:-}" ]]; then
  BIN="$HITCH_BIN"
elif [[ -x "$HOME/.grok/plugins/hitch/bin/hitch" ]]; then
  BIN="$HOME/.grok/plugins/hitch/bin/hitch"
elif [[ -x "$HOME/.hitch/bin/hitch" ]]; then
  BIN="$HOME/.hitch/bin/hitch"
else
  BIN="$SRC/grok-plugin/bin/hitch"
fi
mkdir -p "$LOG_DIR" "$DIR/workspace"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE" >&2
  exit 1
fi
if [[ ! -x "$BIN" ]]; then
  echo "missing compiled binary $BIN (copy a ReleaseFast hitch into grok-plugin/bin/; do not zig build from start.sh)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Drop orphan sdk-bridge processes from earlier hitch lives before we spawn a new one.
reap_orphan_bridges() {
  local ws="${WORKSPACE_DIR:-$DIR/workspace}"
  local legacy_ws="$HOME/.cursor-sdk2api-zig/workspace"
  ps -axo pid=,ppid=,command= | while read -r pid ppid cmd; do
    [[ "$cmd" == *cursor-sdk-bridge* ]] || continue
    [[ "$ppid" == "1" ]] || continue
    case "$cmd" in
      *"--workspace $ws"*|*"--workspace $legacy_ws"*)
        kill "$pid" 2>/dev/null || true
        sleep 0.05
        kill -9 "$pid" 2>/dev/null || true
        echo "reaped orphan bridge pid=$pid"
        ;;
    esac
  done
}
reap_orphan_bridges

pid_alive() {
  local p="${1:-}"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

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

if [[ -f "$PID_FILE" ]]; then
  old="$(tr -d ' \t\r\n' <"$PID_FILE" 2>/dev/null || true)"
  if pid_alive "$old"; then
    if healthy; then
      echo "hitch already running pid=$old"
      exit 0
    fi
    echo "waiting for hitch pid=$old to become healthy"
    for _ in $(seq 1 40); do
      if healthy; then
        echo "hitch already running pid=$old"
        exit 0
      fi
      pid_alive "$old" || break
      sleep 0.25
    done
    if pid_alive "$old"; then
      echo "replacing unhealthy hitch pid=$old"
      kill "$old" 2>/dev/null || true
      sleep 0.2
      kill -9 "$old" 2>/dev/null || true
    fi
  else
    echo "stale pid file pid=$old"
  fi
  rm -f "$PID_FILE"
fi
# No live pid file. Adopt a hitch that already serves; another service on
# PORT is not an error because hitch moves to a free port by itself.
if healthy; then
  listen_pid="$(hitch_listener_pid || true)"
  [[ -n "$listen_pid" ]] && echo "$listen_pid" >"$PID_FILE"
  echo "hitch already listening pid=${listen_pid:-?} port=$(hitch_port)"
  exit 0
fi
# Crash leftovers: empty mkdir lock with a dead pid must not block Grok SessionStart.
if [[ -d "$LOCK_DIR" ]]; then
  rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "hitch already running (lock $LOCK_DIR)" >&2
  exit 1
fi

export HOST="${HOST:-127.0.0.1}"
export PORT="${PORT:-8080}"
export AUTH_MODE="${AUTH_MODE:-managed}"
export STATE_DIR="${STATE_DIR:-$DIR}"
export WORKSPACE_DIR="${WORKSPACE_DIR:-$DIR/workspace}"
export TOOL_CALLBACK_PORT="${TOOL_CALLBACK_PORT:-18771}"
export HITCH_ENDPOINT_DIR="$DIR"
rm -f "$DIR/endpoint.json" "$DIR/port"

nohup "$BIN" >>"$LOG_DIR/stdout.log" 2>>"$LOG_DIR/stderr.log" &
echo $! >"$PID_FILE"
new_pid=$!
echo "started pid=$new_pid bin=$BIN"

for _ in $(seq 1 40); do
  if healthy "$new_pid"; then
    port="$(hitch_port)"
    [[ "$port" == "$PORT" ]] || echo "port $PORT is served by another process; hitch is on $port" >&2
    echo "healthy port=$port endpoint=$DIR/endpoint.json"
    exit 0
  fi
  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "hitch exited before health check" >&2
    rm -f "$PID_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    exit 1
  fi
  sleep 0.25
done
echo "hitch started but /health is not ok/sdk-bridge" >&2
rmdir "$LOCK_DIR" 2>/dev/null || true
exit 1
