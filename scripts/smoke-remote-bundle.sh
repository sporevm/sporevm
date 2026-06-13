#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/smoke-remote-bundle.sh \
    --region REGION \
    --source-instance INSTANCE_ID \
    --dest-instance INSTANCE_ID \
    --bucket BUCKET [options]

Capture a spore on one SSM-managed KVM host, pack it into a chunkpack bundle,
stage the bundle in S3, then unpack and resume it on a second compatible KVM
host. The script uploads tracked HEAD plus the current tracked/staged diff to
S3 so it can validate local changes before they are committed without copying
stray untracked files.

Options:
  --region REGION             AWS region for SSM and S3
  --source-instance ID        SSM instance ID for capture/pack
  --dest-instance ID          SSM instance ID for unpack/resume
  --bucket BUCKET             S3 bucket used as the staging origin
  --prefix PREFIX             S3 prefix (default: sporevm/remote-bundle-smoke)
  --mem-mib N                 guest memory size (default: 512)
  --snapshot-after-ms N       capture delay before snapshot (default: 3000)
  --resume-seconds N          seconds to let resumed VM tick (default: 5)
  --ssm-timeout-seconds N     per-host SSM command timeout (default: 1800)
  --run-id ID                 stable run ID (default: UTC timestamp + uuid)
  --keep-remote               leave remote work directories in /tmp
  -h, --help                  show this help

Example:
  scripts/smoke-remote-bundle.sh \
    --region ap-southeast-2 \
    --source-instance i-... \
    --dest-instance i-... \
    --bucket my-sporevm-bundles
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_value() {
  local opt="$1"
  local value="${2-}"
  [[ -n "${value}" ]] || die "${opt} requires a value"
}

shell_quote() {
  printf '%q' "$1"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "${value}"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

region=""
source_instance=""
dest_instance=""
bucket=""
prefix="sporevm/remote-bundle-smoke"
mem_mib="512"
snapshot_after_ms="3000"
resume_seconds="5"
ssm_timeout_seconds="1800"
run_id=""
keep_remote=0

while (($#)); do
  case "$1" in
    --region)
      need_value "$1" "${2-}"
      region="$2"
      shift 2
      ;;
    --source-instance)
      need_value "$1" "${2-}"
      source_instance="$2"
      shift 2
      ;;
    --dest-instance)
      need_value "$1" "${2-}"
      dest_instance="$2"
      shift 2
      ;;
    --bucket)
      need_value "$1" "${2-}"
      bucket="$2"
      shift 2
      ;;
    --prefix)
      need_value "$1" "${2-}"
      prefix="${2%/}"
      shift 2
      ;;
    --mem-mib)
      need_value "$1" "${2-}"
      mem_mib="$2"
      shift 2
      ;;
    --snapshot-after-ms)
      need_value "$1" "${2-}"
      snapshot_after_ms="$2"
      shift 2
      ;;
    --resume-seconds)
      need_value "$1" "${2-}"
      resume_seconds="$2"
      shift 2
      ;;
    --ssm-timeout-seconds)
      need_value "$1" "${2-}"
      ssm_timeout_seconds="$2"
      shift 2
      ;;
    --run-id)
      need_value "$1" "${2-}"
      run_id="$2"
      shift 2
      ;;
    --keep-remote)
      keep_remote=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${region}" ]] || die "--region is required"
[[ -n "${source_instance}" ]] || die "--source-instance is required"
[[ -n "${dest_instance}" ]] || die "--dest-instance is required"
[[ -n "${bucket}" ]] || die "--bucket is required"

for pair in \
  "mem-mib:${mem_mib}" \
  "snapshot-after-ms:${snapshot_after_ms}" \
  "resume-seconds:${resume_seconds}" \
  "ssm-timeout-seconds:${ssm_timeout_seconds}"
do
  name="${pair%%:*}"
  value="${pair#*:}"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]] || die "--${name} must be a positive integer"
done

command -v aws >/dev/null 2>&1 || die "aws CLI is required"
command -v git >/dev/null 2>&1 || die "git is required"

if [[ -z "${run_id}" ]]; then
  random_id="$(uuidgen 2>/dev/null || openssl rand -hex 16)"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(tr '[:upper:]' '[:lower:]' <<<"${random_id}")"
fi
case "${run_id}" in
  *[!A-Za-z0-9._-]*) die "--run-id may only contain letters, digits, '.', '_' and '-'" ;;
esac
run_prefix="${prefix%/}/${run_id}"
s3_base="s3://${bucket}/${run_prefix}"

q_region="$(shell_quote "${region}")"
q_bucket="$(shell_quote "${bucket}")"
q_run_prefix="$(shell_quote "${run_prefix}")"
q_mem_mib="$(shell_quote "${mem_mib}")"
q_snapshot_after_ms="$(shell_quote "${snapshot_after_ms}")"
q_resume_seconds="$(shell_quote "${resume_seconds}")"
q_keep_remote="$(shell_quote "${keep_remote}")"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-remote-bundle.XXXXXX")"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

