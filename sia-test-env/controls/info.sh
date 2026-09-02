#!/usr/bin/env bash

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

info_wait_for_selected_tip() {
  _control_require_args 1 "$#" 'info_wait_for_selected_tip <height> [timeout-seconds]' || return
  local target="$1" timeout_seconds="${2:-300}" started reference_node reference_tip
  local reference_height reference_id node role tip height tip_id all_ready
  local -a nodes
  [[ "${target}" =~ ^[0-9]+$ && "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] \
    || { _control_error 'Height and timeout must be nonnegative/positive integers.'; return 64; }
  _control_selected_nodes nodes || return
  reference_node="$(_control_bootstrap_node)" || return
  started="$(date +%s)"
  while true; do
    all_ready=1
    reference_tip="$(_control_tip_for_node "${reference_node}" 2>/dev/null || true)"
    reference_height="$(jq -r '.height // -1' <<<"${reference_tip:-{}}" 2>/dev/null || printf '%s' -1)"
    reference_id="$(jq -r '.id // ""' <<<"${reference_tip:-{}}" 2>/dev/null || true)"
    [[ "${reference_height}" == "${target}" && -n "${reference_id}" ]] || all_ready=0
    if (( all_ready == 1 )); then
      for node in "${nodes[@]}"; do
        role="$(_control_role_for_node "${node}")" || { all_ready=0; continue; }
        [[ "${role}" != 'renterd' ]] || continue
        tip="$(_control_tip_for_node "${node}" 2>/dev/null || true)"
        height="$(jq -r '.height // -1' <<<"${tip:-{}}" 2>/dev/null || printf '%s' -1)"
        tip_id="$(jq -r '.id // ""' <<<"${tip:-{}}" 2>/dev/null || true)"
        [[ "${height}" == "${target}" && "${tip_id}" == "${reference_id}" ]] \
          || all_ready=0
      done
    fi
    (( all_ready == 1 )) && return 0
    if (( $(date +%s) - started >= timeout_seconds )); then
      _control_error "Timed out waiting for non-renter nodes to agree on the tip at height ${target}."
      return 124
    fi
    sleep 0.25
  done
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
      nowUnix:$nowUnix,
      useRisk:true}')"
  response="$(_control_local_api POST /bus/slabs/migration "${body}")" || return
  jq -ce '
    if type == "array" then
      {slabs: ., responseShape: "array"}
    elif type == "object" and has("slabs") and
         ((.slabs == null) or ((.slabs | type) == "array")) then
      {slabs: (.slabs // []), responseShape: "object"}
    else
      error("unsupported migration response")
    end
    | .mode = (if any(.slabs[]?; has("lossRisk") or has("recommendedCutoff") or has("reason"))
               then "risk-aware" else "fixed-health" end)
  ' <<<"${response}"
}
