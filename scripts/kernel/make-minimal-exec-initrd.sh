#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/kernel/make-minimal-exec-initrd.sh --arch aarch64|x86_64 \
       --generation-base GPA --toybox-source DIR [--smoke-helpers] \
       [--depfile PATH] <out.cpio>

Build a tiny architecture-specific Linux initrd for the SporeVM minimal
boot/run path. The generation GPA is supplied by build.zig from the selected
SporeVM board and is validated against that architecture here. The
init process listens on AF_VSOCK, accepts one-line JSON run-session requests,
runs the requested binary, streams stdout/stderr frames, and finishes with an
exit-status frame. The initrd also includes a pinned Toybox build for /bin/sh
and a small basic command set. --smoke-helpers adds the test-only helper
binaries from guest/smoke-helpers that the VM smoke scripts run.

Environment:
  CC   C compiler command. Defaults to `zig cc -target ARCH-linux-musl`
       when zig is available, otherwise a matching native `cc`.
  TOYBOX_JOBS
       Parallel jobs for the Toybox build. Defaults to 2.

The newc mtime is pinned to zero so build-system environment changes cannot
change an embedded artifact without changing an explicit build input.
--depfile writes a Makefile-style list of the guest sources the archive was
built from, so build.zig can cache it without repeating that list.
EOF
}

toybox_source=""
target_arch=""
generation_base=""
depfile=""
smoke_helpers=0
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --smoke-helpers)
      smoke_helpers=1
      shift
      ;;
    --toybox-source)
      if [[ $# -lt 2 ]]; then
        echo "error: --toybox-source requires a value" >&2
        exit 2
      fi
      toybox_source="${2:-}"
      shift 2
      ;;
    --toybox-source=*)
      toybox_source="${1#--toybox-source=}"
      shift
      ;;
    --arch)
      [[ $# -ge 2 ]] || { echo "error: --arch requires a value" >&2; exit 2; }
      target_arch="${2:-}"
      shift 2
      ;;
    --arch=*)
      target_arch="${1#--arch=}"
      shift
      ;;
    --generation-base)
      [[ $# -ge 2 ]] || { echo "error: --generation-base requires a value" >&2; exit 2; }
      generation_base="${2:-}"
      shift 2
      ;;
    --generation-base=*)
      generation_base="${1#--generation-base=}"
      shift
      ;;
    --depfile)
      [[ $# -ge 2 ]] || { echo "error: --depfile requires a value" >&2; exit 2; }
      depfile="${2:-}"
      shift 2
      ;;
    --depfile=*)
      depfile="${1#--depfile=}"
      shift
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "${out}" ]]; then
        usage >&2
        exit 2
      fi
      out="$1"
      shift
      ;;
  esac
done

if [[ -z "${target_arch}" || -z "${generation_base}" || -z "${toybox_source}" || -z "${out}" ]]; then
  usage >&2
  exit 2
fi
case "${target_arch}:${generation_base}" in
  aarch64:0xc001000|aarch64:0x0c001000)
    target_triple="aarch64-linux-musl"
    ;;
  x86_64:0xd0001000)
    target_triple="x86_64-linux-musl"
    ;;
  aarch64:*|x86_64:*)
    echo "error: generation GPA does not match the ${target_arch} SporeVM board: ${generation_base}" >&2
    exit 2
    ;;
  *)
    echo "error: --arch must be aarch64 or x86_64" >&2
    exit 2
    ;;
esac
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to build the minimal exec initrd" >&2
  exit 1
fi
if [[ ! -d "${toybox_source}" ]]; then
  echo "error: --toybox-source must name a directory: ${toybox_source}" >&2
  exit 1
