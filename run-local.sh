#!/usr/bin/env bash
# run-local.sh — run gitea-runner directly on the host, mirroring the compose setup.
#
# Usage:
#   GITEA_INSTANCE_URL=https://gitea.example.com \
#   REGISTRATION_TOKEN=<token>                    \
#   [DATA_DIR=/var/lib/gitea-ci-runner]           \
#   [RUNNER_NAME=$(hostname)]                     \
#   ./run-local.sh
#
# The binary is built automatically if not present.
# Ctrl-C to stop.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${REPO_ROOT}/gitea-runner"

# ── required ──────────────────────────────────────────────────────────────────
: "${GITEA_INSTANCE_URL:?Set GITEA_INSTANCE_URL to your Gitea server URL}"
: "${REGISTRATION_TOKEN:?Set REGISTRATION_TOKEN to the runner registration token}"

# ── optional with defaults ────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/var/lib/gitea-ci-runner}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
CONFIG_FILE="${DATA_DIR}/config.yaml"
TOKEN_FILE="${DATA_DIR}/registration_token"

# ── build if needed ───────────────────────────────────────────────────────────
if [[ ! -x "${BINARY}" ]]; then
    echo "==> Binary not found, building..."
    (cd "${REPO_ROOT}" && make build)
fi
echo "==> Using binary: ${BINARY} ($(${BINARY} --version 2>&1 || true))"

# ── create data dirs ──────────────────────────────────────────────────────────
mkdir -p "${DATA_DIR}/home" "${DATA_DIR}/cache" "${DATA_DIR}/work"

# ── write registration token ──────────────────────────────────────────────────
printf '%s' "${REGISTRATION_TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"

# ── write config.yaml ─────────────────────────────────────────────────────────
cat > "${CONFIG_FILE}" <<YAML
log:
  level: info

runner:
  file: ${DATA_DIR}/.runner
  capacity: 1
  envs:
    A_TEST_ENV_NAME_1: a_test_env_value_1
    A_TEST_ENV_NAME_2: a_test_env_value_2
  env_file: .env
  timeout: 3h
  shutdown_timeout: 0s
  insecure: false
  fetch_timeout: 5s
  fetch_interval: 2s
  github_mirror: ''
  labels:
    - "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-22.04"
    - "ubuntu-22.04:docker://ghcr.io/catthehacker/ubuntu:act-22.04"
    - "ubuntu-20.04:docker://ghcr.io/catthehacker/ubuntu:act-20.04"

cache:
  enabled: true
  dir: "${DATA_DIR}/cache"
  host: ""
  port: 0
  external_server: ""

container:
  network: "ci-network"
  privileged: false
  options: --runtime=sysbox-runc --user 0
  workdir_parent:
  valid_volumes: []
  docker_host: "-"
  force_pull: false
  force_rebuild: false
  require_docker: false
  docker_timeout: 0s

host:
  workdir_parent: ${DATA_DIR}/work
YAML

echo "==> Config written to ${CONFIG_FILE}"
echo "==> Data dir: ${DATA_DIR}"
echo "==> Runner name: ${RUNNER_NAME}"
echo "==> Gitea URL: ${GITEA_INSTANCE_URL}"
echo ""

# ── run ───────────────────────────────────────────────────────────────────────
export HOME="${DATA_DIR}/home"
export TZ="Europe/Warsaw"
export TIME_ZONE="Europe/Warsaw"
export CONFIG_FILE="${CONFIG_FILE}"
export GITEA_INSTANCE_URL="${GITEA_INSTANCE_URL}"
export GITEA_RUNNER_REGISTRATION_TOKEN_FILE="${TOKEN_FILE}"
export GITEA_RUNNER_NAME="${RUNNER_NAME}"

exec "${BINARY}" daemon --config "${CONFIG_FILE}"
