#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_prefix="${repo_root}/zig-out/qemu-tcg"
state_dir="${repo_root}/zig-out/qemu-tcg-state"
cache_root="${XDG_CACHE_HOME:-${HOME}/.cache}"
cache_dir="${SPOREVM_TCG_CACHE_DIR:-${cache_root}/sporevm/qemu-tcg}"
ssh_port="${SPOREVM_TCG_SSH_PORT:-22022}"
guest_cpus="${SPOREVM_TCG_CPUS:-4}"
guest_memory="${SPOREVM_TCG_MEMORY:-2048}"

alpine_version="3.24.1"
alpine_iso="alpine-virt-${alpine_version}-aarch64.iso"
alpine_url="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/${alpine_iso}"
alpine_sha256="c81699152db11d2a6dbb7d75348d632fcf5811eff414d7e71876a8bb6d48bc02"
iso_path="${cache_dir}/${alpine_iso}"

pid_file="${state_dir}/qemu.pid"
serial_socket="${state_dir}/serial.sock"
monitor_socket="${state_dir}/monitor.sock"
boot_log="${state_dir}/boot.log"
ssh_key="${state_dir}/id_ed25519"
spore_binary="${build_prefix}/bin/spore"
guest_spore="/workspace/zig-out/qemu-tcg/bin/spore"

die() {
  printf 'qemu-tcg-kvm: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/dev/qemu-tcg-kvm.sh COMMAND [ARGS...]

Commands:
  build             Cross-build SporeVM for aarch64-linux-musl
  start             Start and bootstrap the warm QEMU/KVM development guest
  status            Check the guest, /dev/kvm, and SporeVM binary
  spore ARGS...     Run SporeVM inside the guest
  shell             Open an interactive shell inside the guest
  smoke             Run the KVM, save/restore, and networking smoke suite
  stop              Stop the development guest

Environment:
  SPOREVM_TCG_SSH_PORT       Host SSH port (default: 22022)
  SPOREVM_TCG_CPUS           Outer QEMU vCPUs (default: 4)
  SPOREVM_TCG_MEMORY         Outer QEMU memory in MiB (default: 2048)
  SPOREVM_TCG_FIRMWARE       Path to edk2-aarch64-code.fd
  SPOREVM_TCG_CACHE_DIR      Alpine ISO cache directory
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

qemu_pid() {
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$pid"
}

qemu_is_running() {
  local pid command_line
  pid="$(qemu_pid)" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ "$command_line" == *qemu-system-aarch64* ]]
  [[ "$command_line" == *"$pid_file"* ]]
}

cleanup_runtime_files() {
  rm -f "$pid_file" "$serial_socket" "$monitor_socket"
}

