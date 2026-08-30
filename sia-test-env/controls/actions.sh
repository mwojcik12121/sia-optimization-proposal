#!/usr/bin/env bash

_action_require_role() {
  local required="$1" actual
  actual="$(_control_role_for_node "${NODE_NAME}")" || return
  if [[ "${actual}" != "${required}" ]]; then
    _control_error "This action requires ${required}; current primary daemon is ${actual}."
    return 69
  fi
}

_action_default_miner_address() {
  local node role address
  local -a nodes
  _control_selected_nodes nodes || return
  for node in "${nodes[@]}"; do
    role="$(_control_role_for_node "${node}")" || continue
    [[ "${role}" == 'hostd' || "${role}" == 'renterd' ]] || continue
    address="$(_control_wallet_address_for_node "${node}" 2>/dev/null || true)"
    if [[ -n "${address}" ]]; then
      printf '%s\n' "${address}"
      return 0
    fi
  done
  return 69
}

action_mine_blocks() {
  _control_require_args 1 "$#" 'action_mine_blocks <count> [reward-address]' || return
  local count="$1" address="${2:-}" body
  [[ "${count}" =~ ^[1-9][0-9]*$ ]] || { _control_error 'Block count must be positive.'; return 64; }
  if [[ -z "${address}" ]]; then
    address="$(_action_default_miner_address)" || {
      _control_error 'No hostd or renterd wallet address is available for the reward.'
      return 69
    }
  fi
  body="$(jq -cn --argjson blocks "${count}" --arg address "${address}"     '{blocks:$blocks,address:$address}')"
  _control_bootstrap_api POST /debug/mine "${body}" >/dev/null
}

action_wallet_address() {
  _control_wallet_address_for_node "${NODE_NAME}"
}

action_send_siacoins() {
  _control_require_args 2 "$#" 'action_send_siacoins <address> <hastings> [subtract-fee]' || return
  local address="$1" amount="$2" subtract="${3:-false}" role body
  [[ "${amount}" =~ ^[0-9]+$ ]] || { _control_error 'Amount must be decimal hastings.'; return 64; }
  [[ "${subtract}" == 'true' || "${subtract}" == 'false' ]] \
    || { _control_error 'subtract-fee must be true or false.'; return 64; }
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  body="$(jq -cn --arg address "${address}" --arg amount "${amount}" --argjson subtract "${subtract}" \
    '{address:$address,amount:$amount,subtractMinerFee:$subtract}')"
  case "${role}" in
    hostd) _control_local_api POST /wallet/send "${body}" ;;
    renterd)
      body="$(jq -c '. + {useUnconfirmed:false}' <<<"${body}")"
      _control_local_api POST /bus/wallet/send "${body}"
      ;;
    walletd)
      _control_error 'walletd is key-agnostic; use a hostd or renterd node to sign transactions.'
      return 69
      ;;
  esac
}

action_create_transaction() {
  _control_require_args 2 "$#" 'action_create_transaction <address> <hastings>' || return
  action_send_siacoins "$1" "$2"
}

action_validate_transaction_json() {
  _control_require_args 1 "$#" 'action_validate_transaction_json <json-or-file>' || return
  local input="$1" json
  if [[ -f "${input}" ]]; then
    json="$(cat "${input}")"
  else
    json="${input}"
  fi
  jq -e 'type == "object" and
    (has("siacoinInputs") or has("siacoinOutputs") or has("minerFee") or
     has("transactions") or has("v2transactions"))' <<<"${json}" >/dev/null
}

action_broadcast_transactions() {
  _control_require_args 1 "$#" 'action_broadcast_transactions <json-or-file>' || return
  local input="$1" json
  [[ -f "${input}" ]] && json="$(cat "${input}")" || json="${input}"
  _control_bootstrap_api POST /txpool/broadcast "${json}"
}

action_connect_peer() {
  _control_require_args 1 "$#" 'action_connect_peer <nodeXX>' || return
  local peer="$1" role address body
  [[ "${peer}" =~ ^node0[1-8]$ ]] || { _control_error 'Peer must be node01 through node08.'; return 64; }
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  address="${peer}:9981"
  case "${role}" in
    hostd)
      body="$(jq -cn --arg address "${address}" '{address:$address}')"
      _control_local_api PUT /syncer/peers "${body}"
      ;;
    renterd)
      body="$(_control_json_string "${address}")"
      _control_local_api POST /bus/syncer/connect "${body}"
      ;;
    walletd)
      body="$(_control_json_string "${address}")"
      _control_local_api POST /syncer/connect "${body}"
      ;;
  esac
}

action_host_patch_settings() {
  _control_require_args 1 "$#" 'action_host_patch_settings <json-or-file>' || return
  _action_require_role hostd || return
  local input="$1" json
  [[ -f "${input}" ]] && json="$(cat "${input}")" || json="${input}"
  jq -e 'type == "object"' <<<"${json}" >/dev/null
  _control_local_api PATCH /settings "${json}"
}

action_host_announce() {
  _action_require_role hostd || return
  _control_local_api POST /settings/announce
}

