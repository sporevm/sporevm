#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[ci-buildkite-release] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "missing required command: ${name}"
}

hash_files() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    die "missing required command: shasum or sha256sum"
  fi
}

verify_checksum_file() {
  local checksum_file="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "${checksum_file}"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "${checksum_file}"
  else
    die "missing required command: shasum or sha256sum"
  fi
}

fetch_optional_secret() {
  local key="$1"
  buildkite-agent secret get "${key}" 2>/dev/null || true
}

normalize_secret_value() {
  printf '%s' "$1" | tr -d '\r'
}

load_github_token() {
  local github_token

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    return
  fi

  github_token="$(normalize_secret_value "$(fetch_optional_secret SPOREVM_GITHUB_RELEASE_TOKEN)")"
  [[ -n "${github_token}" ]] || die "GITHUB_TOKEN or Buildkite secret SPOREVM_GITHUB_RELEASE_TOKEN is required"
  export GITHUB_TOKEN="${github_token}"
}

github_request() {
  local method="$1"
  local url="$2"
  local output_path="$3"
  local data_path="${4:-}"
  local -a args

  args=(
    -sS
    -o "${output_path}"
    -w "%{http_code}"
    -X "${method}"
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  if [[ -n "${data_path}" ]]; then
    args+=(-H "Content-Type: application/json" --data "@${data_path}")
  fi

  curl "${args[@]}" "${url}"
}

json_field_from_file() {
  local field="$1"
  local path="$2"

  FIELD="${field}" python3 - "${path}" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    value = json.load(handle).get(os.environ["FIELD"], "")
if value is None:
    value = ""
print(value)
PY
}

asset_id_for_name() {
  local release_json_path="$1"
  local asset_name="$2"

  ASSET_NAME="${asset_name}" python3 - "${release_json_path}" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    release = json.load(handle)

for asset in release.get("assets", []):
    if asset.get("name") == os.environ["ASSET_NAME"]:
        print(asset.get("id", ""))
        break
PY
}

upload_url_from_file() {
  local release_json_path="$1"

  python3 - "${release_json_path}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["upload_url"].split("{", 1)[0])
PY
}

release_body() {
  local notes_path="docs/releases/${BUILDKITE_TAG}.md"
  local previous_tag changes

  if [[ -f "${notes_path}" ]]; then
    cat "${notes_path}"
    return
  fi

  previous_tag="$(git describe --tags --abbrev=0 "${BUILDKITE_TAG}^0^" 2>/dev/null || true)"
  if [[ -n "${previous_tag}" ]]; then
    changes="$(
      git log \
        --format='- %s (%h)' \
        --reverse \
        --extended-regexp \
        --invert-grep \
        --grep='^(docs|test|chore):' \
        "${previous_tag}..${BUILDKITE_TAG}"
    )"
    if [[ -n "${changes}" ]]; then
      printf 'Changes since %s:\n\n%s\n' "${previous_tag}" "${changes}"
      return
    fi
  fi

  printf 'Automated prerelease for %s.\n' "${BUILDKITE_TAG}"
}

write_release_payload() {
  local include_tag="$1"
  local body

  body="$(release_body)"
  RELEASE_TAG="${BUILDKITE_TAG}" \
    RELEASE_NAME="SporeVM ${BUILDKITE_TAG}" \
    RELEASE_BODY="${body}" \
    RELEASE_TARGET="${BUILDKITE_COMMIT:-}" \
    INCLUDE_TAG="${include_tag}" \
    python3 <<'PY'
import json
import os

payload = {
    "name": os.environ["RELEASE_NAME"],
    "body": os.environ["RELEASE_BODY"],
    "prerelease": True,
}

if os.environ["INCLUDE_TAG"] == "1":
    payload["tag_name"] = os.environ["RELEASE_TAG"]
    target = os.environ.get("RELEASE_TARGET", "")
    if target:
        payload["target_commitish"] = target

print(json.dumps(payload))
PY
}

tmp_file() {
  local path

  path="$(mktemp)"
  TMP_FILES+=("${path}")
  printf '%s\n' "${path}"
}

download_release_archives() {
  rm -rf "${ASSET_DIR}"
  mkdir -p "${ASSET_DIR}"

  buildkite-agent artifact download "dist/spore_*.tar.gz" "${REPO_ROOT}"

  for asset_name in "${EXPECTED_ASSETS[@]}"; do
    local asset_path="${ASSET_DIR}/${asset_name}"

    [[ -f "${asset_path}" ]] || die "missing downloaded release asset: ${asset_path}"
    tar -tzf "${asset_path}" >/dev/null
  done
}

write_checksums() {
  (
    cd "${ASSET_DIR}"
    hash_files "${EXPECTED_ASSETS[@]}" >checksums.txt
    verify_checksum_file checksums.txt
  )
}

upsert_github_release() {
  local release_json_path="$1"
  local payload_path status release_id

  status="$(github_request GET "${GITHUB_API_BASE}/releases/tags/${BUILDKITE_TAG}" "${release_json_path}")"
  case "${status}" in
    200)
      release_id="$(json_field_from_file id "${release_json_path}")"
      [[ -n "${release_id}" ]] || die "GitHub release response for ${BUILDKITE_TAG} did not include an id"
      payload_path="$(tmp_file)"
      write_release_payload 0 >"${payload_path}"
      status="$(github_request PATCH "${GITHUB_API_BASE}/releases/${release_id}" "${release_json_path}" "${payload_path}")"
      [[ "${status}" == "200" ]] || die "failed to update GitHub release ${BUILDKITE_TAG}: HTTP ${status}: $(cat "${release_json_path}")"
      ;;
    404)
      payload_path="$(tmp_file)"
      write_release_payload 1 >"${payload_path}"
      status="$(github_request POST "${GITHUB_API_BASE}/releases" "${release_json_path}" "${payload_path}")"
      [[ "${status}" == "201" ]] || die "failed to create GitHub release ${BUILDKITE_TAG}: HTTP ${status}: $(cat "${release_json_path}")"
      ;;
    *)
      die "failed to read GitHub release ${BUILDKITE_TAG}: HTTP ${status}: $(cat "${release_json_path}")"
      ;;
  esac
}

