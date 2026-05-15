# Persistent REPL sessions — stdin-pipe loop per language.
# State (variables, imports, definitions) survives across repl_exec calls within a session.

const _REPL_SENTINEL = "__JL_REPL_DONE_7f3a9b__"
const _REPL_EXEC_END = "__REPL_EXEC_END__"
const _REPL_SESSIONS = Dict{String,Dict{String,Any}}()
const _REPL_LOCK     = ReentrantLock()

# ── Bootstrap scripts ──────────────────────────────────────────────────────────
# Each language gets a script that:
#   1. Reads lines from stdin until _REPL_EXEC_END
#   2. Executes the accumulated block
#   3. Prints _REPL_SENTINEL to mark end of output
#   4. Loops forever
# Tuple: (executable, file_extension, script_content)

const _REPL_BOOTS = Dict{String,Tuple{String,String,String}}()

_REPL_BOOTS["python"] = ("python3", "py", """
import sys, traceback
sys.stderr = sys.stdout
_SENTINEL = "__JL_REPL_DONE_7f3a9b__"
_EXEC_END  = "__REPL_EXEC_END__"
while True:
    lines = []
    while True:
        line = sys.stdin.readline()
        if not line:
            sys.exit(0)
        line = line.rstrip('\\n')
        if line == _EXEC_END:
            break
        lines.append(line)
    code = "\\n".join(lines)
    try:
        exec(compile(code, "<repl>", "exec"), globals())
    except Exception:
        traceback.print_exc()
    print(_SENTINEL, flush=True)
""")

_REPL_BOOTS["julia"] = ("julia", "jl", """
redirect_stderr(stdout)
const SENTINEL = "__JL_REPL_DONE_7f3a9b__"
const EXEC_END  = "__REPL_EXEC_END__"
while true
    lines = String[]
    while true
        eof(stdin) && exit(0)
        line = readline(stdin)
        line == EXEC_END && break
        push!(lines, line)
    end
    code = join(lines, "\\n")
    try
        include_string(Main, code, "<repl>")
    catch e
        showerror(stdout, e, catch_backtrace())
        println()
    end
    println(SENTINEL)
    flush(stdout)
end
""")

_REPL_BOOTS["node"] = ("node", "js", """
const readline = require('readline');
const vm = require('vm');
const SENTINEL = '__JL_REPL_DONE_7f3a9b__';
const EXEC_END  = '__REPL_EXEC_END__';
const ctx = Object.assign(vm.createContext(), {
    require, console, process, Buffer,
    setTimeout, clearTimeout, setInterval, clearInterval,
});
console.error = (...a) => console.log(...a);
const rl = readline.createInterface({ input: process.stdin, terminal: false });
let lines = [];
rl.on('line', line => {
    if (line === EXEC_END) {
        const code = lines.join('\\n'); lines = [];
        try { vm.runInContext(code, ctx); }
        catch(e) { console.log(e.stack || e.message || String(e)); }
        console.log(SENTINEL);
    } else {
        lines.push(line);
    }
});
rl.on('close', () => process.exit(0));
""")

_REPL_BOOTS["ruby"] = ("ruby", "rb", """
\$stderr = \$stdout
SENTINEL = "__JL_REPL_DONE_7f3a9b__"
EXEC_END  = "__REPL_EXEC_END__"
b = binding
lines = []
\$stdin.each_line do |line|
  line.chomp!
  if line == EXEC_END
    begin; b.eval(lines.join("\\n")); rescue => e; puts e; end
    lines = []
    puts SENTINEL; \$stdout.flush
  else
    lines << line
  end
end
""")

_REPL_BOOTS["lua"] = ("lua", "lua", """
local SENTINEL = "__JL_REPL_DONE_7f3a9b__"
local EXEC_END  = "__REPL_EXEC_END__"
local lines = {}
for line in io.lines() do
    if line == EXEC_END then
        local code = table.concat(lines, "\\n")
        lines = {}
        local f, err = load(code, "<repl>", "t", _ENV)
        if f then
            local ok, e2 = pcall(f)
            if not ok then print(e2) end
        else
            print(err)
        end
        print(SENTINEL); io.flush()
    else
        table.insert(lines, line)
    end
end
""")

