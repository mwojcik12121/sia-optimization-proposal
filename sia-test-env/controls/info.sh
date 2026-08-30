#!/usr/bin/env bash

info_height() {
  _control_height_for_node "${NODE_NAME}"
}

info_tip() {
  _control_tip_for_node "${NODE_NAME}"
}

info_last_block() {
  local role tip id
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  case "${role}" in
    renterd)
      _control_local_api GET /bus/consensus/state
      ;;
    hostd)
      tip="$(_control_tip_for_node "${NODE_NAME}")" || return
      id="$(jq -er '.id' <<<"${tip}")" || return
      _control_local_api GET "/consensus/checkpoint/${id}"
      ;;
    walletd)
      tip="$(_control_tip_for_node "${NODE_NAME}")" || return
      id="$(jq -er '.id' <<<"${tip}")" || return
      _control_local_api GET "/consensus/blocks/${id}"
      ;;
  esac
}

info_peers() {
  _control_peers_for_node "${NODE_NAME}"
}

info_peer_count() {
  _control_peer_count_for_node "${NODE_NAME}"
}

info_wallet() {
  _control_wallet_for_node "${NODE_NAME}"
}

info_wallet_spendable() {
  _control_wallet_for_node "${NODE_NAME}" | jq -er '.spendable'
}

info_transaction_pool() {
  local role
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  case "${role}" in
    renterd) _control_local_api GET /bus/txpool/transactions ;;
    hostd) _control_local_api GET /wallet/pending ;;
    walletd) _control_local_api GET /txpool/transactions ;;
  esac
}

info_alerts() {
  local role
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  case "${role}" in
    renterd) _control_local_api GET /bus/alerts ;;
    hostd) _control_local_api GET /alerts ;;
    walletd) printf '[]\n' ;;
  esac
}

info_host_contracts() {
  [[ "$(_control_role_for_node "${NODE_NAME}")" == 'hostd' ]] \
    || { _control_error 'Host contract inspection requires hostd.'; return 69; }
  _control_local_api GET /contracts
}

info_host_settings() {
  [[ "$(_control_role_for_node "${NODE_NAME}")" == 'hostd' ]] \
    || { _control_error 'Host settings inspection requires hostd.'; return 69; }
  _control_local_api GET /settings
}

info_host_volumes() {
  [[ "$(_control_role_for_node "${NODE_NAME}")" == 'hostd' ]] \
    || { _control_error 'Host volume inspection requires hostd.'; return 69; }
  _control_local_api GET /volumes
}

info_renter_contracts() {
  [[ "$(_control_role_for_node "${NODE_NAME}")" == 'renterd' ]] \
    || { _control_error 'Renter contract inspection requires renterd.'; return 69; }
  _control_local_api GET /bus/contracts
}

info_renter_autopilot() {
  [[ "$(_control_role_for_node "${NODE_NAME}")" == 'renterd' ]] \
    || { _control_error 'Autopilot inspection requires renterd.'; return 69; }
  _control_local_api GET /autopilot/state
}

