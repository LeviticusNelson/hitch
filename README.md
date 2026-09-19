# cursor-sdk2api-zig

Zig clone of [cursor-sdk2api](https://github.com/LeviticusNelson/cursor-sdk2api): the same Grok / Claude / OpenAI HTTP surface, without a Node HTTP server.

Cursor inference still goes through Cursor. This repo talks to Cursor via the official **[SDK Bridge](https://cursor.com/docs/sdk/bridge)** (`sdk.v1` Connect JSON), not by copying `@cursor/sdk` internals.

There is **no C ABI** to link: `cursor-sdk-bridge` is a Bun-compiled executable, not a dylib. The Zig module `cursor-sdk-bridge` (`src/sdk.zig`) is the Connect adapter library Cursor documents for languages without a first-party SDK.

| Process | Bind | Role |
|---|---|---|
| Node `cursor-sdk2api` (gold) | `127.0.0.1:8080` | Existing gateway. Do not change its official-SDK rule. |
| This binary | `127.0.0.1:8081` | Zig HTTP + SSE. |
| `cursor-sdk-bridge` | loopback, spawned | Official Agent create/send/onDelta. |

## Status

Grok-facing routes are implemented:

- `GET /health`, `/v1/models`, `/v1/models-v2`, `/v1/account`
- `POST /v1/responses`, `/v1/responses/compact`
- `POST /v1/messages`, `/v1/messages/count_tokens`
- `POST /v1/chat/completions`

**Models only, no Cloud Agents.** Catalog and account are native Zig HTTPS to `https://api.cursor.com` (`GET /v1/models`, `GET /v1/me`). Cursor does not publish a completions API, so prompt/stream still uses official `cursor-sdk-bridge` as backup when that binary is installed. This repo does not spawn Cloud Agents and does not clone `@cursor/sdk` internals.

Without `CURSOR_API_KEY` (or with `FAKE_CURSOR=1`) the gateway uses a local fake driver so the HTTP surface can be tested.

See [docs/design.md](docs/design.md).

## Run

Daily driver on `127.0.0.1:8080` (Grok CIDR models). The Grok plugin `grok-plugin/` starts a **ReleaseFast** binary when a session starts:

```bash
zig build test
zig build --release=fast
~/.cursor-sdk2api-zig/start.sh   # builds --release=fast if the binary is missing/stale
# GET http://127.0.0.1:8080/health  → service=cursor-sdk2api-zig, cursor.inference=sdk-bridge
```

`zig build` / `zig build run` default to ReleaseFast (`-Drelease`). Debug:

```bash
zig build -Drelease=false run
# GET http://127.0.0.1:8081/health
```

Install the pinned bridge (optional, for live Cursor):

```bash
./scripts/fetch-bridge.sh
export CURSOR_SDK_BRIDGE="$HOME/.cursor-sdk2api-zig/bridge/v1.0.30/bin/cursor-sdk-bridge"
export CURSOR_API_KEY=key_...
zig build run
```

Compare with a running Node gateway:

```bash
./scripts/compare-health.sh
```

Requires Zig 0.16. Do not push unless asked.