_REPL_BOOTS["r"] = ("Rscript", "R", """
SENTINEL <- "__JL_REPL_DONE_7f3a9b__"
EXEC_END  <- "__REPL_EXEC_END__"
lines <- character(0)
con <- stdin()
repeat {
    line <- readLines(con, n=1, warn=FALSE)
    if (length(line) == 0) break
    if (line == EXEC_END) {
        tryCatch(
            eval(parse(text=paste(lines, collapse="\\n"))),
            error=function(e) cat(conditionMessage(e), "\\n")
        )
        lines <- character(0)
        cat(SENTINEL, "\\n"); flush(stdout())
    } else {
        lines <- c(lines, line)
    }
}
""")

_REPL_BOOTS["bash"] = ("bash", "sh", raw"""
SENTINEL="__JL_REPL_DONE_7f3a9b__"
EXEC_END="__REPL_EXEC_END__"
lines=()
while IFS= read -r line; do
    if [[ "$line" == "$EXEC_END" ]]; then
        code=$(printf '%s\n' "${lines[@]}")
        lines=()
        eval "$code" 2>&1 || true
        echo "$SENTINEL"
    else
        lines+=("$line")
    fi
done
""")

# ── Language normalization ─────────────────────────────────────────────────────

function _repl_norm(lang::String) :: String
    l = lowercase(strip(lang))
    l ∈ ("python3","py")            && return "python"
    l ∈ ("javascript","js")         && return "node"
    l ∈ ("rb")                      && return "ruby"
    l ∈ ("jl")                      && return "julia"
    l ∈ ("sh","shell","zsh","fish") && return "bash"
    return l
end

# ── Process lifecycle ──────────────────────────────────────────────────────────

function _repl_spawn(lang::String, session_id::String) :: Dict{String,Any}
    nl = _repl_norm(lang)
    haskey(_REPL_BOOTS, nl) || error("No REPL for '$lang'. Supported: python, julia, node, ruby, lua, r, bash")
    (exe, ext, script) = _REPL_BOOTS[nl]

    tmpfile = joinpath(tempdir(), "jl_repl_$(session_id).$(ext)")
    write(tmpfile, script)

    inp = Pipe()
    out = Pipe()
    proc = run(pipeline(`$exe $tmpfile`; stdin=inp, stdout=out, stderr=out), wait=false)
    close(inp.out)
    close(out.in)

    return Dict{String,Any}(
        "lang"       => nl,
        "session_id" => session_id,
        "proc"       => proc,
        "stdin"      => inp.in,
        "stdout"     => out.out,
        "tmpfile"    => tmpfile,
        "created_at" => now(),
        "exec_count" => 0,
    )
end

function _repl_send_recv(session::Dict{String,Any}, code::String; timeout_s::Int=30) :: String
    sin  = session["stdin"]  :: IO
    sout = session["stdout"] :: IO

    for line in split(code, '\n')
        println(sin, line)
    end
    println(sin, _REPL_EXEC_END)
    flush(sin)

    result_ch = Channel{String}(1)
    @async begin
        lines = String[]
        try
            while !eof(sout)
                line = readline(sout)
                line == _REPL_SENTINEL && break
                push!(lines, line)
            end
        catch e
            @warn "REPL stream read failed" session_id=get(session, "session_id", "unknown") exception=(e, catch_backtrace())
        end
        put!(result_ch, join(lines, '\n'))
    end

    t_start = time()
    while !isready(result_ch)
        time() - t_start > timeout_s && return "[timeout after $(timeout_s)s — session may need repl_close]"
        sleep(0.05)
    end
    return take!(result_ch)
