#!/usr/bin/env bash
# Compare a tiny PONG Responses turn on Zig vs optional Node gold.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"
ZIG="${GROK_GATEWAY:-http://127.0.0.1:8080}"
NODE="${NODE_GOLD:-http://127.0.0.1:8081}"
BODY='{"model":"grok-4.6","stream":true,"input":"Reply with exactly the word PONG and do not call tools."}'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -sS --max-time 60 -H 'authorization: Bearer local' -H 'content-type: application/json' \
  -d "$BODY" "$ZIG/v1/responses" >"$tmp/zig.txt" || true
echo "zig bytes=$(wc -c <"$tmp/zig.txt") events=$(rg -c '^event:' "$tmp/zig.txt" || true)"
if curl -fsS --max-time 2 "$NODE/health" >/dev/null 2>&1; then
  curl -sS --max-time 60 -H 'authorization: Bearer local' -H 'content-type: application/json' \
    -d "$BODY" "$NODE/v1/responses" >"$tmp/node.txt" || true
  echo "node bytes=$(wc -c <"$tmp/node.txt") events=$(rg -c '^event:' "$tmp/node.txt" || true)"
else
  echo "node gold not listening on $NODE (skip A/B)"
fi
