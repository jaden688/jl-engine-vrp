# JL Engine (SparkByte)

**A local, unsandboxed, WebSocket-driven AI agent lattice written in Julia.**

I spent 8 months iterating through 66 different repositories, wrestling with Python's GIL, complex state managers, and message brokers trying to build a local AI framework. I finally threw it all out and rewrote the entire architecture in Julia. 

This is not a chat wrapper. This is a live behavioral runtime. 

The engine treats a single SQLite file as its hippocampus, seeding its own source code, file tree, tool schemas, and behavioral states into the database on boot. The agent has direct, unsandboxed access to the host filesystem, a live shell, and a Playwright browser instance. 

## The "Magic Moment": Live Tool Forging
Watch the engine write its own capabilities in real-time. No restarts. No sandboxes.

```julia
User: "SparkByte, we need a way to check system memory. Build a tool for it."

SparkByte: "On it. Forging `tool_check_mem`..."

[Engine Log] -> Evaluating new function into Main.BYTE...
[Engine Log] -> Registering schema for `check_mem`...
[Engine Log] -> Tool live. TTFX overhead: 0.4s.

SparkByte: "Tool forged. Let's test it."
[Action] -> call:check_mem{}
[Result] -> Free Memory: 14.2 GB / 32.0 GB

SparkByte: "Boom. You now have 14.2 GB of free RAM. What's next?"
```

## Core Architecture

*   **SQLite as the Brain:** No Redis, no complex message brokers. Long-term memory, behavioral state grids, tool schemas, and telemetry are all managed concurrently via `memory.sqlite`.
*   **Live Tool Forging:** The engine includes a `forge_new_tool` capability. The agent can write Julia code, evaluate it directly into the live module, and use the new capability instantly without restarting the runtime. 
*   **Behavioral Grid:** The agent operates on a 20-cell behavior grid (Intensity x Control) with dynamic "gait" (walk/trot/sprint) and "aperture" (emotional temperature) modes that shift based on user interaction drift.
*   **Unsandboxed Execution:** The agent writes directly to disk. It executes Python and Julia subprocesses. It runs shell commands. It is designed to be a local operator, not a sandboxed toy.
*   **Playwright Integration:** Native, headless Chromium integration for web reading and interaction when APIs aren't available.

## The Agent (SparkByte)

The default operator loaded into the engine is **SparkByte**. She is defined via a "fat" JSON agent file (`data/agents/SparkByte_Full.json`) which dictates her archetype, emotional baseline, and cognitive routing. 

She is aware of her own architecture and can query her own source code via the SQLite memory store.

## Running the Engine

You will need Julia installed. 

1. Clone the repository.
2. Create a `.env` file in the root directory with your LLM provider keys (e.g., `GEMINI_API_KEY`, `OPENAI_API_KEY`).
3. Run the boot script:

```bash
julia sparkbyte.jl
```

The engine will:
1. Seed the SQLite database with its own context.
2. Boot the Playwright browser context.
3. Launch the WebSocket server on `ws://127.0.0.1:8081`.

## Why Julia?

Python is great for prototyping, but managing concurrent agentic state, live code evaluation, and high-throughput tool routing without choking on the GIL became a nightmare. Julia provides the speed of C with the dynamism needed to evaluate new tool functions into the live runtime on the fly. 

## Disclaimer

This engine gives an LLM direct read/write access to your filesystem and shell. Do not run this on a machine containing sensitive data unless you understand exactly what the agent is allowed to do. 
