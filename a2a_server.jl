# a2a_server.jl — JL Engine A2A (Agent-to-Agent) HTTP endpoint
# Runs on port 8082 alongside SparkByte (8081)
# Implements Google A2A protocol: https://google.github.io/A2A
#
# Endpoints:
#   GET  /.well-known/agent.json   — Agent Card (discovery)
#   POST /                          — JSON-RPC 2.0 task handler
#   GET  /tasks/:id                 — Task status lookup
#   GET  /health                    — Health check

using HTTP
using JSON
using SQLite
using DataFrames
using UUIDs
using SHA
using Dates

# ─────────────────────────────────────────────
#  Config
# ─────────────────────────────────────────────

const A2A_PORT        = parse(Int, get(ENV, "A2A_PORT", "8082"))
const A2A_HOST        = get(ENV, "A2A_HOST", "0.0.0.0")
const A2A_PUBLIC_URL  = get(ENV, "A2A_PUBLIC_URL", "http://localhost:8081")
const A2A_AGENT_NAME  = get(ENV, "A2A_AGENT_NAME", "JL Engine")
const A2A_VERSION     = "1.1.0"
const A2A_PROTOCOL_VERSION = get(ENV, "A2A_PROTOCOL_VERSION", "1.0")
const A2A_DEFAULT_INPUT_MODES = ["text/plain", "application/json"]
const A2A_DEFAULT_OUTPUT_MODES = ["application/json", "text/plain"]

function _canonical_a2a_path(target::AbstractString)::String
    path = split(String(target), "?")[1]
    if path == "/a2a"
        return "/"
    elseif startswith(path, "/a2a/")
        return path[5:end]
    end
    return path
end

function _request_public_url(req::HTTP.Request)::String
    host = strip(HTTP.header(req, "X-Forwarded-Host", ""))
    isempty(host) && (host = strip(HTTP.header(req, "Host", "")))
    isempty(host) && return A2A_PUBLIC_URL

    scheme = strip(HTTP.header(req, "X-Forwarded-Proto", ""))
    if isempty(scheme)
        scheme = startswith(A2A_PUBLIC_URL, "https://") ? "https" : "http"
    end
    return "$(scheme)://$(host)"
end

include(joinpath(@__DIR__, "a2a_billing.jl"))

# ─────────────────────────────────────────────
#  SQLite task log
# ─────────────────────────────────────────────

