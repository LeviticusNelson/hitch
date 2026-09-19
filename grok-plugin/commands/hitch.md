---
description: Check that Hitch is up in release mode on :8080
---

GET http://127.0.0.1:8080/health. Confirm `status=ok`, `service=hitch`, `cursor.inference=sdk-bridge`. If it is down, run `~/.hitch/start.sh` (runs `grok-plugin/bin/hitch`; it does not compile). Do not start Node gold on 8080. To refresh the shipped binary: `zig build --release=fast && ./scripts/install-plugin-bin.sh`.
