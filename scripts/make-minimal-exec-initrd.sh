#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/make-minimal-exec-initrd.sh <out.cpio>

Build a tiny aarch64 Linux initrd for the SporeVM minimal boot benchmark. The
init process listens on AF_VSOCK, accepts one-line JSON exec requests, runs
/bin/true for the default probe, and replies with a JSON exit frame.

Environment:
  CC   C compiler command. Defaults to `zig cc -target aarch64-linux-musl`
       when zig is available, otherwise `cc`.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  [[ $# -eq 1 ]] && exit 0 || exit 2
fi

out="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${REPO_ROOT}/mise.toml}"
fi
if [[ -n "${CC:-}" ]]; then
  read -r -a cc_cmd <<<"${CC}"
elif command -v zig >/dev/null 2>&1; then
  cc_cmd=(zig cc -target aarch64-linux-musl)
elif command -v mise >/dev/null 2>&1; then
  cc_cmd=(mise exec -- zig cc -target aarch64-linux-musl)
else
  cc_cmd=(cc)
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-minimal-initrd.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/root/bin" "${workdir}/root/dev" "${workdir}/root/proc" "${workdir}/root/tmp"

cat >"${workdir}/agent.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xffffffffU
#endif

struct sockaddr_vm {
  sa_family_t svm_family;
  unsigned short svm_reserved1;
  unsigned int svm_port;
  unsigned int svm_cid;
  unsigned char svm_zero[sizeof(struct sockaddr) - sizeof(sa_family_t) - sizeof(unsigned short) - sizeof(unsigned int) - sizeof(unsigned int)];
};

static int64_t t_init_start = 0;
static int64_t t_listen_ready = 0;
static int64_t t_first_accept = 0;
static int64_t t_first_request_decode = 0;
static int64_t t_command_start = 0;
static int64_t t_command_exit = 0;

static int64_t now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
  }
  return 0;
}

static void mount_proc(void) {
  mkdir("/proc", 0755);
  if (mount("proc", "/proc", "proc", 0, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount proc failed: errno=%d\n", errno);
  }
}

static void prepare_dev(void) {
  mkdir("/dev", 0755);
  if (mknod("/dev/null", S_IFCHR | 0666, (dev_t)((1u << 8) | 3u)) != 0 && errno != EEXIST) {
    dprintf(2, "mknod /dev/null failed: errno=%d\n", errno);
  }
}

static uint32_t resolve_port(void) {
  char buf[1024];
  int fd = open("/proc/cmdline", O_RDONLY);
  if (fd < 0) return 10700;
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n <= 0) return 10700;
  buf[n] = '\0';
  const char *key = "cleanroom_guest_port=";
  char *p = strstr(buf, key);
  if (p == NULL) return 10700;
  p += strlen(key);
  unsigned long value = strtoul(p, NULL, 10);
  if (value == 0 || value > 65535) return 10700;
  return (uint32_t)value;
}

static int listen_vsock(uint32_t port) {
  int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  struct sockaddr_vm sa;
  memset(&sa, 0, sizeof(sa));
  sa.svm_family = AF_VSOCK;
  sa.svm_cid = VMADDR_CID_ANY;
  sa.svm_port = port;
  if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
    close(fd);
    return -1;
  }
  if (listen(fd, 16) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static ssize_t read_line(int fd, char *buf, size_t cap) {
  size_t len = 0;
  while (len + 1 < cap) {
    char c;
    ssize_t n = read(fd, &c, 1);
    if (n == 0) break;
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    buf[len++] = c;
    if (c == '\n') break;
  }
  buf[len] = '\0';
  return (ssize_t)len;
}

static void write_all(int fd, const char *buf, size_t len) {
  while (len > 0) {
    ssize_t n = write(fd, buf, len);
    if (n < 0) {
      if (errno == EINTR) continue;
      return;
    }
    buf += n;
    len -= (size_t)n;
  }
}

static void send_exit(int fd, int exit_code, const char *error) {
  char frame[1024];
  if (error == NULL) error = "";
  const char *error_json = error[0] == '\0' ? "null" : "\"unsupported command\"";
  int n = snprintf(frame, sizeof(frame),
    "{\"type\":\"exit\",\"exit_code\":%d,\"error\":%s,\"guest_timing_ms\":{"
    "\"guest_init_start\":%lld,"
    "\"guest_agent_listen_ready\":%lld,"
    "\"guest_agent_first_accept\":%lld,"
    "\"guest_agent_first_request_decode\":%lld,"
    "\"guest_command_start\":%lld,"
    "\"guest_command_exit\":%lld}}\n",
    exit_code,
    error_json,
    (long long)t_init_start,
    (long long)t_listen_ready,
    (long long)t_first_accept,
    (long long)t_first_request_decode,
    (long long)t_command_start,
    (long long)t_command_exit);
  if (n > 0) write_all(fd, frame, (size_t)n);
}

static int run_true(void) {
  t_command_start = now_ms();
  pid_t pid = fork();
  if (pid == 0) {
    char *argv[] = {"/bin/true", NULL};
    execv(argv[0], argv);
    _exit(127);
  }
  if (pid < 0) {
    t_command_exit = now_ms();
    return 127;
  }
  int status = 0;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      t_command_exit = now_ms();
      return 127;
    }
  }
  t_command_exit = now_ms();
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}

int main(void) {
  t_init_start = now_ms();
  mount_proc();
  prepare_dev();

  int listener = listen_vsock(resolve_port());
  if (listener < 0) {
    dprintf(2, "listen vsock failed: errno=%d\n", errno);
    return 1;
  }
  t_listen_ready = now_ms();

  for (;;) {
    int conn = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
    if (conn < 0) {
      if (errno == EINTR) continue;
      dprintf(2, "accept failed: errno=%d\n", errno);
      continue;
    }
    if (t_first_accept == 0) t_first_accept = now_ms();

    char req[2048];
    if (read_line(conn, req, sizeof(req)) <= 0) {
      close(conn);
      continue;
    }
    if (t_first_request_decode == 0) t_first_request_decode = now_ms();

    if (strstr(req, "/bin/true") == NULL) {
      t_command_start = now_ms();
      t_command_exit = t_command_start;
      send_exit(conn, 1, "unsupported command");
      close(conn);
      continue;
    }

    int code = run_true();
    send_exit(conn, code, NULL);
    close(conn);
  }
}
EOF

cat >"${workdir}/true.c" <<'EOF'
int main(void) { return 0; }
EOF

"${cc_cmd[@]}" -static -Os -s "${workdir}/agent.c" -o "${workdir}/root/init"
"${cc_cmd[@]}" -static -Os -s "${workdir}/true.c" -o "${workdir}/root/bin/true"
chmod 0755 "${workdir}/root/init" "${workdir}/root/bin/true"
chmod 1777 "${workdir}/root/tmp"

mkdir -p "$(dirname "${out}")"
(
  cd "${workdir}/root"
  find . -print | LC_ALL=C sort | cpio -o -H newc >"${out}"
)

echo "wrote ${out}"
