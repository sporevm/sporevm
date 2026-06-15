#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/make-minimal-exec-initrd.sh <out.cpio>

Build a tiny aarch64 Linux initrd for the SporeVM minimal boot/run path. The
init process listens on AF_VSOCK, accepts one-line JSON argv requests, runs the
requested binary, and replies with a JSON exit frame.

Environment:
  CC   C compiler command. Defaults to `zig cc -target aarch64-linux-musl`
       when zig is available, otherwise `cc`.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  [[ $# -eq 1 ]] && exit 0 || exit 2
fi

if ! command -v cpio >/dev/null 2>&1; then
  echo "error: cpio is required to build the minimal exec initrd" >&2
  exit 1
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
#include <poll.h>
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

#define MAX_ARGC 16
#define MAX_ARG_LEN 256
#define MAX_OUTPUT 16384
#define MAX_OUTPUT_B64 (((MAX_OUTPUT + 2) / 3) * 4)

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

struct output_capture {
  unsigned char stdout_buf[MAX_OUTPUT];
  unsigned char stderr_buf[MAX_OUTPUT];
  size_t stdout_len;
  size_t stderr_len;
  int stdout_truncated;
  int stderr_truncated;
};

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
  if (mount("devtmpfs", "/dev", "devtmpfs", 0, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount devtmpfs failed: errno=%d\n", errno);
  }
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

static int cmdline_has_flag(const char *flag) {
  char buf[1024];
  int fd = open("/proc/cmdline", O_RDONLY);
  if (fd < 0) return 0;
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n <= 0) return 0;
  buf[n] = '\0';
  return strstr(buf, flag) != NULL;
}

static int wait_for_path(const char *path, int attempts, int sleep_us) {
  for (int i = 0; i < attempts; i++) {
    if (access(path, R_OK) == 0) return 0;
    usleep((useconds_t)sleep_us);
  }
  return -1;
}

static int path_is_dir(const char *path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int mount_if_dir(const char *source, const char *target, const char *fstype, unsigned long flags, const char *data, char *error, size_t cap) {
  if (!path_is_dir(target)) return 0;
  if (mount(source, target, fstype, flags, data) != 0 && errno != EBUSY) {
    snprintf(error, cap, "rootfs runtime mount failed: %s errno=%d", target, errno);
    return -1;
  }
  return 0;
}

static int setup_rootfs(char *error, size_t cap) {
  mkdir("/mnt", 0755);
  mkdir("/mnt/rootfs", 0755);
  if (wait_for_path("/dev/vda", 100, 50000) != 0) {
    snprintf(error, cap, "rootfs block device not found");
    return -1;
  }
  if (mount("/dev/vda", "/mnt/rootfs", "ext4", MS_RDONLY, "noload") != 0) {
    snprintf(error, cap, "rootfs mount failed: errno=%d", errno);
    return -1;
  }
  if (mount_if_dir("devtmpfs", "/mnt/rootfs/dev", "devtmpfs", MS_NOSUID, "", error, cap) != 0) return -1;
  if (mount_if_dir("proc", "/mnt/rootfs/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, "", error, cap) != 0) return -1;
  if (mount_if_dir("sysfs", "/mnt/rootfs/sys", "sysfs", MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV, "", error, cap) != 0) return -1;
  if (mount_if_dir("tmpfs", "/mnt/rootfs/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755", error, cap) != 0) return -1;
  if (mount_if_dir("tmpfs", "/mnt/rootfs/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777", error, cap) != 0) return -1;
  return 0;
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

static void capture_append(unsigned char *dst, size_t *dst_len, int *truncated, const char *src, size_t src_len) {
  size_t copied = 0;
  if (*dst_len < MAX_OUTPUT) {
    size_t n = MAX_OUTPUT - *dst_len;
    if (n > src_len) n = src_len;
    if (n > 0) {
      memcpy(dst + *dst_len, src, n);
      *dst_len += n;
      copied = n;
    }
  }
  if (copied < src_len) *truncated = 1;
}

static void capture_stream(struct output_capture *capture, int stream, const char *buf, size_t len) {
  if (stream == 1) {
    capture_append(capture->stdout_buf, &capture->stdout_len, &capture->stdout_truncated, buf, len);
  } else {
    capture_append(capture->stderr_buf, &capture->stderr_len, &capture->stderr_truncated, buf, len);
  }
}

static int drain_pipe(int fd, struct output_capture *capture, int stream) {
  char buf[4096];
  for (;;) {
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n > 0) {
      capture_stream(capture, stream, buf, (size_t)n);
      continue;
    }
    if (n == 0) return 0;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 1;
    return 0;
  }
}

static int wait_child(pid_t pid, int *status, int block) {
  for (;;) {
    pid_t rc = waitpid(pid, status, block ? 0 : WNOHANG);
    if (rc == pid) return 1;
    if (rc == 0) return 0;
    if (errno == EINTR) continue;
    return -1;
  }
}

static int set_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void finish_pipe(int fd, int *open, struct output_capture *capture, int stream) {
  if (!*open) return;
  (void)drain_pipe(fd, capture, stream);
  close(fd);
  *open = 0;
}

/*
 * Do not wait for pipe EOF after the direct command exits; inherited fds from
 * daemonized children must not block the one-shot exec result.
 */
static void finish_output_pipes(int stdout_fd, int *stdout_open, int stderr_fd, int *stderr_open, struct output_capture *capture) {
  finish_pipe(stdout_fd, stdout_open, capture, 1);
  finish_pipe(stderr_fd, stderr_open, capture, 2);
}

static void base64_encode(const unsigned char *src, size_t len, char *out, size_t cap) {
  static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t i = 0;
  size_t j = 0;
  while (i < len && j + 4 < cap) {
    size_t rem = len - i;
    uint32_t a = src[i++];
    uint32_t b = rem > 1 ? src[i++] : 0;
    uint32_t c = rem > 2 ? src[i++] : 0;
    out[j++] = table[(a >> 2) & 0x3f];
    out[j++] = table[((a & 0x03) << 4) | ((b >> 4) & 0x0f)];
    out[j++] = rem > 1 ? table[((b & 0x0f) << 2) | ((c >> 6) & 0x03)] : '=';
    out[j++] = rem > 2 ? table[c & 0x3f] : '=';
  }
  if (j < cap) out[j] = '\0';
}

static void send_exit(int fd, int exit_code, const char *error, const struct output_capture *capture) {
  char stdout_b64[MAX_OUTPUT_B64 + 1];
  char stderr_b64[MAX_OUTPUT_B64 + 1];
  if (capture != NULL) {
    base64_encode(capture->stdout_buf, capture->stdout_len, stdout_b64, sizeof(stdout_b64));
    base64_encode(capture->stderr_buf, capture->stderr_len, stderr_b64, sizeof(stderr_b64));
  } else {
    stdout_b64[0] = '\0';
    stderr_b64[0] = '\0';
  }

  char frame[2048 + (MAX_OUTPUT_B64 * 2)];
  const char *error_json = "null";
  if (error != NULL) {
    if (strcmp(error, "bad request") == 0) {
      error_json = "\"bad request\"";
    } else if (strcmp(error, "rootfs unavailable") == 0) {
      error_json = "\"rootfs unavailable\"";
    } else {
      error_json = "\"run failed\"";
    }
  }
  int n = snprintf(frame, sizeof(frame),
    "{\"type\":\"exit\",\"exit_code\":%d,\"error\":%s,"
    "\"stdout_b64\":\"%s\","
    "\"stderr_b64\":\"%s\","
    "\"stdout_truncated\":%s,"
    "\"stderr_truncated\":%s,"
    "\"guest_timing_ms\":{"
    "\"guest_init_start\":%lld,"
    "\"guest_agent_listen_ready\":%lld,"
    "\"guest_agent_first_accept\":%lld,"
    "\"guest_agent_first_request_decode\":%lld,"
    "\"guest_command_start\":%lld,"
    "\"guest_command_exit\":%lld}}\n",
    exit_code,
    error_json,
    stdout_b64,
    stderr_b64,
    capture != NULL && capture->stdout_truncated ? "true" : "false",
    capture != NULL && capture->stderr_truncated ? "true" : "false",
    (long long)t_init_start,
    (long long)t_listen_ready,
    (long long)t_first_accept,
    (long long)t_first_request_decode,
    (long long)t_command_start,
    (long long)t_command_exit);
  if (n > 0) {
    size_t len = (size_t)n;
    if (len >= sizeof(frame)) len = sizeof(frame) - 1;
    write_all(fd, frame, len);
  }
}

static const char *skip_ws(const char *p) {
  while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
  return p;
}

static int parse_json_string(const char **cursor, char *out, size_t cap) {
  const char *p = *cursor;
  if (*p != '"') return -1;
  p++;
  size_t len = 0;
  while (*p != '\0' && *p != '"') {
    char c = *p++;
    if (c == '\\') {
      c = *p++;
      switch (c) {
        case '"':
        case '\\':
        case '/':
          break;
        case 'n':
          c = '\n';
          break;
        case 'r':
          c = '\r';
          break;
        case 't':
          c = '\t';
          break;
        default:
          return -1;
      }
    }
    if (len + 1 >= cap) return -1;
    out[len++] = c;
  }
  if (*p != '"') return -1;
  out[len] = '\0';
  *cursor = p + 1;
  return 0;
}

static int parse_argv(const char *req, char storage[MAX_ARGC][MAX_ARG_LEN], char *argv[MAX_ARGC + 1]) {
  const char *p = strstr(req, "\"argv\"");
  if (p == NULL) p = strstr(req, "\"command\"");
  if (p == NULL) return -1;
  p = strchr(p, '[');
  if (p == NULL) return -1;
  p++;

  int argc = 0;
  for (;;) {
    p = skip_ws(p);
    if (*p == ']') {
      argv[argc] = NULL;
      return argc > 0 ? argc : -1;
    }
    if (argc >= MAX_ARGC) return -1;
    if (parse_json_string(&p, storage[argc], MAX_ARG_LEN) != 0) return -1;
    argv[argc] = storage[argc];
    argc++;

    p = skip_ws(p);
    if (*p == ',') {
      p++;
      continue;
    }
    if (*p == ']') {
      argv[argc] = NULL;
      return argc;
    }
    return -1;
  }
}

static int run_argv(char *const argv[], struct output_capture *capture, int use_rootfs) {
  t_command_start = now_ms();
  int stdout_pipe[2];
  int stderr_pipe[2];
  if (pipe2(stdout_pipe, O_CLOEXEC) != 0) {
    t_command_exit = now_ms();
    return 127;
  }
  if (pipe2(stderr_pipe, O_CLOEXEC) != 0) {
    close(stdout_pipe[0]);
    close(stdout_pipe[1]);
    t_command_exit = now_ms();
    return 127;
  }
  if (set_nonblock(stdout_pipe[0]) != 0 || set_nonblock(stderr_pipe[0]) != 0) {
    close(stdout_pipe[0]);
    close(stdout_pipe[1]);
    close(stderr_pipe[0]);
    close(stderr_pipe[1]);
    t_command_exit = now_ms();
    return 127;
  }

  pid_t pid = fork();
  if (pid == 0) {
    close(stdout_pipe[0]);
    close(stderr_pipe[0]);
    if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0) _exit(127);
    if (dup2(stderr_pipe[1], STDERR_FILENO) < 0) _exit(127);
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    if (use_rootfs) {
      if (chroot("/mnt/rootfs") != 0) _exit(126);
      if (chdir("/") != 0) _exit(126);
    }
    char *const empty_env[] = { NULL };
    execve(argv[0], argv, empty_env);
    _exit(127);
  }
  close(stdout_pipe[1]);
  close(stderr_pipe[1]);
  if (pid < 0) {
    close(stdout_pipe[0]);
    close(stderr_pipe[0]);
    t_command_exit = now_ms();
    return 127;
  }

  int status = 0;
  int stdout_open = 1;
  int stderr_open = 1;
  int child_done = 0;
  int wait_failed = 0;

  while (stdout_open || stderr_open || !child_done) {
    if (stdout_open || stderr_open) {
      struct pollfd fds[2];
      int streams[2];
      nfds_t nfds = 0;
      if (stdout_open) {
        fds[nfds].fd = stdout_pipe[0];
        fds[nfds].events = POLLIN | POLLHUP | POLLERR;
        fds[nfds].revents = 0;
        streams[nfds++] = 1;
      }
      if (stderr_open) {
        fds[nfds].fd = stderr_pipe[0];
        fds[nfds].events = POLLIN | POLLHUP | POLLERR;
        fds[nfds].revents = 0;
        streams[nfds++] = 2;
      }

      int pr = poll(fds, nfds, 100);
      if (pr > 0) {
        for (nfds_t i = 0; i < nfds; i++) {
          if ((fds[i].revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;
          int still_open = drain_pipe(fds[i].fd, capture, streams[i]);
          if (!still_open) {
            if (streams[i] == 1) {
              close(stdout_pipe[0]);
              stdout_open = 0;
            } else {
              close(stderr_pipe[0]);
              stderr_open = 0;
            }
          }
        }
      } else if (pr < 0 && errno != EINTR) {
        if (stdout_open) close(stdout_pipe[0]);
        if (stderr_open) close(stderr_pipe[0]);
        stdout_open = 0;
        stderr_open = 0;
      }
    } else if (!child_done) {
      int wr = wait_child(pid, &status, 1);
      child_done = 1;
      if (wr < 0) wait_failed = 1;
      finish_output_pipes(stdout_pipe[0], &stdout_open, stderr_pipe[0], &stderr_open, capture);
    }

    if (!child_done) {
      int wr = wait_child(pid, &status, 0);
      if (wr == 1) {
        child_done = 1;
        finish_output_pipes(stdout_pipe[0], &stdout_open, stderr_pipe[0], &stderr_open, capture);
      } else if (wr < 0) {
        child_done = 1;
        wait_failed = 1;
        finish_output_pipes(stdout_pipe[0], &stdout_open, stderr_pipe[0], &stderr_open, capture);
      }
    }
  }

  t_command_exit = now_ms();
  if (wait_failed) return 127;
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}

int main(void) {
  t_init_start = now_ms();
  mount_proc();
  prepare_dev();
  int use_rootfs = cmdline_has_flag("spore_rootfs=1");
  int rootfs_ready = 1;
  char rootfs_error[128];
  rootfs_error[0] = '\0';
  if (use_rootfs && setup_rootfs(rootfs_error, sizeof(rootfs_error)) != 0) {
    rootfs_ready = 0;
    dprintf(2, "%s\n", rootfs_error);
  }

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

    char arg_storage[MAX_ARGC][MAX_ARG_LEN];
    char *argv[MAX_ARGC + 1];
    if (parse_argv(req, arg_storage, argv) <= 0) {
      t_command_start = now_ms();
      t_command_exit = t_command_start;
      send_exit(conn, 2, "bad request", NULL);
      close(conn);
      continue;
    }
    if (use_rootfs && !rootfs_ready) {
      t_command_start = now_ms();
      t_command_exit = t_command_start;
      send_exit(conn, 126, "rootfs unavailable", NULL);
      close(conn);
      continue;
    }

    struct output_capture capture;
    memset(&capture, 0, sizeof(capture));
    int code = run_argv(argv, &capture, use_rootfs);
    send_exit(conn, code, NULL, &capture);
    close(conn);
  }
}
EOF

cat >"${workdir}/true.c" <<'EOF'
int main(void) { return 0; }
EOF

cat >"${workdir}/false.c" <<'EOF'
int main(void) { return 1; }
EOF

cat >"${workdir}/writeout.c" <<'EOF'
#include <unistd.h>

int main(void) {
  write(1, "spore stdout\n", 13);
  write(2, "spore stderr\n", 13);
  return 0;
}
EOF

"${cc_cmd[@]}" -static -Os -s "${workdir}/agent.c" -o "${workdir}/root/init"
"${cc_cmd[@]}" -static -Os -s "${workdir}/true.c" -o "${workdir}/root/bin/true"
"${cc_cmd[@]}" -static -Os -s "${workdir}/false.c" -o "${workdir}/root/bin/false"
"${cc_cmd[@]}" -static -Os -s "${workdir}/writeout.c" -o "${workdir}/root/bin/writeout"
chmod 0755 "${workdir}/root/init" "${workdir}/root/bin/true" "${workdir}/root/bin/false" "${workdir}/root/bin/writeout"
chmod 1777 "${workdir}/root/tmp"

mkdir -p "$(dirname "${out}")"
(
  cd "${workdir}/root"
  find . -print | LC_ALL=C sort | cpio -o -H newc >"${out}"
)

echo "wrote ${out}"
