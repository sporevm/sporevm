#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"
case "${platform}" in
  linux/arm64|linux/amd64) ;;
  *) echo "usage: scripts/ci/image-gateway-buildkite-workload-benchmark.sh linux/arm64|linux/amd64" >&2; exit 2 ;;
esac

command -v docker >/dev/null

arch="${platform#linux/}"
output="zig-cache/image-gateway-transport/${arch}/buildkite-sporevm"
run_id="${BUILDKITE_JOB_ID:-manual-$$}"
sporevm_commit="${BUILDKITE_COMMIT:-$(git rev-parse HEAD)}"
scratch="${TMPDIR:-/tmp}/image-gateway-buildkite-${run_id}"
source_dir="${scratch}/buildkite"
context="${scratch}/context"
base_layout="${scratch}/base-layout"
outer_layout="${scratch}/outer-layout"
backend="${SPOREVM_IMAGE_GATEWAY_BACKEND:-}"
if [[ -z "${backend}" && -n "${BUILDKITE_BUILD_NUMBER:-}" ]]; then
  backend="s3://sporevm-benchmarks-data/builds/${BUILDKITE_BUILD_NUMBER}/${sporevm_commit}/image-gateway/${arch}/buildkite-sporevm"
fi
buildkite_commit="e446c1b8a74d317a7abd08c42140152a5d9e8462"
dynamodb_sha256="55b425a9a42cfc728436eaf0e4ae64d688b64d177c99c4f4c4d7e3dbb3ac6c09"
buildkite_sporevm_commit="ad8967125968098b917090e49b6410dd5a6b19c5"

rm -rf -- "${output}" "${scratch}"
mkdir -p "${output}" "${scratch}" "${source_dir}" "${context}/image/deps" "${context}/dynamodb-local"
postgres_temp_tag="buildkite-postgres:gateway-benchmark-${arch}-${run_id}"
active_tag=""
active_previous_image=""
restore_active_tag() {
  [[ -n "${active_tag}" ]] || return
  if [[ -n "${active_previous_image}" ]]; then
    docker tag "${active_previous_image}" "${active_tag}"
  else
    docker image rm "${active_tag}" >/dev/null
  fi
  active_tag=""
  active_previous_image=""
}
cleanup() {
  restore_active_tag || true
  rm -rf -- "${scratch}"
  docker image rm "${postgres_temp_tag}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

save_as() {
  local source_ref="$1"
  local expected_tag="$2"
  local output_path="$3"
  active_tag="${expected_tag}"
  active_previous_image="$(docker image inspect --format '{{.Id}}' "${expected_tag}" 2>/dev/null || true)"
  docker tag "${source_ref}" "${expected_tag}"
  local save_status=0
  docker save -o "${output_path}" "${expected_tag}" || save_status=$?
  restore_active_tag
  return "${save_status}"
}
if [[ -n "${SPOREVM_BUILDKITE_SOURCE_DIR:-}" ]]; then
  git -C "${SPOREVM_BUILDKITE_SOURCE_DIR}" cat-file -e "${buildkite_commit}^{commit}"
  rmdir "${source_dir}"
  git clone --local --no-hardlinks --no-checkout "${SPOREVM_BUILDKITE_SOURCE_DIR}" "${source_dir}"
  git -C "${source_dir}" checkout --detach "${buildkite_commit}"
  git -C "${source_dir}" submodule update --init --recursive
  source_actual_commit="$(git -C "${source_dir}" rev-parse HEAD)"
else
  command -v buildkite-agent >/dev/null
  github_token="$(buildkite-agent secret get SPOREVM_GITHUB_TOKEN | tr -d '\r')"
  [[ -n "${github_token}" ]] || { echo "SPOREVM_GITHUB_TOKEN is required" >&2; exit 1; }
  export GITHUB_TOKEN="${github_token}"
  export GIT_TERMINAL_PROMPT=0
  gh repo clone buildkite/buildkite "${source_dir}" -- --filter=blob:none
  git -C "${source_dir}" checkout --detach "${buildkite_commit}"
  source_actual_commit="$(git -C "${source_dir}" rev-parse HEAD)"
  unset GITHUB_TOKEN github_token
fi
[[ "${source_actual_commit}" == "${buildkite_commit}" ]]
printf '%s\n' "${buildkite_commit}" >"${source_dir}/REVISION"
jq -n \
  --arg platform "${platform}" \
  --arg sporevm_commit "${sporevm_commit}" \
  --arg buildkite_commit "${buildkite_commit}" \
  --arg buildkite_sporevm_commit "${buildkite_sporevm_commit}" \
  --arg dynamodb_sha256 "${dynamodb_sha256}" \
  '{
    schema: "spore-image-gateway-buildkite-workload-v1",
    platform: $platform,
    sporevm_commit: $sporevm_commit,
    buildkite_commit: $buildkite_commit,
    buildkite_sporevm_commit: $buildkite_sporevm_commit,
    dynamodb_sha256: $dynamodb_sha256,
    dependency_indexes: [
      "valkey/valkey@sha256:a038175878d66b9d274fbf8be73c0305e93798b83917647f167e18cef3c71eec",
      "memcached@sha256:c29847751abb41f4c268c84fb3087fee05d4edcbda44409ccb5086e26148e8a7",
      "minio/minio@sha256:a1ea29fa28355559ef137d71fc570e508a214ec84ff8083e39bc5428980b015e",
      "nsmithuk/local-kms@sha256:360d7377b6f3687c89a622236791e4fa3f7316366267b437829edbdfa8a5fc60"
    ]
  }' >"${output}/provenance.json"

