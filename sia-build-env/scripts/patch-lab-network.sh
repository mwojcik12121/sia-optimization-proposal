#!/usr/bin/env bash
set -Eeuo pipefail

patch_fail() {
  printf '[lab-network][ERROR] %s\n' "$*" >&2
  exit 1
}

patch_testnet_zen() {
  local file="$1" temporary
  [[ -f "${file}" ]] || patch_fail "network source is missing: ${file}"
  temporary="${file}.lab.tmp"
  awk '
    function indent(line) {
      match(line, /^[ \t]*/)
      return substr(line, 1, RLENGTH)
    }
    /^func TestnetZen\(\)/ { in_zen = 1 }
    in_zen && /^func / && !/^func TestnetZen\(\)/ { in_zen = 0 }
    in_zen && /InitialTarget:[[:space:]]*/ {
      print indent($0) "InitialTarget:   types.BlockID{0: 0xFF},"
      initial_target++
      next
    }
    in_zen && /BlockInterval:[[:space:]]*/ {
      print indent($0) "BlockInterval:   250 * time.Millisecond,"
      block_interval++
      next
    }
    in_zen && /MaturityDelay:[[:space:]]*/ {
      print indent($0) "MaturityDelay:   10,"
      maturity_delay++
      next
    }
    in_zen && /OakTime:[[:space:]]*/ {
      print indent($0) "OakTime:     1 * time.Second,"
      oak_time++
      next
    }
    in_zen && /OakTarget:[[:space:]]*/ {
      print indent($0) "OakTarget:   types.BlockID{0: 0xFF},"
      oak_target++
      next
    }
    in_zen && /NonceFactor:[[:space:]]*/ {
      print indent($0) "NonceFactor: 1,"
      nonce_factor++
      next
    }
    { print }
    END {
      if (initial_target != 1 || block_interval != 1 || maturity_delay != 1 ||
          oak_time != 1 || oak_target != 1 || nonce_factor != 1) {
        printf "replacement counts: target=%d interval=%d maturity=%d oakTime=%d oakTarget=%d nonce=%d\n", \
          initial_target, block_interval, maturity_delay, oak_time, oak_target, nonce_factor > "/dev/stderr"
        exit 65
      }
    }
  ' "${file}" >"${temporary}" || {
    rm -f "${temporary}"
    patch_fail 'TestnetZen layout is unsupported; update the lab patch for this coreutils revision.'
  }
  mv "${temporary}" "${file}"
  printf '[lab-network] Patched copied TestnetZen parameters for the private 200-block lab.\n' >&2
}

(( $# == 1 )) || patch_fail 'Usage: patch-lab-network.sh /path/to/coreutils/chain/network.go'
patch_testnet_zen "$1"
