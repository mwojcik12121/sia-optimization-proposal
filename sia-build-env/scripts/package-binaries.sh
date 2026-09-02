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
  for file in hostd renterd-unmodified renterd-modified walletd BUILD_TAG BUILD_MANIFEST SHA256SUMS; do
    [[ -f "${input}/${file}" ]] || package_fail "Missing ${input}/${file}."
  done
  (cd "${input}" && sha256sum --check --strict SHA256SUMS) \
    || package_fail 'Compiled binary checksums are invalid.'
  PACKAGE_STAGE="$(mktemp -d)"
  mkdir -p "${ROOT_DIR}/bin"
  cp \
    "${input}/hostd" \
    "${input}/renterd-unmodified" \
    "${input}/renterd-modified" \
    "${input}/walletd" \
    "${input}/BUILD_TAG" \
    "${input}/BUILD_MANIFEST" \
    "${input}/SHA256SUMS" \
    "${PACKAGE_STAGE}/"
  chmod 0755 \
    "${PACKAGE_STAGE}/hostd" \
    "${PACKAGE_STAGE}/renterd-unmodified" \
    "${PACKAGE_STAGE}/renterd-modified" \
    "${PACKAGE_STAGE}/walletd"
  chmod 0644 \
    "${PACKAGE_STAGE}/BUILD_TAG" \
    "${PACKAGE_STAGE}/BUILD_MANIFEST" \
    "${PACKAGE_STAGE}/SHA256SUMS"
  archive="${ROOT_DIR}/bin/sia-binaries.tar.gz"
  rm -f "${archive}"
  tar -C "${PACKAGE_STAGE}" -czf "${archive}" \
    BUILD_TAG BUILD_MANIFEST SHA256SUMS \
    hostd renterd-unmodified renterd-modified walletd
}

(( $# == 1 )) || package_fail 'Usage: ./scripts/package-binaries.sh <compiled-output-directory>'
command -v sha256sum >/dev/null 2>&1 || package_fail 'Missing command: sha256sum.'
trap package_cleanup EXIT INT TERM
package_create "$1"
