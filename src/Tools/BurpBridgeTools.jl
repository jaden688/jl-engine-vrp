# Burp Suite bridge tools — talk to the JL Engine Bridge extension running in Burp.
# The extension exposes a local REST API on 127.0.0.1:8888 (configurable via BURP_BRIDGE_PORT).
# These calls are loopback-only and intentionally bypass the Burp proxy.

function _burp_bridge_url(path::String; query::Dict=Dict{String,Any}())
    port = get(ENV, "BURP_BRIDGE_PORT", "8899")
    isempty(query) && return "http://127.0.0.1:$port$path"
    qs = join(["$(HTTP.escapeuri(string(k)))=$(HTTP.escapeuri(string(v)))" for (k,v) in query], "&")
    return "http://127.0.0.1:$port$path?$qs"
end

function _burp_bridge_get(path::String; query::Dict=Dict{String,Any}())
    url  = _burp_bridge_url(path; query)
    # NOTE: no proxy opts here — this is loopback to Burp's extension server
    resp = HTTP.get(url; status_exception=false, connect_timeout=2, readtimeout=10)
    return JSON.parse(String(resp.body))
end

# ── tool_burp_ping ─────────────────────────────────────────────────────────────

function tool_burp_ping(args)
    try
        result = _burp_bridge_get("/ping")
        return merge(result, Dict("tip" => "Extension is live. Call burp_history to pull captured traffic."))
    catch e
        return Dict(
            "status"  => "error",
            "error"   => "Bridge not reachable: $(e)",
            "fix"     => "Load jl-engine-bridge.jar in Burp: Extender → Extensions → Add → select the jar",
        )
    end
end

# ── tool_burp_history ──────────────────────────────────────────────────────────

function tool_burp_history(args)
    limit  = Int(get(args, "limit",  50))
    filter = string(get(args, "filter", ""))
    bodies = Bool(get(args, "bodies", false))

    query = Dict{String,Any}("limit" => limit)
    isempty(filter) || (query["filter"] = filter)
    bodies && (query["bodies"] = "1")

    try
        entries = _burp_bridge_get("/history"; query)
        return Dict(
            "status"  => "ok",
            "count"   => length(entries),
            "entries" => entries,
        )
    catch e
        return Dict("status" => "error", "error" => "Bridge error: $(e)")
    end
end

# ── Burp autoscore triage ─────────────────────────────────────────────────────

function _burp_triage_score(url::String, method::String, status::Int)
    score = 0
    reasons = String[]
    lurl = lowercase(url)
    lmethod = lowercase(method)

    if occursin("/api/organizations/", lurl)
        score += 6
        push!(reasons, "org_scoped_endpoint")
    end
    if occursin("/chat_conversations/", lurl) || occursin("/chat_conversations_v2", lurl)
        score += 5
        push!(reasons, "conversation_data_surface")
    end
    if occursin("/code/repos", lurl)
        score += 5
        push!(reasons, "repo_inventory_surface")
    end
    if occursin("/notification/preferences", lurl) || occursin("/sync/settings", lurl)
        score += 4
        push!(reasons, "account_settings_surface")
    end
    if lmethod == "get" && status == 200
        score += 2
        push!(reasons, "readable_success_response")
    end
    if occursin("/event_logging/", lurl)
        score -= 6
        push!(reasons, "telemetry_noise")
    end
    score = max(score, 0)
    return score, reasons
end

function _burp_path_without_query(url::String)
    q = findfirst(==('?'), url)
    q === nothing && return url
    return url[1:prevind(url, q)]
end

function _burp_extract_org_uuid(url::String)
    m = match(r"/api/organizations/([0-9a-fA-F\-]{36})", url)
    return m === nothing ? "" : String(m.captures[1])
end

function _burp_extract_conv_uuid(url::String)
    m = match(r"/chat_conversations/([0-9a-fA-F\-]{36})", url)
    return m === nothing ? "" : String(m.captures[1])
end

function _burp_preview(s::String, n::Int=240)
    x = replace(s, r"\s+" => " ")
    return first(x, min(n, lastindex(x)))
end

