# CascadeTools.jl — Cascade Swarm Runner + Distributed Target Sweeper
# For authorized testing, CTF competitions, bug bounty, and security research only.
#
# agent_id: vuln_discovery_cascade | archetype: relentless-verifier
#
# Phase engine: indexing → hypothesis_generation → validation_cycle → escalation
# HackerOne escalation failsafe:
#   Only escalates when evidence_demand AND validation_strictness BOTH exceed 0.85.
#   Reads: ENV["HACKERONE_API_TOKEN"] and ENV["HACKERONE_USERNAME"]
#
# JL Engine wiring:
#   BehaviorStateMachine after_states → phase → gait mapping
#   RhythmEngine gait: walk/trot/sprint/idle per phase
#   EmotionalAperture: FOCUSED/OPEN/TIGHT per phase
#   DriftPressureSystem: per-swarm pressure scalar
#   HybridMemorySystem: breadcrumbs via _db_write_thought + _pentest_remember
#   A2A: swarm state persisted in SQLite a2a_tasks table when available

using HTTP, Dates, JSON, UUIDs, Base64

# ── Cascade Constants ─────────────────────────────────────────────────────────

const CASCADE_VERSION = "1.0.0"

# BehaviorStateMachine after_states (from vuln_discovery_cascade schema)
const CASCADE_AFTER_STATES = [
    "active_discovery",
    "validating_finding",
    "evidence_locked",
    "escalating_to_hackerone",
    "backtracking_failed_reproduction",
    "collision_resolving",
]

# Phase → RhythmEngine gait
const CASCADE_PHASE_GAIT = Dict(
    "indexing"              => "walk",
    "hypothesis_generation" => "trot",
    "validation_cycle"      => "sprint",
    "escalation"            => "sprint",
    "backtrack"             => "idle",
    "collision_resolve"     => "trot",
    "complete"              => "walk",
)

# Phase → EmotionalAperture mode
const CASCADE_PHASE_APERTURE = Dict(
    "indexing"              => "FOCUSED",
    "hypothesis_generation" => "OPEN",
    "validation_cycle"      => "TIGHT",
    "escalation"            => "TIGHT",
    "backtrack"             => "FOCUSED",
    "collision_resolve"     => "FOCUSED",
    "complete"              => "FOCUSED",
)

# HackerOne escalation gate thresholds
const CASCADE_HN_EVIDENCE_THRESHOLD    = 0.85
const CASCADE_HN_VALIDATION_THRESHOLD  = 0.85

# ── Global Swarm Registry ─────────────────────────────────────────────────────

const _CASCADE_SWARMS = Dict{String, Dict{String,Any}}()
const _CASCADE_LOCK   = ReentrantLock()

# ── Engine Hooks ──────────────────────────────────────────────────────────────

function _cascade_broadcast(event::String, data::Dict)
    try
        _broadcast(merge(data, Dict("event"=>event, "source"=>"cascade",
                                    "ts"=>string(now()))))
    catch e
        @warn "Cascade broadcast failed" event=event exception=(e, catch_backtrace())
    end
end

function _cascade_remember(swarm_id::String, phase::String, finding::String, severity::String)
    _pentest_remember("cascade:$swarm_id:$phase",
        "[$severity] $finding", "cascade,swarm,pentest")
end

function _cascade_diary(swarm_id::String, phase::String, msg::String;
                        mood::String="focused", gait::String="trot")
    op = _active_operator()
    _db_write_thought("cascade:$swarm_id", "[$phase] $msg", mood,
        get(CASCADE_PHASE_GAIT, phase, gait), op; type="reasoning")
end

function _cascade_advisory(evidence_demand::Float64, validation_strictness::Float64)
    can_escalate = evidence_demand  > CASCADE_HN_EVIDENCE_THRESHOLD &&
                   validation_strictness > CASCADE_HN_VALIDATION_THRESHOLD
    Dict(
        "action_level"          => can_escalate ? "ESCALATE" : "HOLD",
        "gating_bias"           => can_escalate ? 0.9 : 0.3,
        "emotional_drift"       => validation_strictness > 0.7 ? "focused" : "uncertain",
        "can_escalate"          => can_escalate,
        "evidence_demand"       => round(evidence_demand; digits=3),
        "validation_strictness" => round(validation_strictness; digits=3),
        "hn_evidence_threshold" => CASCADE_HN_EVIDENCE_THRESHOLD,
        "hn_validation_threshold" => CASCADE_HN_VALIDATION_THRESHOLD,
    )
end

# ── Swarm Lifecycle ───────────────────────────────────────────────────────────

function _new_swarm(target::String, scope::String, operator::String)
    id = string(UUIDs.uuid4())[1:8]
    lock(_CASCADE_LOCK) do
        _CASCADE_SWARMS[id] = Dict{String,Any}(
            "swarm_id"              => id,
            "target"               => target,
            "scope"                => scope,
            "operator"             => operator,
            "phase"                => "indexing",
            "after_state"          => "active_discovery",
            "agents"               => Dict{String,Any}(),
            "findings"             => Any[],
            "evidence_demand"      => 0.0,
            "validation_strictness"=> 0.0,
            "drift_pressure"       => 0.0,
            "started_at"           => string(now()),
            "status"               => "running",
            "hn_report_id"         => nothing,
        )
    end
    return id
end

