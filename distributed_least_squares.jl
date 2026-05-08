using Distributed
using LinearAlgebra
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

const LEAST_SQUARES_CODE = quote
    using LinearAlgebra
    using Sockets

    function hash_unit(row, col)
        value = UInt64(row) * 0x9e3779b97f4a7c15 + UInt64(col) * 0xbf58476d1ce4e5b9
        value = (value ⊻ (value >> 30)) * 0xbf58476d1ce4e5b9
        value = (value ⊻ (value >> 27)) * 0x94d049bb133111eb
        value = value ⊻ (value >> 31)
        return Float64(value >> 11) * (1.0 / 9007199254740992.0)
    end

    function feature_value(row, col)
        return 2.0 * hash_unit(row, col) - 1.0
    end

    function true_beta(col)
        return sin(0.17 * col) + 0.5 * cos(0.11 * col)
    end

    function shard_normal_equations(task, task_count, rows_per_task, feature_count, repeats)
        gram = zeros(Float64, feature_count, feature_count)
        rhs = zeros(Float64, feature_count)
        x = zeros(Float64, feature_count)
        beta = [true_beta(col) for col in 1:feature_count]
        first_row = (task - 1) * rows_per_task + 1
        last_row = task * rows_per_task

        for _ in 1:repeats
            fill!(gram, 0.0)
            fill!(rhs, 0.0)

            for row in first_row:last_row
                y = 0.0
                for col in 1:feature_count
                    value = feature_value(row, col)
                    x[col] = value
                    y += value * beta[col]
                end
                y += 0.01 * sin(0.013 * row)

                for i in 1:feature_count
                    xi = x[i]
                    rhs[i] += xi * y
                    for j in i:feature_count
                        gram[i, j] += xi * x[j]
                    end
                end
            end
        end

        for i in 1:feature_count
            for j in 1:(i - 1)
                gram[i, j] = gram[j, i]
            end
        end

        return (
            task = task,
            pid = myid(),
            host = gethostname(),
            rows = rows_per_task,
            gram = gram,
            rhs = rhs,
        )
    end
end

eval(LEAST_SQUARES_CODE)

function define_worker_code()
    for pid in workers()
        remotecall_eval(Main, pid, LEAST_SQUARES_CODE)
    end
end

function summarize(results)
    counts = Dict{Tuple{Int, String}, Int}()
    rows = Dict{Tuple{Int, String}, Int}()

    for result in results
        key = (result.pid, result.host)
        counts[key] = get(counts, key, 0) + 1
        rows[key] = get(rows, key, 0) + result.rows
    end

    println("Worker contributions:")
    for ((pid, host), count) in sort(collect(counts))
        println("  pid=$pid host=$host tasks=$count rows=$(rows[(pid, host)])")
    end
end

function solve_from_results(results, feature_count)
    gram = zeros(Float64, feature_count, feature_count)
    rhs = zeros(Float64, feature_count)

    for result in results
        gram .+= result.gram
        rhs .+= result.rhs
    end

    return gram \ rhs
end

function beta_error(beta_hat)
    beta = [true_beta(col) for col in eachindex(beta_hat)]
    return norm(beta_hat - beta) / norm(beta)
end

function main()
    feature_count = env_int("LS_FEATURES", 48)
    tasks = env_int("LS_TASKS", max(8, 8 * max(1, nworkers())))
    rows_per_task = env_int("LS_ROWS_PER_TASK", 25_000)
    repeats = env_int("LS_REPEATS", 1)
    run_serial = env_int("LS_SERIAL", 1) != 0

    println("Master pid: ", myid())
    println("Master host: ", gethostname())
    println(
        "Least squares: features=$feature_count tasks=$tasks rows_per_task=$rows_per_task repeats=$repeats",
    )

    launched = launch_workers()
    println("Launched workers: ", launched)
    println("All workers: ", workers())
    define_worker_code()

    inputs = collect(1:tasks)
    warmup_inputs = collect(1:min(tasks, max(1, nworkers())))
    pmap(task -> shard_normal_equations(task, tasks, 1_000, min(feature_count, 8), 1), warmup_inputs)

    serial_time = NaN
    serial_beta = nothing
    if run_serial
        serial_results = nothing
        serial_time = @elapsed begin
            serial_results = map(
                task -> shard_normal_equations(task, tasks, rows_per_task, feature_count, repeats),
                inputs,
            )
        end
        serial_beta = solve_from_results(serial_results, feature_count)
    end

    distributed_results = nothing
    distributed_time = @elapsed begin
        distributed_results = pmap(
            task -> shard_normal_equations(task, tasks, rows_per_task, feature_count, repeats),
            inputs,
        )
    end
    distributed_beta = solve_from_results(distributed_results, feature_count)

    println()
    summarize(distributed_results)

    println()
    if run_serial
        @printf("Serial time:      %.3f seconds\n", serial_time)
    else
        println("Serial time:      skipped")
    end
    @printf("Distributed time: %.3f seconds\n", distributed_time)
    if run_serial
        @printf("Speedup:          %.2fx\n", serial_time / distributed_time)
        @printf("Beta agreement:   %.3e\n", norm(serial_beta - distributed_beta))
    end
    @printf("Relative error:   %.3e\n", beta_error(distributed_beta))
    @printf("Rows processed:   %d\n", tasks * rows_per_task * repeats)
end

main()
