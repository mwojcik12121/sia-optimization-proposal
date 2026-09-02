#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

[[ ! -f .env ]] || { set -a; source ./.env; set +a; }

CORE_REPO=''
COREUTILS_REPO=''
HOSTD_REPO=''
RENTERD_UNMODIFIED_REPO=''
RENTERD_MODIFIED_REPO=''
WALLETD_REPO=''
BUILD_JOBS=1
EXPORT_CONTAINER=''
EXPORT_IMAGE=''
EXPORT_DIR=''

build_usage() {
  cat <<'USAGE'
Usage:
  ./build.sh \
    --core <directory> \
    --coreutils <directory> \
    --hostd <directory> \
    --renterd-unmodified <directory> \
    --renterd-modified <directory> \
    --walletd <directory> \
    [--build-jobs <count>]
USAGE
}

build_fail() {
  printf '[builder][ERROR] %s\n' "$*" >&2
  exit 1
}

build_option_value() {
  local option="$1" count="$2" value="${3:-}"
  (( count >= 2 )) || build_fail "${option} requires a value."
  [[ -n "${value}" ]] || build_fail "${option} requires a nonempty value."
  printf '%s\n' "${value}"
}

build_cleanup() {
  [[ -z "${EXPORT_CONTAINER}" ]] || docker rm -f "${EXPORT_CONTAINER}" >/dev/null 2>&1 || true
  [[ -z "${EXPORT_IMAGE}" ]] || docker image rm -f "${EXPORT_IMAGE}" >/dev/null 2>&1 || true
  [[ -z "${EXPORT_DIR}" ]] || rm -rf "${EXPORT_DIR}"
}

build_module_path() {
  awk '$1 == "module" { print $2; exit }' "$1/go.mod"
}

build_require_repository() {
  local label="$1" name="$2" expected="$3" command_name="${4:-}" directory actual
  [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || build_fail "${label} must name one direct child of src/ using letters, digits, dot, underscore, or dash."
  directory="${ROOT_DIR}/src/${name}"
  [[ -f "${directory}/go.mod" ]] || build_fail "${label}: ${directory}/go.mod is missing."
  actual="$(build_module_path "${directory}")"
  [[ "${actual}" == "${expected}" ]] \
    || build_fail "${label}: ${name} declares ${actual:-no module}; expected ${expected}."
  if [[ -n "${command_name}" ]]; then
    [[ -d "${directory}/cmd/${command_name}" ]] \
      || build_fail "${label}: ${directory}/cmd/${command_name} is missing."
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --core) CORE_REPO="$(build_option_value "$1" "$#" "${2:-}")"; shift 2 ;;
    --core=*) CORE_REPO="${1#*=}"; shift ;;
    --coreutils) COREUTILS_REPO="$(build_option_value "$1" "$#" "${2:-}")"; shift 2 ;;
    --coreutils=*) COREUTILS_REPO="${1#*=}"; shift ;;
    --hostd) HOSTD_REPO="$(build_option_value "$1" "$#" "${2:-}")"; shift 2 ;;
    --hostd=*) HOSTD_REPO="${1#*=}"; shift ;;
    --renterd|--renterd-unmodified)
      RENTERD_UNMODIFIED_REPO="$(build_option_value "$1" "$#" "${2:-}")"; shift 2
      ;;
    --renterd=*|--renterd-unmodified=*) RENTERD_UNMODIFIED_REPO="${1#*=}"; shift ;;
    --renterd-modified) RENTERD_MODIFIED_REPO="$(build_option_value "$1" "$#" "${2:-}")"; shift 2 ;;
    --renterd-modified=*) RENTERD_MODIFIED_REPO="${1#*=}"; shift ;;
    --walletd) WALLETD_REPO="$(build_option_value "$1" "$#" "${2:-}")"; shift 2 ;;
    --walletd=*) WALLETD_REPO="${1#*=}"; shift ;;
    --build-jobs) BUILD_JOBS="$(build_option_value "$1" "$#" "${2:-}")"; shift 2 ;;
    --build-jobs=*) BUILD_JOBS="${1#*=}"; shift ;;
    -h|--help) build_usage; exit 0 ;;
    *) build_usage >&2; build_fail "Unknown option: $1" ;;
  esac
done

for variable in CORE_REPO COREUTILS_REPO HOSTD_REPO RENTERD_UNMODIFIED_REPO RENTERD_MODIFIED_REPO WALLETD_REPO; do
  [[ -n "${!variable}" ]] || { build_usage >&2; build_fail "Missing required option for ${variable}."; }