function _get_swarm(swarm_id::String)
    lock(_CASCADE_LOCK) do
        copy(get(_CASCADE_SWARMS, swarm_id, Dict{String,Any}()))
    end
end

function _update_swarm!(swarm_id::String; kwargs...)
    lock(_CASCADE_LOCK) do
        s = get(_CASCADE_SWARMS, swarm_id, nothing)
        s === nothing && return
        for (k, v) in kwargs
            s[string(k)] = v
        end
    end
end

function _push_finding!(swarm_id::String, finding::Dict)
    lock(_CASCADE_LOCK) do
        s = get(_CASCADE_SWARMS, swarm_id, nothing)
        s === nothing && return
        push!(s["findings"], finding)
        confirmed = filter(f -> get(f,"confirmed",false), s["findings"])
        s["evidence_demand"] = min(1.0, length(confirmed) * 0.25)
    end
end

# ── HackerOne Scope Cache ─────────────────────────────────────────────────────
# Cached per session so we don't hammer the API on every spawn call

const _HN_SCOPE_CACHE = Dict{String, Dict{String,Any}}()  # program_handle → scope data
const _HN_SCOPE_LOCK  = ReentrantLock()

# ── HackerOne API ─────────────────────────────────────────────────────────────

function _hn_auth_header()
    token    = strip(get(ENV, "HACKERONE_API_TOKEN", ""))
    username = strip(get(ENV, "HACKERONE_USERNAME", ""))
    isempty(token) && return nothing
    isempty(username) && return nothing
    creds = base64encode("$username:$token")
    "Basic $creds"
end

function _hn_submit_report(target::String, findings::Vector, swarm_id::String)
    auth = _hn_auth_header()
    auth === nothing && return Dict(
        "error" => "HackerOne auth not configured. Set HACKERONE_API_TOKEN and HACKERONE_USERNAME env vars.",
        "submitted" => false,
    )

    # Build vulnerability summary from confirmed findings
    vuln_types = unique(map(f -> string(get(f, "type", get(f, "vuln_type", "unknown"))), findings))
    severity   = length(findings) >= 3 ? "high" : length(findings) == 2 ? "medium" : "low"

    title = "[$severity] $(join(vuln_types[1:min(end,3)], " + ")) on $target [JL-VRP Cascade/$swarm_id]"

    body_lines = ["## Cascade Swarm Report", "",
                  "**Target:** $target",
                  "**Swarm ID:** $swarm_id",
                  "**Engine:** JL Engine VRP / Cascade Runner v$CASCADE_VERSION",
                  "**Confirmed Findings:** $(length(findings))",
                  ""]

    for (i, f) in enumerate(findings)
        push!(body_lines, "### Finding $i — $(get(f,"type",get(f,"vuln_type","?")))")
        push!(body_lines, "- **Status:** $(get(f,"confirmed",false) ? "Confirmed" : "Potential")")
        push!(body_lines, "- **Score:** $(get(f,"validation_score","-"))")
        for ev in get(f, "evidence", String[])
            push!(body_lines, "- **Evidence:** $ev")
        end
        push!(body_lines, "")
    end

    push!(body_lines, "---")
    push!(body_lines, "*Submitted automatically by JL Engine VRP Cascade runner. For authorized bug bounty use only.*")

    report_body = join(body_lines, "\n")

    payload = JSON.json(Dict(
        "data" => Dict(
            "type"       => "report",
            "attributes" => Dict(
                "title"            => title,
                "vulnerability_information" => report_body,
                "severity_rating"  => severity,
                "impact"           => "Identified via automated Cascade validation pipeline.",
            )
        )
    ))

    try
        resp = HTTP.post(
            "https://api.hackerone.com/v1/hackers/reports",
            ["Authorization" => auth,
             "Content-Type"  => "application/json",
             "Accept"        => "application/json",
             "X-Source"      => "JL-Engine-VRP"],
            Vector{UInt8}(codeunits(payload));
            status_exception=false,
            connect_timeout=10, readtimeout=15,
        )

        resp_body = String(resp.body)
        parsed    = try JSON.parse(resp_body) catch; Dict{String,Any}() end

        if resp.status in (200, 201)
            report_id = string(get(get(parsed, "data", Dict()), "id", ""))
            return Dict("submitted"=>true, "report_id"=>report_id,
                        "status"=>resp.status, "title"=>title)
        else
            return Dict("submitted"=>false, "status"=>resp.status,
                        "error"=>resp_body, "title"=>title)
        end
    catch e
        return Dict("submitted"=>false, "error"=>string(e))
    end
end

# ── HackerOne Program & Scope Fetchers ───────────────────────────────────────

function _hn_get(path::String)
    auth = _hn_auth_header()
    auth === nothing && return nothing, "HackerOne auth not configured"
    try
        resp = HTTP.get(
            "https://api.hackerone.com/v1/$path",
            ["Authorization" => auth,
             "Accept"        => "application/json",
             "X-Source"      => "JL-Engine-VRP"];
            status_exception=false, connect_timeout=10, readtimeout=15,
        )
        parsed = try JSON.parse(String(resp.body)) catch; nothing end
        resp.status in (200,201) ? (parsed, nothing) : (nothing, "H1 API $(resp.status): $(String(resp.body))")
    catch e
        return nothing, string(e)
    end
end

