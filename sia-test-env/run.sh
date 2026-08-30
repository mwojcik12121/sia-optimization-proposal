#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"
[[ ! -f .env ]] || { set -a; source ./.env; set +a; }
readonly COMPOSE_FILE="${ROOT_DIR}/docker/compose.yaml"
export COMPOSE_FILE

PROJECT=''
STATUS_DIR=''
declare -a LOG_PIDS=()
declare -a LOG_FILES=()

runner_usage() {
  cat <<'USAGE'
Usage: ./run.sh <scenario-number>
       ./run.sh --list <scenario-number>
Only nodes with scenarios/nodeXX_scenarioN.sh are launched.
USAGE
}

runner_fail() {
  printf '[runner][ERROR] %s\n' "$*" >&2
  exit 1
}

runner_select_services() {
  local scenario="$1" destination="$2" file name
  local -a files=() selected=()
  shopt -s nullglob
  files=("${ROOT_DIR}"/scenarios/node??_scenario"${scenario}".sh)
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || return 66
  mapfile -t files < <(printf '%s\n' "${files[@]}" | sort)
  for file in "${files[@]}"; do
    name="$(basename "${file}")"
    [[ "${name}" =~ ^(node0[1-8])_scenario${scenario}\.sh$ ]] \
      || runner_fail "Invalid scenario filename: ${name}"
    [[ -x "${file}" ]] || runner_fail "Scenario is not executable: ${file}"
    selected+=("${BASH_REMATCH[1]}")
  done
  local -n output="${destination}"
  output=("${selected[@]}")
}

runner_stop_logs() {
  local pid
  for pid in "${LOG_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] || continue
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" 2>/dev/null || true
  done
  LOG_PIDS=()
}

runner_cleanup() {
  local status="$1" file
  trap - EXIT INT TERM
  if [[ -n "${PROJECT}" ]]; then
    docker compose -p "${PROJECT}" down --volumes --remove-orphans --timeout 30 >/dev/null 2>&1 || true
  fi
  runner_stop_logs
  [[ -z "${STATUS_DIR}" ]] || rm -rf "${STATUS_DIR}"
  for file in "${LOG_FILES[@]:-}"; do
    [[ -n "${file}" ]] && printf '[runner] Log: %s\n' "${file}" >&2
  done
  exit "${status}"
}

runner_start_logs() {
  local scenario="$1" timestamp service file
  shift
  timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  mkdir -p "${ROOT_DIR}/logs"
  for service in "$@"; do
    file="${ROOT_DIR}/logs/${service}_scenario${scenario}_${timestamp}.log"
    : >"${file}"
    LOG_FILES+=("${file}")
    (
      set +e
      docker compose -p "${PROJECT}" logs --follow --no-color --no-log-prefix "${service}" 2>&1 | tee -a "${file}"
    ) &
    LOG_PIDS+=("$!")
  done
}

runner_wait_ready() {
  local timeout="$1" started service container state health ready
  shift
  started="$(date +%s)"
  while true; do
    ready=1
    for service in "$@"; do
      container="$(docker compose -p "${PROJECT}" ps -a -q "${service}")"
      [[ -n "${container}" ]] || { ready=0; continue; }
      state="$(docker inspect --format '{{.State.Status}}' "${container}")"
      [[ "${state}" != exited && "${state}" != dead ]] \
        || runner_fail "${service} exited before height 200 was ready."
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}")"
      [[ "${health}" == healthy ]] || ready=0
    done
    (( ready == 1 )) && return 0
    (( $(date +%s) - started < timeout )) || runner_fail "Timed out waiting for height 200."
    sleep 1
  done
}

runner_release() {
  local service
  for service in "$@"; do
    docker compose -p "${PROJECT}" exec -T "${service}" touch /run/sia-lab/scenario-release
  done
}

runner_wait() {
  local service container worker code overall=0
  local -a workers=()
  STATUS_DIR="$(mktemp -d)"
  for service in "$@"; do
    container="$(docker compose -p "${PROJECT}" ps -a -q "${service}")"
    [[ -n "${container}" ]] || runner_fail "Missing container for ${service}."
    (docker wait "${container}" >"${STATUS_DIR}/${service}") &
    workers+=("$!")
  done
  for worker in "${workers[@]}"; do wait "${worker}"; done
  for service in "$@"; do
    code="$(cat "${STATUS_DIR}/${service}")"
    (( code == 0 )) || overall="${code}"
  done
  return "${overall}"
}

if [[ "${1:-}" == --list ]]; then
  (( $# == 2 )) || { runner_usage >&2; exit 64; }
  services=()
  runner_select_services "$2" services || exit $?
  printf '%s\n' "${services[@]}"
  exit 0
fi

(( $# == 1 )) || { runner_usage >&2; exit 64; }
scenario="$1"
[[ "${scenario}" =~ ^[0-9]+$ ]] || { runner_usage >&2; exit 64; }
services=()
runner_select_services "${scenario}" services \
  || runner_fail "No node scenario files exist for scenario ${scenario}."

for binary in hostd renterd walletd BUILD_TAG; do
  [[ -f "${ROOT_DIR}/bin/${binary}" ]] || runner_fail "bin/${binary} is missing; extract sia-binaries.tar.gz into bin/."
done
for binary in hostd renterd walletd; do
  [[ -x "${ROOT_DIR}/bin/${binary}" ]] || runner_fail "bin/${binary} is not executable."
done
for command in docker date tee; do
  command -v "${command}" >/dev/null 2>&1 || runner_fail "Missing command: ${command}."
done
docker info >/dev/null 2>&1 || runner_fail 'Docker Engine is not reachable.'
docker compose version >/dev/null 2>&1 || runner_fail 'Docker Compose v2 is required.'

export BUILD_TAG="$(tr -d '\r\n' <"${ROOT_DIR}/bin/BUILD_TAG")"
[[ "${BUILD_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || runner_fail 'bin/BUILD_TAG is invalid.'
export SCENARIO="${scenario}"
export LAB_NODES="${services[*]}"
export INITIAL_CHAIN_HEIGHT=200
PROJECT="sia-test-s${scenario}-$$"
ready_timeout="${RUNNER_READY_TIMEOUT_SECONDS:-7200}"
[[ "${ready_timeout}" =~ ^[1-9][0-9]*$ ]] || runner_fail 'RUNNER_READY_TIMEOUT_SECONDS must be positive.'

runtime_tools_image="${RUNTIME_TOOLS_IMAGE:-sia-lab-runtime-tools:bookworm}"
if ! docker image inspect "${runtime_tools_image}" >/dev/null 2>&1; then
  printf '[runner] Preparing runtime tools image: %s\n' "${runtime_tools_image}"
  "${ROOT_DIR}/scripts/image-actions.sh"
  docker image inspect "${runtime_tools_image}" >/dev/null 2>&1 \
    || runner_fail "Runtime tools image was not loaded: ${runtime_tools_image}."
fi
if [[ "${SKIP_IMAGE_BUILD:-0}" != 1 ]]; then
  docker compose -p "${PROJECT}" build --pull=false "${services[@]}"
fi

trap 'runner_cleanup $?' EXIT
trap 'exit 130' INT TERM
docker compose -p "${PROJECT}" up -d --no-build --force-recreate "${services[@]}"
runner_start_logs "${scenario}" "${services[@]}"
runner_wait_ready "${ready_timeout}" "${services[@]}"
runner_release "${services[@]}"
set +e
runner_wait "${services[@]}"
status=$?
set -e
sleep 1
exit "${status}"
