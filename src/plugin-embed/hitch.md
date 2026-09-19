---
description: Check that Hitch is up in release mode on :8080
---

GET http://127.0.0.1:8080/health. Confirm `status=ok`, `service=hitch`, `cursor.inference=sdk-bridge`. If it is down, run `hitch install-plugin` once, then `~/.hitch/start.sh`. Do not start Node gold on 8080.