fi
if [[ "${out}" != /* ]]; then
  out="${PWD}/${out}"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [[ -f "${REPO_ROOT}/mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${REPO_ROOT}/mise.toml}"
fi
if [[ -n "${CC:-}" ]]; then
  read -r -a cc_cmd <<<"${CC}"
elif command -v zig >/dev/null 2>&1; then
  cc_cmd=(zig cc -target "${target_triple}")
elif command -v mise >/dev/null 2>&1; then
  zig_path="$(mise which zig 2>/dev/null || true)"
  if [[ -n "${zig_path}" ]]; then
    cc_cmd=("${zig_path}" cc -target "${target_triple}")
  else
    cc_cmd=(mise exec -- zig cc -target "${target_triple}")
  fi
else
  host_arch="$(uname -m)"
  [[ "${host_arch}" != arm64 ]] || host_arch=aarch64
  if [[ "${host_arch}" != "${target_arch}" ]]; then
    echo "error: zig is required to cross-compile the ${target_triple} initrd" >&2
    exit 1
  fi
  cc_cmd=(cc)
fi
if command -v zig >/dev/null 2>&1; then
  hostcc_cmd=(zig cc)
elif command -v mise >/dev/null 2>&1; then
  host_zig_path="$(mise which zig 2>/dev/null || true)"
  if [[ -n "${host_zig_path}" ]]; then
    hostcc_cmd=("${host_zig_path}" cc)
  elif command -v cc >/dev/null 2>&1; then
    hostcc_cmd=(cc)
  else
    echo "error: a host C compiler is required to build Toybox" >&2
    exit 1
  fi
elif command -v cc >/dev/null 2>&1; then
  hostcc_cmd=(cc)
else
  echo "error: a host C compiler is required to build Toybox" >&2
  exit 1
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-minimal-initrd.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/root/bin" "${workdir}/root/dev" "${workdir}/root/proc" "${workdir}/root/run" "${workdir}/root/tmp" "${workdir}/root/usr/bin"

source_dir="${REPO_ROOT}/guest/minimal-initrd"
helper_dir="${REPO_ROOT}/guest/smoke-helpers"
# The guest source list. Each NAME.c becomes /bin/NAME, except agent.c, which
# links agent_sources into /init, and toybox-sh.c, which becomes /bin/sh.
programs=(agent true false toybox-sh)
helpers=()
if ((smoke_helpers)); then
  helpers=(writeout finite counter nproc gencheck rngcheck blkcheck netcheck nslookup wget httpd flockcheck cgroupcheck poweroff)
fi
agent_sources=()
for source in boot build_copy build_run build_run_sandbox copy detached generation network request rootfs session session_io spio util; do
  agent_sources+=("${source_dir}/${source}.c")
done
inputs=("${agent_sources[@]}" "${source_dir}/agent.h" "${source_dir}/build_copy.h" "${source_dir}/build_run_sandbox.h" "${source_dir}/toybox.config")
for program in "${programs[@]}"; do
  inputs+=("${source_dir}/${program}.c")
done
for helper in ${helpers[@]+"${helpers[@]}"}; do
  inputs+=("${helper_dir}/${helper}.c")
done
for input in "${inputs[@]}"; do
  if [[ ! -f "${input}" ]]; then
    echo "error: missing minimal initrd source: ${input}" >&2
    exit 1
  fi
done

compile_static() {
  local src="$1"
  local dst="$2"
  shift 2
  "${cc_cmd[@]}" -static -Os -s "-DSPORE_GENERATION_BASE=${generation_base}ULL" "${src}" "$@" -o "${dst}"
}

build_toybox() {
  local src="$1"
  local dst="$2"
  local miniconfig="${source_dir}/toybox.config"
  local toybox_build="${workdir}/toybox-src"
  local config_log="${workdir}/toybox-config.log"
  local build_log="${workdir}/toybox-build.log"

  if [[ ! -f "${miniconfig}" ]]; then
    echo "error: missing Toybox config: ${miniconfig}" >&2
    exit 1
  fi

  cp -R "${src}" "${toybox_build}"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'exec'
    printf ' %q' "${cc_cmd[@]}"
    printf ' "$@"\n'
  } >"${workdir}/toybox-cc"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'exec'
    printf ' %q' "${hostcc_cmd[@]}"
    printf ' "$@"\n'
  } >"${workdir}/toybox-hostcc"
  chmod 0755 "${workdir}/toybox-cc"
  chmod 0755 "${workdir}/toybox-hostcc"

  # Toybox 0.8.14 puts the input file before later -e expressions, which GNU
  # sed accepts but BSD sed treats as a script file.
  awk '
    BEGIN { q = sprintf("%c", 39) }
    index($0, "$SED -En $KCONFIG_CONFIG >") == 1 {
      print "$SED -En \\";
      next;
    }
    index($0, "#define CFG_") && index($0, "|| exit 1") {
      sub(/ \|\| exit 1$/, " \\");
      print;
      print "  \"$KCONFIG_CONFIG\" > \"$GENDIR\"/config.h || exit 1";
      next;
    }
    index($0, "done | $SED -n -e ") == 1 && index($0, "t no;:no") {
      print "done | $SED -n \\";
      print "  -e " q "s/\" *\"//g" q " \\";
      print "  -e " q "/^#/d" q " \\";
      print "  -e " q "t no" q " \\";
      print "  -e " q ":no" q " \\";
      print "  -e " q "s/\"/\"/p" q " \\";
      print "  -e " q "t" q " \\";
      print "  -e " q "s/\\( [AB] \\).*/\\1 \" \"/p" q " |\\";
      next;
    }
    index($0, "  sort -s | $SED -n -e ") == 1 && index($0, "t pair") {
      print "  sort -s | $SED -n \\";
      print "  -e " q "s/ A / /" q " \\";
      print "  -e " q "t pair" q " \\";
      print "  -e " q "h" q " \\";
      print "  -e " q "s/\\([^ ]*\\).*/\\1 \" \"/" q " \\";
      print "  -e " q "x" q " \\";
      print "  -e " q "b single" q " \\";
      print "  -e " q ":pair" q " \\";
      print "  -e " q "h" q " \\";
      print "  -e " q "n" q " \\";
      print "  -e " q ":single" q " \\";
      print "  -e " q "s/[^ ]* B //" q " \\";
      print "  -e " q "H" q " \\";
      print "  -e " q "g" q " \\";
      print "  -e " q "s/\\n/ /" q " \\";
      print "  -e " q "p" q " | \\";
      skip_next = 1;
      next;
    }
    index($0, "  STRUX=\"$($SED -ne ") == 1 {
      print "  STRUX=\"$($SED -n \\";
      print "  -e " q "s/^#define[[:space:]]*FOR_\\([^[:space:]]*\\).*/\\1/" q " \\";
      print "  -e " q "t s1_save" q " \\";
      print "  -e " q "b s1_done" q " \\";
      print "  -e " q ":s1_save" q " \\";
      print "  -e " q "h" q " \\";
      print "  -e " q ":s1_done" q " \\";
      print "  -e " q "/^GLOBALS(/,/^)/{" q " \\";
      print "  -e " q "s/^GLOBALS(//" q " \\";
      print "  -e " q "t s2_start" q " \\";
      print "  -e " q "b s2_body" q " \\";
      print "  -e " q ":s2_start" q " \\";
      print "  -e " q "g" q " \\";
      print "  -e " q "s/.*/struct &_data {/" q " \\";
      print "  -e " q ":s2_body" q " \\";
      print "  -e " q "s/^)/};/" q " \\";
      print "  -e " q "p" q " \\";
      print "  -e " q "}" q " \\";
      print "  $TOYFILES)\"";
      skip_next = 2;
      next;
    }
    index($0, "  $SED -n ") == 1 && index($0, "struct \\(.*\\)_data") {
      print "  $SED -n \\";
      print "  -e " q "s/^struct \\(.*\\)_data .*/\\1/" q " \\";
      print "  -e " q "t s3_save" q " \\";
      print "  -e " q "b" q " \\";
      print "  -e " q ":s3_save" q " \\";
      print "  -e " q "s/.*/    struct &_data &;/p" q " \\";
      next;
    }
    index($0, "$SED -ne " q "/TAGGED_ARRAY") == 1 {
      print "$SED -n \\";
      print "  -e " q "/TAGGED_ARRAY(/,/^)/{" q " \\";
      print "  -e " q "s/.*TAGGED_ARRAY[(]\\([^,]*\\),/\\1/p" q " \\";
      print "  -e " q "s/[^{]*{\"\\([^\"]*\\)\"[^{]*/ _\\1/gp" q " \\";
      print "  -e " q "}" q " toys/*/*.c | tr " q "[:punct:]" q " _ | \\";
      skip_next = 1;
      next;
    }
    skip_next {
      skip_next--;
      next;
    }
    { print }
  ' "${toybox_build}/scripts/make.sh" >"${workdir}/toybox-make.sh"
  mv "${workdir}/toybox-make.sh" "${toybox_build}/scripts/make.sh"
  chmod 0755 "${toybox_build}/scripts/make.sh"

  if ! (
    cd "${toybox_build}"
    KCONFIG_ALLCONFIG="${miniconfig}" \
    CC="${workdir}/toybox-hostcc" \
    HOSTCC="${workdir}/toybox-hostcc" \
    scripts/genconfig.sh -n
  ) >"${config_log}" 2>&1; then
    cat "${config_log}" >&2
    exit 1
  fi
  if ! (
    cd "${toybox_build}"
    CC="${workdir}/toybox-cc" \
    HOSTCC="${workdir}/toybox-hostcc" \
    SED="sed" \
    CFLAGS="-Os -static" \
    LDFLAGS="-static" \
    NOSTRIP=1 \
    CPUS="${TOYBOX_JOBS:-2}" \
    scripts/make.sh
  ) >"${build_log}" 2>&1; then
    cat "${build_log}" >&2
    exit 1
  fi
  cp "${toybox_build}/toybox" "${dst}"
  chmod 0755 "${dst}"
}

