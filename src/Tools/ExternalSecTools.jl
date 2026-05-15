# ExternalSecTools.jl — JL Engine wrappers for external CLI security tools
# Tools: ffuf, nuclei, httpx, sqlmap, ZAP REST API, mitmdump
# For authorized testing, CTF competitions, and bug bounty programs only.
#
# On Windows, all CLI tools are dispatched into WSL2 via:
#   powershell pipe → wsl bash
# On Linux, a temp bash script is executed directly.

# ── Shared runner (defined here so it's usable before tool_run_command exists) ──

function _ext_run(bash_script::String; timeout_ms::Int=60_000)
    out_buf  = IOBuffer()
    tmp_file = nothing
    try
        if Sys.iswindows()
            tmp_file = tempname() * ".ps1"
            # Single-quoted PS1 here-string — $-signs and backticks are NOT expanded.
            # Closing '@ MUST be at column 0.
            write(tmp_file, "@'\n$(bash_script)\n'@ | wsl bash")
            cmd = `powershell -NoProfile -ExecutionPolicy Bypass -NonInteractive -File $tmp_file`
        else
            sh       = something(Sys.which("bash"), "bash")
            tmp_file = tempname() * ".sh"
            write(tmp_file, "#!/usr/bin/env bash\nset -euo pipefail\n$bash_script")
            cmd = `$sh $tmp_file`
        end
        proc = run(pipeline(ignorestatus(cmd), stdout=out_buf, stderr=out_buf); wait=false)
        deadline = time() + timeout_ms / 1000.0
        while process_running(proc) && time() < deadline
            sleep(0.3)
        end
        timed_out = process_running(proc)
        timed_out && kill(proc)
        return (exitcode=proc.exitcode, output=String(take!(out_buf)), timed_out=timed_out)
    catch e
        return (exitcode=-1, output=string(e), timed_out=false)
    finally
        tmp_file !== nothing && rm(tmp_file; force=true)
    end
end

# Parse a stream of JSON lines (nuclei / httpx -json output) into a vector of Dicts.
function _parse_jsonl(text::String)::Vector{Dict{String,Any}}
    out = Dict{String,Any}[]
    for line in split(strip(text), "\n")
        line = strip(line)
        isempty(line) && continue
        try
            push!(out, JSON.parse(line))
        catch
        end
    end
    return out
end

# Friendly "not installed" hint given raw output.
function _not_installed_msg(tool::String, install_hint::String, raw::String)::Union{Nothing,Dict}
    if contains(raw, "not found") || contains(raw, "command not found") || contains(raw, "No such file")
        return Dict(
            "error"   => "$tool not found in WSL2. Install: $install_hint",
            "raw"     => first(raw, 400),
        )
    end
    return nothing  # Tool is installed/found
end

# ── tool_ffuf ─────────────────────────────────────────────────────────────────

