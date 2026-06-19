jl-engine-vrp

My agent project, LLM-driven execution and dynamic tool creation, implemented in Julia.

It provides an unsandboxed environment where code can interact directly with the host system for automation and integration tasks.

Core Features
Dynamic Tool Creation: New Julia functions can be written, evaluated into the running process, and registered as tools at runtime without restarting.
State Management: A single SQLite database stores tool schemas, execution state, and context.
- System Access: Full filesystem read/write, shell command execution, Python/Julia subprocess support, and Playwright-based browser automation.
- Interface: WebSocket server for connecting a frontend UI (chat, terminal, browser panels).
- LLM Support: Compatible with multiple providers via API keys (Gemini, OpenAI, Anthropic, etc.).


On startup the engine initializes the SQLite database, loads configuration, sets up the browser context if enabled, and starts the WebSocket server. Tools and code execution happen through a central runtime module that supports live code evaluation and immediate use of newly forged functions.

The architecture avoids heavy external dependencies like message brokers, keeping persistence and state handling within the local SQLite file.

Setup
1. Install Julia.
2. Clone the repository.
3. Add API keys to a `.env` file (based on `.env.example`).
4. Run the main entrypoint script (typically `julia sparkbyte.jl` or equivalent).

The system listens locally and can handle direct system operations based on input.

Important Note
This project runs with unrestricted access to the local machine. Use only on isolated or test systems,because we have to say it. Review all code before execution because the engine wont. 


Plain technical description. No backstory, no character names, no example dialogues. Let me know if you want adjustments to length, emphasis, or structure.