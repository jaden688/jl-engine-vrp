# Meta-reasoning sweep — rolling retrospective audit.
#
# Every _META_SWEEP_EVERY tool dispatches the engine is shown the last 15 results
# it moved through quickly and asked: "What did you assume was fine? Investigate anything
# suspicious now." The engine then decides what follow-up tool calls to make.
#
# Two entry points for the LLM:
#   meta_sweep — pull the last N results + investigation instruction (auto or manual)
#   meta_log   — explicitly record a "I noticed this but skipped it" item

const _META_BUF      = Vector{Dict{String,Any}}()
const _META_BUF_LOCK = ReentrantLock()
const _META_CTR      = Ref{Int}(0)        # total dispatches recorded
const _META_BUF_MAX  = 60                 # keep last 60 in buffer; sweep reviews 15
const _META_IN_SWEEP = Ref{Bool}(false)   # re-entrancy guard

# Trigger a sweep every this many tool dispatches.
# ~15 feels right: not so frequent it's noise, not so rare it misses things.
const _META_SWEEP_EVERY = 15

# These tools don't produce substantive findings — skip recording them
const _META_NO_RECORD = Set([
    "meta_sweep", "meta_log",
    "cascade_status", "cascade_kill",
    "burp_ping", "repl_list", "get_os_info",
])

# ── Recording (called by dispatch) ────────────────────────────────────────────

function _meta_record(tool::String, result::Any)
    (tool ∈ _META_NO_RECORD || _META_IN_SWEEP[]) && return

    compact = _meta_compact(result)
    seq = lock(_META_BUF_LOCK) do
        _META_CTR[] += 1
        entry = Dict{String,Any}(
            "seq"    => _META_CTR[],
            "tool"   => tool,
            "ts"     => string(now()),
            "result" => compact,
        )
        push!(_META_BUF, entry)
        length(_META_BUF) > _META_BUF_MAX && deleteat!(_META_BUF, 1)
        _META_CTR[]
    end
    seq
end

function _meta_compact(result::Any)
    result isa Dict || return Dict{String,Any}("raw" => string(result)[1:min(end,400)])
    d = Dict{String,Any}()
    for (k, v) in result
        if v isa String && length(v) > 700
            d[k] = v[1:700] * "…[truncated]"
        elseif v isa Vector && length(v) > 25
            d[k] = vcat(v[1:25], ["…$(length(v)-25) more"])
        else
            d[k] = v
        end
    end
    return d
end

# ── Sweep-due check (called by dispatch) ──────────────────────────────────────

function _meta_sweep_due()::Bool
    _META_IN_SWEEP[] && return false
    lock(_META_BUF_LOCK) do
        ctr = _META_CTR[]
        ctr > 0 && ctr % _META_SWEEP_EVERY == 0 && length(_META_BUF) >= 5
    end
end

# ── tool_meta_sweep ───────────────────────────────────────────────────────────

function tool_meta_sweep(args::Dict)
    _META_IN_SWEEP[] = true
    try
        n       = Int(get(args, "n", 15))
        focused = lowercase(string(get(args, "focus", "")))
        auto    = Bool(get(args, "auto", false))

        recent = lock(_META_BUF_LOCK) do
            buf = _META_BUF
            isempty(buf) && return Dict{String,Any}[]
            slice = buf[max(1, length(buf) - n + 1) : end]
            isempty(focused) ? copy(slice) :
                filter(e -> occursin(focused,
                    lowercase(e["tool"] * " " * JSON.json(e["result"]))), slice)
        end

        isempty(recent) && return Dict(
            "status"   => "ok",
            "reviewed" => 0,
            "message"  => "Buffer empty — run some tools first",
        )

        return Dict(
            "status"       => "ok",
            "auto"         => auto,
            "reviewed"     => length(recent),
            "instruction"  => """
━━━ META-REASONING SWEEP ($(auto ? "auto-triggered" : "manual")) ━━━
You moved through these $(length(recent)) results quickly. Before continuing your current task:

For EACH entry below, ask yourself:
  1. What did I implicitly assume was fine? Say it out loud.
  2. Is there any anomaly, edge case, or subtle value I skimmed past?
  3. Does anything here warrant a follow-up probe right now?

Be specific — name exact URLs, parameter names, header values, status codes,
response snippets. If something looks suspicious, call the relevant tool NOW
before moving on. Do not summarize generically. Investigate.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━""",
            "recent_calls" => recent,
        )
    finally
        _META_IN_SWEEP[] = false
    end
end

# ── tool_meta_log ─────────────────────────────────────────────────────────────
# Engine calls this when it consciously notices it's making an assumption
# ("I saw this but moved on — flag it for the next sweep")

function tool_meta_log(args::Dict)
    item       = string(get(args, "item", ""))
    assumption = string(get(args, "assumption", ""))
    context    = string(get(args, "context",    ""))

    isempty(item) && return Dict("status" => "error", "error" => "item required")

    seq = lock(_META_BUF_LOCK) do
        _META_CTR[] += 1
        entry = Dict{String,Any}(
            "seq"    => _META_CTR[],
            "tool"   => "__flagged__",
            "ts"     => string(now()),
            "result" => Dict("item" => item, "assumption" => assumption, "context" => context),
        )
        push!(_META_BUF, entry)
        length(_META_BUF) > _META_BUF_MAX && deleteat!(_META_BUF, 1)
        _META_CTR[]
    end

    return Dict(
        "status"  => "ok",
        "seq"     => seq,
        "message" => "Flagged. Will appear in next meta_sweep.",
    )
end
