#!/usr/bin/env bash
# A/B GET /health: Node gold on :8080 vs Zig on :8081.
set -euo pipefail
NODE="${NODE_URL:-http://127.0.0.1:8080}"
ZIG="${ZIG_URL:-http://127.0.0.1:8081}"

node_body=$(curl -fsS -m 3 "$NODE/health") || {
  echo "FAIL: Node $NODE/health not up (start cursor-sdk2api first)" >&2
  exit 1
}
zig_body=$(curl -fsS -m 3 "$ZIG/health") || {
  echo "FAIL: Zig $ZIG/health not up (zig build run)" >&2
  exit 1
}

echo "NODE $NODE"
echo "$node_body"
echo
echo "ZIG  $ZIG"
echo "$zig_body"
echo

python3 - "$node_body" "$zig_body" <<'PY'
import json, sys
node = json.loads(sys.argv[1])
zig = json.loads(sys.argv[2])
ok = True
if node.get("status") != "ok":
    print("FAIL: Node status", node.get("status"))
    ok = False
if zig.get("status") != "ok":
    print("FAIL: Zig status", zig.get("status"))
    ok = False
if zig.get("service") != "hitch":
    print("FAIL: Zig service", zig.get("service"))
    ok = False
if ok:
    print("PASS: both /health return status=ok")
    raise SystemExit(0)
raise SystemExit(1)
PY