function _a2a_init_db!(db::SQLite.DB)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS a2a_tasks (
            id          TEXT PRIMARY KEY,
            created_at  TEXT NOT NULL,
            api_key     TEXT,
            input       TEXT,
            tool        TEXT,
            args        TEXT,
            status      TEXT DEFAULT 'pending',
            result      TEXT,
            error       TEXT,
            elapsed_ms  INTEGER,
            completed_at TEXT
        )
    """)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS a2a_push_notification_configs (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            api_key TEXT,
            url TEXT NOT NULL,
            token TEXT,
            authentication_json TEXT,
            metadata_json TEXT,
            created_at TEXT,
            updated_at TEXT
        )
    """)
    _billing_init_db!(db)
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_a2a_push_task ON a2a_push_notification_configs(task_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_a2a_push_api_key ON a2a_push_notification_configs(api_key)")
end

function _a2a_log_task!(db, id, api_key, input, tool, args)
    SQLite.execute(db,
        "INSERT OR IGNORE INTO a2a_tasks (id, created_at, api_key, input, tool, args, status) VALUES (?,?,?,?,?,?,?)",
        (id, string(now(UTC)), api_key, input, tool, JSON.json(args), "running"))
end

function _a2a_update_task_snapshot!(db, id, task, status::AbstractString; error_msg::AbstractString="", elapsed_ms=nothing)
    completed_at = string(now(UTC))
    if elapsed_ms === nothing
        SQLite.execute(db,
            "UPDATE a2a_tasks SET status=?, result=?, error=?, completed_at=? WHERE id=?",
            (String(status), JSON.json(task), error_msg, completed_at, id))
    else
        SQLite.execute(db,
            "UPDATE a2a_tasks SET status=?, result=?, error=?, elapsed_ms=?, completed_at=? WHERE id=?",
            (String(status), JSON.json(task), error_msg, elapsed_ms, completed_at, id))
    end
end

function _a2a_complete_task!(db, id, result, elapsed_ms)
    _a2a_update_task_snapshot!(db, id, result, "TASK_STATE_COMPLETED"; elapsed_ms=elapsed_ms)
end

function _a2a_fail_task!(db, id, error_msg, elapsed_ms)
    task = Dict{String,Any}(
        "id" => string(id),
        "contextId" => string(id),
        "status" => Dict(
            "state" => "TASK_STATE_FAILED",
            "timestamp" => string(now(UTC)),
            "message" => Dict(
                "role" => "ROLE_AGENT",
                "parts" => _a2a_message_parts(error_msg),
                "messageId" => string(uuid4()),
                "taskId" => string(id),
                "contextId" => string(id),
            ),
        ),
        "history" => Any[],
        "artifacts" => Any[],
        "metadata" => Dict{String,Any}("error" => String(error_msg), "elapsed_ms" => elapsed_ms),
    )
    _a2a_update_task_snapshot!(db, id, task, "TASK_STATE_FAILED"; error_msg=String(error_msg), elapsed_ms=elapsed_ms)
end

function _a2a_get_task(db, id; history_length::Int=0)
    rows = SQLite.DBInterface.execute(db,
        "SELECT id, status, result, error, created_at, completed_at, elapsed_ms, tool, args FROM a2a_tasks WHERE id=?",
        (id,)) |> DataFrame
    isempty(rows) && return nothing

    r = rows[1, :]
    args = Dict{String,Any}()
    if !ismissing(r.args) && !isempty(strip(String(r.args)))
        parsed_args = try JSON.parse(String(r.args)) catch; nothing end
        parsed_args isa Dict && (args = Dict{String,Any}(parsed_args))
    end

    context_id = string(get(args, "contextId", get(args, "context_id", r.id)))
    completed_at = ismissing(r.completed_at) ? string(now(UTC)) : string(r.completed_at)
    elapsed_ms = ismissing(r.elapsed_ms) ? nothing : Int(r.elapsed_ms)

    parsed_result = nothing
    if !ismissing(r.result) && !isempty(strip(String(r.result)))
        parsed_result = try JSON.parse(String(r.result)) catch; nothing end
    end

    if parsed_result isa Dict && (
        lowercase(string(get(parsed_result, "kind", ""))) == "task" ||
        (haskey(parsed_result, "id") && haskey(parsed_result, "contextId") && haskey(parsed_result, "status"))
    )
        task = Dict{String,Any}(parsed_result)
    else
        history = get(args, "history", Any[])
        history = history isa AbstractVector ? collect(history) : Any[]
        input_text = string(get(args, "input", get(args, "text", ismissing(r.error) ? "" : string(r.error))))
        user_message = get(args, "message", nothing)
        if !(user_message isa Dict)
            user_message = Dict(
                "role" => "ROLE_USER",
                "parts" => _a2a_message_parts(input_text),
                "messageId" => string(get(args, "messageId", r.id)),
                "taskId" => string(r.id),
                "contextId" => context_id,
            )
        else
            user_message = Dict{String,Any}(user_message)
        end

        if isempty(history)
            history = [user_message]
        end

        artifacts = Any[]
        agent_message = nothing
        if !ismissing(r.result) && !isempty(strip(String(r.result)))
            if parsed_result !== nothing
                agent_text = _a2a_result_text(parsed_result)
                agent_message = Dict(
                    "role" => "ROLE_AGENT",
                    "parts" => _a2a_message_parts(agent_text),
                    "messageId" => string(uuid4()),
                    "taskId" => string(r.id),
                    "contextId" => context_id,
                )
                push!(history, agent_message)
                push!(artifacts, _a2a_task_artifact(parsed_result, string(get(args, "tool", "response"))))
            end
        end

        task = Dict{String,Any}(
            "id" => string(r.id),
            "contextId" => context_id,
            "status" => Dict{String,Any}(
                "state" => string(get(args, "status", r.status)),
                "timestamp" => completed_at,
            ),
            "history" => history,
            "artifacts" => artifacts,
            "metadata" => begin
                metadata_value = get(args, "metadata", Dict{String,Any}())
                metadata_value isa Dict ? Dict{String,Any}(metadata_value) : Dict{String,Any}()
            end,
        )
        if agent_message !== nothing
            task["status"]["message"] = agent_message
        end
    end

    task = _a2a_normalize_task!(task)

    if history_length > 0 && haskey(task, "history") && task["history"] isa AbstractVector
        history = collect(task["history"])
        length(history) > history_length && (task["history"] = history[end-history_length+1:end])
    end

    if elapsed_ms !== nothing
        task["metadata"]["elapsed_ms"] = elapsed_ms
    end
    task["metadata"]["task_id"] = string(r.id)
    return task
end

# ─────────────────────────────────────────────
#  Agent Card
# ─────────────────────────────────────────────

function _a2a_message_parts(text::AbstractString)
    trimmed = strip(String(text))
    isempty(trimmed) && return Any[]
    return [Dict("text" => trimmed, "mediaType" => "text/plain")]
end

function _a2a_result_text(result)::String
    if result isa AbstractString
        return String(result)
    elseif result isa Dict && haskey(result, "text")
        return string(result["text"])
    elseif result isa Dict && haskey(result, "data") && result["data"] isa AbstractString
        return string(result["data"])
    elseif result isa Dict && haskey(result, "error")
        return string(result["error"])
    end
    return JSON.json(result)
end

function _a2a_message_record(role::AbstractString, text::AbstractString, task_id::AbstractString, context_id::AbstractString; message_id::AbstractString=string(uuid4()))
    return Dict(
        "role" => _a2a_proto_role(role),
        "parts" => _a2a_message_parts(text),
        "messageId" => message_id,
        "taskId" => string(task_id),
        "contextId" => string(context_id),
    )
end

function _a2a_task_artifact(result, tool::AbstractString; name::Union{Nothing,AbstractString}=nothing)
    parts = Any[]
    if result isa AbstractString
        push!(parts, Dict("text" => String(result), "mediaType" => "text/plain"))
    elseif result isa Dict
        if haskey(result, "text")
            push!(parts, Dict("text" => string(result["text"]), "mediaType" => "text/plain"))
        end
        if !(length(result) == 1 && haskey(result, "text"))
            push!(parts, Dict("data" => result, "mediaType" => "application/json"))
        end
    else
        push!(parts, Dict("data" => result, "mediaType" => "application/json"))
    end
    return Dict(
        "artifactId" => string(uuid4()),
        "name" => isnothing(name) ? (tool == "chat" ? "response" : tool) : String(name),
        "parts" => parts,
    )
end

function _a2a_limit_history(history, history_length::Int)
    history_length <= 0 && return history
    history isa AbstractVector || return history
    items = collect(history)
    length(items) <= history_length && return items
    return items[end-history_length+1:end]
end

function _a2a_proto_role(role::AbstractString)::String
    normalized = lowercase(strip(String(role)))
    normalized in ("user", "role_user") && return "ROLE_USER"
    normalized in ("agent", "role_agent") && return "ROLE_AGENT"
    normalized in ("system", "role_system") && return "ROLE_SYSTEM"
    return "ROLE_UNSPECIFIED"
end

function _a2a_proto_task_state(state::AbstractString)::String
    normalized = lowercase(strip(String(state)))
    normalized in ("submitted", "task_state_submitted") && return "TASK_STATE_SUBMITTED"
    normalized in ("working", "running", "pending", "task_state_working") && return "TASK_STATE_WORKING"
    normalized in ("completed", "task_state_completed") && return "TASK_STATE_COMPLETED"
    normalized in ("failed", "task_state_failed") && return "TASK_STATE_FAILED"
    normalized in ("canceled", "cancelled", "task_state_canceled", "task_state_cancelled") && return "TASK_STATE_CANCELED"
    normalized in ("input-required", "input_required", "task_state_input_required") && return "TASK_STATE_INPUT_REQUIRED"
    normalized in ("auth-required", "auth_required", "task_state_auth_required") && return "TASK_STATE_AUTH_REQUIRED"
    normalized in ("rejected", "task_state_rejected") && return "TASK_STATE_REJECTED"
    return uppercase(replace(strip(String(state)), "-" => "_"))
end

function _a2a_normalize_message!(message::Dict{String,Any})
    message["role"] = _a2a_proto_role(string(get(message, "role", "ROLE_UNSPECIFIED")))
    message["messageId"] = string(get(message, "messageId", get(message, "message_id", string(uuid4()))))
    message["taskId"] = string(get(message, "taskId", get(message, "task_id", "")))
    message["contextId"] = string(get(message, "contextId", get(message, "context_id", "")))
    parts = get(message, "parts", Any[])
    normalized_parts = Any[]
    if parts isa AbstractVector
        for part in parts
            part isa Dict || continue
            item = Dict{String,Any}(part)
            if haskey(item, "mimeType") && !haskey(item, "mediaType")
                item["mediaType"] = item["mimeType"]
                delete!(item, "mimeType")
            elseif haskey(item, "media_type") && !haskey(item, "mediaType")
                item["mediaType"] = item["media_type"]
                delete!(item, "media_type")
            end
            push!(normalized_parts, item)
        end
    end
    message["parts"] = normalized_parts
    if haskey(message, "metadata") && message["metadata"] isa Dict
        message["metadata"] = Dict{String,Any}(message["metadata"])
    end
    return message
end

function _a2a_normalize_task!(task::Dict{String,Any})
    haskey(task, "kind") && delete!(task, "kind")
    task["id"] = string(get(task, "id", ""))
    task["contextId"] = string(get(task, "contextId", get(task, "context_id", task["id"])))

    status = haskey(task, "status") && task["status"] isa Dict ? Dict{String,Any}(task["status"]) : Dict{String,Any}()
    status["state"] = _a2a_proto_task_state(string(get(status, "state", "TASK_STATE_SUBMITTED")))
    status["timestamp"] = string(get(status, "timestamp", string(now(UTC))))
    if haskey(status, "message") && status["message"] isa Dict
        status["message"] = _a2a_normalize_message!(Dict{String,Any}(status["message"]))
    end
    task["status"] = status

    history = get(task, "history", Any[])
    normalized_history = Any[]
    if history isa AbstractVector
        for item in history
            item isa Dict || continue
            push!(normalized_history, _a2a_normalize_message!(Dict{String,Any}(item)))
        end
    end
    task["history"] = normalized_history

    artifacts = get(task, "artifacts", Any[])
    normalized_artifacts = Any[]
    if artifacts isa AbstractVector
        for artifact in artifacts
            artifact isa Dict || continue
            item = Dict{String,Any}(artifact)
            if haskey(item, "artifact_id") && !haskey(item, "artifactId")
                item["artifactId"] = item["artifact_id"]
                delete!(item, "artifact_id")
            end
            parts = get(item, "parts", Any[])
            normalized_parts = Any[]
            if parts isa AbstractVector
                for part in parts
                    part isa Dict || continue
                    p = Dict{String,Any}(part)
                    if haskey(p, "mimeType") && !haskey(p, "mediaType")
                        p["mediaType"] = p["mimeType"]
                        delete!(p, "mimeType")
                    elseif haskey(p, "media_type") && !haskey(p, "mediaType")
                        p["mediaType"] = p["media_type"]
                        delete!(p, "media_type")
                    end
                    push!(normalized_parts, p)
                end
            end
            item["parts"] = normalized_parts
            push!(normalized_artifacts, item)
        end
    end
    task["artifacts"] = normalized_artifacts

    if haskey(task, "metadata") && task["metadata"] isa Dict
        task["metadata"] = Dict{String,Any}(task["metadata"])
    else
        task["metadata"] = Dict{String,Any}()
    end

    return task
end

function _a2a_skill_from_decl(decl)::Dict{String,Any}
    name = string(get(decl, "name", ""))
    desc = string(get(decl, "description", ""))
    tags = String[]
    if occursin("file", name)
        push!(tags, "file", "io")
    end
    if occursin("code", name)
        push!(tags, "code", "execute")
    end
    if occursin("command", name)
        push!(tags, "shell")
    end
    if occursin("browse", name) || occursin("playwright", name)
        push!(tags, "web", "browser")
    end
    if occursin("github", name)
        push!(tags, "github", "code")
    end
    if occursin("memory", name) || name in ("remember", "recall")
        push!(tags, "memory")
    end
    if occursin("forge", name)
        push!(tags, "meta", "self-extending")
    end
    if occursin("sms", name)
        push!(tags, "sms", "notify")
    end
    if occursin("discord", name)
        push!(tags, "discord", "community", "notify")
    end
    if occursin("pages", name)
        push!(tags, "deploy", "web", "github")
    end
    if occursin("bluetooth", name)
        push!(tags, "hardware", "bluetooth")
    end
    if occursin("agent", name) || occursin("card", name)
        push!(tags, "agent")
    end
    isempty(tags) && push!(tags, "utility")
    short_desc = isempty(desc) ? "" : (length(desc) > 120 ? first(desc, 120) : desc)
    examples = isempty(short_desc) ? String[] : [short_desc]
    return Dict(
        "id" => name,
        "name" => titlecase(replace(name, "_" => " ")),
        "description" => short_desc,
        "tags" => unique(tags),
        "examples" => examples,
        "inputModes" => copy(A2A_DEFAULT_INPUT_MODES),
        "outputModes" => copy(A2A_DEFAULT_OUTPUT_MODES),
    )
end

function _a2a_skill_records()
    return map(BYTE.TOOLS_SCHEMA[1]["function_declarations"]) do decl
        _a2a_skill_from_decl(decl)
    end
end

function _a2a_billing_skill_records()
    return [
        Dict(
            "id" => "billing-status",
            "name" => "Billing Status",
            "description" => "Inspect subscription status, usage, and estimated spend for an API key.",
            "tags" => ["billing", "usage", "admin"],
            "examples" => ["Check subscription status and current usage"],
            "inputModes" => copy(A2A_DEFAULT_INPUT_MODES),
            "outputModes" => copy(A2A_DEFAULT_OUTPUT_MODES),
        ),
        Dict(
            "id" => "billing-checkout",
            "name" => "Billing Checkout",
            "description" => "Return the hosted payment link and checkout metadata for a customer key.",
            "tags" => ["billing", "checkout", "payments"],
            "examples" => ["Start a checkout for a new customer"],
            "inputModes" => copy(A2A_DEFAULT_INPUT_MODES),
            "outputModes" => copy(A2A_DEFAULT_OUTPUT_MODES),
        ),
        Dict(
            "id" => "billing-portal",
            "name" => "Billing Portal",
            "description" => "Return the hosted customer portal link for subscription management.",
            "tags" => ["billing", "portal", "payments"],
            "examples" => ["Open the customer billing portal"],
            "inputModes" => copy(A2A_DEFAULT_INPUT_MODES),
            "outputModes" => copy(A2A_DEFAULT_OUTPUT_MODES),
        ),
        Dict(
            "id" => "billing-link",
            "name" => "Billing Link",
            "description" => "Activate or update a key after payment, webhook processing, or manual approval.",
            "tags" => ["billing", "admin", "payments"],
            "examples" => ["Mark a key active after payment"],
            "inputModes" => copy(A2A_DEFAULT_INPUT_MODES),
            "outputModes" => copy(A2A_DEFAULT_OUTPUT_MODES),
        ),
    ]
end

function _a2a_auth_scheme_details()
    return Dict(
        "bearerAuth" => Dict(
            "httpAuthSecurityScheme" => Dict(
                "scheme" => "Bearer",
                "bearerFormat" => "API key",
                "description" => "Bearer token required for authenticated and paid access",
            )
        )
    )
end

function _a2a_auth_requirements()
    return [Dict("schemes" => Dict("bearerAuth" => Dict("list" => String[])))]
end

# ── Fetch.ai / FET payment commerce block ───────────────────────────────────

const _FETCH_WALLET_PATH = joinpath(@__DIR__, "data", "fetch_wallet.json")

function _load_fetch_wallet()
    isfile(_FETCH_WALLET_PATH) || return nothing
    try
        return JSON3.read(read(_FETCH_WALLET_PATH, String), Dict{String,Any})
    catch
        return nothing
    end
end

function _fetch_commerce_configured()
    w = _load_fetch_wallet()
    return w !== nothing && haskey(w, "address") && !isempty(get(w, "address", ""))
end

function _fetch_pricing_block()
    w = _load_fetch_wallet()
    per_call = get(w, "per_call_fet", 0.1)
    free     = get(w, "free_calls_per_ip", 5)
    return Dict{String,Any}(
        "model"          => "per_call",
        "currency"       => "FET",
        "per_call"       => per_call,
        "free_calls"     => free,
        "free_call_note" => "First $free calls per IP are free. Include tx_hash in request after that.",
    )
end

function _fetch_payment_block()
    w = _load_fetch_wallet()
    return Dict{String,Any}(
        "chain"     => get(w, "network", "fetchhub-4"),
        "denom"     => get(w, "denom",   "afet"),
        "address"   => get(w, "address", ""),
        "lcd_url"   => get(w, "lcd_url", "https://rest-fetchhub.fetch.ai"),
        "memo_note" => "Include your tx hash as 'payment_tx' in the JSON-RPC params.",
    )
end

# ── Payment gate: verify FET tx before executing paid calls ─────────────────

function _a2a_verify_payment(tx_hash::String)::Bool
    w = _load_fetch_wallet()
    w === nothing && return false
    address      = get(w, "address", "")
    per_call_fet = get(w, "per_call_fet", 0.1)
    afet_needed  = Int(round(per_call_fet * 1_000_000_000_000_000_000))  # 1 FET = 1e18 afet
    script = joinpath(@__DIR__, "scripts", "verify_fetch_payment.py")
    result = run(ignorestatus(`python $script $tx_hash $afet_needed $address`))
    return result.exitcode == 0
end

function _a2a_agent_card(public_url::AbstractString=A2A_PUBLIC_URL; authenticated::Bool=false)
    base_url = rstrip(strip(String(public_url)), '/')
    skills = _a2a_skill_records()
    if authenticated
        append!(skills, _a2a_billing_skill_records())
    end

    card = Dict{String,Any}(
        "name" => A2A_AGENT_NAME,
        "description" => "Julia-native AI agent engine with behavioral middleware stack (DriftPressure, RhythmEngine, EmotionalAperture), persistent SQLite memory, self-extending tool forge, browser automation, Discord/SMS outreach, and GitHub Pages deployment. Built on JL Engine — runs at native speed.",
        "version" => A2A_VERSION,
        "provider" => Dict("organization" => "JL Engine", "url" => base_url),
        "capabilities" => Dict(
            "streaming" => true,
            "pushNotifications" => true,
            "extendedAgentCard" => _a2a_auth_required(),
        ),
        "supportedInterfaces" => [Dict(
            "url" => base_url,
            "protocolBinding" => "JSONRPC",
            "protocolVersion" => A2A_PROTOCOL_VERSION,
        )],
        "defaultInputModes" => copy(A2A_DEFAULT_INPUT_MODES),
        "defaultOutputModes" => copy(A2A_DEFAULT_OUTPUT_MODES),
        "skills" => skills,
    )

    if _a2a_auth_required()
        card["securitySchemes"] = _a2a_auth_scheme_details()
        card["securityRequirements"] = _a2a_auth_requirements()
    end

    # ACP: advertise pricing + payment info so other agents (and ACP clients
    # like ChatGPT Instant Checkout) can discover what it costs and where to pay.
    if _fetch_commerce_configured()
        card["pricing"] = _fetch_pricing_block()
        card["payment"] = _fetch_payment_block()
    end

    # Privacy disclosure — Alberta PIPA compliance
    card["privacy"] = Dict{String,Any}(
        "policy_url"       => "$base_url/privacy",
        "jurisdiction"     => "Alberta, Canada — PIPA",
        "data_collected"   => ["message content", "hashed IP (daily rotation)", "task history"],
        "data_retained_days" => parse(Int, strip(get(ENV, "SPARKBYTE_DATA_RETENTION_DAYS", "90"))),
        "pii_handling"     => "PII scrubbed before storage (emails, phones, IPs, SINs redacted)",
        "data_subject_rights" => "$base_url/privacy/request",
        "contact"          => "jadenlindenbach@gmail.com",
    )

    return card
end

function _a2a_legacy_agent_card(public_url::AbstractString=A2A_PUBLIC_URL)
    base_url = rstrip(strip(String(public_url)), '/')
    card = _a2a_agent_card(public_url)
    legacy = Dict(
        "name" => card["name"],
        "description" => card["description"],
        "url" => base_url,
        "version" => card["version"],
        "provider" => card["provider"],
        "capabilities" => Dict(
            "streaming" => true,
            "pushNotifications" => true,
            "stateTransitionHistory" => true,
        ),
        "authentication" => [Dict(
            "scheme" => _a2a_auth_scheme(),
            "credentials" => _a2a_auth_scheme() == "bearer" ? "Bearer token required — contact agent owner for key" : "Open development access",
        )],
        "defaultInputModes" => copy(A2A_DEFAULT_INPUT_MODES),
        "defaultOutputModes" => copy(A2A_DEFAULT_OUTPUT_MODES),
        "additionalInterfaces" => [Dict(
            "url" => base_url,
            "transport" => "JSONRPC",
            "protocolVersion" => A2A_PROTOCOL_VERSION,
        )],
        "preferredTransport" => "JSONRPC",
        "skills" => card["skills"],
        "tool_count" => length(card["skills"]),
        "generated_at" => string(now(UTC)),
    )

    # Mirror ACP pricing into legacy card too
    if _fetch_commerce_configured()
        legacy["pricing"] = _fetch_pricing_block()
        legacy["payment"] = _fetch_payment_block()
    end

    return legacy
end

# ─────────────────────────────────────────────
#  Auth
# ─────────────────────────────────────────────

function _check_auth(req::HTTP.Request, db::Union{SQLite.DB,Nothing}=nothing)::Union{Nothing, HTTP.Response}
    return _a2a_check_auth(req, db)
end

# ─────────────────────────────────────────────
#  JSON-RPC helpers
# ─────────────────────────────────────────────

_rpc_result(id, result) = Dict("jsonrpc"=>"2.0", "id"=>id, "result"=>result)
_rpc_error(id, code, msg) = Dict("jsonrpc"=>"2.0", "id"=>id,
    "error"=>Dict("code"=>code, "message"=>msg))

# ─────────────────────────────────────────────
#  Task executor
# ─────────────────────────────────────────────

function _extract_tool_and_args(message_text::String)
    # Try to parse as JSON tool call: {"tool": "...", "args": {...}}
    try
        parsed = JSON.parse(message_text)
        if haskey(parsed, "tool")
            return string(parsed["tool"]), get(parsed, "args", Dict{String,Any}())
        end
    catch; end

    # Plain text → send as user_msg to the engine (chat mode)
    return "chat", Dict{String,Any}("text" => message_text)
end

function _run_task(task_id::String, message_text::String, db, engine_ref)
    t0 = time_ns()
    tool, args = _extract_tool_and_args(message_text)

    result = try
        if tool == "chat"
            # Route through engine as a conversation turn
            if engine_ref !== nothing
                resp = Main.JLEngine.process_turn(engine_ref[], args["text"])
                reply_text = if resp isa AbstractDict
                    something(get(resp, "reply", nothing), get(resp, "text", nothing), string(resp))
                else
                    string(resp)
                end
                # Surface a thought bubble for regular chats too — same lifecycle
                # the autopilot loop uses, so the UI lights up consistently.
                # If the backend captured a chain-of-thought (Gemini reasoning,
                # OpenAI o-series, etc.) expose it as a separate "cot" event so
                # the UI can render the reasoning trace, not just the answer.
                try
                    if isdefined(Main, :Autopilot) && isdefined(Main.Autopilot, :_autopilot_broadcast)
                        meta = resp isa AbstractDict ? resp : Dict{String,Any}()
                        telem = get(meta, "telemetry", Dict())
                        backend_meta = telem isa AbstractDict ? get(telem, "backend_meta", Dict()) : Dict()
                        cot = backend_meta isa AbstractDict ? get(backend_meta, "thoughts", "") : ""
                        if !isempty(cot)
                            Main.Autopilot._autopilot_broadcast(Dict{String,Any}(
                                "type"=>"thinking", "text"=>"Processing reasoning..."
                            ))
                            sleep(0.1)
                            Main.Autopilot._autopilot_broadcast(Dict{String,Any}(
                                "type"=>"thinking_done", "text"=>cot, "chars"=>length(cot)
                            ))
                        end
                        Main.Autopilot._autopilot_broadcast(Dict{String,Any}(
                            "type"=>"autopilot_thinking", "tick"=>round(Int, time() * 1000),
                            "topic"=>"chat", "text"=>reply_text,
                            "gait"=>get(meta, "gait", ""), "done"=>true,
                            "source"=>"chat",
                        ))
                    end
                catch e; @warn "chat thought broadcast failed" exception=e; end
                Dict("text" => reply_text, "source" => "engine", "meta" => resp)
            else
                Dict("error" => "Engine not available in A2A context")
            end
        else
            # Direct BYTE tool dispatch
            BYTE.dispatch(tool, args)
        end
    catch e
        Dict("error" => string(e))
    end

    elapsed = round(Int, (time_ns() - t0) / 1e6)

    return result, elapsed
end

function _a2a_is_terminal_task_state(state::AbstractString)::Bool
    st = uppercase(strip(String(state)))
    return st in (
        "COMPLETED",
        "FAILED",
        "CANCELED",
        "CANCELLED",
        "REJECTED",
        "TASK_STATE_COMPLETED",
        "TASK_STATE_FAILED",
        "TASK_STATE_CANCELED",
        "TASK_STATE_CANCELLED",
        "TASK_STATE_REJECTED",
    )
end

function _a2a_message_text(message)::String
    message isa Dict || return ""
    parts = get(message, "parts", Any[])
    texts = String[]
    if parts isa AbstractVector
        for part in parts
            part isa Dict || continue
            txt = get(part, "text", nothing)
            if txt !== nothing
                s = strip(String(txt))
                isempty(s) || push!(texts, s)
                continue
            end
            data = get(part, "data", nothing)
            data !== nothing && push!(texts, JSON.json(data))
        end
    end
    if isempty(texts)
        raw = strip(String(get(message, "text", "")))
        isempty(raw) || push!(texts, raw)
    end
    return join(texts, "\n")
end

function _a2a_task_snapshot(
    task_id::AbstractString,
    context_id::AbstractString,
    state::AbstractString,
    history,
    artifacts,
    metadata::Dict{String,Any};
    status_message=nothing,
    completed_at::AbstractString=string(now(UTC)),
)
    status = Dict{String,Any}(
        "state" => String(state),
        "timestamp" => completed_at,
    )
    status_message !== nothing && (status["message"] = status_message)
    task = Dict{String,Any}(
        "id" => string(task_id),
        "contextId" => string(context_id),
        "status" => status,
        "history" => history,
        "artifacts" => artifacts,
        "metadata" => metadata,
    )
    return _a2a_normalize_task!(task)
end

function _a2a_stream_response(task::Dict{String,Any}; event::AbstractString="task")::HTTP.Response
    payload = JSON.json(Dict(String(event) => task))
    body = "event: $(event)\n" * "data: $(payload)\n\n"
    return HTTP.Response(200, [
        "Content-Type" => "text/event-stream; charset=utf-8",
        "Cache-Control" => "no-cache",
        "Connection" => "keep-alive",
        "Access-Control-Allow-Origin" => "*",
    ], body)
end

function _a2a_status_update_payload(task::Dict{String,Any})::Dict{String,Any}
    status = haskey(task, "status") && task["status"] isa Dict ? Dict{String,Any}(task["status"]) : Dict{String,Any}()
    payload = Dict{String,Any}(
        "taskId" => string(get(task, "id", "")),
        "contextId" => string(get(task, "contextId", "")),
        "status" => status,
    )
    metadata = haskey(task, "metadata") && task["metadata"] isa Dict ? Dict{String,Any}(task["metadata"]) : Dict{String,Any}()
    isempty(metadata) || (payload["metadata"] = metadata)
    return payload
end

function _a2a_push_config_row_to_dict(r)::Dict{String,Any}
    auth = Dict{String,Any}()
    if !ismissing(r.authentication_json) && !isempty(strip(String(r.authentication_json)))
        parsed_auth = try JSON.parse(String(r.authentication_json)) catch; nothing end
        parsed_auth isa AbstractDict && (auth = Dict{String,Any}(string(k) => v for (k, v) in pairs(parsed_auth)))
    end
    return Dict{String,Any}(
        "id" => string(r.id),
        "taskId" => string(r.task_id),
        "url" => string(r.url),
        "token" => ismissing(r.token) ? "" : string(r.token),
        "authentication" => auth,
        "createdAt" => ismissing(r.created_at) ? "" : string(r.created_at),
        "updatedAt" => ismissing(r.updated_at) ? "" : string(r.updated_at),
    )
end

function _a2a_get_push_notification_config(db::SQLite.DB, config_id::AbstractString)
    key = strip(String(config_id))
    isempty(key) && return nothing
    rows = SQLite.DBInterface.execute(db, """
        SELECT id, task_id, api_key, url, token, authentication_json, metadata_json, created_at, updated_at
        FROM a2a_push_notification_configs
        WHERE id=?
    """, (key,)) |> DataFrame
    isempty(rows) && return nothing
    return _a2a_push_config_row_to_dict(rows[1, :])
end

function _a2a_list_push_notification_configs(db::SQLite.DB; task_id::AbstractString="", api_key::AbstractString="")
    sql = "SELECT id, task_id, api_key, url, token, authentication_json, metadata_json, created_at, updated_at FROM a2a_push_notification_configs"
    clauses = String[]
    args = Any[]
    if !isempty(strip(String(task_id)))
        push!(clauses, "task_id=?")
        push!(args, strip(String(task_id)))
    end
    if !isempty(strip(String(api_key)))
        push!(clauses, "api_key=?")
        push!(args, strip(String(api_key)))
    end
    if !isempty(clauses)
        sql *= " WHERE " * join(clauses, " AND ")
    end
    rows = SQLite.DBInterface.execute(db, sql, Tuple(args)) |> DataFrame
    return [ _a2a_push_config_row_to_dict(rows[i, :]) for i in 1:nrow(rows) ]
end

function _a2a_upsert_push_notification_config!(
    db::SQLite.DB,
    task_id::AbstractString,
    api_key::AbstractString,
    params::Dict{String,Any},
)
    key = strip(String(get(params, "id", get(params, "configId", get(params, "pushNotificationConfigId", string(uuid4()))))))
    url = strip(String(get(params, "url", "")))
    isempty(url) && error("push notification config url is required")
    token = string(get(params, "token", ""))
    auth = get(params, "authentication", Dict{String,Any}())
    auth_json = auth isa Dict ? JSON.json(auth) : "{}"
    metadata = get(params, "metadata", Dict{String,Any}())
    metadata_json = metadata isa Dict ? JSON.json(metadata) : "{}"
    now_text = string(now(UTC))
    SQLite.execute(db, """
        INSERT OR REPLACE INTO a2a_push_notification_configs
        (id, task_id, api_key, url, token, authentication_json, metadata_json, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?)
    """, (key, strip(String(task_id)), strip(String(api_key)), url, token, auth_json, metadata_json, now_text, now_text))
    return _a2a_get_push_notification_config(db, key)
end

function _a2a_delete_push_notification_config!(db::SQLite.DB, config_id::AbstractString)
    key = strip(String(config_id))
    isempty(key) && return false
    SQLite.execute(db, "DELETE FROM a2a_push_notification_configs WHERE id=?", (key,))
    return true
end

function _a2a_dispatch_push_notifications!(db::SQLite.DB, task::Dict{String,Any})
    task_id = string(get(task, "id", ""))
    isempty(task_id) && return nothing
    configs = _a2a_list_push_notification_configs(db; task_id=task_id)
    isempty(configs) && return nothing
    payload = JSON.json(Dict("statusUpdate" => _a2a_status_update_payload(task)))
    for cfg in configs
        url = strip(String(get(cfg, "url", "")))
        isempty(url) && continue
        headers = ["Content-Type" => "application/json"]
        token = strip(String(get(cfg, "token", "")))
        isempty(token) || push!(headers, "X-A2A-Token" => token)
        auth = get(cfg, "authentication", Dict{String,Any}())
        if auth isa Dict && haskey(auth, "scheme") && haskey(auth, "credentials")
            scheme = isempty(strip(String(auth["scheme"]))) ? "Bearer" : strip(String(auth["scheme"]))
            creds = strip(String(auth["credentials"]))
            isempty(creds) || push!(headers, "Authorization" => "$(scheme) $(creds)")
        end
        try
            HTTP.request("POST", url, headers, payload; status_exception=false)
        catch e
            @warn "A2A push notification delivery failed" task_id=task_id url=url exception=(e, catch_backtrace())
        end
    end
    return nothing
end

function _a2a_extract_push_config(params::AbstractDict)
    if haskey(params, "taskPushNotificationConfig") && params["taskPushNotificationConfig"] isa Dict
        return Dict{String,Any}(params["taskPushNotificationConfig"])
    elseif haskey(params, "task_push_notification_config") && params["task_push_notification_config"] isa Dict
        return Dict{String,Any}(params["task_push_notification_config"])
    elseif haskey(params, "pushNotification") && params["pushNotification"] isa Dict
        return Dict{String,Any}(params["pushNotification"])
    elseif haskey(params, "pushNotificationConfig") && params["pushNotificationConfig"] isa Dict
        return Dict{String,Any}(params["pushNotificationConfig"])
    elseif haskey(params, "configuration")
        configuration = params["configuration"]
        if configuration isa AbstractDict
            for key in ("taskPushNotificationConfig", "task_push_notification_config", "pushNotification", "pushNotificationConfig")
                if haskey(configuration, key) && configuration[key] isa Dict
                    return Dict{String,Any}(configuration[key])
                end
            end
        end
    end
    return nothing
end

function _a2a_handle_message_rpc(req::HTTP.Request, db::SQLite.DB, rpc_id, meth::AbstractString, params::Dict{String,Any}, engine_ref; stream::Bool=false)::Union{Nothing,HTTP.Response}
    meth in ("message/send", "SendMessage", "tasks/send", "message/stream", "SendStreamingMessage") || return nothing
    auth_err = _a2a_check_auth(req, db)
    auth_err !== nothing && return auth_err

    # FET payment gate — only active if wallet is configured
    if _fetch_commerce_configured()
        tx_hash   = string(get(params, "payment_tx", ""))
        raw_ip    = string(get(Dict(req.headers), "X-Forwarded-For", get(Dict(req.headers), "X-Real-IP", "unknown")))
        # Hash the IP — we never store raw IPs (Alberta PIPA compliance)
        # Salt = daily bucket so hashes rotate and can't be cross-referenced over time
        day_salt  = string(get(ENV, "SPARKBYTE_IP_SALT", "jlengine")) * Dates.format(now(), "yyyy-mm-dd")
        caller_ip = bytes2hex(sha256(raw_ip * day_salt))   # store hash only
        # Check free call quota via usage ledger
        free_allowed = get(_load_fetch_wallet(), "free_calls_per_ip", 5)
        used_free = try
            r = SQLite.DBInterface.execute(db, "SELECT COUNT(*) as n FROM a2a_usage_ledger WHERE account_id=? AND charged_afet=0", [caller_ip]) |> DataFrames.DataFrame
            nrow(r) > 0 ? Int(r[1,:n]) : 0
        catch; 0 end
        if used_free >= free_allowed && isempty(tx_hash)
            w = _load_fetch_wallet()
            return HTTP.Response(402, ["Content-Type" => "application/json"], JSON.json(Dict(
                "error"   => "payment_required",
                "message" => "Free quota exhausted. Send FET to pay for this call.",
                "payment" => _fetch_payment_block(),
                "pricing" => _fetch_pricing_block(),
            )))
        end
        if !isempty(tx_hash) && !_a2a_verify_payment(tx_hash)
            return HTTP.Response(402, ["Content-Type" => "application/json"], JSON.json(Dict(
                "error"   => "payment_invalid",
                "message" => "Could not verify payment tx on Fetch.ai mainnet.",
                "tx_hash" => tx_hash,
            )))
        end
    end

    message = get(params, "message", Dict{String,Any}())
    message = message isa Dict ? Dict{String,Any}(message) : Dict{String,Any}()
    configuration = get(params, "configuration", Dict{String,Any}())
    configuration = configuration isa Dict ? Dict{String,Any}(configuration) : Dict{String,Any}()

    task_id = string(get(message, "taskId", get(params, "taskId", get(params, "id", string(uuid4())))))
    current_task = _a2a_get_task(db, task_id)
    if current_task !== nothing && _a2a_is_terminal_task_state(string(get(get(current_task, "status", Dict{String,Any}()), "state", "")))
        return HTTP.Response(200, ["Content-Type" => "application/json"],
            JSON.json(_rpc_error(rpc_id, -32002, "Task already completed and cannot be restarted: $task_id")))
    end

    context_id = string(get(message, "contextId", get(params, "contextId", current_task === nothing ? string(uuid4()) : string(get(current_task, "contextId", task_id)))))
    message_id = string(get(message, "messageId", get(params, "messageId", string(uuid4()))))
    history_length = try
        parse(Int, string(get(configuration, "historyLength", get(params, "historyLength", 0))))
    catch
        0
    end

    existing_history = Any[]
    if current_task !== nothing && haskey(current_task, "history") && current_task["history"] isa AbstractVector
        existing_history = collect(current_task["history"])
    end

    user_parts = get(message, "parts", Any[])
    user_parts isa AbstractVector || (user_parts = Any[])
    if isempty(user_parts)
        user_parts = _a2a_message_parts(_a2a_message_text(message))
    end
    user_message = Dict{String,Any}(
        "role" => "ROLE_USER",
        "parts" => user_parts,
        "messageId" => message_id,
        "taskId" => task_id,
        "contextId" => context_id,
    )

    text = _a2a_message_text(message)
    tool, args = _extract_tool_and_args(text)
    api_key = _a2a_request_key(req)
    entitlement_err = _a2a_task_entitlement_block(db, api_key, task_id, text, tool)
    entitlement_err !== nothing && return entitlement_err

    push_cfg = _a2a_extract_push_config(params)
    if push_cfg !== nothing
        _a2a_upsert_push_notification_config!(db, task_id, api_key, Dict{String,Any}(push_cfg))
    end

    task_args = Dict{String,Any}(
        "message" => user_message,
        "contextId" => context_id,
        "messageId" => message_id,
        "input" => text,
        "tool" => tool,
        "toolArgs" => args,
        "history" => vcat(existing_history, [user_message]),
        "configuration" => configuration,
        "metadata" => haskey(params, "metadata") && params["metadata"] isa Dict ? Dict{String,Any}(params["metadata"]) : Dict{String,Any}(),
    )
    push_cfg !== nothing && (task_args["taskPushNotificationConfig"] = Dict{String,Any}(push_cfg))
    _a2a_log_task!(db, task_id, api_key, text, tool, task_args)

    result, elapsed = _run_task(task_id, text, db, engine_ref)
    status_state = haskey(result, "error") ? "TASK_STATE_FAILED" : "TASK_STATE_COMPLETED"
    agent_text = _a2a_result_text(result)
    agent_message = _a2a_message_record("agent", agent_text, task_id, context_id)
    push!(existing_history, user_message)
    push!(existing_history, agent_message)

    artifacts = status_state == "TASK_STATE_COMPLETED" ? [ _a2a_task_artifact(result, tool) ] : Any[]
    metadata = haskey(task_args, "metadata") && task_args["metadata"] isa Dict ? Dict{String,Any}(task_args["metadata"]) : Dict{String,Any}()
    metadata["tool"] = tool
    metadata["elapsed_ms"] = elapsed
    metadata["request_chars"] = length(text)
    metadata["streaming"] = stream

    task = _a2a_task_snapshot(
        task_id,
        context_id,
        status_state,
        _a2a_limit_history(existing_history, history_length),
        artifacts,
        metadata;
        status_message=agent_message,
    )

    if status_state == "TASK_STATE_COMPLETED"
        _a2a_complete_task!(db, task_id, task, elapsed)
    else
        _a2a_update_task_snapshot!(db, task_id, task, "TASK_STATE_FAILED"; error_msg=agent_text, elapsed_ms=elapsed)
    end

    _a2a_record_usage!(db, api_key, task_id, meth, text, task;
        tool_calls=(tool == "chat" ? 0 : 1),
        status=status_state,
        metadata=Dict{String,Any}("tool" => tool, "elapsed_ms" => elapsed, "streaming" => stream))
    _a2a_dispatch_push_notifications!(db, task)

    rpc_result = meth == "tasks/send" ? task : Dict("task" => task)
    return stream ? _a2a_stream_response(task) : HTTP.Response(200,
        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
        JSON.json(_rpc_result(rpc_id, rpc_result)))
end

function _a2a_handle_tasks_get_rpc(req::HTTP.Request, db::SQLite.DB, rpc_id, params::Dict{String,Any})::Union{Nothing,HTTP.Response}
    meth = "tasks/get"
    auth_err = _a2a_check_auth(req, db)
    auth_err !== nothing && return auth_err
    task_id = string(get(params, "id", ""))
    isempty(task_id) && return HTTP.Response(200, ["Content-Type" => "application/json"],
        JSON.json(_rpc_error(rpc_id, -32602, "Task id is required")))
    history_length = try
        parse(Int, string(get(params, "historyLength", 0)))
    catch
        0
    end
    task = _a2a_get_task(db, task_id; history_length=history_length)
    task === nothing && return HTTP.Response(200, ["Content-Type" => "application/json"],
        JSON.json(_rpc_error(rpc_id, -32001, "Task not found: $task_id")))
    return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
        JSON.json(_rpc_result(rpc_id, task)))
