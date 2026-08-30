#!/usr/bin/env bash

test_log() {
  local severity="${1:-INFO}"
  local component="${2:-runtime}"
  shift 2 || true

  printf '%s %-8s [%s][%s] %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S.%3N')" \
    "${severity}" \
    "${NODE_NAME:-runner}" \
    "${component}" \
    "$*" >&2
}

_control_error() {
  test_log ERROR control "$*"
}

_control_require_args() {
  local required="$1" actual="$2" usage="$3"
  if (( actual < required )); then
    _control_error "Usage: ${usage}"
    return 64
  fi
}

_control_role_for_node() {
  case "$1" in
    node01|node02) printf 'renterd\n' ;;
    node03|node04|node05|node06) printf 'hostd\n' ;;
    node07|node08) printf 'walletd\n' ;;
    *) return 64 ;;
  esac
}

_control_selected_nodes() {
  local destination="$1" node
  local -a parsed
  read -r -a parsed <<<"${LAB_NODES:-}"
  (( ${#parsed[@]} > 0 )) || return 64
  for node in "${parsed[@]}"; do
    [[ "${node}" =~ ^node0[1-8]$ ]] || return 64
  done
  local -n output="${destination}"
  output=("${parsed[@]}")
}

_control_node_is_selected() {
  local requested="$1" node
  local -a nodes
  _control_selected_nodes nodes || return
  for node in "${nodes[@]}"; do
    [[ "${node}" == "${requested}" ]] && return 0
  done
  return 1
}

_control_bootstrap_node() {
  local candidate
  local -a nodes
  _control_selected_nodes nodes || return
  for candidate in node07 node08; do
    _control_node_is_selected "${candidate}" && { printf '%s\n' "${candidate}"; return 0; }
  done
  printf '%s\n' "${nodes[0]}"
}

_control_bootstrap_http_address() {
  local bootstrap role host
  bootstrap="$(_control_bootstrap_node)" || return
  role="$(_control_role_for_node "${bootstrap}")" || return
  host="${bootstrap}"
  [[ "${bootstrap}" == "${NODE_NAME:-}" ]] && host='127.0.0.1'
  if [[ "${role}" == 'walletd' ]]; then
    printf '%s:9980\n' "${host}"
  else
    printf '%s:10980\n' "${host}"
  fi
}

_control_bootstrap_peer_address() {
  local bootstrap role
  bootstrap="$(_control_bootstrap_node)" || return
  role="$(_control_role_for_node "${bootstrap}")" || return
  if [[ "${role}" == 'walletd' ]]; then
    printf '%s:9981\n' "${bootstrap}"
  else
    printf '%s:10981\n' "${bootstrap}"
  fi
}

_control_curl() {
  local method="$1" url="$2" body="${3:-}"
  local -a arguments
  arguments=(
    --silent --show-error --fail-with-body
    --connect-timeout 5 --max-time 60
    --user ":${SIA_API_PASSWORD:-lab-api-password}"
    --request "${method}"
    --header 'Accept: application/json'
  )
  if [[ -n "${body}" ]]; then
    arguments+=(--header 'Content-Type: application/json' --data "${body}")
  fi
  curl "${arguments[@]}" "${url}"
}

_control_node_api() {
  local node="$1" method="$2" path="$3" body="${4:-}" host
  host="${node}"
  [[ "${node}" == "${NODE_NAME:-}" ]] && host='127.0.0.1'
  _control_curl "${method}" "http://${host}:9980/api${path}" "${body}"
}

_control_local_api() {
  _control_node_api "${NODE_NAME}" "$@"
}

_control_bootstrap_api() {
  local method="$1" path="$2" body="${3:-}" address
  address="$(_control_bootstrap_http_address)" || return
  _control_curl "${method}" "http://${address}/api${path}" "${body}"
}

_control_height_for_node() {
  local node="$1" role response
  role="$(_control_role_for_node "${node}")" || return
  case "${role}" in
    renterd)
      response="$(_control_node_api "${node}" GET /bus/consensus/state)" || return
      jq -er '.blockHeight' <<<"${response}"
      ;;
    hostd|walletd)
      response="$(_control_node_api "${node}" GET /consensus/tip)" || return
      jq -er '.height' <<<"${response}"
      ;;
  esac
}

_control_tip_for_node() {
  local node="$1" role response height
  role="$(_control_role_for_node "${node}")" || return
  case "${role}" in
    renterd)
      response="$(_control_node_api "${node}" GET /bus/consensus/state)" || return
      height="$(jq -er '.blockHeight' <<<"${response}")" || return
      jq -cn --argjson height "${height}" --arg role "${role}" \
        '{height:$height,id:null,role:$role}'
      ;;
    hostd|walletd)
      response="$(_control_node_api "${node}" GET /consensus/tip)" || return
      jq -c --arg role "${role}" '{height:.height,id:.id,role:$role}' <<<"${response}"
      ;;
  esac
}

_control_peers_for_node() {
  local node="$1" role
  role="$(_control_role_for_node "${node}")" || return
  case "${role}" in
    renterd) _control_node_api "${node}" GET /bus/syncer/peers ;;
    hostd|walletd) _control_node_api "${node}" GET /syncer/peers ;;
  esac
}

_control_peer_count_for_node() {
  _control_peers_for_node "$1" | jq -er 'length'
}

_control_wallet_for_node() {
  local node="$1" role
  role="$(_control_role_for_node "${node}")" || return
  case "${role}" in
    renterd) _control_node_api "${node}" GET /bus/wallet ;;
    hostd) _control_node_api "${node}" GET /wallet ;;
    walletd) return 69 ;;
  esac
}

_control_wallet_address_for_node() {
  _control_wallet_for_node "$1" | jq -er '.address | select(type == "string" and length > 0)'
}

_control_resolve_ipv4() {
  getent ahostsv4 "$1" | awk 'NR == 1 { print $1; exit }'
}

_control_json_string() {
  jq -cn --arg value "$1" '$value'
}
