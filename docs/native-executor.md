# Native Zig Cursor executor?

Checked 2026-09-19 against `~/.cursor-sdk2api-zig/bridge/v1.0.30/bin/cursor-sdk-bridge`.

## What the binary is

- Mach-O 64-bit **executable** (`MH_EXECUTE`), arm64, PIE
- `nm -gU` exports only `__mh_execute_header`
- Not a dylib / not a static archive with a C ABI
- Bun-compiled `@cursor/sdk` plus the published Connect adapter

There is nothing to `@cImport`. Linking `libcursor-sdk-bridge.a` in this repo is the Zig **Connect client**, not the Cursor executor.

## Published ABI

GitHub `cursor/sdk-bridge` ships protobufs and adapter docs. The process ABI is:

```
HTTP/1.1 Connect JSON  sdk.v1.*
  SdkAgentService/CreateAgent
  SdkAgentService/Send
  SdkCursorService/ListModels
  SdkCustomToolCallbackService/CallCustomTool
```

Strings in the official binary match that (`Connect-Protocol-Version`, `CreateAgentArgs`, …). That is the supported way to drive Cursor from Zig.

## Why we are not decompiling it

The executor is proprietary minified JavaScript inside a Bun Mach-O. Decompiling it would be reverse-engineering Cursor’s private HTTP/2 agent runtime, not using a published C API. Even a clean dump would not yield a stable Zig port: the protocol is unpublished and changes with SDK versions.

A “native Zig Cursor executor” would mean reimplementing that private runtime. That is out of scope. Inference stays on the official `cursor-sdk-bridge` subprocess.

## What Zig owns

Grok-facing HTTP/SSE, catalog cache, compact, tool continuation, persist/resume of **our** waiters, then Connect JSON to the official binary.
