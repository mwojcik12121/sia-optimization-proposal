#!/usr/bin/env bash

CONFIG_NODES=()
PRIMARY_PID=''
HELPER_PID=''
PRIMARY_CONFIG=''
NODE_SEED=''
NODE_ADDRESS=''

config_error() {
  printf '[%s][ERROR] %s\n' "${NODE_NAME:-unknown}" "$*" >&2
}

_config_yaml_string() {
  jq -Rn --arg value "$1" '$value'
}

config_parse_nodes() {
  _control_selected_nodes CONFIG_NODES || {
    config_error 'LAB_NODES must contain node01 through node08 names.'
    return 64
  }
}

config_generate_identity() {
  local output
  output="$(/usr/local/bin/walletd seed)" || return
  NODE_SEED="$(sed -n 's/^Recovery Phrase:[[:space:]]*//p' <<<"${output}" | head -n 1)"
  NODE_ADDRESS="$(sed -n 's/^Address[[:space:]]*//p' <<<"${output}" | head -n 1)"
  [[ -n "${NODE_SEED}" && -n "${NODE_ADDRESS}" ]] || {
    config_error 'walletd seed output did not contain a recovery phrase and address.'
    return 65
  }
  printf '%s\n' "${NODE_SEED}" >"/run/sia-lab/${NODE_NAME}.seed"
  chmod 0600 "/run/sia-lab/${NODE_NAME}.seed"
}

config_write_hostd_config() {
  local path="$1" qname qdir qseed qpassword
  qname="$(_config_yaml_string "${NODE_NAME}")"
  qdir="$(_config_yaml_string "/var/lib/sia/${NODE_NAME}")"
  qseed="$(_config_yaml_string "${NODE_SEED}")"
  qpassword="$(_config_yaml_string "${SIA_API_PASSWORD}")"
  cat >"${path}" <<YAML
name: ${qname}
directory: ${qdir}
recoveryPhrase: ${qseed}
autoOpenWebUI: false
http:
  address: ":9980"
  password: ${qpassword}
syncer:
  address: ":9981"
  bootstrap: false
  enableUPnP: false
consensus:
  network: "${SIA_NETWORK:-zen}"
  indexBatchSize: 1000
  pruneTarget: 0
explorer:
  disable: true
storage:
  enableMerkleCache: false
rhp4:
  listenAddresses:
    - protocol: tcp
      address: ":9984"
log:
  stdout:
    enabled: true
    level: info
    format: human
    enableANSI: false
  file:
    enabled: false
YAML
  mkdir -p "/var/lib/sia-host-storage/${NODE_NAME}"
}

config_write_renterd_config() {
  local path="$1" qseed qpassword qdir
  qseed="$(_config_yaml_string "${NODE_SEED}")"
  qpassword="$(_config_yaml_string "${SIA_API_PASSWORD}")"
  qdir="$(_config_yaml_string "/var/lib/sia/${NODE_NAME}")"
  cat >"${path}" <<YAML
seed: ${qseed}
directory: ${qdir}
autoOpenWebUI: false
network: "${SIA_NETWORK:-zen}"
http:
  address: ":9980"
  password: ${qpassword}
autopilot:
  enabled: true
  allowRedundantHostIPs: true
bus:
  allowPrivateIPs: true
  bootstrap: false
  gatewayAddr: ":9981"
worker:
  enabled: true
s3:
  enabled: false
explorer:
  disable: true
log:
  level: info
  stdout:
    enabled: true
    level: info
    format: human
    enableANSI: false
  file:
    enabled: false
  database:
    enabled: false
YAML
}

config_write_walletd_config() {
  local path="$1" name="$2" directory="$3" http_address="$4" peer_address="$5" index_mode="$6"
  local qname qdir qpassword
  qname="$(_config_yaml_string "${name}")"
  qdir="$(_config_yaml_string "${directory}")"
  qpassword="$(_config_yaml_string "${SIA_API_PASSWORD}")"
  cat >"${path}" <<YAML
name: ${qname}
directory: ${qdir}
autoOpenWebUI: false
debug: true
http:
  address: "${http_address}"
  password: ${qpassword}
  publicEndpoints: false
syncer:
  address: "${peer_address}"
  bootstrap: false
  enableUPnP: false
consensus:
  network: "${SIA_NETWORK:-zen}"
index:
  mode: "${index_mode}"
  batchSize: 100
log:
  level: info
  stdout:
    enabled: true
    level: info
    format: human
    enableANSI: false
  file:
    enabled: false
YAML
}

