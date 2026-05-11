ENV["JULIA_CONDAPKG_BACKEND"] = "Null"
ENV["JULIA_PYTHONCALL_EXE"] = "python"

import Pkg

function _env_true(name::AbstractString; default::Bool=false)
    value = lowercase(strip(get(ENV, name, default ? "1" : "0")))
    return !(value in ("", "0", "false", "no", "off"))
end

function _active_project_path()
    active = try
        Base.active_project()
    catch
        nothing
    end
    active === nothing && return ""
    return abspath(String(active))
end

function _ensure_project_setup!()
    project_toml = abspath(joinpath(@__DIR__, "Project.toml"))
    manifest_toml = abspath(joinpath(@__DIR__, "Manifest.toml"))
    if _active_project_path() != project_toml && !_env_true("SPARKBYTE_SKIP_PKG_SETUP")
        Pkg.activate(@__DIR__)
        if isfile(manifest_toml) && !_env_true("SPARKBYTE_FORCE_PKG_INSTANTIATE")
            println("📦 Using checked-in Manifest.toml; skipping automatic Pkg.instantiate().")
        elseif !_env_true("SPARKBYTE_SKIP_PKG_INSTANTIATE")
            Pkg.instantiate()
        end
    end
end

_ensure_project_setup!()

include(joinpath(@__DIR__, "health_check.jl"))
run_health_check()

using JLEngine

# ── Crash-resilient boot ──────────────────────────────────────────────────────
# If app_main() throws (port conflict, OOM, HTTP.serve crash, etc.) we log the
# error to logs/sparkbyte_crash.log and restart automatically rather than just
# exiting silently.  Each restart waits a bit longer (exponential back-off,
# capped at 60s).  Set SPARKBYTE_NO_RESTART=1 to disable restart behaviour.
const _CRASH_LOG_PATH = joinpath(@__DIR__, "logs", "sparkbyte_crash.log")

function _log_crash_to_file(err, bt)
    try
        mkpath(dirname(_CRASH_LOG_PATH))
        open(_CRASH_LOG_PATH, "a") do io
            println(io, "\n=== CRASH @ $(Dates.now()) ===")
            Base.showerror(io, err)
            println(io)
            Base.show_backtrace(io, bt)
            println(io)
            flush(io)
        end
    catch log_err
        println(stderr, "⚠ Could not write crash log: $log_err")
    end
    Base.display_error(stderr, err, bt)
end

function _emergency_cleanup!()
    try
        # Force kill any lingering Julia processes using our port
        run(`cmd /c "netstat -ano | findstr :8081 | findstr LISTENING | for /f \"tokens=5\" %a in ('more') do taskkill /PID %a /F"`, wait=false)
        println(stderr, "🧹 Attempted to kill lingering processes on port 8081")
    catch
        # Ignore cleanup errors
    end
    
    try
        # Close any locked SQLite databases by removing lock files
        db_path = joinpath(@__DIR__, "state", "sparkbyte_memory.db")
        if isfile(db_path * "-shm") || isfile(db_path * "-wal")
            rm(db_path * "-shm", force=true)
            rm(db_path * "-wal", force=true)
            println(stderr, "🧹 Cleared SQLite lock files")
        end
    catch
        # Ignore cleanup errors
    end
end

const _NO_RESTART = _env_true("SPARKBYTE_NO_RESTART")
const _MAX_RESTARTS = 20

import Dates

let delay = 5
    for attempt in 0:_MAX_RESTARTS
        if attempt > 0
            println(stderr, "\n💥 SparkByte crashed — cleaning up...")
            _emergency_cleanup!()

            # Ask user if they want to restart
            print(stderr, "\n🔄 Restart SparkByte? (y/N): ")
            flush(stderr)
            response = try
                lowercase(strip(readline()))
            catch
                "n"  # Default to no on EOF/error
            end

            if response in ("y", "yes")
                println(stderr, "Restarting in $(delay)s (attempt $attempt/$_MAX_RESTARTS)...")
                sleep(delay)
                delay = min(delay * 2, 60)
            else
                println(stderr, "❌ User chose not to restart. Exiting.")
                exit(1)
            end
        end
        try
            JLEngine.app_main()
            break  # clean return (shouldn't happen normally — serve() blocks forever)
        catch err
            bt = catch_backtrace()
            _log_crash_to_file(err, bt)
            _NO_RESTART && rethrow(err)
            attempt == _MAX_RESTARTS && (println(stderr, "❌ Max restarts reached — giving up."); rethrow(err))
        end
    end
end
