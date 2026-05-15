using HTTP, JSON3, Base64

const DEFAULT_OLLAMA_BASE_URL = get(ENV, "OLLAMA_BASE_URL", "http://127.0.0.1:11434")

abstract type AbstractBackend end

struct NoopBackend <: AbstractBackend
    config::Dict{String, Any}
end

struct OllamaBackend <: AbstractBackend
    config::Dict{String, Any}
end

struct OpenRouterBackend <: AbstractBackend
    config::Dict{String, Any}
end

struct CerebrasBackend <: AbstractBackend
    config::Dict{String, Any}
end

BACKEND_REGISTRY = Dict{String, Dict{String, Any}}(
    "noop-stub" => Dict{String, Any}(
        "id" => "noop-stub",
        "label" => "Stub (No backend)",
        "provider" => "noop",
    ),
    "openrouter" => Dict{String, Any}(
        "id" => "openrouter",
        "label" => "OpenRouter",
        "provider" => "openrouter",
        "base_url" => "https://openrouter.ai/api/v1/chat/completions",
        "model" => "google/gemma-3-27b-it:free",
        "api_key" => "",
        "env_key" => "OPENROUTER_API_KEY",
        "timeout" => 60,
    ),
    "cerebras" => Dict{String, Any}(
        "id" => "cerebras",
        "label" => "Cerebras",
        "provider" => "cerebras",
        "base_url" => "https://api.cerebras.ai/v1/chat/completions",
        "model" => "qwen-3-235b-a22b-instruct-2507",
        "api_key" => "",
        "env_key" => "CEREBRAS_API_KEY",
        "timeout" => 60,
    ),
    "ollama-local" => Dict{String, Any}(
        "id" => "ollama-local",
        "label" => "Ollama (Local)",
        "provider" => "ollama",
        "baseUrl" => DEFAULT_OLLAMA_BASE_URL,
        "modelName" => "qwen3:4b",
    ),
)

# Auto-detect best available backend from env vars on boot.
# Priority: OpenRouter → Cerebras → Ollama → noop.
function _detect_default_backend()
    !isempty(get(ENV, "OPENROUTER_API_KEY", "")) && return "openrouter"
    !isempty(get(ENV, "CEREBRAS_API_KEY", "")) && return "cerebras"
    return "ollama-local"
end

const _BOOT_BACKEND = _detect_default_backend()

const ACTIVE_BACKENDS = Dict{String, String}(
    "current" => _BOOT_BACKEND,
    "brain" => _BOOT_BACKEND,
    "tool" => _BOOT_BACKEND,
)