ssh_options=(
  -i "$ssh_key"
  -p "$ssh_port"
  -o BatchMode=yes
  -o ConnectTimeout=2
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

run_ssh() {
  ssh "${ssh_options[@]}" root@127.0.0.1 "$@"
}

wait_for_ssh() {
  local attempt
  for attempt in $(seq 1 60); do
    if run_ssh true >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

resolve_firmware() {
  if [[ -n "${SPOREVM_TCG_FIRMWARE:-}" ]]; then
    [[ -f "$SPOREVM_TCG_FIRMWARE" ]] || die "firmware not found: $SPOREVM_TCG_FIRMWARE"
    printf '%s\n' "$SPOREVM_TCG_FIRMWARE"
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_firmware
    brew_firmware="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd"
    if [[ -f "$brew_firmware" ]]; then
      printf '%s\n' "$brew_firmware"
      return
    fi
  fi

  die "edk2-aarch64-code.fd was not found; install QEMU with Homebrew or set SPOREVM_TCG_FIRMWARE"
}

ensure_platform() {
  [[ "$(uname -s)" == "Darwin" ]] || die "this harness currently supports macOS hosts"
  [[ "$(uname -m)" == "arm64" ]] || die "this harness requires an Apple Silicon host"
  require_command qemu-system-aarch64
  require_command expect
  require_command nc
  require_command ssh
  require_command ssh-keygen
}

ensure_iso() {
  mkdir -p "$cache_dir"

  if [[ -f "$iso_path" ]]; then
    local existing_sha
    existing_sha="$(shasum -a 256 "$iso_path" | awk '{print $1}')"
    [[ "$existing_sha" == "$alpine_sha256" ]] ||
      die "cached ISO checksum mismatch: $iso_path"
    return
  fi

  require_command curl
  local partial="${iso_path}.partial.$$"
  printf 'Downloading %s...\n' "$alpine_iso"
  if ! curl -fL --retry 3 --output "$partial" "$alpine_url"; then
    rm -f "$partial"
    die "failed to download $alpine_url"
  fi

  local downloaded_sha
  downloaded_sha="$(shasum -a 256 "$partial" | awk '{print $1}')"
  if [[ "$downloaded_sha" != "$alpine_sha256" ]]; then
    rm -f "$partial"
    die "downloaded ISO checksum mismatch: expected ${alpine_sha256}, got ${downloaded_sha}"
  fi
  mv "$partial" "$iso_path"
}

ensure_ssh_key() {
  mkdir -p "$state_dir"
  if [[ ! -f "$ssh_key" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"
  fi
  [[ -f "${ssh_key}.pub" ]] || die "SSH public key is missing: ${ssh_key}.pub"
}

build_spore() {
  require_command mise
  (
    cd "$repo_root"
    mise trust mise.toml
    mise exec -- zig build \
      --release=safe \
      -Dtarget=aarch64-linux-musl \
      --prefix "$build_prefix"
  )
  [[ -x "$spore_binary" ]] || die "cross-build did not produce $spore_binary"
  file "$spore_binary"
}

ensure_spore_binary() {
  if [[ ! -x "$spore_binary" ]]; then
    printf 'SporeVM cross-build is missing; building it now...\n'
    build_spore
  fi
}

terminate_qemu() {
  local pid attempt
  qemu_is_running || {
    cleanup_runtime_files
    return
  }
  pid="$(qemu_pid)"

  if [[ -S "$monitor_socket" ]]; then
    printf 'system_powerdown\n' | nc -w 1 -U "$monitor_socket" >/dev/null 2>&1 || true
    for attempt in $(seq 1 20); do
      if ! kill -0 "$pid" 2>/dev/null; then
        cleanup_runtime_files
        return
      fi
      sleep 0.25
    done
  fi

  kill "$pid"
  for attempt in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then
      cleanup_runtime_files
      return
    fi
    sleep 0.25
  done

  die "QEMU did not stop after SIGTERM (pid $pid)"
}

bootstrap_guest() {
  local public_key bootstrap_command
  public_key="$(<"${ssh_key}.pub")"
  bootstrap_command="set -eu; modprobe kvm; modprobe 9pnet_virtio; ip link set lo up; ip link set eth0 up; udhcpc -i eth0 -q -n; apk add --no-cache openssh-server; mkdir -p /workspace /root/.ssh /tmp/spore-runtime; mount -t 9p -o trans=virtio,version=9p2000.L,ro workspace /workspace; printf '%s\\n' $(shell_quote "$public_key") > /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys; ssh-keygen -A; rc-service sshd start; test -c /dev/kvm; test -x $(shell_quote "$guest_spore"); echo __SPOREVM_TCG_READY__"

  SPOREVM_TCG_SERIAL_SOCKET="$serial_socket" \
    SPOREVM_TCG_BOOTSTRAP_COMMAND="$bootstrap_command" \
    SPOREVM_TCG_BOOT_LOG="$boot_log" \
    expect <<'EXPECT'
set timeout 120
log_file -noappend $env(SPOREVM_TCG_BOOT_LOG)
log_user 0
spawn nc -U $env(SPOREVM_TCG_SERIAL_SOCKET)
send "\r"
expect {
  -re "login:" {
    send "root\r"
  }
  timeout {
    puts stderr "timed out waiting for the Alpine login prompt"
    exit 1
  }
  eof {
    puts stderr "QEMU serial socket closed before login"
    exit 1
  }
}
expect {
  -re "# " {}
  timeout {
    puts stderr "timed out waiting for the Alpine root shell"
    exit 1
  }
}
send -- "$env(SPOREVM_TCG_BOOTSTRAP_COMMAND)\r"
expect {
  "__SPOREVM_TCG_READY__" {}
  timeout {
    puts stderr "timed out bootstrapping the Alpine guest"
    exit 1
  }
  eof {
    puts stderr "QEMU serial socket closed during bootstrap"
    exit 1
  }
}
send "exit\r"
expect {
  -re "login:" {}
  timeout {}
}
close
wait
EXPECT
}

start_qemu() {
  if qemu_is_running; then
    printf 'qemu-tcg-kvm: already running (pid %s, SSH port %s)\n' "$(qemu_pid)" "$ssh_port"
    return
  fi

  ensure_platform
  ensure_spore_binary
  ensure_iso
  ensure_ssh_key

  if nc -z 127.0.0.1 "$ssh_port" >/dev/null 2>&1; then
    die "TCP port $ssh_port is already in use; set SPOREVM_TCG_SSH_PORT"
  fi

  mkdir -p "$state_dir"
  cleanup_runtime_files

  local firmware
  firmware="$(resolve_firmware)"
  qemu-system-aarch64 \
    -name sporevm-qemu-tcg-kvm \
    -machine virt,virtualization=on,gic-version=3 \
    -cpu max \
    -accel tcg,thread=multi \
    -smp "$guest_cpus" \
    -m "$guest_memory" \
    -bios "$firmware" \
    -drive "file=${iso_path},media=cdrom,readonly=on,format=raw" \
    -boot d \
    -fsdev "local,id=workspace,path=${repo_root},security_model=none,readonly=on" \
    -device virtio-9p-pci,fsdev=workspace,mount_tag=workspace \
    -device virtio-rng-pci \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" \
    -chardev "socket,id=serial0,path=${serial_socket},server=on,wait=off" \
    -serial chardev:serial0 \
    -monitor "unix:${monitor_socket},server=on,wait=off" \
    -display none \
    -no-reboot \
    -daemonize \
    -pidfile "$pid_file"

  if ! qemu_is_running; then
    cleanup_runtime_files
    die "QEMU exited during startup"
  fi

  if ! bootstrap_guest || ! wait_for_ssh; then
    if [[ -f "$boot_log" ]]; then
      printf 'Last guest boot output (%s):\n' "$boot_log" >&2
      tail -80 "$boot_log" >&2
    fi
    terminate_qemu || true
    die "guest bootstrap failed"
  fi

  printf 'qemu-tcg-kvm: ready (pid %s, SSH port %s)\n' "$(qemu_pid)" "$ssh_port"
}

require_running() {
  qemu_is_running || die "guest is not running; run scripts/dev/qemu-tcg-kvm.sh start"
}

show_status() {
  require_running
  run_ssh "test -c /dev/kvm && test -x $(shell_quote "$guest_spore") && $(shell_quote "$guest_spore") version"
  printf 'qemu-tcg-kvm: running (pid %s, SSH port %s, /dev/kvm available)\n' \
    "$(qemu_pid)" "$ssh_port"
}

run_spore() {
  require_running
  local remote_command
  remote_command="env HOME=/root SPOREVM_RUNTIME_DIR=/tmp/spore-runtime $(shell_quote "$guest_spore")"
  local arg
  for arg in "$@"; do
    remote_command+=" $(shell_quote "$arg")"
  done
  run_ssh "$remote_command"
}

run_smoke() {
  require_running
  run_ssh "env HOME=/root sh /workspace/scripts/dev/qemu-tcg-kvm-guest-smoke.sh"
}

open_shell() {
  require_running
  ssh -t "${ssh_options[@]}" root@127.0.0.1
}

command="${1:-}"
if [[ -z "$command" ]]; then
  usage
  exit 1
fi
shift

case "$command" in
  build)
    [[ "$#" -eq 0 ]] || die "build takes no arguments"
    build_spore
    ;;
  start)
    [[ "$#" -eq 0 ]] || die "start takes no arguments"
    start_qemu
    ;;
  status)
    [[ "$#" -eq 0 ]] || die "status takes no arguments"
    show_status
    ;;
  spore)
    run_spore "$@"
    ;;
  shell)
    [[ "$#" -eq 0 ]] || die "shell takes no arguments"
    open_shell
    ;;
  smoke)
    [[ "$#" -eq 0 ]] || die "smoke takes no arguments"
    run_smoke
    ;;
  stop)
    [[ "$#" -eq 0 ]] || die "stop takes no arguments"
    if qemu_is_running; then
      local_pid="$(qemu_pid)"
      terminate_qemu
      printf 'qemu-tcg-kvm: stopped (pid %s)\n' "$local_pid"
    else
      cleanup_runtime_files
      printf 'qemu-tcg-kvm: already stopped\n'
    fi
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    die "unknown command: $command"
    ;;
esac
