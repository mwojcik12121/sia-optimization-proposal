#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/sia-lab/controls/common.sh
source /opt/sia-lab/controls/actions.sh
source /opt/sia-lab/controls/info.sh
source /opt/sia-lab/controls/network.sh
source /opt/sia-lab/configure.sh

readonly SCENARIO_NUMBER="${SCENARIO:-}"
readonly SCENARIO_TIMEOUT="${SCENARIO_TIMEOUT_SECONDS:-1800}"
readonly RELEASE_TIMEOUT="${SCENARIO_RELEASE_TIMEOUT_SECONDS:-900}"

entry_error() {
  printf '[%s][ERROR] %s\n' "${NODE_NAME:-unknown}" "$*" >&2
}

entry_cleanup() {
  local status="$1" pid
  trap - EXIT INT TERM
  network_reset >/dev/null 2>&1 || true
  for pid in "${HELPER_PID:-}" "${PRIMARY_PID:-}"; do
    [[ -n "${pid}" ]] || continue
    kill -CONT "${pid}" >/dev/null 2>&1 || true
    kill -TERM "${pid}" >/dev/null 2>&1 || true
  done
  for pid in "${HELPER_PID:-}" "${PRIMARY_PID:-}"; do
    [[ -n "${pid}" ]] || continue
    for _ in $(seq 1 120); do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.25
    done
    kill -KILL "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" 2>/dev/null || true
  done
  exit "${status}"
}

entry_wait_for_release() {
  local started
  started="$(date +%s)"
  while [[ ! -f /run/sia-lab/scenario-release ]]; do
    if [[ -n "${PRIMARY_PID:-}" ]] && ! kill -0 "${PRIMARY_PID}" 2>/dev/null; then
      entry_error 'Primary Sia daemon exited before scenario release.'
      return 1
    fi
    if (( $(date +%s) - started >= RELEASE_TIMEOUT )); then
      entry_error 'Timed out waiting for scenario release.'
      return 124
    fi
    sleep 0.2
  done
}

trap 'entry_cleanup $?' EXIT
trap 'exit 130' INT TERM

[[ "${NODE_NAME:-}" =~ ^node0[1-8]$ ]] || { entry_error 'NODE_NAME must be node01 through node08.'; exit 64; }
[[ "${NODE_ID:-}" =~ ^0[1-8]$ ]] || { entry_error 'NODE_ID must be 01 through 08.'; exit 64; }
[[ "${SCENARIO_NUMBER}" =~ ^[0-9]+$ ]] || { entry_error 'SCENARIO must be numeric.'; exit 64; }
[[ "${SCENARIO_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || { entry_error 'SCENARIO_TIMEOUT_SECONDS must be positive.'; exit 64; }
[[ "${RELEASE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || { entry_error 'SCENARIO_RELEASE_TIMEOUT_SECONDS must be positive.'; exit 64; }

expected_daemon="$(_control_role_for_node "${NODE_NAME}")"
[[ "${SIA_DAEMON:-}" == "${expected_daemon}" ]] \
  || { entry_error "Expected ${expected_daemon}, received ${SIA_DAEMON:-nothing}."; exit 64; }
command -v "${expected_daemon}" >/dev/null 2>&1 \
  || { entry_error "Missing primary binary ${expected_daemon}."; exit 69; }
command -v walletd >/dev/null 2>&1 || { entry_error 'Missing walletd bootstrap binary.'; exit 69; }

scenario_file="/opt/sia-lab/scenarios/${NODE_NAME}_scenario${SCENARIO_NUMBER}.sh"
[[ -x "${scenario_file}" ]] || { entry_error "Missing scenario file ${scenario_file}."; exit 66; }

rm -rf "/var/lib/sia/${NODE_NAME}" "/var/lib/sia-host-storage/${NODE_NAME}" /run/sia-lab/*
mkdir -p "/var/lib/sia/${NODE_NAME}" "/var/lib/sia-host-storage/${NODE_NAME}" /run/sia-lab
config_write_primary_config
config_start_primary
config_wait_for_primary 300
configure_initial_network
entry_wait_for_release

printf '[%s][scenario] Running scenario %s.\n' "${NODE_NAME}" "${SCENARIO_NUMBER}" >&2
set +e
timeout --signal=TERM --kill-after=30s "${SCENARIO_TIMEOUT}" bash "${scenario_file}"
scenario_status=$?
set -e
printf '[%s][scenario] Scenario %s exited with status %s.\n' \
  "${NODE_NAME}" "${SCENARIO_NUMBER}" "${scenario_status}" >&2
exit "${scenario_status}"
