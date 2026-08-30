#!/usr/bin/env bash

readonly NETWORK_INTERFACE="${NETWORK_INTERFACE:-eth0}"
readonly _SIA_LAB_INPUT_CHAIN='SIA_LAB_INPUT'
readonly _SIA_LAB_OUTPUT_CHAIN='SIA_LAB_OUTPUT'

network_notice() {
  printf '[%s][fault] %s\n' "${NODE_NAME:-unknown}" "$*" >&2
}

_network_require_admin() {
  if ! tc qdisc show dev "${NETWORK_INTERFACE}" >/dev/null 2>&1; then
    network_notice "NET_ADMIN is unavailable or interface ${NETWORK_INTERFACE} does not exist."
    return 77
  fi
}

_network_ensure_chains() {
  iptables -N "${_SIA_LAB_INPUT_CHAIN}" 2>/dev/null || true
  iptables -N "${_SIA_LAB_OUTPUT_CHAIN}" 2>/dev/null || true
  iptables -C INPUT -i "${NETWORK_INTERFACE}" -j "${_SIA_LAB_INPUT_CHAIN}" 2>/dev/null \
    || iptables -I INPUT 1 -i "${NETWORK_INTERFACE}" -j "${_SIA_LAB_INPUT_CHAIN}"
  iptables -C OUTPUT -o "${NETWORK_INTERFACE}" -j "${_SIA_LAB_OUTPUT_CHAIN}" 2>/dev/null \
    || iptables -I OUTPUT 1 -o "${NETWORK_INTERFACE}" -j "${_SIA_LAB_OUTPUT_CHAIN}"
}

network_delay() {
  _control_require_args 1 "$#" 'network_delay <milliseconds> [jitter-ms] [correlation-percent]' || return
  _network_require_admin || return
  local delay="$1" jitter="${2:-0}" correlation="${3:-0}"
  network_notice "Applying egress delay ${delay}ms, jitter ${jitter}ms, correlation ${correlation}% on ${NETWORK_INTERFACE}."
  tc qdisc replace dev "${NETWORK_INTERFACE}" root netem \
    delay "${delay}ms" "${jitter}ms" "${correlation}%"
}

network_latency() {
  network_delay "$@"
}

network_loss() {
  _control_require_args 1 "$#" 'network_loss <percent> [correlation-percent]' || return
  _network_require_admin || return
  local loss="$1" correlation="${2:-0}"
  network_notice "Applying egress packet loss ${loss}% with correlation ${correlation}% on ${NETWORK_INTERFACE}."
  tc qdisc replace dev "${NETWORK_INTERFACE}" root netem loss "${loss}%" "${correlation}%"
}

network_duplicate() {
  _control_require_args 1 "$#" 'network_duplicate <percent>' || return
  _network_require_admin || return
  network_notice "Applying egress packet duplication $1% on ${NETWORK_INTERFACE}."
  tc qdisc replace dev "${NETWORK_INTERFACE}" root netem duplicate "$1%"
}

network_corrupt() {
  _control_require_args 1 "$#" 'network_corrupt <percent>' || return
  _network_require_admin || return
  network_notice "Applying egress packet corruption $1% on ${NETWORK_INTERFACE}."
  tc qdisc replace dev "${NETWORK_INTERFACE}" root netem corrupt "$1%"
}

network_reorder() {
  _control_require_args 1 "$#" 'network_reorder <percent> [correlation-percent] [gap]' || return
  _network_require_admin || return
  local percent="$1" correlation="${2:-0}" gap="${3:-5}"
  network_notice "Applying packet reordering ${percent}% correlation ${correlation}% gap ${gap}."
  tc qdisc replace dev "${NETWORK_INTERFACE}" root netem \
    delay 10ms reorder "${percent}%" "${correlation}%" gap "${gap}"
}

network_rate() {
  _control_require_args 1 "$#" 'network_rate <kilobits-per-second>' || return
  _network_require_admin || return
  network_notice "Limiting egress rate to $1 kbit/s on ${NETWORK_INTERFACE}."
  tc qdisc replace dev "${NETWORK_INTERFACE}" root netem rate "$1kbit"
}

network_profile() {
  _control_require_args 4 "$#" 'network_profile <delay-ms> <jitter-ms> <loss-percent> <rate-kbit>' || return
  _network_require_admin || return
  network_notice "Applying combined profile: delay=$1ms jitter=$2ms loss=$3% rate=$4kbit."
  tc qdisc replace dev "${NETWORK_INTERFACE}" root netem \
    delay "$1ms" "$2ms" loss "$3%" rate "$4kbit"
}

