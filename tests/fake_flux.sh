#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "build" && "${2:-}" == "artifact" ]]; then
  path=""
  output="artifact.tgz"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        path="$2"
        shift 2
        ;;
      --path=*)
        path="${1#--path=}"
        shift
        ;;
      --output)
        output="$2"
        shift 2
        ;;
      --output=*)
        output="${1#--output=}"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  if [[ -z "${path}" ]]; then
    echo "fake flux build artifact missing --path" >&2
    exit 2
  fi
  mkdir -p "${output%/*}"
  tar -czf "${output}" -C "${path}" .
  exit 0
fi

for arg in "$@"; do
  case "${arg}" in
    --path=*)
      path="${arg#--path=}"
      if [[ -L "${path}" ]]; then
        echo "fake flux received symlink path: ${path}" >&2
        exit 1
      fi
      if [[ -d "${path}" && ! -f "${path}/base/kustomization.yaml" ]]; then
        echo "fake flux missing rendered kustomization under: ${path}" >&2
        exit 1
      fi
      ;;
  esac
done
echo "$@"