done
[[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || build_fail '--build-jobs must be a positive integer.'

repo_names=(
  "${CORE_REPO}"
  "${COREUTILS_REPO}"
  "${HOSTD_REPO}"
  "${RENTERD_UNMODIFIED_REPO}"
  "${RENTERD_MODIFIED_REPO}"
  "${WALLETD_REPO}"
)
[[ "$(printf '%s\n' "${repo_names[@]}" | sort -u | wc -l)" -eq 6 ]] \
  || build_fail 'Each repository option must point to a different src/ directory.'

build_require_repository --core "${CORE_REPO}" go.sia.tech/core
build_require_repository --coreutils "${COREUTILS_REPO}" go.sia.tech/coreutils
build_require_repository --hostd "${HOSTD_REPO}" go.sia.tech/hostd/v2 hostd
build_require_repository --renterd-unmodified "${RENTERD_UNMODIFIED_REPO}" go.sia.tech/renterd/v2 renterd
build_require_repository --renterd-modified "${RENTERD_MODIFIED_REPO}" go.sia.tech/renterd/v2 renterd
build_require_repository --walletd "${WALLETD_REPO}" go.sia.tech/walletd/v2 walletd

for command in docker tar awk sort wc mktemp date grep; do
  command -v "${command}" >/dev/null 2>&1 || build_fail "Missing host command: ${command}."
done
if grep -q 'yaml:"slabRisk' "${ROOT_DIR}/src/${RENTERD_UNMODIFIED_REPO}/config/config.go"; then
  build_fail '--renterd-unmodified unexpectedly contains the slabRisk configuration extension.'
fi
grep -q 'yaml:"slabRisk' "${ROOT_DIR}/src/${RENTERD_MODIFIED_REPO}/config/config.go" \
  || build_fail '--renterd-modified does not contain the slabRisk configuration extension.'

docker info >/dev/null 2>&1 || build_fail 'Docker Engine is not reachable.'

export CORE_REPO COREUTILS_REPO HOSTD_REPO RENTERD_UNMODIFIED_REPO RENTERD_MODIFIED_REPO WALLETD_REPO BUILD_JOBS
export BUILD_TAG="build-$(date -u +'%Y%m%dT%H%M%SZ')-$$"

"${ROOT_DIR}/scripts/prepare-dependencies.sh" cache

EXPORT_IMAGE="sia-binary-export:${BUILD_TAG}"
trap build_cleanup EXIT INT TERM

printf '[builder] Compiling hostd, both renterd variants, and walletd with --build-jobs=%s and Docker networking disabled.\n' "${BUILD_JOBS}" >&2

docker build \
  --pull=false \
  --network=none \
  --file Dockerfile \
  --target binary-export \
  --build-arg "GO_BUILDER_IMAGE=${GO_BUILDER_IMAGE:-golang:1.26-bookworm}" \
  --build-arg "CORE_REPO=${CORE_REPO}" \
  --build-arg "COREUTILS_REPO=${COREUTILS_REPO}" \
  --build-arg "HOSTD_REPO=${HOSTD_REPO}" \
  --build-arg "RENTERD_UNMODIFIED_REPO=${RENTERD_UNMODIFIED_REPO}" \
  --build-arg "RENTERD_MODIFIED_REPO=${RENTERD_MODIFIED_REPO}" \
  --build-arg "WALLETD_REPO=${WALLETD_REPO}" \
  --build-arg "BUILD_JOBS=${BUILD_JOBS}" \
  --build-arg "RUN_GO_GENERATE=${RUN_GO_GENERATE:-1}" \
  --build-arg "APPLY_LAB_NETWORK_PATCH=${APPLY_LAB_NETWORK_PATCH:-1}" \
  --build-arg "SIA_BUILD_STATIC=${SIA_BUILD_STATIC:-1}" \
  --build-arg "BUILD_TAG=${BUILD_TAG}" \
  --tag "${EXPORT_IMAGE}" \
  .

EXPORT_DIR="$(mktemp -d)"
EXPORT_CONTAINER="$(docker create "${EXPORT_IMAGE}" /out/walletd version)"
docker cp "${EXPORT_CONTAINER}:/out/." "${EXPORT_DIR}/"
"${ROOT_DIR}/scripts/package-binaries.sh" "${EXPORT_DIR}"
printf '[builder] Created %s/bin/sia-binaries.tar.gz\n' "${ROOT_DIR}" >&2
