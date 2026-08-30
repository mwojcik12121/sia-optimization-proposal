#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MODULE_CACHE="${ROOT_DIR}/src/.gomodcache"
readonly SRC_DIR="${ROOT_DIR}/src"
readonly BUILD_ENV="${ROOT_DIR}/build.env"

dependency_fail() {
  printf '[dependencies][ERROR] %s\n' "$*" >&2
  exit 1
}

dependency_prepare_image() {
  local image="${GO_BUILDER_IMAGE:-golang:1.26-bookworm}"
  docker image inspect "${image}" >/dev/null 2>&1 && return 0
  [[ "${AUTO_PULL_BUILDER_IMAGE:-1}" == '1' ]] \
    || dependency_fail "Builder image ${image} is not available."
  docker pull "${image}"
}

dependency_fill_cache() {
  local image uid gid
  image="${GO_BUILDER_IMAGE:-golang:1.26-bookworm}"
  uid="$(id -u)"
  gid="$(id -g)"
  mkdir -p "${MODULE_CACHE}"
  docker run --rm \
    --network=bridge \
    --user "${uid}:${gid}" \
    --env HOME=/tmp/home \
    --env GOCACHE=/tmp/go-build \
    --env GOMODCACHE=/gomodcache \
    --env "GOPROXY=${GO_DEPENDENCY_PROXY:-https://proxy.golang.org,direct}" \
    --env "GOSUMDB=${GO_DEPENDENCY_SUMDB:-sum.golang.org}" \
    --env GOTOOLCHAIN=local \
    --env "RUN_GO_GENERATE=${RUN_GO_GENERATE:-1}" \
    --env "CORE_REPO=${CORE_REPO}" \
    --env "COREUTILS_REPO=${COREUTILS_REPO}" \
    --env "HOSTD_REPO=${HOSTD_REPO}" \
    --env "RENTERD_REPO=${RENTERD_REPO}" \
    --env "WALLETD_REPO=${WALLETD_REPO}" \
    --volume "${ROOT_DIR}/src:/input:ro" \
    --volume "${MODULE_CACHE}:/gomodcache" \
    --volume "${ROOT_DIR}/scripts/fill-module-cache.sh:/fill-module-cache.sh:ro" \
    "${image}" /bin/bash /fill-module-cache.sh
}

source_fail() {
  printf '[source-build][ERROR] %s\n' "$*" >&2
  exit 1
}

source_create_workspace() {
  local go_mod directory relative count=0
  rm -f "${SRC_DIR}/go.work" "${SRC_DIR}/go.work.sum"
  (cd "${SRC_DIR}" && go work init)
  while IFS= read -r -d '' go_mod; do
    directory="$(dirname "${go_mod}")"
    relative="$(realpath --relative-to="${SRC_DIR}" "${directory}")"
    (cd "${SRC_DIR}" && go work use "./${relative}")
    count=$((count + 1))
  done < <(find "${SRC_DIR}" -mindepth 2 -maxdepth 2 -type f -name go.mod -print0 | sort -z)
  (( count >= 5 )) || source_fail 'At least five source modules are required.'
}

source_prepare_dependencies() {
  local variable
  for variable in CORE_REPO COREUTILS_REPO HOSTD_REPO RENTERD_REPO WALLETD_REPO; do
    [[ -n "${!variable:-}" ]] || source_fail "${variable} is not set."
    [[ -f "${SRC_DIR}/${!variable}/go.mod" ]] || source_fail "src/${!variable}/go.mod is missing."
  done

  case "${APPLY_LAB_NETWORK_PATCH:-1}" in
    1) "${ROOT_DIR}/scripts/patch-lab-network.sh" "${SRC_DIR}/${COREUTILS_REPO}/chain/network.go" ;;
    0) ;;
    *) source_fail 'APPLY_LAB_NETWORK_PATCH must be 0 or 1.' ;;
  esac

  source_create_workspace
  cat >"${BUILD_ENV}" <<ENV
export GOWORK='${SRC_DIR}/go.work'
export GOMODCACHE='${SRC_DIR}/.gomodcache'
export GOFLAGS='-mod=readonly'
export GOPROXY='off'
export GOSUMDB='off'
export GOTOOLCHAIN='local'
ENV
}

(( $# == 1 )) || dependency_fail 'Usage: prepare-dependencies.sh cache|sources'
case "$1" in
  cache)
    command -v docker >/dev/null 2>&1 || dependency_fail 'docker is required.'
    dependency_prepare_image
    dependency_fill_cache
    ;;
  sources)
    source_prepare_dependencies
    ;;
  *) dependency_fail 'Usage: prepare-dependencies.sh cache|sources' ;;
esac