function tool_ffuf(args::Dict)
    url     = string(get(args, "url", ""))
    mc      = string(get(args, "match_codes",  "200,204,301,302,307,401,403"))
    fc      = string(get(args, "filter_codes", "404"))
    threads = Int(get(args, "threads",    40))
    timeout = Int(get(args, "timeout_ms", 90_000))
    extra   = string(get(args, "extra_flags", ""))
    op      = string(get(args, "operator", _active_operator()))

    isempty(url) && return Dict("error" => "url is required (include FUZZ placeholder, e.g. https://target.com/FUZZ)")
    !contains(url, "FUZZ") && return Dict("error" => "url must contain the FUZZ keyword, e.g. https://target.com/FUZZ")

    rid      = string(rand(UInt32))
    out_file = "/tmp/jl_ffuf_$(rid).json"
    wl_file  = "/tmp/jl_wl_$(rid).txt"

    # Wordlist — path string, array, or operator built-in
    custom = get(args, "wordlist", nothing)
    wordlist_setup = ""
    if custom isa AbstractString && !isempty(custom)
        wl_ref = string(custom)
    elseif custom isa AbstractVector && !isempty(custom)
        words        = join(map(string, custom), "\n")
        wordlist_setup = "cat > $wl_file << 'ENDWL'\n$words\nENDWL\n"
        wl_ref         = wl_file
    else
        # fall back to a Kali SecLists path
        wordlist_setup = "WL=/usr/share/seclists/Discovery/Web-Content/common.txt\n" *
                         "[ -f \"$WL\" ] || WL=/usr/share/wordlists/dirb/common.txt\n" *
                         "[ -f \"$WL\" ] || WL=/usr/share/wordlists/dirb/small.txt\n"
        wl_ref         = "\$WL"
    end

    fc_part = isempty(fc) ? "" : "-fc $fc"

    bash_script = """
$(wordlist_setup)ffuf -u '$url' -w $wl_ref -mc $mc $fc_part -t $threads -o $out_file -of json $extra 2>/dev/null
if [ -f $out_file ]; then cat $out_file; rm -f $out_file; fi
rm -f $wl_file 2>/dev/null || true
"""

    _pentest_broadcast("ffuf_start", Dict("url" => url, "threads" => threads, "operator" => op))

    r = _ext_run(bash_script; timeout_ms=timeout)

    ni = _not_installed_msg("ffuf", "go install github.com/ffuf/ffuf/v2@latest", r.output)
    ni !== nothing && return ni

    hits = Any[]
    try
        if !isempty(strip(r.output))
            data  = JSON.parse(r.output)
            raw_r = get(data, "results", Any[])
            hits  = [Dict(
                "url"    => string(get(h, "url",    "")),
                "status" => Int(get(h, "status",  0)),
                "length" => Int(get(h, "length",  0)),
                "words"  => Int(get(h, "words",   0)),
                "lines"  => Int(get(h, "lines",   0)),
            ) for h in raw_r]
        end
    catch
        return Dict("error" => "Failed to parse ffuf output", "raw" => first(r.output, 1200), "exitcode" => r.exitcode)
    end

    !isempty(hits) && _pentest_broadcast("ffuf_hits",
        Dict("url" => url, "count" => length(hits), "operator" => op))
    !isempty(hits) && _pentest_diary("ffuf",
        "$(length(hits)) paths found on $url", mood="curious", gait="trot")

    return Dict("url" => url, "hits" => hits, "total" => length(hits),
                "timed_out" => r.timed_out, "exitcode" => r.exitcode, "operator" => op)
end

# ── tool_nuclei ───────────────────────────────────────────────────────────────

function tool_nuclei(args::Dict)
    target    = string(get(args, "target",    ""))
    templates = string(get(args, "templates", ""))     # e.g. "cves,misconfiguration"
    severity  = string(get(args, "severity",  "low,medium,high,critical"))
    tags      = string(get(args, "tags",      ""))
    rate      = Int(get(args, "rate_limit",   150))
    timeout   = Int(get(args, "timeout_ms",   120_000))
    op        = string(get(args, "operator",  _active_operator()))

    isempty(target) && return Dict("error" => "target is required")

    tpl_flag  = isempty(templates) ? "" : "-t $templates"
    tags_flag = isempty(tags)      ? "" : "-tags $tags"

    bash_script = """
nuclei -u '$target' $tpl_flag $tags_flag -severity $severity -rl $rate -json -silent 2>/dev/null
"""

    _pentest_broadcast("nuclei_start", Dict("target" => target, "severity" => severity, "operator" => op))

    r = _ext_run(bash_script; timeout_ms=timeout)

    ni = _not_installed_msg("nuclei", "go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest", r.output)
    ni !== nothing && return ni

    findings = _parse_jsonl(r.output)

    # Summarize by severity
    by_sev = Dict{String,Int}()
    for f in findings
        sev = lowercase(string(get(get(f, "info", Dict()), "severity", get(f, "severity", "unknown"))))
        by_sev[sev] = get(by_sev, sev, 0) + 1
    end

    if !isempty(findings)
        _pentest_broadcast("nuclei_findings",
            Dict("target" => target, "count" => length(findings), "by_severity" => by_sev, "operator" => op))
        _pentest_diary("nuclei",
            "$(length(findings)) findings on $target: $(join(["$k=$v" for (k,v) in by_sev], ", "))",
            mood=get(by_sev, "critical", 0) > 0 ? "alarmed" : "alert", gait="sprint")
        for f in findings
            tid  = string(get(f, "template-id",  get(f, "templateID", "")))
            host = string(get(f, "host",  get(f, "matched-at", target)))
            sev  = lowercase(string(get(get(f, "info", Dict()), "severity", "")))
            _pentest_remember("nuclei:$(tid):$(host)", "[$sev] $tid on $host", "pentest,nuclei,$sev")
        end
    end

    return Dict(
        "target"   => target,
        "findings" => findings,
        "count"    => length(findings),
        "by_severity" => by_sev,
        "timed_out"   => r.timed_out,
        "operator"    => op,
    )
