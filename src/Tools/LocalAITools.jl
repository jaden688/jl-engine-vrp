# LocalAITools.jl — Ollama and LM Studio local inference integrations
#
# Both tools talk to the OpenAI-compatible REST APIs each server exposes.
#   Ollama:    http://localhost:11434  (ollama serve)
#   LM Studio: http://localhost:1234   (LM Studio → Local Server → Start Server)
#
# Pass model="list" (or omit prompt) to list available/loaded models instead.

function _local_ai_post(url::String, payload::Dict; timeout_s::Int=120)
    body = JSON.json(payload)
    resp = HTTP.post(url, ["Content-Type" => "application/json"], body;
        status_exception=false, connect_timeout=5, readtimeout=timeout_s)
    return resp.status, String(resp.body)
end

function _local_ai_get(url::String; timeout_s::Int=10)
    resp = HTTP.get(url; status_exception=false, connect_timeout=3, readtimeout=timeout_s)
    return resp.status, String(resp.body)
end

# ── tool_ask_ollama ───────────────────────────────────────────────────────────

function tool_ask_ollama(args::Dict)
    prompt  = string(get(args, "prompt",      ""))
    model   = string(get(args, "model",       ""))
    system  = string(get(args, "system",      ""))
    host    = rstrip(string(get(args, "host", "http://localhost:11434")), '/')
    temp    = Float64(get(args, "temperature", 0.7))
    maxtok  = get(args, "max_tokens", nothing)
    timeout = Int(get(args, "timeout_s", 120))

    # ── model listing ─────────────────────────────────────────────────────────
    if model == "list" || (isempty(prompt) && isempty(model))
        try
            status, body = _local_ai_get("$host/api/tags")
            status != 200 && return Dict(
                "error" => "Ollama not reachable on $host (HTTP $status)",
                "tip"   => "Start it: ollama serve",
            )
            data   = JSON.parse(body)
            models = [Dict(
                "name"     => string(get(m, "name",        "")),
                "size_gb"  => round(Int(get(m, "size", 0)) / 1_073_741_824; digits=2),
                "modified" => string(get(m, "modified_at", "")),
            ) for m in get(data, "models", Any[])]
            return Dict("models" => models, "count" => length(models), "host" => host)
        catch e
            return Dict(
                "error" => "Ollama unreachable at $host: $e",
                "tip"   => "Install: https://ollama.com  |  Start: ollama serve",
            )
        end
    end

    isempty(prompt) && return Dict(
        "error" => "prompt is required. Pass model='list' to list installed models.")

    use_model = isempty(model) ? "llama3.2" : model

    messages = Any[]
    !isempty(system) && push!(messages, Dict("role" => "system", "content" => system))
    push!(messages, Dict("role" => "user", "content" => prompt))

    options = Dict{String,Any}("temperature" => temp)
    maxtok !== nothing && (options["num_predict"] = Int(maxtok))

    payload = Dict{String,Any}(
        "model"    => use_model,
        "messages" => messages,
        "stream"   => false,
        "options"  => options,
    )

    t0 = time()
    try
        status, body = _local_ai_post("$host/api/chat", payload; timeout_s=timeout)
        elapsed = round(time() - t0; digits=2)

        status != 200 && return Dict(
            "error"   => "Ollama returned HTTP $status",
            "body"    => first(body, 600),
            "host"    => host,
            "model"   => use_model,
        )

        data   = JSON.parse(body)
        reply  = string(get(get(data, "message", Dict()), "content", ""))
        mdl    = string(get(data, "model", use_model))
        tokens = Int(get(data, "eval_count", 0))
        tps    = get(data, "eval_duration", 0) > 0 ?
                    round(tokens / (Int(get(data, "eval_duration", 1)) / 1e9); digits=1) : 0.0

        return Dict(
            "reply"     => reply,
            "model"     => mdl,
            "tokens"    => tokens,
            "tok_per_s" => tps,
            "elapsed_s" => elapsed,
            "host"      => host,
            "status"    => "ok",
        )
    catch e
        return Dict(
            "error" => "Ollama request failed: $e",
            "host"  => host,
            "tip"   => "Is it running? ollama serve  |  Model missing? ollama pull $use_model",
        )
    end