for program in "${programs[@]}"; do
  case "${program}" in
    agent) compile_static "${source_dir}/agent.c" "${workdir}/root/init" "${agent_sources[@]}" ;;
    toybox-sh) compile_static "${source_dir}/toybox-sh.c" "${workdir}/root/bin/sh" ;;
    *) compile_static "${source_dir}/${program}.c" "${workdir}/root/bin/${program}" ;;
  esac
done
for helper in ${helpers[@]+"${helpers[@]}"}; do
  compile_static "${helper_dir}/${helper}.c" "${workdir}/root/bin/${helper}"
done
build_toybox "${toybox_source}" "${workdir}/root/bin/toybox"

python3 - "${workdir}/root" "${target_arch}" <<'PY'
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
expected_machine = {"aarch64": 183, "x86_64": 62}[sys.argv[2]]
for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4:6] != b"\x02\x01":
        raise SystemExit(f"error: initrd executable is not little-endian ELF64: {path.relative_to(root)}")
    if struct.unpack_from("<H", data, 18)[0] != expected_machine:
        raise SystemExit(f"error: initrd executable has the wrong architecture: {path.relative_to(root)}")
    program_offset = struct.unpack_from("<Q", data, 32)[0]
    program_size = struct.unpack_from("<H", data, 54)[0]
    program_count = struct.unpack_from("<H", data, 56)[0]
    if program_size < 4 or program_offset + program_size * program_count > len(data):
        raise SystemExit(f"error: initrd executable has malformed program headers: {path.relative_to(root)}")
    for index in range(program_count):
        if struct.unpack_from("<I", data, program_offset + index * program_size)[0] == 3:
            raise SystemExit(f"error: initrd executable is dynamically linked: {path.relative_to(root)}")
