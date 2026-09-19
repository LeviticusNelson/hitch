# cursor-sdk2api-zig

Zig clone of [cursor-sdk2api](https://github.com/LeviticusNelson/cursor-sdk2api): the same Grok / Claude / OpenAI HTTP surface, without a Node HTTP server.

Cursor inference still goes through Cursor. This repo talks to Cursor via the official **[SDK Bridge](https://cursor.com/docs/sdk/bridge)** (`sdk.v1` Connect/protobuf), not by copying `@cursor/sdk` internals.

| Process | Bind | Role |
|---|---|---|
| Node `cursor-sdk2api` (gold) | `127.0.0.1:8080` | Existing gateway. Do not change its official-SDK rule. |
| This binary | `127.0.0.1:8081` | Zig HTTP + SSE. |
| `cursor-sdk-bridge` | loopback, spawned | Official Agent create/send/onDelta. |

## Status

Milestone 0: `GET /health` so we can A/B against Node. Protocols and the bridge client are next; see [docs/design.md](docs/design.md).

## Run

```bash
zig build run
# GET http://127.0.0.1:8081/health
```

Compare with a running Node gateway:

```bash
./scripts/compare-health.sh
```

Requires Zig 0.16.
