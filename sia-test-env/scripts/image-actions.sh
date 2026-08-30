#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
source "${ROOT_DIR}/controls/common.sh"
[[ ! -f .env ]] || { set -a; source ./.env; set +a; }

runtime_image_usage() {
  cat <<'USAGE'
Usage: ./scripts/image-actions.sh [output.tar]
       ./scripts/image-actions.sh --load <input.tar>
USAGE
}

prepare_runtime_image() {
  local output="${1:-}" image="${RUNTIME_TOOLS_IMAGE:-sia-lab-runtime-tools:bookworm}"
  docker build --file docker/runtime-tools.Dockerfile --tag "${image}" docker
  if [[ -n "${output}" ]]; then
    mkdir -p "$(dirname "${output}")"
    docker save -o "${output}" "${image}"
  fi
}

load_runtime_image() {
  local archive="$1"
  [[ -f "${archive}" ]] \
    || { test_log ERROR runtime "missing archive: ${archive}"; return 66; }
  docker load -i "${archive}"
}

case "${1:-}" in
  --load)
    (( $# == 2 )) || { runtime_image_usage >&2; exit 64; }
    load_runtime_image "$2"
    ;;
  -h|--help)
    (( $# == 1 )) || { runtime_image_usage >&2; exit 64; }
    runtime_image_usage
    ;;
  *)
    (( $# <= 1 )) || { runtime_image_usage >&2; exit 64; }
    prepare_runtime_image "${1:-}"
    ;;
esac
