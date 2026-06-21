#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/validate-release-a1-kvm.sh \
    --region REGION \
    --source-instance INSTANCE_ID \
    --dest-instance INSTANCE_ID [--dest-instance INSTANCE_ID ...] \
    --bucket BUCKET \
    --source-peer-ip IP [options]

Run the A1/KVM release-readiness validation matrix against SSM-managed hosts.
The matrix uses the repo-local remote bundle harness so it validates tracked
HEAD plus the current tracked/staged diff.

Checks:
  1. Direct S3 diskless remote bundle pull with destination cache reuse,
     corrupt bundle rejection, and source-host KVM networking smokes.
  2. Direct S3 chunked-rootfs remote bundle pull with destination rootfs CAS
     materialization/cache reuse and corrupt rootfs rejection.
  3. HTTP peer chunked-rootfs remote bundle pull with destination rootfs CAS
     materialization/cache reuse and corrupt rootfs rejection.

Environment defaults:
  SPOREVM_REMOTE_REGION
  SPOREVM_REMOTE_SOURCE_INSTANCE
  SPOREVM_REMOTE_DEST_INSTANCE      comma-separated destination instance IDs
  SPOREVM_REMOTE_BUCKET
  SPOREVM_REMOTE_SOURCE_PEER_IP
  SPOREVM_REMOTE_PREFIX
  SPOREVM_REMOTE_CACHE_DIR
  SPOREVM_REMOTE_RUN_ID
  SPOREVM_REMOTE_ROOTFS_IMAGE
  SPOREVM_REMOTE_ROOTFS_PLATFORM
  SPOREVM_REMOTE_ROOTFS_MEM_MIB

Options:
  --region REGION             AWS region for SSM and S3
  --source-instance ID        SSM instance ID for capture/pack
  --dest-instance ID          SSM instance ID for pull/resume (repeatable)
  --bucket BUCKET             S3 bucket used as the staging origin
  --source-peer-ip IP         source host IP used for HTTP peer pulls
  --source-peer-port N        source host HTTP port (default: 20000)
  --prefix PREFIX             S3 prefix (default: sporevm/release-a1-kvm)
  --cache-dir DIR             remote host cache root (default: /tmp/sporevm-release-a1-kvm-RUN_ID)
  --run-id ID                 stable run ID prefix
  --mem-mib N                 guest memory size (default: 512)
  --snapshot-after-ms N       capture delay before snapshot (default: 3000)
  --resume-seconds N          seconds to let diskless resumed VM tick (default: 5)
  --dest-repeat N             restores per destination for cache reuse (default: 2)
  --rootfs-image REF          OCI image for rootfs coverage
                              (default: docker.io/library/alpine:3.20)
  --rootfs-platform PLATFORM  OCI platform for rootfs coverage (default: linux/arm64)
  --rootfs-mem-mib N          guest memory for rootfs coverage (default: 2048)
  --ssm-timeout-seconds N     per-host SSM command timeout (default: 1800)
  --skip-network-smokes       skip source-host KVM networking smokes
  --keep-remote               leave remote work directories in /tmp
  -h, --help                  show this help
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

split_csv_destinations() {
  local raw="$1"
  [[ -n "${raw}" ]] || return 0
  local old_ifs="${IFS}"
  IFS=,
  read -r -a parsed_destinations <<<"${raw}"
  IFS="${old_ifs}"
  for dest in "${parsed_destinations[@]}"; do
    [[ -n "${dest}" ]] && dest_instances+=("${dest}")
  done
}