PY

for applet in echo cat env ls mkdir printf pwd rm sleep test touch uname; do
  [[ -e "${workdir}/root/bin/${applet}" ]] || ln -s toybox "${workdir}/root/bin/${applet}"
done
ln -s ../../bin/env "${workdir}/root/usr/bin/env"

mkdir -p "$(dirname "${out}")"

# Write newc directly so temporary-directory inode allocation, host uid/gid,
# file mtimes, and cpio implementation differences cannot perturb the embedded
# artifact or its cache identity.
python3 - "${workdir}/root" "${out}" <<'PY'
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
mtime = 0

paths = [root]
paths.extend(sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()))

def pad4(stream, size):
    padding = (-size) % 4
    if padding:
        stream.write(b"\0" * padding)

def write_entry(stream, inode, name, mode, payload, links):
    encoded_name = name.encode("utf-8") + b"\0"
    fields = (
        inode, mode, 0, 0, links, mtime, len(payload),
        0, 0, 0, 0, len(encoded_name), 0,
    )
    header = b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields)
    stream.write(header)
    stream.write(encoded_name)
    pad4(stream, len(header) + len(encoded_name))
    stream.write(payload)
    pad4(stream, len(payload))

temporary = output.with_name(output.name + ".tmp")
with temporary.open("wb") as stream:
    for inode, path in enumerate(paths, start=1):
        info = path.lstat()
        name = "." if path == root else path.relative_to(root).as_posix()
        if stat.S_ISLNK(info.st_mode):
            mode = stat.S_IFLNK | 0o777
            payload = os.readlink(path).encode("utf-8")
        elif stat.S_ISREG(info.st_mode):
            mode = stat.S_IFREG | 0o755
            payload = path.read_bytes()
        elif stat.S_ISDIR(info.st_mode):
            mode = stat.S_IFDIR | (0o1777 if name == "tmp" else 0o755)
            payload = b""
        else:
            raise SystemExit(f"error: unsupported initrd entry type: {name}")
        write_entry(stream, inode, name, mode, payload, 2 if stat.S_ISDIR(info.st_mode) else 1)
    write_entry(stream, len(paths) + 1, "TRAILER!!!", 0, b"", 1)
    remainder = stream.tell() % 512
    if remainder:
        stream.write(b"\0" * (512 - remainder))
os.replace(temporary, output)
PY

if [[ -n "${depfile}" ]]; then
  printf '%s: %s\n' "${out}" "${inputs[*]}" >"${depfile}"
fi
echo "wrote ${out}"
