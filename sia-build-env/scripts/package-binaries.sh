#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_STAGE=''

package_fail() {
  printf '[package][ERROR] %s\n' "$*" >&2
  exit 1
}

package_cleanup() {
  [[ -z "${PACKAGE_STAGE}" ]] || rm -rf "${PACKAGE_STAGE}"
}

package_create() {
  local input="$1" file archive
  for file in hostd renterd walletd BUILD_TAG; do
    [[ -f "${input}/${file}" ]] || package_fail "Missing ${input}/${file}."
  done
  PACKAGE_STAGE="$(mktemp -d)"
  mkdir -p "${ROOT_DIR}/bin"
  cp "${input}/hostd" "${input}/renterd" "${input}/walletd" "${input}/BUILD_TAG" \
    "${PACKAGE_STAGE}/"
  chmod 0755 "${PACKAGE_STAGE}/hostd" "${PACKAGE_STAGE}/renterd" "${PACKAGE_STAGE}/walletd"
  chmod 0644 "${PACKAGE_STAGE}/BUILD_TAG"
  archive="${ROOT_DIR}/bin/sia-binaries.tar.gz"
  rm -f "${archive}"
  tar -C "${PACKAGE_STAGE}" -czf "${archive}" BUILD_TAG hostd renterd walletd
}

(( $# == 1 )) || package_fail 'Usage: ./scripts/package-binaries.sh <compiled-output-directory>'
trap package_cleanup EXIT INT TERM
package_create "$1"