delete_existing_asset() {
  local release_json_path="$1"
  local asset_name="$2"
  local asset_id

  asset_id="$(asset_id_for_name "${release_json_path}" "${asset_name}")"
  if [[ -z "${asset_id}" ]]; then
    return
  fi

  curl -fsSL \
    -X DELETE \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_BASE}/releases/assets/${asset_id}" >/dev/null
}

upload_asset() {
  local upload_url="$1"
  local asset_path="$2"
  local asset_name

  asset_name="$(basename "${asset_path}")"
  curl -fsSL \
    -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    --data-binary "@${asset_path}" \
    "${upload_url}?name=${asset_name}" >/dev/null
}

publish_release_assets() {
  local release_json_path="$1"
  local upload_url asset_name
  local -a upload_assets

  upload_url="$(upload_url_from_file "${release_json_path}")"
  [[ -n "${upload_url}" ]] || die "failed to resolve GitHub release upload URL for ${BUILDKITE_TAG}"

  upload_assets=(
    "${ASSET_DIR}/spore_Darwin_arm64.tar.gz"
    "${ASSET_DIR}/spore_Linux_arm64.tar.gz"
    "${ASSET_DIR}/checksums.txt"
  )

  for asset_path in "${upload_assets[@]}"; do
    [[ -f "${asset_path}" ]] || die "missing release asset: ${asset_path}"
    asset_name="$(basename "${asset_path}")"
    delete_existing_asset "${release_json_path}" "${asset_name}"
    upload_asset "${upload_url}" "${asset_path}"
  done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSET_DIR="${REPO_ROOT}/dist"
GITHUB_REPOSITORY_NAME="${SPOREVM_GITHUB_REPOSITORY:-buildkite/sporevm}"
GITHUB_API_BASE="https://api.github.com/repos/${GITHUB_REPOSITORY_NAME}"
EXPECTED_ASSETS=(
  spore_Darwin_arm64.tar.gz
  spore_Linux_arm64.tar.gz
)
TMP_FILES=()

cleanup() {
  if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

require_command buildkite-agent
require_command curl
require_command git
require_command python3
require_command tar

[[ -n "${BUILDKITE_TAG:-}" ]] || die "BUILDKITE_TAG is required for release publishing"
load_github_token

cd "${REPO_ROOT}"
git fetch --tags origin

echo "--- :package: Download release archives"
download_release_archives

echo "--- :fingerprint: Write checksums"
write_checksums

echo "--- :rocket: Publish GitHub release"
release_json_path="$(tmp_file)"
upsert_github_release "${release_json_path}"
publish_release_assets "${release_json_path}"
