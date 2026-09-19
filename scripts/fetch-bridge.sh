#!/usr/bin/env bash
# Download cursor-sdk-bridge 1.0.30 (matches Node @cursor/sdk pin) into
# ~/.cursor-sdk2api-zig/bridge/v1.0.30/
set -euo pipefail
VERSION="${CURSOR_SDK_BRIDGE_VERSION:-1.0.30}"
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "unsupported OS: $OS" >&2; exit 1 ;;
esac
case "$ARCH" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=x64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac
dest="${CURSOR_SDK2API_ZIG_HOME:-$HOME/.cursor-sdk2api-zig}/bridge/v${VERSION}"
mkdir -p "$dest"
archive="cursor-sdk-bridge-standalone-${os}-${arch}.tar.gz"
url="https://github.com/cursor/sdk-bridge/releases/download/v${VERSION}/${archive}"
echo "downloading $url"
curl -fsSL "$url" -o "$dest/$archive"
tar -xzf "$dest/$archive" -C "$dest"
chmod +x "$dest/bin/cursor-sdk-bridge"
"$dest/bin/cursor-sdk-bridge" --help | head -5
echo "installed $dest/bin/cursor-sdk-bridge"
echo "export CURSOR_SDK_BRIDGE=$dest/bin/cursor-sdk-bridge"
