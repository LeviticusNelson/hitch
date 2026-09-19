# cursor-sdk2api-zig design

Date: 2026-09-18

## Goal

A Zig process that Grok Build can point at instead of Node `cursor-sdk2api`, with the same HTTP protocols, faster accept/parse/SSE, and no Node HTTP server. Compare against Node on `:8080`.

This is a **separate git repo**. Node `cursor-sdk2api` stays the gold standard and keeps `Official @cursor/sdk only`.

## What we will not do

- Do not vendor or decompile `@cursor/sdk` (minified local executor, private HTTP/2).
- Do not put this tree inside `cursor-sdk2api` (accidental upstream PRs).
- Do not steal port `8080`.

## Cursor-facing: official SDK Bridge

Cursor documents [SDK Bridge](https://cursor.com/docs/sdk/bridge) for languages without a first-party SDK. Zig is that case.

```
Grok  --HTTP/1.1 SSE-->  zig :8081  --Connect sdk.v1-->  cursor-sdk-bridge  --HTTPS-->  Cursor
```

The bridge binary embeds `@cursor/sdk`. We pin a release whose `sdkVersion` matches Node’s pin (`1.0.30` today). Adapters use HTTP/1.1 Connect (not classic gRPC/H2). Custom tools are callbacks the Zig process hosts; the bridge calls back.

That is how we “make the SDK work in Zig” without copying internals. A native Zig executor is out of scope unless the bridge is proven insufficient.

## Grok-facing protocols (compatibility)

Match Node `docs/PROTOCOL_COMPATIBILITY.md`:

| Method | Path | First ship |
|---|---|---|
| GET | `/health` | milestone 0 |
| GET | `/v1/models`, `/v1/models-v2` | milestone 1 (bridge `ListModels`) |
| GET | `/v1/account` | later |
| POST | `/v1/responses` stream | milestone 2 (Grok) |
| POST | `/v1/responses/compact` | local HMAC, no Cursor Send |
| POST | `/v1/messages` | Claude Code |
| POST | `/v1/chat/completions` | OpenAI SDK |
| POST | `/v1/messages/count_tokens` | local estimate |

Fail closed on the same shapes Node rejects (`previous_response_id`, hosted tools, mixed tool_result, unknown tool ids).

Wire ids: accept `cursor-cidr/grok-4.6` (and siblings), strip prefix before Cursor, echo the prefixed id on HTTP.

## Testing against Node

- Node gold: `http://127.0.0.1:8080`
- Zig: `http://127.0.0.1:8081`
- `scripts/compare-health.sh` then a responses SSE fixture runner that asserts event order and that Zig first-byte time is ≤ Node’s on the same prompt.

## Errors

Reuse Node’s public error types: `invalid_request`, `authentication_error`, `rate_limited`, `cursor_session_lost`, `cursor_empty_turn`, `cursor_upstream_error`, `cursor_timeout`.

## Milestone 0 (landed)

Listen on `127.0.0.1:8081`, `GET /health` JSON, compare script.

## Current (this tree)

HTTP clone of the Grok-facing surface: models, account, messages, chat, responses, compact, local Grok compact-summary intercept.

### Cursor-facing (models only, no Cloud Agents)

Cursor does **not** publish a chat-completions / raw inference API. Cloud Agents (`POST /v1/agents`) are out of scope.

| Call | How |
|---|---|
| Model catalog, account (`GET /v1/models`, `/v1/me`) | Native Zig HTTPS to `https://api.cursor.com` |
| Prompt / stream / custom tools | Official `cursor-sdk-bridge` local agent (backup). Not a Zig clone of `@cursor/sdk` private HTTP/2. |

`FAKE_CURSOR=1` or a missing API key uses the local fake driver for HTTP contract tests.

The Grok-facing process is Zig. Cursor’s **local agent executor** is still the official `cursor-sdk-bridge` binary (Bun-compiled `@cursor/sdk`). GitHub `cursor/sdk-bridge` publishes protos and adapter docs only — there is no server source to port, and we will not decompile the minified local executor. A 100% Zig Cursor executor is not possible with published APIs.

`cursor-sdk-bridge` is `MH_EXECUTE` (not `MH_DYLIB`). `nm -gU` exports only `__mh_execute_header`. There is no C ABI to `@cImport`. The published ABI is Connect HTTP/1.1 JSON (`sdk.v1`). `src/sdk.zig` is that adapter as a Zig module (`zig build` installs `libcursor-sdk-bridge.a`).
