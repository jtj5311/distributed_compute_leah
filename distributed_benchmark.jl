using Distributed
using Printf
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
        append!(
            launched,
            addprocs(
                [(remote_spec(), remote_workers)];
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

const BENCHMARK_CODE = quote
    using Sockets

    function mandelbrot_tile(tile_index, tile_count, width, height, max_iter)
        total = 0
        escaped = 0

        for pixel_index in tile_index:tile_count:(width * height)
            x = (pixel_index - 1) % width
            y = (pixel_index - 1) ÷ width
            cr = -2.0 + 3.0 * x / (width - 1)
            ci = -1.2 + 2.4 * y / (height - 1)
            zr = 0.0
            zi = 0.0
            iter = 0

            while iter < max_iter && zr * zr + zi * zi <= 4.0
                zr, zi = zr * zr - zi * zi + cr, 2.0 * zr * zi + ci
                iter += 1
            end

            total += iter
            escaped += iter < max_iter
        end

        return (
            tile = tile_index,
            pid = myid(),
            host = gethostname(),
            thread_count = Threads.nthreads(),
            total = total,
            escaped = escaped,
        )
    end
end

eval(BENCHMARK_CODE)

function define_worker_code()
    for pid in workers()
        remotecall_eval(Main, pid, BENCHMARK_CODE)
    end
end

function summarize(results)
    totals_by_worker = Dict{Tuple{Int, String}, Int}()
    for result in results
        key = (result.pid, result.host)
        totals_by_worker[key] = get(totals_by_worker, key, 0) + 1
    end

    println("Worker task counts:")
    for ((pid, host), count) in sort(collect(totals_by_worker))
        println("  pid=$pid host=$host tasks=$count")
    end
end

function main()
    width = env_int("BENCH_WIDTH", 1800)
    height = env_int("BENCH_HEIGHT", 1200)
    max_iter = env_int("BENCH_MAX_ITER", 700)
    tasks = env_int("BENCH_TASKS", max(8, 8 * max(1, nworkers())))

    println("Master pid: ", myid())
    println("Master host: ", gethostname())
    println("Benchmark: width=$width height=$height max_iter=$max_iter tasks=$tasks")

    launched = launch_workers()
    println("Launched workers: ", launched)
    println("All workers: ", workers())
    define_worker_code()

    inputs = collect(1:tasks)
    warmup_inputs = collect(1:min(tasks, max(1, nworkers())))
    map(tile -> mandelbrot_tile(tile, tasks, 240, 160, 80), warmup_inputs)
    pmap(tile -> mandelbrot_tile(tile, tasks, 240, 160, 80), warmup_inputs)

    serial_results = nothing
    serial_time = @elapsed begin
        serial_results = map(tile -> mandelbrot_tile(tile, tasks, width, height, max_iter), inputs)
    end

    distributed_results = nothing
    distributed_time = @elapsed begin
        distributed_results = pmap(
            tile -> mandelbrot_tile(tile, tasks, width, height, max_iter),
            inputs,
        )
    end

    serial_total = sum(result.total for result in serial_results)
    distributed_total = sum(result.total for result in distributed_results)
    serial_escaped = sum(result.escaped for result in serial_results)
    distributed_escaped = sum(result.escaped for result in distributed_results)

    println()
    summarize(distributed_results)

    println()
    @printf("Serial time:      %.3f seconds\n", serial_time)
    @printf("Distributed time: %.3f seconds\n", distributed_time)
    @printf("Speedup:          %.2fx\n", serial_time / distributed_time)
    println("Checksum match:   ", serial_total == distributed_total)
    println("Escaped match:    ", serial_escaped == distributed_escaped)
    println("Checksum:         ", distributed_total)
end

main()
