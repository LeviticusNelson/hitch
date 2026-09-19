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

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "hitch already running pid=$(cat "$PID_FILE")"
  exit 0
fi
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  listen_pid=$(lsof -nP -t -iTCP:8080 -sTCP:LISTEN | head -1)
  cmd=$(ps -p "$listen_pid" -o comm= 2>/dev/null || true)
  if [[ "$cmd" == *hitch* || "$cmd" == *cursor-sdk2api-zig* ]]; then
    echo "$listen_pid" >"$PID_FILE"
    echo "hitch already listening pid=$listen_pid"
    exit 0
  fi
  echo "port 8080 already in use by $cmd pid=$listen_pid" >&2
  exit 1
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "hitch already running (lock $LOCK_DIR)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export HOST="${HOST:-127.0.0.1}"
export PORT="${PORT:-8080}"
export AUTH_MODE="${AUTH_MODE:-managed}"
export STATE_DIR="${STATE_DIR:-$DIR}"
export WORKSPACE_DIR="${WORKSPACE_DIR:-$DIR/workspace}"
export TOOL_CALLBACK_PORT="${TOOL_CALLBACK_PORT:-18771}"

nohup "$BIN" >>"$LOG_DIR/stdout.log" 2>>"$LOG_DIR/stderr.log" &
echo $! >"$PID_FILE"
echo "started pid=$! bin=$BIN"

for _ in $(seq 1 40); do
  if curl -fsS -m 1 http://127.0.0.1:8080/health 2>/dev/null | python3 -c 'import sys,json; h=json.load(sys.stdin); sys.exit(0 if h.get("status")=="ok" and (h.get("cursor") or {}).get("inference")=="sdk-bridge" else 1)' 2>/dev/null; then
    echo "healthy"
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
