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

## Quick start

Zig 0.16. Official bridge is optional until you want live Cursor.

```bash
git clone https://github.com/LeviticusNelson/hitch.git
cd hitch
zig build test
zig build --release=fast && ./scripts/install-plugin-bin.sh
./scripts/fetch-bridge.sh          # official binary → ~/.hitch/bridge/ (not in git)
cp env.example ~/.hitch/env        # add your Cursor key
~/.hitch/start.sh                  # or grok-plugin/bin/hitch
```

`GET http://127.0.0.1:8080/health` → `service=hitch`, `cursor.inference=sdk-bridge`.

Install the Grok plugin from a built binary (no source tree required):

```bash
./zig-out/bin/hitch install-plugin
# or, after copying hitch onto PATH:
hitch install-plugin
```

That writes `~/.grok/plugins/hitch`, copies this binary to `bin/hitch`, installs `~/.hitch/start.sh`, and enables hitch in `~/.grok/config.toml` when possible. SessionStart / UserPromptSubmit then start Hitch; they do not compile.

## License

MIT. Cursor’s agent runtime stays theirs; we only spawn the official bridge the operator downloads.