function tool_burp_triage_autoscore(args)
    limit   = clamp(Int(get(args, "limit", 250)), 1, 500)
    filter  = string(get(args, "filter", ""))
    top_n   = clamp(Int(get(args, "top_n", 20)), 1, 100)
    anthro_only = Bool(get(args, "anthropic_only", true))

    query = Dict{String,Any}("limit" => limit, "bodies" => "0")
    isempty(filter) || (query["filter"] = filter)

    try
        entries_any = _burp_bridge_get("/history"; query)
        entries = entries_any isa Vector ? entries_any : Any[]
        scored = Dict{String,Any}[]
        for e in entries
            e isa AbstractDict || continue
            url    = string(get(e, "url", ""))
            host   = lowercase(string(get(e, "host", "")))
            method = uppercase(string(get(e, "method", "")))
            status = Int(get(e, "status", 0))

            if anthro_only
                if !(occursin("claude.ai", host) || occursin("anthropic.com", host))
                    continue
                end
            end

            score, reasons = _burp_triage_score(url, method, status)
            score == 0 && continue
            push!(scored, Dict(
                "id" => get(e, "id", 0),
                "score" => score,
                "reasons" => reasons,
                "method" => method,
                "status" => status,
                "host" => get(e, "host", ""),
                "url" => url,
                "path" => _burp_path_without_query(url),
            ))
        end

        sort!(scored; by = x -> (-Int(get(x, "score", 0)), Int(get(x, "id", 0))))
        top = scored[1:min(top_n, length(scored))]
        return Dict(
            "status" => "ok",
            "analyzed" => length(entries),
            "candidate_count" => length(scored),
            "top" => top,
            "tip" => "Use burp_mutation_recipe on a top candidate URL to generate exact safe Repeater mutations."
        )
    catch e
        return Dict("status" => "error", "error" => "burp_triage_autoscore failed: $(e)")
    end
end

# ── Burp mutation recipe ──────────────────────────────────────────────────────

function tool_burp_mutation_recipe(args)
    url = string(get(args, "url", ""))
    replacement_org = string(get(args, "replacement_org", "11111111-1111-1111-1111-111111111111"))
    replacement_conv = string(get(args, "replacement_conversation", "22222222-2222-2222-2222-222222222222"))
    isempty(url) && return Dict("status" => "error", "error" => "url is required")

    org = _burp_extract_org_uuid(url)
    conv = _burp_extract_conv_uuid(url)

    steps = Dict{String,Any}[]
    if !isempty(org)
        push!(steps, Dict(
            "name" => "org_uuid_swap",
            "action" => "Replace org UUID in URL only; keep headers/cookies unchanged.",
            "mutated_url" => replace(url, org => replacement_org),
            "expected_secure" => "403/404/401",
            "finding_signal" => "200 with foreign org metadata/content"
        ))
    end
    if !isempty(conv)
        push!(steps, Dict(
            "name" => "conversation_uuid_swap",
            "action" => "Replace conversation UUID only; keep org UUID unchanged.",
            "mutated_url" => replace(url, conv => replacement_conv),
            "expected_secure" => "403/404/401",
            "finding_signal" => "200 with unrelated conversation metadata/messages"
        ))
    end
    push!(steps, Dict(
        "name" => "cookie_minimal_replay",
        "action" => "Replay with URL unchanged but remove lastActiveOrg and routingHint cookie values.",
        "mutated_url" => url,
        "expected_secure" => "same or stricter access control (never broader)",
        "finding_signal" => "broader access or data leakage after cookie reduction"
    ))

    return Dict(
        "status" => "ok",
        "url" => url,
        "detected_org_uuid" => org,
        "detected_conversation_uuid" => conv,
        "mutations" => steps
    )
end

# ── Burp evidence pack ────────────────────────────────────────────────────────

function _burp_headers_without_secrets(h::AbstractDict)
    out = Dict{String,Any}()
    for (k_any, v_any) in h
        k = string(k_any)
        lk = lowercase(k)
        if lk in ("cookie", "authorization", "proxy-authorization", "set-cookie", "x-api-key", "api-key")
            out[k] = "[REDACTED]"
        else
            out[k] = string(v_any)
        end
    end
    return out
end

function tool_burp_evidence_pack(args)
    ids_any = get(args, "ids", Any[])
    if !(ids_any isa AbstractVector) || isempty(ids_any)
        return Dict("status" => "error", "error" => "ids (array of history entry ids) is required")
    end
    ids = Set{Int}()
    for x in ids_any
        try
            push!(ids, Int(x))
        catch
        end
    end
    isempty(ids) && return Dict("status" => "error", "error" => "No valid ids were provided")

    limit = clamp(Int(get(args, "limit", 500)), 1, 500)
    filter = string(get(args, "filter", ""))
    query = Dict{String,Any}("limit" => limit, "bodies" => "1")
    isempty(filter) || (query["filter"] = filter)

    try
        entries_any = _burp_bridge_get("/history"; query)
        entries = entries_any isa Vector ? entries_any : Any[]
        picked = Dict{String,Any}[]
        for e in entries
            e isa AbstractDict || continue
            id = Int(get(e, "id", -1))
            id in ids || continue
            req_h = get(e, "request_headers", Dict{String,Any}())
            resp_h = get(e, "response_headers", Dict{String,Any}())
            url = string(get(e, "url", ""))
            method = string(get(e, "method", ""))
            status = Int(get(e, "status", 0))
            score, reasons = _burp_triage_score(url, method, status)
            push!(picked, Dict(
                "id" => id,
                "url" => url,
                "method" => method,
                "status" => status,
                "host" => string(get(e, "host", "")),
                "timestamp" => get(e, "timestamp", 0),
                "risk_score" => score,
                "risk_reasons" => reasons,
                "request_headers" => req_h isa AbstractDict ? _burp_headers_without_secrets(req_h) : Dict{String,Any}(),
                "response_headers" => resp_h isa AbstractDict ? _burp_headers_without_secrets(resp_h) : Dict{String,Any}(),
                "request_body_preview" => _burp_preview(string(get(e, "request_body", ""))),
                "response_body_preview" => _burp_preview(string(get(e, "response_body", ""))),
            ))
        end

        sort!(picked; by = x -> Int(get(x, "id", 0)))
        return Dict(
            "status" => "ok",
            "selected_count" => length(picked),
            "entries" => picked,
            "note" => "Sanitized evidence pack for reporting workflows."
        )
    catch e
        return Dict("status" => "error", "error" => "burp_evidence_pack failed: $(e)")
    end