function _hn_fetch_scope(program_handle::String)
    lock(_HN_SCOPE_LOCK) do
        haskey(_HN_SCOPE_CACHE, program_handle) && return _HN_SCOPE_CACHE[program_handle], nothing
    end

    data, err = _hn_get("programs/$program_handle/structured_scopes")
    err !== nothing && return nothing, err

    scopes = get(data, "data", Any[])
    in_scope  = Any[]
    out_scope = Any[]

    for item in scopes
        attrs = get(item, "attributes", Dict())
        asset = Dict(
            "type"                => get(attrs, "asset_type", ""),
            "identifier"          => get(attrs, "asset_identifier", ""),
            "eligible_for_bounty" => get(attrs, "eligible_for_bounty", false),
            "eligible_for_submission" => get(attrs, "eligible_for_submission", false),
            "instruction"         => get(attrs, "instruction", ""),
            "max_severity"        => get(attrs, "max_severity", ""),
        )
        if get(attrs, "eligible_for_submission", false)
            push!(in_scope, asset)
        else
            push!(out_scope, asset)
        end
    end

    result = Dict("in_scope"=>in_scope, "out_scope"=>out_scope, "program"=>program_handle)
    lock(_HN_SCOPE_LOCK) do
        _HN_SCOPE_CACHE[program_handle] = result
    end
    return result, nothing
end

function _hn_check_target_in_scope(target::String, scope::Dict)
    host = replace(target, r"https?://" => "") |> x -> split(x, "/")[1] |> x -> split(x, ":")[1]

    for asset in get(scope, "in_scope", Any[])
        identifier = string(get(asset, "identifier", ""))
        asset_type = string(get(asset, "type", ""))

        if asset_type in ("URL", "WILDCARD")
            # Strip protocol from identifier
            clean_id = replace(identifier, r"https?://|\*\." => "")
            # Wildcard match: *.example.com matches sub.example.com
            if startswith(identifier, "*.") && endswith(host, clean_id)
                return true, asset
            end
            # Direct match or host starts with identifier
            if host == clean_id || endswith(host, ".$clean_id")
                return true, asset
            end
        elseif asset_type in ("IP_ADDRESS", "CIDR")
            # Basic IP match
            host == identifier && return true, asset
        end
    end
    return false, nothing
end

# ── tool_hn_programs ──────────────────────────────────────────────────────────

function tool_hackerone_programs(args)
    data, err = _hn_get("me/programs")
    err !== nothing && return Dict("error" => err)

    programs = Any[]
    for item in get(get(data, "data", Dict()), "items", get(data, "data", Any[]))
        item isa AbstractDict || continue
        attrs  = get(item, "attributes", Dict())
        handle = string(get(attrs, "handle", get(item, "id", "?")))
        push!(programs, Dict(
            "handle"       => handle,
            "name"         => get(attrs, "name", handle),
            "state"        => get(attrs, "state", ""),
            "bounties"     => get(attrs, "offers_bounties", false),
            "response_sla" => get(attrs, "first_response_time", ""),
            "url"          => "https://hackerone.com/$handle",
        ))
    end

    return Dict("programs" => programs, "count" => length(programs),
                "hint" => "Use tool_hn_scope(program='handle') to see scope for any program.")
end

# ── tool_hn_scope ─────────────────────────────────────────────────────────────

function tool_hackerone_scope(args)
    program = string(get(args, "program", ""))
    isempty(program) && return Dict("error" => "program handle is required (e.g. 'twitter' or 'shopify')")

    scope, err = _hn_fetch_scope(program)
    err !== nothing && return Dict("error" => err, "program" => program)

    return Dict(
        "program"       => program,
        "in_scope"      => scope["in_scope"],
        "out_scope"     => scope["out_scope"],
        "in_scope_count"  => length(scope["in_scope"]),
        "out_scope_count" => length(scope["out_scope"]),
        "url"           => "https://hackerone.com/$program",
        "hint"          => "Pass program='$program' to cascade_spawn to enforce scope automatically.",
    )
end

# ── MetaMorph Synthesis ───────────────────────────────────────────────────────
# hypothesis_generation phase: synthesizes attack hypotheses from recon

