#!/usr/bin/env bash
# Run builtin + residual smoke. pipefail so | tee cannot hide a FAIL exit.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GROK_GATEWAY="${GROK_GATEWAY:-http://127.0.0.1:8080}"
OUT="${1:-}"
run() {
  if [[ -n "$OUT" ]]; then
    python3 "$1" | tee -a "$OUT"
  else
    python3 "$1"
  fi
}
cd "$ROOT"
run "$ROOT/scripts/grok_interface_smoke.py"
run "$ROOT/scripts/residual_smoke.py"
