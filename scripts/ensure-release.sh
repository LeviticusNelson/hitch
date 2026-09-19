#!/usr/bin/env bash
# Build zig-out/bin/cursor-sdk2api-zig as ReleaseFast when missing or stale.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin${PATH:+:$PATH}"
SRC="${CURSOR_SDK2API_ZIG_SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
OPTIMIZE="${CURSOR_SDK2API_ZIG_OPTIMIZE:-ReleaseFast}"
BIN="${CURSOR_SDK2API_ZIG_BIN:-$SRC/zig-out/bin/cursor-sdk2api-zig}"
STAMP="$SRC/zig-out/bin/.optimize"

need_build=0
if [[ ! -x "$BIN" ]]; then
  need_build=1
elif [[ ! -f "$STAMP" ]] || [[ "$(cat "$STAMP")" != "$OPTIMIZE" ]]; then
  need_build=1
else
  while IFS= read -r -d '' f; do
    need_build=1
    break
  done < <(find "$SRC/src" "$SRC/build.zig" -type f -newer "$BIN" -print0 2>/dev/null)
fi

if [[ "$need_build" == 1 ]]; then
  case "$OPTIMIZE" in
    ReleaseSafe) rel=(--release=safe) ;;
    ReleaseSmall) rel=(--release=small) ;;
    Debug) rel=() ;;
    *) rel=(--release=fast) ;;
  esac
  echo "building cursor-sdk2api-zig ${rel[*]:-Debug}"
  (cd "$SRC" && zig build "${rel[@]}")
  mkdir -p "$(dirname "$STAMP")"
  echo "$OPTIMIZE" >"$STAMP"
else
  echo "release binary ok ($OPTIMIZE) $BIN"
fi
