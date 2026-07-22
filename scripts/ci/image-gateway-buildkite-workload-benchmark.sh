#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"
case "${platform}" in
  linux/arm64|linux/amd64) ;;
  *) echo "usage: scripts/ci/image-gateway-buildkite-workload-benchmark.sh linux/arm64|linux/amd64" >&2; exit 2 ;;
esac

[[ -n "${BUILDKITE_BUILD_NUMBER:-}" && -n "${BUILDKITE_COMMIT:-}" ]] || {
  echo "buildkite-sporevm gateway benchmark must run in Buildkite" >&2
  exit 2
}
command -v docker >/dev/null
command -v buildkite-agent >/dev/null

arch="${platform#linux/}"
output="zig-cache/image-gateway-transport/${arch}/buildkite-sporevm"
scratch="${TMPDIR:-/tmp}/image-gateway-buildkite-${BUILDKITE_JOB_ID}"
source_dir="${scratch}/buildkite"
context="${scratch}/context"
base_layout="${scratch}/base-layout"
outer_layout="${scratch}/outer-layout"
backend="s3://sporevm-benchmarks-data/builds/${BUILDKITE_BUILD_NUMBER}/${BUILDKITE_COMMIT}/image-gateway/${arch}/buildkite-sporevm"
buildkite_commit="e446c1b8a74d317a7abd08c42140152a5d9e8462"
dynamodb_sha256="55b425a9a42cfc728436eaf0e4ae64d688b64d177c99c4f4c4d7e3dbb3ac6c09"

mkdir -p "${output}" "${scratch}" "${context}/image/deps" "${context}/dynamodb-local"
github_token="$(buildkite-agent secret get SPOREVM_GITHUB_TOKEN | tr -d '\r')"
[[ -n "${github_token}" ]] || { echo "SPOREVM_GITHUB_TOKEN is required" >&2; exit 1; }
export GITHUB_TOKEN="${github_token}"
export GIT_TERMINAL_PROMPT=0
gh repo clone buildkite/buildkite "${source_dir}" -- --filter=blob:none
git -C "${source_dir}" checkout --detach "${buildkite_commit}"
[[ "$(git -C "${source_dir}" rev-parse HEAD)" == "${buildkite_commit}" ]]
jq -n \
  --arg platform "${platform}" \
  --arg sporevm_commit "${BUILDKITE_COMMIT}" \
  --arg buildkite_commit "${buildkite_commit}" \
  --arg buildkite_sporevm_commit "ad89671" \
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
docker build --platform "${platform}" -f "${source_dir}/.buildkite/Dockerfile.postgres" -t buildkite-postgres:benchmark "${source_dir}"

dependency_refs=(
  "valkey/valkey@sha256:a038175878d66b9d274fbf8be73c0305e93798b83917647f167e18cef3c71eec"
  "memcached@sha256:c29847751abb41f4c268c84fb3087fee05d4edcbda44409ccb5086e26148e8a7"
  "minio/minio@sha256:a1ea29fa28355559ef137d71fc570e508a214ec84ff8083e39bc5428980b015e"
  "nsmithuk/local-kms@sha256:360d7377b6f3687c89a622236791e4fa3f7316366267b437829edbdfa8a5fc60"
)
for ref in "${dependency_refs[@]}"; do
  docker pull --platform "${platform}" "${ref}"
done
docker save -o "${context}/image/deps/01-valkey.tar" "${dependency_refs[0]}"
docker save -o "${context}/image/deps/02-memcached.tar" "${dependency_refs[1]}"
docker save -o "${context}/image/deps/03-buildkite-postgres.tar" buildkite-postgres:benchmark
docker save -o "${context}/image/deps/04-minio.tar" "${dependency_refs[2]}"
docker save -o "${context}/image/deps/06-local-kms.tar" "${dependency_refs[3]}"

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
scripts/benchmark/image-gateway-transport.py run \
  --fixture "${output}/outer/fixture" \
  --overlap-fixture "${output}/buildkite-ci/fixture" \
  --output "${output}/s3" \
  --iterations 5 \
  --s3-uri "${backend}" \
  --s3-region ap-southeast-2

echo "buildkite-sporevm gateway benchmark passed: ${platform} ${output}/s3/summary.json"
