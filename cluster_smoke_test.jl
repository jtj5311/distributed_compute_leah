using Distributed
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

const WORKER_CODE = quote
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

function remote_dir()
    return get(ENV, "JULIA_REMOTE_DIR", pwd())
end

function worker_exeflags(project_dir::AbstractString)
    threads = get(ENV, "JULIA_WORKER_THREADS", "1")
    return "--threads=$threads --project=$project_dir"
end

function remote_spec()
    host = require_env("JULIA_REMOTE_HOST")
    user = get(ENV, "JULIA_REMOTE_USER", "")
    return isempty(user) ? host : "$user@$host"
end

function launch_workers()
    remote_workers = env_int("JULIA_REMOTE_WORKERS", 2)
    local_workers = env_int("JULIA_LOCAL_WORKERS", 1)
    remote_exename = get(ENV, "JULIA_REMOTE_EXENAME", "julia")
    launched = Int[]

    if local_workers > 0
        append!(
            launched,
            addprocs(
                local_workers;
                exeflags = worker_exeflags(pwd()),
                topology = :master_worker,
            ),
        )
    end

    if remote_workers > 0
        remote = remote_spec()
        append!(
            launched,
            addprocs(
                [(remote, remote_workers)];
                dir = remote_dir(),
                exename = remote_exename,
                exeflags = worker_exeflags(remote_dir()),
                topology = :master_worker,
                tunnel = true,
            ),
        )
    end

    return launched
end

function define_worker_code()
    for pid in workers()
        remotecall_eval(Main, pid, WORKER_CODE)
    end
end

function main()
    println("Master pid: ", myid())
    println("Master host: ", gethostname())

    new_workers = launch_workers()
    println("Launched workers: ", new_workers)
    println("All workers: ", workers())

    define_worker_code()

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