end

# ── Tools ──────────────────────────────────────────────────────────────────────

function tool_repl_open(args::Dict)
    lang       = string(get(args, "lang", "python"))
    session_id = string(get(args, "session_id", "sess_" * string(rand(UInt32), base=16)))

    lock(_REPL_LOCK) do
        if haskey(_REPL_SESSIONS, session_id)
            s = _REPL_SESSIONS[session_id]
            return Dict("status"=>"existing","session_id"=>session_id,"lang"=>s["lang"],"exec_count"=>s["exec_count"])
        end
        try
            s = _repl_spawn(lang, session_id)
            sleep(0.4)
            _REPL_SESSIONS[session_id] = s
            return Dict("status"=>"created","session_id"=>session_id,"lang"=>s["lang"])
        catch e
            return Dict("status"=>"error","error"=>string(e))
        end
    end
end

function tool_repl_exec(args::Dict)
    session_id = string(get(args, "session_id", ""))
    code       = string(get(args, "code", ""))
    timeout_s  = Int(get(args, "timeout_s", 30))
    auto_open  = Bool(get(args, "auto_open", true))
    lang       = string(get(args, "lang", "python"))

    isempty(session_id) && return Dict("status"=>"error","error"=>"session_id required")
    isempty(code)       && return Dict("status"=>"error","error"=>"code required")

    session = lock(_REPL_LOCK) do
        if !haskey(_REPL_SESSIONS, session_id) && auto_open
            try
                s = _repl_spawn(lang, session_id)
                sleep(0.4)
                _REPL_SESSIONS[session_id] = s
                s
            catch e
                return Dict("status"=>"error","error"=>"auto_open failed: $(e)")
            end
        else
            get(_REPL_SESSIONS, session_id, nothing)
        end
    end

    session isa Dict || return session  # propagate error dict from auto_open
    session === nothing && return Dict("status"=>"error","error"=>"No session '$session_id' — call repl_open first")

    try
        output = _repl_send_recv(session, code; timeout_s)
        lock(_REPL_LOCK) do; session["exec_count"] += 1; end
        return Dict("status"=>"ok","session_id"=>session_id,"output"=>output,"exec_count"=>session["exec_count"])
    catch e
        return Dict("status"=>"error","session_id"=>session_id,"error"=>string(e))
    end
end

function tool_repl_close(args::Dict)
    session_id = string(get(args, "session_id", ""))
    isempty(session_id) && return Dict("status"=>"error","error"=>"session_id required")

    session = lock(_REPL_LOCK) do
        pop!(_REPL_SESSIONS, session_id, nothing)
    end
    session === nothing && return Dict("status"=>"not_found","session_id"=>session_id)

    try
        close(session["stdin"])
    catch e
        @warn "REPL close stdin failed" session_id=session_id exception=(e, catch_backtrace())
    end
    try
        close(session["stdout"])
    catch e
        @warn "REPL close stdout failed" session_id=session_id exception=(e, catch_backtrace())
    end
    try
        kill(session["proc"])
    catch e
        @warn "REPL process kill failed" session_id=session_id exception=(e, catch_backtrace())
    end
    try
        isfile(session["tmpfile"]) && rm(session["tmpfile"]; force=true)
    catch e
        @warn "REPL temp file cleanup failed" session_id=session_id path=string(get(session, "tmpfile", "")) exception=(e, catch_backtrace())
    end

    return Dict("status"=>"closed","session_id"=>session_id,"exec_count"=>session["exec_count"])
end

function tool_repl_list(args::Dict)
    sessions = lock(_REPL_LOCK) do
        [Dict(
            "session_id"  => k,
            "lang"        => v["lang"],
            "exec_count"  => v["exec_count"],
            "created_at"  => string(v["created_at"]),
        ) for (k, v) in _REPL_SESSIONS]
    end
    return Dict("status"=>"ok","sessions"=>sessions,"count"=>length(sessions))
end
