# Hitch TODO

Tracked build list for **hitch** vs Node gold ([cursor-sdk2api](https://github.com/Sunnyender-org/cursor-sdk2api) / `docs/PROTOCOL_COMPATIBILITY.md`). Hitch is a Zig gateway; Cursor inference stays on official `cursor-sdk-bridge`.

---

## Harness compatibility (not done unless marked)

Dogfood each client against hitch on `:8080` the way that product actually talks to an LLM API. Routes existing ≠ harness-complete.

| Harness | Speaks | Status | Notes |
|---|---|---|---|
| Grok Build | OpenAI Responses `/v1/responses` | **done** | Daily driver, plugin auto-start, compact-summary intercept |
| Claude Code | Anthropic `/v1/messages` | **missing** | Hitch serves the route; no `claude` CLI dogfood, cache_control, 1M extras unproven |
| Codex CLI / Codex VS Code | OpenAI Responses | **missing** | No Codex client matrix; `instructions` / store / previous_response_id stay fail-closed |
| OpenCode | OpenAI + Anthropic | **missing** | |
| GitHub Copilot Chat / VS Code LM | OpenAI Chat Completions | **missing** | |
| Aider | OpenAI Chat Completions | **missing** | |
| Continue.dev | OpenAI Chat Completions | **missing** | |
| Cline / Roo Code | Anthropic or OpenAI | **missing** | |
| Gemini CLI | Gemini / OpenAI-compat | **missing** | No Gemini protocol |
| Cursor CLI / ACP | Cursor-native | **skip** | Out of scope; hitch is not a Cursor IDE replacement |
| Open WebUI / LiteLLM | OpenAI | **missing** | |
| Droid / Factory | varies | **missing** | |

---

# Gateway vs Node gold

**Status:** `done` · `partial` · `missing` · `skip` (out of scope)

Last reviewed: 2026-09-19 (pending jsonl, lineage hash, managed pool, run caps).

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
| Base64 `input_image` on `/v1/responses` | done | Connect nested `{data:{data,mimeType}}` (proto oneof; flat TS shape 502s) |
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
| Ordinary next turn without session header | done | `digest.stripLastUserBlock` + lineage map; lookup prefix, store full flatten |
| Pending-tool restart after gateway kill | done | `state_dir/pending.jsonl`; restore waiters; Send `local.force=true` |
| Duplicate-same request digest replay | done | SHA-256 of body, non-stream |
| Persist lineage across process restart | partial | Lineage is in-memory; pending tools jsonl survives kill |

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
| Managed `GATEWAY_ACCESS_KEY` + pool | done | `MANAGED_CURSOR_KEYS` comma list, round-robin bind per session |
| Continuation stuck to original credential | done | `Pool.binds` session → key |
| Managed failover before response starts | done | CreateAgent retry with `Pool.failover` |

---

## P2 — Ops / polish

### 9. Observability & ops

| Item | Status | Notes |
|---|---|---|
| Structured logs without secrets | partial | Health not logged; keys not printed |
| Graceful shutdown (`shutting_down`) | partial | Health field + `active_runs`; stop.sh SIGTERM |
| Active-run / per-credential limits | done | `MAX_ACTIVE_RUNS`/`MAX_RUNS_PER_KEY` default 32; wait `CAPACITY_WAIT_MS`; compact + tool continuation do not occupy a slot |
| Health: `transcript_tool_recovery`, `stale_auth_recovery`, `managed_account_failover` | done | Advertised on `/health` |

### 10. Testing / CI

| Item | Status | Notes |
|---|---|---|
| Zig↔Node SSE fixture A/B | done | `scripts/compare-sse.sh` (Node optional on `:8081`) |
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
| Native Zig Cursor executor / decompile | MH_EXECUTE, nm only `__mh_execute_header`; see `docs/native-executor.md` |
| Operator `/console/` | Node-only |
| Sand / BeefAPI / type64 | Not Zig day-1 |

---

## Still open (next)

Native Zig Cursor executor remains **skip**: official `cursor-sdk-bridge` is `MH_EXECUTE` with no C ABI (`docs/native-executor.md`). Do not decompile.

---

## Smoke / evidence

```bash
cd /Users/levi/hitch
zig build test
GROK_GATEWAY=http://127.0.0.1:8080 ./scripts/run-smoke.sh
```
