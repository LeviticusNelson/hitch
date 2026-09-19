# Zig bridge TODO

Tracked build list for `cursor-sdk2api-zig` vs Node gold (`cursor-sdk2api` / `docs/PROTOCOL_COMPATIBILITY.md`).

**Status:** `done` · `partial` · `missing` · `skip` (out of scope)

Last reviewed: 2026-09-19 (images, catalog cache, digest replay, health capacity, tool_choice, effort 409).

---

## Already green (keep green)

| Item | Status | Notes |
|---|---|---|
| Core routes | done | Official + residual smoke |
| Streaming SSE + thinking | done | |
| Client function tools + parallel + interleaved / trailing-only | done | |
| Namespaced tools | done | |
| Fail-closed previous_response_id / store / mixed / hosted | done | |
| Health under concurrent streams | done | |
| Official cursor-sdk-bridge inference | done | |
| Grok plugin binary + session start hook | done | |
| Live catalog cache (no Fake-4 fallback) | done | `5d64c50`; warm at start; 5 min TTL; concurrent GET /v1/models |
| Prefixed ids strip for Cursor, echo on HTTP | done | `models.upstreamCursorModelId` + catalog aliases |

---

## P0 — Grok Build reliability

### 1. Vision / images

| Item | Status | Notes |
|---|---|---|
| Base64 `input_image` on `/v1/responses` | done | Parsed to SDK `{data,mimeType}` on Send |
| Base64 `image_url` on `/v1/chat/completions` | done | |
| Images inside Messages content blocks | done | Anthropic `{type:image,source:{base64}}` |
| Tool-result images (text + base64 image parts) | partial | Text collected; image parts in tool output still text-join |
| Reject remote image URLs with 422 | done | Residual smoke |
| Smoke fixtures for each path | done | `residual_smoke.py` |

### 2. Catalog consistency

| Item | Status | Notes |
|---|---|---|
| Never serve Fake’s 4-model stub when a live cache exists | done | `chooseModels` + Catalog cache |
| Stable full catalog under concurrent `/v1/models` | done | Residual concurrent probe |
| Prefixed ids | done | |

### 3. Session continuity

| Item | Status | Notes |
|---|---|---|
| `x-cursor-session-id` completed follow-up (`Agent.resume`) E2E | done | Reuse agent; Send last user turn only |
| Ordinary next turn without session header | partial | Lineage reuse when session id matches; no transcript-hash coordinator |
| Pending-tool restart after gateway kill | missing | Waiters are in-memory; jsonl persist still open |
| Duplicate-same request digest replay | done | SHA-256 of body, non-stream |
| Persist lineage across process restart | missing | agents map is process-local |

### 4. Long-session / compact

| Item | Status | Notes |
|---|---|---|
| compaction_trigger + HMAC compact token | done | Local compact route |
| Cold-rebuild Send clipped to compact window | done | `clip(flatten, sdkPromptMaxCharsForModel)` |
| Completed Responses usage cache + reasoning detail | done | Always present (`cached_tokens` / `reasoning_tokens`) |

### 5. Error parity with Node

| Item | Status | Notes |
|---|---|---|
| Public error set | done | Types + HTTP map; session_conflict 409; upstream 502 |
| Mid-stream error → terminal SSE | done | `runBridge` writes `error` event if `reply.started` |
| Concrete `invalid_request` reasons | done | Images, tool_choice, mixed, unknown ids |

---

## P1 — Protocol depth

### 6. Tool surface

| Item | Status | Notes |
|---|---|---|
| `tool_choice` / `parallel_tool_calls=false` / `disable_parallel_tool_use` | done | Parsed; `none` is 422 |
| Custom / freeform tools → `custom_tool_call` SSE | done | Emit path |
| `additional_tools` + Lite dedupe | done | Namespace + duplicate sdk_name drop |
| `reasoning_effort` / `cursor_model_params` bound; 409 on change | done | Bound per session on CreateAgent |

### 7. Chat + Messages parity

| Item | Status | Notes |
|---|---|---|
| Chat `reasoning_content`, `stream_options.include_usage` | done | |
| Messages historical `tool`/`function` roles, system/developer order | done | parseTranscript |
| Count-tokens estimated; SDK usage authoritative | done | |

### 8. Auth modes

| Item | Status | Notes |
|---|---|---|
| BYOK | done | |
| Managed `GATEWAY_ACCESS_KEY` + pool | partial | Single `MANAGED_CURSOR_KEY`; no round-robin pool |
| Continuation stuck to original credential | partial | One bridge api_key per process |
| Managed failover before response starts | missing | Health advertises flag in managed mode |

---

## P2 — Ops / polish

### 9. Observability & ops

| Item | Status | Notes |
|---|---|---|
| Structured logs without secrets | partial | Health not logged; keys not printed |
| Graceful shutdown (`shutting_down`) | partial | Health field + `active_runs`; stop.sh SIGTERM |
| Active-run / per-credential limits | partial | `capacity.global_active_runs` counted; no cap yet |
| Health: `transcript_tool_recovery`, `stale_auth_recovery`, `managed_account_failover` | done | Advertised on `/health` |

### 10. Testing / CI

| Item | Status | Notes |
|---|---|---|
| Zig↔Node SSE fixture A/B | partial | `compare-health.sh`; Zig is daily driver `:8080` |
| Live smoke matrix | partial | `run-smoke.sh` + residual + stability_matrix |
| Image + resume in automated suite | partial | Image 422 + base64 in residual; kill/restart still manual |
| Keep smoke green on binary refresh | done | |

### 11. Packaging

| Item | Status |
|---|---|
| Pin cursor-sdk-bridge 1.0.30 | done |
| One-command refresh | done |
| Document :8080 vs :8081 | done |

---

## Explicitly out of scope (`skip`)

| Item | Reason |
|---|---|
| Cloud Agents (`POST /v1/agents`) | Design: models only |
| Hosted Cursor tools | Fail closed |
| OpenAI `previous_response_id` / `store=true` | Fail closed |
| Native Zig Cursor executor / decompile | No C ABI |
| Operator `/console/` | Node-only |
| Sand / BeefAPI / type64 | Not Zig day-1 |

---

## Still open (next)

1. Pending-tool jsonl persist + load after kill (`local.force=true`)
2. Transcript-hash ordinary-turn coordinator without session header
3. Managed account pool round-robin + failover
4. Per-credential concurrency cap
5. Node A/B SSE fixture in CI

---

## Smoke / evidence

```bash
cd /Users/levi/cursor-sdk2api-zig
zig build test
GROK_GATEWAY=http://127.0.0.1:8080 ./scripts/run-smoke.sh
```