config_write_primary_config() {
  local role index_mode
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  PRIMARY_CONFIG="/run/sia-lab/${role}.yml"
  case "${role}" in
    hostd)
      config_generate_identity
      config_write_hostd_config "${PRIMARY_CONFIG}"
      ;;
    renterd)
      config_generate_identity
      config_write_renterd_config "${PRIMARY_CONFIG}"
      ;;
    walletd)
      index_mode='personal'
      [[ "${NODE_NAME}" == 'node08' ]] && index_mode='full'
      config_write_walletd_config "${PRIMARY_CONFIG}" "${NODE_NAME}" \
        "/var/lib/sia/${NODE_NAME}" ':9980' ':9981' "${index_mode}"
      ;;
  esac
  chmod 0600 "${PRIMARY_CONFIG}"
}

config_start_primary() {
  local role
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  case "${role}" in
    hostd)
      HOSTD_CONFIG_FILE="${PRIMARY_CONFIG}" \
      HOSTD_API_PASSWORD="${SIA_API_PASSWORD}" \
      HOSTD_WALLET_SEED="${NODE_SEED}" \
        /usr/local/bin/hostd --env &
      ;;
    renterd)
      RENTERD_CONFIG_FILE="${PRIMARY_CONFIG}" \
      RENTERD_API_PASSWORD="${SIA_API_PASSWORD}" \
      RENTERD_SEED="${NODE_SEED}" \
        /usr/local/bin/renterd &
      ;;
    walletd)
      WALLETD_CONFIG_FILE="${PRIMARY_CONFIG}" \
      WALLETD_API_PASSWORD="${SIA_API_PASSWORD}" \
        /usr/local/bin/walletd &
      ;;
  esac
  PRIMARY_PID=$!
  printf '%s\n' "${PRIMARY_PID}" >/run/sia-lab/primary.pid
}

config_wait_for_primary() {
  local timeout_seconds="$1" started height
  started="$(date +%s)"
  while true; do
    height="$(_control_height_for_node "${NODE_NAME}" 2>/dev/null || true)"
    if [[ "${height}" =~ ^[0-9]+$ ]]; then
      return 0
    fi
    if ! kill -0 "${PRIMARY_PID}" 2>/dev/null; then
      config_error 'Primary daemon exited before its API became ready.'
      wait "${PRIMARY_PID}" || true
      return 1
    fi
    if (( $(date +%s) - started >= timeout_seconds )); then
      config_error 'Timed out waiting for the primary daemon API.'
      return 124
    fi
    sleep 0.25
  done
}

config_wait_for_all_apis() {
  local timeout_seconds="$1" started node height all_ready
  started="$(date +%s)"
  while true; do
    all_ready=1
    for node in "${CONFIG_NODES[@]}"; do
      height="$(_control_height_for_node "${node}" 2>/dev/null || true)"
      [[ "${height}" =~ ^[0-9]+$ ]] || all_ready=0
    done
    (( all_ready == 1 )) && return 0
    if (( $(date +%s) - started >= timeout_seconds )); then
      config_error 'Timed out waiting for selected daemon APIs.'
      return 124
    fi
    sleep 0.25
  done
}

config_connect_primary_peer() {
  local peer="$1" role address body
  role="$(_control_role_for_node "${NODE_NAME}")" || return
  address="${peer}:9981"
  case "${role}" in
    hostd)
      body="$(jq -cn --arg address "${address}" '{address:$address}')"
      _control_local_api PUT /syncer/peers "${body}" >/dev/null 2>&1 || true
      ;;
    renterd)
      body="$(_control_json_string "${address}")"
      _control_local_api POST /bus/syncer/connect "${body}" >/dev/null 2>&1 || true
      ;;
    walletd)
      body="$(_control_json_string "${address}")"
      _control_local_api POST /syncer/connect "${body}" >/dev/null 2>&1 || true
      ;;
  esac
}