new_run_id() {
  local random_id
  random_id="$(uuidgen 2>/dev/null || openssl rand -hex 16)"
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(tr '[:upper:]' '[:lower:]' <<<"${random_id}")"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

region="${SPOREVM_REMOTE_REGION:-${AWS_REGION:-}}"
source_instance="${SPOREVM_REMOTE_SOURCE_INSTANCE:-}"
dest_instances=()
split_csv_destinations "${SPOREVM_REMOTE_DEST_INSTANCE:-}"
bucket="${SPOREVM_REMOTE_BUCKET:-}"
source_peer_ip="${SPOREVM_REMOTE_SOURCE_PEER_IP:-}"
source_peer_port="${SPOREVM_REMOTE_SOURCE_PEER_PORT:-20000}"
prefix="${SPOREVM_REMOTE_PREFIX:-sporevm/release-a1-kvm}"
cache_dir="${SPOREVM_REMOTE_CACHE_DIR:-}"
run_id="${SPOREVM_REMOTE_RUN_ID:-}"
mem_mib="${SPOREVM_REMOTE_MEM_MIB:-512}"
snapshot_after_ms="${SPOREVM_REMOTE_SNAPSHOT_AFTER_MS:-3000}"
resume_seconds="${SPOREVM_REMOTE_RESUME_SECONDS:-5}"
dest_repeat="${SPOREVM_REMOTE_DEST_REPEAT:-2}"
rootfs_image="${SPOREVM_REMOTE_ROOTFS_IMAGE:-docker.io/library/alpine:3.20}"
rootfs_platform="${SPOREVM_REMOTE_ROOTFS_PLATFORM:-linux/arm64}"
rootfs_mem_mib="${SPOREVM_REMOTE_ROOTFS_MEM_MIB:-2048}"
ssm_timeout_seconds="${SPOREVM_REMOTE_SSM_TIMEOUT_SECONDS:-1800}"
skip_network_smokes=0
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
      dest_instances+=("$2")
      shift 2
      ;;
    --bucket)
      need_value "$1" "${2-}"
      bucket="$2"
      shift 2
      ;;
    --source-peer-ip)
      need_value "$1" "${2-}"
      source_peer_ip="$2"
      shift 2
      ;;
    --source-peer-port)
      need_value "$1" "${2-}"
      source_peer_port="$2"
      shift 2
      ;;
    --prefix)
      need_value "$1" "${2-}"
      prefix="${2%/}"
      shift 2
      ;;
    --cache-dir)
      need_value "$1" "${2-}"
      cache_dir="$2"
      shift 2
      ;;
    --run-id)
      need_value "$1" "${2-}"
      run_id="$2"
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
    --dest-repeat)
      need_value "$1" "${2-}"
      dest_repeat="$2"
      shift 2
      ;;
    --rootfs-image)
      need_value "$1" "${2-}"
      rootfs_image="$2"
      shift 2
      ;;
    --rootfs-platform)
      need_value "$1" "${2-}"
      rootfs_platform="$2"
      shift 2
      ;;
    --rootfs-mem-mib)
      need_value "$1" "${2-}"
      rootfs_mem_mib="$2"
      shift 2
      ;;
    --ssm-timeout-seconds)
      need_value "$1" "${2-}"
      ssm_timeout_seconds="$2"
      shift 2
      ;;
    --skip-network-smokes)
      skip_network_smokes=1
      shift
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
((${#dest_instances[@]} > 0)) || die "at least one --dest-instance is required"
[[ -n "${bucket}" ]] || die "--bucket is required"
[[ -n "${source_peer_ip}" ]] || die "--source-peer-ip is required"

for pair in \
  "mem-mib:${mem_mib}" \
  "snapshot-after-ms:${snapshot_after_ms}" \
  "resume-seconds:${resume_seconds}" \
  "dest-repeat:${dest_repeat}" \
  "rootfs-mem-mib:${rootfs_mem_mib}" \
  "source-peer-port:${source_peer_port}" \
  "ssm-timeout-seconds:${ssm_timeout_seconds}"
do
  name="${pair%%:*}"
  value="${pair#*:}"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]] || die "--${name} must be a positive integer"
done
((dest_repeat >= 2)) || die "--dest-repeat must be at least 2 to prove destination cache reuse"

if [[ -z "${run_id}" ]]; then
  run_id="$(new_run_id)"
fi
case "${run_id}" in
  *[!A-Za-z0-9._-]*) die "--run-id may only contain letters, digits, '.', '_' and '-'" ;;
esac

if [[ -z "${cache_dir}" ]]; then
  cache_dir="/tmp/sporevm-release-a1-kvm-${run_id}"
fi

base_args=(
  --region "${region}"
  --source-instance "${source_instance}"
  --bucket "${bucket}"
  --prefix "${prefix}"
  --mem-mib "${mem_mib}"
  --snapshot-after-ms "${snapshot_after_ms}"
  --resume-seconds "${resume_seconds}"
  --dest-repeat "${dest_repeat}"
  --source-peer-port "${source_peer_port}"
  --ssm-timeout-seconds "${ssm_timeout_seconds}"
)

all_dest_args=()
peer_dest_args=()
for dest_instance in "${dest_instances[@]}"; do
  all_dest_args+=(--dest-instance "${dest_instance}")
  if [[ "${dest_instance}" != "${source_instance}" ]]; then
    peer_dest_args+=(--dest-instance "${dest_instance}")
  fi
done
if ((keep_remote)); then
  base_args+=(--keep-remote)
fi
((${#peer_dest_args[@]} > 0)) || die "HTTP peer check requires at least one destination that is not the source instance"

common_args=("${base_args[@]}" "${all_dest_args[@]}")
http_peer_args=("${base_args[@]}" "${peer_dest_args[@]}")

network_args=()
if ((skip_network_smokes == 0)); then
  network_args+=(--source-network-smokes)
fi

run_check() {
  local label="$1"
  shift
  printf '\n==> %s\n' "${label}" >&2
  bash "${repo_root}/scripts/smoke-remote-bundle.sh" "$@"
}

run_check "direct S3 diskless bundle, cache reuse, corrupt rejection, KVM networking" \
  "${common_args[@]}" \
  --workload initrd \
  --cache-dir "${cache_dir}/direct-s3-initrd" \
  --run-id "${run_id}-direct-s3-initrd" \
  "${network_args[@]}"

run_check "direct S3 chunked rootfs bundle, CAS reuse, corrupt rootfs rejection" \
  "${common_args[@]}" \
  --workload rootfs \
  --rootfs-image "${rootfs_image}" \
  --rootfs-platform "${rootfs_platform}" \
  --rootfs-mem-mib "${rootfs_mem_mib}" \
  --cache-dir "${cache_dir}/direct-s3-rootfs-cas" \
  --run-id "${run_id}-direct-s3-rootfs-cas"

run_check "HTTP peer chunked rootfs bundle, CAS reuse, corrupt rootfs rejection" \
  "${http_peer_args[@]}" \
  --workload rootfs \
  --rootfs-image "${rootfs_image}" \
  --rootfs-platform "${rootfs_platform}" \
  --rootfs-mem-mib "${rootfs_mem_mib}" \
  --source-peer-ip "${source_peer_ip}" \
  --cache-dir "${cache_dir}/http-rootfs-cas" \
  --run-id "${run_id}-http-rootfs-cas"

printf '\nrelease A1/KVM validation ok: run_id=%s prefix=s3://%s/%s cache_dir=%s\n' \
  "${run_id}" "${bucket}" "${prefix}" "${cache_dir}"