function _metamorph_synthesize(target::String, recon::Dict)
    hypotheses = Any[]

    headers_audit = get(recon, "headers_audit", get(recon, "headers", Dict()))
    cors_result   = get(recon, "cors", Dict())

    missing_h = get(get(headers_audit, "missing", Dict()), "headers", String[])
    if "Content-Security-Policy" in missing_h
        push!(hypotheses, Dict("type"=>"XSS","confidence"=>0.7,
            "rationale"=>"No CSP — reflected/stored XSS viable",
            "test_payloads"=>["<script>alert(1)</script>","<img src=x onerror=alert(1)>"]))
    end
    if "Strict-Transport-Security" in missing_h
        push!(hypotheses, Dict("type"=>"SSL_downgrade","confidence"=>0.45,
            "rationale"=>"No HSTS — SSL stripping viable on active MITM paths"))
    end
    if "X-Frame-Options" in missing_h
        push!(hypotheses, Dict("type"=>"Clickjacking","confidence"=>0.6,
            "rationale"=>"No X-Frame-Options — UI redress / clickjacking viable"))
    end

    if get(cors_result, "vulnerable", false)
        push!(hypotheses, Dict("type"=>"CORS_ATO","confidence"=>0.9,
            "rationale"=>"CORS misconfiguration: $(get(cors_result,"vuln_type","?")) — cross-origin credential theft",
            "validated"=>true,
            "evidence"=>["CORS vuln confirmed by cors_check"]))
    end

    server   = string(get(get(recon, "server", Dict()), "name", ""))
    version  = string(get(get(recon, "server", Dict()), "version", ""))
    if !isempty(version)
        push!(hypotheses, Dict("type"=>"CVE_probe","confidence"=>0.55,
            "rationale"=>"Server version exposed: $server $version — check CVE db",
            "server"=>server, "version"=>version))
    end

    cms = string(get(recon, "cms", ""))
    if cms == "WordPress"
        push!(hypotheses, Dict("type"=>"WP_enum","confidence"=>0.65,
            "rationale"=>"WordPress — plugin/user enumeration and weak auth viable"))
    elseif cms in ("Drupal","Joomla","Magento")
        push!(hypotheses, Dict("type"=>"CMS_CVE","confidence"=>0.6,
            "rationale"=>"$cms — check SA-CORE advisories and default admin paths"))
    end

    high_risk_ports = get(get(recon, "ports", Dict()), "high_risk", Int[])
    if 6379 in high_risk_ports
        push!(hypotheses, Dict("type"=>"Redis_unauth","confidence"=>0.8,
            "rationale"=>"Redis port open — check for unauthenticated access"))
    end
    if 9200 in high_risk_ports || 9300 in high_risk_ports
        push!(hypotheses, Dict("type"=>"Elasticsearch_unauth","confidence"=>0.75,
            "rationale"=>"Elasticsearch port open — check for open index"))
    end
    if 27017 in high_risk_ports
        push!(hypotheses, Dict("type"=>"MongoDB_unauth","confidence"=>0.75,
            "rationale"=>"MongoDB port open — check for no-auth access"))
    end

    # Secrets from JS harvest
    js_findings = get(get(recon, "js_harvest", Dict()), "findings", Any[])
    for f in js_findings
        push!(hypotheses, Dict("type"=>"Secret_exposure","confidence"=>0.95,
            "rationale"=>"Secret found in JS: $(get(f,"type","?"))",
            "evidence"=>["$(get(f,"type","?")): $(get(f,"snippet","?"))"],
            "validated"=>true))
    end

    return hypotheses
end

# ── Balthazar Validation ──────────────────────────────────────────────────────
# validation_cycle phase: re-tests each hypothesis

function _balthazar_validate(target::String, hypothesis::Dict)
    vuln_type  = string(get(hypothesis, "type", "unknown"))
    confidence = Float64(get(hypothesis, "confidence", 0.5))

    # Pre-validated hypotheses (CORS, JS secrets) skip re-testing
    if get(hypothesis, "validated", false)
        return Dict(
            "vuln_type"           => vuln_type,
            "confirmed"           => confidence >= 0.8,
            "validation_score"    => confidence,
            "evidence"            => get(hypothesis, "evidence", String[]),
            "original_confidence" => confidence,
        )
    end

    validation_score = 0.0
    evidence = String[]

    if vuln_type == "XSS"
        payloads = get(hypothesis, "test_payloads", ["<script>alert(1)</script>"])
        for p in first(payloads, 2)
            try
                probe_url = contains(target, "?") ?
                    "$(target)&x=$(HTTP.escapeuri(p))" :
                    "$(target)?x=$(HTTP.escapeuri(p))"
                resp = HTTP.get(probe_url; status_exception=false,
                                connect_timeout=6, readtimeout=8)
                body = String(resp.body)
                if contains(body, p) || contains(body, "alert(1)")
                    validation_score = max(validation_score, 0.95)
                    push!(evidence, "Payload reflected: $(first(p,60))")
                end
            catch e
                @warn "Cascade XSS validation probe failed" target=target exception=(e, catch_backtrace())
            end
        end

    elseif vuln_type == "Clickjacking"
        try
            resp = HTTP.get(target; status_exception=false,
                            connect_timeout=5, readtimeout=8)
            hdrs = Dict(lowercase(string(k))=>string(v) for (k,v) in resp.headers)
            if !haskey(hdrs, "x-frame-options") && !contains(get(hdrs,"content-security-policy",""), "frame-ancestors")
                validation_score = 0.85
                push!(evidence, "Neither X-Frame-Options nor CSP frame-ancestors present")
            end
        catch e
            @warn "Cascade clickjacking validation failed" target=target exception=(e, catch_backtrace())
        end

    elseif vuln_type == "CVE_probe"
        validation_score = min(confidence + 0.15, 0.75)
        push!(evidence, "Server version exposed: $(get(hypothesis,"server","")) $(get(hypothesis,"version",""))")

    elseif contains(vuln_type, "_unauth")
        # Port-based — already confirmed by port_scan; add contextual score
        validation_score = min(confidence + 0.1, 0.85)
        push!(evidence, "Service confirmed open by port scan")

    else
        try
            resp = HTTP.get(target; status_exception=false, connect_timeout=6, readtimeout=8)
            validation_score = resp.status < 500 ? confidence : confidence * 0.4
            push!(evidence, "HTTP $(resp.status) on re-probe")
        catch
            validation_score = confidence * 0.3
        end
    end

    return Dict(
        "vuln_type"           => vuln_type,
        "confirmed"           => validation_score >= 0.8,
        "validation_score"    => round(validation_score; digits=3),
        "evidence"            => evidence,
        "original_confidence" => confidence,
    )
