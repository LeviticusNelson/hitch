---
description: Check that the Zig cursor-sdk2api gateway is up in release mode on :8080
---

GET http://127.0.0.1:8080/health. Confirm `status=ok`, `service=cursor-sdk2api-zig`, `cursor.inference=sdk-bridge`. If it is down, run `~/.cursor-sdk2api-zig/start.sh` (that script builds `--release=fast` when needed). Do not start Node gold on 8080.
