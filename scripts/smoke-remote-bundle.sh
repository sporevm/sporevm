#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/smoke-remote-bundle.sh \
    --region REGION \
    --source-instance INSTANCE_ID \
    --dest-instance INSTANCE_ID [--dest-instance INSTANCE_ID ...] \
    --bucket BUCKET [options]

Capture a spore on one SSM-managed KVM host, pack it into a chunkpack bundle,
stage the bundle in S3, then unpack and resume it on one or more compatible KVM
hosts. The script uploads tracked HEAD plus the current tracked/staged diff to
S3 so it can validate local changes before they are committed without copying
stray untracked files. Destinations fetch directly from S3 by default; pass
`--source-peer-ip IP` to have destinations fetch the bundle from a temporary
HTTP seed on the source host instead. Pass `--cache-dir` and `--dest-repeat N`
to prove repeated restores on one host can reuse a host-local bundle cache
without refetching from S3 or the source peer. Each destination also corrupts a
fetched bundle copy and asserts `spore unpack` rejects it before the normal
restore path is counted successful. Pass `--tree-relay INSTANCE_ID:IP` one or
more times to make relays fetch from the source peer, resume once, then serve
the same bundle to leaf destinations.

Options:
  --region REGION             AWS region for SSM and S3
  --source-instance ID        SSM instance ID for capture/pack
  --dest-instance ID          SSM instance ID for unpack/resume (repeatable)
  --bucket BUCKET             S3 bucket used as the staging origin
  --prefix PREFIX             S3 prefix (default: sporevm/remote-bundle-smoke)
  --mem-mib N                 guest memory size (default: 512)
  --snapshot-after-ms N       capture delay before snapshot (default: 3000)
  --resume-seconds N          seconds to let resumed VM tick (default: 5)
  --dest-repeat N             restore each destination N times (default: 1)
  --cache-dir DIR             remote host-local bundle cache directory
  --source-peer-ip IP         source host IP destinations use for HTTP bundle fetches
  --source-peer-port N        source host HTTP port (default: 20000)
  --tree-relay ID:IP          relay instance and private IP for source→relay→leaf fan-out
                              (repeatable; relays also run one resume)
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

safe_component() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