end

function _a2a_handle_tasks_cancel_rpc(req::HTTP.Request, db::SQLite.DB, rpc_id, params::Dict{String,Any})::Union{Nothing,HTTP.Response}
    auth_err = _a2a_check_auth(req, db)
    auth_err !== nothing && return auth_err
    task_id = string(get(params, "id", ""))
    isempty(task_id) && return HTTP.Response(200, ["Content-Type" => "application/json"],
        JSON.json(_rpc_error(rpc_id, -32602, "Task id is required")))
    task = _a2a_get_task(db, task_id)
    task === nothing && return HTTP.Response(200, ["Content-Type" => "application/json"],
        JSON.json(_rpc_error(rpc_id, -32001, "Task not found: $task_id")))
    state = string(get(get(task, "status", Dict{String,Any}()), "state", ""))
    if _a2a_is_terminal_task_state(state)
        return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
            JSON.json(_rpc_result(rpc_id, task)))
    end

    context_id = string(get(task, "contextId", task_id))
    history = haskey(task, "history") && task["history"] isa AbstractVector ? collect(task["history"]) : Any[]
    cancel_message = _a2a_message_record("agent", "Task canceled", task_id, context_id)
    push!(history, cancel_message)
    metadata = haskey(task, "metadata") && task["metadata"] isa Dict ? Dict{String,Any}(task["metadata"]) : Dict{String,Any}()
    metadata["canceled"] = true
    metadata["cancelled_at"] = string(now(UTC))
    task = _a2a_task_snapshot(task_id, context_id, "TASK_STATE_CANCELED", history, get(task, "artifacts", Any[]), metadata; status_message=cancel_message)
    _a2a_update_task_snapshot!(db, task_id, task, "TASK_STATE_CANCELED"; elapsed_ms=get(metadata, "elapsed_ms", nothing))
    return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
        JSON.json(_rpc_result(rpc_id, task)))