info_wait_for_height() {
  _control_require_args 1 "$#" 'info_wait_for_height <height> [timeout-seconds]' || return
  local target="$1" timeout_seconds="${2:-300}" started height
  [[ "${target}" =~ ^[0-9]+$ && "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'Height and timeout must be nonnegative/positive integers.'; return 64; }
  started="$(date +%s)"
  while true; do
    height="$(_control_height_for_node "${NODE_NAME}" 2>/dev/null || printf '%s' -1)"
    [[ "${height}" =~ ^[0-9]+$ ]] && (( height >= target )) && return 0
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error "Timed out at height ${height}; expected at least ${target}."
      return 124
    fi
    sleep 0.25
  done
}

info_wait_for_txpool_count() {
  _control_require_args 1 "$#" 'info_wait_for_txpool_count <count> [timeout-seconds]' || return
  local target="$1" timeout_seconds="${2:-120}" started response count
  [[ "${target}" =~ ^[0-9]+$ && "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'Count and timeout must be nonnegative/positive integers.'; return 64; }
  started="$(date +%s)"
  while true; do
    response="$(_control_bootstrap_api GET /txpool/transactions 2>/dev/null || true)"
    count="$(jq -r '((.transactions // []) | length) + ((.v2transactions // []) | length)' \
      <<<"${response:-{}}" 2>/dev/null || printf '0')"
    [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= target )) && return 0
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error "Timed out with ${count} transaction(s); expected ${target}."
      return 124
    fi
    sleep 0.25
  done
}


info_wait_for_selected_height() {
  _control_require_args 1 "$#" 'info_wait_for_selected_height <height> [timeout-seconds]' || return
  local target="$1" timeout_seconds="${2:-300}" started node height all_ready
  local -a nodes
  [[ "${target}" =~ ^[0-9]+$ && "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'Height and timeout must be nonnegative/positive integers.'; return 64; }
  _control_selected_nodes nodes || return
  started="$(date +%s)"
  while true; do
    all_ready=1
    for node in "${nodes[@]}"; do
      height="$(_control_height_for_node "${node}" 2>/dev/null || printf '%s' -1)"
      [[ "${height}" =~ ^[0-9]+$ ]] && (( height >= target )) || all_ready=0
    done
    (( all_ready == 1 )) && return 0
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error "Timed out waiting for all selected nodes at height ${target}."
      return 124
    fi
    sleep 0.25
  done
}

info_assert_height() {
  _control_require_args 1 "$#" 'info_assert_height <height>' || return
  local expected="$1" actual
  actual="$(_control_height_for_node "${NODE_NAME}")" || return
  [[ "${actual}" == "${expected}" ]]
}

info_selected_heights() {
  local node height result='{}'
  local -a nodes
  _control_selected_nodes nodes || return
  for node in "${nodes[@]}"; do
    height="$(_control_height_for_node "${node}")" || return
    result="$(jq -c --arg node "${node}" --argjson height "${height}" \
      '. + {($node):$height}' <<<"${result}")"
  done
  printf '%s\n' "${result}"
}

info_assert_selected_height() {
  _control_require_args 1 "$#" 'info_assert_selected_height <height>' || return
  local expected="$1" node actual
  local -a nodes
  _control_selected_nodes nodes || return
  for node in "${nodes[@]}"; do
    actual="$(_control_height_for_node "${node}")" || return
    [[ "${actual}" == "${expected}" ]] || {
      _control_error "${node} reports height ${actual}, expected ${expected}."
      return 65
    }
  done
}

_repair_notice() {
  local state="$1"
  shift
  test_log INFO "repair:${state}" "$*"
}

info_renter_migration_snapshot() {
  local cutoff="${1:-0.75}" enter_risk="${2:-0.000001}" limit="${3:-1000}"
  local now body response
  [[ "$(_control_role_for_node "${NODE_NAME}")" == 'renterd' ]] \
    || { _control_error 'Repair observation requires renterd.'; return 69; }
  now="$(date +%s)"
  body="$(jq -cn \
    --argjson healthCutoff "${cutoff}" \
    --argjson fallbackHealthCutoff "${cutoff}" \
    --argjson enterRisk "${enter_risk}" \
    --argjson limit "${limit}" \
    --argjson nowUnix "${now}" \
    '{healthCutoff:$healthCutoff,
      fallbackHealthCutoff:$fallbackHealthCutoff,
      enterRisk:$enterRisk,
      limit:$limit,
      nowUnix:$nowUnix}')"
  response="$(_control_local_api POST /bus/slabs/migration "${body}")" || return
  jq -ce '
    if type == "array" then
      {slabs: ., responseShape: "array"}
    elif (.slabs? | type) == "array" then
      {slabs: .slabs, responseShape: "object"}
    else
      error("unsupported migration response")
    end
    | .mode = (if any(.slabs[]?; has("lossRisk") or has("recommendedCutoff") or has("reason"))
               then "risk-aware" else "fixed-health" end)
  ' <<<"${response}"
}

info_watch_renter_repairs() {
  _control_require_args 1 "$#" 'info_watch_renter_repairs <duration-seconds> [poll-seconds]' || return
  local duration="$1" interval="${2:-5}" started snapshot count previous_count=-1
  local contracts contract_count reasons health_range risk_range seen=0 endpoint_warned=0
  [[ "${duration}" =~ ^[1-9][0-9]*$ && "${interval}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'Duration and poll interval must be positive integers.'; return 64; }
  [[ "$(_control_role_for_node "${NODE_NAME}")" == 'renterd' ]] \
    || { _control_error 'Repair observation requires renterd.'; return 69; }

  contracts="$(_control_local_api GET /bus/contracts 2>/dev/null || printf '[]')"
  contract_count="$(jq -r 'if type == "array" then length elif (.contracts? | type) == "array" then .contracts|length else 0 end' <<<"${contracts}" 2>/dev/null || printf '0')"
  if (( contract_count == 0 )); then
    _repair_notice PRECONDITION 'No renter contracts are visible; host faults cannot create a real slab repair until contracts and distributed slabs exist.'
  else
    _repair_notice PRECONDITION "Renter contracts visible=${contract_count}."
  fi
  _repair_notice ARMED "Watching renterd migration candidates for ${duration}s; fixed fallback health cutoff=0.75, risk entry threshold=0.000001. Native autopilot.migrator logs remain authoritative for execution."

  started="$(date +%s)"
  while (( $(date +%s) - started < duration )); do
    if ! snapshot="$(info_renter_migration_snapshot 0.75 0.000001 1000 2>/dev/null)"; then
      if (( endpoint_warned == 0 )); then
        _repair_notice NOTICE 'The migration-candidate API could not be read; inspect native renterd autopilot.migrator output for repair execution.'
        endpoint_warned=1
      fi
      sleep "${interval}"
      continue
    fi

    count="$(jq -r '.slabs | length' <<<"${snapshot}")"
    if (( count > 0 )); then
      reasons="$(jq -r '[.slabs[] | (.reason // "fixed-health")] | unique | join(",")' <<<"${snapshot}")"
      health_range="$(jq -r '[.slabs[] | .health? // empty] as $h | if ($h|length)>0 then "health="+(($h|min)|tostring)+".."+(($h|max)|tostring) else "health=n/a" end' <<<"${snapshot}")"
      risk_range="$(jq -r '[.slabs[] | .lossRisk? // empty] as $r | if ($r|length)>0 then "lossRisk="+(($r|min)|tostring)+".."+(($r|max)|tostring) else "lossRisk=n/a" end' <<<"${snapshot}")"
      if (( seen == 0 )); then
        _repair_notice TRIGGERED "renterd exposed ${count} migration candidate(s); mode=$(jq -r '.mode' <<<"${snapshot}"); reasons=${reasons}; ${health_range}; ${risk_range}."
        seen=1
      elif (( count != previous_count )); then
        _repair_notice PROGRESS "Pending migration candidates changed ${previous_count}->${count}; reasons=${reasons}; ${health_range}; ${risk_range}."
      fi
    elif (( previous_count > 0 )); then
      _repair_notice CLEARED 'The renterd migration-candidate queue is empty again.'
    fi
    previous_count="${count}"
    sleep "${interval}"
  done

  if (( seen == 0 )); then
    _repair_notice NOT-OBSERVED 'No slab entered renterd migration candidates during this observation window.'
  fi
}
