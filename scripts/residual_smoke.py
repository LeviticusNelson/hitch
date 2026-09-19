#!/usr/bin/env python3
"""Residual + extended smoke after builtin hung on /v1/messages."""
from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.request

BASE = os.environ.get("GROK_GATEWAY", "http://127.0.0.1:8080")
FAIL = 0


def req(method: str, path: str, body: dict | None = None, timeout: int = 90):
    data = None if body is None else json.dumps(body).encode()
    headers = {"content-type": "application/json", "authorization": "Bearer local"}
    r = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read(), resp.headers.get("content-type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("content-type", "")
    except TimeoutError as e:
        return 0, f"TimeoutError: {e}".encode(), ""
    except socket.timeout as e:
        return 0, f"TimeoutError: {e}".encode(), ""
    except urllib.error.URLError as e:
        return 0, f"URLError: {e}".encode(), ""
    except Exception as e:
        return 0, f"{type(e).__name__}: {e}".encode(), ""


def expect(name: str, ok: bool, detail: str = ""):
    global FAIL
    if not ok:
        FAIL += 1
    print(("PASS" if ok else "FAIL") + f"  {name}" + (f"  {detail}" if detail else ""), flush=True)


def j(raw: bytes):
    try:
        return json.loads(raw.decode())
    except Exception:
        return None


def sse_calls(raw: bytes):
    calls = []
    event = None
    data_lines = []
    text = raw.decode("utf-8", "replace")

    def flush():
        nonlocal event, data_lines
        if not (event or data_lines):
            return
        payload = "\n".join(data_lines)
        try:
            payload = json.loads(payload)
        except Exception:
            pass
        if isinstance(payload, dict):
            item = payload.get("item") or {}
            if isinstance(item, dict) and item.get("type") in ("function_call", "custom_tool_call"):
                cid = item.get("call_id")
                if cid and cid not in [c["call_id"] for c in calls]:
                    calls.append(
                        {
                            "call_id": cid,
                            "name": item.get("name"),
                            "arguments": item.get("arguments") or item.get("input") or "{}",
                        }
                    )
            for it in (payload.get("response") or {}).get("output") or []:
                if isinstance(it, dict) and it.get("type") == "function_call":
                    cid = it.get("call_id")
                    if cid and cid not in [c["call_id"] for c in calls]:
                        calls.append(
                            {
                                "call_id": cid,
                                "name": it.get("name"),
                                "arguments": it.get("arguments") or "{}",
                            }
                        )
        event = None
        data_lines = []

    for line in text.splitlines():
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data_lines.append(line[5:].strip())
        elif line == "":
            flush()
    flush()
    return calls, text


def tool(name: str):
    return {
        "type": "function",
        "name": name,
        "description": f"{name} lookup",
        "parameters": {
            "type": "object",
            "properties": {"q": {"type": "string"}},
            "required": ["q"],
        },
    }


def main() -> int:
    status, raw, _ = req("GET", "/health", timeout=10)
    h = j(raw) or {}
    expect(
        "health",
        status == 200 and h.get("status") == "ok" and (h.get("cursor") or {}).get("inference") == "sdk-bridge",
        json.dumps(h.get("cursor")),
    )

    # P2: /health must not starve while a live stream holds waitBoundary/sendCollect.
    health_hits = {"ok": 0, "fail": 0, "detail": ""}
    stop = threading.Event()

    def poke_health():
        while not stop.wait(0.15):
            st, body, _ = req("GET", "/health", timeout=2)
            if st == 200 and b'"status":"ok"' in body:
                health_hits["ok"] += 1
            else:
                health_hits["fail"] += 1
                health_hits["detail"] = f"status={st} {body[:80]!r}"

    poker = threading.Thread(target=poke_health, daemon=True)
    poker.start()
    st, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": True,
            "input": "Reply with exactly the word PONG and do not call any tools.",
        },
        timeout=60,
    )
    time.sleep(0.3)
    stop.set()
    poker.join(timeout=3)
    expect(
        "health stays ok during live stream",
        st == 200 and health_hits["ok"] >= 1 and health_hits["fail"] == 0,
        f"stream={st} health_ok={health_hits['ok']} health_fail={health_hits['fail']} {health_hits['detail']}",
    )

    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": False,
            "input": [{"type": "input_image", "image_url": "https://example.com/x.png"}],
        },
        timeout=15,
    )
    expect(
        "remote input_image is 422",
        status in (400, 422) and b"base64 data URL" in raw,
        f"status={status} head={raw[:180]!r}",
    )

    png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": False,
            "input": [
                {
                    "type": "message",
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": "Reply with exactly the word PONG."},
                        {"type": "input_image", "image_url": png},
                    ],
                }
            ],
        },
        timeout=90,
    )
    expect(
        "base64 input_image is not 422",
        status != 422 and b"base64 data URL" not in raw,
        f"status={status} head={raw[:180]!r}",
    )

    status, raw, _ = req(
        "POST",
        "/v1/chat/completions",
        {
            "model": "grok-4.6",
            "stream": False,
            "tool_choice": "none",
            "messages": [{"role": "user", "content": "hi"}],
        },
        timeout=15,
    )
    expect(
        "tool_choice none is 422",
        status in (400, 422) and b"tool_choice" in raw,
        f"status={status} head={raw[:180]!r}",
    )

    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": False,
            "input": [
                {"type": "message", "role": "user", "content": "<user_query>default aggregate to 30 days but keep lifetime</user_query>"},
                {"type": "message", "role": "assistant", "content": "Inspected the admin report query."},
                {
                    "type": "message",
                    "role": "user",
                    "content": "Your task is to produce a faithful, concise summary of the conversation so far so that a successor assistant can continue the work seamlessly after the earlier turns are discarded. Output the final summary inside a single <summary>...</summary> block.",
                },
            ],
        },
        timeout=20,
    )
    expect(
        "grok compact-summary keeps user_query and continue instruction",
        status == 200
        and b"<summary>" in raw
        and b"default aggregate to 30 days" in raw
        and b"Continue the unfinished task" in raw
        and b"Output the final summary inside a single" not in raw,
        f"status={status} head={raw[:240]!r}",
    )

    model_ns: list[int] = []
    model_err: list[str] = []

    def poke_models():
        st, body, _ = req("GET", "/v1/models", timeout=15)
        o = j(body) or {}
        n = len(o.get("data") or [])
        model_ns.append(n)
        if st != 200 or n < 10:
            model_err.append(f"status={st} n={n}")

    threads = [threading.Thread(target=poke_models) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=20)
    expect(
        "concurrent GET /v1/models stays full",
        len(model_err) == 0 and model_ns and min(model_ns) >= 10,
        f"ns={model_ns} err={model_err}",
    )

    # Builtin hung here previously
    status, raw, _ = req(
        "POST",
        "/v1/messages",
        {
            "model": "grok-4.6",
            "max_tokens": 64,
            "stream": False,
            "messages": [{"role": "user", "content": "Reply with exactly the word PONG."}],
        },
        timeout=90,
    )
    expect("POST /v1/messages", status == 200, f"status={status} head={raw[:200]!r}")

    status, raw, _ = req("GET", "/v1/models-v2", timeout=30)
    expect("GET /v1/models-v2", status == 200, f"status={status} bytes={len(raw)}")

    status, raw, _ = req(
        "POST",
        "/v1/responses/compact",
        {"model": "grok-4.6", "input": [{"type": "message", "role": "user", "content": "summarize me"}]},
        timeout=60,
    )
    expect("POST /v1/responses/compact", status in (200, 400, 422), f"status={status} head={raw[:160]!r}")

    status, raw, _ = req(
        "POST",
        "/v1/messages/count_tokens",
        {"model": "grok-4.6", "messages": [{"role": "user", "content": "hi"}]},
        timeout=30,
    )
    expect("POST /v1/messages/count_tokens", status in (200, 400, 404, 501), f"status={status} head={raw[:120]!r}")

    lookup = tool("lookup")

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
    calls, text = sse_calls(raw)
    expect(
        "parallel tool emit",
        status == 200 and len(calls) >= 1,
        f"status={status} n={len(calls)} names={[c.get('name') for c in calls]}",
    )

    if calls:
        interleaved = []
        trailing = []
        for i, c in enumerate(calls):
            interleaved.append(
                {
                    "type": "function_call",
                    "call_id": c["call_id"],
                    "name": c.get("name") or "lookup",
                    "arguments": c.get("arguments") or "{}",
                }
            )
            interleaved.append(
                {"type": "function_call_output", "call_id": c["call_id"], "output": f"result-{i}"}
            )
            trailing.append({"type": "function_call_output", "call_id": c["call_id"], "output": f"result-{i}"})

        status, raw, _ = req(
            "POST",
            "/v1/responses",
            {"model": "grok-4.6", "stream": True, "tools": [lookup], "input": interleaved},
            timeout=180,
        )
        body = raw.decode("utf-8", "replace")
        expect(
            "interleaved parallel continuation",
            status == 200 and "missing tool_result" not in body and "unknown tool_use_id" not in body,
            f"status={status} head={body[:180]!r}",
        )

        # Spent ids after interleaved must fail closed (this is the 400 the
        # previous residual run treated as a gateway regression).
        prior_spent = [
            {
                "type": "message",
                "role": "user",
                "content": "Call lookup twice in parallel with q=alpha and q=beta.",
            }
        ]
        for c in calls:
            prior_spent.append(
                {
                    "type": "function_call",
                    "call_id": c["call_id"],
                    "name": c.get("name") or "lookup",
                    "arguments": c.get("arguments") or "{}",
                }
            )
        status, raw, _ = req(
            "POST",
            "/v1/responses",
            {"model": "grok-4.6", "stream": True, "tools": [lookup], "input": prior_spent + trailing},
            timeout=60,
        )
        spent_body = raw.decode("utf-8", "replace")
        expect(
            "spent call_id after interleaved is unknown",
            status in (400, 422) and "unknown" in spent_body.lower(),
            f"status={status} head={spent_body[:180]!r}",
        )

    # Fresh emit, then trailing-only outputs (no interleaved POST in between).
    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": True,
            "tools": [lookup],
            "input": (
                "Call lookup twice in parallel, once with q=gamma and once with q=delta. "
                "Do not write a final answer yet."
            ),
        },
        timeout=180,
    )
    calls2, _ = sse_calls(raw)
    expect(
        "trailing-only fresh emit",
        status == 200 and len(calls2) >= 1,
        f"status={status} n={len(calls2)}",
    )
    if calls2:
        prior = [
            {
                "type": "message",
                "role": "user",
                "content": "Call lookup twice in parallel with q=gamma and q=delta.",
            }
        ]
        trailing = []
        for i, c in enumerate(calls2):
            prior.append(
                {
                    "type": "function_call",
                    "call_id": c["call_id"],
                    "name": c.get("name") or "lookup",
                    "arguments": c.get("arguments") or "{}",
                }
            )
            trailing.append({"type": "function_call_output", "call_id": c["call_id"], "output": f"result-{i}"})
        status, raw, _ = req(
            "POST",
            "/v1/responses",
            {"model": "grok-4.6", "stream": True, "tools": [lookup], "input": prior + trailing},
            timeout=180,
        )
        body = raw.decode("utf-8", "replace")
        expect(
            "trailing-only parallel continuation",
            status == 200 and "missing tool_result" not in body and "unknown tool_use_id" not in body,
            f"status={status} head={body[:180]!r}",
        )

    # Historical completed tools + new user turn
    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": True,
            "tools": [lookup],
            "input": [
                {"type": "message", "role": "user", "content": "old turn"},
                {
                    "type": "function_call",
                    "call_id": "call_hist_1",
                    "name": "lookup",
                    "arguments": '{"q":"old"}',
                },
                {"type": "function_call_output", "call_id": "call_hist_1", "output": "old-result"},
                {"type": "message", "role": "assistant", "content": "done with old"},
                {
                    "type": "message",
                    "role": "user",
                    "content": "Reply with exactly the word PONG and do not call tools.",
                },
            ],
        },
        timeout=180,
    )
    text = raw.decode("utf-8", "replace")
    expect(
        "historical tool_result + new user",
        status == 200 and "mixed" not in text.lower() and "unknown tool_use_id" not in text,
        f"status={status} head={text[:200]!r}",
    )

    # Namespaced tool
    ns = {
        "type": "function",
        "name": "custom-user-tools__list_dir",
        "description": "List a directory",
        "parameters": {
            "type": "object",
            "properties": {"target_directory": {"type": "string"}},
            "required": ["target_directory"],
        },
    }
    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": True,
            "tools": [ns],
            "input": (
                "Call custom-user-tools__list_dir once with target_directory=/tmp. "
                "Do not write a final answer yet."
            ),
        },
        timeout=180,
    )
    calls, text = sse_calls(raw)
    expect(
        "namespaced tool emit",
        status == 200 and (len(calls) >= 1 or "function_call" in text),
        f"status={status} n={len(calls)} head={text[:160]!r}",
    )
    if calls:
        c = calls[0]
        status, raw, _ = req(
            "POST",
            "/v1/responses",
            {
                "model": "grok-4.6",
                "stream": True,
                "tools": [ns],
                "input": [
                    {
                        "type": "function_call",
                        "call_id": c["call_id"],
                        "name": "custom-user-tools__list_dir",
                        "arguments": c.get("arguments") or "{}",
                    },
                    {"type": "function_call_output", "call_id": c["call_id"], "output": "[tmp]"},
                ],
            },
            timeout=180,
        )
        body = raw.decode("utf-8", "replace")
        expect(
            "namespaced tool continuation",
            status == 200 and "missing tool_result" not in body and "unknown tool_use_id" not in body,
            f"status={status} head={body[:180]!r}",
        )

    status, raw, _ = req(
        "POST",
        "/v1/responses",
        {
            "model": "grok-4.6",
            "stream": True,
            "tools": [lookup],
            "input": [
                {
                    "type": "function_call_output",
                    "call_id": "call_does_not_exist",
                    "output": "nope",
                }
            ],
        },
        timeout=60,
    )
    text = raw.decode("utf-8", "replace").lower()
    expect(
        "unknown tool_use_id fail-closed",
        status in (400, 422) and ("unknown" in text or "tool" in text),
        f"status={status} head={raw[:160]!r}",
    )

    status, raw, _ = req("GET", "/v1/does-not-exist", timeout=10)
    expect("missing route 404", status == 404, f"status={status}")

    print(f"\n{FAIL} failure(s)", flush=True)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
