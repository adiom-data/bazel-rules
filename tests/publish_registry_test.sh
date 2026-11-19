#!/usr/bin/env bash
set -euo pipefail

publisher="$1"
publisher_runfiles=$(cd "${publisher}.runfiles" && pwd)
crane_runfile=$(find "${publisher_runfiles}" -name crane -print)
[[ -n "${crane_runfile}" ]]
crane_runfile="${crane_runfile#"${publisher_runfiles}/"}"

runfiles=$(mktemp -d)
trap 'rm -rf -- "${runfiles}"' EXIT
ln -s "${publisher_runfiles}/_main" "${runfiles}/_main"
crane="${runfiles}/${crane_runfile}"
mkdir -p "${crane%/*}"
cat > "${crane}" <<'MOCK_CRANE'
#!/usr/bin/env bash
set -euo pipefail

reference="${!#}"
repo_tag="${reference#*/}"
manifest_url="https://${reference%%/*}/v2/${repo_tag%:*}/manifests/${repo_tag##*:}"
prefix='Error: '
if [[ "$1" == manifest ]]; then
  prefix+="fetching manifest ${reference}: "
fi

case "${MOCK_REGISTRY}" in
  missing) diagnostic="GET ${manifest_url}: unexpected status code 404 Not Found" ;;
  missing_code) diagnostic="GET ${manifest_url}: MANIFEST_UNKNOWN: manifest unknown" ;;
  probe) diagnostic='GET https://registry.example:4040/v2/: unexpected status code 404 Not Found' ;;
  token) diagnostic='GET https://registry.example:4040/token?service=registry: unexpected status code 404 Not Found' ;;
  forbidden) diagnostic="GET ${manifest_url}: unexpected status code 403 Forbidden" ;;
  retry)
    printf 'HEAD request failed, falling back on GET: HEAD %s: unexpected status code 404 Not Found\n' "${manifest_url}" >&2
    diagnostic="GET ${manifest_url}: unexpected status code 403 Forbidden"
    ;;
esac
printf '%s%s\n' "${prefix}" "${diagnostic}" >&2
exit 23
MOCK_CRANE
chmod +x "${crane}"

check_lookup() {
  local scenario="$1" expected="$2" status=0 output
  shift 2
  output=$(MOCK_REGISTRY="${scenario}" RUNFILES_DIR="${runfiles}" \
    "${publisher}" --skip-existing --push-prefix registry.example:4040/acme "$@" 2>&1) || status=$?
  if [[ "${status}" != "${expected}" ]]; then
    printf '%s returned %s, expected %s\n%s\n' "${scenario}" "${status}" "${expected}" "${output}" >&2
    exit 1
  fi
  if [[ "${expected}" == 0 ]]; then
    [[ "${output}" == *frontend-assets* && "${output}" == *"push artifact"* ]]
  else
    [[ "${output}" != *frontend-assets* && "${output}" != *"push artifact"* ]]
  fi
}

for scenario in probe token forbidden retry; do
  check_lookup "${scenario}" 23
  check_lookup "${scenario}" 23 --skip-images
done
for scenario in missing missing_code; do
  check_lookup "${scenario}" 0
  check_lookup "${scenario}" 0 --skip-images --insecure
done
