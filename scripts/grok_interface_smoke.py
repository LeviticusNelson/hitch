#!/usr/bin/env python3
"""Exercise Grok-facing routes on a running cursor-sdk2api-zig gateway."""

from __future__ import annotations

import json
import os
import socket
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("GROK_GATEWAY", "http://127.0.0.1:8080")
FAIL = 0


def req(method: str, path: str, body: dict | None = None, stream: bool = False, timeout: int = 90):
    data = None if body is None else json.dumps(body).encode()
    headers = {"content-type": "application/json", "authorization": "Bearer local"}
    r = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
            ctype = resp.headers.get("content-type", "")
            return resp.status, raw, ctype
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("content-type", "")
    except TimeoutError as e:
        return 0, str(e).encode(), "timeout"
    except socket.timeout as e:
        return 0, str(e).encode(), "timeout"
    except urllib.error.URLError as e:
        return 0, str(e).encode(), "timeout"


def expect(name: str, ok: bool, detail: str = ""):
    global FAIL
    status = "PASS" if ok else "FAIL"
    if not ok:
        FAIL += 1
    print(f"{status}  {name}" + (f"  {detail}" if detail else ""))


def json_body(raw: bytes):
    try:
        return json.loads(raw.decode())
    except Exception:
        return None


def sse_events(raw: bytes):
    events = []
    event = None
    data_lines = []
    for line in raw.decode("utf-8", "replace").splitlines():
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data_lines.append(line[5:].strip())
        elif line == "":
            if event or data_lines:
                payload = "\n".join(data_lines)
                try:
                    payload = json.loads(payload)
                except Exception:
                    pass
                events.append((event, payload))
            event = None
            data_lines = []
    return events


def main() -> int:
    status, raw, _ = req("GET", "/health")
    health = json_body(raw) or {}
    expect(
        "GET /health",
        status == 200
        and health.get("status") == "ok"
        and health.get("service") == "cursor-sdk2api-zig"
        and (health.get("cursor") or {}).get("inference") == "sdk-bridge",
        json.dumps({k: health.get(k) for k in ("status", "service", "runtime")})
        + " cursor="
        + json.dumps(health.get("cursor")),
    )

    status, raw, _ = req("GET", "/v1/models")
    models = json_body(raw) or {}
    items = models.get("data") or models.get("items") or []
    expect("GET /v1/models", status == 200 and len(items) > 0, f"n={len(items)}")

    status, raw, _ = req("GET", "/v1/account")
    expect("GET /v1/account", status in (200, 401, 403), f"status={status}")

    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {"model": "grok-4.6", "input": "hi", "previous_response_id": "resp_1"},
    )
    err = json_body(raw) or {}
    msg = str(err)
    expect(
        "fail-closed previous_response_id",
        status in (400, 422) and "previous_response_id" in msg,
        f"status={status}",
    )

    status, raw, _ = req("POST", "/v1/responses", {"model": "grok-4.6", "input": "hi", "store": True})
    expect("fail-closed store=true", status in (400, 422) and "store" in str(json_body(raw)), f"status={status}")

    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "input": [
                {"type": "message", "role": "user", "content": [
                    {"type": "input_text", "text": "hi"},
                    {"type": "function_call_output", "call_id": "call_x", "output": "nope"},
                ]}
            ],
        },
    )
    expect(
        "fail-closed mixed text+tool_result",
        status in (400, 422) and "mixed" in str(json_body(raw)).lower(),
        f"status={status} body={raw[:180]!r}",
    )

    lookup = {
        "type": "function",
        "name": "lookup",
        "description": "Look up a short fact",
        "parameters": {"type": "object", "properties": {"q": {"type": "string"}}, "required": ["q"]},
    }

    status, raw, ctype = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": True,
            "input": "Reply with exactly the word PONG and do not call any tools.",
        },
        timeout=120,
    )
    text = raw.decode("utf-8", "replace")
    expect(
        "POST /v1/responses text stream",
        status == 200 and ("PONG" in text.upper() or "response.completed" in text),
        f"status={status} bytes={len(raw)} ctype={ctype}",
    )

    status, raw, _ = req(
        "POST",
        "/v1/chat/completions",
        {
            "model": "grok-4.6",
            "stream": False,
            "messages": [{"role": "user", "content": "Reply with exactly the word PONG."}],
        },
        timeout=120,
    )
    chat = json_body(raw) or {}
    expect(
        "POST /v1/chat/completions",
        status == 200 and "choices" in chat,
        f"status={status} keys={list(chat)[:6]}",
    )

    status, raw, _ = req(
        "POST",
        "/v1/messages",
        {
            "model": "grok-4.6",
            "max_tokens": 64,
            "stream": False,
            "messages": [{"role": "user", "content": "Reply with exactly the word PONG."}],
        },
        timeout=120,
    )
    expect("POST /v1/messages", status == 200, f"status={status} bytes={len(raw)}")

    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": True,
            "tools": [lookup],
            "input": (
                "Call lookup twice in parallel, once with q=alpha and once with q=beta. "
                "Do not write a final answer yet."
            ),
        },
        timeout=180,
    )
    events = sse_events(raw)
    calls = []
    for ev, payload in events:
        if ev in ("response.output_item.done", "response.output_item.added") and isinstance(payload, dict):
            item = payload.get("item") or payload
            if isinstance(item, dict) and item.get("type") in ("function_call", "custom_tool_call"):
                cid = item.get("call_id")
                if cid and cid not in [c["call_id"] for c in calls]:
                    calls.append({"call_id": cid, "name": item.get("name"), "arguments": item.get("arguments") or item.get("input") or "{}"})
        if isinstance(payload, dict):
            resp = payload.get("response") or {}
            for item in resp.get("output") or []:
                if isinstance(item, dict) and item.get("type") == "function_call":
                    cid = item.get("call_id")
                    if cid and cid not in [c["call_id"] for c in calls]:
                        calls.append({"call_id": cid, "name": item.get("name"), "arguments": item.get("arguments") or "{}"})
    expect("parallel tool request emitted function_call", status == 200 and len(calls) >= 1, f"status={status} n={len(calls)} names={[c.get('name') for c in calls]}")

    if calls:
        # Interleaved reconstruction Grok uses for parallel tools: fc, output, fc, output...
        interleaved = []
        trailing = []
        for i, c in enumerate(calls):
            interleaved.append({"type": "function_call", "call_id": c["call_id"], "name": c.get("name") or "lookup", "arguments": c.get("arguments") or "{}"})
            interleaved.append({"type": "function_call_output", "call_id": c["call_id"], "output": f"result-{i}"})
            trailing.append({"type": "function_call_output", "call_id": c["call_id"], "output": f"result-{i}"})
        status, raw, _ = req(
            "POST",
            "/v1/responses",
            {"model": "grok-4.6", "stream": True, "tools": [lookup], "input": interleaved},
            timeout=180,
        )
        body = raw.decode("utf-8", "replace")
        expect(
            "interleaved parallel function_call_output continuation",
            status == 200 and "missing tool_result" not in body and "unknown tool_use_id" not in body,
            f"status={status} bytes={len(raw)} head={body[:180]!r}",
        )

    print(f"\n{FAIL} failure(s)")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