source_archive="${tmpdir}/source.tar.gz"
source_patch="${tmpdir}/source.patch"
source_script="${tmpdir}/source.sh"
dest_script="${tmpdir}/dest.sh"

echo "packing local checkout for remote smoke" >&2
git -C "${repo_root}" archive --format=tar.gz -o "${source_archive}" HEAD
git -C "${repo_root}" diff --binary HEAD -- >"${source_patch}"

cat >"${source_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export HOME="\${HOME:-/root}"
export XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\${HOME}/.cache}"
export XDG_DATA_HOME="\${XDG_DATA_HOME:-\${HOME}/.local/share}"
export XDG_STATE_HOME="\${XDG_STATE_HOME:-\${HOME}/.local/state}"
mkdir -p "\${XDG_CACHE_HOME}" "\${XDG_DATA_HOME}" "\${XDG_STATE_HOME}"
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

region=${q_region}
bucket=${q_bucket}
run_prefix=${q_run_prefix}
mem_mib=${q_mem_mib}
snapshot_after_ms=${q_snapshot_after_ms}
keep_remote=${q_keep_remote}
workdir="/tmp/sporevm-remote-bundle-source-${run_id}"

rm -rf "\${workdir}"
mkdir -p "\${workdir}/repo"
aws s3 cp "s3://\${bucket}/\${run_prefix}/source.tar.gz" "\${workdir}/source.tar.gz" --region "\${region}" --only-show-errors
aws s3 cp "s3://\${bucket}/\${run_prefix}/source.patch" "\${workdir}/source.patch" --region "\${region}" --only-show-errors
tar -xzf "\${workdir}/source.tar.gz" -C "\${workdir}/repo"
cd "\${workdir}/repo"
if [[ -s "\${workdir}/source.patch" ]]; then
  git apply --binary "\${workdir}/source.patch"
fi
export MISE_TRUSTED_CONFIG_PATHS="\${PWD}/mise.toml"

mise install
mise exec -- zig build
mise exec -- zig build kvm-boot
mise exec -- env CC='zig cc -target aarch64-linux-musl' scripts/make-smoke-initrd.sh "\${workdir}/ticker.cpio"
scripts/smoke-restore-leg.sh capture \
  --backend kvm \
  --initrd "\${workdir}/ticker.cpio" \
  --spore-dir "\${workdir}/spore" \
  --mem-mib "\${mem_mib}" \
  --snapshot-after-ms "\${snapshot_after_ms}"
zig-out/bin/spore pack "\${workdir}/spore" --out "\${workdir}/spore.bundle"

bundle_bytes="\$(du -sb "\${workdir}/spore.bundle" | awk '{print \$1}')"
packed_chunks="\$(find "\${workdir}/spore.bundle/chunkpacks" -type f | wc -l | tr -d ' ')"
aws s3 cp "\${workdir}/spore.bundle" "s3://\${bucket}/\${run_prefix}/spore.bundle/" --recursive --region "\${region}" --only-show-errors
cat >"\${workdir}/source-result.json" <<JSON
{
  "role": "source",
  "instance_id": "${source_instance}",
  "workdir": "\${workdir}",
  "bundle_bytes": \${bundle_bytes},
  "pack_files": \${packed_chunks},
  "bundle_s3_uri": "s3://\${bucket}/\${run_prefix}/spore.bundle/"
}
JSON
aws s3 cp "\${workdir}/source-result.json" "s3://\${bucket}/\${run_prefix}/source-result.json" --region "\${region}" --only-show-errors
cat "\${workdir}/source-result.json"

if [[ "\${keep_remote}" != "1" ]]; then
  rm -rf "\${workdir}"
fi
EOF

cat >"${dest_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export HOME="\${HOME:-/root}"
export XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\${HOME}/.cache}"
export XDG_DATA_HOME="\${XDG_DATA_HOME:-\${HOME}/.local/share}"
export XDG_STATE_HOME="\${XDG_STATE_HOME:-\${HOME}/.local/state}"
mkdir -p "\${XDG_CACHE_HOME}" "\${XDG_DATA_HOME}" "\${XDG_STATE_HOME}"
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

region=${q_region}
bucket=${q_bucket}
run_prefix=${q_run_prefix}
resume_seconds=${q_resume_seconds}
keep_remote=${q_keep_remote}
workdir="/tmp/sporevm-remote-bundle-dest-${run_id}"

rm -rf "\${workdir}"
mkdir -p "\${workdir}/repo" "\${workdir}/spore.bundle"
aws s3 cp "s3://\${bucket}/\${run_prefix}/source.tar.gz" "\${workdir}/source.tar.gz" --region "\${region}" --only-show-errors
aws s3 cp "s3://\${bucket}/\${run_prefix}/source.patch" "\${workdir}/source.patch" --region "\${region}" --only-show-errors
aws s3 cp "s3://\${bucket}/\${run_prefix}/spore.bundle/" "\${workdir}/spore.bundle" --recursive --region "\${region}" --only-show-errors
bundle_bytes="\$(du -sb "\${workdir}/spore.bundle" | awk '{print \$1}')"
tar -xzf "\${workdir}/source.tar.gz" -C "\${workdir}/repo"
cd "\${workdir}/repo"
if [[ -s "\${workdir}/source.patch" ]]; then
  git apply --binary "\${workdir}/source.patch"
