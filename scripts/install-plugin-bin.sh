#!/usr/bin/env bash
# Copy an already-built ReleaseFast binary into grok-plugin/bin/.
# Pass --build to compile first. Grok start/hooks never call this.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$SRC/zig-out/bin/cursor-sdk2api-zig"
DEST="$SRC/grok-plugin/bin/cursor-sdk2api-zig"

if [[ "${1:-}" == "--build" ]]; then
  (cd "$SRC" && zig build --release=fast)
fi
if [[ ! -x "$OUT" ]]; then
  echo "missing $OUT; run: zig build --release=fast && $0" >&2
  exit 1
fi
mkdir -p "$(dirname "$DEST")"
cp "$OUT" "$DEST"
chmod +x "$DEST"
echo "installed $DEST ($(wc -c <"$DEST") bytes)"