end

# ── Burp submission draft (one-shot) ──────────────────────────────────────────

function tool_burp_submission_draft(args)
    limit = clamp(Int(get(args, "limit", 300)), 1, 500)
    top_n = clamp(Int(get(args, "top_n", 5)), 1, 20)
    filter = string(get(args, "filter", "/api/organizations/"))
    export_path = strip(string(get(args, "export_path", "")))

    triage = tool_burp_triage_autoscore(Dict(
        "limit" => limit,
        "top_n" => top_n,
        "filter" => filter,
        "anthropic_only" => true,
    ))
    get(triage, "status", "error") == "ok" || return triage
    top = get(triage, "top", Any[])
    isempty(top) && return Dict(
        "status" => "ok",
        "message" => "No high-signal candidates found with current filter.",
        "triage" => triage
    )

    ids = Int[]
    for c in top
        c isa AbstractDict || continue
        try
            push!(ids, Int(get(c, "id", 0)))
        catch
        end
    end
    ids = unique(filter(x -> x > 0, ids))
    isempty(ids) && return Dict("status" => "error", "error" => "Could not derive candidate ids from triage output")

    evidence = tool_burp_evidence_pack(Dict(
        "ids" => ids,
        "limit" => 500,
        "filter" => filter,
    ))
    get(evidence, "status", "error") == "ok" || return evidence
    entries = get(evidence, "entries", Any[])

    # Build concise issue hypotheses per entry
    hypotheses = Dict{String,Any}[]
    for e in entries
        e isa AbstractDict || continue
        url = string(get(e, "url", ""))
        status = Int(get(e, "status", 0))
        reasons_any = get(e, "risk_reasons", Any[])
        reasons = String[string(x) for x in reasons_any]
        suspected = String[]
        if "org_scoped_endpoint" in reasons
            push!(suspected, "Potential access-control/IDOR on org-scoped endpoint")
        end
        if "conversation_data_surface" in reasons
            push!(suspected, "Potential conversation metadata/content exposure")
        end
        if "repo_inventory_surface" in reasons
            push!(suspected, "Potential code/repo inventory leakage across org boundary")
        end
        if isempty(suspected)
            push!(suspected, "General authz boundary validation needed")
        end
        push!(hypotheses, Dict(
            "id" => get(e, "id", 0),
            "url" => url,
            "status_observed" => status,
            "suspected_issues" => suspected,
            "next_test" => "Swap org UUID only; expect 403/404. 200 with foreign data is strong finding signal."
        ))
    end

    title = string(get(args, "title", "Potential org-scoped access control weakness on claude.ai API endpoints"))
    report_template = Dict(
        "title" => title,
        "asset_hint" => "claude.ai",
        "summary" => "Multiple org-scoped endpoints returned sensitive account/org data in authenticated context. Requires boundary validation via UUID mutation to confirm/deny IDOR.",
        "repro_plan" => [
            "Replay captured GET request in Repeater.",
            "Mutate only org UUID in path to random UUID.",
            "Keep headers/cookies otherwise unchanged.",
            "Compare status/body for unauthorized data exposure.",
        ],
        "impact_if_confirmed" => "Unauthorized cross-org access to organization metadata, repo inventory, conversation metadata, or notification/usage details.",
        "candidate_count" => length(hypotheses),
        "candidate_ids" => ids,
    )

    out = Dict(
        "status" => "ok",
        "triage" => triage,
        "evidence" => evidence,
        "hypotheses" => hypotheses,
        "submission_draft" => report_template,
        "note" => "Draft is intentionally conservative until a cross-org UUID mutation proves unauthorized access."
    )

    if !isempty(export_path)
        try
            abspath_out = abspath(export_path)
            mkpath(dirname(abspath_out))
            open(abspath_out, "w") do io
                JSON.print(io, out, 2)
            end
            out["exported"] = true
            out["export_path"] = abspath_out
        catch e
            out["exported"] = false
            out["export_error"] = "Failed to write export_path: $(e)"
        end
    end

    return out
end