end

# ── tool_httpx ────────────────────────────────────────────────────────────────

function tool_httpx(args::Dict)
    targets_raw = get(args, "targets", get(args, "target", ""))
    timeout     = Int(get(args, "timeout_ms", 30_000))
    ports       = string(get(args, "ports", ""))
    threads     = Int(get(args, "threads", 50))
    op          = string(get(args, "operator", _active_operator()))

    targets = if targets_raw isa AbstractVector
        map(string, targets_raw)
    elseif !isempty(string(targets_raw))
        [string(targets_raw)]
    else
        String[]
    end
    isempty(targets) && return Dict("error" => "targets or target is required")

    rid        = string(rand(UInt32))
    list_file  = "/tmp/jl_httpx_$(rid).txt"
    target_str = join(targets, "\n")
    ports_flag = isempty(ports) ? "" : "-ports $ports"

    bash_script = """
cat > $list_file << 'ENDHOSTS'
$target_str
ENDHOSTS
httpx -l $list_file $ports_flag -threads $threads \
    -json -title -status-code -tech-detect -content-length -silent 2>/dev/null
rm -f $list_file
"""

    _pentest_broadcast("httpx_start",
        Dict("targets" => length(targets), "operator" => op))

    r = _ext_run(bash_script; timeout_ms=timeout)

    ni = _not_installed_msg("httpx",
        "go install github.com/projectdiscovery/httpx/cmd/httpx@latest", r.output)
    ni !== nothing && return ni

    results = _parse_jsonl(r.output)

    !isempty(results) && _pentest_diary("httpx",
        "httpx: $(length(results)) live hosts from $(length(targets)) targets",
        mood="focused", gait="trot")

    return Dict(
        "results"   => results,
        "count"     => length(results),
        "timed_out" => r.timed_out,
        "operator"  => op,
    )
end

# ── tool_sqlmap ───────────────────────────────────────────────────────────────