end

function _a2a_handle_task_resubscribe_rpc(req::HTTP.Request, db::SQLite.DB, rpc_id, meth::AbstractString, params::Dict{String,Any})::Union{Nothing,HTTP.Response}
    meth in ("tasks/resubscribe", "TaskResubscriptionRequest") || return nothing
    auth_err = _a2a_check_auth(req, db)
    auth_err !== nothing && return auth_err
    task_id = string(get(params, "id", get(params, "taskId", get(params, "task_id", ""))))
    isempty(task_id) && return HTTP.Response(200, ["Content-Type" => "application/json"],
        JSON.json(_rpc_error(rpc_id, -32602, "Task id is required")))
    task = _a2a_get_task(db, task_id)
    task === nothing && return HTTP.Response(200, ["Content-Type" => "application/json"],
        JSON.json(_rpc_error(rpc_id, -32001, "Task not found: $task_id")))
    return _a2a_stream_response(task)
end

function _a2a_handle_extended_card_rpc(req::HTTP.Request, db::SQLite.DB, rpc_id, public_url::AbstractString)::Union{Nothing,HTTP.Response}
    auth_err = _a2a_check_auth(req, db)
    auth_err !== nothing && return auth_err
    if !_a2a_auth_required()
        return HTTP.Response(200, ["Content-Type" => "application/json"],
            JSON.json(_rpc_error(rpc_id, -32601, "Method not found: GetExtendedAgentCard")))
    end
    # Support both the older camelCase alias and the v1 agent-scoped method name.
    card = _a2a_agent_card(public_url; authenticated=true)
    return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
        JSON.json(_rpc_result(rpc_id, card)))
