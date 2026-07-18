#!/usr/bin/env bash
set -euo pipefail

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/aws" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${AWS_CALL_LOG}"
if [[ "$1 $2" == "s3 ls" ]]; then
  printf '                           PRE run-old/\n'
  printf '                           PRE run-new/\n'
elif [[ "$1 $2" == "s3 cp" ]]; then
  mkdir -p "$4"
  printf '{}\n' >"$4/results.jsonl"
fi
SH
  chmod +x "${tmp}/bin/aws"
  AWS_CALL_LOG="${tmp}/aws.log" PATH="${tmp}/bin:${PATH}" \
    "$0" "${tmp}/history" 1 main macos
  test -f "${tmp}/history/run-new/results.jsonl"
  test ! -e "${tmp}/history/run-old"
  grep -q 'history/main/macos/' "${tmp}/aws.log"
  grep -q -- '--include regression-report.json' "${tmp}/aws.log"
  echo "download-history self-test ok"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

usage() {
  echo "usage: $0 DEST LIMIT BRANCH PLATFORM" >&2
  exit 2
}

[[ "$#" == 4 ]] || usage

dest="$1"
limit="$2"
branch="$3"
platform="$4"
history_uri="${SPOREVM_BENCHMARK_HISTORY_S3_URI:-s3://sporevm-benchmarks/history}"

[[ "${limit}" =~ ^[0-9]+$ ]] || usage

command -v aws >/dev/null 2>&1 || exit 1
mkdir -p "${dest}"

prefix="${history_uri%/}/${branch}/${platform}"
while IFS= read -r run; do
  [[ -n "${run}" ]] || continue
  aws s3 cp "${prefix}/${run}" "${dest}/${run}" \
    --recursive \
    --no-progress \
    --exclude "*" \
    --include "config.json" \
    --include "results.jsonl" \
    --include "regression-report.json" \
    --include "summary.json" >/dev/null 2>&1 || true
done < <(aws s3 ls "${prefix}/" 2>/dev/null | awk '$1 == "PRE" { print $2 }' | tail -n "${limit}")

find "${dest}" -name results.jsonl -type f -print -quit | grep -q .