config_connect_primary_mesh() {
  local peer
  for peer in "${CONFIG_NODES[@]}"; do
    [[ "${peer}" == "${NODE_NAME}" ]] && continue
    [[ "${NODE_NAME}" < "${peer}" ]] || continue
    config_connect_primary_peer "${peer}"
  done
}

config_wait_for_full_mesh() {
  local timeout_seconds="$1" started expected node count all_ready
  expected=$(( ${#CONFIG_NODES[@]} - 1 ))
  (( expected == 0 )) && return 0
  started="$(date +%s)"
  while true; do
    all_ready=1
    for node in "${CONFIG_NODES[@]}"; do
      count="$(_control_peer_count_for_node "${node}" 2>/dev/null || printf '0')"
      [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= expected )) || all_ready=0
    done
    (( all_ready == 1 )) && return 0
    if (( $(date +%s) - started >= timeout_seconds )); then
      config_error 'Timed out waiting for the full primary mesh.'
      return 124
    fi
    sleep 0.5
  done
}

config_start_walletd_helper() {
  local helper_config='/run/sia-lab/bootstrap-walletd.yml' started
  rm -rf /run/sia-lab/bootstrap-walletd
  config_write_walletd_config "${helper_config}" "${NODE_NAME}-bootstrap" \
    '/run/sia-lab/bootstrap-walletd' ':10980' ':10981' personal
  chmod 0600 "${helper_config}"
  WALLETD_CONFIG_FILE="${helper_config}" \
  WALLETD_API_PASSWORD="${SIA_API_PASSWORD}" \
    /usr/local/bin/walletd &
  HELPER_PID=$!
  started="$(date +%s)"
  until _control_curl GET 'http://127.0.0.1:10980/api/consensus/tip' >/dev/null 2>&1; do
    kill -0 "${HELPER_PID}" 2>/dev/null || {
      config_error 'Bootstrap walletd helper exited before becoming ready.'
      return 1
    }
    if (( $(date +%s) - started >= 180 )); then
      config_error 'Timed out waiting for bootstrap walletd helper.'
      return 124
    fi
    sleep 0.25
  done
}

config_connect_walletd_helper() {
  local node body started count expected
  expected="${#CONFIG_NODES[@]}"
  for node in "${CONFIG_NODES[@]}"; do
    body="$(_control_json_string "${node}:9981")"
    _control_curl POST 'http://127.0.0.1:10980/api/syncer/connect' "${body}" >/dev/null 2>&1 || true
  done
  started="$(date +%s)"
  while true; do
    count="$(_control_curl GET 'http://127.0.0.1:10980/api/syncer/peers' 2>/dev/null \
      | jq -r 'length' 2>/dev/null || printf '0')"
    [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= expected )) && return 0
    if (( $(date +%s) - started >= 180 )); then
      config_error "Timed out with ${count}/${expected} helper peer connections."
      return 124
    fi
    sleep 0.5
  done
}

config_wait_for_all_heights() {
  local expected="$1" timeout_seconds="$2" started node height all_ready
  started="$(date +%s)"
  while true; do
    all_ready=1
    for node in "${CONFIG_NODES[@]}"; do
      height="$(_control_height_for_node "${node}" 2>/dev/null || printf '%s' -1)"
      if [[ "${height}" =~ ^[0-9]+$ ]] && (( height > expected )); then
        config_error "${node} overshot expected height ${expected}: ${height}."
        return 65
      fi
      [[ "${height}" == "${expected}" ]] || all_ready=0
    done
    (( all_ready == 1 )) && return 0
    if (( $(date +%s) - started >= timeout_seconds )); then
      config_error "Timed out waiting for every selected node at height ${expected}."
      return 124
    fi
    sleep 0.25
  done
}

config_verify_final_state() {
  local expected_height="$1" reference_id="$2" node role tip height tip_id
  for node in "${CONFIG_NODES[@]}"; do
    role="$(_control_role_for_node "${node}")" || return
    tip="$(_control_tip_for_node "${node}")" || return
    height="$(jq -er '.height' <<<"${tip}")" || return
    [[ "${height}" == "${expected_height}" ]] || {
      config_error "${node} reports final height ${height}, expected ${expected_height}."
      return 65
    }
    if [[ "${role}" != 'renterd' ]]; then
      tip_id="$(jq -er '.id' <<<"${tip}")" || return
      [[ "${tip_id}" == "${reference_id}" ]] || {
        config_error "${node} final tip ${tip_id} differs from bootstrap tip ${reference_id}."
        return 65
      }
    fi
  done
}

config_select_reward_address() {
  local node role address output
  for node in "${CONFIG_NODES[@]}"; do
    role="$(_control_role_for_node "${node}")" || continue
    [[ "${role}" == 'hostd' || "${role}" == 'renterd' ]] || continue
    address="$(_control_wallet_address_for_node "${node}" 2>/dev/null || true)"
    [[ -n "${address}" ]] && { printf '%s\n' "${address}"; return 0; }
  done
  output="$(/usr/local/bin/walletd seed)" || return
  address="$(sed -n 's/^Address[[:space:]]*//p' <<<"${output}" | head -n 1)"
  [[ -n "${address}" ]] || return 65
  sed -n 's/^Recovery Phrase:[[:space:]]*//p' <<<"${output}" >'/run/sia-lab/bootstrap-reward.seed'
  chmod 0600 '/run/sia-lab/bootstrap-reward.seed'
  printf '%s\n' "${address}"
}

config_mine_initial_chain() {
  local target="$1" address tip height remaining body
  address="$(config_select_reward_address)" || {
    config_error 'Could not select a reward address.'
    return 69
  }
  tip="$(_control_bootstrap_api GET /consensus/tip)" || return
  height="$(jq -er '.height' <<<"${tip}")" || return
  [[ "${height}" =~ ^[0-9]+$ ]] || {
    config_error "Bootstrap walletd returned invalid height: ${height}."
    return 65
  }
  (( height <= target )) || {
    config_error "Bootstrap walletd is already above target height ${target}: ${height}."
    return 65
  }
  remaining=$(( target - height ))
  printf '%s\n' "${address}" >'/run/sia-lab/miner-address'
  (( remaining > 0 )) || return 0
  body="$(jq -cn --argjson blocks "${remaining}" --arg address "${address}"     '{blocks:$blocks,address:$address}')"
  _control_bootstrap_api POST /debug/mine "${body}" >/dev/null
}

configure_initial_network() {
  local bootstrap role tip target timeout_seconds
  target="${INITIAL_CHAIN_HEIGHT:-200}"
  timeout_seconds="${BOOTSTRAP_TIMEOUT_SECONDS:-7200}"
  [[ "${target}" == '200' ]] || { config_error 'INITIAL_CHAIN_HEIGHT must remain 200.'; return 64; }
  config_parse_nodes
  config_wait_for_all_apis 300
  config_connect_primary_mesh
  config_wait_for_full_mesh 300

  bootstrap="$(_control_bootstrap_node)" || return
  role="$(_control_role_for_node "${bootstrap}")" || return
  if [[ "${NODE_NAME}" == "${bootstrap}" ]]; then
    if [[ "${role}" != 'walletd' ]]; then
      config_start_walletd_helper
      config_connect_walletd_helper
    fi
    config_mine_initial_chain "${target}"
  fi

  config_wait_for_all_heights "${target}" "${timeout_seconds}"
  tip="$(_control_bootstrap_api GET /consensus/tip)" || return
  config_verify_final_state "${target}" "$(jq -er '.id' <<<"${tip}")"
  printf '[%s][READY] Initial private blockchain reached height %s; tip=%s; all selected modern daemons are synchronized.\n' \
    "${NODE_NAME}" "${target}" "$(jq -r '.id' <<<"${tip}")"
  printf '%s\n' "${tip}" >'/run/sia-lab/initial-chain-tip.json'
  touch '/run/sia-lab/initial-chain-ready'
}