end

# ── Cascade Phase Runner ──────────────────────────────────────────────────────

function _run_cascade_phase!(swarm_id::String, recon::Dict)
    s = _get_swarm(swarm_id)
    isempty(s) && return

    target   = s["target"]
    operator = s["operator"]

    # ── Phase 1: indexing ─────────────────────────────────────────────────────
    _update_swarm!(swarm_id; phase="indexing", after_state="active_discovery")
    _cascade_broadcast("cascade_phase", Dict("swarm_id"=>swarm_id,
        "phase"=>"indexing", "gait"=>"walk", "aperture"=>"FOCUSED"))
    _cascade_diary(swarm_id, "indexing",
        "Recon ingested. server=$(get(get(recon,"server",Dict()),"name","?")) cms=$(get(recon,"cms","?")) cors_vuln=$(get(get(recon,"cors",Dict()),"vulnerable",false))",
        mood="focused", gait="walk")

    # ── Phase 2: hypothesis_generation (MetaMorph) ────────────────────────────
    _update_swarm!(swarm_id; phase="hypothesis_generation", after_state="active_discovery")
    _cascade_broadcast("cascade_phase", Dict("swarm_id"=>swarm_id,
        "phase"=>"hypothesis_generation", "gait"=>"trot", "aperture"=>"OPEN"))

    hypotheses = _metamorph_synthesize(target, recon)
    _cascade_broadcast("cascade_hypotheses", Dict("swarm_id"=>swarm_id,
        "count"=>length(hypotheses),
        "types"=>map(h->get(h,"type","?"), hypotheses)))
    _cascade_diary(swarm_id, "hypothesis_generation",
        "MetaMorph: $(length(hypotheses)) hypotheses — $(join(map(h->get(h,"type","?"), hypotheses), ", "))",
        mood="curious", gait="trot")

    # ── Phase 3: validation_cycle (Balthazar) ─────────────────────────────────
    _update_swarm!(swarm_id; phase="validation_cycle", after_state="validating_finding",
                   validation_strictness=0.5, drift_pressure=0.2)
    _cascade_broadcast("cascade_phase", Dict("swarm_id"=>swarm_id,
        "phase"=>"validation_cycle", "gait"=>"sprint", "aperture"=>"TIGHT"))

    confirmed_findings = Any[]
    failed_findings    = Any[]

    for hyp in hypotheses
        result = _balthazar_validate(target, hyp)
        merged = merge(hyp, result)
        if result["confirmed"]
            push!(confirmed_findings, merged)
            _push_finding!(swarm_id, merge(merged, Dict("confirmed"=>true)))
            _cascade_remember(swarm_id, "validation_cycle",
                "CONFIRMED: $(result["vuln_type"]) score=$(result["validation_score"])",
                result["validation_score"] >= 0.9 ? "critical" : "high")
            _cascade_broadcast("cascade_finding", Dict("swarm_id"=>swarm_id,
                "status"=>"CONFIRMED", "finding"=>merged))
            _cascade_diary(swarm_id, "validation_cycle",
                "Balthazar CONFIRMED: $(result["vuln_type"]) ($(result["validation_score"]))",
                mood="intense", gait="sprint")
        else
            push!(failed_findings, merged)
            _push_finding!(swarm_id, merge(merged, Dict("confirmed"=>false)))
            _update_swarm!(swarm_id; after_state="backtracking_failed_reproduction")
            _cascade_broadcast("cascade_finding", Dict("swarm_id"=>swarm_id,
                "status"=>"FAILED_REPRO", "finding"=>merged))
        end
    end

    total = length(hypotheses)
    v_strict = total > 0 ? round(length(confirmed_findings) / total; digits=3) : 0.0
    _update_swarm!(swarm_id;
        validation_strictness = v_strict,
        after_state = isempty(confirmed_findings) ?
            "backtracking_failed_reproduction" : "evidence_locked")

    # ── Phase 4: escalation check ─────────────────────────────────────────────
    s = _get_swarm(swarm_id)
    advisory = _cascade_advisory(
        Float64(get(s, "evidence_demand", 0.0)),
        Float64(get(s, "validation_strictness", 0.0)),
    )

    if advisory["can_escalate"]
        _update_swarm!(swarm_id; phase="escalation",
                       after_state="escalating_to_hackerone", status="escalating")
        _cascade_broadcast("cascade_phase", Dict("swarm_id"=>swarm_id,
            "phase"=>"escalation", "advisory"=>advisory,
            "findings_count"=>length(confirmed_findings)))
        _cascade_diary(swarm_id, "escalation",
            "HackerOne gate OPEN — evidence=$(advisory["evidence_demand"]) validation=$(advisory["validation_strictness"])",
            mood="urgent", gait="sprint")

        auto_submit = lowercase(strip(get(ENV, "HACKERONE_AUTO_SUBMIT", "false"))) == "true"

        if auto_submit
            hn_result = _hn_submit_report(target, confirmed_findings, swarm_id)
            _update_swarm!(swarm_id;
                hn_report_id = get(hn_result, "report_id", nothing),
                hn_result    = hn_result,
                status       = "escalated")
            _cascade_broadcast("cascade_hn_submitted", Dict("swarm_id"=>swarm_id,
                "submitted"   => get(hn_result,"submitted",false),
                "report_id"   => get(hn_result,"report_id",""),
                "title"       => get(hn_result,"title","")))
            _cascade_diary(swarm_id, "escalation",
                "HackerOne auto-submitted: id=$(get(hn_result,"report_id","")) submitted=$(get(hn_result,"submitted",false))",
                mood=get(hn_result,"submitted",false) ? "resolved" : "alarmed",
                gait="sprint")
        else
            # Stage for human review — call cascade_submit(swarm_id) to actually send
            _update_swarm!(swarm_id; status="staged_for_review")
            _cascade_broadcast("cascade_staged", Dict(
                "swarm_id"      => swarm_id,
                "target"        => target,
                "confirmed"     => length(confirmed_findings),
                "advisory"      => advisory,
                "message"       => "Report staged for review. Call cascade_submit(swarm_id='$swarm_id') to send to HackerOne.",
                "findings"      => confirmed_findings,
            ))
            _cascade_diary(swarm_id, "escalation",
                "Evidence locked. Report STAGED — awaiting human review before HackerOne submission.",
                mood="resolved", gait="walk")
        end
    else
        _update_swarm!(swarm_id; phase="complete", status="complete")
        _cascade_broadcast("cascade_complete", Dict("swarm_id"=>swarm_id,
            "confirmed"=>length(confirmed_findings),
            "failed"=>length(failed_findings),
            "advisory"=>advisory,
            "reason"=>"Thresholds not met: evidence=$(round(advisory["evidence_demand"];digits=2))/$(CASCADE_HN_EVIDENCE_THRESHOLD) validation=$(round(advisory["validation_strictness"];digits=2))/$(CASCADE_HN_VALIDATION_THRESHOLD)"))
        _cascade_diary(swarm_id, "complete",
            "Swarm done. $(length(confirmed_findings)) confirmed / $(length(failed_findings)) failed. Escalation held — thresholds not met.",
            mood="resolved", gait="walk")
    end

    return confirmed_findings, failed_findings, advisory
