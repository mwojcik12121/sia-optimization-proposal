#!/usr/bin/env bash

readonly NETWORK_INTERFACE="${NETWORK_INTERFACE:-eth0}"
readonly _SIA_LAB_INPUT_CHAIN='SIA_LAB_INPUT'
readonly _SIA_LAB_OUTPUT_CHAIN='SIA_LAB_OUTPUT'

network_notice() {
  test_log INFO network "$*"
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

network_clear_impairment() {
  _network_require_admin || return
  network_notice "Removing all tc/netem delay, loss, corruption, duplication, reordering, and rate controls."
  tc qdisc del dev "${NETWORK_INTERFACE}" root 2>/dev/null || true
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
