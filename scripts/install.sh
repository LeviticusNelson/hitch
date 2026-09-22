#!/usr/bin/env sh
# Download a hitch release binary for this OS and CPU, then install the Grok plugin.
# No git clone. Plugin files are inside the binary.
#
#   curl -fsSL https://raw.githubusercontent.com/LeviticusNelson/hitch/main/scripts/install.sh | sh
#
# HITCH_VERSION=v0.2.1  (default: latest GitHub release)
# HITCH_PREFIX=$HOME/.local  (binary is placed in $HITCH_PREFIX/bin)
set -eu

repo="${HITCH_REPO:-LeviticusNelson/hitch}"
version="${HITCH_VERSION:-latest}"
prefix="${HITCH_PREFIX:-${HOME}/.local}"

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) platform=macos ;;
  Linux) platform=linux ;;
  *)
    echo "unsupported OS: $os (Windows: scripts/install.ps1)" >&2
    exit 1
    ;;
esac
case "$arch" in
  arm64|aarch64) cpu=aarch64 ;;
  x86_64|amd64) cpu=x86_64 ;;
  *)
    echo "unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

asset="hitch-${cpu}-${platform}"
if [ "$version" = "latest" ]; then
  url="https://github.com/${repo}/releases/latest/download/${asset}"
else
  url="https://github.com/${repo}/releases/download/${version}/${asset}"
fi

dest="${prefix}/bin/hitch"
mkdir -p "${prefix}/bin"
echo "downloading ${url}"
curl -fL "$url" -o "$dest"
chmod +x "$dest"

echo "installing Grok plugin from the binary"
"$dest" install-plugin
echo "hitch is at $dest"
echo "edit ~/.hitch/env, then: ~/.hitch/fetch-bridge.sh && ~/.hitch/start.sh"
