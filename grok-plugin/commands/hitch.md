---
description: Check that Hitch is up in release mode (PORT, default 8080, or the fallback it published)
---

Read the port from `~/.hitch/port` (full record in `~/.hitch/endpoint.json`; 8080 if missing), then GET http://127.0.0.1:<port>/health. If the port is not 8080, another process holds 8080 and Grok's provider `base_url` must point at the published port. Confirm `status=ok`, `service=hitch`, `cursor.inference=sdk-bridge`. If it is down, run `hitch install-plugin` once, then `~/.hitch/start.sh`. Do not start Node gold on 8080.