action_host_add_volume() {
  _control_require_args 2 "$#" 'action_host_add_volume <absolute-path> <max-sectors>' || return
  _action_require_role hostd || return
  local path="$1" sectors="$2" body
  [[ "${path}" == /* ]] || { _control_error 'Volume path must be absolute.'; return 64; }
  [[ "${sectors}" =~ ^[1-9][0-9]*$ ]] || { _control_error 'Sector count must be positive.'; return 64; }
  mkdir -p "${path}"
  body="$(jq -cn --arg path "${path}" --argjson sectors "${sectors}" \
    '{localPath:$path,maxSectors:$sectors}')"
  _control_local_api POST /volumes "${body}"
}

action_renter_trigger_autopilot() {
  _action_require_role renterd || return
  _control_local_api POST /autopilot/trigger
}

action_renter_create_bucket() {
  _control_require_args 1 "$#" 'action_renter_create_bucket <name>' || return
  _action_require_role renterd || return
  local name="$1" body
  body="$(jq -cn --arg name "${name}" '{name:$name,policy:{publicReadAccess:false}}')"
  _control_local_api POST /bus/buckets "${body}"
}

action_renter_upload_object() {
  _control_require_args 3 "$#" 'action_renter_upload_object <bucket> <key> <file>' || return
  _action_require_role renterd || return
  local bucket="$1" key="$2" file="$3" encoded_bucket encoded_key
  [[ -f "${file}" ]] || { _control_error "Upload file does not exist: ${file}."; return 66; }
  encoded_bucket="$(jq -rn --arg value "${bucket}" '$value|@uri')"
  encoded_key="$(jq -rn --arg value "${key}" '$value|@uri')"
  curl --silent --show-error --fail-with-body \
    --connect-timeout 5 --max-time "${SCENARIO_TIMEOUT_SECONDS:-1800}" \
    --user ":${SIA_API_PASSWORD:-lab-api-password}" \
    --request PUT \
    --header 'Content-Type: application/octet-stream' \
    --data-binary "@${file}" \
    "http://127.0.0.1:9980/api/worker/object/${encoded_key}?bucket=${encoded_bucket}"
}

action_renter_download_object() {
  _control_require_args 3 "$#" 'action_renter_download_object <bucket> <key> <destination>' || return
  _action_require_role renterd || return
  local bucket="$1" key="$2" destination="$3" encoded_bucket encoded_key
  encoded_bucket="$(jq -rn --arg value "${bucket}" '$value|@uri')"
  encoded_key="$(jq -rn --arg value "${key}" '$value|@uri')"
  mkdir -p "$(dirname "${destination}")"
  curl --silent --show-error --fail-with-body \
    --connect-timeout 5 --max-time "${SCENARIO_TIMEOUT_SECONDS:-1800}" \
    --user ":${SIA_API_PASSWORD:-lab-api-password}" \
    --output "${destination}" \
    "http://127.0.0.1:9980/api/worker/object/${encoded_key}?bucket=${encoded_bucket}"
}

action_renter_delete_object() {
  _control_require_args 2 "$#" 'action_renter_delete_object <bucket> <key>' || return
  _action_require_role renterd || return
  local bucket="$1" key="$2" encoded_bucket encoded_key
  encoded_bucket="$(jq -rn --arg value "${bucket}" '$value|@uri')"
  encoded_key="$(jq -rn --arg value "${key}" '$value|@uri')"
  curl --silent --show-error --fail-with-body \
    --connect-timeout 5 --max-time 60 \
    --user ":${SIA_API_PASSWORD:-lab-api-password}" \
    --request DELETE \
    "http://127.0.0.1:9980/api/worker/object/${encoded_key}?bucket=${encoded_bucket}"
}

action_generate_test_file() {
  _control_require_args 2 "$#" 'action_generate_test_file <path> <bytes>' || return
  local path="$1" bytes="$2"
  [[ "${bytes}" =~ ^[0-9]+$ ]] || { _control_error 'Byte count must be a nonnegative integer.'; return 64; }
  mkdir -p "$(dirname "${path}")"
  head -c "${bytes}" /dev/zero >"${path}"
}

action_api_call() {
  _control_require_args 2 "$#" 'action_api_call <method> <path> [json]' || return
  _control_local_api "$1" "$2" "${3:-}"
}

action_pause_primary_daemon_for() {
  _control_require_args 1 "$#" 'action_pause_primary_daemon_for <seconds>' || return
  local seconds="$1" pid
  [[ "${seconds}" =~ ^[1-9][0-9]*$ ]] || { _control_error 'Duration must be a positive integer.'; return 64; }
  [[ -r /run/sia-lab/primary.pid ]] || { _control_error 'Primary daemon PID file is missing.'; return 66; }
  pid="$(cat /run/sia-lab/primary.pid)"
  kill -0 "${pid}" 2>/dev/null || { _control_error 'Primary daemon is not running.'; return 69; }
  printf '[%s][fault] Pausing the primary daemon for %s seconds.\n' "${NODE_NAME}" "${seconds}" >&2
  kill -STOP "${pid}"
  sleep "${seconds}"
  kill -CONT "${pid}"
  printf '[%s][fault] Primary daemon resumed.\n' "${NODE_NAME}" >&2
}
