#!/usr/bin/env bash
set -Eeuo pipefail

readonly SRC_DIR=/workspace/src
readonly OUTPUT_DIR=/out
UNMODIFIED_HELP=''
MODIFIED_HELP=''

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
  local repository="$1" workspace="$2"
  case "${RUN_GO_GENERATE:-1}" in
    0) return 0 ;;
    1)
      compile_ensure_git_metadata "${repository}"
      (cd "${SRC_DIR}/${repository}" && GOWORK="${workspace}" go generate ./...)
      ;;
    *) compile_fail 'RUN_GO_GENERATE must be 0 or 1.' ;;
  esac
}

compile_daemon() {
  local repository="$1" package="$2" output="$3" workspace="$4"
  local -a arguments
  compile_generate "${repository}" "${workspace}"
  arguments=(-p "${BUILD_JOBS}" -buildvcs=false -tags 'netgo timetzdata' -trimpath)
  if [[ "${SIA_BUILD_STATIC:-1}" == '1' ]]; then
    arguments+=(-a -ldflags '-s -w -linkmode external -extldflags "-static"')
  else
    arguments+=(-ldflags '-s -w')
  fi
  printf '[source-build] Compiling %s\n' "${output}" >&2
  (cd "${SRC_DIR}/${repository}" && GOWORK="${workspace}" CGO_ENABLED=1 go build "${arguments[@]}" -o "${OUTPUT_DIR}/${output}" "${package}")
  [[ -x "${OUTPUT_DIR}/${output}" ]] || compile_fail "${output} was not produced."
}

[[ "${BUILD_JOBS:-}" =~ ^[1-9][0-9]*$ ]] || compile_fail 'BUILD_JOBS must be a positive integer.'
[[ "${SIA_BUILD_STATIC:-1}" == '0' || "${SIA_BUILD_STATIC:-1}" == '1' ]] \
  || compile_fail 'SIA_BUILD_STATIC must be 0 or 1.'
source /workspace/build.env
export GOMAXPROCS="${BUILD_JOBS}"
mkdir -p "${OUTPUT_DIR}"
compile_daemon "${HOSTD_REPO}" ./cmd/hostd hostd "${UNMODIFIED_GOWORK}"
compile_daemon \
  "${RENTERD_UNMODIFIED_REPO}" ./cmd/renterd renterd-unmodified "${UNMODIFIED_GOWORK}"
compile_daemon \
  "${RENTERD_MODIFIED_REPO}" ./cmd/renterd renterd-modified "${MODIFIED_GOWORK}"
compile_daemon "${WALLETD_REPO}" ./cmd/walletd walletd "${UNMODIFIED_GOWORK}"

UNMODIFIED_HELP="$("${OUTPUT_DIR}/renterd-unmodified" -h 2>&1)" \
  || compile_fail 'Could not inspect renterd-unmodified.'
MODIFIED_HELP="$("${OUTPUT_DIR}/renterd-modified" -h 2>&1)" \
  || compile_fail 'Could not inspect renterd-modified.'
if [[ "${UNMODIFIED_HELP}" == *autopilot.slabRisk.enabled* ]]; then
  compile_fail 'renterd-unmodified unexpectedly exposes slab-risk configuration flags.'
fi
[[ "${MODIFIED_HELP}" == *autopilot.slabRisk.enabled* ]] \
  || compile_fail 'renterd-modified does not expose slab-risk configuration flags.'

printf '%s\n' "${BUILD_TAG}" >"${OUTPUT_DIR}/BUILD_TAG"
cat >"${OUTPUT_DIR}/BUILD_MANIFEST" <<MANIFEST
format=1
build_tag=${BUILD_TAG}
core_repo=${CORE_REPO}
coreutils_repo=${COREUTILS_REPO}
hostd_repo=${HOSTD_REPO}
renterd_unmodified_repo=${RENTERD_UNMODIFIED_REPO}
renterd_modified_repo=${RENTERD_MODIFIED_REPO}
walletd_repo=${WALLETD_REPO}
MANIFEST
(cd "${OUTPUT_DIR}" && sha256sum hostd renterd-unmodified renterd-modified walletd >SHA256SUMS)
