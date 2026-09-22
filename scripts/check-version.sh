#!/usr/bin/env bash
# One semantic version, no leading v, in the files a release must agree on.
# When GITHUB_REF_NAME is a vX.Y.Z tag, it must match that version.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

field() {
  sed -n "$1" "$2" | head -1
}

zon="$(field 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)"
cfg="$(field 's/.*pub const version = "\([^"]*\)".*/\1/p' src/config.zig)"
embed="$(python3 -c 'import json; print(json.load(open("src/plugin-embed/plugin.json"))["version"])')"
plugin="$(python3 -c 'import json; print(json.load(open("grok-plugin/plugin.json"))["version"])')"

for name in zon cfg embed plugin; do
  value="${!name}"
  if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$name is not MAJOR.MINOR.PATCH: $value" >&2
    exit 1
  fi
done
if [[ "$zon" != "$cfg" || "$cfg" != "$embed" || "$embed" != "$plugin" ]]; then
  echo "version mismatch zon=$zon config=$cfg embed=$embed plugin=$plugin" >&2
  exit 1
fi

ref="${GITHUB_REF_NAME:-}"
if [[ "$ref" == v* ]]; then
  tag="${ref#v}"
  if [[ "$tag" != "$cfg" ]]; then
    echo "tag $ref does not match source version $cfg" >&2
    exit 1
  fi
fi

if ! cmp -s env.example src/plugin-embed/env.example; then
  echo "env.example and src/plugin-embed/env.example differ" >&2
  exit 1
fi
if ! cmp -s scripts/fetch-bridge.sh src/plugin-embed/fetch-bridge.sh; then
  echo "scripts/fetch-bridge.sh and src/plugin-embed/fetch-bridge.sh differ" >&2
  exit 1
fi

echo "version $cfg"
