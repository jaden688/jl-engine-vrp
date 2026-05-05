"""
    Telemetry.jl — Full event logging for SparkByte.

Writes newline-delimited JSON (JSONL) to full_telemetry.jsonl in the runtime state directory.
Every event is a self-contained JSON object with at minimum:
  - timestamp   (ISO8601)
  - event       (string category)
  - session_id  (shared across the process lifetime)

Append-only. Never truncates. Safe for concurrent WS connections (file-level lock via ReentrantLock).
"""

using JSON, Dates, SHA

# ── State ───────────────────────────────────────────────────────────────────
const _telem_lock    = ReentrantLock()
const _telem_path    = Ref{String}("")
const _telem_db      = Ref{Any}(nothing)   # SQLite.DB handle — set by init_telemetry
const _session_id    = string(round(Int, datetime2unix(now()))) # epoch seconds as session id
const _turn_counter  = Ref{Int}(0)

# ── Audit log (operator-only, full fidelity, human-readable) ─────────────────
const _audit_lock    = ReentrantLock()
const _audit_path    = Ref{String}("")
const _audit_turn    = Ref{Int}(0)
const _audit_loop    = Ref{Int}(0)

function _telemetry_root(project_root::String)
    configured = strip(get(ENV, "SPARKBYTE_STATE_DIR", ""))
    if !isempty(configured) && Sys.islinux() && occursin(r"^[A-Za-z]:[\\/]"i, configured)
        configured = isdir("/app") ? "/app/runtime" : ""
    end
    root = isempty(configured) ? project_root : abspath(configured)
    mkpath(root)
    return root
end

