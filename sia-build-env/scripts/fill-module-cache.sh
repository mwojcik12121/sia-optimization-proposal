#!/usr/bin/env bash
set -Eeuo pipefail

readonly INPUT_ROOT=/input
readonly WORK_ROOT=/tmp/sia-dependency-work
readonly WORK_SRC="${WORK_ROOT}/src"

cache_fail() {
  printf '[dependencies][ERROR] %s\n' "$*" >&2
  exit 1
}

cache_copy_modules() {
  local go_mod source name count=0
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_SRC}" "${GOMODCACHE}" "${HOME}" "${GOCACHE}"
  while IFS= read -r -d '' go_mod; do
    source="$(dirname "${go_mod}")"
    name="$(basename "${source}")"
    mkdir -p "${WORK_SRC}/${name}"
    (
      cd "${source}"
      tar -cf - .
    ) | tar -C "${WORK_SRC}/${name}" -xf -
    count=$((count + 1))
  done < <(find "${INPUT_ROOT}" -mindepth 2 -maxdepth 2 -type f -name go.mod -print0 | sort -z)
  (( count >= 5 )) || cache_fail 'At least five direct-child Go repositories are required in src/.'
}

cache_create_workspace() {
  local go_mod directory relative
  (cd "${WORK_SRC}" && go work init)
  while IFS= read -r -d '' go_mod; do
    directory="$(dirname "${go_mod}")"
    relative="$(realpath --relative-to="${WORK_SRC}" "${directory}")"
    (cd "${WORK_SRC}" && go work use "./${relative}")
  done < <(find "${WORK_SRC}" -mindepth 2 -maxdepth 2 -type f -name go.mod -print0 | sort -z)
  export GOWORK="${WORK_SRC}/go.work"
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

cache_run_generators() {
  local repository
  case "${RUN_GO_GENERATE:-1}" in
    0) return 0 ;;
    1) ;;
    *) cache_fail 'RUN_GO_GENERATE must be 0 or 1.' ;;
  esac
  for repository in "${HOSTD_REPO}" "${RENTERD_REPO}" "${WALLETD_REPO}"; do
    cache_ensure_git_metadata "${repository}"
    (cd "${WORK_SRC}/${repository}" && go generate ./...)
  done
}

cache_resolve_commands() {
  (cd "${WORK_SRC}/${HOSTD_REPO}" && go list -tags 'netgo timetzdata' -deps ./cmd/hostd >/dev/null)
  (cd "${WORK_SRC}/${RENTERD_REPO}" && go list -tags 'netgo timetzdata' -deps ./cmd/renterd >/dev/null)
  (cd "${WORK_SRC}/${WALLETD_REPO}" && go list -tags 'netgo timetzdata' -deps ./cmd/walletd >/dev/null)
}

for variable in CORE_REPO COREUTILS_REPO HOSTD_REPO RENTERD_REPO WALLETD_REPO; do
  [[ -n "${!variable:-}" ]] || cache_fail "${variable} is not set."
done
for command in go git find sort tar realpath; do
  command -v "${command}" >/dev/null 2>&1 || cache_fail "Missing command: ${command}."
done

export GOMODCACHE="${GOMODCACHE:-/gomodcache}"
export GOCACHE="${GOCACHE:-/tmp/go-build}"
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.org}"
export GOTOOLCHAIN=local
export GOFLAGS=-mod=readonly

cache_copy_modules
cache_create_workspace
cache_run_generators
cache_resolve_commands
printf '[dependencies] External Go dependencies are ready.\n' >&2