network_clear_impairment() {
  _network_require_admin || return
  network_notice "Removing all tc/netem delay, loss, corruption, duplication, reordering, and rate controls."
  tc qdisc del dev "${NETWORK_INTERFACE}" root 2>/dev/null || true
}

network_partition_peer() {
  _control_require_args 1 "$#" 'network_partition_peer <node-name|ipv4>' || return
  _network_require_admin || return
  local peer="$1" ip
  if [[ "${peer}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="${peer}"
  else
    ip="$(_control_resolve_ipv4 "${peer}")"
  fi
  [[ -n "${ip}" ]] || { network_notice "Could not resolve ${peer}; partition not applied."; return 1; }
  _network_ensure_chains
  network_notice "Partitioning this node from ${peer} (${ip}) in both directions."
  iptables -C "${_SIA_LAB_OUTPUT_CHAIN}" -d "${ip}" -j DROP 2>/dev/null \
    || iptables -A "${_SIA_LAB_OUTPUT_CHAIN}" -d "${ip}" -j DROP
  iptables -C "${_SIA_LAB_INPUT_CHAIN}" -s "${ip}" -j DROP 2>/dev/null \
    || iptables -A "${_SIA_LAB_INPUT_CHAIN}" -s "${ip}" -j DROP
}

network_heal_peer() {
  _control_require_args 1 "$#" 'network_heal_peer <node-name|ipv4>' || return
  _network_require_admin || return
  local peer="$1" ip
  if [[ "${peer}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="${peer}"
  else
    ip="$(_control_resolve_ipv4 "${peer}")"
  fi
  [[ -n "${ip}" ]] || { network_notice "Could not resolve ${peer}; no peer rule removed."; return 1; }
  _network_ensure_chains
  network_notice "Healing partition with ${peer} (${ip})."
  while iptables -D "${_SIA_LAB_OUTPUT_CHAIN}" -d "${ip}" -j DROP 2>/dev/null; do :; done
  while iptables -D "${_SIA_LAB_INPUT_CHAIN}" -s "${ip}" -j DROP 2>/dev/null; do :; done
}

network_partition_all() {
  _network_require_admin || return
  _network_ensure_chains
  network_notice "Blocking all ingress and egress on ${NETWORK_INTERFACE}; loopback remains available."
  iptables -C "${_SIA_LAB_OUTPUT_CHAIN}" -j DROP 2>/dev/null \
    || iptables -A "${_SIA_LAB_OUTPUT_CHAIN}" -j DROP
  iptables -C "${_SIA_LAB_INPUT_CHAIN}" -j DROP 2>/dev/null \
    || iptables -A "${_SIA_LAB_INPUT_CHAIN}" -j DROP
}

network_heal_all() {
  _network_require_admin || return
  _network_ensure_chains
  network_notice "Removing every lab-created partition rule."
  iptables -F "${_SIA_LAB_INPUT_CHAIN}"
  iptables -F "${_SIA_LAB_OUTPUT_CHAIN}"
}

network_partition_peer_for() {
  _control_require_args 2 "$#" 'network_partition_peer_for <node-name|ipv4> <seconds>' || return
  local peer="$1" seconds="$2"
  network_partition_peer "${peer}"
  network_notice "Holding the partition with ${peer} for ${seconds} second(s)."
  sleep "${seconds}"
  network_heal_peer "${peer}"
}

network_delay_for() {
  _control_require_args 2 "$#" 'network_delay_for <delay-ms> <seconds> [jitter-ms] [correlation-percent]' || return
  local delay="$1" seconds="$2" jitter="${3:-0}" correlation="${4:-0}"
  network_delay "${delay}" "${jitter}" "${correlation}"
  network_notice "Holding the delay profile for ${seconds} second(s)."
  sleep "${seconds}"
  network_clear_impairment
}

network_reset() {
  _network_require_admin || return
  network_notice "Resetting every lab-created traffic impairment and partition."
  tc qdisc del dev "${NETWORK_INTERFACE}" root 2>/dev/null || true
  _network_ensure_chains
  iptables -F "${_SIA_LAB_INPUT_CHAIN}"
  iptables -F "${_SIA_LAB_OUTPUT_CHAIN}"
}
