This is a repo for Leah and I to test out distributed compute across our laptops.

## Goal

Start a Julia session on one laptop, use that same laptop as a worker too, launch
additional Julia workers on the other laptop over Tailscale, and run a small
distributed job to prove the setup works.

## Recommended First Setup

Use:

- Tailscale for private connectivity between laptops
- SSH over the Tailscale network for worker launch
- Julia's built-in `Distributed` stdlib
- `topology = :master_worker` for the first pass
- `tunnel = true` so the control path stays on SSH

That avoids the more annoying all-to-all worker networking issues while you are
just getting started.

## Prerequisites On Both Machines

1. Install the same Julia version on both machines.
2. Make sure both machines are online in Tailscale.
3. Make sure you can SSH from the master machine to the remote machine over
   Tailscale.
4. Make sure the remote machine can run `julia` from the shell, or note the full
   path to the Julia binary.

## Tailscale / SSH Checks

If MagicDNS is enabled, prefer the MagicDNS hostname instead of the raw
`100.x.y.z` address. From your master machine:

```bash
ssh your-linux-user@pop-os.tail50cba4.ts.net hostname
```

If that works, Julia can usually launch workers there.

If you want to use Tailscale SSH instead of normal SSH, that also works, but get
plain SSH connectivity working first because it is easier to debug.

## Install Julia

Do this on both machines.

```bash
curl -fsSL https://install.julialang.org | sh
```

Then verify:

```bash
julia --version
```

The versions should match on both machines.

## Step 1: Local-Only Smoke Test

Before involving the second laptop, verify that this laptop can start Julia
worker processes:

```bash
JULIA_LOCAL_WORKERS=2 \
JULIA_REMOTE_WORKERS=0 \
julia cluster_smoke_test.jl
```

You should see one master process plus two worker entries with this laptop's
hostname.

## Step 2: Remote Smoke Test

From this repo on the master machine:

```bash
JULIA_REMOTE_HOST=pop-os.tail50cba4.ts.net \
JULIA_REMOTE_USER=your-linux-user \
JULIA_REMOTE_DIR=/path/to/this/repo/on/remote/laptop \
JULIA_LOCAL_WORKERS=1 \
JULIA_REMOTE_WORKERS=2 \
julia cluster_smoke_test.jl
```

If the remote machine does not have `julia` on `PATH`, also set:

```bash
JULIA_REMOTE_EXENAME=/full/path/to/julia
```

`JULIA_REMOTE_DIR` should be the path to this repo on the remote laptop. If both
laptops use the same absolute path, you can omit it.

## What The Smoke Test Does

- launches local workers with `addprocs`
- launches remote workers with `addprocs` when `JULIA_REMOTE_WORKERS` is above 0
- prints worker ids and hostnames
- runs a small `pmap` workload across the workers
- confirms that execution is happening on both local and remote workers

## Common Failure Modes

### `ssh: connect` errors

- verify the remote machine is online in Tailscale
- verify the Linux username is correct
- verify `ssh your-linux-user@pop-os.tail50cba4.ts.net` works outside Julia

### `tailnet policy does not permit you to SSH to this node`

This means Tailscale connectivity is working, but Tailscale SSH is enabled on the
remote node and the tailnet ACL does not allow your user to SSH there.

You have two practical options:

- allow this SSH connection in the Tailscale admin console's Access Controls
- disable Tailscale SSH on the remote node and use regular Linux `sshd` over the
  Tailscale address instead

For this project, either option is fine. The important check is still:

```bash
ssh your-linux-user@pop-os.tail50cba4.ts.net hostname
```

Julia's remote worker launch should only be tested after that command succeeds.

### Julia launches but workers do not connect back

This is usually networking or environment mismatch. For the initial setup this
repo uses:

- `tunnel = true`
- `topology = :master_worker`

That keeps the setup simpler than the default all-to-all topology.

### Version mismatch

Julia distributed execution relies on serialization compatibility. Keep the Julia
version the same on all nodes.

### Package / environment mismatch

Workers do not automatically inherit your session state. The script launches them
with `--project=<repo>` so they use the same project environment as the master.

If you see `cd: can't cd to ...`, set `JULIA_REMOTE_DIR` to the repo path on the
remote laptop, or clone this repo to the same absolute path on both laptops.

## Next Step After Smoke Test

Once the smoke test passes, the next practical step is usually to move your real
work into a function and switch from a serial `map` or loop to `pmap`, or to use
`@spawnat` for more manual control.

## Mixed Local + Remote Pattern

This is the model you asked for: one Julia session on this laptop acts as:

- the driver process
- optionally one or more local workers
- the launcher for workers on the second laptop

In practice that usually looks like:

```julia
using Distributed

addprocs(1; topology = :master_worker)
addprocs(
    [("your-user@pop-os.tail50cba4.ts.net", 2)];
    topology = :master_worker,
    tunnel = true,
)
```

Then `pmap`, `@distributed`, or `remotecall_fetch` can use all workers in one
pool.

## References

- Julia distributed computing manual:
  https://docs.julialang.org/en/v1/manual/distributed-computing/
- Julia `Distributed` stdlib reference:
  https://docs.julialang.org/en/v1/stdlib/Distributed/
- Tailscale MagicDNS:
  https://tailscale.com/docs/features/magicdns
- Tailscale SSH:
  https://tailscale.com/docs/features/tailscale-ssh
