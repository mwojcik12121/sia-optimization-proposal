#!/usr/bin/env bash

# Shared implementation for three automatic repair-policy observation scenarios.
# The scenarios create real renter/host states and record the responses produced
# by the running binaries. They do not classify or grade original/optimized behavior.

readonly _REPAIR_BUCKET='repair-risk-tests'
readonly _REPAIR_OBJECT='fixture.bin'
readonly _REPAIR_TEST_BYTES='16777216'
readonly _REPAIR_FUNDING_HASTINGS='10000000000000000000000000000'
readonly _REPAIR_ENTER_RISK='0.000001'
readonly _REPAIR_MODEL_TTL_SECONDS='30'
readonly _REPAIR_HOSTS=(node03 node04 node05 node06)

declare -a _REPAIR_CONTRACT_IDS=()
declare -a _REPAIR_HOST_KEYS=()
declare _REPAIR_AUTOPILOT_DISABLED=0

_repair_notice() {
  local state="$1"
  shift
  test_log INFO "repair:${state}" "$*"
}

_repair_fail() {
  _control_error "$*"
  return 65
}

_repair_validate_environment() {
  local node
  [[ "${SCENARIO:-}" =~ ^[123]$ ]] \
    || { _control_error 'Repair scenario must be 1, 2, or 3.'; return 64; }
  [[ "${INITIAL_CHAIN_HEIGHT:-}" =~ ^[0-9]+$ ]] \
    || { _control_error 'INITIAL_CHAIN_HEIGHT must be a nonnegative integer.'; return 64; }
  [[ "${SCENARIO_SETUP_BLOCKS:-40}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_SETUP_BLOCKS must be positive.'; return 64; }
  [[ "${SCENARIO_BLOCKS:-240}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_BLOCKS must be positive.'; return 64; }
  [[ "${SCENARIO_MINE_INTERVAL_SECONDS:-4}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_MINE_INTERVAL_SECONDS must be positive.'; return 64; }
  [[ "${SCENARIO_TRANSFER_TIMEOUT_SECONDS:-45}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'SCENARIO_TRANSFER_TIMEOUT_SECONDS must be positive.'; return 64; }
  for node in node01 node02 node03 node04 node05 node06 node07 node08; do
    _control_node_is_selected "${node}" || {
      _control_error "Repair scenario ${SCENARIO} requires all eight nodes; ${node} is not selected."
      return 64
    }
  done
}

_repair_start_height() {
  printf '%d\n' "$(( 10#${INITIAL_CHAIN_HEIGHT} + 10#${SCENARIO_SETUP_BLOCKS:-40} ))"
}

_repair_final_height() {
  printf '%d\n' "$(( 10#${INITIAL_CHAIN_HEIGHT} + 10#${SCENARIO_SETUP_BLOCKS:-40} + 10#${SCENARIO_BLOCKS:-240} ))"
}

_repair_wait_for_wallet_funds() {
  local timeout_seconds="${1:-300}" started response spendable
  started="$(date +%s)"
  while true; do
    response="$(_control_wallet_for_node "${NODE_NAME}" 2>/dev/null || true)"
    spendable="$(jq -r '.spendable // "0" | tostring' <<<"${response:-"{}"}" 2>/dev/null || printf '0')"
    if [[ "${spendable}" =~ ^[0-9]+$ && "${spendable}" != 0 ]]; then
      return 0
    fi
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error 'Timed out waiting for confirmed wallet funds.'
      return 124
    fi
    sleep 1
  done
}

_repair_send_with_retry() {
  local address="$1" amount="$2" timeout_seconds="${3:-120}" started
  started="$(date +%s)"
  until action_send_siacoins "${address}" "${amount}" >/dev/null 2>&1; do
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error "Timed out sending ${amount} hastings to ${address}."
      return 124
    fi
    sleep 2
  done
}

_repair_fund_hosts() {
  local host address
  _repair_wait_for_wallet_funds 120
  for host in "${_REPAIR_HOSTS[@]}"; do
    address="$(_control_wallet_address_for_node "${host}")" || return
    _repair_send_with_retry "${address}" "${_REPAIR_FUNDING_HASTINGS}" 120
  done
}

_repair_wait_for_volume() {
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

_repair_announce_with_retry() {
  local started
  started="$(date +%s)"
  until action_host_announce >/dev/null 2>&1; do
    if (( $(date +%s) - started >= 120 )); then
      _control_error 'Timed out announcing the host.'
      return 124
    fi
    sleep 2
  done
}

_repair_prepare_host() {
  local settings
  action_host_add_volume "/var/lib/sia-host-storage/${NODE_NAME}/repair-tests.dat" 512 >/dev/null
  _repair_wait_for_volume
  settings="$(jq -cn --arg address "${NODE_NAME}" \
    '{acceptingContracts:true,netAddress:$address}')"
  action_host_patch_settings "${settings}" >/dev/null
  _repair_wait_for_wallet_funds 300
  _repair_announce_with_retry
}

_repair_autopilot_config() {
  local enabled="$1"
  jq -cn --argjson enabled "${enabled}" \
    '{enabled:$enabled,
      contracts:{amount:4,period:10000,renewWindow:1000,
        download:1073741824,upload:1073741824,storage:1073741824,prune:false},
      hosts:{maxConsecutiveScanFailures:100,maxDowntimeHours:24,minProtocolVersion:""}}'
}

_repair_configure_renter() {
  local upload_config autopilot_config
  upload_config="$(jq -cn \
    '{packing:{enabled:false,slabBufferMaxSizeSoft:4294967296},
      redundancy:{minShards:2,totalShards:4}}')"
  autopilot_config="$(_repair_autopilot_config true)"
  _control_local_api PUT /bus/settings/upload "${upload_config}" >/dev/null
  _control_local_api PUT /bus/autopilot "${autopilot_config}" >/dev/null
  action_renter_trigger_autopilot true >/dev/null
  _repair_notice READY 'renter configured for four contracts and 2-of-4 full slabs'
}

_repair_contract_array() {
  local mode="${1:-good}" response
  response="$(_control_local_api GET "/bus/contracts?filtermode=${mode}")" || return
  jq -ce '
    if type == "array" then .
    elif type == "object" and ((.contracts? | type) == "array") then .contracts
    else error("unsupported contracts response")
    end
  ' <<<"${response}"
}

_repair_wait_for_contracts() {
  local started contracts count
  started="$(date +%s)"
  while true; do
    contracts="$(_repair_contract_array good 2>/dev/null || printf '[]')"
    count="$(jq -r 'length' <<<"${contracts}" 2>/dev/null || printf '0')"
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count == 4 )); then
      mapfile -t _REPAIR_CONTRACT_IDS < <(
        jq -er '.[] | (.id // .contractID) | select(type == "string" and length > 0)' \
          <<<"${contracts}"
      )
      mapfile -t _REPAIR_HOST_KEYS < <(jq -er '.[].hostKey' <<<"${contracts}")
      (( ${#_REPAIR_CONTRACT_IDS[@]} == 4 )) \
        || _repair_fail 'Four contracts were returned, but their IDs were not usable.'
      (( ${#_REPAIR_HOST_KEYS[@]} == 4 )) \
        || _repair_fail 'Four contracts must identify four host keys.'
      _repair_notice READY 'renter has four good contracts'
      return 0
    fi
    action_renter_trigger_autopilot true >/dev/null 2>&1 || true
    if (( $(date +%s) - started >= 600 )); then
      _control_error "Timed out waiting for exactly four good contracts; found ${count}."
      return 124
    fi
    sleep 5
  done
}

_repair_files_match() {
  local source_hash destination_hash
  source_hash="$(sha256sum "$1" | awk '{print $1}')" || return
  destination_hash="$(sha256sum "$2" | awk '{print $1}')" || return
  [[ "${source_hash}" == "${destination_hash}" ]]
}

_repair_download_verified() {
  local label="$1"
  local source_file='/run/sia-lab/repair-tests-source.bin'
  local destination="/run/sia-lab/repair-tests-download-${label}.bin"
  rm -f "${destination}"
  action_renter_download_object "${_REPAIR_BUCKET}" "${_REPAIR_OBJECT}" "${destination}" >/dev/null || return
  _repair_files_match "${source_file}" "${destination}" \
    || _repair_fail "${label}: downloaded object does not match its source."
}

_repair_upload_fixture() {
  local source_file='/run/sia-lab/repair-tests-source.bin' started
  action_renter_create_bucket "${_REPAIR_BUCKET}" >/dev/null 2>&1 || true
  action_generate_test_file "${source_file}" "${_REPAIR_TEST_BYTES}"
  started="$(date +%s)"
  until action_renter_upload_object "${_REPAIR_BUCKET}" "${_REPAIR_OBJECT}" "${source_file}" \
    >/dev/null 2>&1; do
    action_renter_trigger_autopilot true >/dev/null 2>&1 || true
    if (( $(date +%s) - started >= 600 )); then
      _control_error 'Timed out uploading the repair-test fixture.'
      return 124
    fi
    sleep 5
  done
  _repair_download_verified initial
  _repair_notice READY "uploaded and verified ${_REPAIR_TEST_BYTES} bytes"
}

_repair_global_gate_ready() {
  local host response active sectors
  _control_node_api node01 GET \
    "/bus/object/${_REPAIR_OBJECT}?bucket=${_REPAIR_BUCKET}&onlymetadata=true" \
    >/dev/null 2>&1 || return 1
  for host in "${_REPAIR_HOSTS[@]}"; do
    response="$(_control_node_api "${host}" GET /metrics 2>/dev/null || true)"
    active="$(jq -r '.contracts.active // 0' <<<"${response:-"{}"}" 2>/dev/null || printf '0')"
    sectors="$(jq -r '.storage.contractSectors // 0' <<<"${response:-"{}"}" 2>/dev/null || printf '0')"
    [[ "${active}" =~ ^[0-9]+$ && "${sectors}" =~ ^[0-9]+$ ]] || return 1
    (( active >= 1 && sectors >= 2 )) || return 1
  done
}

_repair_wait_for_global_gate() {
  local timeout_seconds="${1:-900}" started
  started="$(date +%s)"
  until _repair_global_gate_ready; do
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error 'Timed out waiting for the fixture and two data sectors on every host.'
      return 124
    fi
    sleep 2
  done
}

_repair_setup_miner_until_ready() {
  local start_height="$1" height remaining
  sleep 2
  until _repair_global_gate_ready; do
    height="$(_control_height_for_node "${NODE_NAME}")"
    if (( height >= start_height )); then
      _control_error 'The fixture was not ready within the bounded setup block allowance.'
      return 65
    fi
    action_mine_blocks 1
    sleep 8
  done
  height="$(_control_height_for_node "${NODE_NAME}")"
  remaining=$(( start_height - height ))
  (( remaining <= 0 )) || action_mine_blocks "${remaining}"
  _repair_notice READY "setup gate complete at height ${start_height}"
}

_repair_miner_loop() {
  local target="$1" height interval="${SCENARIO_MINE_INTERVAL_SECONDS:-4}"
  while true; do
    height="$(_control_height_for_node "${NODE_NAME}")"
    (( height < target )) || break
    action_mine_blocks 1
    sleep "${interval}"
  done
}

_repair_compact_payload() {
  local payload="$1" compact
  if [[ -z "${payload}" ]]; then
    printf '<empty>\n'
  elif compact="$(jq -ce . <<<"${payload}" 2>/dev/null)"; then
    printf '%s\n' "${compact}"
  else
    printf '%s' "${payload}" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
    printf '\n'
  fi
}

_repair_http_observe() {
  local label="$1" method="$2" path="$3" body="${4:-}"
  local response_file error_file http_status curl_status response error request
  local -a arguments

  response_file="$(mktemp /run/sia-lab/repair-http-response.XXXXXX)" || return
  error_file="$(mktemp /run/sia-lab/repair-http-error.XXXXXX)" || {
    rm -f "${response_file}"
    return 1
  }
  arguments=(
    --silent --show-error
    --connect-timeout 5 --max-time 60
    --user ":${SIA_API_PASSWORD:-lab-api-password}"
    --request "${method}"
    --header 'Accept: application/json'
    --output "${response_file}"
    --write-out '%{http_code}'
  )
  if [[ -n "${body}" ]]; then
    arguments+=(--header 'Content-Type: application/json' --data "${body}")
  fi

  if http_status="$(curl "${arguments[@]}" "http://127.0.0.1:9980/api${path}" 2>"${error_file}")"; then
    curl_status=0
  else
    curl_status=$?
  fi
  response="$(cat "${response_file}")"
  error="$(cat "${error_file}")"
  rm -f "${response_file}" "${error_file}"

  [[ -n "${http_status}" ]] || http_status='000'
  request="$(_repair_compact_payload "${body}")"
  response="$(_repair_compact_payload "${response}")"
  error="$(_repair_compact_payload "${error}")"
  _repair_notice OBSERVED \
    "label=${label}; method=${method}; path=${path}; curlStatus=${curl_status}; httpStatus=${http_status}; request=${request}; response=${response}; stderr=${error}"
  return 0
}

_repair_block_interval() {
  local network
  network="$(_control_local_api GET /bus/consensus/network)" || return
  jq -er '(.blockInterval // .BlockInterval) / 1000000 | floor | select(. > 0)' \
    <<<"${network}"
}

_repair_observe_migration() {
  local label="$1" use_risk="$2" health_cutoff="$3" enter_risk="$4"
  local body block_interval=0
  if [[ "${use_risk}" == true ]]; then
    if ! block_interval="$(_repair_block_interval 2>/dev/null)"; then
      _repair_notice OBSERVED \
        "label=${label}; risk request was not sent because the running binary did not provide a usable consensus block interval"
      return 0
    fi
  fi
  body="$(jq -cn \
    --argjson healthCutoff "${health_cutoff}" \
    --argjson enterRisk "${enter_risk}" \
    --argjson useRisk "${use_risk}" \
    --argjson blockInterval "${block_interval}" \
    '{healthCutoff:$healthCutoff,limit:1000} +
      (if $useRisk then {risk:{
        policy:{enabled:true,entryThreshold:$enterRisk,exitThreshold:($enterRisk / 4),
          safetyMargin:300000,modelTTL:30000,defaultRepairTime:5000,
          maxQueueDelay:1800000,maxHorizon:3600000},
        queueDepth:0,parallelism:1,repairTime:5000,blockInterval:$blockInterval}}
       else {} end)')" || return
  _repair_http_observe "${label}" POST /bus/slabs/migration "${body}"
}

_repair_refresh_health() {
  _control_local_api POST /bus/slabs/refreshhealth >/dev/null
}

_repair_set_contract_usability() {
  local id="$1" usability="$2" body
  [[ "${usability}" == good || "${usability}" == bad ]] \
    || { _control_error 'Contract usability must be good or bad.'; return 64; }
  body="$(jq -Rn --arg usability "${usability}" '$usability')"
  _control_local_api PUT "/bus/contract/${id}/usability" "${body}" >/dev/null
}

_repair_set_autopilot_enabled() {
  local enabled="$1" body
  body="$(_repair_autopilot_config "${enabled}")"
  _control_local_api PUT /bus/autopilot "${body}" >/dev/null
  if [[ "${enabled}" == false ]]; then
    _REPAIR_AUTOPILOT_DISABLED=1
    local started state
    started="$(date +%s)"
    while true; do
      state="$(_control_local_api GET /autopilot/state)" || return
      if jq -e '.enabled == false and .migrating == false and .scanning == false' \
        <<<"${state}" >/dev/null; then
        break
      fi
      (( $(date +%s) - started < 120 )) \
        || { _control_error 'Timed out stopping renter maintenance.'; return 124; }
      sleep 1
    done
  else
    _REPAIR_AUTOPILOT_DISABLED=0
  fi
}

_repair_restore_contracts() {
  local id
  for id in "${_REPAIR_CONTRACT_IDS[@]:-}"; do
    [[ -n "${id}" ]] || continue
    _repair_set_contract_usability "${id}" good >/dev/null 2>&1 || true
  done
  _repair_refresh_health >/dev/null 2>&1 || true
}

_repair_host_ip() {
  local host="$1" ip
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "${host}" | awk 'NR == 1 {print $1}')"
  else
    ip="$(dig +short A "${host}" | head -n 1)"
  fi
  [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    _control_error "Could not resolve ${host} to an IPv4 address."
    return 69
  }
  printf '%s\n' "${ip}"
}

_repair_unblock_storage() {
  _network_require_admin || return
  _network_ensure_chains
  iptables -F "${_SIA_LAB_OUTPUT_CHAIN}"
}

_repair_block_storage() {
  local host ip
  _repair_unblock_storage
  for host in "$@"; do
    ip="$(_repair_host_ip "${host}")" || return
    iptables -A "${_SIA_LAB_OUTPUT_CHAIN}" -p tcp -d "${ip}" --dport 9984 -j REJECT
    iptables -A "${_SIA_LAB_OUTPUT_CHAIN}" -p udp -d "${ip}" --dport 9984 -j DROP
  done
  _repair_notice ACTION "blocked storage traffic to: $*"
}

_repair_record_failed_scans() {
  local round key
  _repair_set_autopilot_enabled false
  _repair_block_storage "${_REPAIR_HOSTS[@]}"
  for round in 1 2 3; do
    for key in "${_REPAIR_HOST_KEYS[@]}"; do
      _repair_http_observe \
        "blocked-scan-round-${round}-host-${key}" \
        POST "/bus/host/${key}/scan" '{"timeout":1000}'
    done
  done
  _repair_unblock_storage
  _repair_notice ACTION 'restored storage traffic after blocked scans'
}

_repair_observe_contracts() {
  local label="$1"
  _repair_http_observe "${label}-good-contracts" GET '/bus/contracts?filtermode=good'
  _repair_http_observe "${label}-bad-contracts" GET '/bus/contracts?filtermode=bad'
}

_repair_observe_download() {
  local label="$1" attempt="${2:-1}"
  local source_file='/run/sia-lab/repair-tests-source.bin'
  local destination="/run/sia-lab/repair-tests-observed-${label}-${attempt}.bin"
  local output status started duration source_hash destination_hash bytes file_present matches

  rm -f "${destination}"
  started="$(date +%s)"
  if output="$(action_renter_download_object \
    "${_REPAIR_BUCKET}" "${_REPAIR_OBJECT}" "${destination}" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  duration=$(( $(date +%s) - started ))

  source_hash="$(sha256sum "${source_file}" | awk '{print $1}')"
  file_present=false
  bytes=0
  destination_hash='<none>'
  matches=false
  if [[ -f "${destination}" ]]; then
    file_present=true
    bytes="$(stat -c '%s' "${destination}")"
    destination_hash="$(sha256sum "${destination}" | awk '{print $1}')"
    [[ "${source_hash}" != "${destination_hash}" ]] || matches=true
  fi
  output="$(_repair_compact_payload "${output}")"

  _repair_notice OBSERVED \
    "label=${label}; attempt=${attempt}; exitStatus=${status}; durationSeconds=${duration}; filePresent=${file_present}; bytes=${bytes}; sha256=${destination_hash}; fixtureSha256=${source_hash}; matchesFixture=${matches}; output=${output}"
  return 0
}

_repair_sample_migration_pair() {
  local label="$1" health_cutoff="$2" enter_risk="$3" sample
  for sample in 1 2 3; do
    _repair_observe_migration "${label}-sample-${sample}-risk-request" true "${health_cutoff}" "${enter_risk}"
    _repair_observe_migration "${label}-sample-${sample}-fixed-request" false "${health_cutoff}" "${enter_risk}"
    (( sample == 3 )) || sleep 2
  done
}

_repair_test_scan_evidence() {
  local cycle
  for cycle in 1 2 3; do
    _repair_notice ACTION "scenario=1; cycle=${cycle}; recording blocked host scans"
    _repair_record_failed_scans
    _repair_refresh_health
    sleep 2
    _repair_sample_migration_pair "scenario-1-cycle-${cycle}" 0.75 "${_REPAIR_ENTER_RISK}"
    _repair_observe_download "scenario-1-cycle-${cycle}-download"
    (( cycle == 3 )) || sleep "$(( _REPAIR_MODEL_TTL_SECONDS + 5 ))"
  done
}

_repair_test_expiry_sequence() {
  local id
  _repair_set_autopilot_enabled false
  id="${_REPAIR_CONTRACT_IDS[0]}"

  _repair_notice ACTION "scenario=2; marking contract ${id} bad"
  _repair_set_contract_usability "${id}" bad
  _repair_refresh_health
  sleep 2
  _repair_observe_contracts 'scenario-2-after-contract-disabled'
  _repair_observe_migration 'scenario-2-before-expiry-fixed-cutoff-0.5' false 0.5 1

  sleep "$(( _REPAIR_MODEL_TTL_SECONDS + 5 ))"
  _repair_observe_migration 'scenario-2-after-expiry-risk-cutoff-0.5' true 0.5 1
  _repair_observe_migration 'scenario-2-after-expiry-risk-cutoff-0.25' true 0.25 1

  _repair_notice ACTION "scenario=2; restoring contract ${id}"
  _repair_set_contract_usability "${id}" good
  _repair_refresh_health
  sleep 2
  _repair_observe_contracts 'scenario-2-after-contract-restored'

  _repair_record_failed_scans
  _repair_refresh_health
  sleep 2
  _repair_sample_migration_pair 'scenario-2-after-recovery' 0.75 "${_REPAIR_ENTER_RISK}"
  _repair_observe_download 'scenario-2-recovery-download'
}

_repair_test_source_boundary() {
  local id cycle attempt
  _repair_set_autopilot_enabled false

  _repair_notice ACTION 'scenario=3; marking two contracts bad'
  for id in "${_REPAIR_CONTRACT_IDS[@]:0:2}"; do
    _repair_set_contract_usability "${id}" bad
  done
  _repair_refresh_health
  sleep 2
  _repair_observe_contracts 'scenario-3-two-bad-contracts'
  _repair_sample_migration_pair 'scenario-3-two-bad-contracts' -1 1

  id="${_REPAIR_CONTRACT_IDS[2]}"
  _repair_notice ACTION "scenario=3; marking third contract ${id} bad"
  _repair_set_contract_usability "${id}" bad
  _repair_refresh_health
  sleep 2
  _repair_observe_contracts 'scenario-3-three-bad-contracts'
  _repair_sample_migration_pair 'scenario-3-three-bad-contracts' -1 1

  _repair_notice ACTION 'scenario=3; restoring all contracts'
  _repair_restore_contracts
  sleep 2
  _repair_observe_contracts 'scenario-3-contracts-restored'
  _repair_sample_migration_pair 'scenario-3-contracts-restored' 0.75 "${_REPAIR_ENTER_RISK}"

  for cycle in 1 2; do
    _repair_block_storage node03 node04
    _repair_observe_download "scenario-3-cycle-${cycle}-two-hosts-blocked"

    _repair_block_storage node03 node04 node05
    for attempt in 1 2 3; do
      _repair_observe_download "scenario-3-cycle-${cycle}-three-hosts-blocked" "${attempt}"
    done

    _repair_unblock_storage
    _repair_notice ACTION 'restored storage traffic to all hosts'
    _repair_observe_download "scenario-3-cycle-${cycle}-all-hosts-restored"
  done
}

_repair_cleanup() {
  local status="$1"
  trap - EXIT
  set +e
  network_reset >/dev/null 2>&1 || true
  if [[ "${NODE_NAME:-}" == node01 ]]; then
    _repair_restore_contracts
    if (( _REPAIR_AUTOPILOT_DISABLED == 1 )); then
      _repair_set_autopilot_enabled true >/dev/null 2>&1 || true
    fi
  fi
  exit "${status}"
}

_repair_finish() {
  local final_height="$1" started
  started="$(date +%s)"
  until _control_node_api node01 GET /bus/bucket/repair-tests-complete >/dev/null 2>&1; do
    (( $(date +%s) - started < 1200 )) \
      || { _control_error 'Timed out waiting for renter observations to complete.'; return 124; }
    sleep 1
  done
  info_wait_for_height "${final_height}" 1200
  info_wait_for_selected_height "${final_height}" 300
  info_wait_for_selected_tip "${final_height}" 300
  _repair_notice COMPLETE "all nodes reached height ${final_height} and agree on the non-renter tip"
  sleep 10
}

repair_test_run() {
  local start_height final_height role
  _repair_validate_environment
  start_height="$(_repair_start_height)"
  final_height="$(_repair_final_height)"
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  trap '_repair_cleanup $?' EXIT

  _repair_notice START \
    "scenario=${SCENARIO}; role=${role}; startHeight=${start_height}; finalHeight=${final_height}"

  case "${NODE_NAME}" in
    node01)
      _repair_fund_hosts
      _repair_configure_renter
      _repair_wait_for_contracts
      _repair_upload_fixture
      ;;
    node03|node04|node05|node06)
      _repair_prepare_host
      ;;
    node07)
      _repair_setup_miner_until_ready "${start_height}"
      ;;
  esac

  if [[ "${NODE_NAME}" != node07 ]]; then
    _repair_wait_for_global_gate 900
  fi
  info_wait_for_height "${start_height}" 300
  info_wait_for_selected_height "${start_height}" 300

  case "${NODE_NAME}" in
    node01)
      case "${SCENARIO}" in
        1) _repair_test_scan_evidence ;;
        2) _repair_test_expiry_sequence ;;
        3) _repair_test_source_boundary ;;  # unimplemented
      esac
      _repair_notice OBSERVED "scenario=${SCENARIO}; actions complete; inspect recorded API and download outcomes"
      action_renter_create_bucket repair-tests-complete >/dev/null
      ;;
    node07)
      _repair_miner_loop "${final_height}"
      ;;
  esac

  _repair_finish "${final_height}"
}