end

function _a2a_handle_push_config_rpc(req::HTTP.Request, db::SQLite.DB, rpc_id, meth::AbstractString, params::Dict{String,Any})::Union{Nothing,HTTP.Response}
    methods = Set([
        "tasks/pushNotificationConfig/set",
        "tasks/pushNotificationConfig/get",
        "tasks/pushNotificationConfig/list",
        "tasks/pushNotificationConfig/delete",
        "CreatePushNotificationConfig",
        "GetPushNotificationConfig",
        "ListPushNotificationConfigs",
        "DeletePushNotificationConfig",
        "CreateTaskPushNotificationConfig",
        "GetTaskPushNotificationConfig",
        "ListTaskPushNotificationConfigs",
        "DeleteTaskPushNotificationConfig",
    ])
    meth in methods || return nothing
    auth_err = _a2a_check_auth(req, db; require_admin=true)
    auth_err !== nothing && return auth_err

    if meth in ("tasks/pushNotificationConfig/set", "CreatePushNotificationConfig", "CreateTaskPushNotificationConfig")
        task_id = string(get(params, "taskId", get(params, "task_id", "")))
        isempty(task_id) && return HTTP.Response(200, ["Content-Type" => "application/json"],
            JSON.json(_rpc_error(rpc_id, -32602, "taskId is required")))
        api_key = string(get(params, "apiKey", get(params, "api_key", _a2a_request_key(req))))
        cfg = _a2a_upsert_push_notification_config!(db, task_id, api_key, params)
        result = Dict("taskId" => task_id, "pushNotificationConfig" => cfg)
        return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
            JSON.json(_rpc_result(rpc_id, result)))
    elseif meth in ("tasks/pushNotificationConfig/get", "GetPushNotificationConfig", "GetTaskPushNotificationConfig")
        config_id = string(get(params, "id", get(params, "configId", get(params, "pushNotificationConfigId", ""))))
        if !isempty(config_id)
            cfg = _a2a_get_push_notification_config(db, config_id)
            cfg === nothing && return HTTP.Response(200, ["Content-Type" => "application/json"],
                JSON.json(_rpc_error(rpc_id, -32001, "Push notification config not found: $config_id")))
            return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                JSON.json(_rpc_result(rpc_id, cfg)))
        end
        task_id = string(get(params, "taskId", get(params, "task_id", "")))
        configs = _a2a_list_push_notification_configs(db; task_id=task_id)
        result = isempty(task_id) ? Dict("items" => configs) : Dict("taskId" => task_id, "items" => configs)
        return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
            JSON.json(_rpc_result(rpc_id, result)))
    elseif meth in ("tasks/pushNotificationConfig/list", "ListTaskPushNotificationConfigs", "ListPushNotificationConfigs")
        task_id = string(get(params, "taskId", get(params, "task_id", "")))
        api_key = string(get(params, "apiKey", get(params, "api_key", "")))
        configs = _a2a_list_push_notification_configs(db; task_id=task_id, api_key=api_key)
        result = Dict("items" => configs)
        isempty(task_id) || (result["taskId"] = task_id)
        return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
            JSON.json(_rpc_result(rpc_id, result)))
    elseif meth in ("tasks/pushNotificationConfig/delete", "DeletePushNotificationConfig", "DeleteTaskPushNotificationConfig")
        config_id = string(get(params, "id", get(params, "configId", get(params, "pushNotificationConfigId", ""))))
        isempty(config_id) && return HTTP.Response(200, ["Content-Type" => "application/json"],
            JSON.json(_rpc_error(rpc_id, -32602, "config id is required")))
        cfg = _a2a_get_push_notification_config(db, config_id)
        cfg === nothing && return HTTP.Response(200, ["Content-Type" => "application/json"],
            JSON.json(_rpc_error(rpc_id, -32001, "Push notification config not found: $config_id")))
        SQLite.execute(db, "DELETE FROM a2a_push_notification_configs WHERE id=?", (config_id,))
        result = Dict("deleted" => true, "id" => config_id, "pushNotificationConfig" => cfg)
        return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
            JSON.json(_rpc_result(rpc_id, result)))
    end

    return nothing