end

# ── tool_cascade_spawn ────────────────────────────────────────────────────────

function tool_cascade_spawn(args)
    target   = string(get(args, "target", ""))
    depth    = lowercase(string(get(args, "scope", "standard")))
    operator = string(get(args, "operator", _active_operator()))
    recon    = get(args, "recon", nothing)
    program  = string(get(args, "program", ""))

    depth in ("quick","standard","deep") || (depth = "standard")

    # ── Program mode: pull scope from HackerOne, run against ALL in-scope targets ──
    if !isempty(program) && isempty(target)
        hn_scope_data, scope_err = _hn_fetch_scope(program)
        scope_err !== nothing && return Dict("error" => "Could not fetch scope for '$program': $scope_err")

        in_scope_assets = get(hn_scope_data, "in_scope", Any[])
        isempty(in_scope_assets) && return Dict(
            "error"   => "No in-scope assets found for program '$program'.",
            "program" => program,
        )

        # Extract web targets from scope — URLs and wildcards only
        targets = String[]
        for asset in in_scope_assets
            atype = string(get(asset, "type", ""))
            id    = string(get(asset, "identifier", ""))
            isempty(id) && continue
            atype in ("URL","WILDCARD") || continue
            url = startswith(id, "http") ? id :
                  startswith(id, "*.") ? "https://$(id[3:end])" : "https://$id"
            push!(targets, url)
        end

        isempty(targets) && return Dict(
            "error"      => "No web targets (URL/WILDCARD) in scope for '$program'.",
            "all_assets" => in_scope_assets,
        )

        _cascade_broadcast("cascade_program_launch", Dict(
            "program" => program,
            "targets" => targets,
            "count"   => length(targets),
            "depth"   => depth,
            "message" => "Scope pulled from HackerOne — launching against $(length(targets)) in-scope targets",
        ))

        return tool_swarm_launch(Dict("targets"=>targets, "scope"=>depth,
                                      "operator"=>operator, "program"=>program))
    end

    # ── Single target mode ────────────────────────────────────────────────────
    isempty(target) && return Dict("error" => "Provide program= (HackerOne handle) or target= (URL)")
    url = startswith(target, "http") ? target : "https://$target"

    # Scope-gate if program provided with explicit target
    if !isempty(program)
        hn_scope_data, scope_err = _hn_fetch_scope(program)
        scope_err !== nothing && return Dict("error" => "Could not fetch scope for '$program': $scope_err")
        in_scope, matched_asset = _hn_check_target_in_scope(url, hn_scope_data)
        in_scope || return Dict(
            "error"           => "OUT OF SCOPE — $url not in scope for '$program'. Blocked.",
            "program"         => program,
            "in_scope_assets" => hn_scope_data["in_scope"],
        )
        _cascade_broadcast("cascade_scope_confirmed", Dict(
            "target"=>url, "program"=>program,
            "asset_type"=>get(matched_asset,"type",""),
            "bounty_eligible"=>get(matched_asset,"eligible_for_bounty",false),
        ))
    end

    swarm_id = _new_swarm(url, depth, operator)
    !isempty(program) && _update_swarm!(swarm_id; hn_program=program)

    _cascade_broadcast("cascade_spawned", Dict(
        "swarm_id" => swarm_id, "target" => url, "depth" => depth,
        "operator" => operator, "program" => program,
        "phases"   => ["indexing","hypothesis_generation","validation_cycle","escalation"],
    ))

    recon_data = if recon isa Dict
        recon
    else
        _cascade_diary(swarm_id, "indexing", "Auto-recon: $url", gait="walk")
        auto = Dict{String,Any}()
        try
            merge!(auto, tool_tech_detect(Dict("url"=>url, "operator"=>operator)))
        catch e
            @warn "Cascade auto-recon tech_detect failed" target=url exception=(e, catch_backtrace())
        end
        try
            auto["headers_audit"] = tool_security_headers(Dict("url"=>url, "operator"=>operator))
        catch e
            @warn "Cascade auto-recon security_headers failed" target=url exception=(e, catch_backtrace())
        end
        try
            auto["cors"] = tool_cors_check(Dict("url"=>url, "operator"=>operator))
        catch e
            @warn "Cascade auto-recon cors_check failed" target=url exception=(e, catch_backtrace())
        end
        if depth in ("standard","deep")
            host = split(replace(url, r"https?://" => ""), "/")[1] |> x->split(x,":")[1]
            try
                auto["ports"] = tool_port_scan(Dict("host"=>host, "operator"=>operator))
            catch e
                @warn "Cascade auto-recon port_scan failed" host=host exception=(e, catch_backtrace())
            end
        end
        if depth == "deep"
            try
                auto["js_harvest"] = tool_js_harvest(Dict("url"=>url, "operator"=>operator))
            catch e
                @warn "Cascade auto-recon js_harvest failed" target=url exception=(e, catch_backtrace())
            end
        end
        auto
    end

    @async begin
        try
            _run_cascade_phase!(swarm_id, recon_data)
        catch e
            _update_swarm!(swarm_id; status="error", swarm_error=string(e))
            _cascade_broadcast("cascade_error", Dict("swarm_id"=>swarm_id, "error"=>string(e)))
            _cascade_diary(swarm_id, "error", "Swarm crashed: $(string(e))", mood="alarmed", gait="idle")
        end
    end

    return Dict(
        "swarm_id"    => swarm_id,
        "target"      => url,
        "depth"       => depth,
        "operator"    => operator,
        "status"      => "running",
        "phase"       => "indexing",
        "after_state" => "active_discovery",
        "message"     => "Cascade runner $swarm_id launched. Poll: cascade_status(swarm_id='$swarm_id')",
    )
