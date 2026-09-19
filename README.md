# cursor-sdk2api-zig

Zig clone of [cursor-sdk2api](https://github.com/LeviticusNelson/cursor-sdk2api): the same Grok / Claude / OpenAI HTTP surface, without a Node HTTP server.

Cursor inference still goes through Cursor. This repo talks to Cursor via the official **[SDK Bridge](https://cursor.com/docs/sdk/bridge)** (`sdk.v1` Connect JSON), not by copying `@cursor/sdk` internals.

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

Without `CURSOR_API_KEY` (or with `FAKE_CURSOR=1`) the gateway uses a local fake driver so the HTTP surface can be tested. With a key and `cursor-sdk-bridge` 1.0.30 it creates a local agent and streams `enableDeltas`.

See [docs/design.md](docs/design.md).

## Run

```bash
zig build test
zig build run
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