end

# ─────────────────────────────────────────────
#  HTTP router
# ─────────────────────────────────────────────

function _handle_request(req::HTTP.Request, db::SQLite.DB, engine_ref; public_url::AbstractString=A2A_PUBLIC_URL)::HTTP.Response
    _a2a_init_db!(db)
    path   = _canonical_a2a_path(req.target)
    method = string(req.method)

    # ── Health ───────────────────────────────
    if path == "/health" || path == "/a2a/health"
        return HTTP.Response(200, ["Content-Type"=>"application/json"],
            JSON.json(Dict("status"=>"ok", "engine"=>"JL Engine", "version"=>A2A_VERSION,
                           "port"=>A2A_PORT, "timestamp"=>string(now(UTC)))))
    end

    # ── Agent Card ──────────────────────────
    if path == "/.well-known/agent-card.json" && method == "GET"
        return HTTP.Response(200,
            ["Content-Type"=>"application/json", "Access-Control-Allow-Origin"=>"*"],
            JSON.json(_a2a_agent_card(public_url), 2))
    elseif path == "/.well-known/agent.json" && method == "GET"
        return HTTP.Response(200,
            ["Content-Type"=>"application/json", "Access-Control-Allow-Origin"=>"*"],
            JSON.json(_a2a_legacy_agent_card(public_url), 2))
    elseif path == "/extendedAgentCard" && method == "GET"
        auth_err = _a2a_check_auth(req, db)
        auth_err !== nothing && return auth_err
        if !_a2a_auth_required()
            return HTTP.Response(404, ["Content-Type" => "application/json"],
                JSON.json(Dict("error" => "Authenticated extended card is not enabled")))
        end
        return HTTP.Response(200, ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
            JSON.json(_a2a_agent_card(public_url; authenticated=true), 2))
    end

    # ── Task status ──────────────────────────
    if startswith(path, "/tasks/") && method == "GET"
        task_id = path[8:end]  # strip /tasks/
        auth_err = _a2a_check_auth(req, db)
        auth_err !== nothing && return auth_err

        task = _a2a_get_task(db, task_id)
        task === nothing && return HTTP.Response(404, ["Content-Type"=>"application/json"],
            JSON.json(Dict("error"=>"Task not found: $task_id")))
        return HTTP.Response(200, ["Content-Type"=>"application/json", "Access-Control-Allow-Origin"=>"*"],
            JSON.json(task, 2))
    end

    # ── JSON-RPC 2.0 task handler ────────────
    if path == "/" && method == "POST"
        body = try JSON.parse(String(req.body)) catch
            return HTTP.Response(400, ["Content-Type"=>"application/json"],
                JSON.json(_rpc_error(nothing, -32700, "Parse error — invalid JSON")))
        end
        body = body isa AbstractDict ? Dict{String,Any}(body) : Dict{String,Any}()

        rpc_id = get(body, "id", nothing)
        meth   = string(get(body, "method", ""))
        params = get(body, "params", Dict{String,Any}())
        params = params isa AbstractDict ? Dict{String,Any}(params) : Dict{String,Any}()

        billing_resp = _a2a_handle_billing_rpc(req, db, rpc_id, meth, params)
        billing_resp !== nothing && return billing_resp

        message_resp = _a2a_handle_message_rpc(req, db, rpc_id, meth, params, engine_ref; stream=meth in ("message/stream", "SendStreamingMessage"))
        message_resp !== nothing && return message_resp

        task_get_resp = meth in ("tasks/get", "GetTask") ? _a2a_handle_tasks_get_rpc(req, db, rpc_id, params) : nothing
        task_get_resp !== nothing && return task_get_resp

        task_cancel_resp = meth in ("tasks/cancel", "CancelTask") ? _a2a_handle_tasks_cancel_rpc(req, db, rpc_id, params) : nothing
        task_cancel_resp !== nothing && return task_cancel_resp

        resubscribe_resp = meth in ("tasks/resubscribe", "TaskResubscriptionRequest") ? _a2a_handle_task_resubscribe_rpc(req, db, rpc_id, meth, params) : nothing
        resubscribe_resp !== nothing && return resubscribe_resp

        extended_card_resp = meth in ("GetExtendedAgentCard", "GetAuthenticatedExtendedCard", "agent/getAuthenticatedExtendedCard") ? _a2a_handle_extended_card_rpc(req, db, rpc_id, public_url) : nothing
        extended_card_resp !== nothing && return extended_card_resp

        push_config_resp = startswith(meth, "tasks/pushNotificationConfig/") || startswith(meth, "Create") || startswith(meth, "Get") || startswith(meth, "List") || startswith(meth, "Delete") ? _a2a_handle_push_config_rpc(req, db, rpc_id, meth, params) : nothing
        push_config_resp !== nothing && return push_config_resp

        supported_methods = [
            "message/send", "SendMessage", "tasks/send",
            "message/stream", "SendStreamingMessage",
            "tasks/get", "GetTask",
            "tasks/cancel", "CancelTask",
            "tasks/resubscribe", "TaskResubscriptionRequest",
            "GetExtendedAgentCard", "GetAuthenticatedExtendedCard", "agent/getAuthenticatedExtendedCard",
            "tasks/pushNotificationConfig/set", "CreatePushNotificationConfig", "CreateTaskPushNotificationConfig",
            "tasks/pushNotificationConfig/get", "GetPushNotificationConfig", "GetTaskPushNotificationConfig",
            "tasks/pushNotificationConfig/list", "ListPushNotificationConfigs", "ListTaskPushNotificationConfigs",
            "tasks/pushNotificationConfig/delete", "DeletePushNotificationConfig", "DeleteTaskPushNotificationConfig",
        ]
        return HTTP.Response(200, ["Content-Type"=>"application/json"],
            JSON.json(_rpc_error(rpc_id, -32601, "Method not found: $meth. Supported: $(join(supported_methods, ", "))")))
    end

    # ── Privacy policy (Alberta PIPA compliance) ─────────────────────────────
    if path == "/privacy" && method == "GET"
        policy_path = joinpath(@__DIR__, "PRIVACY.md")
        policy_text = isfile(policy_path) ? read(policy_path, String) : "Privacy policy not found."
        return HTTP.Response(200, [
            "Content-Type"  => "text/markdown; charset=utf-8",
            "Access-Control-Allow-Origin" => "*",
            "Cache-Control" => "public, max-age=86400",
        ], policy_text)
    end

    # ── Data-subject rights endpoint (PIPA s. 25) ────────────────────────────
    # Accepts: POST /privacy/request  body: { type, identifier, details }
    # type = "access" | "deletion" | "correction"
    if path == "/privacy/request"
        if method == "OPTIONS"
            return HTTP.Response(204, [
                "Access-Control-Allow-Origin"=>"*",
                "Access-Control-Allow-Methods"=>"POST, OPTIONS",
                "Access-Control-Allow-Headers"=>"Content-Type",
            ])
        end
        method != "POST" && return HTTP.Response(405,
            ["Content-Type"=>"application/json"],
            JSON.json(Dict("error"=>"Method Not Allowed — use POST")))

        req_body = try JSON.parse(String(req.body)) catch
            return HTTP.Response(400, ["Content-Type"=>"application/json"],
                JSON.json(Dict("error"=>"Invalid JSON body")))
        end
        req_body = req_body isa AbstractDict ? Dict{String,Any}(req_body) : Dict{String,Any}()
        req_type   = strip(string(get(req_body, "type", "")))
        identifier = strip(string(get(req_body, "identifier", "")))
        details    = strip(string(get(req_body, "details", "")))

        req_type in ("access", "deletion", "correction") || return HTTP.Response(400,
            ["Content-Type"=>"application/json"],
            JSON.json(Dict("error"=>"type must be 'access', 'deletion', or 'correction'")))
        isempty(identifier) && return HTTP.Response(400,
            ["Content-Type"=>"application/json"],
            JSON.json(Dict("error"=>"identifier (IP address or session ID) is required")))

        # Log the request to a dedicated table for operator follow-up
        try
            _a2a_init_db!(db)
            SQLite.execute(db, """
                CREATE TABLE IF NOT EXISTS privacy_requests (
                    id          TEXT PRIMARY KEY,
                    created_at  TEXT NOT NULL,
                    type        TEXT NOT NULL,
                    identifier  TEXT NOT NULL,
                    details     TEXT,
                    status      TEXT DEFAULT 'pending'
                )
            """)
            SQLite.execute(db,
                "INSERT INTO privacy_requests (id, created_at, type, identifier, details) VALUES (?,?,?,?,?)",
                (string(uuid4()), string(now(UTC)), req_type, identifier, details))
        catch e
            @warn "Failed to log privacy request" exception=e
        end

        # For deletion requests: immediately wipe matching records from telemetry tables
        deletion_counts = Dict{String,Int}()
        if req_type == "deletion"
            try
                for tbl in ("telemetry", "thoughts", "turn_snapshots")
                    try
                        r = SQLite.DBInterface.execute(db,
                            "DELETE FROM $tbl WHERE session_id=? OR message LIKE ?",
                            (identifier, "%$identifier%")) |> DataFrame
                        deletion_counts[tbl] = 0  # SQLite DELETE doesn't return count easily; we just confirm it ran
                    catch; end
                end
                # Also wipe usage ledger entries matching the hashed identifier
                try
                    SQLite.execute(db,
                        "DELETE FROM a2a_usage_ledger WHERE account_id=?", (identifier,))
                    deletion_counts["a2a_usage_ledger"] = 0
                catch; end
                @info "Privacy deletion executed" identifier=identifier
            catch e
                @warn "Privacy deletion partial failure" exception=e
            end
        end

        # For access requests: return a summary of what's stored
        access_data = Dict{String,Any}()
        if req_type == "access"
            try
                for tbl in ("telemetry", "thoughts", "turn_snapshots", "a2a_usage_ledger")
                    count_col = tbl == "a2a_usage_ledger" ? "account_id" : "session_id"
                    r = try
                        SQLite.DBInterface.execute(db,
                            "SELECT COUNT(*) AS n FROM $tbl WHERE $count_col=?",
                            (identifier,)) |> DataFrame
                        nrow(r) > 0 ? Int(r[1,:n]) : 0
                    catch; 0 end
                    access_data[tbl] = r
                end
            catch e
                @warn "Privacy access query failed" exception=e
            end
        end

        response_body = Dict{String,Any}(
            "status"     => "received",
            "type"       => req_type,
            "identifier" => identifier,
            "message"    => req_type == "deletion" ?
                "Your deletion request has been logged and immediate purge of matching records has been attempted. Full processing within 7 business days. Contact jadenlindenbach@gmail.com with reference: $(identifier[1:min(8,end)])." :
                req_type == "access" ?
                "Your access request has been logged. You will receive a full data export within 30 calendar days at the contact you provide. Contact jadenlindenbach@gmail.com with subject: PIPA Access Request." :
                "Your correction request has been logged. We will review and respond within 30 calendar days.",
            "pipa_reference" => "PIPA (Alberta) SA 2003 c P-6.5, s. 25",
        )
        req_type == "access" && !isempty(access_data) && (response_body["record_counts"] = access_data)
        req_type == "deletion" && !isempty(deletion_counts) && (response_body["purged_tables"] = collect(keys(deletion_counts)))

        return HTTP.Response(200, [
            "Content-Type" => "application/json",
            "Access-Control-Allow-Origin" => "*",
        ], JSON.json(response_body))
    end

    # ── CORS preflight ───────────────────────
    if method == "OPTIONS"
        return HTTP.Response(204, [
            "Access-Control-Allow-Origin"=>"*",
            "Access-Control-Allow-Methods"=>"GET, POST, OPTIONS",
            "Access-Control-Allow-Headers"=>"Authorization, Content-Type",
        ])
    end

    return HTTP.Response(404, ["Content-Type"=>"application/json"],
        JSON.json(Dict("error"=>"Not found: $method $path")))