docker buildx build \
  --platform "${platform}" \
  --target ci \
  --output "type=oci,dest=${scratch}/base-layout.tar" \
  "${source_dir}"
mkdir -p "${base_layout}"
tar -xf "${scratch}/base-layout.tar" -C "${base_layout}"
docker buildx build --load --platform "${platform}" \
  -f "${source_dir}/.buildkite/Dockerfile.postgres" \
  -t "${postgres_temp_tag}" \
  "${source_dir}"

dependency_refs=(
  "valkey/valkey@sha256:a038175878d66b9d274fbf8be73c0305e93798b83917647f167e18cef3c71eec"
  "memcached@sha256:c29847751abb41f4c268c84fb3087fee05d4edcbda44409ccb5086e26148e8a7"
  "minio/minio@sha256:a1ea29fa28355559ef137d71fc570e508a214ec84ff8083e39bc5428980b015e"
  "nsmithuk/local-kms@sha256:360d7377b6f3687c89a622236791e4fa3f7316366267b437829edbdfa8a5fc60"
)
for ref in "${dependency_refs[@]}"; do
  docker pull --platform "${platform}" "${ref}"
done
save_as "${dependency_refs[0]}" "valkey/valkey:8.1-alpine" "${context}/image/deps/01-valkey.tar"
save_as "${dependency_refs[1]}" "memcached:1.6-alpine" "${context}/image/deps/02-memcached.tar"
save_as "${postgres_temp_tag}" buildkite-postgres:latest "${context}/image/deps/03-buildkite-postgres.tar"
save_as "${dependency_refs[2]}" "minio/minio:RELEASE.2025-04-22T22-12-26Z" "${context}/image/deps/04-minio.tar"
save_as "${dependency_refs[3]}" "nsmithuk/local-kms:3.11.7" "${context}/image/deps/06-local-kms.tar"

curl -fsSL --retry 3 \
  "https://s3.us-west-2.amazonaws.com/dynamodb-local/dynamodb_local_latest.tar.gz" \
  -o "${scratch}/dynamodb-local.tar.gz"
printf '%s  %s\n' "${dynamodb_sha256}" "${scratch}/dynamodb-local.tar.gz" | sha256sum -c -
tar -xzf "${scratch}/dynamodb-local.tar.gz" -C "${context}/dynamodb-local"

cp -R test/image-gateway/benchmark/buildkite-sporevm/. "${context}/"
docker buildx build \
  --platform "${platform}" \
  --build-context "base=oci-layout://${base_layout}" \
  --output "type=oci,dest=${scratch}/outer-layout.tar" \
  "${context}"
mkdir -p "${outer_layout}"
tar -xf "${scratch}/outer-layout.tar" -C "${outer_layout}"

mise run build
scripts/benchmark/image-gateway-transport.py prepare \
  --source-layout "${base_layout}" \
  --platform "${platform}" \
  --spore-bin zig-out/bin/spore \
  --output "${output}/buildkite-ci" \
  --iterations 5
scripts/benchmark/image-gateway-transport.py prepare \
  --source-layout "${outer_layout}" \
  --platform "${platform}" \
  --spore-bin zig-out/bin/spore \
  --output "${output}/outer" \
  --iterations 5
transport_output="${output}/local"
transport_args=()
if [[ -n "${backend}" ]]; then
  transport_output="${output}/s3"
  transport_args+=(--s3-uri "${backend}" --s3-region ap-southeast-2)
fi
scripts/benchmark/image-gateway-transport.py run \
  --fixture "${output}/outer/fixture" \
  --overlap-fixture "${output}/buildkite-ci/fixture" \
  --output "${transport_output}" \
  --iterations 5 \
  "${transport_args[@]}"

echo "buildkite-sporevm gateway benchmark passed: ${platform} ${transport_output}/summary.json"
