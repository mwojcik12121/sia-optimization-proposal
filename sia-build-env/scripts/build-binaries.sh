#!/usr/bin/env bash
set -Eeuo pipefail

readonly SRC_DIR=/workspace/src
readonly OUTPUT_DIR=/out

compile_fail() {
  printf '[source-build][ERROR] %s\n' "$*" >&2
  exit 1
}

compile_ensure_git_metadata() {
  local repository="$1" directory="${SRC_DIR}/$1"
  if git -C "${directory}" log -1 --format=%H >/dev/null 2>&1; then
    return 0
  fi

  rm -rf "${directory}/.git"
  git -C "${directory}" init -q
  git -C "${directory}" config user.name 'Sia local builder'
  git -C "${directory}" config user.email 'local-builder@invalid'
  git -C "${directory}" add -A
  GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' \
  GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
    git -C "${directory}" commit -q -m 'Temporary build metadata'
  printf '[source-build] %s has no portable Git metadata; using temporary build-only metadata for go generate.\n' "${repository}" >&2
}

compile_generate() {
  local repository="$1"
  case "${RUN_GO_GENERATE:-1}" in
    0) return 0 ;;
    1)
      compile_ensure_git_metadata "${repository}"
      (cd "${SRC_DIR}/${repository}" && go generate ./...)
      ;;
    *) compile_fail 'RUN_GO_GENERATE must be 0 or 1.' ;;
  esac
}

compile_daemon() {
  local repository="$1" package="$2" output="$3"
  local -a arguments
  compile_generate "${repository}"
  arguments=(-p "${BUILD_JOBS}" -buildvcs=false -tags 'netgo timetzdata' -trimpath)
  if [[ "${SIA_BUILD_STATIC:-1}" == '1' ]]; then
    arguments+=(-a -ldflags '-s -w -linkmode external -extldflags "-static"')
  else
    arguments+=(-ldflags '-s -w')
  fi
  printf '[source-build] Compiling %s\n' "${output}" >&2
  (cd "${SRC_DIR}/${repository}" && CGO_ENABLED=1 go build "${arguments[@]}" -o "${OUTPUT_DIR}/${output}" "${package}")
  [[ -x "${OUTPUT_DIR}/${output}" ]] || compile_fail "${output} was not produced."
}

[[ "${BUILD_JOBS:-}" =~ ^[1-9][0-9]*$ ]] || compile_fail 'BUILD_JOBS must be a positive integer.'
[[ "${SIA_BUILD_STATIC:-1}" == '0' || "${SIA_BUILD_STATIC:-1}" == '1' ]] \
  || compile_fail 'SIA_BUILD_STATIC must be 0 or 1.'
source /workspace/build.env
export GOMAXPROCS="${BUILD_JOBS}"
mkdir -p "${OUTPUT_DIR}"
compile_daemon "${HOSTD_REPO}" ./cmd/hostd hostd
compile_daemon "${RENTERD_REPO}" ./cmd/renterd renterd
compile_daemon "${WALLETD_REPO}" ./cmd/walletd walletd
printf '%s\n' "${BUILD_TAG}" >"${OUTPUT_DIR}/BUILD_TAG"
