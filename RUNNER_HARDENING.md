# Runner Hardening

## Goal

This runner is deployed as a shared CI service where untrusted external contributors
can submit pull requests from forks.  The goal was to ensure that a malicious workflow
author — someone who can open a PR but is not a trusted team member — cannot:

- escape the job container and access the host filesystem or processes,
- steal secrets or credentials from other jobs running on the same runner,
- poison build artefacts or cached tools that affect subsequent jobs,
- alter the container runtime or security profile configured by the operator.

The runner uses [sysbox](https://github.com/nestybox/sysbox) as the container runtime,
which provides strong OS-level isolation (per-container kernel namespaces, user-namespace
remapping, inner Docker daemon).  The hardening changes described here are the
software-layer controls that sit above sysbox and complement it.

---

## Changes

### 1. Replace `docker cp` with `docker exec + tar` (sysbox compatibility)

**Files:** `act/container/docker_run.go`, `act/container/docker_run_test.go`

**What changed:**
The runner previously used Docker's `CopyToContainer` API (`docker cp`) to write files
into job containers, and `CopyFromContainer` to read them back.  Both API calls access
the container's overlay filesystem directly from outside the container, bypassing the
container runtime.  Sysbox's per-container mount namespace makes these calls fail.

All three write paths (`copyContent`, `copyDir`, `CopyTarStream`) were replaced with
`execWriteTar`: a tar archive is streamed to `stdin` of `tar -x` running inside the
container via `docker exec`.  The matching read path (`GetContainerArchive`) was replaced
with `execReadTar`: `tar -c` runs inside the container and its `stdout` is streamed out.

**Protects against:**
- Broken CI on sysbox (primary motivation).
- As a side-effect, file I/O now goes through the container's own process namespace
  rather than bypassing the runtime, which is the correct isolation boundary.

---

### 2. `actions/cache` already scoped per-repository

**Files:** `act/artifactcache/handler.go` (no change needed — documenting for clarity)

**What changed:** Nothing — this was confirmed correct during the audit.

Every job's `ACTIONS_RUNTIME_TOKEN` is registered with its repository string.  Cache
entries are stamped with `Repo` on write and filtered by `Repo` on every read.  An
explicit `403` is returned if the requesting token's repo does not match the stored
entry's repo.

**Protects against:**
- A fork PR reading or overwriting the upstream repository's `actions/cache` entries.
- Cache poisoning across repositories on the same runner.

---

### 3. Per-repository `act-toolcache` volume

**Files:** `act/runner/run_context.go`

**What changed:**
The Docker named volume used as `RUNNER_TOOL_CACHE` (`/opt/hostedtoolcache`) was
previously a single global volume `act-toolcache` shared by every job on the runner.
A new helper `toolcacheVolume()` now derives the volume name from the repository:
`act-toolcache-{owner}-{repo}` (e.g. `act-toolcache-sasol-repo-test`).  When no
repository context is available (local runs, tests) the legacy name is used as a
fallback.

**Protects against:**
- A fork PR replacing a cached binary (e.g. `node`, `python`, `pip`) inside
  `/opt/hostedtoolcache` with a trojan that exfiltrates secrets from every subsequent
  job that uses `actions/setup-node`, `actions/setup-python`, etc.
- Each repository's tool cache is now isolated; a fork cannot read or write the
  upstream repository's cache.

---

### 4. Per-repository Docker image cache volume

**Files:** `act/runner/run_context.go`, `act/runner/runner.go`,
`internal/app/run/runner.go`, `internal/pkg/config/config.go`

**What changed:**
An opt-in feature (`docker_image_cache: true` in `config.yml`) that mounts a
persistent named Docker volume at `/var/lib/docker` inside sysbox job containers.
Sysbox uses this as the inner Docker daemon's image store, so images pulled in one
run are present in the next without re-downloading.

The volume is scoped per-repository (`docker-images-{owner}-{repo}`) via the new
`dockerImagesVolume()` helper, following the same pattern as `toolcacheVolume()`.

> **Note:** requires `capacity: 1`.  At higher concurrency, two jobs from the same
> repository would share the inner Docker daemon's image store concurrently, which
> is unsafe.

**Protects against:**
- A fork PR poisoning Docker images cached inside the sysbox inner daemon for the
  upstream repository's subsequent jobs.

---

### 5. Workflow `container.options` restricted to an explicit allowlist

**Files:** `act/runner/run_context.go`, `act/container/docker_run.go`

**What changed:**
Workflow authors can set `container.options:` in their workflow YAML to pass extra
flags to the job container.  Previously all flags were forwarded to Docker after
parsing; now the per-workflow options are filtered through `allowedContainerOptions()`
before being concatenated with the operator's global options from `config.yml`.

Only the following flags are permitted from per-workflow options:

| Flag | Purpose |
|---|---|
| `--hostname` | Set container hostname |
| `--user` / `-u` | Run as a specific UID:GID |
| `--add-host` | Add entries to `/etc/hosts` |
| `--env` / `-e` | Set extra environment variables |

All other flags — including `--runtime`, `--pid`, `--ipc`, `--uts`, `--userns`,
`--privileged`, `--cap-add`, `--security-opt`, `--volume`, `--net` — are silently
discarded.

Additionally, `mergeContainerConfigs` in `docker_run.go` unconditionally resets
`PidMode`, `IpcMode`, `UTSMode`, and `UsernsMode` to safe defaults after merging,
as a second line of defence.

The operator's global `container.options` in `config.yml` (e.g.
`--runtime=sysbox-runc --user 0`) is never filtered and always takes effect.

**Protects against:**
- `--runtime=runc`: bypassing the sysbox runtime entirely, removing all kernel-level
  isolation.
- `--pid=host`: sharing the host PID namespace, allowing the container to observe and
  signal all host processes including the runner daemon.
- `--ipc=host` / `--uts=host`: sharing host IPC and UTS namespaces.
- `--userns=host`: disabling user-namespace remapping, collapsing the UID mapping that
  sysbox relies on for isolation.
- `--cap-add SYS_PTRACE` (or similar): adding kernel capabilities that allow container
  escape or inter-process inspection.
- `--security-opt seccomp=unconfined`: removing the seccomp syscall filter.

---

### 6. Service container `options` uses operator global config

**Files:** `act/runner/run_context.go`

**What changed:**
Service containers defined in a workflow (`services:`) previously used only the
per-service `options:` field from the workflow YAML, which meant they ran with the
default Docker runtime (not sysbox).  The `options` for service containers now comes
from `rc.Config.ContainerOptions` (the operator's global config), identical to the
job container.

**Protects against:**
- Service containers running without sysbox isolation while the job container runs with
  it, creating an inconsistent security boundary on the shared job network.
- A workflow author using `services.<id>.options: "--privileged"` or
  `"--runtime=runc"` to gain a foothold that the job container itself would deny.

---

### 7. `valid_volumes` enforcement applies to service containers

**Files:** `act/container/docker_run.go` (existing behaviour — documented for clarity)

**What changed:** Nothing new — documenting the existing `sanitizeConfig` behaviour.

When `ValidVolumes` is empty (which is always the case for service containers, since
the runner never assigns a volume allowlist to them), `sanitizeConfig` clears all
`Binds` and `Mounts` from the container's host config.  This means a workflow author
cannot mount arbitrary host paths or named volumes via `services.<id>.volumes:`.

**Protects against:**
- A fork PR mounting `/:/mnt-host` inside a service container to read the host
  filesystem.
- A service container accessing volumes belonging to other jobs.