function set_backend_model!(backend_id::AbstractString, model_name::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return
    model_str = String(model_name)
    reg = BACKEND_REGISTRY[String(backend_id)]
    reg["modelName"] = model_str
    reg["model_name"] = model_str
    reg["model"] = model_str
end

function configure_backends!(; brain_id=nothing, tool_id=nothing)
    brain_id !== nothing && set_brain_backend_id!(String(brain_id))
    tool_id !== nothing && set_tool_backend_id!(String(tool_id))
    return ACTIVE_BACKENDS
end

function set_brain_backend_id!(backend_id::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return ACTIVE_BACKENDS
    ACTIVE_BACKENDS["brain"] = String(backend_id)
    ACTIVE_BACKENDS["current"] = String(backend_id)
    if isdefined(Main, :BYTE)
        reg = get(BACKEND_REGISTRY, backend_id, Dict())
        model = get(reg, "model", get(reg, "modelName", get(reg, "model_name", "")))
        !isempty(model) && Main.BYTE.set_current_model!(model; source=:backend_sync)
    end
    return ACTIVE_BACKENDS
end

function set_tool_backend_id!(backend_id::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return ACTIVE_BACKENDS
    ACTIVE_BACKENDS["tool"] = String(backend_id)
    return ACTIVE_BACKENDS
end

function get_backend(backend_id::Union{Nothing, AbstractString}=nothing; overrides=nothing)
    target_id = backend_id === nothing ? ACTIVE_BACKENDS["current"] : String(backend_id)
    config = deepcopy(get(BACKEND_REGISTRY, target_id, BACKEND_REGISTRY["noop-stub"]))
    if overrides isa AbstractDict
        merge!(config, Dict{String, Any}(string(key) => value for (key, value) in pairs(overrides)))
    end
    provider = String(get(config, "provider", "noop"))
    if provider == "ollama"
        return OllamaBackend(config)
    elseif provider == "openrouter"
        return OpenRouterBackend(config)
    elseif provider == "cerebras"
        return CerebrasBackend(config)
    end
    return NoopBackend(config)
end

get_brain_backend() = get_backend(ACTIVE_BACKENDS["brain"])
get_tool_backend() = get_backend(ACTIVE_BACKENDS["tool"])

"""
    sync_from_byte!()

Read the current model from BYTE and ensure Backends.jl's ACTIVE_BACKENDS
and BACKEND_REGISTRY reflect it.  Call after BYTE.init / engine build and
whenever BYTE's model changes.
"""
function sync_from_byte!()
    isdefined(Main, :BYTE) || return ACTIVE_BACKENDS
    model    = Main.BYTE.get_current_model()
    provider = Main.BYTE.get_provider_for_model(model)

    backend_id = if haskey(BACKEND_REGISTRY, provider)
        reg = BACKEND_REGISTRY[provider]
        reg["model"] = model
        reg["model_name"] = model
        reg["modelName"] = model
        prof = Main.BYTE.get_provider_profile(provider)
        ek = get(prof, "env_key", "")
        !isempty(ek) && (reg["env_key"] = ek)
        provider
    else
        prof = Main.BYTE.get_provider_profile(provider)
        ep = get(prof, "endpoint", "")
        ek = get(prof, "env_key", "")
        # Auto-register unknown provider as openrouter-routed entry
        BACKEND_REGISTRY[provider] = Dict{String, Any}(
            "id" => provider,
            "label" => "Auto-synced: $provider",
            "provider" => "openrouter",
            "base_url" => isempty(ep) ? "https://openrouter.ai/api/v1/chat/completions" : ep,
            "model" => model,
            "api_key" => "",
            "env_key" => isempty(ek) ? "OPENROUTER_API_KEY" : ek,
            "timeout" => 60,
        )
        provider
    end

    ACTIVE_BACKENDS["brain"]   = backend_id
    ACTIVE_BACKENDS["current"] = backend_id
    @info "Backends synced from BYTE" model=model backend_id=backend_id
    return ACTIVE_BACKENDS
end

function _message_content(messages)
    for message in Iterators.reverse(messages)
        if message isa AbstractDict && get(message, "role", nothing) == "user"
            content = get(message, "content", "")
            if content isa AbstractVector
                for part in content
                    if get(part, "type", "") == "text"
                        return String(get(part, "text", ""))
                    end
                end
            end
            return String(content)
        end
    end
    return ""
end

function _resolve_runtime_api_key(config::AbstractDict; fallback_env_keys::AbstractVector{<:AbstractString}=String[])
    explicit = get(config, "api_key", nothing)
    if explicit !== nothing
        explicit_key = strip(String(explicit))
        !isempty(explicit_key) && return explicit_key
    end
    for env_key in fallback_env_keys
        candidate = strip(String(env_key))
        isempty(candidate) && continue
        env_value = strip(get(ENV, candidate, ""))
        !isempty(env_value) && return env_value
    end
    return ""
end

# Shared OAI-format response parser used by OpenRouter and Cerebras.
function _parse_oai_choices(data::AbstractDict, backend_label::AbstractString)
    if haskey(data, "choices") && data["choices"] isa AbstractVector && !isempty(data["choices"])
        choice = data["choices"][1]
        if choice isa AbstractDict
            message = get(choice, "message", nothing)
            if message isa AbstractDict
                meta = Dict{String, Any}("backend" => backend_label, "raw" => data)
                for rkey in ("reasoning_content", "reasoning")
                    rv = get(message, rkey, nothing)
                    rv isa AbstractString && !isempty(rv) && (meta["thoughts"] = String(rv))
                end
                raw_tc = get(message, "tool_calls", nothing)
                if raw_tc isa AbstractVector && !isempty(raw_tc)
                    parsed = Any[]
                    for tc in raw_tc
                        tc isa AbstractDict || continue
                        fn = get(tc, "function", nothing)
                        fn isa AbstractDict || continue
                        name = String(get(fn, "name", ""))
                        isempty(name) && continue
                        raw_args = get(fn, "arguments", "{}")
                        args = try
                            _materialize_json(JSON3.read(raw_args isa AbstractString ? raw_args : JSON3.write(raw_args)))
                        catch
                            Dict{String, Any}()
                        end
                        push!(parsed, Dict{String, Any}(
                            "id"   => String(get(tc, "id", "")),
                            "name" => name,
                            "args" => args,
                        ))
                    end
                    isempty(parsed) || (meta["tool_calls"] = parsed)
                end
                text = get(message, "content", nothing)
                return (text === nothing || text == "" ? "" : String(text)), meta
            end
        end
    end
    return nothing, nothing
end

# ── Noop ──────────────────────────────────────────────────────────────────────

function generate(backend::NoopBackend, messages; options=Dict{String, Any}(), timeout=nothing, tools=nothing)
    return "[no backend reachable]", Dict{String, Any}("provider" => "noop", "status" => "no_backend", "model" => "noop-stub", "options" => options)
end

# ── Ollama ────────────────────────────────────────────────────────────────────

function generate(backend::OllamaBackend, messages; options=Dict{String, Any}(), timeout=30, tools=nothing)
    base_url = rstrip(String(get(backend.config, "baseUrl", DEFAULT_OLLAMA_BASE_URL)), '/')
    model = String(get(backend.config, "modelName", "qwen3:4b"))
    payload = Dict{String, Any}(
        "model" => model,
        "messages" => messages,
        "stream" => false,
    )
    !isempty(options) && (payload["options"] = options)
    if tools !== nothing && !isempty(tools)
        oai_tools = Any[]
        for t in (tools isa AbstractVector ? tools : [tools])
            push!(oai_tools, Dict{String, Any}("type" => "function", "function" => t))
        end
        payload["tools"] = oai_tools
    end
    try
        response = HTTP.post("$(base_url)/api/chat", ["Content-Type" => "application/json"], JSON3.write(payload); readtimeout=timeout)
        data = _materialize_json(JSON3.read(String(response.body)))
        if haskey(data, "error")
            return "[ERROR: Ollama reported an issue. Details: $(data["error"])]", Dict{String, Any}("error" => data["error"])
        end
        message = get(get(data, "message", Dict{String, Any}()), "content", "")
        text = String(message)
        isempty(strip(text)) && return "[ERROR: The local model returned an empty response.]", Dict{String, Any}("error" => "empty_reply")
        return text, Dict{String, Any}("model" => model, "backend" => "ollama")
    catch exc
        return "[ERROR: Could not connect to Ollama.]", Dict{String, Any}("error" => sprint(showerror, exc))
    end
end

# ── OpenRouter ────────────────────────────────────────────────────────────────

function generate(backend::OpenRouterBackend, messages; options=Dict{String, Any}(), timeout=nothing, tools=nothing)
    base_url = String(get(backend.config, "base_url", "https://openrouter.ai/api/v1/chat/completions"))
    model_name = String(get(backend.config, "model", get(backend.config, "model_name", "")))
    env_key = String(get(backend.config, "env_key", "OPENROUTER_API_KEY"))
    api_key = _resolve_runtime_api_key(backend.config; fallback_env_keys=[env_key])
    isempty(api_key) && return "[ERROR: OpenRouter API key not set. Set OPENROUTER_API_KEY.]", Dict{String, Any}(
        "backend" => "openrouter", "error" => "api_key_missing",
    )

    formatted_messages = Any[]
    for msg in messages
        role = get(msg, "role", "user")
        content = get(msg, "content", "")
        if content isa AbstractVector
            new_content = Any[]
            for item in content
                if get(item, "type", "") == "text"
                    push!(new_content, Dict("type" => "text", "text" => get(item, "text", "")))
                elseif get(item, "type", "") == "image"
                    mime = get(item, "mime", "image/png")
                    data = get(item, "image", "")
                    push!(new_content, Dict("type" => "image_url", "image_url" => Dict("url" => "data:$mime;base64,$data")))
                end
            end
            push!(formatted_messages, Dict("role" => role, "content" => new_content))
        else
            push!(formatted_messages, msg)
        end
    end

    payload = Dict{String, Any}(
        "model" => model_name,
        "messages" => formatted_messages,
        "stream" => false,
    )
    !isempty(options) && merge!(payload, options)
    if tools !== nothing && !isempty(tools)
        oai_tools = Any[]
        for t in (tools isa AbstractVector ? tools : [tools])
            push!(oai_tools, Dict{String, Any}("type" => "function", "function" => t))
        end
        payload["tools"] = oai_tools
        payload["tool_choice"] = "auto"
    end

    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $api_key",
    ]

    try
        json_str = String(JSON3.write(payload))
        response = HTTP.post(
            base_url, headers, json_str;
            readtimeout=(timeout === nothing ? get(backend.config, "timeout", 60) : timeout),
            status_exception=false,
        )
        response_text = String(response.body)
        if response.status < 200 || response.status >= 300
            return "[ERROR: OpenRouter returned HTTP $(response.status).]", Dict{String, Any}(
                "backend" => "openrouter", "error" => "http_$(response.status)",
                "status" => response.status, "body" => first(strip(response_text), 500),
            )
        end
        data = _materialize_json(JSON3.read(response_text))
        text, meta = _parse_oai_choices(data, "openrouter")
        text !== nothing && return text, meta
        return "[ERROR: OpenRouter returned an empty response.]", Dict{String, Any}("backend" => "openrouter", "error" => "empty_reply", "raw" => data)
    catch exc
        return "[ERROR: OpenRouter request failed.]", Dict{String, Any}("error" => sprint(showerror, exc))
    end
end

# ── Cerebras ──────────────────────────────────────────────────────────────────

function generate(backend::CerebrasBackend, messages; options=Dict{String, Any}(), timeout=nothing, tools=nothing)
    base_url = String(get(backend.config, "base_url", "https://api.cerebras.ai/v1/chat/completions"))
    model_name = String(get(backend.config, "model", get(backend.config, "model_name", "")))
    env_key = String(get(backend.config, "env_key", "CEREBRAS_API_KEY"))
    api_key = _resolve_runtime_api_key(backend.config; fallback_env_keys=[env_key])
    isempty(api_key) && return "[ERROR: Cerebras API key not set. Set CEREBRAS_API_KEY.]", Dict{String, Any}(
        "backend" => "cerebras", "error" => "api_key_missing",
    )

    payload = Dict{String, Any}(
        "model" => model_name,
        "messages" => messages,
        "stream" => false,
    )
    !isempty(options) && merge!(payload, options)
    if tools !== nothing && !isempty(tools)
        oai_tools = Any[]
        for t in (tools isa AbstractVector ? tools : [tools])
            push!(oai_tools, Dict{String, Any}("type" => "function", "function" => t))
        end
        payload["tools"] = oai_tools
        payload["tool_choice"] = "auto"
    end
    # gpt-oss models require these Cerebras-specific fields
    if startswith(string(model_name), "gpt-oss")
        payload["reasoning_effort"] = "medium"
        payload["max_completion_tokens"] = 32768
    end
    # Cerebras does not support top_p
    delete!(payload, "top_p")

    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $api_key",
    ]

    try
        json_str = String(JSON3.write(payload))
        response = HTTP.post(
            base_url, headers, json_str;
            readtimeout=(timeout === nothing ? get(backend.config, "timeout", 60) : timeout),
            status_exception=false,
        )
        response_text = String(response.body)
        if response.status < 200 || response.status >= 300
            return "[ERROR: Cerebras returned HTTP $(response.status).]", Dict{String, Any}(
                "backend" => "cerebras", "error" => "http_$(response.status)",
                "status" => response.status, "body" => first(strip(response_text), 500),
            )
        end
        data = _materialize_json(JSON3.read(response_text))
        text, meta = _parse_oai_choices(data, "cerebras")
        text !== nothing && return text, meta
        return "[ERROR: Cerebras returned an empty response.]", Dict{String, Any}("backend" => "cerebras", "error" => "empty_reply", "raw" => data)
    catch exc
        return "[ERROR: Cerebras request failed.]", Dict{String, Any}("error" => sprint(showerror, exc))
    end
end