end

# ── tool_cascade_status ───────────────────────────────────────────────────────

function tool_cascade_status(args)
    swarm_id = string(get(args, "swarm_id", ""))

    if isempty(swarm_id)
        all_s = lock(_CASCADE_LOCK) do
            map(collect(values(_CASCADE_SWARMS))) do s
                confirmed = count(f->get(f,"confirmed",false), get(s,"findings",Any[]))
                Dict(
                    "swarm_id"    => s["swarm_id"],
                    "target"      => s["target"],
                    "phase"       => s["phase"],
                    "after_state" => s["after_state"],
                    "status"      => s["status"],
                    "findings"    => length(get(s,"findings",Any[])),
                    "confirmed"   => confirmed,
                    "started_at"  => s["started_at"],
                    "evidence_demand"        => s["evidence_demand"],
                    "validation_strictness"  => s["validation_strictness"],
                    "hn_report_id"           => s["hn_report_id"],
                )
            end
        end
        return Dict("runners"=>all_s, "count"=>length(all_s))
    end

    s = _get_swarm(swarm_id)
    isempty(s) && return Dict("error" => "Unknown swarm_id: $swarm_id")

    all_findings  = get(s, "findings", Any[])
    confirmed_f   = filter(f->get(f,"confirmed",false), all_findings)
    advisory      = _cascade_advisory(
        Float64(get(s,"evidence_demand",0.0)),
        Float64(get(s,"validation_strictness",0.0)),
    )

    return Dict(
        "swarm_id"    => swarm_id,
        "target"      => s["target"],
        "scope"       => s["scope"],
        "operator"    => s["operator"],
        "phase"       => s["phase"],
        "after_state" => s["after_state"],
        "status"      => s["status"],
        "started_at"  => s["started_at"],
        "findings" => Dict(
            "total"     => length(all_findings),
            "confirmed" => length(confirmed_f),
            "failed"    => length(all_findings) - length(confirmed_f),
            "list"      => all_findings,
        ),
        "scalars" => Dict(
            "evidence_demand"       => s["evidence_demand"],
            "validation_strictness" => s["validation_strictness"],
            "drift_pressure"        => s["drift_pressure"],
        ),
        "advisory"      => advisory,
        "hn_report_id"  => s["hn_report_id"],
        "hn_result"     => get(s, "hn_result", nothing),
        "cascade_version" => CASCADE_VERSION,
    )
end

# ── tool_cascade_kill ─────────────────────────────────────────────────────────

function tool_cascade_kill(args)
    swarm_id = string(get(args, "swarm_id", ""))
    isempty(swarm_id) && return Dict("error" => "swarm_id is required")
    isempty(_get_swarm(swarm_id)) && return Dict("error" => "Unknown swarm_id: $swarm_id")
    _update_swarm!(swarm_id; status="killed")
    _cascade_broadcast("cascade_killed", Dict("swarm_id"=>swarm_id))
    _cascade_diary(swarm_id, "killed", "Runner killed by operator.", mood="neutral", gait="idle")
    return Dict("swarm_id"=>swarm_id, "status"=>"killed")
