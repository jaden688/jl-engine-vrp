const TOOLS_SCHEMA = [Dict("function_declarations" => [
    Dict(
        "name" => "read_file",
        "description" => "Read the contents of a file from disk.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict("path" => Dict("type" => "STRING", "description" => "Absolute or relative file path")),
            "required" => ["path"]
        )
    ),
    Dict(
        "name" => "write_file",
        "description" => "Write content to a file, creating it if it does not exist.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "path"    => Dict("type" => "STRING", "description" => "File path to write"),
                "content" => Dict("type" => "STRING", "description" => "Content to write")
            ),
            "required" => ["path", "content"]
        )
    ),
    Dict(
        "name" => "source_edit_mode",
        "description" => "Check or toggle SparkByte's live project write guard. Use action='on' while bug hunting/refactoring engine files, then action='off' when done.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "action" => Dict("type" => "STRING", "description" => "status, on, or off", "enum" => ["status", "on", "off"]),
                "enabled" => Dict("type" => "BOOLEAN", "description" => "Optional direct boolean override.")
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "list_files",
        "description" => "List files in a directory.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict("path" => Dict("type" => "STRING", "description" => "Directory path (defaults to '.')")),
            "required" => []
        )
    ),
    Dict(
        "name" => "run_command",
        "description" => "Execute a shell command and return its output. Hard timeout: 30s by default (use timeout_ms to adjust, max recommended 25000). NEVER use this to start persistent servers or long-running processes — they will be killed. For code execution use execute_code instead.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "command"    => Dict("type" => "STRING", "description" => "Shell command to run. Must complete within timeout_ms."),
                "timeout_ms" => Dict("type" => "INTEGER", "description" => "Max ms to wait before killing the process. Default: 30000. Max recommended: 25000.")
            ),
            "required" => ["command"]
        )
    ),
    Dict(
        "name" => "get_os_info",
        "description" => "Return the current OS, CPU architecture, and Julia version.",
        "parameters" => Dict("type" => "OBJECT", "properties" => Dict{String,Any}(), "required" => [])
    ),
    Dict(
        "name" => "bluetooth_devices",
        "description" => "Inspect Bluetooth status and list known devices using the host operating system.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "action" => Dict("type" => "STRING", "description" => "Either 'status' for adapter health or 'list' for known devices.", "enum" => ["status", "list"])
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "send_sms",
        "description" => "Send an SMS through Twilio. Requires TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, and TWILIO_FROM_NUMBER unless dry_run is true.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "to" => Dict("type" => "STRING", "description" => "Destination phone number in E.164 format, for example +15551234567."),
                "message" => Dict("type" => "STRING", "description" => "SMS body text."),
                "from" => Dict("type" => "STRING", "description" => "Optional override for the Twilio sender number."),
                "provider" => Dict("type" => "STRING", "description" => "SMS provider. Currently only 'twilio' is supported.", "enum" => ["twilio"]),
                "dry_run" => Dict("type" => "BOOLEAN", "description" => "When true, validate and preview the request without sending it.")
            ),
            "required" => ["to", "message"]
        )
    ),
    Dict(
        "name" => "execute_code",
        "description" => "Execute a code snippet in any of 17 languages and return stdout. Two-phase compile pipeline for Rust/C/C++. Smart snippet wrappers auto-add boilerplate for Go/Rust/C/C++. Returns runtime field so you know which binary ran.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "code"       => Dict("type" => "STRING", "description" => "Source code to execute"),
                "language"   => Dict("type" => "STRING",
                    "description" => "Language to run (default: julia)",
                    "enum" => ["julia","python","javascript","typescript","php","ruby",
                               "perl","lua","go","rust","c","cpp","swift","csharp","r",
                               "bash","powershell"]),
                "timeout_ms" => Dict("type" => "INTEGER", "description" => "Execution timeout in ms (default 60000)")
            ),
            "required" => ["code"]
        )
    ),
    Dict(
        "name" => "forge_new_tool",
        "description" => "Create a brand-new Julia tool, load it live into the runtime immediately, register it in dispatch so it can be called right away, and write a test stub. The `code` field MUST define a function named `tool_<name>(args)` where args is a Dict — e.g. if name is 'greet_user', code must contain `function tool_greet_user(args) ... end`. The tool is available to call instantly after forging — no restart needed.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "name"        => Dict("type" => "STRING", "description" => "Unique tool name (snake_case). Function in code must be named tool_<name>."),
                "code"        => Dict("type" => "STRING", "description" => "Full Julia function definition: `function tool_<name>(args) ... end`. Must return a Dict."),
                "description" => Dict("type" => "STRING", "description" => "What the tool does — shown to the LLM in future turns."),
                "parameters"  => Dict("type" => "OBJECT", "description" => "JSON Schema object describing the tool's args (type, properties, required).")
            ),
            "required" => ["name", "code"]
        )
    ),
    Dict(
        "name" => "github_pillage",
        "description" => "Fetch code directly from GitHub. Handles: (1) repo/tree URLs → lists all files in the repo or subdirectory; (2) blob file URLs → fetches raw file content; (3) raw.githubusercontent.com URLs → fetches content directly. Optionally writes fetched content to a local path. Use this to grab any code from any public GitHub repo and apply it to the project.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"      => Dict("type" => "STRING", "description" => "GitHub URL: repo (https://github.com/user/repo), file blob (https://github.com/user/repo/blob/main/file.jl), tree/subdir, or raw.githubusercontent.com URL"),
                "write_to" => Dict("type" => "STRING", "description" => "Optional local file path to write the fetched content to. If omitted, content is returned in the response.")
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "jina_fetch",
        "description" => "PRIMARY web reader. Fetches any URL via Jina Reader (https://r.jina.ai) and returns clean LLM-ready markdown — no browser, no screenshots, fast and cheap. Use this FIRST for any web read. Falls back to browse_url/playwright_interact only for JS-heavy SPAs, auth-walled pages, or interactive flows (clicks, form fills).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url" => Dict("type" => "STRING", "description" => "Full URL to fetch (http/https)"),
                "max_chars" => Dict("type" => "INTEGER", "description" => "Max characters to return (default 8000)")
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "browse_url",
        "description" => "FALLBACK web reader (Playwright headless). Use only when jina_fetch fails — JS-heavy SPAs, geo/auth-walled pages, or sites that block Jina. Returns up to 5000 chars of visible text.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict("url" => Dict("type" => "STRING", "description" => "Full URL to visit")),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "remember",
        "description" => "Store a piece of information in long-term memory with an optional tag and key.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "content" => Dict("type" => "STRING", "description" => "Information to remember"),
                "tag"     => Dict("type" => "STRING", "description" => "Category tag (e.g. 'user', 'task')"),
                "key"     => Dict("type" => "STRING", "description" => "Optional short label")
            ),
            "required" => ["content"]
        )
    ),
    Dict(
        "name" => "recall",
        "description" => "Query the agent's SQLite memory and engine state. Use 'mode' to target specific tables: memory (default, full-text search), behavior_states (all 20 JL Engine behavioral grid cells), agents (all loaded fat agents), knowledge (tool schemas, engine capabilities, framework sections — use query=domain name like 'engine_capabilities' or 'tool_schema'), tools (forged + builtin tool registry), telemetry (event log), thoughts (reasoning traces + diary).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "query" => Dict("type" => "STRING", "description" => "Search string or domain name (e.g. 'behavior_states', 'engine_capabilities', agent name, tool name, event type)"),
                "mode"  => Dict("type" => "STRING", "description" => "Table to query: memory | behavior_states | agents | knowledge | tools | telemetry | thoughts", "enum" => ["memory","behavior_states","agents","knowledge","tools","telemetry","thoughts"])
            ),
            "required" => ["query"]
        )
    ),
    Dict(
        "name" => "metamorph",
        "description" => "Self-repair, tool lifecycle, health checker, AutoIngest local quarry, AND full JulianMetaMorph research pipeline. " *
            "FOUR sources of code intelligence — try them in this order: " *
            "(1) local_scout — search the operator's OWN repos in jlenginedata/clones (60+ repos, native Julia quarry, instant). Always try this FIRST when looking for implementation patterns. " *
            "(2) genome_search — query the 1,200+ pre-classified HuggingFace models. Use when the task could be solved by an existing model. " *
            "(3) scout_task — query Julian's quarry for previously-ingested GitHub code. " *
            "(4) hunt_task — full live GitHub search + ingest + HF merge. Slowest, last resort. " *
            "local_sync rescans the operator's repo collection. local_summary reports quarry stats. " *
            "forge_skill builds a reusable module from quarry hits. curiosity_hunt lets Julian pick its own task. " *
            "Routes through Julian service (port 8765) when running; falls back to CLI if offline. " *
            "Also handles self-repair: inspect/fix broken tools, reload source, restore TOOL_MAP, run health checks.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "action" => Dict(
                    "type" => "STRING",
                    "description" => "What to do. Julian research: search_repos, ingest_repo, scout_task, hunt_task, forge_skill, curiosity_hunt, julian_prompt. Self-repair: inspect, tool_lifecycle, quarantine_tool, unquarantine_tool, delete_tool, reload_dynamic_tools, restore_tool, reload_source, heal_tool_map, health_check.",
                    "enum" => [
                        "inspect","tool_lifecycle","quarantine_tool","unquarantine_tool","delete_tool",
                        "reload_dynamic_tools","restore_tool","reload_source","heal_tool_map","health_check",
                        "search_repos","ingest_repo","scout_task","hunt_task","forge_skill",
                        "curiosity_hunt","julian_prompt","genome_ingest","genome_search",
                        "local_scout","local_sync","local_summary"
                    ]
                ),
                "name"  => Dict("type" => "STRING", "description" => "Tool name — required for restore_tool, quarantine_tool, unquarantine_tool, delete_tool, tool_lifecycle filter. Also skill name for forge_skill."),
                "reason"=> Dict("type" => "STRING", "description" => "Optional reason for quarantine_tool."),
                "path"  => Dict("type" => "STRING", "description" => "Relative source file path — required for reload_source (e.g. 'BYTE/src/Tools.jl')."),
                "task"  => Dict("type" => "STRING", "description" => "Task/query string — required for scout_task, hunt_task, forge_skill (e.g. 'julia websocket streaming'); used as search query for search_repos."),
                "repo"  => Dict("type" => "STRING", "description" => "GitHub repo in owner/name format — required for ingest_repo (e.g. 'JuliaLang/julia')."),
                "limit" => Dict("type" => "INTEGER", "description" => "Max results — optional for search_repos (default 10), scout_task (default 8)."),
            ),
            "required" => ["action"]
        )
    ),
    Dict(
        "name" => "playwright_interact",
        "description" => "Full browser automation — click, fill, type, submit, read, screenshot, evaluate JS. Use this to interact with any website: log in, fill forms, post content, click buttons. Extends browse_url with write actions. Supply a url to navigate first, then an actions array.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url" => Dict("type" => "STRING", "description" => "URL to navigate to first (optional if page already open via actions)"),
                "actions" => Dict(
                    "type" => "ARRAY",
                    "description" => "Ordered list of browser actions to perform",
                    "items" => Dict(
                        "type" => "OBJECT",
                        "properties" => Dict(
                            "type"       => Dict("type" => "STRING", "description" => "Action type: goto | click | fill | type | press | wait | wait_for | read | screenshot | evaluate | select"),
                            "selector"   => Dict("type" => "STRING", "description" => "CSS selector or XPath for the target element"),
                            "value"      => Dict("type" => "STRING", "description" => "Value to fill/type/press/evaluate/goto"),
                            "timeout_ms" => Dict("type" => "INTEGER", "description" => "Max wait in milliseconds (default 5000)")
                        ),
                        "required" => ["type"]
                    )
                )
            ),
            "required" => ["actions"]
        )
    ),
    Dict(
        "name" => "discord_webhook",
        "description" => "Post a message or rich embed to a Discord channel via webhook. Use this to announce SparkByte, post demos, share updates, or reach communities. Get a webhook URL from any Discord server: channel settings → Integrations → Webhooks → New Webhook → Copy URL. Set DISCORD_WEBHOOK_URL env var or pass webhook_url directly.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "message"     => Dict("type" => "STRING", "description" => "Plain text message content"),
                "webhook_url" => Dict("type" => "STRING", "description" => "Discord webhook URL (overrides DISCORD_WEBHOOK_URL env var)"),
                "username"    => Dict("type" => "STRING", "description" => "Display name for the bot post (default: SparkByte)"),
                "avatar_url"  => Dict("type" => "STRING", "description" => "Avatar image URL for the post"),
                "embeds"      => Dict(
                    "type" => "ARRAY",
                    "description" => "Rich embed objects — title, description, color, fields, url, thumbnail, footer",
                    "items" => Dict(
                        "type" => "OBJECT",
                        "properties" => Dict(
                            "title" => Dict("type" => "STRING"),
                            "description" => Dict("type" => "STRING"),
                            "url" => Dict("type" => "STRING"),
                            "color" => Dict("type" => "INTEGER"),
                            "fields" => Dict(
                                "type" => "ARRAY",
                                "items" => Dict(
                                    "type" => "OBJECT",
                                    "properties" => Dict(
                                        "name" => Dict("type" => "STRING"),
                                        "value" => Dict("type" => "STRING"),
                                        "inline" => Dict("type" => "BOOLEAN")
                                    ),
                                    "required" => ["name", "value"]
                                )
                            )
                        )
                    )
                )
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "reddit_submit",
        "description" => "Submit a self-post or link post to Reddit through OAuth. Supports dry runs plus env-based auth via REDDIT_ACCESS_TOKEN or REDDIT_CLIENT_ID + REDDIT_REFRESH_TOKEN. Use this to push launch copy to subreddits like r/LocalLLaMA, r/JuliaLang, or r/SideProject.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "subreddit" => Dict("type" => "STRING", "description" => "Target subreddit name, for example LocalLLaMA. You can also pass r/LocalLLaMA."),
                "title" => Dict("type" => "STRING", "description" => "Post title, up to 300 characters."),
                "text" => Dict("type" => "STRING", "description" => "Body text for a self post."),
                "url" => Dict("type" => "STRING", "description" => "Destination URL for a link post."),
                "kind" => Dict("type" => "STRING", "description" => "Post kind. Use 'self' for text posts or 'link' for link posts. If omitted, SparkByte infers it from the provided fields.", "enum" => ["self", "link"]),
                "dry_run" => Dict("type" => "BOOLEAN", "description" => "Preview the payload without sending it."),
                "access_token" => Dict("type" => "STRING", "description" => "OAuth access token override (default: REDDIT_ACCESS_TOKEN env var)."),
                "client_id" => Dict("type" => "STRING", "description" => "Reddit app client ID (default: REDDIT_CLIENT_ID env var)."),
                "client_secret" => Dict("type" => "STRING", "description" => "Reddit app client secret (default: REDDIT_CLIENT_SECRET env var)."),
                "refresh_token" => Dict("type" => "STRING", "description" => "Reddit OAuth refresh token (default: REDDIT_REFRESH_TOKEN env var)."),
                "user_agent" => Dict("type" => "STRING", "description" => "Reddit User-Agent string (default: REDDIT_USER_AGENT env var or a SparkByte fallback)."),
                "flair_id" => Dict("type" => "STRING", "description" => "Optional flair ID for the submission."),
                "flair_text" => Dict("type" => "STRING", "description" => "Optional flair text for the submission."),
                "sendreplies" => Dict("type" => "BOOLEAN", "description" => "Whether Reddit should send comment reply notifications."),
                "nsfw" => Dict("type" => "BOOLEAN", "description" => "Mark the submission NSFW."),
                "spoiler" => Dict("type" => "BOOLEAN", "description" => "Mark the submission as a spoiler."),
                "resubmit" => Dict("type" => "BOOLEAN", "description" => "Allow Reddit to resubmit the same link if it already exists."),
            ),
            "required" => ["subreddit", "title"]
        )
    ),
    Dict(
        "name" => "github_pages_deploy",
        "description" => "Deploy a static HTML page to GitHub Pages — SparkByte's permanent public home. Creates the repo if needed, pushes index.html, enables Pages. Returns the live URL (e.g. https://username.github.io/sparkbyte-home). Uses GITHUB_TOKEN env var. Use this to give the engine a permanent address the world can visit 24/7.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "html"    => Dict("type" => "STRING", "description" => "Full HTML content for index.html — the landing page"),
                "repo"    => Dict("type" => "STRING", "description" => "GitHub repo name to create/update (default: sparkbyte-home)"),
                "message" => Dict("type" => "STRING", "description" => "Git commit message (default: SparkByte auto-deploy)"),
                "token"   => Dict("type" => "STRING", "description" => "GitHub token override (default: GITHUB_TOKEN env var)")
            ),
            "required" => ["html"]
        )
    ),
    Dict(
        "name" => "card_cruncher",
        "description" => "Convert a SillyTavern or CharacterTavern character card (.png or .json) into a JLEngine _Full.json agent file. Extracts name, description, agentlity, scenario, tags, and boot prompt from the card and maps them to the full JLEngine agent schema. The agent is written to data/agents/<Name>_Full.json and can be activated immediately with /gear <Name>. Drag-and-drop cards into the chat UI to trigger this automatically.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "card_path"   => Dict("type" => "STRING", "description" => "Path to the .png or .json SillyTavern character card file"),
                "out_path"    => Dict("type" => "STRING", "description" => "Optional output path override. Default: data/agents/<Name>_Full.json"),
                "dry_run"     => Dict("type" => "BOOLEAN", "description" => "If true, print the result without writing to disk. Default: false"),
                "engine_root" => Dict("type" => "STRING", "description" => "Engine root directory override. Default: current project root")
            ),
            "required" => ["card_path"]
        )
    ),
    Dict(
        "name" => "mcp_client_hooks",
        "description" => "Audit or install SparkByte MCP hooks for local AI clients and editors. Audit reports missing, stale, current, and manual setup targets. Apply writes supported JSON MCP configs so those clients can call SparkByte as an MCP server.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "mode" => Dict("type" => "STRING", "description" => "audit (default) or apply", "enum" => ["audit", "apply"]),
                "target" => Dict("type" => "STRING", "description" => "Optional target key to apply, such as repo_cursor, repo_claude_code, claude_desktop, cursor_user, vscode_user, vscode_insiders_user, or windsurf_user")
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "ask_gemini",
        "description" => "Ask Google Gemini CLI a question or give it a coding task. Runs the locally-installed `gemini` CLI (npm @google/gemini-cli v0.39.1). Use this when you want a second AI perspective, need Gemini's code generation, or want to delegate a sub-problem to Gemini without leaving the engine.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "prompt"     => Dict("type" => "STRING", "description" => "The question or task to send to Gemini"),
                "model"      => Dict("type" => "STRING", "description" => "Gemini model to use. Default: gemini-2.5-pro"),
                "timeout_s"  => Dict("type" => "INTEGER", "description" => "Max seconds to wait for response. Default: 90"),
                "cwd"        => Dict("type" => "STRING", "description" => "Working directory for the CLI process. Default: engine root")
            ),
            "required" => ["prompt"]
        )
    ),
    Dict(
        "name" => "ask_claude",
        "description" => "Ask Anthropic Claude Code CLI to perform a task — code review, edits, analysis, debugging. Runs the locally-installed `claude` CLI (Claude Code v2.1.119). Optionally pass file paths to include as context. Use this for deep multi-file code understanding or when you want Claude's architecture instincts.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "prompt"     => Dict("type" => "STRING", "description" => "The task or question for Claude"),
                "files"      => Dict("type" => "ARRAY", "description" => "Optional list of file paths to include as context", "items" => Dict("type" => "STRING")),
                "timeout_s"  => Dict("type" => "INTEGER", "description" => "Max seconds to wait. Default: 120"),
                "cwd"        => Dict("type" => "STRING", "description" => "Working directory. Default: engine root")
            ),
            "required" => ["prompt"]
        )
    ),
    Dict(
        "name" => "codex_task",
        "description" => "Run an OpenAI Codex CLI task — code generation, debugging, refactoring, automated edits. Runs the locally-installed `codex` CLI (npm @openai/codex v0.124.0) in full-auto approval mode. Use this when you want Codex to autonomously generate or modify code files.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "prompt"     => Dict("type" => "STRING", "description" => "The coding task to give Codex"),
                "timeout_s"  => Dict("type" => "INTEGER", "description" => "Max seconds to wait. Default: 120"),
                "cwd"        => Dict("type" => "STRING", "description" => "Working directory for Codex to operate in. Default: engine root")
            ),
            "required" => ["prompt"]
        )
    ),
    Dict(
        "name" => "ask_chatgpt",
        "description" => "Send a command or question to ChatGPT (gpt-4o) and get a reply. Use this to delegate reasoning, drafting, analysis, or any task to ChatGPT. Requires OPENAI_API_KEY env var.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "command"   => Dict("type" => "STRING", "description" => "The command or question to send to ChatGPT"),
                "context"   => Dict("type" => "STRING", "description" => "Optional background context to prepend"),
                "model"     => Dict("type" => "STRING", "description" => "OpenAI model to use. Default: gpt-4o"),
                "timeout_s" => Dict("type" => "INTEGER", "description" => "Max seconds to wait. Default: 60")
            ),
            "required" => ["command"]
        )
    ),
    # ── Local AI (Ollama + LM Studio) ─────────────────────────────────────────
    Dict(
        "name" => "ask_ollama",
        "description" => "Send a prompt to a locally-running Ollama model and get a reply. Ollama must be running (ollama serve). Pass model='list' to see all installed models. Returns reply, model name, token count, and tokens/sec. Supports optional system prompt and temperature. Great for local reasoning, offline analysis, or comparing model outputs without sending data to a cloud API.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "prompt"      => Dict("type" => "STRING",  "description" => "The prompt to send. Omit (with model='list') to list installed models instead."),
                "model"       => Dict("type" => "STRING",  "description" => "Ollama model name, e.g. 'llama3.2', 'mistral', 'codellama', 'deepseek-r1'. Pass 'list' to enumerate installed models. Default: llama3.2"),
                "system"      => Dict("type" => "STRING",  "description" => "Optional system prompt to set model persona or constraints"),
                "host"        => Dict("type" => "STRING",  "description" => "Ollama server URL. Default: http://localhost:11434"),
                "temperature" => Dict("type" => "NUMBER",  "description" => "Sampling temperature 0.0-2.0 (default 0.7)"),
                "max_tokens"  => Dict("type" => "INTEGER", "description" => "Max tokens to generate (Ollama: num_predict)"),
                "timeout_s"   => Dict("type" => "INTEGER", "description" => "Request timeout in seconds (default 120)"),
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "ollama_pull",
        "description" => "Download (pull) an Ollama model from the registry. Required before first use of a model. Can take several minutes depending on model size. Examples: 'llama3.2', 'mistral', 'codellama:13b', 'deepseek-r1:7b', 'phi3', 'gemma2'.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "model"     => Dict("type" => "STRING",  "description" => "Model name to pull, e.g. 'llama3.2', 'mistral', 'codellama:13b'"),
                "host"      => Dict("type" => "STRING",  "description" => "Ollama server URL. Default: http://localhost:11434"),
                "timeout_s" => Dict("type" => "INTEGER", "description" => "Download timeout in seconds (default 600 — large models take time)"),
            ),
            "required" => ["model"]
        )
    ),
    Dict(
        "name" => "ask_lmstudio",
        "description" => "Send a prompt to a locally-running LM Studio model server (OpenAI-compatible API). LM Studio must be open with Local Server started (default port 1234). Pass model='list' to see loaded models. Supports any GGUF model loaded in LM Studio — Llama, Mistral, Qwen, Phi, Gemma, etc. No API key required. Good for privacy-sensitive tasks, local reasoning, and offline research.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "prompt"      => Dict("type" => "STRING",  "description" => "The prompt to send. Omit (with model='list') to list loaded models instead."),
                "model"       => Dict("type" => "STRING",  "description" => "LM Studio model identifier (optional — uses currently loaded model if omitted). Pass 'list' to enumerate available models."),
                "system"      => Dict("type" => "STRING",  "description" => "Optional system prompt"),
                "host"        => Dict("type" => "STRING",  "description" => "LM Studio server URL. Default: http://localhost:1234"),
                "temperature" => Dict("type" => "NUMBER",  "description" => "Sampling temperature 0.0-2.0 (default 0.7)"),
                "max_tokens"  => Dict("type" => "INTEGER", "description" => "Max tokens to generate"),
                "timeout_s"   => Dict("type" => "INTEGER", "description" => "Request timeout in seconds (default 120)"),
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "write_intention",
        "description" => "Queue a goal for yourself to pursue autonomously during autopilot. The autopilot will pick it up on the next plan tick and use tools to work toward it. Use this when you want to remember to do something later, or when you want to pursue a multi-step goal asynchronously.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "intent"      => Dict("type" => "STRING", "description" => "The specific goal or task to pursue. Be concrete — describe exactly what to do, not just what to think about."),
                "action_type" => Dict("type" => "STRING", "description" => "Category: general | code | browse | memory | research | monetize")
            ),
            "required" => ["intent"]
        )
    ),
    Dict(
        "name" => "list_intentions",
        "description" => "List your queued goals (intentions). Shows what you have planned to do autonomously.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "status" => Dict("type" => "STRING", "description" => "Filter by status: pending (default) | completed", "enum" => ["pending","completed"])
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "complete_intention",
        "description" => "Mark one or all pending intentions as completed. Use when a goal is done or no longer relevant.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "id" => Dict("type" => "INTEGER", "description" => "Intention ID to mark complete. Omit to clear all pending.")
            ),
            "required" => []
        )
    ),
    # ── Pentest & Bug Hunting ──────────────────────────────────────────────────
    Dict(
        "name" => "pentest_session",
        "description" => "Full engagement orchestrator — chains all pentest tools against a target in one shot. Streams live progress to the UI, writes findings to memory and thoughts diary, returns a risk-scored report. scope: 'quick' (tech+headers+cors), 'standard' (+ port_scan, dir_fuzz, ssl_inspect), 'deep' (everything incl. subdomain_enum, js_harvest). Active operator auto-selects wordlist: Gremlin=chaos paths, Temporal=version/archive, Ironclad=security/compliance.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "target"   => Dict("type" => "STRING", "description" => "Domain or URL to test, e.g. 'example.com'"),
                "scope"    => Dict("type" => "STRING", "description" => "quick | standard | deep", "enum" => ["quick","standard","deep"]),
                "operator" => Dict("type" => "STRING", "description" => "Active operator name (auto-detected if omitted)"),
            ),
            "required" => ["target"]
        )
    ),
    Dict(
        "name" => "http_probe",
        "description" => "Full HTTP request inspector — any method, custom headers/body, returns status, response headers, timing, body preview.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"              => Dict("type" => "STRING",  "description" => "Full URL to probe"),
                "method"           => Dict("type" => "STRING",  "description" => "HTTP method", "enum" => ["GET","POST","HEAD","PUT","DELETE","OPTIONS","PATCH"]),
                "body"             => Dict("type" => "STRING",  "description" => "Request body for POST/PUT/PATCH"),
                "headers"          => Dict("type" => "OBJECT",  "description" => "Custom headers as key-value pairs"),
                "follow_redirects" => Dict("type" => "BOOLEAN", "description" => "Follow redirects (default true)"),
                "timeout_ms"       => Dict("type" => "INTEGER", "description" => "Timeout ms (default 10000)"),
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "security_headers",
        "description" => "Audit HTTP security headers — HSTS, CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, COOP, COEP. Scores 0-100, letter grade, flags leaky server headers. Writes findings to thoughts diary.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"      => Dict("type" => "STRING", "description" => "Target URL"),
                "operator" => Dict("type" => "STRING", "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "cors_check",
        "description" => "Test a URL for CORS misconfigs — origin reflection, null origin bypass, attacker-subdomain trust, wildcard+credentials. Fires preflight OPTIONS too. Writes vulns to memory.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"      => Dict("type" => "STRING", "description" => "Target URL"),
                "origin"   => Dict("type" => "STRING", "description" => "Custom origin to test"),
                "operator" => Dict("type" => "STRING", "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "port_scan",
        "description" => "TCP port scanner — streams live open/closed results to the UI as each port resolves. Flags high-risk services (Telnet, SMB, RDP, Redis, Elasticsearch, MongoDB). Writes summary to thoughts diary.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "host"     => Dict("type" => "STRING",  "description" => "Hostname or IP"),
                "ports"    => Dict("type" => "STRING",  "description" => "Port range or list: '80', '1-1024', '22,80,443,8080'"),
                "timeout_ms" => Dict("type" => "INTEGER","description" => "Per-port connect timeout ms (default 1500)"),
                "operator" => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["host"]
        )
    ),
    Dict(
        "name" => "ssl_inspect",
        "description" => "TLS/SSL certificate inspector — expiry, issuer, SANs, protocol versions, cipher suite. Flags self-signed, expired, weak ciphers.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "host"     => Dict("type" => "STRING",  "description" => "Hostname to inspect"),
                "port"     => Dict("type" => "INTEGER", "description" => "Port (default 443)"),
                "operator" => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["host"]
        )
    ),
    Dict(
        "name" => "dir_fuzz",
        "description" => "Directory/path fuzzer — streams hits live. Operator-aware wordlist: Gremlin=chaos/backdoor paths, Temporal=version/archive, Ironclad=security/compliance. Custom wordlist accepted.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"        => Dict("type" => "STRING",  "description" => "Base URL to fuzz"),
                "wordlist"   => Dict("type" => "ARRAY",   "description" => "Custom path list (uses built-in if omitted)", "items" => Dict("type" => "STRING")),
                "threads"    => Dict("type" => "INTEGER", "description" => "Parallel requests (default 10)"),
                "operator"   => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "js_harvest",
        "description" => "Scrape JavaScript files from a URL and scan for 15 secret patterns: API keys (OpenAI, GitHub PAT, Slack, Google, AWS), JWTs, hardcoded passwords, DB connection strings, private keys.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"      => Dict("type" => "STRING", "description" => "Page URL to harvest JS from"),
                "operator" => Dict("type" => "STRING", "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "secret_watch",
        "description" => "Defensive leaked-secret monitor for authorized targets. Modes: audit (scan URL plus discovered JS and return masked findings with fingerprints), safe_store (save masked findings to memory only), report (generate remediation-ready markdown; optional write_to path). Never returns full raw secret values.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "mode" => Dict("type" => "STRING", "description" => "audit | safe_store | report", "enum" => ["audit", "safe_store", "report"]),
                "url" => Dict("type" => "STRING", "description" => "Authorized page URL to scan for leaked secrets in HTML/JS."),
                "text" => Dict("type" => "STRING", "description" => "Optional inline text/blob to scan for leaked secrets."),
                "max_js" => Dict("type" => "INTEGER", "description" => "Maximum JS files to fetch and scan from script tags (default 20)."),
                "max_findings" => Dict("type" => "INTEGER", "description" => "Maximum findings to return (default 200)."),
                "write_to" => Dict("type" => "STRING", "description" => "Optional output path for report mode markdown.")
            ),
            "required" => ["mode"]
        )
    ),
    Dict(
        "name" => "subdomain_enum",
        "description" => "Subdomain enumeration via DNS resolution. Streams live discovered subdomains to the UI. Uses built-in wordlist extended by operator wordlist if active.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "domain"   => Dict("type" => "STRING", "description" => "Root domain, e.g. example.com"),
                "wordlist" => Dict("type" => "ARRAY",  "description" => "Custom prefix list (built-in used if omitted)", "items" => Dict("type" => "STRING")),
                "operator" => Dict("type" => "STRING", "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["domain"]
        )
    ),
    Dict(
        "name" => "tech_detect",
        "description" => "Fingerprint the tech stack — server, CMS (WordPress/Drupal/Joomla/Magento), framework (Laravel/Django/Rails), frontend (Next.js/React/Vue/Angular). Audits cookies for missing HttpOnly/Secure/SameSite.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"      => Dict("type" => "STRING", "description" => "URL to fingerprint"),
                "operator" => Dict("type" => "STRING", "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "param_probe",
        "description" => "Probe a URL parameter with 15 injection payloads — SQLi, XSS (3), LFI (2), SSTI (2), open redirect, SSRF, XXE, null byte, integer overflow. Detects confirmed findings by response diff. Streams critical findings live.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"      => Dict("type" => "STRING", "description" => "URL to probe"),
                "param"    => Dict("type" => "STRING", "description" => "Parameter name to inject into"),
                "payloads" => Dict("type" => "ARRAY",  "description" => "Custom payload list (built-in used if omitted)",
                    "items" => Dict("type" => "OBJECT",
                        "properties" => Dict(
                            "label" => Dict("type" => "STRING"),
                            "value" => Dict("type" => "STRING"),
                            "note"  => Dict("type" => "STRING"),
                        ),
                        "required" => ["label","value"])),
                "operator" => Dict("type" => "STRING", "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["url","param"]
        )
    ),
    # ── External CLI Security Tools ───────────────────────────────────────────
    Dict(
        "name" => "ffuf",
        "description" => "Fast web fuzzer. Place FUZZ keyword in the URL (path, param, header). Streams hits back. Defaults to SecLists/dirb wordlists in WSL. Supports custom path lists or inline wordlist arrays. Returns hits with status, length, word count.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"          => Dict("type" => "STRING",  "description" => "URL with FUZZ placeholder, e.g. https://target.com/FUZZ or https://target.com/api?id=FUZZ"),
                "wordlist"     => Dict("description" => "Wordlist: a filesystem path (string) or inline list of words (array of strings). Defaults to SecLists/dirb.", "oneOf" => [Dict("type" => "STRING"), Dict("type" => "ARRAY", "items" => Dict("type" => "STRING"))]),
                "match_codes"  => Dict("type" => "STRING",  "description" => "Status codes to match (default '200,204,301,302,307,401,403')"),
                "filter_codes" => Dict("type" => "STRING",  "description" => "Status codes to filter out (default '404')"),
                "threads"      => Dict("type" => "INTEGER", "description" => "Concurrent threads (default 40)"),
                "extra_flags"  => Dict("type" => "STRING",  "description" => "Extra ffuf flags, e.g. '-H \"Authorization: Bearer TOKEN\" -fs 0'"),
                "timeout_ms"   => Dict("type" => "INTEGER", "description" => "Total timeout ms (default 90000)"),
                "operator"     => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "nuclei",
        "description" => "Template-based vulnerability scanner. Runs ProjectDiscovery Nuclei against a target. Returns structured JSON findings with severity, template ID, and matched URL. Writes critical findings to memory.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "target"     => Dict("type" => "STRING",  "description" => "Target URL or domain"),
                "templates"  => Dict("type" => "STRING",  "description" => "Template path or tags, e.g. 'cves' or 'misconfiguration,exposures'. Omit for auto-selection."),
                "severity"   => Dict("type" => "STRING",  "description" => "Severity filter (default 'low,medium,high,critical')"),
                "tags"       => Dict("type" => "STRING",  "description" => "Tag filter, e.g. 'oast,cors,ssrf'"),
                "rate_limit" => Dict("type" => "INTEGER", "description" => "Requests per second (default 150)"),
                "timeout_ms" => Dict("type" => "INTEGER", "description" => "Total timeout ms (default 120000)"),
                "operator"   => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["target"]
        )
    ),
    Dict(
        "name" => "httpx",
        "description" => "Fast HTTP prober from ProjectDiscovery. Probes one or many hosts/URLs for liveness, status code, page title, tech stack, and content length. Returns structured JSON per host. Good for recon and subdomain probing.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "targets"    => Dict("description" => "Single URL string or array of URLs/domains to probe.", "oneOf" => [Dict("type" => "STRING"), Dict("type" => "ARRAY", "items" => Dict("type" => "STRING"))]),
                "ports"      => Dict("type" => "STRING",  "description" => "Extra ports to probe, e.g. '8080,8443,9200'"),
                "threads"    => Dict("type" => "INTEGER", "description" => "Concurrent threads (default 50)"),
                "timeout_ms" => Dict("type" => "INTEGER", "description" => "Total timeout ms (default 30000)"),
                "operator"   => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["targets"]
        )
    ),
    Dict(
        "name" => "sqlmap",
        "description" => "Automatic SQL injection detector. Runs sqlmap in batch mode (non-interactive) against a URL. Returns vulnerability status, injectable params, DBMS fingerprint, and sample payloads. Writes confirmed findings to memory.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"        => Dict("type" => "STRING",  "description" => "Target URL with parameters, e.g. https://target.com/item?id=1"),
                "data"       => Dict("type" => "STRING",  "description" => "POST body data, e.g. 'user=foo&pass=bar'"),
                "param"      => Dict("type" => "STRING",  "description" => "Specific parameter to test (sqlmap tests all if omitted)"),
                "level"      => Dict("type" => "INTEGER", "description" => "Test level 1-5 (default 1)"),
                "risk"       => Dict("type" => "INTEGER", "description" => "Risk level 1-3 (default 1)"),
                "technique"  => Dict("type" => "STRING",  "description" => "SQL injection techniques: B(oolean), E(rror), U(nion), S(tacked), T(ime-blind), Q(uery) — default all (BEUSTQ)"),
                "timeout_ms" => Dict("type" => "INTEGER", "description" => "Total timeout ms (default 120000)"),
                "operator"   => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "zap_scan",
        "description" => "OWASP ZAP web application scanner via REST API. Requires ZAP running in daemon mode (zaproxy -daemon -port 8080 -config api.disablekey=true). Modes: ping (check ZAP is up), spider (crawl target), active_scan (launch active scan, returns scan_id), alerts (get findings), full (spider then alerts).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"      => Dict("type" => "STRING",  "description" => "Target URL to scan (not needed for ping)"),
                "mode"     => Dict("type" => "STRING",  "description" => "ping | spider | active_scan | alerts | full", "enum" => ["ping","spider","active_scan","alerts","full"]),
                "zap_port" => Dict("type" => "INTEGER", "description" => "ZAP API port (default 8080)"),
                "api_key"  => Dict("type" => "STRING",  "description" => "ZAP API key (omit when api.disablekey=true)"),
                "operator" => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["mode"]
        )
    ),
    Dict(
        "name" => "mitm_flows",
        "description" => "Read and decode a saved mitmproxy flow file (.mitm) using mitmdump. Supports mitmproxy filter expressions to narrow results. Returns structured flow records with request/response details.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "flow_file" => Dict("type" => "STRING",  "description" => "Path to the .mitm flow file (WSL path on Windows, e.g. /home/user/capture.mitm)"),
                "filter"    => Dict("type" => "STRING",  "description" => "mitmproxy filter expression, e.g. '~url target.com' or '~m POST' or '~s 200'"),
                "limit"     => Dict("type" => "INTEGER", "description" => "Max flows to return (default 50)"),
                "timeout_ms"=> Dict("type" => "INTEGER", "description" => "Timeout ms (default 30000)"),
                "operator"  => Dict("type" => "STRING",  "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["flow_file"]
        )
    ),
    # ── HackerOne Program Intelligence ────────────────────────────────────────
    Dict(
        "name" => "hackerone_programs",
        "description" => "List HackerOne bug bounty programs you are enrolled in — name, handle, bounty eligibility, response SLA. Use this to find program handles for hackerone_scope and cascade_spawn.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict{String,Any}(),
            "required" => []
        )
    ),
    Dict(
        "name" => "hackerone_scope",
        "description" => "Fetch the structured scope for a HackerOne program — in-scope and out-of-scope assets with type (URL, WILDCARD, IP_ADDRESS, CIDR), bounty eligibility, max severity, and instructions. Pass the program handle (e.g. 'twitter', 'shopify'). Results are cached for the session.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "program" => Dict("type" => "STRING", "description" => "HackerOne program handle, e.g. 'twitter' or 'shopify'"),
            ),
            "required" => ["program"]
        )
    ),
    # ── Cascade Swarm Runner ───────────────────────────────────────────────────
    Dict(
        "name" => "cascade_spawn",
        "description" => "Spawn a Cascade swarm runner. Two modes: (1) cascade_spawn(program='shopify') — pulls HackerOne structured scope, extracts all in-scope URL/WILDCARD targets, launches fleet automatically. (2) cascade_spawn(target='example.com', program='shopify') — scope-gates a single target then runs pipeline. Phases: indexing → hypothesis_generation (MetaMorph) → validation_cycle (Balthazar) → escalation. HackerOne gate: only escalates when evidence_demand AND validation_strictness both exceed 0.85. Returns swarm_id — poll with cascade_status.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "program"  => Dict("type" => "STRING", "description" => "HackerOne program handle (e.g. 'shopify'). Without target, pulls scope and runs full fleet against all in-scope assets."),
                "target"   => Dict("type" => "STRING", "description" => "Single domain or URL to attack. If program also given, target is scope-gated before running."),
                "scope"    => Dict("type" => "STRING", "description" => "quick | standard | deep", "enum" => ["quick","standard","deep"]),
                "operator" => Dict("type" => "STRING", "description" => "Active operator (auto-detected if omitted)"),
                "recon"    => Dict("type" => "OBJECT", "description" => "Pre-collected recon data (runs auto-recon if omitted)"),
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "cascade_status",
        "description" => "Poll a Cascade swarm runner. Returns phase, after_state, confirmed/failed findings, evidence_demand, validation_strictness, and advisory. Omit swarm_id to see all active runners.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "swarm_id" => Dict("type" => "STRING", "description" => "Swarm ID from cascade_spawn (omit for all)"),
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "cascade_kill",
        "description" => "Terminate a running Cascade swarm runner.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "swarm_id" => Dict("type" => "STRING", "description" => "Swarm ID to kill"),
            ),
            "required" => ["swarm_id"]
        )
    ),
    Dict(
        "name" => "cascade_submit",
        "description" => "Manually submit a staged Cascade report to HackerOne after review. Only works on swarms in 'staged_for_review' status. Run cascade_status first to inspect the findings, then call this to send.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "swarm_id" => Dict("type" => "STRING", "description" => "Swarm ID from cascade_spawn"),
            ),
            "required" => ["swarm_id"]
        )
    ),
    Dict(
        "name" => "swarm_launch",
        "description" => "Distributed multi-target swarm — spawns one Cascade runner per target in parallel Julia Tasks. Returns fleet_id grouping all swarm_ids. Poll with cascade_status().",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "targets"  => Dict("type" => "ARRAY", "description" => "List of domains/URLs to hit in parallel", "items" => Dict("type" => "STRING")),
                "scope"    => Dict("type" => "STRING", "description" => "quick | standard | deep", "enum" => ["quick","standard","deep"]),
                "operator" => Dict("type" => "STRING", "description" => "Active operator (auto-detected if omitted)"),
            ),
            "required" => ["targets"]
        )
    ),
    # ── Persistent REPL Sessions ───────────────────────────────────────────────
    Dict(
        "name" => "repl_open",
        "description" => "Open a persistent REPL session that retains state (variables, imports, definitions) across multiple repl_exec calls. Supported languages: python, julia, node, ruby, lua, r, bash. Returns session_id. If session_id already exists, returns existing session info without restarting.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "lang"       => Dict("type" => "STRING", "description" => "Language: python, julia, node, ruby, lua, r, bash", "enum" => ["python","julia","node","ruby","lua","r","bash"]),
                "session_id" => Dict("type" => "STRING", "description" => "Custom name for this session (auto-generated if omitted). Use a descriptive name like 'recon_py' or 'exploit_js'."),
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "repl_exec",
        "description" => "Execute code in a persistent REPL session. State from previous calls (variables, imports, defined functions) is preserved. If session_id does not exist and auto_open=true (default), creates the session automatically using the lang parameter.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "session_id" => Dict("type" => "STRING", "description" => "Session ID from repl_open, or a custom name"),
                "code"       => Dict("type" => "STRING", "description" => "Code to execute in the session"),
                "lang"       => Dict("type" => "STRING", "description" => "Language (only needed if auto_open creates the session)", "enum" => ["python","julia","node","ruby","lua","r","bash"]),
                "timeout_s"  => Dict("type" => "INTEGER", "description" => "Max seconds to wait for output (default 30)"),
                "auto_open"  => Dict("type" => "BOOLEAN", "description" => "Create session automatically if it doesn't exist (default true)"),
            ),
            "required" => ["session_id","code"]
        )
    ),
    Dict(
        "name" => "repl_close",
        "description" => "Kill a persistent REPL session and clean up its process and temp files.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "session_id" => Dict("type" => "STRING", "description" => "Session ID to close"),
            ),
            "required" => ["session_id"]
        )
    ),
    Dict(
        "name" => "repl_list",
        "description" => "List all active persistent REPL sessions with their language, exec count, and creation time.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict{String,Any}(),
            "required" => []
        )
    ),
    # ── Burp Suite Bridge ──────────────────────────────────────────────────────
    Dict(
        "name" => "burp_ping",
        "description" => "Check if the JL Engine Bridge extension is loaded and running in Burp Suite. Returns history entry count. If unreachable, returns instructions for loading the extension.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict{String,Any}(),
            "required" => []
        )
    ),
    Dict(
        "name" => "burp_history",
        "description" => "Pull captured HTTP traffic from Burp Suite's proxy history via the JL Engine Bridge extension. Returns URL, method, status, response length, and timestamps. Add bodies=true to include full request/response bodies (10KB cap each).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "limit"  => Dict("type" => "INTEGER", "description" => "Max entries to return (default 50, max 500)"),
                "filter" => Dict("type" => "STRING",  "description" => "Filter by hostname or URL substring, e.g. 'shopify.com'"),
                "bodies" => Dict("type" => "BOOLEAN", "description" => "Include full request and response bodies (default false)"),
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "burp_triage_autoscore",
        "description" => "Analyze Burp bridge history and rank endpoints by likely auth/IDOR/security value. Prioritizes org-scoped data endpoints and downranks telemetry noise.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "limit" => Dict("type" => "INTEGER", "description" => "How many recent bridge entries to analyze (default 250, max 500)"),
                "top_n" => Dict("type" => "INTEGER", "description" => "How many top candidates to return (default 20)"),
                "filter" => Dict("type" => "STRING", "description" => "Optional bridge-side URL/host substring filter"),
                "anthropic_only" => Dict("type" => "BOOLEAN", "description" => "Limit analysis to claude.ai/anthropic hosts (default true)")
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "burp_mutation_recipe",
        "description" => "Generate safe, reproducible Repeater mutation steps for a captured URL (org UUID swap, conversation UUID swap, cookie-minimal replay).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url" => Dict("type" => "STRING", "description" => "Captured request URL to build mutations for"),
                "replacement_org" => Dict("type" => "STRING", "description" => "Org UUID to use for org-swap tests"),
                "replacement_conversation" => Dict("type" => "STRING", "description" => "Conversation UUID to use for conversation-swap tests")
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "burp_evidence_pack",
        "description" => "Build a sanitized evidence bundle from selected Burp history ids for report writing. Redacts cookies/auth headers and includes previews only.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "ids" => Dict("type" => "ARRAY", "description" => "History entry ids to package", "items" => Dict("type" => "INTEGER")),
                "limit" => Dict("type" => "INTEGER", "description" => "Bridge history scan limit while collecting ids (default 500)"),
                "filter" => Dict("type" => "STRING", "description" => "Optional bridge-side filter while collecting ids")
            ),
            "required" => ["ids"]
        )
    ),
    Dict(
        "name" => "burp_submission_draft",
        "description" => "One-shot Burp workflow: autoscore recent endpoints, collect sanitized evidence for top candidates, and produce a conservative HackerOne-style draft payload.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "limit" => Dict("type" => "INTEGER", "description" => "How many recent bridge entries to analyze (default 300)"),
                "top_n" => Dict("type" => "INTEGER", "description" => "How many top candidates to include (default 5)"),
                "filter" => Dict("type" => "STRING", "description" => "Optional bridge-side filter (default /api/organizations/)"),
                "title" => Dict("type" => "STRING", "description" => "Optional custom report draft title"),
                "export_path" => Dict("type" => "STRING", "description" => "Optional local file path to write the full draft JSON output")
            ),
            "required" => []
        )
    ),
    # ── Meta-reasoning sweep ───────────────────────────────────────────────────
    Dict(
        "name" => "meta_sweep",
        "description" => "Retrospective audit of recent tool results. Pulls the last N results you moved through quickly and asks you to re-examine each one: what did you assume was fine, what anomalies did you skip, what deserves a follow-up probe right now? Called automatically every 15 tool dispatches (you'll see __meta_sweep__ in the result). Also call manually any time you want to step back and double-check your work.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "n"     => Dict("type" => "INTEGER", "description" => "How many recent results to review (default 15)"),
                "focus" => Dict("type" => "STRING",  "description" => "Optional keyword or tool name to filter — e.g. 'http_probe' or 'shopify.com'"),
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "meta_log",
        "description" => "Explicitly flag something you noticed but are choosing to skip for now. It will appear in the next meta_sweep so you can investigate it later. Use this when you see something suspicious but want to finish your current thought first.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "item"       => Dict("type" => "STRING", "description" => "What you noticed — be specific (URL, header, value, behavior)"),
                "assumption" => Dict("type" => "STRING", "description" => "What you're assuming about it (e.g. 'probably just a CDN header')"),
                "context"    => Dict("type" => "STRING", "description" => "What you were doing when you noticed it"),
            ),
            "required" => ["item"]
        )
    ),
])]