function tool_sqlmap(args::Dict)
    url     = string(get(args, "url", ""))
    data    = string(get(args, "data",  ""))   # POST body
    param   = string(get(args, "param", ""))   # specific param
    level   = clamp(Int(get(args, "level", 1)), 1, 5)
    risk    = clamp(Int(get(args, "risk",  1)), 1, 3)
    tech    = string(get(args, "technique", "BEUSTQ"))  # SQLi techniques
    timeout = Int(get(args, "timeout_ms", 120_000))
    op      = string(get(args, "operator", _active_operator()))

    isempty(url) && return Dict("error" => "url is required")

    rid     = string(rand(UInt32))
    out_dir = "/tmp/jl_sqlmap_$(rid)"

    data_flag  = isempty(data)  ? "" : "--data='$data'"
    param_flag = isempty(param) ? "" : "-p $param"

    bash_script = """
sqlmap -u '$url' $data_flag $param_flag \
    --level=$level --risk=$risk --technique=$tech \
    --batch --random-agent --output-dir=$out_dir \
    --answers="quit=N,crack=N,dict=N" 2>&1
echo "---SQLMAP_DONE---"
"""

    _pentest_broadcast("sqlmap_start",
        Dict("url" => url, "level" => level, "risk" => risk, "operator" => op))

    r = _ext_run(bash_script; timeout_ms=timeout)

    ni = _not_installed_msg("sqlmap", "sudo apt-get install -y sqlmap", r.output)
    ni !== nothing && return ni

    raw = r.output

    # Extract key findings from sqlmap text output
    vulnerable   = contains(raw, "is vulnerable") || contains(raw, "sqlmap identified")
    injectable   = [m.match for m in eachmatch(r"Parameter: .+ \(.+\)\n\s+Type:", raw)]
    payloads     = [m.match for m in eachmatch(r"Payload: .+", raw)]
    db_banner    = let m = match(r"back-end DBMS: (.+)", raw); m !== nothing ? m.captures[1] : "" end
    db_version   = let m = match(r"banner: '([^']+)'",   raw); m !== nothing ? m.captures[1] : "" end

    if vulnerable
        _pentest_broadcast("sqlmap_vuln",
            Dict("url" => url, "dbms" => db_banner, "operator" => op))
        _pentest_remember("sqlmap:$url", "SQLi confirmed — $db_banner $db_version", "pentest,sqli,critical")
        _pentest_diary("sqlmap", "SQLi confirmed on $url — $db_banner", mood="intense", gait="sprint")
    end

    return Dict(
        "url"        => url,
        "vulnerable" => vulnerable,
        "injectable_params" => first(injectable, 10),
        "payloads"   => first(payloads, 5),
        "dbms"       => db_banner,
        "version"    => strip(db_version),
        "raw"        => first(raw, 3000),
        "timed_out"  => r.timed_out,
        "operator"   => op,
    )
end

# ── tool_zap_scan ─────────────────────────────────────────────────────────────
# Uses ZAP REST API — no shell needed. Start ZAP with:
#   zaproxy -daemon -port 8080 -config api.disablekey=true

function _zap_api(port::Int, path::String; api_key::String="")
    qs    = isempty(api_key) ? "" : "?apikey=$(HTTP.escapeuri(api_key))"
    url   = "http://127.0.0.1:$(port)$(path)$(qs)"
    resp  = HTTP.get(url; status_exception=false, connect_timeout=3, readtimeout=30)
    resp.status != 200 && return Dict("error" => "ZAP API returned $(resp.status)", "url" => url)
    return JSON.parse(String(resp.body))
end