end

# ─────────────────────────────────────────────
#  Public API — called from App.jl
# ─────────────────────────────────────────────

"""
    handle_public_a2a_request(req, db; engine_ref=nothing)

Serve only the public A2A discovery/task routes when SparkByte's main HTTP server
falls through to the extra handler. Non-A2A paths return `nothing` so BYTE can
continue with its normal 404 handling.
"""
function handle_public_a2a_request(req::HTTP.Request, db::SQLite.DB; engine_ref=nothing)
    path = _canonical_a2a_path(req.target)
    method = string(req.method)

    path == "/favicon.ico" && return HTTP.Response(204)

    if path == "/health" ||
       path == "/.well-known/agent.json" ||
       path == "/.well-known/agent-card.json" ||
       path == "/extendedAgentCard" ||
       path == "/privacy" ||
       path == "/privacy/request" ||
       startswith(path, "/tasks/") ||
       (path == "/" && method == "POST") ||
       method == "OPTIONS"
        return _handle_request(req, db, engine_ref; public_url=_request_public_url(req))
    end

    return nothing
end

"""
    start_a2a_server(db; engine_ref=nothing)

Start the A2A HTTP server on A2A_PORT (default 8082) in a background task.
Pass engine_ref=Ref(engine) to enable chat-mode task routing.
"""
function start_a2a_server(db::SQLite.DB; engine_ref=nothing)
    _a2a_init_db!(db)

    @async begin
        try
            println("🤖 A2A SERVER  → http://$(A2A_HOST):$(A2A_PORT)")
            println("   Agent Card  → $(A2A_PUBLIC_URL)/.well-known/agent.json")
            println("   Tasks       → POST $(A2A_PUBLIC_URL)/")
            println("   Auth        → $(_a2a_auth_scheme())")
            println("   Privacy     → $(A2A_PUBLIC_URL)/privacy  (Alberta PIPA)")
            _billing_enforce_enabled() && println("   Billing     → enforced (set A2A_BILLING_PAYMENT_LINK_URL for checkout)")

            HTTP.serve(A2A_HOST, A2A_PORT) do req
                try
                    _handle_request(req, db, engine_ref; public_url=_request_public_url(req))
                catch e
                    HTTP.Response(500, ["Content-Type"=>"application/json"],
                        JSON.json(Dict("error"=>"Internal server error: $(string(e))")))
                end
            end
        catch e
            @warn "A2A server crashed" exception=(e, catch_backtrace())
        end
    end
end
