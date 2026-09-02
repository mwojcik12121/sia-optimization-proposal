#!/usr/bin/env bash
set -Eeuo pipefail

readonly INPUT_ROOT=/input
readonly WORK_ROOT=/tmp/sia-dependency-work
readonly WORK_SRC="${WORK_ROOT}/src"
readonly WORKSPACES="${WORK_ROOT}/workspaces"

cache_fail() {
  printf '[dependencies][ERROR] %s\n' "$*" >&2
  exit 1
}

cache_copy_modules() {
  local repository source
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_SRC}" "${GOMODCACHE}" "${HOME}" "${GOCACHE}"
  for repository in \
    "${CORE_REPO}" \
    "${COREUTILS_REPO}" \
    "${HOSTD_REPO}" \
    "${RENTERD_UNMODIFIED_REPO}" \
    "${RENTERD_MODIFIED_REPO}" \
    "${WALLETD_REPO}"; do
    source="${INPUT_ROOT}/${repository}"
    [[ -f "${source}/go.mod" ]] || cache_fail "${source}/go.mod is missing."
    mkdir -p "${WORK_SRC}/${repository}"
    (
      cd "${source}"
      tar -cf - .
    ) | tar -C "${WORK_SRC}/${repository}" -xf -
  done
}

cache_create_workspace() {
  local name="$1" renterd_repository="$2" directory="${WORKSPACES}/$1"
  mkdir -p "${directory}"
  (
    cd "${directory}"
    go work init \
      "${WORK_SRC}/${CORE_REPO}" \
      "${WORK_SRC}/${COREUTILS_REPO}" \
      "${WORK_SRC}/${HOSTD_REPO}" \
      "${WORK_SRC}/${renterd_repository}" \
      "${WORK_SRC}/${WALLETD_REPO}"
  )
}

cache_ensure_git_metadata() {
  local repository="$1" directory="${WORK_SRC}/$1"
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
  printf '[dependencies] %s has no portable Git metadata; using temporary build-only metadata for go generate.\n' "${repository}" >&2
}

cache_run_generator() {
  local repository="$1" workspace="$2"
  cache_ensure_git_metadata "${repository}"
  (cd "${WORK_SRC}/${repository}" && GOWORK="${workspace}" go generate ./...)
}

cache_run_generators() {
  local unmodified_workspace="${WORKSPACES}/unmodified/go.work"
  local modified_workspace="${WORKSPACES}/modified/go.work"
  case "${RUN_GO_GENERATE:-1}" in
    0) return 0 ;;
    1) ;;
    *) cache_fail 'RUN_GO_GENERATE must be 0 or 1.' ;;
  esac
  cache_run_generator "${HOSTD_REPO}" "${unmodified_workspace}"
  cache_run_generator "${RENTERD_UNMODIFIED_REPO}" "${unmodified_workspace}"
  cache_run_generator "${RENTERD_MODIFIED_REPO}" "${modified_workspace}"
  cache_run_generator "${WALLETD_REPO}" "${unmodified_workspace}"
}

cache_resolve_commands() {
  local unmodified_workspace="${WORKSPACES}/unmodified/go.work"
  local modified_workspace="${WORKSPACES}/modified/go.work"
  (cd "${WORK_SRC}/${HOSTD_REPO}" && GOWORK="${unmodified_workspace}" go list -tags 'netgo timetzdata' -deps ./cmd/hostd >/dev/null)
  (cd "${WORK_SRC}/${RENTERD_UNMODIFIED_REPO}" && GOWORK="${unmodified_workspace}" go list -tags 'netgo timetzdata' -deps ./cmd/renterd >/dev/null)
  (cd "${WORK_SRC}/${RENTERD_MODIFIED_REPO}" && GOWORK="${modified_workspace}" go list -tags 'netgo timetzdata' -deps ./cmd/renterd >/dev/null)
  (cd "${WORK_SRC}/${WALLETD_REPO}" && GOWORK="${unmodified_workspace}" go list -tags 'netgo timetzdata' -deps ./cmd/walletd >/dev/null)
}

for variable in CORE_REPO COREUTILS_REPO HOSTD_REPO RENTERD_UNMODIFIED_REPO RENTERD_MODIFIED_REPO WALLETD_REPO; do
  [[ -n "${!variable:-}" ]] || cache_fail "${variable} is not set."
done
for command in go git tar; do
  command -v "${command}" >/dev/null 2>&1 || cache_fail "Missing command: ${command}."
done

export GOMODCACHE="${GOMODCACHE:-/gomodcache}"
export GOCACHE="${GOCACHE:-/tmp/go-build}"
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.org}"
export GOTOOLCHAIN=local
export GOFLAGS=-mod=readonly

cache_copy_modules
cache_create_workspace unmodified "${RENTERD_UNMODIFIED_REPO}"
cache_create_workspace modified "${RENTERD_MODIFIED_REPO}"
cache_run_generators
cache_resolve_commands
printf '[dependencies] External Go dependencies are ready.\n' >&2
