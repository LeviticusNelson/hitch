# NOTICE

**Hitch** is an independent MIT-licensed Zig gateway maintained by Levi Nelson.

It is **not affiliated with, endorsed by, or sponsored by** Anysphere, Inc., Cursor, xAI, Anthropic, OpenAI, or Sunnyender-org.

## Credit: cursor-sdk2api (Node gold)

Hitch’s Grok / Anthropic / OpenAI HTTP surface, fail-closed protocol rules, compact-summary intercept, and live-smoke expectations were designed and A/B-tested against:

**[cursor-sdk2api](https://github.com/Sunnyender-org/cursor-sdk2api)**  
Copyright (c) 2026 Sunnyender-org and contributors  
Licensed under the MIT License (see that repository’s `LICENSE`).

Substantial protocol behavior (including the Grok `<summary>` successor brief) follows that project. Their copyright notice is included here as required by MIT:

> MIT License — Copyright (c) 2026 Sunnyender-org and contributors

Hitch is a **Zig rewrite of the gateway HTTP layer**, not a fork of their Node tree, and not a substitute for their Operator Console.

## Cursor SDK and sdk-bridge

- Inference uses the official **`cursor-sdk-bridge`** process (Connect HTTP/1.1 JSON, `sdk.v1`), downloaded by the operator via `scripts/fetch-bridge.sh` from [cursor/sdk-bridge](https://github.com/cursor/sdk-bridge) releases.
- The **sdk-bridge adapter** (protos, Connect docs, standalone launcher) is MIT, Copyright (c) 2026 Anysphere, Inc. Hitch does not vendor that source; it implements a client against the published Connect contract.
- **`@cursor/sdk`** remains the property of its copyright holders (`SEE LICENSE IN LICENSE.md` on the npm package). This repository does **not** vendor, patch, decompile, or redistribute `@cursor/sdk` or the Bun-compiled `cursor-sdk-bridge` Mach-O.
- Do not commit `bridge/` or `cursor-sdk-bridge` binaries. Operators must supply their own legally obtained Cursor User API Key and comply with Cursor Terms of Service.

## What you may ship

| Artifact | In this git repo? | License |
|---|---|---|
| Hitch Zig sources, tests, Grok plugin scripts | yes | MIT (Levi Nelson) + credit to cursor-sdk2api |
| Prebuilt **hitch** gateway binary (`grok-plugin/bin/hitch`) | optional, our code | MIT |
| `cursor-sdk-bridge` standalone binary | **no** | Cursor / Anysphere; fetch at install time |
| `@cursor/sdk` npm tree | **no** | Cursor package license |

## Headers

Hitch still accepts `x-cursor-sdk2api-key` so existing cursor-sdk2api clients keep working.
