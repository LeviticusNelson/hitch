#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"
DIR="${HITCH_DIR:-$HOME/.hitch}"
PID_FILE="$DIR/gateway.pid"
LOCK_DIR="$DIR/gateway.lock.d"

if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    echo "stopped pid=$pid"
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  else
    echo "stale pid file ($pid)"
  fi
  rm -f "$PID_FILE"
else
  echo "no pid file"
fi

if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  listen_pid=$(lsof -nP -t -iTCP:8080 -sTCP:LISTEN | head -1)
  cmd=$(ps -p "$listen_pid" -o comm= 2>/dev/null || true)
  if [[ "$cmd" == *hitch* || "$cmd" == *cursor-sdk2api-zig* ]]; then
    kill "$listen_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$listen_pid" 2>/dev/null || true
    echo "cleared hitch listen pid=$listen_pid"
  fi
fi
# Reap leftover official bridge children (they survive SIGKILL of hitch and leak RAM).
reap_bridges() {
  local ws="${HITCH_WORKSPACE:-$DIR/workspace}"
  local legacy_ws="$HOME/.cursor-sdk2api-zig/workspace"
  ps -axo pid=,command= | while read -r pid cmd; do
    case "$cmd" in
      *cursor-sdk-bridge*)
        case "$cmd" in
          *"--workspace $ws"*|*"--workspace $legacy_ws"*)
            kill "$pid" 2>/dev/null || true
            sleep 0.05
            kill -9 "$pid" 2>/dev/null || true
            echo "reaped bridge pid=$pid"
            ;;
        esac
        ;;
    esac
  done
}
reap_bridges
rmdir "$LOCK_DIR" 2>/dev/null || true