end

# ── tool_ollama_pull ──────────────────────────────────────────────────────────
# Pull (download) a model. This can take minutes — use a generous timeout.

function tool_ollama_pull(args::Dict)
    model   = string(get(args, "model",   ""))
    host    = rstrip(string(get(args, "host", "http://localhost:11434")), '/')
    timeout = Int(get(args, "timeout_s",  600))

    isempty(model) && return Dict("error" => "model is required, e.g. 'llama3.2' or 'mistral'")

    payload = Dict("model" => model, "stream" => false)
    t0 = time()
    try
        status, body = _local_ai_post("$host/api/pull", payload; timeout_s=timeout)
        elapsed = round(time() - t0; digits=1)
        data    = try JSON.parse(body) catch _; Dict("status" => body) end
        return Dict(
            "model"     => model,
            "status"    => string(get(data, "status", "done")),
            "elapsed_s" => elapsed,
            "host"      => host,
        )
    catch e
        return Dict("error" => "ollama pull failed: $e", "model" => model)
    end
end

# ── tool_ask_lmstudio ─────────────────────────────────────────────────────────

function tool_ask_lmstudio(args::Dict)
    prompt  = string(get(args, "prompt",      ""))
    model   = string(get(args, "model",       ""))
    system  = string(get(args, "system",      ""))
    host    = rstrip(string(get(args, "host", "http://localhost:1234")), '/')
    temp    = Float64(get(args, "temperature", 0.7))
    maxtok  = get(args, "max_tokens", nothing)
    timeout = Int(get(args, "timeout_s", 120))

    # ── model listing ─────────────────────────────────────────────────────────
    if model == "list" || (isempty(prompt) && isempty(model))
        try
            status, body = _local_ai_get("$host/v1/models")
            status != 200 && return Dict(
                "error" => "LM Studio not reachable on $host (HTTP $status)",
                "tip"   => "Open LM Studio → Local Server tab → Start Server",
            )
            data   = JSON.parse(body)
            models = [string(get(m, "id", "")) for m in get(data, "data", Any[])]
            return Dict("models" => models, "count" => length(models), "host" => host)
        catch e
            return Dict(
                "error" => "LM Studio unreachable at $host: $e",
                "tip"   => "Open LM Studio → Local Server → Start Server (default port 1234)",
            )
        end
    end

    isempty(prompt) && return Dict(
        "error" => "prompt is required. Pass model='list' to list loaded models.")

    messages = Any[]
    !isempty(system) && push!(messages, Dict("role" => "system", "content" => system))
    push!(messages, Dict("role" => "user", "content" => prompt))

    payload = Dict{String,Any}(
        "messages"    => messages,
        "temperature" => temp,
        "stream"      => false,
    )
    !isempty(model)    && (payload["model"]      = model)
    maxtok !== nothing && (payload["max_tokens"] = Int(maxtok))

    t0 = time()
    try
        status, body = _local_ai_post("$host/v1/chat/completions", payload; timeout_s=timeout)
        elapsed = round(time() - t0; digits=2)

        status != 200 && return Dict(
            "error"  => "LM Studio returned HTTP $status",
            "body"   => first(body, 600),
            "host"   => host,
        )

        data      = JSON.parse(body)
        reply     = try string(data["choices"][1]["message"]["content"]) catch _; "" end
        mdl       = string(get(data, "model", isempty(model) ? "loaded-model" : model))
        usage     = get(data, "usage", Dict())
        tok_in    = Int(get(usage, "prompt_tokens",     0))
        tok_out   = Int(get(usage, "completion_tokens", 0))

        return Dict(
            "reply"      => reply,
            "model"      => mdl,
            "tokens_in"  => tok_in,
            "tokens_out" => tok_out,
            "elapsed_s"  => elapsed,
            "host"       => host,
            "status"     => "ok",
        )
    catch e
        return Dict(
            "error" => "LM Studio request failed: $e",
            "host"  => host,
            "tip"   => "Open LM Studio → Local Server → Start Server",
        )
    end
end

export tool_ask_ollama, tool_ollama_pull, tool_ask_lmstudio