function tool_zap_scan(args::Dict)
    url     = string(get(args, "url",      ""))
    mode    = lowercase(string(get(args, "mode", "alerts")))
    port    = Int(get(args, "zap_port",    8080))
    api_key = string(get(args, "api_key",  ""))
    op      = string(get(args, "operator", _active_operator()))

    isempty(url) && mode != "ping" && return Dict("error" => "url is required")
    mode in ("ping", "spider", "active_scan", "alerts", "full") ||
        return Dict("error" => "mode must be: ping, spider, active_scan, alerts, or full")

    qs_sep = isempty(api_key) ? "?" : "?apikey=$(HTTP.escapeuri(api_key))&"

    try
        # ── ping ──────────────────────────────────────────────────────────────
        if mode == "ping"
            v = _zap_api(port, "/JSON/core/view/version/"; api_key=api_key)
            return haskey(v, "error") ? merge(v, Dict(
                "tip" => "Start ZAP: zaproxy -daemon -port $port -config api.disablekey=true")) :
                Dict("status" => "ok", "zap_version" => get(v, "version", "?"), "port" => port)
        end

        # ── spider ────────────────────────────────────────────────────────────
        if mode in ("spider", "full")
            _pentest_broadcast("zap_spider_start", Dict("url" => url, "operator" => op))
            scan = _zap_api(port, "/JSON/spider/action/scan/$(qs_sep)url=$(HTTP.escapeuri(url))"; api_key=api_key)
            scan_id = string(get(scan, "scan", "0"))

            # Poll until complete (max 60s)
            deadline = time() + 60.0
            while time() < deadline
                s = _zap_api(port, "/JSON/spider/view/status/$(qs_sep)scanId=$scan_id"; api_key=api_key)
                pct = parse(Int, get(s, "status", "0"))
                _pentest_broadcast("zap_spider_progress", Dict("pct" => pct, "url" => url))
                pct >= 100 && break
                sleep(3)
            end

            mode == "spider" && return Dict("status" => "ok", "spider_scan_id" => scan_id,
                "url" => url, "operator" => op)
        end

        # ── active_scan ───────────────────────────────────────────────────────
        if mode == "active_scan"
            _pentest_broadcast("zap_ascan_start", Dict("url" => url, "operator" => op))
            scan = _zap_api(port, "/JSON/ascan/action/scan/$(qs_sep)url=$(HTTP.escapeuri(url))"; api_key=api_key)
            return Dict("status" => "ok", "ascan_id" => get(scan, "scan", ""),
                "url" => url, "tip" => "Poll alerts after scan finishes with mode=alerts", "operator" => op)
        end

        # ── alerts (also used after full) ─────────────────────────────────────
        enc = HTTP.escapeuri(url)
        raw = _zap_api(port,
            "/JSON/core/view/alerts/$(qs_sep)baseurl=$enc&start=0&count=200"; api_key=api_key)
        alerts = get(raw, "alerts", Any[])

        by_risk = Dict{String,Int}()
        for a in alerts
            r = lowercase(string(get(a, "risk", "informational")))
            by_risk[r] = get(by_risk, r, 0) + 1
        end

        !isempty(alerts) && _pentest_diary("zap_scan",
            "ZAP: $(length(alerts)) alerts on $url — $(join(["$k=$v" for (k,v) in by_risk], ", "))",
            mood=get(by_risk, "high", 0) + get(by_risk, "critical", 0) > 0 ? "alert" : "focused",
            gait="trot")

        return Dict("url" => url, "alerts" => alerts, "count" => length(alerts),
                    "by_risk" => by_risk, "operator" => op)
    catch e
        return Dict("error" => "ZAP API error: $(e)",
                    "tip" => "Start ZAP: zaproxy -daemon -port $port -config api.disablekey=true")
    end
end

# ── tool_mitm_flows ───────────────────────────────────────────────────────────
# Read and decode a saved mitmproxy flow file using mitmdump.

function tool_mitm_flows(args::Dict)
    flow_file = string(get(args, "flow_file", ""))
    filter_ex = string(get(args, "filter",    ""))   # e.g. "~url target.com"
    limit     = Int(get(args, "limit",       50))
    timeout   = Int(get(args, "timeout_ms",  30_000))
    op        = string(get(args, "operator",  _active_operator()))

    isempty(flow_file) && return Dict("error" => "flow_file is required (path to .mitm file)")

    filter_part = isempty(filter_ex) ? "" : "'$filter_ex'"

    bash_script = """
mitmdump -r '$flow_file' -n -q $filter_part 2>&1 | head -$(limit * 30)
"""

    r = _ext_run(bash_script; timeout_ms=timeout)

    ni = _not_installed_msg("mitmdump", "pip install mitmproxy", r.output)
    ni !== nothing && return ni

    raw = r.output

    # Parse text blocks into structured entries (best-effort)
    flows = Any[]
    current = String[]
    for line in split(raw, "\n")
        if startswith(line, r"^\d{4}-\d{2}-\d{2}") || (length(current) > 20)
            !isempty(current) && push!(flows, join(current, "\n"))
            current = String[line]
        else
            push!(current, line)
        end
    end
    !isempty(current) && push!(flows, join(current, "\n"))

    flows = first(flows, limit)

    return Dict(
        "flow_file"  => flow_file,
        "filter"     => filter_ex,
        "flows"      => flows,
        "count"      => length(flows),
        "raw"        => first(raw, 5000),
        "timed_out"  => r.timed_out,
        "operator"   => op,
        "tip"        => "Use filter='~url target.com' to narrow, or '~m POST' for POST requests only.",
    )
end

export tool_ffuf, tool_nuclei, tool_httpx, tool_sqlmap, tool_zap_scan, tool_mitm_flows
