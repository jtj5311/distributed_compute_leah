using Distributed
using Sockets

function env_int(name::AbstractString, default::Int)
    value = get(ENV, name, string(default))
    try
        return parse(Int, value)
    catch
        error("Environment variable $name must be an integer, got '$value'")
    end
end

function require_env(name::AbstractString)
    value = get(ENV, name, "")
    isempty(value) && error("Missing required environment variable $name")
    return value
end

function project_flag()
    return "--project=$(pwd())"
end

function remote_spec()
    host = require_env("JULIA_REMOTE_HOST")
    user = get(ENV, "JULIA_REMOTE_USER", "")
    return isempty(user) ? host : "$user@$host"
end

function launch_workers()
    remote = remote_spec()
    remote_workers = env_int("JULIA_REMOTE_WORKERS", 2)
    local_workers = env_int("JULIA_LOCAL_WORKERS", 0)
    remote_exename = get(ENV, "JULIA_REMOTE_EXENAME", "julia")

    if local_workers > 0
        addprocs(local_workers; topology = :master_worker)
    end

    return addprocs(
        [(remote, remote_workers)];
        exename = remote_exename,
        exeflags = project_flag(),
        topology = :master_worker,
        tunnel = true,
    )
end

function main()
    println("Master pid: ", myid())
    println("Master host: ", gethostname())

    new_workers = launch_workers()
    println("Launched workers: ", new_workers)

    @everywhere begin
        using Sockets

        function worker_report(x)
            return (
                input = x,
                pid = myid(),
                host = gethostname(),
                thread_count = Threads.nthreads(),
                result = x^2,
            )
        end
    end

    reports = pmap(worker_report, 1:8)

    println()
    println("Worker inventory:")
    for pid in workers()
        info = remotecall_fetch(() -> (myid(), gethostname()), pid)
        println("  pid=$(info[1]) host=$(info[2])")
    end

    println()
    println("pmap results:")
    for report in reports
        println(report)
    end
end

main()
