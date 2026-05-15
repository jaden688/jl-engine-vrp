#!/usr/bin/env python3
"""
JL Engine VRP — MCP server (stdio transport, pure stdlib)
Compatible with: Claude Code, Gemini CLI, OpenAI Codex CLI

The engine must be running (julia sparkbyte.jl) at VRP_CONTROL_URL.
All reasoning happens in the driving CLI — the engine is a pure tool executor.
"""

import sys
import json
import urllib.request
import urllib.error
import os

CONTROL_URL = os.environ.get("VRP_CONTROL_URL", "http://127.0.0.1:8081")
TIMEOUT     = 90   # seconds — long enough for cascade/swarm ops

# Supported protocol versions — echo client's version if we support it
SUPPORTED_VERSIONS = {"2024-11-05", "2025-03-26", "2025-06-18"}
DEFAULT_VERSION    = "2025-03-26"

# ── HTTP to engine ─────────────────────────────────────────────────────────────

def _get(path):
    try:
        with urllib.request.urlopen(f"{CONTROL_URL}{path}", timeout=10) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"error": str(e)}

def _post(path, payload):
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(
        f"{CONTROL_URL}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()[:500]}"}
    except Exception as e:
        return {"error": str(e)}

def dispatch(tool_name, args, operator="Cascade"):
    return _post("/control/dispatch", {"tool": tool_name, "args": args, "operator": operator})

def fetch_tools():
    return _get("/control/tools")

def fetch_state():
    return _get("/control/state")

# ── MCP stdio framing ──────────────────────────────────────────────────────────

def _read_message():
    headers = {}
    while True:
        line = sys.stdin.readline()
        if not line:
            raise EOFError
        line = line.strip()
        if not line:
            break
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip()] = v.strip()
    length = int(headers.get("Content-Length", 0))
    return json.loads(sys.stdin.read(length))

def _send(obj):
    body  = json.dumps(obj, separators=(",", ":"))
    sys.stdout.write(f"Content-Length: {len(body.encode())}\r\n\r\n{body}")
    sys.stdout.flush()

def _respond(id_, result):
    _send({"jsonrpc": "2.0", "id": id_, "result": result})

def _error(id_, code, message):
    _send({"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}})

# ── Handlers ───────────────────────────────────────────────────────────────────

SERVER_INFO  = {"name": "jl-engine-vrp", "version": "1.0.0"}
CAPABILITIES = {"tools": {}, "logging": {}}

def handle_initialize(id_, params):
    requested = params.get("protocolVersion", DEFAULT_VERSION)
    version   = requested if requested in SUPPORTED_VERSIONS else DEFAULT_VERSION
    _respond(id_, {
        "protocolVersion": version,
        "capabilities":    CAPABILITIES,
        "serverInfo":      SERVER_INFO,
    })

def handle_tools_list(id_, *_):
    tools = fetch_tools()
    if isinstance(tools, dict) and "error" in tools:
        _respond(id_, {"tools": [{
            "name":        "vrp_status",
            "description": f"Engine not reachable at {CONTROL_URL}. Run: julia sparkbyte.jl",
            "inputSchema": {"type": "object", "properties": {}, "required": []},
        }]})
        return
    _respond(id_, {"tools": tools if isinstance(tools, list) else []})

def handle_tools_call(id_, params):
    name      = params.get("name", "")
    arguments = params.get("arguments", {})

    if name == "vrp_status":
        result = fetch_state()
    else:
        result = dispatch(name, arguments)

    _respond(id_, {
        "content": [{"type": "text", "text": json.dumps(result, indent=2)}],
        "isError": isinstance(result, dict) and "error" in result,
    })

# ── Main loop ──────────────────────────────────────────────────────────────────

def main():
    # Unbuffered stdout — critical for stdio MCP transport
    sys.stdout.reconfigure(line_buffering=False)  # type: ignore[attr-defined]

    while True:
        try:
            msg = _read_message()
        except (EOFError, json.JSONDecodeError):
            break
        except Exception:
            continue

        method = msg.get("method", "")
        id_    = msg.get("id")
        params = msg.get("params", {}) or {}

        try:
            if   method == "initialize":    handle_initialize(id_, params)
            elif method == "initialized":   pass   # notification — no response
            elif method == "tools/list":    handle_tools_list(id_, params)
            elif method == "tools/call":    handle_tools_call(id_, params)
            elif method == "ping":          _respond(id_, {})
            elif id_ is not None:           _error(id_, -32601, f"Method not found: {method}")
        except Exception as e:
            if id_ is not None:
                _error(id_, -32603, str(e))

if __name__ == "__main__":
    main()