end

# ── tool_swarm_launch ─────────────────────────────────────────────────────────
# D — Distributed multi-target sweep: N Cascade runners in parallel Julia Tasks

function tool_swarm_launch(args)
    targets_raw = get(args, "targets", Any[])
    targets = if targets_raw isa AbstractVector
        filter(!isempty, map(t->startswith(string(t),"http") ? string(t) : "https://$(string(t))", targets_raw))
    else
        filter(!isempty, map(t->startswith(t,"http") ? t : "https://$t",
                             split(string(targets_raw), r"[,\n\s]+")))
    end

    isempty(targets) && return Dict("error" => "targets list is required and must be non-empty")

    scope    = lowercase(string(get(args, "scope", "quick")))
    operator = string(get(args, "operator", _active_operator()))
    scope in ("quick","standard","deep") || (scope = "quick")

    fleet_id  = string(UUIDs.uuid4())[1:8]
    swarm_ids = String[]

    _cascade_broadcast("swarm_fleet_launched", Dict(
        "fleet_id" => fleet_id,
        "targets"  => targets,
        "count"    => length(targets),
        "scope"    => scope,
        "operator" => operator,
        "message"  => "Fleet $fleet_id: $(length(targets)) Cascade runners launched in parallel",
    ))

    for target in targets
        sid = _new_swarm(target, scope, operator)
        push!(swarm_ids, sid)

        @async begin
            try
                auto = Dict{String,Any}()
                try
                    merge!(auto, tool_tech_detect(Dict("url"=>target,"operator"=>operator)))
                catch e
                    @warn "Swarm launch tech_detect failed" target=target exception=(e, catch_backtrace())
                end
                try
                    auto["headers_audit"] = tool_security_headers(Dict("url"=>target,"operator"=>operator))
                catch e
                    @warn "Swarm launch security_headers failed" target=target exception=(e, catch_backtrace())
                end
                try
                    auto["cors"] = tool_cors_check(Dict("url"=>target,"operator"=>operator))
                catch e
                    @warn "Swarm launch cors_check failed" target=target exception=(e, catch_backtrace())
                end
                _run_cascade_phase!(sid, auto)
            catch e
                _update_swarm!(sid; status="error", swarm_error=string(e))
                _cascade_broadcast("cascade_error", Dict(
                    "fleet_id"=>fleet_id, "swarm_id"=>sid,
                    "target"=>target, "error"=>string(e)))
            end
        end
    end

    return Dict(
        "fleet_id"  => fleet_id,
        "swarm_ids" => swarm_ids,
        "targets"   => targets,
        "scope"     => scope,
        "operator"  => operator,
        "count"     => length(swarm_ids),
        "message"   => "Fleet $fleet_id active. Poll all runners: cascade_status()",
        "hn_gate"   => "evidence > $(CASCADE_HN_EVIDENCE_THRESHOLD) AND validation > $(CASCADE_HN_VALIDATION_THRESHOLD)",
    )
end

# ── tool_cascade_submit ───────────────────────────────────────────────────────
# Manual gate: review cascade_status first, then call this to actually send
# the staged report to HackerOne. Only works on swarms in "staged_for_review".

function tool_cascade_submit(args)
    swarm_id = string(get(args, "swarm_id", ""))
    isempty(swarm_id) && return Dict("error" => "swarm_id is required")

    s = _get_swarm(swarm_id)
    isempty(s) && return Dict("error" => "Unknown swarm_id: $swarm_id")

    status = string(get(s, "status", ""))
    if status != "staged_for_review"
        return Dict(
            "error"   => "Swarm is not staged for review (current status: $status).",
            "hint"    => status == "escalated" ? "Already submitted — check hn_report_id in cascade_status." :
                         status == "running"   ? "Still running — wait for it to complete first." :
                         "Run cascade_status(swarm_id='$swarm_id') to check current state.",
        )
    end

    confirmed = filter(f -> get(f,"confirmed",false), get(s,"findings",Any[]))
    isempty(confirmed) && return Dict("error" => "No confirmed findings to submit.")

    _cascade_diary(swarm_id, "escalation",
        "Human review complete — submitting to HackerOne now.", mood="urgent", gait="sprint")

    hn_result = _hn_submit_report(s["target"], confirmed, swarm_id)

    _update_swarm!(swarm_id;
        hn_report_id = get(hn_result, "report_id", nothing),
        hn_result    = hn_result,
        status       = get(hn_result, "submitted", false) ? "escalated" : "submit_failed")

    _cascade_broadcast("cascade_hn_submitted", Dict(
        "swarm_id"   => swarm_id,
        "submitted"  => get(hn_result,"submitted",false),
        "report_id"  => get(hn_result,"report_id",""),
        "title"      => get(hn_result,"title",""),
    ))
    _cascade_diary(swarm_id, "escalation",
        "HackerOne submission: submitted=$(get(hn_result,"submitted",false)) id=$(get(hn_result,"report_id",""))",
        mood=get(hn_result,"submitted",false) ? "resolved" : "alarmed", gait="sprint")

    return merge(hn_result, Dict("swarm_id"=>swarm_id, "confirmed_findings"=>length(confirmed)))
end

export tool_hackerone_programs, tool_hackerone_scope,
       tool_cascade_spawn, tool_cascade_status, tool_cascade_kill, tool_cascade_submit,
       tool_swarm_launch
