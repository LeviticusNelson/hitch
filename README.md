<p align="center">
  <strong>hitch</strong>
</p>

<p align="center">
  Cursor models, on the APIs your harness already speaks — in Zig.
</p>

<p align="center">
  <a href="LICENSE">MIT</a> ·
  Inspired by <a href="https://github.com/Sunnyender-org/cursor-sdk2api">cursor-sdk2api</a>
</p>

**Hitch** is an independent Zig HTTP gateway. It exposes official Cursor models as OpenAI Responses, Anthropic Messages, and OpenAI Chat Completions so Grok Build, Claude Code, Codex, and other harnesses can keep their own tools.

It is a rewrite of the **gateway**, not a clone of Cursor. Inference still runs in the official [`cursor-sdk-bridge`](https://cursor.com/docs/sdk/bridge) process (Connect `sdk.v1`). This repo does not vendor or decompile `@cursor/sdk`.

Hitch is **not affiliated with Cursor, xAI, Anthropic, or OpenAI**. Protocol gold and compact-summary behavior follow MIT-licensed [cursor-sdk2api](https://github.com/Sunnyender-org/cursor-sdk2api) (Sunnyender-org) — see [NOTICE.md](NOTICE.md).

## Status

| Harness | API | Hitch |
|---|---|---|
| **Grok Build** | `/v1/responses` | Daily driver on `127.0.0.1:8080` |
| Claude Code | `/v1/messages` | Routes exist; CLI dogfood **not done** |
| Codex | `/v1/responses` | Contract **not done** |
| OpenCode, Copilot, Aider, Continue, Cline | OpenAI / Anthropic | **Not done** |

See [TODO.md](TODO.md).

## Install the binary

You do not need to clone the repository. `hitch install-plugin` writes the Grok plugin, hooks, start and stop scripts, `~/.hitch/env`, and `~/.hitch/fetch-bridge.sh` from bytes stored in the binary.

Release assets (tag `vX.Y.Z`):

| OS | CPU | Asset |
|---|---|---|
| macOS | Apple Silicon (arm64) | `hitch-aarch64-macos` |
| macOS | Intel (x86_64) | `hitch-x86_64-macos` |
| Linux | arm64 | `hitch-aarch64-linux` |
| Linux | x86_64 | `hitch-x86_64-linux` |
| Windows | arm64 | `hitch-aarch64-windows.exe` |
| Windows | x86_64 | `hitch-x86_64-windows.exe` |

### Shell installer

macOS or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/LeviticusNelson/hitch/main/scripts/install.sh | sh
```

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/LeviticusNelson/hitch/main/scripts/install.ps1 | iex
```

Pin a version with `HITCH_VERSION=v0.2.1`. The script picks the asset from `uname` or `PROCESSOR_ARCHITECTURE`, puts `hitch` on `~/.local/bin` (or `%LOCALAPPDATA%\hitch` on Windows), and runs `hitch install-plugin`.

### Homebrew tap

The formula lives at `Formula/hitch.rb` in this repository. Tap that URL (this is not a `homebrew-hitch` repo).

```bash
brew tap LeviticusNelson/hitch https://github.com/LeviticusNelson/hitch
brew install hitch
hitch install-plugin
```

`Formula/hitch.rb` checksums are placeholders until the `v0.2.1` assets exist. After the release, replace each `sha256` with `shasum -a 256` of that asset. Until then use the shell installer or a direct download.

### Direct download

```bash
# Apple Silicon. Swap the asset name from the table for other machines.
curl -fL -o hitch https://github.com/LeviticusNelson/hitch/releases/latest/download/hitch-aarch64-macos
chmod +x hitch
./hitch install-plugin
```

Then edit `~/.hitch/env`, download the official bridge, and start:

```bash
# set CURSOR_API_KEY in ~/.hitch/env
~/.hitch/fetch-bridge.sh
~/.hitch/start.sh
```

`GET http://127.0.0.1:8080/health` → `service=hitch`, `cursor.inference=sdk-bridge`.

Windows has no `start.sh`. Run `hitch.exe` in a terminal after editing `%USERPROFILE%\.hitch\env`. The Grok hook scripts are bash. On Windows, run them from Git Bash, or start `hitch.exe` yourself.

### From source

Zig 0.16. The compiled binary is not in git.

```bash
git clone https://github.com/LeviticusNelson/hitch.git
cd hitch
zig build test
zig build --release=fast
./zig-out/bin/hitch install-plugin
```

A tag `vX.Y.Z` must match the version in `build.zig.zon`, `src/config.zig`, and both `plugin.json` files (`./scripts/check-version.sh`). Pushing that tag builds the assets in the table.

## License

MIT. Cursor’s agent runtime stays theirs; we only spawn the official bridge the operator downloads.
