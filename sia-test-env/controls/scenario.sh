#!/usr/bin/env bash

# Shared controls for scenario 1. The blockchain height is the common clock:
# every role keeps working until the miner reaches the configured target.

readonly _SCENARIO_BUCKET='risk-scenario'
readonly _SCENARIO_FUNDING_HASTINGS='10000000000000000000000000000'
readonly _SCENARIO_TRANSFER_HASTINGS='1000000000000000000000000'
readonly _SCENARIO_TEST_BYTES='12582912'

_scenario_notice() {
  local state="$1"
  shift
  test_log INFO "scenario:${state}" "$*"
}

_scenario_warn() {
  test_log WARN scenario "$*"
}

_scenario_validate() {
  local node drain_seconds minimum_drain_seconds
  [[ "${INITIAL_CHAIN_HEIGHT:-}" =~ ^[0-9]+$ ]] \
    || { _control_error 'INITIAL_CHAIN_HEIGHT must be a nonnegative integer.'; return 64; }
  [[ "${SCENARIO_BLOCKS:-240}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_BLOCKS must be a positive integer.'; return 64; }
  [[ "${SCENARIO_SETUP_BLOCKS:-40}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_SETUP_BLOCKS must be a positive integer.'; return 64; }
  [[ "${SCENARIO_DRAIN_BLOCKS:-80}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_DRAIN_BLOCKS must be a positive integer.'; return 64; }
  [[ "${SCENARIO_MINE_INTERVAL_SECONDS:-4}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_MINE_INTERVAL_SECONDS must be a positive integer.'; return 64; }
  [[ "${SCENARIO_TRANSFER_TIMEOUT_SECONDS:-45}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_TRANSFER_TIMEOUT_SECONDS must be a positive integer.'; return 64; }
  drain_seconds="$(( 10#${SCENARIO_DRAIN_BLOCKS:-80} * 10#${SCENARIO_MINE_INTERVAL_SECONDS:-4} ))"
  minimum_drain_seconds="$(( 230 + 2 * 10#${SCENARIO_TRANSFER_TIMEOUT_SECONDS:-45} ))"
  (( minimum_drain_seconds >= 300 )) || minimum_drain_seconds=300
  if (( drain_seconds < minimum_drain_seconds )); then
    _control_error \
      "The drain window is ${drain_seconds}s; at least ${minimum_drain_seconds}s is required for one in-flight loop."
    return 64
  fi
  for node in node01 node02 node03 node04 node05 node06 node07 node08; do
    _control_node_is_selected "${node}" || {
      _control_error "Scenario 1 requires all eight nodes; ${node} is not selected."
      return 64
    }
  done
}

_scenario_target_height() {
  printf '%d\n' \
    "$(( 10#${INITIAL_CHAIN_HEIGHT} + 10#${SCENARIO_SETUP_BLOCKS:-40} + 10#${SCENARIO_BLOCKS:-240} ))"
}

_scenario_start_height() {
  printf '%d\n' "$(( 10#${INITIAL_CHAIN_HEIGHT} + 10#${SCENARIO_SETUP_BLOCKS:-40} ))"
}

_scenario_drain_height() {
  printf '%d\n' \
    "$(( 10#${INITIAL_CHAIN_HEIGHT} + 10#${SCENARIO_SETUP_BLOCKS:-40} + 10#${SCENARIO_BLOCKS:-240} + 10#${SCENARIO_DRAIN_BLOCKS:-80} ))"
}

_scenario_below_target() {
  local target="$1" height
  height="$(_control_height_for_node "${NODE_NAME}" 2>/dev/null || true)"
  [[ "${height}" =~ ^[0-9]+$ ]] || return 0
  (( height < target ))
}

_scenario_wait_for_wallet_funds() {
  local timeout_seconds="${1:-300}" started response spendable
  started="$(date +%s)"
  while true; do
    response="$(_control_wallet_for_node "${NODE_NAME}" 2>/dev/null || true)"
    spendable="$(jq -r '.spendable // "0" | tostring' <<<"${response:-{}}" 2>/dev/null || printf '0')"
    if [[ "${spendable}" =~ ^[0-9]+$ && "${spendable}" != '0' ]]; then
      _scenario_notice READY "wallet is funded; spendable=${spendable} hastings"
      return 0
    fi
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error 'Timed out waiting for confirmed wallet funds.'
      return 124
    fi
    sleep 1
  done
}

_scenario_send_with_retry() {
  local address="$1" amount="$2" timeout_seconds="${3:-120}" started
  started="$(date +%s)"
  while ! action_send_siacoins "${address}" "${amount}" >/dev/null 2>&1; do
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error "Timed out sending ${amount} hastings to ${address}."
      return 124
    fi
    sleep 2
  done
}

_scenario_fund_participants() {
  local node address
  [[ "${NODE_NAME}" == 'node01' ]] || return 69
  _scenario_wait_for_wallet_funds 120
  for node in node02 node03 node04 node05 node06; do
    address="$(_control_wallet_address_for_node "${node}")" || return
    _scenario_send_with_retry "${address}" "${_SCENARIO_FUNDING_HASTINGS}" 120
    _scenario_notice FUNDING "sent startup funds to ${node}; address=${address}"
  done
}

_scenario_wait_for_volume() {
  local started response
  started="$(date +%s)"
  while true; do
    response="$(_control_local_api GET /volumes 2>/dev/null || true)"
    if jq -e 'any(.[]?; .available == true and .status == "ready" and .readOnly == false)' \
      <<<"${response:-[]}" >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) - started >= 300 )); then
      _control_error 'Timed out waiting for writable host storage.'
      return 124
    fi
    sleep 1
  done
}

_scenario_prepare_host() {
  local settings
  action_host_add_volume "/var/lib/sia-host-storage/${NODE_NAME}/scenario.dat" 512 >/dev/null
  _scenario_wait_for_volume
  settings="$(jq -cn --arg address "${NODE_NAME}" \
    '{acceptingContracts:true,netAddress:$address}')"
  action_host_patch_settings "${settings}" >/dev/null
  _scenario_wait_for_wallet_funds 300
  _scenario_send_with_retry_announce
  _scenario_notice READY \
    "host is accepting contracts at ${NODE_NAME}:9984 with a 512-sector volume"
}

_scenario_send_with_retry_announce() {
  local started
  started="$(date +%s)"
  while ! action_host_announce >/dev/null 2>&1; do
    if (( $(date +%s) - started >= 120 )); then
      _control_error 'Timed out announcing the host.'
      return 124
    fi
    sleep 2
  done
}

_scenario_global_gate_ready() {
  local renter host response active sectors
  for renter in node01 node02; do
    if ! _control_node_api "${renter}" GET \
      "/bus/object/initial-${renter}.bin?bucket=${_SCENARIO_BUCKET}&onlymetadata=true" \
      >/dev/null 2>&1; then
      return 1
    fi
  done
  for host in node03 node04 node05 node06; do
    response="$(_control_node_api "${host}" GET /metrics 2>/dev/null || true)"
    active="$(jq -r '.contracts.active // 0' <<<"${response:-{}}" 2>/dev/null || printf '0')"
    sectors="$(jq -r '.storage.contractSectors // 0' <<<"${response:-{}}" 2>/dev/null || printf '0')"
    if [[ ! "${active}" =~ ^[0-9]+$ || ! "${sectors}" =~ ^[0-9]+$ ]] \
      || (( active < 2 || sectors < 2 )); then
      return 1
    fi
  done
}

_scenario_wait_for_global_gate() {
  local timeout_seconds="${1:-900}" started
  started="$(date +%s)"
  until _scenario_global_gate_ready; do
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error \
        'Timed out waiting for both renter objects and two active, data-bearing contracts on every host.'
      return 124
    fi
    sleep 2
  done
  _scenario_notice READY \
    'global gate passed; renterObjects=2/2, readyHosts=4/4, activeContractsPerHost>=2, contractSectorsPerHost>=2'
}

_scenario_configure_renter() {
  local upload_config autopilot_config
  upload_config="$(jq -cn \
    '{packing:{enabled:false,slabBufferMaxSizeSoft:4294967296},
      redundancy:{minShards:2,totalShards:4}}')"
  autopilot_config="$(jq -cn \
    '{enabled:true,
      contracts:{amount:4,period:1000,renewWindow:100,
        download:1073741824,upload:1073741824,storage:1073741824,prune:false},
      hosts:{maxConsecutiveScanFailures:100,maxDowntimeHours:24,minProtocolVersion:""}}')"
  _control_local_api PUT /bus/settings/upload "${upload_config}" >/dev/null
  _control_local_api PUT /bus/autopilot "${autopilot_config}" >/dev/null
  action_renter_trigger_autopilot true >/dev/null
  _scenario_notice READY \
    'renter configured for four contracts, 2-of-4 slabs, disabled packing, and forced host scans'
}

_scenario_wait_for_renter_contracts() {
  local started response count
  started="$(date +%s)"
  while true; do
    response="$(_control_local_api GET '/bus/contracts?filtermode=good' 2>/dev/null || true)"
    count="$(jq -r \
      'if type == "array" then length elif (.contracts? | type) == "array" then .contracts | length else 0 end' \
      <<<"${response:-[]}" 2>/dev/null || printf '0')"
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= 4 )); then
      _scenario_notice READY "renter has ${count} good contracts"
      return 0
    fi
    action_renter_trigger_autopilot true >/dev/null 2>&1 || true
    if (( $(date +%s) - started >= 600 )); then
      _control_error "Timed out waiting for four good renter contracts; found ${count:-0}."
      return 124
    fi
    sleep 5
  done
}

_scenario_files_match() {
  local source_hash destination_hash
  source_hash="$(sha256sum "$1" | awk '{print $1}')" || return
  destination_hash="$(sha256sum "$2" | awk '{print $1}')" || return
  [[ "${source_hash}" == "${destination_hash}" ]]
}

_scenario_upload_initial_object() {
  local source_file="/run/sia-lab/${NODE_NAME}-scenario-data.bin"
  local downloaded_file="/run/sia-lab/${NODE_NAME}-scenario-download.bin"
  local key="initial-${NODE_NAME}.bin" started
  action_renter_create_bucket "${_SCENARIO_BUCKET}" >/dev/null
  action_generate_test_file "${source_file}" "${_SCENARIO_TEST_BYTES}"
  started="$(date +%s)"
  while ! action_renter_upload_object "${_SCENARIO_BUCKET}" "${key}" "${source_file}" \
    >/dev/null; do
    action_renter_trigger_autopilot true >/dev/null 2>&1 || true
    if (( $(date +%s) - started >= 600 )); then
      _control_error "Timed out uploading initial object ${key}."
      return 124
    fi
    sleep 5
  done
  action_renter_download_object "${_SCENARIO_BUCKET}" "${key}" "${downloaded_file}"
  _scenario_files_match "${source_file}" "${downloaded_file}" || {
    _control_error "Downloaded initial object ${key} does not match its source."
    return 65
  }
  _scenario_notice READY \
    "uploaded and verified ${_SCENARIO_TEST_BYTES} bytes as ${_SCENARIO_BUCKET}/${key}"
}

_scenario_transaction_once() {
  local address="$1"
  if action_send_siacoins "${address}" "${_SCENARIO_TRANSFER_HASTINGS}" >/dev/null 2>&1; then
    _scenario_notice TX "sent ${_SCENARIO_TRANSFER_HASTINGS} hastings to ${address}"
  else
    _scenario_warn "transaction attempt to ${address} failed; the loop will continue"
  fi
}

_scenario_renter_loop() {
  local target="$1" peer address source_file initial_key download_file iteration=0
  peer='node02'
  [[ "${NODE_NAME}" == 'node02' ]] && peer='node01'
  address="$(_control_wallet_address_for_node "${peer}")" || return
  source_file="/run/sia-lab/${NODE_NAME}-scenario-data.bin"
  initial_key="initial-${NODE_NAME}.bin"
  download_file="/run/sia-lab/${NODE_NAME}-loop-download.bin"

  while _scenario_below_target "${target}"; do
    iteration=$(( iteration + 1 ))
    _scenario_transaction_once "${address}"
    action_renter_trigger_autopilot true >/dev/null 2>&1 || \
      _scenario_warn 'autopilot trigger was not accepted'

    if action_renter_download_object "${_SCENARIO_BUCKET}" "${initial_key}" \
      "${download_file}" >/dev/null 2>&1 \
      && _scenario_files_match "${source_file}" "${download_file}"; then
      _scenario_notice STORAGE "download ${iteration} verified"
    else
      _scenario_warn "download ${iteration} failed or was corrupt; continuing during host faults"
    fi

    if (( iteration <= 8 )); then
      if action_renter_upload_object "${_SCENARIO_BUCKET}" \
        "activity-${NODE_NAME}-${iteration}.bin" "${source_file}" >/dev/null 2>&1; then
        _scenario_notice STORAGE "uploaded activity object ${iteration}"
      else
        _scenario_warn "activity upload ${iteration} failed; healthy-chain work continues"
      fi
    fi

    _scenario_log_risk_candidates
    sleep 10
  done
}

_scenario_log_risk_candidates() {
  local snapshot count mode
  if snapshot="$(info_renter_migration_snapshot 0.75 0.000001 1000 2>/dev/null)"; then
    count="$(jq -r '.slabs | length' <<<"${snapshot}")"
    mode="$(jq -r '.mode' <<<"${snapshot}")"
    if (( count == 0 )); then
      _scenario_notice RISK 'migrationCandidates=0; requestedMode=risk-aware'
    else
      _scenario_notice RISK "migrationCandidates=${count}; responseMode=${mode}"
    fi
  else
    _scenario_warn 'risk candidate request failed; native renterd scoring logs remain available'
  fi
}

_scenario_host_metrics() {
  local response active sectors writes
  response="$(_control_local_api GET /metrics 2>/dev/null || true)"
  active="$(jq -r '.contracts.active // 0' <<<"${response:-{}}" 2>/dev/null || printf '0')"
  sectors="$(jq -r '.storage.contractSectors // 0' <<<"${response:-{}}" 2>/dev/null || printf '0')"
  writes="$(jq -r '.storage.writes // 0' <<<"${response:-{}}" 2>/dev/null || printf '0')"
  _scenario_notice HOST "activeContracts=${active}; contractSectors=${sectors}; writes=${writes}"
}

_scenario_healthy_host_loop() {
  local target="$1" address
  address="$(_control_wallet_address_for_node node01)" || return
  while _scenario_below_target "${target}"; do
    _scenario_transaction_once "${address}"
    _scenario_host_metrics
    sleep 8
  done
}

_scenario_faulty_host_loop() {
  local target="$1" address cycle=0
  address="$(_control_wallet_address_for_node node01)" || return
  [[ "${NODE_NAME}" != 'node05' ]] || sleep 7

  while _scenario_below_target "${target}"; do
    cycle=$(( cycle + 1 ))
    _scenario_notice FAULT "cycle=${cycle}; phase=delay"
    network_delay_for 900 20 200 25

    _scenario_notice FAULT "cycle=${cycle}; phase=network-interruption"
    network_partition_all
    sleep 25
    network_heal_all
    action_connect_peer node07 >/dev/null 2>&1 || true
    sleep 25

    _scenario_notice FAULT "cycle=${cycle}; phase=temporary-daemon-failure"
    action_pause_primary_daemon_for 25
    _scenario_transaction_once "${address}"
    _scenario_host_metrics
    # Multiple healthy scans separate the deterministic failure samples.
    sleep 25
  done
  network_reset
}

_scenario_setup_miner_until_ready() {
  local start_height="$1" height remaining
  sleep 2
  until _scenario_global_gate_ready; do
    height="$(_control_height_for_node "${NODE_NAME}")"
    if (( height >= start_height )); then
      _control_error \
        "Global setup gate did not pass within ${SCENARIO_SETUP_BLOCKS:-40} setup blocks."
      return 65
    fi
    action_mine_blocks 1
    height="$(_control_height_for_node "${NODE_NAME}")"
    _scenario_notice SETUP "mined confirmation block; localHeight=${height}; setupCeiling=${start_height}"
    sleep 8
  done
  _scenario_notice READY 'node07 observed the global contract and object gate'

  height="$(_control_height_for_node "${NODE_NAME}")"
  remaining=$(( start_height - height ))
  if (( remaining > 0 )); then
    action_mine_blocks "${remaining}"
    _scenario_notice SETUP \
      "advanced ${remaining} block(s) to the fixed workload start height ${start_height}"
  fi
}

_scenario_miner_loop() {
  local target="$1" initial_delay="$2" height
  local interval="$(( 2 * 10#${SCENARIO_MINE_INTERVAL_SECONDS:-4} ))"
  sleep "${initial_delay}"
  while true; do
    height="$(_control_height_for_node "${NODE_NAME}")"
    (( height < target )) || break
    if { [[ "${NODE_NAME}" == 'node07' ]] && (( height % 2 == 0 )); } \
      || { [[ "${NODE_NAME}" == 'node08' ]] && (( height % 2 == 1 )); }; then
      action_mine_blocks 1
      height="$(_control_height_for_node "${NODE_NAME}")"
      _scenario_notice BLOCK "mined block; localHeight=${height}; targetHeight=${target}"
    fi
    sleep "${interval}"
  done
}

_scenario_finish() {
  local drain_height="$1" role initial_delay settlement_height
  settlement_height=$(( drain_height + 1 ))
  network_reset >/dev/null 2>&1 || true
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  if [[ "${role}" == 'walletd' ]]; then
    initial_delay=2
    [[ "${NODE_NAME}" != 'node08' ]] || initial_delay=6
    _scenario_notice DRAIN \
      "continuing alternating mining through drain height ${drain_height}"
    _scenario_miner_loop "${drain_height}" "${initial_delay}"
  else
    _scenario_notice DRAIN \
      "workload stopped; waiting for miners at drain height ${drain_height}"
    info_wait_for_height "${drain_height}" 900
  fi
  info_wait_for_selected_height "${drain_height}" 300
  if [[ "${NODE_NAME}" == 'node07' ]]; then
    action_mine_blocks 1
    _scenario_notice DRAIN \
      "mined final settlement block at height ${settlement_height}"
  fi
  info_wait_for_selected_height "${settlement_height}" 300
  info_wait_for_selected_tip "${settlement_height}" 300
  _scenario_notice COMPLETE \
    "all nodes reached height ${settlement_height}; non-renter nodes agree on one tip"
  # Keep APIs alive while every peer completes the all-node check.
  sleep 15
}

scenario_run() {
  local role start_height target drain_height
  _scenario_validate
  start_height="$(_scenario_start_height)"
  target="$(_scenario_target_height)"
  drain_height="$(_scenario_drain_height)"
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  _scenario_notice START \
    "role=${role}; initialHeight=${INITIAL_CHAIN_HEIGHT}; workloadStartHeight=${start_height}; targetHeight=${target}; drainHeight=${drain_height}"

  case "${NODE_NAME}" in
    node01)
      _scenario_fund_participants
      _scenario_configure_renter
      _scenario_wait_for_renter_contracts
      _scenario_upload_initial_object
      ;;
    node02)
      _scenario_wait_for_wallet_funds 300
      _scenario_configure_renter
      _scenario_wait_for_renter_contracts
      _scenario_upload_initial_object
      ;;
    node03|node05)
      _scenario_prepare_host
      ;;
    node04|node06)
      _scenario_prepare_host
      ;;
    node07)
      _scenario_setup_miner_until_ready "${start_height}"
      ;;
  esac

  if [[ "${NODE_NAME}" != 'node07' ]]; then
    _scenario_wait_for_global_gate 900
  fi
  info_wait_for_height "${start_height}" 300
  info_wait_for_selected_height "${start_height}" 300
  _scenario_notice START "workload and fault window opened at height ${start_height}"

  case "${NODE_NAME}" in
    node01|node02) _scenario_renter_loop "${target}" ;;
    node03|node05) _scenario_faulty_host_loop "${target}" ;;
    node04|node06) _scenario_healthy_host_loop "${target}" ;;
    node07) _scenario_miner_loop "${target}" 2 ;;
    node08) _scenario_miner_loop "${target}" 6 ;;
  esac

  _scenario_finish "${drain_height}"
}