function _redact_sensitive_text(value)
    text = string(value)
    isempty(text) && return text

    # ── API keys & tokens (existing) ─────────────────────────────────────────
    text = replace(text, r"(?i)([?&](?:key|api[_-]?key|x-goog-api-key)=)([^&\s\"']+)" => s"\1[REDACTED]")
    text = replace(text, r"(?i)(Authorization:\s*Bearer\s+)([A-Za-z0-9._-]+)" => s"\1[REDACTED]")
    text = replace(text, r"(?i)(Bearer\s+)([A-Za-z0-9._-]+)" => s"\1[REDACTED]")
    text = replace(text, r"\b(csk|sk|xai)-[A-Za-z0-9_-]+\b" => s"\1-[REDACTED]")
    text = replace(text, r"\bAIza[0-9A-Za-z\-_]{20,}\b" => "[REDACTED]")

    # ── PII — Alberta PIPA compliance ─────────────────────────────────────────
    # Email addresses
    text = replace(text, r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b" => "[EMAIL]")
    # Canadian/US phone numbers
    text = replace(text, r"(\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b" => "[PHONE]")
    # IPv4 addresses (hashed context — raw IPs never stored)
    text = replace(text, r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b" => "[IP]")
    # Canadian SIN (Social Insurance Number)
    text = replace(text, r"\b\d{3}[-\s]\d{3}[-\s]\d{3}\b" => "[SIN]")
    # Credit/debit card numbers (16-digit, various separators)
    text = replace(text, r"\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}\b" => "[CARD]")
    # Postal codes (Canadian format)
    text = replace(text, r"\b[A-Za-z]\d[A-Za-z][\s]?\d[A-Za-z]\d\b" => "[POSTAL]")

    return text
end

"""
    _pii_scrub(value) -> String

Alias for _redact_sensitive_text. Use this explicitly when writing
user-sourced content to any persistent store (DB, log files, etc.)
"""
_pii_scrub(value) = _redact_sensitive_text(value)

function _thinking_config_snapshot(gen_config)
    thinking_cfg = get(gen_config, "thinking_config", Dict{String,Any}())
    level = get(thinking_cfg, "thinkingLevel", get(thinking_cfg, "thinking_level", nothing))
    budget = get(thinking_cfg, "thinkingBudget", get(thinking_cfg, "thinking_budget", nothing))
    return level, budget
end

function init_telemetry(project_root::String; db=nothing)
    telem_root = _telemetry_root(project_root)
    _telem_path[] = joinpath(telem_root, "full_telemetry.jsonl")
    _telem_db[]   = db
    init_audit_log(project_root)   # start operator audit log alongside telemetry
    log_event("session_start", Dict{String,Any}(
        "session_id" => _session_id,
        "project_root" => project_root,
        "state_root" => telem_root,
        "julia_version" => string(VERSION),
        "os" => string(Sys.KERNEL),
        "arch" => string(Sys.ARCH),
    ))
end

# ── Core writer ─────────────────────────────────────────────────────────────
function log_event(event::String, data::Dict{String,Any} = Dict{String,Any}())
    _telem_path[] == "" && return  # not yet initialized
    ts = string(now())
    entry = merge(Dict{String,Any}(
        "timestamp"  => ts,
        "session_id" => _session_id,
        "event"      => event,
    ), data)
    line = JSON.json(entry)

    # ① Always write to JSONL (raw debug log)
    lock(_telem_lock) do
        open(_telem_path[], "a") do f
            println(f, line)
        end
    end

    # ② Dual-write to SQLite telemetry table so SparkByte can query her own history
    if _telem_db[] !== nothing
        try
            model   = string(get(data, "model", ""))
            agent = string(get(data, "agent", ""))
            lock(_DB_WRITE_LOCK) do
                SQLite.execute(_telem_db[],
                    "INSERT INTO telemetry (timestamp, session_id, event, turn_number, model, jl_agent, data_json) VALUES (?,?,?,?,?,?,?)",
                    (ts, _session_id, event, Int(_turn_counter[]), model, agent, line))
            end
        catch e
            @warn "Telemetry SQLite write failed" event=event exception=(e, catch_backtrace())
        end
    end
end

# ── Convenience wrappers ─────────────────────────────────────────────────────

function log_ws_message_in(raw::String)
    try
        p = JSON.parse(raw)
        t = get(p, "type", "unknown")
        d = Dict{String,Any}("msg_type" => t)
        if t == "user_msg"
            raw_text = get(p, "text", "")
            scrubbed  = _pii_scrub(raw_text)   # PII never hits the DB
            d["text_len"]    = length(raw_text)
            d["text_preview"] = first(scrubbed, 200)
            d["has_image"]   = get(p, "image", nothing) !== nothing
            d["pii_scrubbed"] = scrubbed != raw_text   # flag if anything was redacted
        elseif t == "builder_cmd"
            d["cmd"] = get(p, "cmd", "")
        elseif t == "model_change"
            d["model"] = get(p, "model", "")
        elseif t == "operator_change" || t == "agent_change"
            d["operator"] = get(p, "operator", get(p, "agent", ""))
        end
        log_event("ws_in", d)
    catch
        log_event("ws_in", Dict{String,Any}("raw_preview" => first(raw, 200), "parse_error" => true))
    end
end

function log_ws_message_out(obj::Dict)
    t = get(obj, "type", "unknown")
    d = Dict{String,Any}("msg_type" => t)
    if t == "spark"
        spark_text = _redact_sensitive_text(get(obj, "text", ""))
        d["text_len"]     = length(spark_text)
        d["text_preview"] = first(spark_text, 200)
    elseif t == "tool"
        d["text"] = get(obj, "text", "")
    elseif t == "ui_update"
        d["gear"]  = get(obj, "gear", "")
        d["modes"] = get(obj, "modes", [])
    elseif t == "builder_tree"
        d["file_count"] = length(get(obj, "files", []))
    end
    log_event("ws_out", d)
end

function log_engine_snapshot(snapshot::Dict)
    log_event("engine_snapshot", Dict{String,Any}(
        "gait"            => get(snapshot, "gait", ""),
        "rhythm_mode"     => get(get(snapshot, "rhythm", Dict()), "mode", ""),
        "aperture_mode"   => get(get(snapshot, "aperture_state", Dict()), "mode", ""),
        "aperture_temp"   => get(get(snapshot, "aperture_state", Dict()), "temp", 0.0),
        "aperture_top_p"  => get(get(snapshot, "aperture_state", Dict()), "top_p", 0.0),
        "behavior_state"  => get(get(snapshot, "behavior_state", Dict()), "name", ""),
        "behavior_expr"   => get(get(snapshot, "behavior_state", Dict()), "expressiveness", 0.0),
        "drift_pressure"  => get(get(snapshot, "drift", Dict()), "pressure", 0.0),
        "drift_temp_delta"=> get(get(snapshot, "drift", Dict()), "temperature_delta", 0.0),
        "advisory_msg"    => get(get(snapshot, "advisory", Dict()), "msg", ""),
        "operator"        => get(snapshot, "operator", get(snapshot, "agent", "")),
        "trigger"         => get(snapshot, "trigger", ""),
    ))
end

function log_api_request(model, gen_config, history_len, loop_iter)
    thinking_level, thinking_budget = _thinking_config_snapshot(gen_config)
    log_event("api_request", Dict{String,Any}(
        "model"        => string(model),
        "loop_iter"    => Int(loop_iter),
        "history_len"  => Int(history_len),
        "temperature"  => get(gen_config, "temperature", nothing),
        "top_p"        => get(gen_config, "topP", nothing),
        "thinking"     => thinking_level === nothing ? string(thinking_budget === nothing ? "none" : "budget") : string("level"),
        "thinking_level" => thinking_level === nothing ? "none" : string(thinking_level),
        "thinking_budget" => thinking_budget === nothing ? "none" : thinking_budget,
    ))
end

function log_api_response(model, status, body_len, loop_iter;
                          has_text=false, has_tool=false,
                          text_preview="", tool_name="",
                          finish_reason="", error="")
    log_event("api_response", Dict{String,Any}(
        "model"        => string(model),
        "loop_iter"    => Int(loop_iter),
        "status"       => Int(status),
        "body_len"     => Int(body_len),
        "has_text"     => has_text,
        "has_tool"     => has_tool,
        "text_preview" => first(_redact_sensitive_text(text_preview), 300),
        "tool_name"    => string(tool_name),
        "finish_reason"=> string(finish_reason),
        "error"        => _redact_sensitive_text(error),
    ))
end

function log_tool_call(name, args, loop_iter; receipt=nothing)
    safe_args = try JSON.parse(JSON.json(args)) catch; Dict("_raw" => string(args)) end
    # Scrub PII from any string values in args before writing to DB
    for (k, v) in safe_args
        if v isa String
            safe_args[k] = _pii_scrub(v)
        end
    end
    log_event("tool_call", Dict{String,Any}(
        "tool_name" => name,
        "loop_iter" => loop_iter,
        "args"      => safe_args,
        "receipt"   => receipt === nothing ? Dict{String,Any}() : receipt,
    ))
end

function log_tool_result(name, result, loop_iter; elapsed_ms=0, receipt=nothing)
    safe_result = try JSON.parse(JSON.json(result)) catch; Dict("_raw" => string(result)) end
    # Scrub PII from result text before DB write
    for (k, v) in safe_result
        if v isa String
            safe_result[k] = _pii_scrub(v)
        end
    end
    result_str = JSON.json(safe_result)
    # Cap at 2000 chars in DB (full version goes to audit log)
    if length(result_str) > 2000
        safe_result = Dict("_preview" => first(result_str, 2000) * "...[see audit log for full output]")
    end
    log_event("tool_result", Dict{String,Any}(
        "tool_name"  => string(name),
        "loop_iter"  => Int(loop_iter),
        "elapsed_ms" => Int(elapsed_ms),
        "result"     => safe_result,
        "is_error"   => haskey(safe_result, "error"),
        "receipt"    => receipt === nothing ? Dict{String,Any}() : receipt,
    ))
end

function log_turn_complete(user_text, reply_len, loop_iters, elapsed_ms)
    _turn_counter[] += 1
    log_event("turn_complete", Dict{String,Any}(
        "turn_number"   => _turn_counter[],
        "user_preview"  => first(string(user_text), 200),
        "reply_len"     => Int(reply_len),
        "tool_loops"    => Int(loop_iters),
        "elapsed_ms"    => Int(elapsed_ms),
    ))
end

function log_error(event_context, err; stacktrace_str="")
    log_event("error", Dict{String,Any}(
        "context"    => string(event_context),
        "error_type" => string(typeof(err)),
        "error_msg"  => first(_redact_sensitive_text(err), 500),
        "stacktrace" => first(_redact_sensitive_text(stacktrace_str), 1000),
    ))
end

function log_builder_cmd(cmd, path="", extra=Dict{String,Any}())
    d = merge(Dict{String,Any}("cmd" => string(cmd), "path" => string(path)), extra)
    log_event("builder_cmd", d)
end

function log_operator_change(from, to, success)
    log_event("operator_change", Dict{String,Any}("from"=>string(from), "to"=>string(to), "success"=>success==true))
end

function log_model_change(from, to)
    log_event("model_change", Dict{String,Any}("from"=>string(from), "to"=>string(to)))
end

function log_settings_change(key_set, field)
    log_event("settings_change", Dict{String,Any}("field"=>string(field), "key_set"=>key_set==true))
end

# ── Deep "why" telemetry ─────────────────────────────────────────────────────

"""Log the full system prompt + the engine state that produced it."""
function log_system_prompt(prompt, snapshot)
    aperture   = get(snapshot, "aperture_state", Dict())
    drift      = get(snapshot, "drift",          Dict())
    behavior   = get(snapshot, "behavior_state", Dict())
    rhythm     = get(snapshot, "rhythm",         Dict())
    advisory   = get(snapshot, "advisory",       Dict())
    log_event("system_prompt", Dict{String,Any}(
        "prompt_len"        => length(prompt),
        "prompt_hash"       => string(hash(prompt)),
        "prompt_head"       => first(prompt, 600),
        # WHY these params were set
        "engine_gait"       => string(get(snapshot, "gait", "")),
        "engine_operator"   => string(get(snapshot, "operator", get(snapshot, "agent", ""))),
        "engine_trigger"    => string(get(snapshot, "trigger", "")),
        "behavior_name"     => string(get(behavior, "name", "")),
        "behavior_expr"     => get(behavior, "expressiveness", 0.0),
        "behavior_pacing"   => string(get(behavior, "pacing", "")),
        "behavior_tone"     => string(get(behavior, "tone", "")),
        "rhythm_mode"       => string(get(rhythm,   "mode", "")),
        "rhythm_momentum"   => get(rhythm,   "momentum",    0.0),
        "aperture_mode"     => string(get(aperture, "mode", "")),
        "aperture_temp"     => get(aperture, "temp",    0.0),
        "aperture_top_p"    => get(aperture, "top_p",   0.0),
        "drift_pressure"    => get(drift, "pressure",         0.0),
        "drift_temp_delta"  => get(drift, "temperature_delta",0.0),
        "drift_action"      => string(get(drift, "action_level", "")),
        "advisory_msg"      => string(get(advisory, "msg", "")),
        "advisory_gating"   => string(get(advisory, "gating_bias", "")),
        "advisory_emotion"  => string(get(advisory, "emotional_drift", "")),
    ))
end

"""Log the causal chain: engine snapshot → temperature/topP decision."""
function log_param_decision(gen_config, snapshot)
    thinking_level, thinking_budget = _thinking_config_snapshot(gen_config)
    aperture = get(snapshot, "aperture_state", Dict())
    drift    = get(snapshot, "drift",          Dict())
    base_temp  = get(aperture, "temp",              0.45)
    delta_temp = get(drift,    "temperature_delta", 0.0)
    final_temp = get(gen_config, "temperature",     0.0)
    log_event("param_decision", Dict{String,Any}(
        "base_temp"       => base_temp,
        "drift_delta"     => delta_temp,
        "final_temp"      => final_temp,
        "final_top_p"     => get(gen_config, "topP", 0.0),
        "thinking"        => thinking_level === nothing ? string(thinking_budget === nothing ? "none" : "budget") : string("level"),
        "thinking_level"  => thinking_level === nothing ? "none" : string(thinking_level),
        "thinking_budget" => thinking_budget === nothing ? "none" : thinking_budget,
        "aperture_mode"   => string(get(aperture, "mode", "")),
        "drift_pressure"  => get(drift, "pressure", 0.0),
        "why_temp"        => "aperture_base=$(round(base_temp,digits=3)) + drift_delta=$(round(delta_temp,digits=3)) = $(round(final_temp,digits=3))",
        "why_top_p"       => "clamped aperture top_p = $(get(aperture,"top_p",0.7)) → $(get(gen_config,"topP",0.0))",
    ))
end

"""Log Gemini token usage from usageMetadata."""
function log_token_usage(usage_meta, loop_iter)
    isnothing(usage_meta) && return
    log_event("token_usage", Dict{String,Any}(
        "loop_iter"          => Int(loop_iter),
        "prompt_tokens"      => get(usage_meta, "promptTokenCount",     0),
        "candidate_tokens"   => get(usage_meta, "candidatesTokenCount", 0),
        "total_tokens"       => get(usage_meta, "totalTokenCount",       0),
        "thinking_tokens"    => get(usage_meta, "thoughtsTokenCount",   0),
    ))
end

"""Log safety ratings from a Gemini candidate."""
function log_safety_ratings(ratings, loop_iter)
    isempty(ratings) && return
    safe_list = [Dict{String,Any}(
        "category"    => string(get(r, "category",    "")),
        "probability" => string(get(r, "probability", "")),
        "blocked"     => get(r, "blocked", false) == true,
    ) for r in ratings]
    blocked_any = any(get(r, "blocked", false) == true for r in ratings)
    log_event("safety_ratings", Dict{String,Any}(
        "loop_iter"   => Int(loop_iter),
        "ratings"     => safe_list,
        "blocked_any" => blocked_any,
    ))
end

"""Log reasoning/thinking text from thinking models."""
function log_thinking(thought_text, loop_iter)
    isempty(thought_text) && return
    log_event("model_thinking", Dict{String,Any}(
        "loop_iter"    => Int(loop_iter),
        "thought_len"  => length(thought_text),
        "thought_head" => first(thought_text, 800),
    ))
end

# ── Audit Log — operator-only, full fidelity, no truncation ─────────────────
# Written to logs/audit_<session_id>.log
# Contains: full user message, engine state, LLM reasoning between tool calls,
# full tool args, full tool output, final reply — everything needed for audit.
# PII is scrubbed before writing (same redaction as DB).
# This file is for the operator (Jaden) only — never exposed to end users.

function _audit_write(text::String)
    _audit_path[] == "" && return
    lock(_audit_lock) do
        open(_audit_path[], "a") do f
            print(f, text)
        end
    end
end

function init_audit_log(project_root::String)
    logs_dir = joinpath(project_root, "logs")
    mkpath(logs_dir)
    _audit_path[] = joinpath(logs_dir, "audit_$(_session_id).log")
    _audit_write("""
╔══════════════════════════════════════════════════════════════════╗
║  JL ENGINE OPERATOR AUDIT LOG                                    ║
║  Session: $(_session_id)                                         ║
║  Started: $(now())                                               ║
║  CONFIDENTIAL — operator use only                                ║
║  Alberta PIPA compliant — PII scrubbed before storage            ║
╚══════════════════════════════════════════════════════════════════╝

""")
end

function audit_turn_start(user_text::String, model::String, snapshot::Dict)
    _audit_path[] == "" && return
    _audit_turn[] += 1
    _audit_loop[]  = 0
    turn = _audit_turn[]
    ts   = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

    aperture = get(snapshot, "aperture_state", Dict())
    drift    = get(snapshot, "drift", Dict())
    behavior = get(snapshot, "behavior_state", Dict())

    _audit_write("""
═══════════════════════════════════════════════════════════════════
TURN $turn  [$ts]  session=$(_session_id)
───────────────────────────────────────────────────────────────────
USER:
  $(_pii_scrub(user_text))

ENGINE STATE:
  gait=$(get(snapshot,"gait","?"))  aperture=$(get(aperture,"mode","?"))  temp=$(round(get(aperture,"temp",0.0),digits=3))
  drift=$(round(get(drift,"pressure",0.0),digits=3))  behavior=$(get(behavior,"name","?"))
  model=$model

""")
end

function audit_reasoning(text::String, loop_iter::Int)
    _audit_path[] == "" && return
    isempty(strip(text)) && return
    _audit_write("""  [LOOP $loop_iter] REASONING:
$(join("    " .* split(_pii_scrub(text), "\n"), "\n"))

""")
end

function audit_tool_call(name::String, args, loop_iter::Int; receipt=nothing)
    _audit_path[] == "" && return
    _audit_loop[] = loop_iter
    args_json = try
        JSON.json(args, 2)   # pretty-printed, full, no truncation
    catch
        string(args)
    end
    _audit_write("""  [LOOP $loop_iter] TOOL CALL: $name
$(join("    " .* split(_pii_scrub(args_json), "\n"), "\n"))
  RECEIPT:
$(join("    " .* split(_pii_scrub(receipt === nothing ? "{}" : JSON.json(receipt, 2)), "\n"), "\n"))

""")
end

function audit_tool_result(name::String, result, elapsed_ms::Int, loop_iter::Int; receipt=nothing)
    _audit_path[] == "" && return
    result_str = try
        JSON.json(result, 2)   # full output, no truncation
    catch
        string(result)
    end
    is_err = result isa Dict && haskey(result, "error")
    status = is_err ? "✗ ERROR" : "✓ OK"
    _audit_write("""  [LOOP $loop_iter] TOOL RESULT: $name  $status  ($(elapsed_ms)ms)
$(join("    " .* split(_pii_scrub(result_str), "\n"), "\n"))
  RECEIPT:
$(join("    " .* split(_pii_scrub(receipt === nothing ? "{}" : JSON.json(receipt, 2)), "\n"), "\n"))

""")
end

function audit_turn_reply(reply::String)
    _audit_path[] == "" && return
    _audit_write("""  FINAL REPLY:
$(join("    " .* split(_pii_scrub(reply), "\n"), "\n"))
───────────────────────────────────────────────────────────────────

""")
end

function audit_thinking(thought::String, loop_iter::Int)
    _audit_path[] == "" && return
    isempty(strip(thought)) && return
    _audit_write("""  [LOOP $loop_iter] THINKING (chain of thought):
$(join("    " .* split(first(thought, 4000), "\n"), "\n"))
    [...$(length(thought)) chars total]

""")
end

# ── Data Retention — Alberta PIPA compliance ────────────────────────────────

"""
    run_retention_sweep!(db)

Purges records older than SPARKBYTE_DATA_RETENTION_DAYS (default 90) from:
  - telemetry, thoughts, turn_snapshots, web_cache

Does NOT touch: memory, knowledge, intentions, agents (user's own data).
Safe to call on boot and daily. Logs how many rows were deleted.
"""
function run_retention_sweep!(db)
    db === nothing && return
    retention_days = try
        parse(Int, strip(get(ENV, "SPARKBYTE_DATA_RETENTION_DAYS", "90")))
    catch; 90 end

    cutoff = Dates.format(now() - Day(retention_days), "yyyy-mm-dd")
    total_deleted = 0

    tables_with_ts = [
        ("telemetry",      "timestamp"),
        ("thoughts",       "timestamp"),
        ("turn_snapshots", "timestamp"),   # turn_snapshots schema uses `timestamp`, not `created_at`
        ("web_cache",      "fetched_at"),
    ]

    for (tbl, ts_col) in tables_with_ts
        try
            # Count first — SQLite.jl has no changes() function
            count_rows = try
                df = SQLite.DBInterface.execute(db,
                    "SELECT COUNT(*) AS n FROM $tbl WHERE $ts_col < ?", [cutoff]) |> DataFrames.DataFrame
                nrow(df) > 0 ? Int(df[1, :n]) : 0
            catch; 0 end
            if count_rows > 0
                SQLite.DBInterface.execute(db,
                    "DELETE FROM $tbl WHERE $ts_col < ?", [cutoff])
                total_deleted += count_rows
                @info "[retention] purged $count_rows rows from $tbl (older than $retention_days days)"
            end
        catch e
            @warn "[retention] failed on $tbl" exception=e
        end
    end

    total_deleted > 0 &&
        @info "[retention] sweep complete — $total_deleted rows purged (cutoff=$cutoff)"
    log_event("retention_sweep", Dict{String,Any}(
        "cutoff"         => cutoff,
        "retention_days" => retention_days,
        "rows_deleted"   => total_deleted,
    ))
end