region=""
source_instance=""
dest_instances=()
tree_relay_ids=()
tree_relay_ips=()
bucket=""
prefix="sporevm/remote-bundle-smoke"
mem_mib="512"
snapshot_after_ms="3000"
resume_seconds="5"
dest_repeat="1"
cache_dir=""
source_peer_ip=""
source_peer_port="20000"
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
      dest_instances+=("$2")
      shift 2
      ;;
    --tree-relay)
      need_value "$1" "${2-}"
      relay_spec="$2"
      case "${relay_spec}" in
        *:*) ;;
        *) die "--tree-relay must be INSTANCE_ID:IP" ;;
      esac
      relay_id="${relay_spec%%:*}"
      relay_ip="${relay_spec#*:}"
      [[ -n "${relay_id}" && -n "${relay_ip}" ]] || die "--tree-relay must be INSTANCE_ID:IP"
      tree_relay_ids+=("${relay_id}")
      tree_relay_ips+=("${relay_ip}")
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
    --dest-repeat)
      need_value "$1" "${2-}"
      dest_repeat="$2"
      shift 2
      ;;
    --cache-dir)
      need_value "$1" "${2-}"
      cache_dir="$2"
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
(( ${#dest_instances[@]} > 0 )) || die "at least one --dest-instance is required"
[[ -n "${bucket}" ]] || die "--bucket is required"
if (( ${#tree_relay_ids[@]} > 0 )); then
  [[ -n "${source_peer_ip}" ]] || die "--tree-relay requires --source-peer-ip for the source seed"
  [[ "${dest_repeat}" == "1" ]] || die "--tree-relay currently requires --dest-repeat 1"
  [[ -z "${cache_dir}" ]] || die "--tree-relay currently cannot be combined with --cache-dir"
fi
for i in "${!dest_instances[@]}"; do
  for j in "${!dest_instances[@]}"; do
    if (( j > i )) && [[ "${dest_instances[$i]}" == "${dest_instances[$j]}" ]]; then
      die "duplicate --dest-instance ${dest_instances[$i]}; use --dest-repeat for repeated restores on one host"
    fi
  done
  if [[ "${dest_instances[$i]}" == "${source_instance}" && ( -n "${source_peer_ip}" || "${#tree_relay_ids[@]}" -gt 0 ) ]]; then
    die "source instance can only also be a destination in direct S3 mode"
  fi
done
for i in "${!tree_relay_ids[@]}"; do
  [[ "${tree_relay_ids[$i]}" != "${source_instance}" ]] || die "source instance cannot also be a tree relay"
  for j in "${!tree_relay_ids[@]}"; do
    if (( j > i )) && [[ "${tree_relay_ids[$i]}" == "${tree_relay_ids[$j]}" ]]; then
      die "duplicate --tree-relay instance ${tree_relay_ids[$i]}"
    fi
  done
  for dest_instance in "${dest_instances[@]}"; do
    [[ "${tree_relay_ids[$i]}" != "${dest_instance}" ]] || die "tree relay ${tree_relay_ids[$i]} should not also be listed as --dest-instance"
  done
done

for pair in \
  "mem-mib:${mem_mib}" \
  "snapshot-after-ms:${snapshot_after_ms}" \
  "resume-seconds:${resume_seconds}" \
  "dest-repeat:${dest_repeat}" \
  "source-peer-port:${source_peer_port}" \
  "ssm-timeout-seconds:${ssm_timeout_seconds}"
do
  name="${pair%%:*}"
  value="${pair#*:}"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]] || die "--${name} must be a positive integer"
done

command -v aws >/dev/null 2>&1 || die "aws CLI is required"
command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [[ -z "${run_id}" ]]; then
  random_id="$(uuidgen 2>/dev/null || openssl rand -hex 16)"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(tr '[:upper:]' '[:lower:]' <<<"${random_id}")"
fi
case "${run_id}" in
  *[!A-Za-z0-9._-]*) die "--run-id may only contain letters, digits, '.', '_' and '-'" ;;
esac
run_prefix="${prefix%/}/${run_id}"
s3_base="s3://${bucket}/${run_prefix}"
child_count="${#dest_instances[@]}"
if (( ${#tree_relay_ids[@]} > child_count )); then
  child_count="${#tree_relay_ids[@]}"
fi
if (( dest_repeat > child_count )); then
  child_count="${dest_repeat}"
fi
if (( child_count <= 0 )); then
  child_count=1
fi

q_region="$(shell_quote "${region}")"
q_bucket="$(shell_quote "${bucket}")"
q_run_prefix="$(shell_quote "${run_prefix}")"
q_child_count="$(shell_quote "${child_count}")"
q_mem_mib="$(shell_quote "${mem_mib}")"
q_snapshot_after_ms="$(shell_quote "${snapshot_after_ms}")"
q_resume_seconds="$(shell_quote "${resume_seconds}")"
q_dest_repeat="$(shell_quote "${dest_repeat}")"
q_cache_dir="$(shell_quote "${cache_dir}")"
q_source_peer_ip="$(shell_quote "${source_peer_ip}")"
q_source_peer_port="$(shell_quote "${source_peer_port}")"
q_keep_remote="$(shell_quote "${keep_remote}")"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-remote-bundle.XXXXXX")"
source_peer_started=0
relay_peer_started_ids=()
relay_peer_started_safes=()

cleanup_remote_workdir() {
  local instance_id="$1"
  local workdir="$2"
  local comment="$3"
  local q_workdir
  local command
  local quoted_command
  local ssm_command
  local parameters_json
  q_workdir="$(shell_quote "${workdir}")"
  command="if [ -f ${q_workdir}/peer-http.pid ]; then kill \$(cat ${q_workdir}/peer-http.pid) 2>/dev/null || true; fi; rm -rf ${q_workdir}"
  quoted_command="$(shell_quote "${command}")"
  ssm_command="bash -lc ${quoted_command}"
  parameters_json="{\"commands\":[\"$(json_escape "${ssm_command}")\"]}"
  aws ssm send-command \
    --region "${region}" \
    --instance-ids "${instance_id}" \
    --document-name AWS-RunShellScript \
    --comment "${comment}" \
    --timeout-seconds 60 \
    --parameters "${parameters_json}" \
    --query 'Command.CommandId' \
    --output text >/dev/null 2>&1 || true
}

cleanup_remote_source() {
  if (( source_peer_started == 0 )) || [[ "${keep_remote}" == "1" ]]; then
    return 0
  fi

  local workdir="/tmp/sporevm-remote-bundle-source-${run_id}"
  cleanup_remote_workdir "${source_instance}" "${workdir}" "sporevm-remote-bundle-cleanup-${run_id}"
  source_peer_started=0
}

cleanup_remote_relays() {
  if [[ "${keep_remote}" == "1" ]]; then
    return 0
  fi
  for i in "${!relay_peer_started_ids[@]}"; do
    local instance_id="${relay_peer_started_ids[$i]}"
    local safe_dest="${relay_peer_started_safes[$i]}"
    local workdir="/tmp/sporevm-remote-bundle-dest-${run_id}-${safe_dest}"
    cleanup_remote_workdir "${instance_id}" "${workdir}" "sporevm-remote-bundle-relay-cleanup-${run_id}"
  done
  relay_peer_started_ids=()
  relay_peer_started_safes=()
}

cleanup() {
  local status=$?
  rm -rf "${tmpdir}"
  cleanup_remote_source
  cleanup_remote_relays
  exit "${status}"
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
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

region=${q_region}
bucket=${q_bucket}
run_prefix=${q_run_prefix}
child_count=${q_child_count}
mem_mib=${q_mem_mib}
snapshot_after_ms=${q_snapshot_after_ms}
source_peer_ip=${q_source_peer_ip}
source_peer_port=${q_source_peer_port}
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
zig-out/bin/spore fork "\${workdir}/spore" --count "\${child_count}" --out "\${workdir}/spore.children" | tee "\${workdir}/fork-result.json"
zig-out/bin/spore pack "\${workdir}/spore" --children "\${workdir}/spore.children" --out "\${workdir}/spore.bundle" | tee "\${workdir}/pack-result.json"

bundle_bytes="\$(du -sb "\${workdir}/spore.bundle" | awk '{print \$1}')"
unique_chunk_bytes="\$(du -sb "\${workdir}/spore.bundle/chunkpacks/000000.pack" | awk '{print \$1}')"
bundle_key="\$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["bundle_digest"])' "\${workdir}/pack-result.json")"
packed_chunks="\$(find "\${workdir}/spore.bundle/chunkpacks" -type f | wc -l | tr -d ' ')"
bundle_archive_bytes=0
source_peer_url=""
if [[ -n "\${source_peer_ip}" ]]; then
  mkdir -p "\${workdir}/peer-www"
  tar -cf "\${workdir}/peer-www/spore.bundle.tar" -C "\${workdir}" spore.bundle
  bundle_archive_bytes="\$(wc -c <"\${workdir}/peer-www/spore.bundle.tar" | tr -d ' ')"
  source_peer_url="http://\${source_peer_ip}:\${source_peer_port}/spore.bundle.tar"
  nohup python3 -m http.server "\${source_peer_port}" --bind 0.0.0.0 --directory "\${workdir}/peer-www" >"\${workdir}/peer-http.log" 2>&1 &
  printf '%s\n' "\$!" >"\${workdir}/peer-http.pid"
  sleep 1
  if ! kill -0 "\$(cat "\${workdir}/peer-http.pid")" 2>/dev/null; then
    cat "\${workdir}/peer-http.log" >&2 || true
    exit 1
  fi
fi
zig-out/bin/spore push "\${workdir}/spore.bundle" "s3://\${bucket}/\${run_prefix}/spore.bundle/" --region "\${region}" | tee "\${workdir}/push-result.json"
printf '%s\n' "\${bundle_key}" >"\${workdir}/bundle-key.txt"
aws s3 cp "\${workdir}/bundle-key.txt" "s3://\${bucket}/\${run_prefix}/bundle-key.txt" --region "\${region}" --only-show-errors
cat >"\${workdir}/source-result.json" <<JSON
{
  "role": "source",
  "instance_id": "${source_instance}",
  "workdir": "\${workdir}",
  "bundle_bytes": \${bundle_bytes},
  "unique_chunk_bytes": \${unique_chunk_bytes},
  "bundle_key": "\${bundle_key}",
  "bundle_archive_bytes": \${bundle_archive_bytes},
  "pack_files": \${packed_chunks},
  "bundle_s3_uri": "s3://\${bucket}/\${run_prefix}/spore.bundle/",
  "source_peer_url": "\${source_peer_url}"
}
JSON
aws s3 cp "\${workdir}/source-result.json" "s3://\${bucket}/\${run_prefix}/source-result.json" --region "\${region}" --only-show-errors
cat "\${workdir}/source-result.json"

if [[ "\${keep_remote}" != "1" && -z "\${source_peer_ip}" ]]; then
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
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

region=${q_region}
bucket=${q_bucket}
run_prefix=${q_run_prefix}
child_count=${q_child_count}
resume_seconds=${q_resume_seconds}
dest_repeat=${q_dest_repeat}
cache_dir=${q_cache_dir}
source_peer_ip=${q_source_peer_ip}
source_peer_port=${q_source_peer_port}
keep_remote=${q_keep_remote}
dest_instance="\${SPOREVM_DEST_INSTANCE:?SPOREVM_DEST_INSTANCE is required}"
dest_role="\${SPOREVM_DEST_ROLE:-dest}"
child_id="\${SPOREVM_CHILD_ID:-0}"
case "\${child_id}" in
  ''|*[!0-9]*) echo "SPOREVM_CHILD_ID must be a non-negative integer" >&2; exit 1 ;;
esac
peer_ip="\${SPOREVM_PEER_IP:-\${source_peer_ip}}"
serve_bundle="\${SPOREVM_SERVE_BUNDLE:-0}"
safe_dest="\$(printf '%s' "\${dest_instance}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
workdir="/tmp/sporevm-remote-bundle-dest-${run_id}-\${safe_dest}"

rm -rf "\${workdir}"
mkdir -p "\${workdir}/repo"
aws s3 cp "s3://\${bucket}/\${run_prefix}/source.tar.gz" "\${workdir}/source.tar.gz" --region "\${region}" --only-show-errors
aws s3 cp "s3://\${bucket}/\${run_prefix}/source.patch" "\${workdir}/source.patch" --region "\${region}" --only-show-errors
aws s3 cp "s3://\${bucket}/\${run_prefix}/bundle-key.txt" "\${workdir}/bundle-key.txt" --region "\${region}" --only-show-errors
bundle_key="\$(tr -d '\n' <"\${workdir}/bundle-key.txt")"
tar -xzf "\${workdir}/source.tar.gz" -C "\${workdir}/repo"
cd "\${workdir}/repo"
if [[ -s "\${workdir}/source.patch" ]]; then
  git apply --binary "\${workdir}/source.patch"
fi
export MISE_TRUSTED_CONFIG_PATHS="\${PWD}/mise.toml"

mise install
mise exec -- zig build
mise exec -- zig build kvm-boot

json_field() {
  python3 -c 'import json, sys; value=json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]; print(str(value).lower() if isinstance(value, bool) else value)' "\$1" "\$2"
}

fetch_bundle() {
  local out_dir="\$1"
  local origin_bytes_var="\$2"
  local peer_bytes_var="\$3"

  rm -rf "\${out_dir}"
  if [[ -n "\${peer_ip}" ]]; then
    local tar_path="\${out_dir}.tar"
    mkdir -p "\$(dirname "\${out_dir}")"
    python3 - "\${peer_ip}" "\${source_peer_port}" "\${tar_path}" <<'PY'
import sys
import urllib.request

ip, port, out_path = sys.argv[1:4]
url = f"http://{ip}:{port}/spore.bundle.tar"
with urllib.request.urlopen(url, timeout=300) as response, open(out_path, "wb") as out:
    while True:
        chunk = response.read(1024 * 1024)
        if not chunk:
            break
        out.write(chunk)
PY
    local peer_download_size
    peer_download_size="\$(wc -c <"\${tar_path}" | tr -d ' ')"
    while IFS= read -r member; do
      case "\${member}" in
        spore.bundle|spore.bundle/*) ;;
        *) echo "unexpected peer bundle tar member: \${member}" >&2; exit 1 ;;
      esac
      case "\${member}" in
        /*|..|../*|*/..|*/../*) echo "unsafe peer bundle tar member: \${member}" >&2; exit 1 ;;
      esac
    done < <(tar -tf "\${tar_path}")
    tar -xf "\${tar_path}" -C "\$(dirname "\${out_dir}")"
    rm -f "\${tar_path}"
    [[ -d "\${out_dir}" ]] || { echo "peer bundle extraction did not create \${out_dir}" >&2; exit 1; }
    printf -v "\${origin_bytes_var}" '%s' 0
    printf -v "\${peer_bytes_var}" '%s' "\${peer_download_size}"
    return
  fi

  mkdir -p "\${out_dir}"
  aws s3 cp "s3://\${bucket}/\${run_prefix}/spore.bundle/" "\${out_dir}" --recursive --region "\${region}" --only-show-errors
  local direct_bytes
  direct_bytes="\$(du -sb "\${out_dir}" | awk '{print \$1}')"
  printf -v "\${origin_bytes_var}" '%s' "\${direct_bytes}"
  printf -v "\${peer_bytes_var}" '%s' 0
}

materialize_bundle() {
  local out_dir="\$1"
  local cache_hit_var="\$2"
  local origin_bytes_var="\$3"
  local peer_bytes_var="\$4"

  if [[ -z "\${cache_dir}" ]]; then
    fetch_bundle "\${out_dir}" origin_bytes peer_bytes
    printf -v "\${cache_hit_var}" '%s' false
    printf -v "\${origin_bytes_var}" '%s' "\${origin_bytes}"
    printf -v "\${peer_bytes_var}" '%s' "\${peer_bytes}"
    return
  fi

  local cache_bundle_dir="\${cache_dir}/\${bundle_key}/spore.bundle"
  local cache_complete="\${cache_dir}/\${bundle_key}/.complete"
  if [[ -f "\${cache_complete}" ]]; then
    mkdir -p "\${out_dir}"
    cp -R "\${cache_bundle_dir}/." "\${out_dir}/"
    printf -v "\${cache_hit_var}" '%s' true
    printf -v "\${origin_bytes_var}" '%s' 0
    printf -v "\${peer_bytes_var}" '%s' 0
    return
  fi

  local cache_tmp="\${cache_dir}/.tmp-\${bundle_key}-\${safe_dest}-\$\$"
  rm -rf "\${cache_tmp}"
  fetch_bundle "\${cache_tmp}/spore.bundle" fetched_origin_bytes fetched_peer_bytes
  mkdir -p "\${cache_dir}/\${bundle_key}"
  rm -rf "\${cache_bundle_dir}"
  mv "\${cache_tmp}/spore.bundle" "\${cache_bundle_dir}"
  : >"\${cache_complete}"
  rm -rf "\${cache_tmp}"
  mkdir -p "\${out_dir}"
  cp -R "\${cache_bundle_dir}/." "\${out_dir}/"
  printf -v "\${cache_hit_var}" '%s' false
  printf -v "\${origin_bytes_var}" '%s' "\${fetched_origin_bytes}"
  printf -v "\${peer_bytes_var}" '%s' "\${fetched_peer_bytes}"
}

assert_corrupt_bundle_rejected() {
  local bundle_dir="\$1"
  local iteration="\$2"
  local corrupt_dir="\${workdir}/corrupt-\${iteration}.bundle"
  local corrupt_out="\${workdir}/corrupt-\${iteration}.unpacked"
  local corrupt_log="\${workdir}/corrupt-\${iteration}.log"

  rm -rf "\${corrupt_dir}" "\${corrupt_out}" "\${corrupt_log}"
  mkdir -p "\${corrupt_dir}"
  cp -a "\${bundle_dir}/." "\${corrupt_dir}/"
  python3 - "\${corrupt_dir}/chunkpacks/000000.pack" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
if not data:
    raise SystemExit("cannot corrupt empty chunkpack")
data[0] ^= 0x01
path.write_bytes(data)
PY
  if zig-out/bin/spore unpack "\${corrupt_dir}" --out "\${corrupt_out}" >"\${corrupt_log}" 2>&1; then
    cat "\${corrupt_log}" >&2 || true
    echo "corrupt bundle unexpectedly unpacked successfully" >&2
    exit 1
  fi
  rm -rf "\${corrupt_dir}" "\${corrupt_out}"
}

start_peer_server() {
  local bundle_dir="\$1"
  local serve_dir="\${workdir}/peer-www"
  rm -rf "\${serve_dir}"
  mkdir -p "\${serve_dir}"
  tar -cf "\${serve_dir}/spore.bundle.tar" -C "\$(dirname "\${bundle_dir}")" "\$(basename "\${bundle_dir}")"
  nohup python3 -m http.server "\${source_peer_port}" --bind 0.0.0.0 --directory "\${serve_dir}" >"\${workdir}/peer-http.log" 2>&1 &
  printf '%s\n' "\$!" >"\${workdir}/peer-http.pid"
  sleep 1
  if ! kill -0 "\$(cat "\${workdir}/peer-http.pid")" 2>/dev/null; then
    cat "\${workdir}/peer-http.log" >&2 || true
    exit 1
  fi
  wc -c <"\${serve_dir}/spore.bundle.tar" | tr -d ' '
}

if [[ -n "\${cache_dir}" ]]; then
  mkdir -p "\${cache_dir}"
fi

total_origin_bytes=0
total_peer_bytes=0
total_download_bytes=0
total_chunk_bytes_fetched=0
total_rootfs_bytes_fetched=0
total_rootfs_cache_hits=0
total_rootfs_cache_misses=0
cache_hits=0
cache_misses=0
corrupt_bundle_rejections=0
local_bundle_bytes=0
served_bundle_archive_bytes=0
unpacked_chunks=0
iteration_json=""
for iteration in \$(seq 1 "\${dest_repeat}"); do
  iter_dir="\${workdir}/resume-\${iteration}"
  bundle_dir="\${iter_dir}/spore.bundle"
  unpacked_dir="\${iter_dir}/spore.unpacked"
  unpack_result="\${iter_dir}/unpack-result.json"
  child_base=\$((10#\${child_id}))
  iteration_child_id="\${child_base}"
  if [[ -z "\${peer_ip}" ]]; then
    iteration_child_id="\$(( (child_base + iteration - 1) % child_count ))"
  fi
  selected_child=""
  chunk_bytes_fetched=0
  rootfs_artifact_count=0
  rootfs_bytes_fetched=0
  rootfs_cache_hits=0
  rootfs_cache_misses=0
  if [[ -z "\${peer_ip}" ]]; then
    mkdir -p "\${iter_dir}"
    if [[ -n "\${cache_dir}" ]]; then
      pull_bundle_cache="\${cache_dir}"
    else
      pull_bundle_cache="\${iter_dir}/bundle-cache"
    fi
    pull_source="s3://\${bucket}/\${run_prefix}/spore.bundle@sha256:\${bundle_key}"
    pull_rootfs_cache="\${pull_bundle_cache}/rootfs-cache"
    SPOREVM_BUNDLE_CACHE_DIR="\${pull_bundle_cache}" \
      SPOREVM_ROOTFS_CACHE_DIR="\${pull_rootfs_cache}" \
      zig-out/bin/spore pull "\${pull_source}" --child "\${iteration_child_id}" --out "\${unpacked_dir}" --region "\${region}" | tee "\${unpack_result}"
    cache_hit="\$(json_field "\${unpack_result}" remote_bundle_cache_hit)"
    origin_bytes="\$(json_field "\${unpack_result}" origin_bytes_read)"
    selected_child="\$(json_field "\${unpack_result}" selected_child)"
    chunk_bytes_fetched="\$(json_field "\${unpack_result}" chunk_bytes_fetched)"
    rootfs_artifact_count="\$(json_field "\${unpack_result}" rootfs_artifact_count)"
    rootfs_bytes_fetched="\$(json_field "\${unpack_result}" rootfs_bytes_fetched)"
    rootfs_cache_hits="\$(json_field "\${unpack_result}" rootfs_cache_hit_count)"
    rootfs_cache_misses="\$(json_field "\${unpack_result}" rootfs_cache_miss_count)"
    expected_child="\$(printf '%06d' "\${iteration_child_id}")"
    if [[ "\${selected_child}" != "\${expected_child}" ]]; then
      echo "spore pull selected child \${selected_child}, expected \${expected_child}" >&2
      exit 1
    fi
    if [[ -n "\${cache_dir}" && "\${iteration}" -gt 1 ]]; then
      [[ "\${cache_hit}" == "true" ]] || { echo "repeat pull did not hit remote bundle cache" >&2; exit 1; }
      [[ "\${origin_bytes}" == "0" ]] || { echo "repeat pull fetched \${origin_bytes} origin bytes, expected 0" >&2; exit 1; }
      [[ "\${chunk_bytes_fetched}" == "0" ]] || { echo "repeat pull fetched \${chunk_bytes_fetched} chunk bytes, expected 0" >&2; exit 1; }
      if [[ "\${rootfs_artifact_count}" -gt 0 ]]; then
        [[ "\${rootfs_bytes_fetched}" == "0" ]] || { echo "repeat pull fetched \${rootfs_bytes_fetched} rootfs bytes, expected 0" >&2; exit 1; }
      fi
    fi
    peer_bytes=0
    bundle_dir="\${pull_bundle_cache}/remote/s3/sha256/\${bundle_key}/bundle"
  else
    materialize_bundle "\${bundle_dir}" cache_hit origin_bytes peer_bytes
  fi
  if [[ "\${cache_hit}" == "true" ]]; then
    cache_hits=\$((cache_hits + 1))
  else
    cache_misses=\$((cache_misses + 1))
  fi
  downloaded_bytes=\$((origin_bytes + peer_bytes))
  total_origin_bytes=\$((total_origin_bytes + origin_bytes))
  total_peer_bytes=\$((total_peer_bytes + peer_bytes))
  total_download_bytes=\$((total_download_bytes + downloaded_bytes))
  total_chunk_bytes_fetched=\$((total_chunk_bytes_fetched + chunk_bytes_fetched))
  total_rootfs_bytes_fetched=\$((total_rootfs_bytes_fetched + rootfs_bytes_fetched))
  total_rootfs_cache_hits=\$((total_rootfs_cache_hits + rootfs_cache_hits))
  total_rootfs_cache_misses=\$((total_rootfs_cache_misses + rootfs_cache_misses))
  local_bundle_bytes="\$(du -sb "\${bundle_dir}" | awk '{print \$1}')"
  corrupt_rejected=false
  if [[ "\${iteration}" == "1" ]]; then
    assert_corrupt_bundle_rejected "\${bundle_dir}" "\${iteration}"
    corrupt_bundle_rejections=\$((corrupt_bundle_rejections + 1))
    corrupt_rejected=true
  fi
  if [[ -n "\${peer_ip}" ]]; then
    zig-out/bin/spore unpack "\${bundle_dir}" --out "\${unpacked_dir}" | tee "\${unpack_result}"
  fi
  unpack_bundle_key="\$(json_field "\${unpack_result}" bundle_digest)"
  if [[ "\${unpack_bundle_key}" != "\${bundle_key}" ]]; then
    echo "unpacked bundle digest mismatch: expected \${bundle_key}, got \${unpack_bundle_key}" >&2
    exit 1
  fi
  if [[ "\${serve_bundle}" == "1" && "\${iteration}" == "1" ]]; then
    served_bundle_archive_bytes="\$(start_peer_server "\${bundle_dir}")"
  fi
  scripts/smoke-restore-leg.sh resume \
    --backend kvm \
    --spore-dir "\${unpacked_dir}" \
    --resume-seconds "\${resume_seconds}" \
    --kvm-lazy-ram
  unpacked_chunks="\$(find "\${unpacked_dir}/chunks" -type f | wc -l | tr -d ' ')"
  if [[ -n "\${iteration_json}" ]]; then
    iteration_json="\${iteration_json},"
  fi
  iteration_json="\${iteration_json}{\"iteration\":\${iteration},\"requested_child\":\"\${iteration_child_id}\",\"selected_child\":\"\${selected_child}\",\"cache_hit\":\${cache_hit},\"downloaded_bundle_bytes\":\${downloaded_bytes},\"origin_downloaded_bundle_bytes\":\${origin_bytes},\"peer_downloaded_bundle_bytes\":\${peer_bytes},\"chunk_bytes_fetched\":\${chunk_bytes_fetched},\"rootfs_artifact_count\":\${rootfs_artifact_count},\"rootfs_bytes_fetched\":\${rootfs_bytes_fetched},\"rootfs_cache_hits\":\${rootfs_cache_hits},\"rootfs_cache_misses\":\${rootfs_cache_misses},\"local_bundle_bytes\":\${local_bundle_bytes},\"unpacked_bundle_key\":\"\${unpack_bundle_key}\",\"unpacked_chunks\":\${unpacked_chunks},\"corrupt_bundle_rejected\":\${corrupt_rejected}}"
done

cache_enabled=false
if [[ -n "\${cache_dir}" ]]; then
  cache_enabled=true
fi
source_peer_enabled=false
if [[ -n "\${peer_ip}" ]]; then
  source_peer_enabled=true
fi
serves_bundle=false
if [[ "\${serve_bundle}" == "1" ]]; then
  serves_bundle=true
fi

cat >"\${workdir}/dest-result.json" <<JSON
{
  "role": "\${dest_role}",
  "instance_id": "\${dest_instance}",
  "workdir": "\${workdir}",
  "upstream_peer_ip": "\${peer_ip}",
  "serves_bundle": \${serves_bundle},
  "served_bundle_archive_bytes": \${served_bundle_archive_bytes},
  "downloaded_bundle_bytes": \${total_download_bytes},
  "origin_downloaded_bundle_bytes": \${total_origin_bytes},
  "peer_downloaded_bundle_bytes": \${total_peer_bytes},
  "chunk_bytes_fetched": \${total_chunk_bytes_fetched},
  "rootfs_bytes_fetched": \${total_rootfs_bytes_fetched},
  "rootfs_cache_hits": \${total_rootfs_cache_hits},
  "rootfs_cache_misses": \${total_rootfs_cache_misses},
  "local_bundle_bytes": \${local_bundle_bytes},
  "bundle_key": "\${bundle_key}",
  "cache_enabled": \${cache_enabled},
  "source_peer_enabled": \${source_peer_enabled},
  "cache_hits": \${cache_hits},
  "cache_misses": \${cache_misses},
  "corrupt_bundle_rejections": \${corrupt_bundle_rejections},
  "resume_count": \${dest_repeat},
  "unpacked_chunks": \${unpacked_chunks},
  "resume_mode": "kvm-lazy-ram",
  "iterations": [\${iteration_json}]
}
JSON
aws s3 cp "\${workdir}/dest-result.json" "s3://\${bucket}/\${run_prefix}/dest-results/\${safe_dest}.json" --region "\${region}" --only-show-errors
cat "\${workdir}/dest-result.json"

if [[ "\${keep_remote}" != "1" && "\${serve_bundle}" != "1" ]]; then
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
  local dest_instance_arg="${3-}"
  local peer_ip_arg="${4-}"
  local dest_role_arg="${5-}"
  local serve_bundle_arg="${6-}"
  local child_id_arg="${7-}"
  local comment="sporevm-remote-bundle-${script_name}-${run_id}"
  local command
  local quoted_command
  local parameters_json
  local remote_script_path
  local remote_script_uri
  local remote_invocation
  local env_prefix=""
  local ssm_command
  remote_script_uri="${s3_base}/${script_name}.sh"
  remote_script_path="/tmp/sporevm-${script_name}-${run_id}.sh"
  remote_invocation="$(shell_quote "${remote_script_path}")"
  if [[ -n "${dest_instance_arg}" ]]; then
    env_prefix="${env_prefix} SPOREVM_DEST_INSTANCE=$(shell_quote "${dest_instance_arg}")"
  fi
  if [[ -n "${peer_ip_arg}" ]]; then
    env_prefix="${env_prefix} SPOREVM_PEER_IP=$(shell_quote "${peer_ip_arg}")"
  fi
  if [[ -n "${dest_role_arg}" ]]; then
    env_prefix="${env_prefix} SPOREVM_DEST_ROLE=$(shell_quote "${dest_role_arg}")"
  fi
  if [[ -n "${serve_bundle_arg}" ]]; then
    env_prefix="${env_prefix} SPOREVM_SERVE_BUNDLE=$(shell_quote "${serve_bundle_arg}")"
  fi
  if [[ -n "${child_id_arg}" ]]; then
    env_prefix="${env_prefix} SPOREVM_CHILD_ID=$(shell_quote "${child_id_arg}")"
  fi
  remote_invocation="${env_prefix# } ${remote_invocation}"
  command="aws s3 cp $(shell_quote "${remote_script_uri}") $(shell_quote "${remote_script_path}") --region $(shell_quote "${region}") --only-show-errors && chmod +x $(shell_quote "${remote_script_path}") && ${remote_invocation}"
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
if [[ -n "${source_peer_ip}" && "${keep_remote}" != "1" ]]; then
  source_peer_started=1
fi
wait_remote_command "${source_instance}" "${source_command_id}" source

dest_command_ids=()
dest_safe_names=()
if (( ${#tree_relay_ids[@]} > 0 )); then
  relay_command_ids=()
  relay_safe_names=()
  for i in "${!tree_relay_ids[@]}"; do
    relay_instance="${tree_relay_ids[$i]}"
    relay_ip="${tree_relay_ips[$i]}"
    relay_safe="$(safe_component "${relay_instance}")"
    echo "starting relay unpack/resume/serve on ${relay_instance} (${relay_ip})" >&2
    relay_command_ids+=("$(send_remote_script "${relay_instance}" dest "${relay_instance}" "${source_peer_ip}" relay 1 "${i}")")
    relay_safe_names+=("${relay_safe}")
    relay_peer_started_ids+=("${relay_instance}")
    relay_peer_started_safes+=("${relay_safe}")
  done

  for i in "${!tree_relay_ids[@]}"; do
    wait_remote_command "${tree_relay_ids[$i]}" "${relay_command_ids[$i]}" "relay:${tree_relay_ids[$i]}"
    dest_safe_names+=("${relay_safe_names[$i]}")
  done

  for i in "${!dest_instances[@]}"; do
    dest_instance="${dest_instances[$i]}"
    relay_index=$(( i % ${#tree_relay_ids[@]} ))
    relay_ip="${tree_relay_ips[$relay_index]}"
    echo "starting leaf unpack/resume on ${dest_instance} via relay ${tree_relay_ids[$relay_index]} (${relay_ip})" >&2
    dest_command_ids+=("$(send_remote_script "${dest_instance}" dest "${dest_instance}" "${relay_ip}" leaf 0 "${i}")")
    dest_safe_names+=("$(safe_component "${dest_instance}")")
  done

  for i in "${!dest_instances[@]}"; do
    wait_remote_command "${dest_instances[$i]}" "${dest_command_ids[$i]}" "leaf:${dest_instances[$i]}"
  done
else
  for i in "${!dest_instances[@]}"; do
    dest_instance="${dest_instances[$i]}"
    echo "starting destination unpack/resume on ${dest_instance}" >&2
    dest_command_ids+=("$(send_remote_script "${dest_instance}" dest "${dest_instance}" "" "" "" "${i}")")
    dest_safe_names+=("$(safe_component "${dest_instance}")")
  done

  for i in "${!dest_instances[@]}"; do
    wait_remote_command "${dest_instances[$i]}" "${dest_command_ids[$i]}" "dest:${dest_instances[$i]}"
  done
fi

metrics_path="${tmpdir}/metrics.json"
source_result_path="${tmpdir}/source-result.json"
dest_result_paths=()
aws s3 cp "${s3_base}/source-result.json" "${source_result_path}" --region "${region}" --only-show-errors
for safe_dest in "${dest_safe_names[@]}"; do
  dest_result_path="${tmpdir}/dest-${safe_dest}.json"
  aws s3 cp "${s3_base}/dest-results/${safe_dest}.json" "${dest_result_path}" --region "${region}" --only-show-errors
  dest_result_paths+=("${dest_result_path}")
done

python3 - "${run_id}" "${s3_base}/" "${source_result_path}" "${dest_result_paths[@]}" >"${metrics_path}" <<'PY'
import json
import sys
from urllib.parse import urlparse

run_id = sys.argv[1]
s3_uri = sys.argv[2]
source_path = sys.argv[3]
dest_paths = sys.argv[4:]

with open(source_path, "r", encoding="utf-8") as f:
    source = json.load(f)
dests = []
for path in dest_paths:
    with open(path, "r", encoding="utf-8") as f:
        dests.append(json.load(f))

bundle_bytes = int(source["bundle_bytes"])
unique_chunk_bytes = int(source["unique_chunk_bytes"])
total_destination_download_bytes = sum(int(d["downloaded_bundle_bytes"]) for d in dests)
total_destination_origin_bytes = sum(int(d.get("origin_downloaded_bundle_bytes", d["downloaded_bundle_bytes"])) for d in dests)
total_destination_peer_bytes = sum(int(d.get("peer_downloaded_bundle_bytes", 0)) for d in dests)
total_chunk_bytes_fetched = sum(int(d.get("chunk_bytes_fetched", 0)) for d in dests)
total_rootfs_bytes_fetched = sum(int(d.get("rootfs_bytes_fetched", 0)) for d in dests)
total_rootfs_cache_hits = sum(int(d.get("rootfs_cache_hits", 0)) for d in dests)
total_rootfs_cache_misses = sum(int(d.get("rootfs_cache_misses", 0)) for d in dests)
total_resume_count = sum(int(d.get("resume_count", 1)) for d in dests)
total_cache_hits = sum(int(d.get("cache_hits", 0)) for d in dests)
total_cache_misses = sum(int(d.get("cache_misses", 0)) for d in dests)
total_corrupt_bundle_rejections = sum(int(d.get("corrupt_bundle_rejections", 0)) for d in dests)
cache_enabled = any(bool(d.get("cache_enabled", False)) for d in dests)
source_peer_enabled = any(bool(d.get("source_peer_enabled", False)) for d in dests)
relays = [d for d in dests if d.get("role") == "relay"]
leaves = [d for d in dests if d.get("role") == "leaf"]
source_peer_host = urlparse(source.get("source_peer_url", "")).hostname or ""
peer_egress_by_upstream = {}
for dest in dests:
    upstream = dest.get("upstream_peer_ip") or ""
    peer_bytes = int(dest.get("peer_downloaded_bundle_bytes", 0))
    if upstream and peer_bytes:
        peer_egress_by_upstream[upstream] = peer_egress_by_upstream.get(upstream, 0) + peer_bytes
source_peer_egress_bytes = peer_egress_by_upstream.get(source_peer_host, 0)
relay_peer_egress_bytes = total_destination_peer_bytes - source_peer_egress_bytes
max_peer_egress_bytes = max(peer_egress_by_upstream.values(), default=0)

if relays:
    origin_mode = "source-peer-http-tree"
elif source_peer_enabled and cache_enabled:
    origin_mode = "source-peer-http-with-host-local-cache"
elif source_peer_enabled:
    origin_mode = "source-peer-http"
elif cache_enabled:
    origin_mode = "host-local-bundle-cache"
else:
    origin_mode = "direct-s3-per-destination"

def ratio(numerator, denominator):
    if denominator == 0:
        return None
    return round(numerator / denominator, 6)

json.dump({
    "run_id": run_id,
    "s3_uri": s3_uri,
    "source_instance": source["instance_id"],
    "destination_count": len(dests),
    "relay_count": len(relays),
    "leaf_count": len(leaves),
    "destination_resume_count": total_resume_count,
    "destination_instances": [d["instance_id"] for d in dests],
    "bundle_bytes": bundle_bytes,
    "unique_chunk_bytes": unique_chunk_bytes,
    "bundle_key": source["bundle_key"],
    "total_destination_download_bytes": total_destination_download_bytes,
    "total_destination_origin_bytes": total_destination_origin_bytes,
    "total_destination_peer_bytes": total_destination_peer_bytes,
    "total_chunk_bytes_fetched": total_chunk_bytes_fetched,
    "total_rootfs_bytes_fetched": total_rootfs_bytes_fetched,
    "total_rootfs_cache_hits": total_rootfs_cache_hits,
    "total_rootfs_cache_misses": total_rootfs_cache_misses,
    "source_peer_egress_bytes": source_peer_egress_bytes,
    "relay_peer_egress_bytes": relay_peer_egress_bytes,
    "max_peer_egress_bytes": max_peer_egress_bytes,
    "peer_egress_by_upstream": peer_egress_by_upstream,
    "total_cache_hits": total_cache_hits,
    "total_cache_misses": total_cache_misses,
    "total_corrupt_bundle_rejections": total_corrupt_bundle_rejections,
    "download_multiplier_vs_bundle": ratio(total_destination_download_bytes, bundle_bytes),
    "peer_multiplier_vs_bundle": ratio(total_destination_peer_bytes, bundle_bytes),
    "origin_multiplier_vs_bundle": ratio(total_destination_origin_bytes, bundle_bytes),
    "origin_multiplier_vs_unique_chunks": ratio(total_destination_origin_bytes, unique_chunk_bytes),
    "origin_multiplier_vs_resume_bundle": ratio(total_destination_origin_bytes, bundle_bytes * total_resume_count),
    "origin_mode": origin_mode,
    "destinations": dests,
}, sys.stdout, indent=2)
print()
PY

aws s3 cp "${metrics_path}" "${s3_base}/metrics.json" --region "${region}" --only-show-errors
cat "${metrics_path}"

total_dest_count=$(( ${#dest_instances[@]} + ${#tree_relay_ids[@]} ))
echo "remote bundle smoke ok: source=${source_instance} dest_count=${total_dest_count} s3=${s3_base}/"
aws s3 ls "${s3_base}/" --recursive --region "${region}"