fi
export MISE_TRUSTED_CONFIG_PATHS="\${PWD}/mise.toml"

mise install
mise exec -- zig build
mise exec -- zig build kvm-boot
zig-out/bin/spore unpack "\${workdir}/spore.bundle" --out "\${workdir}/spore.unpacked"
scripts/smoke-restore-leg.sh resume \
  --backend kvm \
  --spore-dir "\${workdir}/spore.unpacked" \
  --resume-seconds "\${resume_seconds}" \
  --kvm-lazy-ram

unpacked_chunks="\$(find "\${workdir}/spore.unpacked/chunks" -type f | wc -l | tr -d ' ')"
cat >"\${workdir}/dest-result.json" <<JSON
{
  "role": "dest",
  "instance_id": "${dest_instance}",
  "workdir": "\${workdir}",
  "downloaded_bundle_bytes": \${bundle_bytes},
  "unpacked_chunks": \${unpacked_chunks},
  "resume_mode": "kvm-lazy-ram"
}
JSON
aws s3 cp "\${workdir}/dest-result.json" "s3://\${bucket}/\${run_prefix}/dest-result.json" --region "\${region}" --only-show-errors
cat "\${workdir}/dest-result.json"

if [[ "\${keep_remote}" != "1" ]]; then
  rm -rf "\${workdir}"
fi
EOF

chmod +x "${source_script}" "${dest_script}"

echo "uploading smoke inputs to ${s3_base}/" >&2
aws s3 cp "${source_archive}" "${s3_base}/source.tar.gz" --region "${region}" --only-show-errors
aws s3 cp "${source_patch}" "${s3_base}/source.patch" --region "${region}" --only-show-errors
aws s3 cp "${source_script}" "${s3_base}/source.sh" --region "${region}" --only-show-errors
aws s3 cp "${dest_script}" "${s3_base}/dest.sh" --region "${region}" --only-show-errors

send_remote_script() {
  local instance_id="$1"
  local script_name="$2"
  local comment="sporevm-remote-bundle-${script_name}-${run_id}"
  local command
  local quoted_command
  local parameters_json
  local remote_script_path
  local remote_script_uri
  local ssm_command
  remote_script_uri="${s3_base}/${script_name}.sh"
  remote_script_path="/tmp/sporevm-${script_name}-${run_id}.sh"
  command="aws s3 cp $(shell_quote "${remote_script_uri}") $(shell_quote "${remote_script_path}") --region $(shell_quote "${region}") --only-show-errors && chmod +x $(shell_quote "${remote_script_path}") && $(shell_quote "${remote_script_path}")"
  quoted_command="$(shell_quote "${command}")"
  ssm_command="bash -lc ${quoted_command}"
  parameters_json="{\"commands\":[\"$(json_escape "${ssm_command}")\"]}"
  aws ssm send-command \
    --region "${region}" \
    --instance-ids "${instance_id}" \
    --document-name AWS-RunShellScript \
    --comment "${comment}" \
    --timeout-seconds "${ssm_timeout_seconds}" \
    --parameters "${parameters_json}" \
    --query 'Command.CommandId' \
    --output text
}

wait_remote_command() {
  local instance_id="$1"
  local command_id="$2"
  local label="$3"
  local status=""
  local elapsed=0

  while :; do
    status="$(aws ssm get-command-invocation \
      --region "${region}" \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --query Status \
      --output text 2>/dev/null || true)"
    case "${status}" in
      Success|Failed|Cancelled|TimedOut|Cancelling) break ;;
      ""|Pending|InProgress|Delayed) ;;
      *) echo "${label}: status=${status}" >&2 ;;
    esac
    sleep 5
    elapsed=$((elapsed + 5))
    if (( elapsed > ssm_timeout_seconds + 60 )); then
      die "timed out waiting for ${label} command ${command_id}"
    fi
  done

  echo "--- ${label} stdout (${status}) ---"
  aws ssm get-command-invocation \
    --region "${region}" \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query StandardOutputContent \
    --output text || true
  echo "--- ${label} stderr (${status}) ---" >&2
  aws ssm get-command-invocation \
    --region "${region}" \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query StandardErrorContent \
    --output text >&2 || true

  [[ "${status}" == "Success" ]] || die "${label} command ${command_id} finished with ${status}"
}

echo "running source capture/pack on ${source_instance}" >&2
source_command_id="$(send_remote_script "${source_instance}" source)"
wait_remote_command "${source_instance}" "${source_command_id}" source

echo "running destination unpack/resume on ${dest_instance}" >&2
dest_command_id="$(send_remote_script "${dest_instance}" dest)"
wait_remote_command "${dest_instance}" "${dest_command_id}" dest

echo "remote bundle smoke ok: source=${source_instance} dest=${dest_instance} s3=${s3_base}/"
aws s3 ls "${s3_base}/" --recursive --region "${region}"
