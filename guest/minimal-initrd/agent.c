#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>
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
#define MAX_ENVC 64
#define MAX_ENV_LEN 256
#define MAX_WORKDIR_LEN 256
#define MAX_REQUEST 8192
#define MAX_FRAME_PAYLOAD 4096
#define MAX_COPY_PATH_LEN 512
#define MAX_COPY_FULL_PATH_LEN 1024
#define COPY_ARCHIVE_HEADER_LEN 16
#define MAX_DETACHED_CHILDREN 32
#define REPLAY_CAP 65536
#define SESSION_ID "default"
#define GEN_PARAMS_MAX 4096
#define SPORE_NET_IFACE "eth0"
#define SPORE_NET_GUEST_IP "100.96.0.2"
#define SPORE_NET_GATEWAY_IP "100.96.0.1"
#define SPORE_NET_NETMASK "255.255.255.252"
#define SPORE_NET_RESOLV_CONF "nameserver 100.96.0.1\n"
#define FILE_STDOUT_PATH "/tmp/spore-run.stdout"
#define FILE_STDERR_PATH "/tmp/spore-run.stderr"
#define SPORE_INJECTED_INITRD_DIR "/run/sporevm/injected"
#define SPORE_INJECTED_ROOTFS_DIR "/mnt/rootfs/run/sporevm/injected"
#define SPIO_MAGIC "SPIO"
#define SPIO_VERSION 1
#define SPIO_HEADER_LEN 24
#define SPIO_DATA 1
#define SPIO_CLOSE 2
#define SPIO_EXIT 3
#define SPIO_RESIZE 4
#define SPIO_EVENT 7
#define SPIO_CONTROL_STREAM 0
#define SPIO_STDIN_STREAM 1
#define SPIO_STDOUT_STREAM 2
#define SPIO_STDERR_STREAM 3
#define SPIO_TERMINAL_STREAM 4
#define COPY_KIND_FILE 'F'
#define COPY_KIND_DIR 'D'
#define COPY_KIND_END 'E'
#define GEN_BASE 0x0c001000ULL
#define GEN_WINDOW_SIZE 0x1000U
#define GEN_MAGIC 0x4e475053U
#define GEN_IRQ_GENERATION_CHANGED 1U
#define REG_MAGIC 0x000U
#define REG_PARAMS_OFFSET 0x008U
#define REG_PARAMS_SIZE 0x00cU
#define REG_IRQ_STATUS 0x010U
#define REG_IRQ_ACK 0x014U
#define REG_GENERATION 0x018U
#define NSEC_PER_SEC 1000000000ULL

struct sockaddr_vm {
  sa_family_t svm_family;
  unsigned short svm_reserved1;
  unsigned int svm_port;
  unsigned int svm_cid;
  unsigned char svm_zero[sizeof(struct sockaddr) - sizeof(sa_family_t) - sizeof(unsigned short) - sizeof(unsigned int) - sizeof(unsigned int)];
};

static int64_t t_init_start = 0;
static int64_t t_listen_ready = 0;
static int64_t t_request_accept = 0;
static int64_t t_request_decode = 0;
static int64_t t_command_start = 0;
static int64_t t_command_exit = 0;
static int sigchld_pipe[2] = { -1, -1 };
static const uint64_t memory_high_step_bytes = 1073741824ULL;
static const char memory_high_limit[] = "268435456\n";

static int path_is_dir(const char *path);
static int copy_injected_files_to_rootfs(char *error, size_t cap);
struct session;
struct client;
static void close_client_input_lost(struct session *session, struct client *client);

struct replay_buffer {
  unsigned char data[REPLAY_CAP];
  uint64_t base_offset;
  size_t len;
};

struct session {
  int started;
  int exited;
  int memory_pressure_fd;
  char memory_cgroup_path[128];
  char session_id[64];
  pid_t pid;
  int stdout_fd;
  int stderr_fd;
  int stdin_fd;
  int terminal_fd;
  int stdout_open;
  int stderr_open;
  int stdin_open;
  int stdin_capable;
  int stdin_close_pending;
  int tty;
  int terminal_close_pending;
  int file_stdio;
  int exit_code;
  uint64_t stdout_offset;
  uint64_t stderr_offset;
  uint64_t stdin_offset;
  uint64_t terminal_offset;
  uint64_t terminal_input_offset;
  unsigned char stdin_pending[MAX_FRAME_PAYLOAD];
  size_t stdin_pending_len;
  size_t stdin_pending_off;
  unsigned char terminal_pending[MAX_FRAME_PAYLOAD];
  size_t terminal_pending_len;
  size_t terminal_pending_off;
  struct replay_buffer stdout_replay;
  struct replay_buffer stderr_replay;
};

struct client {
  int fd;
  int protocol_v1;
  uint64_t stdout_offset;
  uint64_t stderr_offset;
  uint64_t stdin_offset;
  uint64_t terminal_offset;
  uint64_t terminal_input_offset;
  int stdin_input_owner;
  int terminal_input_owner;
  unsigned char v1_header[SPIO_HEADER_LEN];
  size_t v1_header_len;
  uint8_t v1_type;
  uint32_t v1_stream_id;
  uint64_t v1_offset;
  uint32_t v1_payload_len;
  unsigned char v1_payload[MAX_FRAME_PAYLOAD];
  size_t v1_payload_read;
};

struct detached_children {
  pid_t pids[MAX_DETACHED_CHILDREN];
  int count;
};

struct generation_monitor {
  volatile uint8_t *base;
  uint64_t last_generation;
  int unavailable;
};

static int64_t now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
  }
  return 0;
}

static void apply_resume_clock(uint64_t unix_ns) {
  if (unix_ns == 0) return;
  struct timespec ts;
  ts.tv_sec = (time_t)(unix_ns / NSEC_PER_SEC);
  ts.tv_nsec = (long)(unix_ns % NSEC_PER_SEC);
  if (clock_settime(CLOCK_REALTIME, &ts) != 0) {
    dprintf(2, "spore generation: clock_settime failed errno=%d\n", errno);
  }
}

static void mount_proc(void) {
  mkdir("/proc", 0755);
  if (mount("proc", "/proc", "proc", 0, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount proc failed: errno=%d\n", errno);
  }
}

static void mount_sysfs(void) {
  mkdir("/sys", 0755);
  if (mount("sysfs", "/sys", "sysfs", MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount sysfs failed: errno=%d\n", errno);
  }
}

static void mount_cgroup2_if_dir(const char *target) {
  if (!path_is_dir(target)) return;
  if (mount("none", target, "cgroup2", MS_NOSUID | MS_NOEXEC | MS_NODEV, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount cgroup2 failed: target=%s errno=%d\n", target, errno);
  }
}

static void prepare_dev(void) {
  mkdir("/dev", 0755);
  if (mount("devtmpfs", "/dev", "devtmpfs", 0, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount devtmpfs failed: errno=%d\n", errno);
  }
  mkdir("/dev/pts", 0755);
  if (mount("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666") != 0 && errno != EBUSY) {
    dprintf(2, "mount devpts failed: errno=%d\n", errno);
  }
  if (mknod("/dev/null", S_IFCHR | 0666, (dev_t)((1u << 8) | 3u)) != 0 && errno != EEXIST) {
    dprintf(2, "mknod /dev/null failed: errno=%d\n", errno);
  }
}

static void read_cmdline(char *buf, size_t cap) {
  if (cap == 0) return;
  buf[0] = '\0';
  int fd = open("/proc/cmdline", O_RDONLY);
  if (fd < 0) return;
  ssize_t n = read(fd, buf, cap - 1);
  close(fd);
  if (n <= 0) return;
  buf[n] = '\0';
}

static uint32_t resolve_port_from_cmdline(const char *buf) {
  if (buf[0] == '\0') return 10700;
  const char *key = "cleanroom_guest_port=";
  char *p = strstr(buf, key);
  if (p == NULL) return 10700;
  p += strlen(key);
  unsigned long value = strtoul(p, NULL, 10);
  if (value == 0 || value > 65535) return 10700;
  return (uint32_t)value;
}

static int cmdline_has_flag_in(const char *buf, const char *flag) {
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

static const char *generation_root_path(int use_rootfs, int rootfs_ready) {
  if (use_rootfs && rootfs_ready) return "/mnt/rootfs";
  return "";
}

static int write_file_atomic(const char *path, const char *data, size_t len);

static int mount_if_dir(const char *source, const char *target, const char *fstype, unsigned long flags, const char *data, char *error, size_t cap) {
  if (!path_is_dir(target)) return 0;
  if (mount(source, target, fstype, flags, data) != 0 && errno != EBUSY) {
    snprintf(error, cap, "rootfs runtime mount failed: %s errno=%d", target, errno);
    return -1;
  }
  return 0;
}

static int setup_rootfs(int writable, char *error, size_t cap) {
  mkdir("/mnt", 0755);
  mkdir("/mnt/rootfs", 0755);
  if (wait_for_path("/dev/vda", 100, 50000) != 0) {
    snprintf(error, cap, "rootfs block device not found");
    return -1;
  }
  unsigned long rootfs_flags = writable ? 0 : MS_RDONLY;
  const char *rootfs_data = writable ? "" : "noload";
  if (mount("/dev/vda", "/mnt/rootfs", "ext4", rootfs_flags, rootfs_data) != 0) {
    snprintf(error, cap, "rootfs mount failed: errno=%d", errno);
    return -1;
  }
  if (mount_if_dir("devtmpfs", "/mnt/rootfs/dev", "devtmpfs", MS_NOSUID, "", error, cap) != 0) return -1;
  if (mount_if_dir("proc", "/mnt/rootfs/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, "", error, cap) != 0) return -1;
  if (mount_if_dir("sysfs", "/mnt/rootfs/sys", "sysfs", MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV, "", error, cap) != 0) return -1;
  mount_cgroup2_if_dir("/mnt/rootfs/sys/fs/cgroup");
  if (mount_if_dir("tmpfs", "/mnt/rootfs/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755", error, cap) != 0) return -1;
  if (mount_if_dir("tmpfs", "/mnt/rootfs/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777", error, cap) != 0) return -1;
  if (copy_injected_files_to_rootfs(error, cap) != 0) return -1;
  return 0;
}

static int sockaddr_in_addr(struct sockaddr *sa, const char *ip) {
  struct sockaddr_in sin;
  memset(&sin, 0, sizeof(sin));
  sin.sin_family = AF_INET;
  if (inet_pton(AF_INET, ip, &sin.sin_addr) != 1) return -1;
  memcpy(sa, &sin, sizeof(sin));
  return 0;
}

static int wait_for_iface(int fd, const char *name, int attempts, int sleep_us) {
  for (int i = 0; i < attempts; i++) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) == 0) return 0;
    usleep((useconds_t)sleep_us);
  }
  return -1;
}

static int set_iface_sockaddr(int fd, const char *name, unsigned long request, const char *ip) {
  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
  if (sockaddr_in_addr(&ifr.ifr_addr, ip) != 0) return -1;
  return ioctl(fd, request, &ifr);
}

static int bring_iface_up(int fd, const char *name) {
  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
  if (ioctl(fd, SIOCGIFFLAGS, &ifr) != 0) return -1;
  ifr.ifr_flags |= IFF_UP;
  return ioctl(fd, SIOCSIFFLAGS, &ifr);
}

static int add_default_route(int fd, const char *name, const char *gateway) {
  struct rtentry route;
  memset(&route, 0, sizeof(route));
  if (sockaddr_in_addr(&route.rt_dst, "0.0.0.0") != 0) return -1;
  if (sockaddr_in_addr(&route.rt_gateway, gateway) != 0) return -1;
  if (sockaddr_in_addr(&route.rt_genmask, "0.0.0.0") != 0) return -1;
  route.rt_flags = RTF_UP | RTF_GATEWAY;
  route.rt_dev = (char *)name;
  if (ioctl(fd, SIOCADDRT, &route) != 0 && errno != EEXIST) return -1;
  return 0;
}

static int write_resolv_conf_path(const char *path) {
  return write_file_atomic(path, SPORE_NET_RESOLV_CONF, sizeof(SPORE_NET_RESOLV_CONF) - 1);
}

static int mkdir_p(const char *path, mode_t mode) {
  char tmp[192];
  size_t len = strlen(path);
  if (len == 0 || len >= sizeof(tmp)) return -1;
  memcpy(tmp, path, len + 1);
  for (char *p = tmp + 1; *p != '\0'; p++) {
    if (*p != '/') continue;
    *p = '\0';
    if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -1;
    *p = '/';
  }
  if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -1;
  return 0;
}

static int write_resolv_conf_with_parent(const char *path) {
  char parent[192];
  size_t len = strlen(path);
  if (len == 0 || len >= sizeof(parent)) return -1;
  memcpy(parent, path, len + 1);
  char *slash = strrchr(parent, '/');
  if (slash == NULL || slash == parent) return -1;
  *slash = '\0';
  if (mkdir_p(parent, 0755) != 0) return -1;
  return write_resolv_conf_path(path);
}

static int prepare_rootfs_resolv_targets(void) {
  if (write_resolv_conf_with_parent("/mnt/rootfs/run/sporevm/resolv.conf") != 0) return -1;
  if (write_resolv_conf_with_parent("/mnt/rootfs/run/systemd/resolve/stub-resolv.conf") != 0) return -1;
  if (write_resolv_conf_with_parent("/mnt/rootfs/run/systemd/resolve/resolv.conf") != 0) return -1;
  if (write_resolv_conf_with_parent("/mnt/rootfs/run/resolvconf/resolv.conf") != 0) return -1;
  return 0;
}

static int bind_rootfs_resolv(char *error, size_t cap) {
  if (!path_is_dir("/mnt/rootfs/etc")) {
    snprintf(error, cap, "network setup failed: rootfs /etc missing");
    return -1;
  }
  struct stat st;
  if (lstat("/mnt/rootfs/etc/resolv.conf", &st) != 0) {
    snprintf(error, cap, "network setup failed: rootfs /etc/resolv.conf missing");
    return -1;
  }
  if (S_ISLNK(st.st_mode)) return 0;
  if (prepare_rootfs_resolv_targets() != 0) {
    snprintf(error, cap, "network setup failed: rootfs resolv target errno=%d", errno);
    return -1;
  }
  if (mount("/run/sporevm/resolv.conf", "/mnt/rootfs/etc/resolv.conf", NULL, MS_BIND, NULL) != 0 && errno != EBUSY) {
    snprintf(error, cap, "network setup failed: rootfs resolv.conf bind errno=%d", errno);
    return -1;
  }
  return 0;
}

static int setup_network(int use_rootfs, char *error, size_t cap) {
  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    snprintf(error, cap, "network setup failed: socket errno=%d", errno);
    return -1;
  }

  if (wait_for_iface(fd, SPORE_NET_IFACE, 100, 50000) != 0) {
    snprintf(error, cap, "network setup failed: %s not found", SPORE_NET_IFACE);
    close(fd);
    return -1;
  }
  if (set_iface_sockaddr(fd, SPORE_NET_IFACE, SIOCSIFADDR, SPORE_NET_GUEST_IP) != 0) {
    snprintf(error, cap, "network setup failed: set address errno=%d", errno);
    close(fd);
    return -1;
  }
  if (set_iface_sockaddr(fd, SPORE_NET_IFACE, SIOCSIFNETMASK, SPORE_NET_NETMASK) != 0) {
    snprintf(error, cap, "network setup failed: set netmask errno=%d", errno);
    close(fd);
    return -1;
  }
  if (bring_iface_up(fd, SPORE_NET_IFACE) != 0) {
    snprintf(error, cap, "network setup failed: bring link up errno=%d", errno);
    close(fd);
    return -1;
  }
  if (add_default_route(fd, SPORE_NET_IFACE, SPORE_NET_GATEWAY_IP) != 0) {
    snprintf(error, cap, "network setup failed: default route errno=%d", errno);
    close(fd);
    return -1;
  }
  close(fd);

  mkdir("/etc", 0755);
  if (write_resolv_conf_path("/etc/resolv.conf") != 0) {
    snprintf(error, cap, "network setup failed: write /etc/resolv.conf errno=%d", errno);
    return -1;
  }

  if (use_rootfs) {
    mkdir("/run/sporevm", 0755);
    if (write_resolv_conf_path("/run/sporevm/resolv.conf") != 0) {
      snprintf(error, cap, "network setup failed: write rootfs resolv source errno=%d", errno);
      return -1;
    }
    if (bind_rootfs_resolv(error, cap) != 0) return -1;
  }
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

static int write_all(int fd, const void *raw, size_t len) {
  const char *buf = (const char *)raw;
  while (len > 0) {
    ssize_t n = write(fd, buf, len);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    buf += n;
    len -= (size_t)n;
  }
  return 0;
}

static int valid_injected_file_id(const char *id) {
  size_t len = strlen(id);
  if (len == 0 || len > 96) return 0;
  if (strcmp(id, ".") == 0 || strcmp(id, "..") == 0) return 0;
  for (size_t i = 0; i < len; i++) {
    char c = id[i];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') continue;
    return 0;
  }
  return 1;
}

static int copy_injected_file(const char *src, const char *dst) {
  int in = open(src, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (in < 0) return -1;
  struct stat st;
  if (fstat(in, &st) != 0 || !S_ISREG(st.st_mode)) {
    close(in);
    return -1;
  }
  int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0400);
  if (out < 0) {
    close(in);
    return -1;
  }
  char buf[4096];
  int rc = 0;
  for (;;) {
    ssize_t n = read(in, buf, sizeof(buf));
    if (n < 0) {
      if (errno == EINTR) continue;
      rc = -1;
      break;
    }
    if (n == 0) break;
    if (write_all(out, buf, (size_t)n) != 0) {
      rc = -1;
      break;
    }
  }
  if (fchmod(out, 0400) != 0) rc = -1;
  if (close(out) != 0) rc = -1;
  if (close(in) != 0) rc = -1;
  return rc;
}

static int copy_injected_files_to_rootfs(char *error, size_t cap) {
  DIR *dir = opendir(SPORE_INJECTED_INITRD_DIR);
  if (dir == NULL) {
    if (errno == ENOENT) return 0;
    snprintf(error, cap, "injected file setup failed: open injected dir errno=%d", errno);
    return -1;
  }
  if (mkdir_p(SPORE_INJECTED_ROOTFS_DIR, 0700) != 0) {
    snprintf(error, cap, "injected file setup failed: create rootfs dir errno=%d", errno);
    closedir(dir);
    return -1;
  }
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    if (!valid_injected_file_id(entry->d_name)) {
      snprintf(error, cap, "injected file setup failed: invalid injected id");
      closedir(dir);
      return -1;
    }
    char src[192];
    char dst[192];
    int src_len = snprintf(src, sizeof(src), "%s/%s", SPORE_INJECTED_INITRD_DIR, entry->d_name);
    int dst_len = snprintf(dst, sizeof(dst), "%s/%s", SPORE_INJECTED_ROOTFS_DIR, entry->d_name);
    if (src_len <= 0 || (size_t)src_len >= sizeof(src) || dst_len <= 0 || (size_t)dst_len >= sizeof(dst)) {
      snprintf(error, cap, "injected file setup failed: path too long");
      closedir(dir);
      return -1;
    }
    if (copy_injected_file(src, dst) != 0) {
      snprintf(error, cap, "injected file setup failed: copy %s errno=%d", entry->d_name, errno);
      closedir(dir);
      return -1;
    }
  }
  if (closedir(dir) != 0) {
    snprintf(error, cap, "injected file setup failed: close injected dir errno=%d", errno);
    return -1;
  }
  return 0;
}

static int read_exact(int fd, void *raw, size_t len) {
  char *buf = (char *)raw;
  while (len > 0) {
    ssize_t n = read(fd, buf, len);
    if (n == 0) return -1;
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    buf += n;
    len -= (size_t)n;
  }
  return 0;
}

static int write_file_atomic(const char *path, const char *data, size_t len) {
  char tmp[256];
  int n = snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", path, (long)getpid());
  if (n <= 0 || (size_t)n >= sizeof(tmp)) return -1;

  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return -1;
  int rc = write_all(fd, data, len);
  if (close(fd) != 0) rc = -1;
  if (rc != 0) {
    unlink(tmp);
    return -1;
  }
  if (rename(tmp, path) != 0) {
    unlink(tmp);
    return -1;
  }
  return 0;
}

static int parse_string_field(const char *req, const char *name, char *out, size_t cap);
static int parse_u64_field(const char *req, const char *name, uint64_t *out);
static int parse_bool_field(const char *req, const char *name, int *out);

static void env_append(char *env, size_t *len, const char *key, const char *value) {
  if (value[0] == '\0' || *len >= 2048) return;
  int n = snprintf(env + *len, 2048 - *len, "%s=%s\n", key, value);
  if (n > 0 && (size_t)n < 2048 - *len) *len += (size_t)n;
}

static void env_append_u64(char *env, size_t *len, const char *key, uint64_t value) {
  if (*len >= 2048) return;
  int n = snprintf(env + *len, 2048 - *len, "%s=%llu\n", key, (unsigned long long)value);
  if (n > 0 && (size_t)n < 2048 - *len) *len += (size_t)n;
}

static int build_path(char *out, size_t cap, const char *root, const char *suffix) {
  int n = snprintf(out, cap, "%s%s", root, suffix);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int write_generation_files(const char *root, const char *params) {
  char run_dir[128];
  char spore_dir[160];
  char generation_path[192];
  char env_path[192];
  if (build_path(run_dir, sizeof(run_dir), root, "/run") != 0) return -1;
  if (build_path(spore_dir, sizeof(spore_dir), root, "/run/sporevm") != 0) return -1;
  if (build_path(generation_path, sizeof(generation_path), spore_dir, "/generation.json") != 0) return -1;
  if (build_path(env_path, sizeof(env_path), spore_dir, "/env") != 0) return -1;

  if (mkdir(run_dir, 0755) != 0 && errno != EEXIST) return -1;
  if (mkdir(spore_dir, 0755) != 0 && errno != EEXIST) return -1;

  char json_with_newline[GEN_PARAMS_MAX + 2];
  size_t params_len = strlen(params);
  if (params_len + 1 >= sizeof(json_with_newline)) return -1;
  memcpy(json_with_newline, params, params_len);
  json_with_newline[params_len] = '\n';
  json_with_newline[params_len + 1] = '\0';
  if (write_file_atomic(generation_path, json_with_newline, params_len + 1) != 0) return -1;

  char env[2048];
  size_t env_len = 0;
  env[0] = '\0';

  uint64_t value = 0;
  uint64_t fork_index = 0;
  uint64_t fork_count = 0;
  uint64_t parallel_index = 0;
  uint64_t parallel_count = 0;
  int have_fork_index = parse_u64_field(params, "fork_index", &fork_index);
  int have_fork_count = parse_u64_field(params, "fork_count", &fork_count);
  int have_parallel_index = parse_u64_field(params, "parallel_index", &parallel_index);
  int have_parallel_count = parse_u64_field(params, "parallel_count", &parallel_count);
  if (have_parallel_index == 0 && have_fork_index > 0) {
    parallel_index = fork_index;
    have_parallel_index = 1;
  }
  if (have_parallel_count == 0 && have_fork_count > 0) {
    parallel_count = fork_count;
    have_parallel_count = 1;
  }
  if (have_parallel_index > 0) env_append_u64(env, &env_len, "SPORE_PARALLEL_JOB", parallel_index);
  if (have_parallel_count > 0) env_append_u64(env, &env_len, "SPORE_PARALLEL_JOB_COUNT", parallel_count);
  if (have_fork_index > 0) env_append_u64(env, &env_len, "SPORE_FORK_INDEX", fork_index);
  if (have_fork_count > 0) env_append_u64(env, &env_len, "SPORE_FORK_COUNT", fork_count);
  if (parse_u64_field(params, "parent_generation", &value) > 0) env_append_u64(env, &env_len, "SPORE_PARENT_GENERATION", value);
  if (parse_u64_field(params, "generation", &value) > 0) env_append_u64(env, &env_len, "SPORE_GENERATION", value);
  if (parse_u64_field(params, "resume_time_unix_ns", &value) > 0) env_append_u64(env, &env_len, "SPORE_RESUME_TIME_UNIX_NS", value);

  char text[128];
  if (parse_string_field(params, "vm_id", text, sizeof(text)) > 0) env_append(env, &env_len, "SPORE_VM_ID", text);
  if (parse_string_field(params, "fork_batch_id", text, sizeof(text)) > 0) env_append(env, &env_len, "SPORE_FORK_BATCH_ID", text);
  if (parse_string_field(params, "hostname", text, sizeof(text)) > 0) env_append(env, &env_len, "SPORE_HOSTNAME", text);
  if (parse_string_field(params, "resume_entropy_seed", text, sizeof(text)) > 0) env_append(env, &env_len, "SPORE_RESUME_ENTROPY_SEED", text);

  return write_file_atomic(env_path, env, env_len);
}

static volatile uint8_t *generation_map(void) {
  mkdir("/dev", 0755);
  if (mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1)) != 0 && errno != EEXIST) {
    dprintf(2, "spore generation: mknod /dev/mem failed errno=%d\n", errno);
    return NULL;
  }
  int fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
  if (fd < 0) {
    dprintf(2, "spore generation: open /dev/mem failed errno=%d\n", errno);
    return NULL;
  }
  void *mapped = mmap(NULL, GEN_WINDOW_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GEN_BASE);
  close(fd);
  if (mapped == MAP_FAILED) {
    dprintf(2, "spore generation: mmap failed errno=%d\n", errno);
    return NULL;
  }
  return (volatile uint8_t *)mapped;
}

static uint32_t mmio_read32(volatile uint8_t *base, unsigned offset) {
  volatile uint32_t *p = (volatile uint32_t *)(base + offset);
  return *p;
}

static uint64_t mmio_read64(volatile uint8_t *base, unsigned offset) {
  uint64_t lo = mmio_read32(base, offset);
  uint64_t hi = mmio_read32(base, offset + 4);
  return lo | (hi << 32);
}

static void mmio_write32(volatile uint8_t *base, unsigned offset, uint32_t value) {
  volatile uint32_t *p = (volatile uint32_t *)(base + offset);
  *p = value;
}

static int mix_resume_entropy(const char *params) {
  char entropy_seed[80];
  int rc = parse_string_field(params, "resume_entropy_seed", entropy_seed, sizeof(entropy_seed));
  if (rc < 0) return -1;
  if (rc == 0 || entropy_seed[0] == '\0') return 0;

  if (mknod("/dev/urandom", S_IFCHR | 0600, makedev(1, 9)) != 0 && errno != EEXIST) return -1;
  int fd = open("/dev/urandom", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  int write_rc = write_all(fd, entropy_seed, strlen(entropy_seed));
  if (close(fd) != 0) write_rc = -1;
  return write_rc;
}

static int apply_generation_identity(const char *params) {
  char hostname[128];
  int hostname_rc = parse_string_field(params, "hostname", hostname, sizeof(hostname));
  if (hostname_rc < 0) return -1;
  if (hostname_rc > 0 && hostname[0] != '\0') {
    (void)sethostname(hostname, strlen(hostname));
  }
  if (mix_resume_entropy(params) != 0) return -1;
  uint64_t resume_time_unix_ns = 0;
  int resume_time_rc = parse_u64_field(params, "resume_time_unix_ns", &resume_time_unix_ns);
  if (resume_time_rc < 0) return -1;
  if (resume_time_rc > 0) {
    apply_resume_clock(resume_time_unix_ns);
  }
  return 0;
}

static int poll_generation(struct generation_monitor *monitor, const char *root) {
  if (monitor->unavailable) return 0;
  if (monitor->base == NULL) {
    monitor->base = generation_map();
    if (monitor->base == NULL) {
      monitor->unavailable = 1;
      return 0;
    }
  }

  if (mmio_read32(monitor->base, REG_MAGIC) != GEN_MAGIC) return 0;
  uint32_t params_offset = mmio_read32(monitor->base, REG_PARAMS_OFFSET);
  uint32_t params_size = mmio_read32(monitor->base, REG_PARAMS_SIZE);
  if (params_offset >= GEN_WINDOW_SIZE || params_size > GEN_WINDOW_SIZE - params_offset) return 0;

  uint64_t generation = mmio_read64(monitor->base, REG_GENERATION);
  if (generation == monitor->last_generation) return 0;

  char params[GEN_PARAMS_MAX];
  size_t limit = params_size;
  if (limit >= sizeof(params)) limit = sizeof(params) - 1;
  size_t i = 0;
  for (; i < limit; i++) {
    params[i] = (char)*(monitor->base + params_offset + i);
    if (params[i] == '\0') break;
  }
  params[i] = '\0';
  if (params[0] == '\0') return 0;

  if (write_generation_files(root, params) != 0) return -1;
  uint32_t irq_status = mmio_read32(monitor->base, REG_IRQ_STATUS);
  if (apply_generation_identity(params) != 0) return -1;
  monitor->last_generation = generation;
  if ((irq_status & GEN_IRQ_GENERATION_CHANGED) != 0) {
    mmio_write32(monitor->base, REG_IRQ_ACK, GEN_IRQ_GENERATION_CHANGED);
  }
  return 0;
}

static int ensure_generation_ready(struct generation_monitor *monitor, const char *root) {
  if (poll_generation(monitor, root) != 0) return -1;
  return monitor->last_generation == UINT64_MAX ? -1 : 0;
}

static void ack_applied_generation(struct generation_monitor *monitor, const char *params) {
  uint64_t applied_generation = 0;
  int generation_rc = parse_u64_field(params, "generation", &applied_generation);
  if (generation_rc <= 0 || monitor->unavailable) return;
  if (monitor->base == NULL) {
    monitor->base = generation_map();
    if (monitor->base == NULL) {
      monitor->unavailable = 1;
      return;
    }
  }
  if (mmio_read32(monitor->base, REG_MAGIC) != GEN_MAGIC) return;
  if (mmio_read64(monitor->base, REG_GENERATION) != applied_generation) return;
  monitor->last_generation = applied_generation;
  if ((mmio_read32(monitor->base, REG_IRQ_STATUS) & GEN_IRQ_GENERATION_CHANGED) != 0) {
    mmio_write32(monitor->base, REG_IRQ_ACK, GEN_IRQ_GENERATION_CHANGED);
  }
}

static int set_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void replay_append(struct replay_buffer *replay, uint64_t offset, const unsigned char *buf, size_t len) {
  if (len >= REPLAY_CAP) {
    memcpy(replay->data, buf + (len - REPLAY_CAP), REPLAY_CAP);
    replay->base_offset = offset + len - REPLAY_CAP;
    replay->len = REPLAY_CAP;
    return;
  }
  if (replay->len + len > REPLAY_CAP) {
    size_t drop = replay->len + len - REPLAY_CAP;
    memmove(replay->data, replay->data + drop, replay->len - drop);
    replay->base_offset += drop;
    replay->len -= drop;
  }
  memcpy(replay->data + replay->len, buf, len);
  replay->len += len;
}

static int send_stream_frame(int fd, const char *name, uint64_t offset, const unsigned char *buf, size_t len) {
  char header[96];
  int n = snprintf(header, sizeof(header), "%s %llu %zu\n", name, (unsigned long long)offset, len);
  if (n <= 0 || (size_t)n >= sizeof(header)) return -1;
  if (write_all(fd, header, (size_t)n) != 0) return -1;
  if (len > 0 && write_all(fd, buf, len) != 0) return -1;
  return 0;
}

static int send_stream_data(int fd, const char *name, uint64_t offset, const unsigned char *buf, size_t len) {
  size_t sent = 0;
  while (sent < len) {
    size_t chunk = len - sent;
    if (chunk > MAX_FRAME_PAYLOAD) chunk = MAX_FRAME_PAYLOAD;
    if (send_stream_frame(fd, name, offset + sent, buf + sent, chunk) != 0) return -1;
    sent += chunk;
  }
  return 0;
}

static void write_le16(unsigned char *out, uint16_t value) {
  out[0] = (unsigned char)(value & 0xff);
  out[1] = (unsigned char)((value >> 8) & 0xff);
}

static void write_le32(unsigned char *out, uint32_t value) {
  out[0] = (unsigned char)(value & 0xff);
  out[1] = (unsigned char)((value >> 8) & 0xff);
  out[2] = (unsigned char)((value >> 16) & 0xff);
  out[3] = (unsigned char)((value >> 24) & 0xff);
}

static void write_le64(unsigned char *out, uint64_t value) {
  for (int i = 0; i < 8; i++) {
    out[i] = (unsigned char)((value >> (8 * i)) & 0xff);
  }
}

static uint16_t read_le16(const unsigned char *in) {
  return (uint16_t)in[0] | ((uint16_t)in[1] << 8);
}

static uint32_t read_le32(const unsigned char *in) {
  return (uint32_t)in[0] | ((uint32_t)in[1] << 8) | ((uint32_t)in[2] << 16) | ((uint32_t)in[3] << 24);
}

static uint64_t read_le64(const unsigned char *in) {
  uint64_t value = 0;
  for (int i = 0; i < 8; i++) {
    value |= ((uint64_t)in[i]) << (8 * i);
  }
  return value;
}

static int send_spio_frame(int fd, uint8_t type, uint32_t stream_id, uint64_t offset, const unsigned char *payload, size_t len) {
  if (len > MAX_FRAME_PAYLOAD) return -1;
  unsigned char header[SPIO_HEADER_LEN];
  memcpy(header, SPIO_MAGIC, 4);
  header[4] = SPIO_VERSION;
  header[5] = type;
  write_le16(header + 6, 0);
  write_le32(header + 8, stream_id);
  write_le64(header + 12, offset);
  write_le32(header + 20, (uint32_t)len);
  if (write_all(fd, header, sizeof(header)) != 0) return -1;
  if (len > 0 && write_all(fd, payload, len) != 0) return -1;
  return 0;
}

static int send_spio_data(int fd, uint32_t stream_id, uint64_t offset, const unsigned char *buf, size_t len) {
  size_t sent = 0;
  while (sent < len) {
    size_t chunk = len - sent;
    if (chunk > MAX_FRAME_PAYLOAD) chunk = MAX_FRAME_PAYLOAD;
    if (send_spio_frame(fd, SPIO_DATA, stream_id, offset + sent, buf + sent, chunk) != 0) return -1;
    sent += chunk;
  }
  return 0;
}

static int send_spio_event(int fd, const char *event) {
  return send_spio_frame(fd, SPIO_EVENT, SPIO_CONTROL_STREAM, 0, (const unsigned char *)event, strlen(event));
}

static int send_spio_exit(int fd, int exit_code) {
  unsigned char payload[4];
  write_le32(payload, (uint32_t)exit_code);
  return send_spio_frame(fd, SPIO_EXIT, SPIO_CONTROL_STREAM, 0, payload, sizeof(payload));
}

static int format_timing(char *frame, size_t cap) {
  int64_t now = now_ms();
  int n = snprintf(frame, cap,
                   "timing listen=%lld accept=%lld decode=%lld spawn=%lld exit=%lld now=%lld\n",
                   (long long)(t_listen_ready ? t_listen_ready - t_init_start : -1),
                   (long long)(t_request_accept ? t_request_accept - t_init_start : -1),
                   (long long)(t_request_decode ? t_request_decode - t_init_start : -1),
                   (long long)(t_command_start ? t_command_start - t_init_start : -1),
                   (long long)(t_command_exit ? t_command_exit - t_init_start : -1),
                   (long long)(now ? now - t_init_start : -1));
  if (n <= 0 || (size_t)n >= cap) return -1;
  return n;
}

static int send_timing_frame(int fd) {
  char frame[128];
  int n = format_timing(frame, sizeof(frame));
  if (n < 0) return -1;
  return write_all(fd, frame, (size_t)n);
}

static int send_spio_timing_frame(int fd) {
  char frame[128];
  int n = format_timing(frame, sizeof(frame));
  if (n < 0) return -1;
  if (n > 0 && frame[n - 1] == '\n') n--;
  return send_spio_frame(fd, SPIO_EVENT, SPIO_CONTROL_STREAM, 0, (const unsigned char *)frame, (size_t)n);
}

static int send_memory_pressure_frame(int fd) {
  return write_all(fd, "memory-pressure\n", 16);
}

static int send_exit_frame(int fd, int exit_code) {
  char frame[32];
  int n = snprintf(frame, sizeof(frame), "exit %d\n", exit_code);
  if (n <= 0 || (size_t)n >= sizeof(frame)) return -1;
  (void)send_timing_frame(fd);
  return write_all(fd, frame, (size_t)n);
}

static int write_text_file(const char *path, const char *text) {
  int fd = open(path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  int rc = write_all(fd, text, strlen(text));
  close(fd);
  return rc;
}

static int write_pid_file(const char *path, pid_t pid) {
  char buf[32];
  int n = snprintf(buf, sizeof(buf), "%ld\n", (long)pid);
  if (n <= 0 || (size_t)n >= sizeof(buf)) return -1;
  return write_text_file(path, buf);
}

static int read_u64_file(const char *path, uint64_t *out) {
  char buf[32];
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n <= 0) return -1;
  buf[n] = '\0';
  char *end = NULL;
  unsigned long long value = strtoull(buf, &end, 10);
  if (end == buf) return -1;
  *out = (uint64_t)value;
  return 0;
}

static int cgroup_child_path(char *out, size_t out_len, const char *dir, const char *file) {
  int n = snprintf(out, out_len, "%s/%s", dir, file);
  return (n > 0 && (size_t)n < out_len) ? 0 : -1;
}

static void close_memory_pressure(struct session *session) {
  if (session->memory_pressure_fd >= 0) {
    close(session->memory_pressure_fd);
    session->memory_pressure_fd = -1;
  }
  if (session->memory_cgroup_path[0] != '\0') {
    if (rmdir(session->memory_cgroup_path) == 0 || errno == ENOENT) {
      session->memory_cgroup_path[0] = '\0';
    }
  }
}

static int memory_pressure_setup_error(const char *step) {
  dprintf(2, "memory pressure setup failed: %s errno=%d\n", step, errno);
  return -1;
}

static int setup_memory_pressure(struct session *session, pid_t pid) {
  if (write_text_file("/sys/fs/cgroup/cgroup.subtree_control", "+memory\n") != 0) return memory_pressure_setup_error("enable memory controller");
  int n = snprintf(session->memory_cgroup_path, sizeof(session->memory_cgroup_path), "/sys/fs/cgroup/spore-run-%ld", (long)pid);
  if (n <= 0 || (size_t)n >= sizeof(session->memory_cgroup_path)) return memory_pressure_setup_error("format cgroup path");
  if (mkdir(session->memory_cgroup_path, 0755) != 0) return memory_pressure_setup_error("create cgroup");

  char path[192];
  if (cgroup_child_path(path, sizeof(path), session->memory_cgroup_path, "memory.high") != 0 ||
      write_text_file(path, memory_high_limit) != 0) return memory_pressure_setup_error("set high limit");
  if (cgroup_child_path(path, sizeof(path), session->memory_cgroup_path, "cgroup.procs") != 0 ||
      write_pid_file(path, pid) != 0) return memory_pressure_setup_error("move process");
  if (cgroup_child_path(path, sizeof(path), session->memory_cgroup_path, "memory.events") != 0) return memory_pressure_setup_error("format events path");
  session->memory_pressure_fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  if (session->memory_pressure_fd < 0) return memory_pressure_setup_error("open events");
  char buf[256];
  (void)read(session->memory_pressure_fd, buf, sizeof(buf));
  return 0;
}

static void drain_memory_pressure_events(struct session *session) {
  char buf[256];
  (void)lseek(session->memory_pressure_fd, 0, SEEK_SET);
  (void)read(session->memory_pressure_fd, buf, sizeof(buf));
}

static int rearm_memory_pressure_limit(struct session *session) {
  char path[192];
  uint64_t current = 0;
  if (cgroup_child_path(path, sizeof(path), session->memory_cgroup_path, "memory.current") != 0 ||
      read_u64_file(path, &current) != 0) return -1;
  uint64_t next = current + memory_high_step_bytes;
  if (next < current) return -1;
  if (cgroup_child_path(path, sizeof(path), session->memory_cgroup_path, "memory.high") != 0) return -1;
  char limit[32];
  int n = snprintf(limit, sizeof(limit), "%llu\n", (unsigned long long)next);
  if (n <= 0 || (size_t)n >= sizeof(limit)) return -1;
  return write_text_file(path, limit);
}

static void close_client(struct client *client) {
  if (client->fd >= 0) {
    close(client->fd);
    client->fd = -1;
  }
  client->protocol_v1 = 0;
  client->stdout_offset = 0;
  client->stderr_offset = 0;
  client->stdin_offset = 0;
  client->terminal_offset = 0;
  client->terminal_input_offset = 0;
  client->stdin_input_owner = 0;
  client->terminal_input_owner = 0;
  client->v1_header_len = 0;
  client->v1_type = 0;
  client->v1_stream_id = 0;
  client->v1_offset = 0;
  client->v1_payload_len = 0;
  client->v1_payload_read = 0;
}

static int send_client_output(struct session *session, struct client *client, const char *name, uint64_t *client_offset, uint64_t offset, const unsigned char *buf, size_t len) {
  if (client->fd < 0) return -1;
  if (*client_offset != offset) return 0;
  int rc;
  if (client->protocol_v1) {
    uint32_t stream_id = strcmp(name, "stdout") == 0 ? SPIO_STDOUT_STREAM : SPIO_STDERR_STREAM;
    rc = send_spio_data(client->fd, stream_id, offset, buf, len);
  } else {
    rc = send_stream_data(client->fd, name, offset, buf, len);
  }
  if (rc != 0) {
    close_client_input_lost(session, client);
    return -1;
  }
  *client_offset += len;
  return 0;
}

static int send_client_terminal_output(struct session *session, struct client *client, uint64_t offset, const unsigned char *buf, size_t len) {
  if (client->fd < 0 || !client->protocol_v1) return -1;
  if (client->terminal_offset != offset) return 0;
  if (send_spio_data(client->fd, SPIO_TERMINAL_STREAM, offset, buf, len) != 0) {
    close_client_input_lost(session, client);
    return -1;
  }
  client->terminal_offset += len;
  return 0;
}

static void mirror_console(int is_stdout, const unsigned char *buf, size_t len) {
  int fd = is_stdout ? STDOUT_FILENO : STDERR_FILENO;
  (void)write_all(fd, buf, len);
}

static int wait_child(pid_t pid, int *status) {
  for (;;) {
    pid_t rc = waitpid(pid, status, WNOHANG);
    if (rc == pid) return 1;
    if (rc == 0) return 0;
    if (errno == EINTR) continue;
    return -1;
  }
}

static void sigchld_handler(int signum) {
  (void)signum;
  int saved_errno = errno;
  if (sigchld_pipe[1] >= 0) {
    char byte = 1;
    (void)write(sigchld_pipe[1], &byte, 1);
  }
  errno = saved_errno;
}

static int setup_sigchld_wakeup(void) {
  if (pipe2(sigchld_pipe, O_CLOEXEC | O_NONBLOCK) != 0) return -1;

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = sigchld_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_NOCLDSTOP | SA_RESTART;
  return sigaction(SIGCHLD, &sa, NULL);
}

static void drain_sigchld_wakeup(void) {
  char buf[32];
  while (read(sigchld_pipe[0], buf, sizeof(buf)) > 0) {
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

static const char *find_field_value(const char *req, const char *name) {
  char key[64];
  snprintf(key, sizeof(key), "\"%s\"", name);
  size_t key_len = strlen(key);
  const char *p = req;
  while ((p = strstr(p, key)) != NULL) {
    const char *value = skip_ws(p + key_len);
    if (*value == ':') return skip_ws(value + 1);
    p += key_len;
  }
  return NULL;
}

static int parse_env(const char *req, char storage[MAX_ENVC][MAX_ENV_LEN], char *envp[MAX_ENVC + 1]) {
  const char *p = find_field_value(req, "env");
  if (p == NULL) {
    envp[0] = NULL;
    return 0;
  }
  if (*p != '[') return -1;
  p++;

  int envc = 0;
  for (;;) {
    p = skip_ws(p);
    if (*p == ']') {
      envp[envc] = NULL;
      return envc;
    }
    if (envc >= MAX_ENVC) return -1;
    if (parse_json_string(&p, storage[envc], MAX_ENV_LEN) != 0) return -1;
    envp[envc] = storage[envc];
    envc++;

    p = skip_ws(p);
    if (*p == ',') {
      p++;
      continue;
    }
    if (*p == ']') {
      envp[envc] = NULL;
      return envc;
    }
    return -1;
  }
}

enum request_kind {
  REQUEST_START,
  REQUEST_ATTACH,
  REQUEST_GENERATION,
  REQUEST_COPY_IN,
  REQUEST_COPY_OUT,
};

struct run_request {
  enum request_kind kind;
  char session_id[64];
  uint64_t stdout_offset;
  uint64_t stderr_offset;
  uint64_t resume_time_unix_ns;
  int protocol_v1;
  int stdin_enabled;
  int tty;
  int interactive;
  uint16_t terminal_rows;
  uint16_t terminal_cols;
  int memory_pressure;
  int detached;
  int require_generation_ready;
  char generation_params[GEN_PARAMS_MAX];
  char copy_path[MAX_COPY_PATH_LEN];
  char arg_storage[MAX_ARGC][MAX_ARG_LEN];
  char *argv[MAX_ARGC + 1];
  char env_storage[MAX_ENVC][MAX_ENV_LEN];
  char *envp[MAX_ENVC + 1];
  char working_dir[MAX_WORKDIR_LEN];
};

static int parse_string_field(const char *req, const char *name, char *out, size_t cap) {
  const char *p = find_field_value(req, name);
  if (p == NULL) return 0;
  return parse_json_string(&p, out, cap) == 0 ? 1 : -1;
}

static int parse_u64_field(const char *req, const char *name, uint64_t *out) {
  const char *p = find_field_value(req, name);
  if (p == NULL) return 0;
  errno = 0;
  char *end = NULL;
  unsigned long long value = strtoull(p, &end, 10);
  if (errno != 0 || end == p) return -1;
  *out = (uint64_t)value;
  return 1;
}

static int json_token_finished(char c) {
  return c == '\0' || c == ',' || c == '}' || c == ']' || c == ' ' || c == '\n' || c == '\r' || c == '\t';
}

static int parse_bool_field(const char *req, const char *name, int *out) {
  const char *p = find_field_value(req, name);
  if (p == NULL) return 0;
  if (strncmp(p, "true", 4) == 0 && json_token_finished(p[4])) {
    *out = 1;
    return 1;
  }
  if (strncmp(p, "false", 5) == 0 && json_token_finished(p[5])) {
    *out = 0;
    return 1;
  }
  return -1;
}

static int parse_request(const char *req, struct run_request *out) {
  memset(out, 0, sizeof(*out));
  out->kind = REQUEST_START;
  out->terminal_rows = 24;
  out->terminal_cols = 80;

  char type[32];
  int type_rc = parse_string_field(req, "type", type, sizeof(type));
  if (type_rc < 0) return -1;
  if (type_rc > 0) {
    if (strcmp(type, "start") == 0) {
      out->kind = REQUEST_START;
    } else if (strcmp(type, "start-v1") == 0) {
      out->kind = REQUEST_START;
      out->protocol_v1 = 1;
    } else if (strcmp(type, "attach") == 0) {
      out->kind = REQUEST_ATTACH;
    } else if (strcmp(type, "attach-v1") == 0) {
      out->kind = REQUEST_ATTACH;
      out->protocol_v1 = 1;
    } else if (strcmp(type, "generation") == 0) {
      out->kind = REQUEST_GENERATION;
    } else if (strcmp(type, "copy-in-v1") == 0) {
      out->kind = REQUEST_COPY_IN;
      out->protocol_v1 = 1;
    } else if (strcmp(type, "copy-out-v1") == 0) {
      out->kind = REQUEST_COPY_OUT;
      out->protocol_v1 = 1;
    } else {
      return -1;
    }
  }

  char req_session_id[64];
  int session_rc = parse_string_field(req, "session_id", req_session_id, sizeof(req_session_id));
  if (session_rc < 0) return -1;
  if (session_rc > 0) {
    if (req_session_id[0] == '\0') return -1;
    snprintf(out->session_id, sizeof(out->session_id), "%s", req_session_id);
  } else {
    snprintf(out->session_id, sizeof(out->session_id), "%s", SESSION_ID);
  }

  uint64_t offset = 0;
  int stdout_rc = parse_u64_field(req, "stdout_offset", &offset);
  if (stdout_rc < 0) return -1;
  if (stdout_rc > 0) out->stdout_offset = offset;
  offset = 0;
  int stderr_rc = parse_u64_field(req, "stderr_offset", &offset);
  if (stderr_rc < 0) return -1;
  if (stderr_rc > 0) out->stderr_offset = offset;
  uint64_t resume_time_unix_ns = 0;
  int resume_time_rc = parse_u64_field(req, "resume_time_unix_ns", &resume_time_unix_ns);
  if (resume_time_rc < 0) return -1;
  if (resume_time_rc > 0) out->resume_time_unix_ns = resume_time_unix_ns;

  if (out->kind == REQUEST_GENERATION || out->kind == REQUEST_ATTACH || out->kind == REQUEST_START) {
    int params_rc = parse_string_field(req, "params_json", out->generation_params, sizeof(out->generation_params));
    if (out->kind == REQUEST_GENERATION && params_rc <= 0) return -1;
    if (params_rc < 0) return -1;
  }
  if (out->kind == REQUEST_COPY_IN || out->kind == REQUEST_COPY_OUT) {
    int path_rc = parse_string_field(req, "path", out->copy_path, sizeof(out->copy_path));
    if (path_rc <= 0) return -1;
  }
  if (out->protocol_v1 && (out->kind == REQUEST_START || out->kind == REQUEST_ATTACH)) {
    char stdio[16];
    int stdio_rc = parse_string_field(req, "stdio", stdio, sizeof(stdio));
    if (stdio_rc <= 0) return -1;
    if (strcmp(stdio, "pipe") == 0) {
      out->stdin_enabled = 1;
    } else if (strcmp(stdio, "tty") == 0) {
      out->tty = 1;
      uint64_t rows = 0;
      uint64_t cols = 0;
      int rows_rc = parse_u64_field(req, "terminal_rows", &rows);
      int cols_rc = parse_u64_field(req, "terminal_cols", &cols);
      if (rows_rc < 0 || cols_rc < 0) return -1;
      if (rows_rc > 0 && rows > 0 && rows <= UINT16_MAX) out->terminal_rows = (uint16_t)rows;
      if (cols_rc > 0 && cols > 0 && cols <= UINT16_MAX) out->terminal_cols = (uint16_t)cols;
    } else {
      return -1;
    }
    int interactive = 0;
    int interactive_rc = parse_bool_field(req, "interactive", &interactive);
    if (interactive_rc < 0) return -1;
    if (interactive_rc > 0) out->interactive = interactive;
    if (out->kind == REQUEST_ATTACH && out->stdin_enabled && !out->interactive) return -1;
  }
  if (out->kind == REQUEST_START) {
    if (parse_argv(req, out->arg_storage, out->argv) <= 0) return -1;
    if (parse_env(req, out->env_storage, out->envp) < 0) return -1;
    int working_dir_rc = parse_string_field(req, "working_dir", out->working_dir, sizeof(out->working_dir));
    if (working_dir_rc < 0) return -1;
    if (working_dir_rc == 0) out->working_dir[0] = '\0';
    int memory_pressure = 0;
    int memory_pressure_rc = parse_bool_field(req, "memory_pressure", &memory_pressure);
    if (memory_pressure_rc < 0) return -1;
    if (memory_pressure_rc > 0) out->memory_pressure = memory_pressure;
    int detached = 0;
    int detached_rc = parse_bool_field(req, "detached", &detached);
    if (detached_rc < 0) return -1;
    if (detached_rc > 0) out->detached = detached;
    int require_generation_ready = 0;
    int generation_ready_rc = parse_bool_field(req, "require_generation_ready", &require_generation_ready);
    if (generation_ready_rc < 0) return -1;
    if (generation_ready_rc > 0) out->require_generation_ready = require_generation_ready;
    if (out->protocol_v1) {
      if (out->detached) return -1;
    }
  }
  return 0;
}

static int send_error_exit(int fd, int code, const char *message) {
  (void)send_stream_data(fd, "stderr", 0, (const unsigned char *)message, strlen(message));
  return send_exit_frame(fd, code);
}

static int send_client_error_exit(struct client *client, int code, const char *message) {
  if (client->fd < 0) return -1;
  if (!client->protocol_v1) return send_error_exit(client->fd, code, message);

  size_t len = strlen(message);
  if (len > 0) {
    if (send_spio_data(client->fd, SPIO_STDERR_STREAM, client->stderr_offset, (const unsigned char *)message, len) != 0) return -1;
    client->stderr_offset += len;
  }
  if (send_spio_timing_frame(client->fd) != 0) return -1;
  return send_spio_exit(client->fd, code);
}

static int send_client_exit(struct client *client, int code) {
  if (client->fd < 0) return -1;
  if (!client->protocol_v1) return send_exit_frame(client->fd, code);
  if (send_spio_timing_frame(client->fd) != 0) return -1;
  return send_spio_exit(client->fd, code);
}

static int validate_copy_path(const char *path) {
  if (path[0] != '/' || path[1] == '\0') return -1;
  size_t len = strlen(path);
  if (len >= MAX_COPY_PATH_LEN || path[len - 1] == '/') return -1;
  const char *p = path + 1;
  while (*p != '\0') {
    const char *start = p;
    while (*p != '\0' && *p != '/') p++;
    size_t part_len = (size_t)(p - start);
    if (part_len == 0) return -1;
    if (part_len == 1 && start[0] == '.') return -1;
    if (part_len == 2 && start[0] == '.' && start[1] == '.') return -1;
    if (*p == '/') p++;
  }
  return 0;
}

static int build_copy_path(char *out, size_t cap, const char *root, const char *guest_path) {
  int n = root[0] == '\0'
      ? snprintf(out, cap, "%s", guest_path)
      : snprintf(out, cap, "%s%s", root, guest_path);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int build_copy_tmp_path(char *out, size_t cap, const char *path, unsigned attempt) {
  const char *slash = strrchr(path, '/');
  if (slash == NULL || slash[1] == '\0') return -1;
  const char *name = slash + 1;
  int n;
  if (slash == path) {
    n = snprintf(out, cap, "/.%s.spore-copy.%ld.%u.tmp", name, (long)getpid(), attempt);
  } else {
    n = snprintf(out, cap, "%.*s/.%s.spore-copy.%ld.%u.tmp", (int)(slash - path), path, name, (long)getpid(), attempt);
  }
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int reserve_copy_tmp_dir(char *out, size_t cap, const char *path) {
  for (unsigned attempt = 0; attempt < 16; attempt++) {
    if (build_copy_tmp_path(out, cap, path, attempt) != 0) return -1;
    if (mkdir(out, 0700) == 0) return 0;
    if (errno != EEXIST) return -1;
  }
  errno = EEXIST;
  return -1;
}

static int read_spio_header_blocking(int fd, uint8_t *type, uint32_t *stream_id, uint64_t *offset, uint32_t *payload_len) {
  unsigned char header[SPIO_HEADER_LEN];
  if (read_exact(fd, header, sizeof(header)) != 0) return -1;
  if (memcmp(header, SPIO_MAGIC, 4) != 0) return -1;
  if (header[4] != SPIO_VERSION) return -1;
  if (read_le16(header + 6) != 0) return -1;
  *type = header[5];
  *stream_id = read_le32(header + 8);
  *offset = read_le64(header + 12);
  *payload_len = read_le32(header + 20);
  if (*payload_len > MAX_FRAME_PAYLOAD) return -1;
  return 0;
}

static const unsigned char copy_archive_magic[8] = { 'S', 'P', 'C', 'P', '1', '\n', '\0', '\n' };

struct copy_record {
  int kind;
  char path[MAX_COPY_PATH_LEN + 1];
  size_t path_len;
  uint32_t mode;
  uint64_t size;
};

static int validate_copy_archive_path(const char *path, size_t len, int allow_root) {
  if (len == 0) return allow_root ? 0 : -1;
  if (len > MAX_COPY_PATH_LEN || path[0] == '/' || path[len - 1] == '/') return -1;
  size_t i = 0;
  while (i < len) {
    size_t start = i;
    while (i < len && path[i] != '/') {
      if (path[i] == '\0') return -1;
      i++;
    }
    size_t part_len = i - start;
    if (part_len == 0) return -1;
    if (part_len == 1 && path[start] == '.') return -1;
    if (part_len == 2 && path[start] == '.' && path[start + 1] == '.') return -1;
    if (i < len && path[i] == '/') i++;
  }
  return 0;
}

static int build_copy_archive_target(char *out, size_t cap, const char *root, const char *rel) {
  int n = rel[0] == '\0'
      ? snprintf(out, cap, "%s", root)
      : snprintf(out, cap, "%s/%s", root, rel);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int remove_tree(const char *path) {
  struct stat st;
  if (lstat(path, &st) != 0) return -1;
  if (!S_ISDIR(st.st_mode)) return unlink(path);

  int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return -1;
  DIR *dir = fdopendir(fd);
  if (dir == NULL) {
    close(fd);
    return -1;
  }

  struct dirent *entry;
  int rc = 0;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    char child[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
    int n = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
    if (n <= 0 || (size_t)n >= sizeof(child) || remove_tree(child) != 0) rc = -1;
  }
  if (closedir(dir) != 0) rc = -1;
  if (rmdir(path) != 0) rc = -1;
  return rc;
}

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif

static int rename_noreplace(const char *old_path, const char *new_path) {
#ifdef SYS_renameat2
  if (syscall(SYS_renameat2, AT_FDCWD, old_path, AT_FDCWD, new_path, RENAME_NOREPLACE) == 0) return 0;
  return -1;
#else
  errno = ENOSYS;
  return -1;
#endif
}

static int receive_copy_archive_from_spio(struct client *client, const char *archive_path) {
  int fd = open(archive_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return -1;

  uint64_t expected = 0;
  unsigned char payload[MAX_FRAME_PAYLOAD];
  int rc = 0;
  for (;;) {
    uint8_t type = 0;
    uint32_t stream_id = 0;
    uint64_t offset = 0;
    uint32_t payload_len = 0;
    if (read_spio_header_blocking(client->fd, &type, &stream_id, &offset, &payload_len) != 0) {
      rc = -1;
      break;
    }
    if (payload_len > 0 && read_exact(client->fd, payload, payload_len) != 0) {
      rc = -1;
      break;
    }
    if (type == SPIO_DATA) {
      if (stream_id != SPIO_STDIN_STREAM || offset != expected) {
        rc = -1;
        break;
      }
      if (payload_len > 0 && write_all(fd, payload, payload_len) != 0) {
        rc = -1;
        break;
      }
      expected += payload_len;
      continue;
    }
    if (type == SPIO_CLOSE && stream_id == SPIO_STDIN_STREAM && offset == expected && payload_len == 0) {
      break;
    }
    rc = -1;
    break;
  }

  if (close(fd) != 0) rc = -1;
  if (rc != 0) unlink(archive_path);
  return rc;
}

static int read_copy_record(int fd, struct copy_record *record) {
  unsigned char header[COPY_ARCHIVE_HEADER_LEN];
  if (read_exact(fd, header, sizeof(header)) != 0) return -1;
  record->kind = header[0];
  record->path_len = read_le16(header + 1);
  uint32_t raw_mode = read_le32(header + 3);
  record->mode = raw_mode;
  record->size = read_le64(header + 7);
  if (header[15] != 0 || record->path_len > MAX_COPY_PATH_LEN || (raw_mode & ~0777U) != 0) return -1;
  if (record->path_len > 0 && read_exact(fd, record->path, record->path_len) != 0) return -1;
  record->path[record->path_len] = '\0';

  if (record->kind == COPY_KIND_END) {
    return record->path_len == 0 && record->mode == 0 && record->size == 0 ? 0 : -1;
  }
  if (record->kind != COPY_KIND_FILE && record->kind != COPY_KIND_DIR) return -1;
  if (record->kind == COPY_KIND_DIR && record->size != 0) return -1;
  return validate_copy_archive_path(record->path, record->path_len, 1);
}

static int expect_archive_eof(int fd) {
  unsigned char byte;
  for (;;) {
    ssize_t n = read(fd, &byte, 1);
    if (n == 0) return 0;
    if (n > 0) return -1;
    if (errno == EINTR) continue;
    return -1;
  }
}

static int copy_archive_file_to_fd(int archive_fd, int out_fd, uint64_t size) {
  unsigned char buf[MAX_FRAME_PAYLOAD];
  uint64_t remaining = size;
  while (remaining > 0) {
    size_t take = remaining > sizeof(buf) ? sizeof(buf) : (size_t)remaining;
    if (read_exact(archive_fd, buf, take) != 0) return -1;
    if (write_all(out_fd, buf, take) != 0) return -1;
    remaining -= take;
  }
  return 0;
}

static int create_copy_archive_file(int archive_fd, const char *path, mode_t mode, uint64_t size) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return -1;
  int rc = copy_archive_file_to_fd(archive_fd, fd, size);
  if (rc == 0 && fchmod(fd, mode & 0777) != 0) rc = -1;
  if (close(fd) != 0) rc = -1;
  if (rc != 0) unlink(path);
  return rc;
}

static int create_copy_archive_dir(const char *path, mode_t mode) {
  return mkdir(path, (mode & 0777) | 0700);
}

static int extract_copy_archive(const char *archive_path, const char *target_path, int *root_kind) {
  int fd = open(archive_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return -1;

  unsigned char magic[sizeof(copy_archive_magic)];
  int rc = 0;
  if (read_exact(fd, magic, sizeof(magic)) != 0 || memcmp(magic, copy_archive_magic, sizeof(magic)) != 0) rc = -1;

  struct copy_record record;
  if (rc == 0 && read_copy_record(fd, &record) != 0) rc = -1;
  if (rc == 0 && record.path_len != 0) rc = -1;
  if (rc == 0) {
    *root_kind = record.kind;
    if (record.kind == COPY_KIND_FILE) {
      if (create_copy_archive_file(fd, target_path, (mode_t)record.mode, record.size) != 0) rc = -1;
      if (rc == 0 && read_copy_record(fd, &record) != 0) rc = -1;
      if (rc == 0 && record.kind != COPY_KIND_END) rc = -1;
      if (rc == 0 && expect_archive_eof(fd) != 0) rc = -1;
    } else if (record.kind == COPY_KIND_DIR) {
      if (create_copy_archive_dir(target_path, (mode_t)record.mode) != 0) rc = -1;
      while (rc == 0) {
        if (read_copy_record(fd, &record) != 0) {
          rc = -1;
          break;
        }
        if (record.kind == COPY_KIND_END) break;
        if (record.path_len == 0) {
          rc = -1;
          break;
        }
        char child[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
        if (build_copy_archive_target(child, sizeof(child), target_path, record.path) != 0) {
          rc = -1;
          break;
        }
        if (record.kind == COPY_KIND_FILE) {
          if (create_copy_archive_file(fd, child, (mode_t)record.mode, record.size) != 0) rc = -1;
        } else if (record.kind == COPY_KIND_DIR) {
          if (create_copy_archive_dir(child, (mode_t)record.mode) != 0) rc = -1;
        } else {
          rc = -1;
        }
      }
      if (rc == 0 && expect_archive_eof(fd) != 0) rc = -1;
    } else {
      rc = -1;
    }
  }

  if (close(fd) != 0) rc = -1;
  return rc;
}

static int send_copy_stdout(struct client *client, const unsigned char *buf, size_t len) {
  if (len == 0) return 0;
  if (send_spio_data(client->fd, SPIO_STDOUT_STREAM, client->stdout_offset, buf, len) != 0) return -1;
  client->stdout_offset += len;
  return 0;
}

static int send_copy_record(struct client *client, int kind, const char *rel, mode_t mode, uint64_t size) {
  size_t rel_len = strlen(rel);
  if (rel_len > MAX_COPY_PATH_LEN || (kind != COPY_KIND_END && validate_copy_archive_path(rel, rel_len, 1) != 0)) return -1;
  unsigned char header[COPY_ARCHIVE_HEADER_LEN];
  header[0] = (unsigned char)kind;
  write_le16(header + 1, (uint16_t)rel_len);
  write_le32(header + 3, (uint32_t)(mode & 0777));
  write_le64(header + 7, size);
  header[15] = 0;
  if (send_copy_stdout(client, header, sizeof(header)) != 0) return -1;
  if (rel_len > 0 && send_copy_stdout(client, (const unsigned char *)rel, rel_len) != 0) return -1;
  return 0;
}

static int emit_copy_entry(struct client *client, const char *path, const char *rel) {
  struct stat st;
  if (lstat(path, &st) != 0) return -1;

  if (S_ISREG(st.st_mode)) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat opened;
    if (fstat(fd, &opened) != 0 || !S_ISREG(opened.st_mode)) {
      close(fd);
      return -1;
    }
    if (send_copy_record(client, COPY_KIND_FILE, rel, opened.st_mode, (uint64_t)opened.st_size) != 0) {
      close(fd);
      return -1;
    }
    unsigned char buf[MAX_FRAME_PAYLOAD];
    int rc = 0;
    for (;;) {
      ssize_t n = read(fd, buf, sizeof(buf));
      if (n > 0) {
        if (send_copy_stdout(client, buf, (size_t)n) != 0) {
          rc = -1;
          break;
        }
        continue;
      }
      if (n == 0) break;
      if (errno == EINTR) continue;
      rc = -1;
      break;
    }
    if (close(fd) != 0) rc = -1;
    return rc;
  }

  if (!S_ISDIR(st.st_mode)) return -1;
  if (send_copy_record(client, COPY_KIND_DIR, rel, st.st_mode, 0) != 0) return -1;

  int dir_fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (dir_fd < 0) return -1;
  DIR *dir = fdopendir(dir_fd);
  if (dir == NULL) {
    close(dir_fd);
    return -1;
  }
  int rc = 0;
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    char child_path[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
    char child_rel[MAX_COPY_PATH_LEN + 1];
    int path_n = snprintf(child_path, sizeof(child_path), "%s/%s", path, entry->d_name);
    int rel_n = rel[0] == '\0'
        ? snprintf(child_rel, sizeof(child_rel), "%s", entry->d_name)
        : snprintf(child_rel, sizeof(child_rel), "%s/%s", rel, entry->d_name);
    if (path_n <= 0 || (size_t)path_n >= sizeof(child_path) ||
        rel_n <= 0 || (size_t)rel_n >= sizeof(child_rel) ||
        validate_copy_archive_path(child_rel, strlen(child_rel), 0) != 0 ||
        emit_copy_entry(client, child_path, child_rel) != 0) {
      rc = -1;
      break;
    }
  }
  if (closedir(dir) != 0) rc = -1;
  return rc;
}

static int copy_in_file(struct client *client, const char *root, const char *guest_path) {
  if (validate_copy_path(guest_path) != 0) return send_client_error_exit(client, 2, "spore copy-in: invalid guest path\n");

  char path[MAX_COPY_FULL_PATH_LEN];
  char tmp_dir[MAX_COPY_FULL_PATH_LEN + 96];
  char tmp[MAX_COPY_FULL_PATH_LEN + 112];
  if (build_copy_path(path, sizeof(path), root, guest_path) != 0) {
    return send_client_error_exit(client, 2, "spore copy-in: guest path is too long\n");
  }
  if (reserve_copy_tmp_dir(tmp_dir, sizeof(tmp_dir), path) != 0) {
    return send_client_error_exit(client, 1, "spore copy-in: cannot create guest transfer temp\n");
  }
  int tmp_n = snprintf(tmp, sizeof(tmp), "%s/payload", tmp_dir);
  if (tmp_n <= 0 || (size_t)tmp_n >= sizeof(tmp)) {
    remove_tree(tmp_dir);
    return send_client_error_exit(client, 2, "spore copy-in: guest path is too long\n");
  }

  char archive_tmp[MAX_COPY_FULL_PATH_LEN + 112];
  int archive_n = snprintf(archive_tmp, sizeof(archive_tmp), "%s/archive", tmp_dir);
  if (archive_n <= 0 || (size_t)archive_n >= sizeof(archive_tmp)) {
    remove_tree(tmp_dir);
    return send_client_error_exit(client, 1, "spore copy-in: cannot create guest transfer archive\n");
  }

  if (receive_copy_archive_from_spio(client, archive_tmp) != 0) {
    remove_tree(tmp_dir);
    return send_client_error_exit(client, 1, "spore copy-in: transfer failed\n");
  }

  int root_kind = 0;
  if (extract_copy_archive(archive_tmp, tmp, &root_kind) != 0) {
    remove_tree(tmp_dir);
    return send_client_error_exit(client, 1, "spore copy-in: cannot write guest path\n");
  }
  unlink(archive_tmp);

  int publish_rc = root_kind == COPY_KIND_FILE ? link(tmp, path) : rename_noreplace(tmp, path);
  if (publish_rc != 0) {
    int exists = errno == EEXIST;
    remove_tree(tmp_dir);
    if (exists) return send_client_error_exit(client, 1, "spore copy-in: guest path already exists\n");
    return send_client_error_exit(client, 1, "spore copy-in: cannot publish guest path\n");
  }
  remove_tree(tmp_dir);
  return send_client_exit(client, 0);
}

static int copy_out_file(struct client *client, const char *root, const char *guest_path) {
  if (validate_copy_path(guest_path) != 0) return send_client_error_exit(client, 2, "spore copy-out: invalid guest path\n");

  char path[MAX_COPY_FULL_PATH_LEN];
  if (build_copy_path(path, sizeof(path), root, guest_path) != 0) {
    return send_client_error_exit(client, 2, "spore copy-out: guest path is too long\n");
  }

  if (send_copy_stdout(client, copy_archive_magic, sizeof(copy_archive_magic)) != 0 ||
      emit_copy_entry(client, path, "") != 0 ||
      send_copy_record(client, COPY_KIND_END, "", 0, 0) != 0) {
    return send_client_error_exit(client, 1, "spore copy-out: cannot read guest path\n");
  }
  return send_client_exit(client, 0);
}

static void pump_session_file(struct session *session, struct client *client, int is_stdout) {
  int fd = is_stdout ? session->stdout_fd : session->stderr_fd;
  if (fd < 0) return;
  unsigned char buf[MAX_FRAME_PAYLOAD];
  const char *name = is_stdout ? "stdout" : "stderr";
  uint64_t *offset = is_stdout ? &session->stdout_offset : &session->stderr_offset;
  uint64_t *client_offset = is_stdout ? &client->stdout_offset : &client->stderr_offset;
  for (;;) {
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n > 0) {
      uint64_t frame_offset = *offset;
      mirror_console(is_stdout, buf, (size_t)n);
      *offset += (uint64_t)n;
      if (client->fd >= 0) (void)send_client_output(session, client, name, client_offset, frame_offset, buf, (size_t)n);
      continue;
    }
    if (n == 0) return;
    if (errno == EINTR) continue;
    return;
  }
}

static void close_file_stdio(struct session *session) {
  if (session->stdout_fd >= 0) {
    close(session->stdout_fd);
    session->stdout_fd = -1;
  }
  if (session->stderr_fd >= 0) {
    close(session->stderr_fd);
    session->stderr_fd = -1;
  }
  session->stdout_open = 0;
  session->stderr_open = 0;
  unlink(FILE_STDOUT_PATH);
  unlink(FILE_STDERR_PATH);
}

static int apply_terminal_size(int fd, uint16_t rows, uint16_t cols) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = rows;
  ws.ws_col = cols;
  return ioctl(fd, TIOCSWINSZ, &ws);
}

static int open_session_pty(int *master_out, int *slave_out, uint16_t rows, uint16_t cols) {
  int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (master < 0) return -1;
  if (grantpt(master) != 0 || unlockpt(master) != 0) {
    close(master);
    return -1;
  }
  char *slave_path = ptsname(master);
  if (slave_path == NULL) {
    close(master);
    return -1;
  }
  int slave = open(slave_path, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (slave < 0) {
    close(master);
    return -1;
  }
  if (set_nonblock(master) != 0) {
    close(slave);
    close(master);
    return -1;
  }
  (void)apply_terminal_size(slave, rows, cols);
  *master_out = master;
  *slave_out = slave;
  return 0;
}

static int exec_failure_code(int err) {
  return err == ENOENT || err == ENOTDIR ? 127 : 126;
}

static void execve_or_report(char *const argv[], char *const envp[], int use_rootfs, int failure_fd) {
  char *const empty_env[] = { NULL };
  execve(argv[0], argv, envp[0] != NULL ? envp : empty_env);
  int err = errno;
  if ((err == ENOENT || err == ENOTDIR) && strchr(argv[0], '/') == NULL) {
    dprintf(STDERR_FILENO, "spore run: exact argv command \"%s\" was not found.\nExact argv mode does not run through /bin/sh or PATH lookup. Use shell command form or pass an absolute guest path.\n", argv[0]);
  } else if (!use_rootfs && (err == ENOENT || err == ENOTDIR)) {
    dprintf(STDERR_FILENO, "spore run: initrd cannot execute %s: not found; use --image, --rootfs, or provide an initrd containing the command\n", argv[0]);
  } else {
    dprintf(STDERR_FILENO, "spore run: exec %s failed: %s\n", argv[0], strerror(err));
  }
  if (failure_fd >= 0) (void)write_all(failure_fd, "!", 1);
  _exit(exec_failure_code(err));
}

static void pin_to_current_cpu(pid_t pid);
static int start_session(struct session *session, const char *session_id, char *const argv[], char *const envp[], const char *working_dir, int use_rootfs, int file_stdio, int memory_pressure, int stdin_enabled, int tty, uint16_t terminal_rows, uint16_t terminal_cols) {
  t_command_start = now_ms();
  int stdin_pipe[2] = { -1, -1 };
  int stdout_pipe[2] = { -1, -1 };
  int stderr_pipe[2] = { -1, -1 };
  int pty_master = -1;
  int pty_slave = -1;
  int start_pipe[2] = { -1, -1 };
  int ready_pipe[2] = { -1, -1 };
  if (tty) {
    if (open_session_pty(&pty_master, &pty_slave, terminal_rows, terminal_cols) != 0) {
      t_command_exit = now_ms();
      return 127;
    }
  } else if (file_stdio) {
    stdout_pipe[1] = open(FILE_STDOUT_PATH, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    stderr_pipe[1] = open(FILE_STDERR_PATH, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    stdout_pipe[0] = open(FILE_STDOUT_PATH, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    stderr_pipe[0] = open(FILE_STDERR_PATH, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (stdout_pipe[0] < 0 || stderr_pipe[0] < 0 || stdout_pipe[1] < 0 || stderr_pipe[1] < 0) {
      if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
      if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
      if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
      if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
      t_command_exit = now_ms();
      return 127;
    }
  } else {
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
  }
  if (stdin_enabled) {
    if (pipe2(stdin_pipe, O_CLOEXEC) != 0) {
      if (pty_master >= 0) close(pty_master);
      if (pty_slave >= 0) close(pty_slave);
      if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
      if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
      if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
      if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
      t_command_exit = now_ms();
      return 127;
    }
    if (set_nonblock(stdin_pipe[1]) != 0) {
      close(stdin_pipe[0]);
      close(stdin_pipe[1]);
      if (pty_master >= 0) close(pty_master);
      if (pty_slave >= 0) close(pty_slave);
      if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
      if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
      if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
      if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
      t_command_exit = now_ms();
      return 127;
    }
  }
  if (pipe2(start_pipe, O_CLOEXEC) != 0) {
    if (stdin_pipe[0] >= 0) close(stdin_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (pty_slave >= 0) close(pty_slave);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
    t_command_exit = now_ms();
    return 127;
  }
  if (pipe2(ready_pipe, O_CLOEXEC) != 0) {
    close(start_pipe[0]);
    close(start_pipe[1]);
    if (stdin_pipe[0] >= 0) close(stdin_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (pty_slave >= 0) close(pty_slave);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
    t_command_exit = now_ms();
    return 127;
  }

  pid_t pid = fork();
  if (pid == 0) {
    close(start_pipe[1]);
    close(ready_pipe[0]);
    char start_byte = 0;
    while (read(start_pipe[0], &start_byte, 1) < 0 && errno == EINTR) {
    }
    if (start_byte != 1) _exit(127);
    if (write_all(ready_pipe[1], "\1", 1) != 0) _exit(127);
    close(ready_pipe[1]);
    close(start_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (tty) {
      if (setsid() < 0) _exit(127);
      (void)ioctl(pty_slave, TIOCSCTTY, 0);
      if (dup2(pty_slave, STDIN_FILENO) < 0) _exit(127);
      if (dup2(pty_slave, STDOUT_FILENO) < 0) _exit(127);
      if (dup2(pty_slave, STDERR_FILENO) < 0) _exit(127);
      close(pty_slave);
    } else if (stdin_enabled) {
      if (dup2(stdin_pipe[0], STDIN_FILENO) < 0) _exit(127);
      close(stdin_pipe[0]);
    } else {
      int null_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
      if (null_fd < 0) _exit(127);
      if (dup2(null_fd, STDIN_FILENO) < 0) _exit(127);
      close(null_fd);
    }
    if (!tty) {
      if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0) _exit(127);
      if (dup2(stderr_pipe[1], STDERR_FILENO) < 0) _exit(127);
      close(stdout_pipe[1]);
      close(stderr_pipe[1]);
    }
    if (use_rootfs) {
      if (chroot("/mnt/rootfs") != 0) _exit(126);
    }
    const char *cwd = working_dir[0] != '\0' ? working_dir : "/";
    if (chdir(cwd) != 0) _exit(126);
    execve_or_report(argv, envp, use_rootfs, -1);
  }
  if (stdin_pipe[0] >= 0) close(stdin_pipe[0]);
  if (pty_slave >= 0) close(pty_slave);
  if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
  if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
  close(start_pipe[0]);
  close(ready_pipe[1]);
  if (pid < 0) {
    close(start_pipe[1]);
    close(ready_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    t_command_exit = now_ms();
    return 127;
  }
  /*
   * Completed-session resumes use file-backed stdio after restoring an already
   * booted guest. Keep that start-gate handoff on the agent's current CPU so a
   * restored multi-vCPU guest cannot strand the new child behind a lost wakeup.
   */
  if (file_stdio) pin_to_current_cpu(pid);

  memset(session, 0, sizeof(*session));
  session->memory_pressure_fd = -1;
  if ((memory_pressure && setup_memory_pressure(session, pid) != 0) || write_all(start_pipe[1], "\1", 1) != 0) {
    close(start_pipe[1]);
    close(ready_pipe[0]);
    (void)kill(pid, SIGKILL);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    close_memory_pressure(session);
    t_command_exit = now_ms();
    return 127;
  }
  close(start_pipe[1]);
  char ready_byte = 0;
  ssize_t ready_read = 0;
  do {
    ready_read = read(ready_pipe[0], &ready_byte, 1);
  } while (ready_read < 0 && errno == EINTR);
  close(ready_pipe[0]);
  if (ready_read != 1 || ready_byte != 1) {
    (void)kill(pid, SIGKILL);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    close_memory_pressure(session);
    t_command_exit = now_ms();
    return 127;
  }

  session->started = 1;
  snprintf(session->session_id, sizeof(session->session_id), "%s", session_id);
  session->pid = pid;
  session->stdin_fd = stdin_pipe[1];
  session->terminal_fd = pty_master;
  session->stdout_fd = tty ? pty_master : stdout_pipe[0];
  session->stderr_fd = stderr_pipe[0];
  session->stdin_open = stdin_pipe[1] >= 0;
  session->stdin_capable = stdin_enabled;
  session->tty = tty;
  session->stdout_open = tty ? pty_master >= 0 : 1;
  session->stderr_open = tty ? 0 : 1;
  session->file_stdio = file_stdio;
  return 0;
}

static void wait_child_blocking(pid_t pid) {
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }
}

static void pin_to_current_cpu(pid_t pid) {
  int cpu = sched_getcpu();
  if (cpu < 0 || cpu >= CPU_SETSIZE) return;
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  (void)sched_setaffinity(pid, sizeof(set), &set);
}

static void reap_detached_children(struct detached_children *children) {
  int i = 0;
  while (i < children->count) {
    int status = 0;
    pid_t rc = waitpid(children->pids[i], &status, WNOHANG);
    if (rc == children->pids[i] || (rc < 0 && errno == ECHILD)) {
      children->count--;
      if (i < children->count) {
        children->pids[i] = children->pids[children->count];
      }
      continue;
    }
    if (rc < 0 && errno == EINTR) continue;
    i++;
  }
}

static void close_fd_if_open(int *fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

static void close_pipe_if_open(int pipefd[2]) {
  close_fd_if_open(&pipefd[0]);
  close_fd_if_open(&pipefd[1]);
}

static void detached_child_fail(int status_fd) {
  if (status_fd >= 0) {
    (void)write_all(status_fd, "!", 1);
  }
  _exit(127);
}

static int start_detached(char *const argv[], char *const envp[], const char *working_dir, int use_rootfs, struct detached_children *children) {
  t_command_start = now_ms();
  reap_detached_children(children);
  if (children->count >= MAX_DETACHED_CHILDREN) {
    t_command_exit = now_ms();
    return 127;
  }

  int devnull = open("/dev/null", O_RDWR | O_CLOEXEC);
  int start_pipe[2] = { -1, -1 };
  int exec_pipe[2] = { -1, -1 };
  if (devnull < 0 || pipe2(start_pipe, O_CLOEXEC) != 0 || pipe2(exec_pipe, O_CLOEXEC) != 0) {
    close_fd_if_open(&devnull);
    close_pipe_if_open(start_pipe);
    close_pipe_if_open(exec_pipe);
    t_command_exit = now_ms();
    return 127;
  }

  pid_t pid = fork();
  if (pid == 0) {
    close(start_pipe[1]);
    close(exec_pipe[0]);
    char start_byte = 0;
    ssize_t sr = 0;
    do {
      sr = read(start_pipe[0], &start_byte, 1);
    } while (sr < 0 && errno == EINTR);
    if (sr != 1 || start_byte != 1) detached_child_fail(exec_pipe[1]);
    close(start_pipe[0]);
    if (dup2(devnull, STDIN_FILENO) < 0 ||
        dup2(devnull, STDOUT_FILENO) < 0 ||
        dup2(devnull, STDERR_FILENO) < 0) {
      detached_child_fail(exec_pipe[1]);
    }
    close(devnull);
    if (use_rootfs) {
      if (chroot("/mnt/rootfs") != 0) detached_child_fail(exec_pipe[1]);
    }
    const char *cwd = working_dir[0] != '\0' ? working_dir : "/";
    if (chdir(cwd) != 0) detached_child_fail(exec_pipe[1]);
    execve_or_report(argv, envp, use_rootfs, exec_pipe[1]);
  }

  close_fd_if_open(&devnull);
  close_fd_if_open(&start_pipe[0]);
  close_fd_if_open(&exec_pipe[1]);
  if (pid < 0) {
    close_pipe_if_open(start_pipe);
    close_pipe_if_open(exec_pipe);
    t_command_exit = now_ms();
    return 127;
  }

  if (write_all(start_pipe[1], "\1", 1) != 0) {
    close_pipe_if_open(start_pipe);
    close_pipe_if_open(exec_pipe);
    (void)kill(pid, SIGKILL);
    wait_child_blocking(pid);
    t_command_exit = now_ms();
    return 127;
  }
  close_fd_if_open(&start_pipe[1]);

  char failure = 0;
  ssize_t n = 0;
  do {
    n = read(exec_pipe[0], &failure, 1);
  } while (n < 0 && errno == EINTR);
  close_fd_if_open(&exec_pipe[0]);
  if (n != 0) {
    (void)kill(pid, SIGKILL);
    wait_child_blocking(pid);
    t_command_exit = now_ms();
    return 127;
  }

  children->pids[children->count++] = pid;
  t_command_exit = now_ms();
  return 0;
}

static int session_finished(const struct session *session) {
  return session->started && session->exited && !session->stdout_open && !session->stderr_open;
}

static void reset_session(struct session *session) {
  close_memory_pressure(session);
  if (session->stdout_fd >= 0) close(session->stdout_fd);
  if (session->stderr_fd >= 0) close(session->stderr_fd);
  if (session->stdin_fd >= 0) close(session->stdin_fd);
  if (session->terminal_fd >= 0 && session->terminal_fd != session->stdout_fd) close(session->terminal_fd);
  memset(session, 0, sizeof(*session));
  session->stdout_fd = -1;
  session->stderr_fd = -1;
  session->stdin_fd = -1;
  session->terminal_fd = -1;
  session->memory_pressure_fd = -1;
}

static int replay_available(const struct replay_buffer *replay, uint64_t offset, uint64_t end_offset) {
  return offset >= replay->base_offset && offset <= end_offset;
}

static int send_replay(struct session *session, struct client *client, const struct replay_buffer *replay, const char *name, uint64_t *client_offset, uint64_t end_offset) {
  if (!replay_available(replay, *client_offset, end_offset)) return -1;
  uint64_t replay_end = replay->base_offset + replay->len;
  if (*client_offset >= replay_end) return 0;
  size_t start = (size_t)(*client_offset - replay->base_offset);
  size_t len = replay->len - start;
  return send_client_output(session, client, name, client_offset, *client_offset, replay->data + start, len);
}

static int attach_client(struct session *session, struct client *client, uint64_t stdout_offset, uint64_t stderr_offset) {
  client->stdout_offset = stdout_offset;
  client->stderr_offset = stderr_offset;
  if (send_replay(session, client, &session->stdout_replay, "stdout", &client->stdout_offset, session->stdout_offset) != 0 ||
      send_replay(session, client, &session->stderr_replay, "stderr", &client->stderr_offset, session->stderr_offset) != 0) {
    (void)send_client_error_exit(client, 125, "spore run: requested replay offset is unavailable\n");
    close_client(client);
    return -1;
  }
  if (session->exited && !session->stdout_open && !session->stderr_open) {
    (void)send_client_exit(client, session->exit_code);
    close_client(client);
  }
  return 0;
}

static void pump_session_stream(struct session *session, struct client *client, int is_stdout) {
  int *fd = is_stdout ? &session->stdout_fd : &session->stderr_fd;
  int *open = is_stdout ? &session->stdout_open : &session->stderr_open;
  uint64_t *offset = is_stdout ? &session->stdout_offset : &session->stderr_offset;
  struct replay_buffer *replay = is_stdout ? &session->stdout_replay : &session->stderr_replay;
  const char *name = is_stdout ? "stdout" : "stderr";
  uint64_t *client_offset = is_stdout ? &client->stdout_offset : &client->stderr_offset;
  unsigned char buf[MAX_FRAME_PAYLOAD];

  if (!*open) return;
  for (;;) {
    ssize_t n = read(*fd, buf, sizeof(buf));
    if (n > 0) {
      uint64_t frame_offset = *offset;
      mirror_console(is_stdout, buf, (size_t)n);
      replay_append(replay, frame_offset, buf, (size_t)n);
      *offset += (uint64_t)n;
      if (client->fd >= 0) {
        (void)send_client_output(session, client, name, client_offset, frame_offset, buf, (size_t)n);
      }
      continue;
    }
    if (n == 0) {
      close(*fd);
      *fd = -1;
      *open = 0;
      return;
    }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    close(*fd);
    *fd = -1;
    *open = 0;
    return;
  }
}

static void pump_session_terminal(struct session *session, struct client *client) {
  if (!session->tty || !session->stdout_open || session->terminal_fd < 0) return;
  unsigned char buf[MAX_FRAME_PAYLOAD];
  for (;;) {
    ssize_t n = read(session->terminal_fd, buf, sizeof(buf));
    if (n > 0) {
      (void)write_all(STDOUT_FILENO, buf, (size_t)n);
      session->terminal_offset += (uint64_t)n;
      if (client->fd >= 0) {
        (void)send_client_terminal_output(session, client, client->terminal_offset, buf, (size_t)n);
      }
      continue;
    }
    if (n == 0) {
      close(session->terminal_fd);
      session->terminal_fd = -1;
      session->stdout_fd = -1;
      session->stdout_open = 0;
      return;
    }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    close(session->terminal_fd);
    session->terminal_fd = -1;
    session->stdout_fd = -1;
    session->stdout_open = 0;
    return;
  }
}

static void close_session_terminal_input(struct session *session) {
  if (!session->tty) return;
  if (session->terminal_pending_len == 0) {
    session->terminal_pending[0] = 4;
    session->terminal_pending_len = 1;
    session->terminal_pending_off = 0;
  } else {
    session->terminal_close_pending = 1;
  }
}

static void drain_session_terminal(struct session *session) {
  while (session->tty && session->terminal_fd >= 0 && session->terminal_pending_off < session->terminal_pending_len) {
    size_t remaining = session->terminal_pending_len - session->terminal_pending_off;
    ssize_t n = write(session->terminal_fd, session->terminal_pending + session->terminal_pending_off, remaining);
    if (n > 0) {
      session->terminal_pending_off += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    session->terminal_pending_len = 0;
    session->terminal_pending_off = 0;
    session->terminal_close_pending = 0;
    return;
  }
  if (session->terminal_pending_off >= session->terminal_pending_len) {
    session->terminal_pending_off = 0;
    session->terminal_pending_len = 0;
    if (session->terminal_close_pending) {
      session->terminal_close_pending = 0;
      close_session_terminal_input(session);
    }
  }
}

static void close_session_stdin(struct session *session) {
  if (session->stdin_fd >= 0) {
    close(session->stdin_fd);
    session->stdin_fd = -1;
  }
  session->stdin_open = 0;
  session->stdin_pending_len = 0;
  session->stdin_pending_off = 0;
  session->stdin_close_pending = 0;
}

static void drain_session_stdin(struct session *session) {
  while (session->stdin_open && session->stdin_pending_off < session->stdin_pending_len) {
    size_t remaining = session->stdin_pending_len - session->stdin_pending_off;
    ssize_t n = write(session->stdin_fd, session->stdin_pending + session->stdin_pending_off, remaining);
    if (n > 0) {
      session->stdin_pending_off += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    close_session_stdin(session);
    return;
  }
  if (session->stdin_pending_off >= session->stdin_pending_len) {
    session->stdin_pending_off = 0;
    session->stdin_pending_len = 0;
    if (session->stdin_close_pending) close_session_stdin(session);
  }
}

static int parse_spio_header(struct client *client) {
  if (memcmp(client->v1_header, SPIO_MAGIC, 4) != 0) return -1;
  if (client->v1_header[4] != SPIO_VERSION) return -1;
  client->v1_type = client->v1_header[5];
  uint16_t flags = read_le16(client->v1_header + 6);
  if (flags != 0) return -1;
  client->v1_stream_id = read_le32(client->v1_header + 8);
  client->v1_offset = read_le64(client->v1_header + 12);
  client->v1_payload_len = read_le32(client->v1_header + 20);
  if (client->v1_payload_len > MAX_FRAME_PAYLOAD) return -1;
  client->v1_payload_read = 0;
  return 0;
}

static int handle_spio_frame(struct session *session, struct client *client) {
  if (client->v1_type == SPIO_DATA) {
    if (client->v1_stream_id == SPIO_TERMINAL_STREAM) {
      if (!session->tty || session->terminal_fd < 0) return -1;
      if (!client->terminal_input_owner) return -1;
      if (client->v1_offset != client->terminal_input_offset) return -1;
      if (session->terminal_pending_len != 0) return -1;
      memcpy(session->terminal_pending, client->v1_payload, client->v1_payload_len);
      session->terminal_pending_len = client->v1_payload_len;
      session->terminal_pending_off = 0;
      client->terminal_input_offset += client->v1_payload_len;
      session->terminal_input_offset = client->terminal_input_offset;
      drain_session_terminal(session);
      return 0;
    }
    if (client->v1_stream_id != SPIO_STDIN_STREAM) return -1;
    if (!client->stdin_input_owner) return -1;
    if (!session->stdin_open) return -1;
    if (client->v1_offset != client->stdin_offset) return -1;
    if (session->stdin_pending_len != 0) return -1;
    memcpy(session->stdin_pending, client->v1_payload, client->v1_payload_len);
    session->stdin_pending_len = client->v1_payload_len;
    session->stdin_pending_off = 0;
    client->stdin_offset += client->v1_payload_len;
    session->stdin_offset = client->stdin_offset;
    drain_session_stdin(session);
    return 0;
  }
  if (client->v1_type == SPIO_CLOSE) {
    if (client->v1_stream_id == SPIO_TERMINAL_STREAM) {
      if (!session->tty || client->v1_payload_len != 0) return -1;
      if (!client->terminal_input_owner) return -1;
      if (client->v1_offset != client->terminal_input_offset) return -1;
      close_session_terminal_input(session);
      return 0;
    }
    if (client->v1_stream_id != SPIO_STDIN_STREAM || client->v1_payload_len != 0) return -1;
    if (!client->stdin_input_owner) return -1;
    if (client->v1_offset != client->stdin_offset) return -1;
    if (session->stdin_pending_len == 0) {
      close_session_stdin(session);
    } else {
      session->stdin_close_pending = 1;
    }
    return 0;
  }
  if (client->v1_type == SPIO_RESIZE) {
    if (!session->tty || client->v1_stream_id != SPIO_TERMINAL_STREAM || client->v1_payload_len != 4) return -1;
    uint16_t rows = read_le16(client->v1_payload);
    uint16_t cols = read_le16(client->v1_payload + 2);
    if (rows == 0 || cols == 0) return -1;
    if (session->terminal_fd >= 0) (void)apply_terminal_size(session->terminal_fd, rows, cols);
    return 0;
  }
  return -1;
}

// The v1 client owning session input disconnected or violated the stream
// protocol, so its stdin/terminal ownership can never produce more input.
// Close the session's input pipes so the child observes EOF and can finish;
// otherwise the session blocks forever and later execs fail with "session
// already started".
static void close_client_input_lost(struct session *session, struct client *client) {
  if (session->started && !session->exited) {
    if (client->stdin_input_owner) close_session_stdin(session);
    if (client->terminal_input_owner) close_session_terminal_input(session);
  }
  close_client(client);
}

static void pump_client_v1(struct session *session, struct client *client) {
  if (client->fd < 0 || !client->protocol_v1) return;
  if (session->stdin_pending_len != 0 || session->terminal_pending_len != 0) return;

  for (;;) {
    if (client->v1_header_len < SPIO_HEADER_LEN) {
      ssize_t n = recv(client->fd, client->v1_header + client->v1_header_len, SPIO_HEADER_LEN - client->v1_header_len, MSG_DONTWAIT);
      if (n > 0) {
        client->v1_header_len += (size_t)n;
        if (client->v1_header_len < SPIO_HEADER_LEN) return;
        if (parse_spio_header(client) != 0) {
          close_client_input_lost(session, client);
          return;
        }
        if (client->v1_payload_len == 0) {
          if (handle_spio_frame(session, client) != 0) close_client_input_lost(session, client);
          client->v1_header_len = 0;
          return;
        }
      } else if (n == 0) {
        close_client_input_lost(session, client);
        return;
      } else {
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        close_client_input_lost(session, client);
        return;
      }
    }

    while (client->v1_payload_read < client->v1_payload_len) {
      ssize_t n = recv(client->fd, client->v1_payload + client->v1_payload_read, client->v1_payload_len - client->v1_payload_read, MSG_DONTWAIT);
      if (n > 0) {
        client->v1_payload_read += (size_t)n;
        continue;
      }
      if (n == 0) {
        close_client_input_lost(session, client);
        return;
      }
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) return;
      close_client_input_lost(session, client);
      return;
    }

    if (handle_spio_frame(session, client) != 0) {
      close_client_input_lost(session, client);
      return;
    }
    client->v1_header_len = 0;
    client->v1_payload_len = 0;
    client->v1_payload_read = 0;
    if (session->stdin_pending_len != 0 || session->terminal_pending_len != 0) return;
  }
}

static void poll_session_exit(struct session *session, struct client *client) {
  if (!session->started || session->exited) return;

  int status = 0;
  int wr = wait_child(session->pid, &status);
  if (wr == 0) return;
  t_command_exit = now_ms();
  if (wr < 0) {
    session->exit_code = 127;
  } else if (WIFEXITED(status)) {
    session->exit_code = WEXITSTATUS(status);
  } else if (WIFSIGNALED(status)) {
    session->exit_code = 128 + WTERMSIG(status);
  } else {
    session->exit_code = 1;
  }
  session->exited = 1;
  close_session_stdin(session);

  /*
   * Do not wait indefinitely for pipe EOF after the direct command exits;
   * inherited fds from daemonized children must not block the run result.
   */
  if (session->file_stdio) {
    pump_session_file(session, client, 1);
    pump_session_file(session, client, 0);
    close_file_stdio(session);
  } else if (session->tty) {
    pump_session_terminal(session, client);
    if (session->terminal_fd >= 0) {
      close(session->terminal_fd);
      session->terminal_fd = -1;
      session->stdout_fd = -1;
      session->stdout_open = 0;
    }
  } else {
    pump_session_stream(session, client, 1);
    pump_session_stream(session, client, 0);
    if (session->stdout_open) {
      close(session->stdout_fd);
      session->stdout_fd = -1;
      session->stdout_open = 0;
    }
    if (session->stderr_open) {
      close(session->stderr_fd);
      session->stderr_fd = -1;
      session->stderr_open = 0;
    }
  }
  close_memory_pressure(session);
}

static void maybe_send_session_exit(struct session *session, struct client *client) {
  if (client->fd < 0) return;
  if (!session->started || !session->exited || session->stdout_open || session->stderr_open) return;
  int rc;
  if (client->protocol_v1) {
    rc = send_spio_timing_frame(client->fd);
    if (rc == 0) rc = send_spio_exit(client->fd, session->exit_code);
  } else {
    rc = send_exit_frame(client->fd, session->exit_code);
  }
  if (rc != 0) {
    close_client(client);
    return;
  }
  close_client(client);
}

static void maybe_send_memory_pressure(struct session *session, struct client *client) {
  if (client->fd < 0 || !session->started || session->exited || session->memory_pressure_fd < 0) return;
  drain_memory_pressure_events(session);
  int rc = client->protocol_v1 ? send_spio_event(client->fd, "memory-pressure") : send_memory_pressure_frame(client->fd);
  if (rc != 0) {
    close_client(client);
    return;
  }
  if (rearm_memory_pressure_limit(session) != 0) {
    dprintf(2, "memory pressure setup failed: rearm high limit errno=%d\n", errno);
    close(session->memory_pressure_fd);
    session->memory_pressure_fd = -1;
  }
}

static void run_transient_exec(struct client *client, const struct run_request *request, int use_rootfs) {
  if (request->protocol_v1 || request->stdin_enabled || request->tty || request->interactive || request->memory_pressure) {
    (void)send_client_error_exit(client, 2, "spore run: session already started\n");
    close_client(client);
    return;
  }

  struct session transient;
  int rc = start_session(&transient, request->session_id, request->argv, request->envp, request->working_dir, use_rootfs, 0, 0, 0, 0, request->terminal_rows, request->terminal_cols);
  if (rc != 0) {
    (void)send_client_error_exit(client, rc, "spore run: exec setup failed\n");
    close_client(client);
    return;
  }

  while (client->fd >= 0 && (!transient.exited || transient.stdout_open || transient.stderr_open)) {
    struct pollfd fds[3];
    int roles[3];
    nfds_t nfds = 0;
    if (transient.stdout_open) {
      fds[nfds].fd = transient.stdout_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 1;
    }
    if (transient.stderr_open) {
      fds[nfds].fd = transient.stderr_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 2;
    }
    fds[nfds].fd = client->fd;
    fds[nfds].events = POLLHUP | POLLERR;
    fds[nfds].revents = 0;
    roles[nfds++] = 3;

    int pr = poll(fds, nfds, 100);
    if (pr > 0) {
      for (nfds_t i = 0; i < nfds; i++) {
        if (fds[i].revents == 0) continue;
        if (roles[i] == 1) {
          pump_session_stream(&transient, client, 1);
        } else if (roles[i] == 2) {
          pump_session_stream(&transient, client, 0);
        } else if (roles[i] == 3 && (fds[i].revents & (POLLHUP | POLLERR))) {
          close_client(client);
        }
      }
    }
    poll_session_exit(&transient, client);
    maybe_send_session_exit(&transient, client);
  }

  if (client->fd < 0 && transient.started && !transient.exited) {
    (void)kill(transient.pid, SIGKILL);
    wait_child_blocking(transient.pid);
  }
  reset_session(&transient);
}

static const char *apply_request_generation(struct generation_monitor *generation, const char *root, const char *params) {
  if (write_generation_files(root, params) != 0) return "spore run: generation helper write failed\n";
  if (apply_generation_identity(params) != 0) return "spore run: generation helper apply failed\n";
  ack_applied_generation(generation, params);
  return NULL;
}

static void accept_request(int listener, struct session *session, struct client *client, struct detached_children *detached, struct generation_monitor *generation, const char *generation_root, int use_rootfs, int rootfs_ready, const char *rootfs_error, int network_requested, int network_ready, const char *network_error) {
  int conn = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
  if (conn < 0) {
    if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
      dprintf(2, "accept failed: errno=%d\n", errno);
    }
    return;
  }
  t_request_accept = now_ms();

  char req[MAX_REQUEST];
  if (read_line(conn, req, sizeof(req)) <= 0) {
    close(conn);
    return;
  }
  t_request_decode = now_ms();

  struct run_request request;
  if (parse_request(req, &request) != 0) {
    (void)send_error_exit(conn, 2, "spore run: bad request\n");
    close(conn);
    return;
  }

  close_client(client);
  client->fd = conn;
  client->protocol_v1 = request.protocol_v1;
  client->stdout_offset = 0;
  client->stderr_offset = 0;
  client->stdin_offset = 0;
  client->stdin_input_owner = request.protocol_v1 && request.stdin_enabled;
  client->terminal_input_owner = request.protocol_v1 && request.tty && (request.kind == REQUEST_START || request.interactive);

  if (request.kind == REQUEST_GENERATION) {
    if (use_rootfs && !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = generation_root_path(use_rootfs, rootfs_ready);
    const char *generation_error = apply_request_generation(generation, root, request.generation_params);
    if (generation_error != NULL) {
      (void)send_client_error_exit(client, 126, generation_error);
      close_client(client);
      return;
    }
    (void)send_exit_frame(client->fd, 0);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_COPY_IN || request.kind == REQUEST_COPY_OUT) {
    if (use_rootfs && !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = use_rootfs && rootfs_ready ? "/mnt/rootfs" : "";
    if (request.kind == REQUEST_COPY_IN) {
      (void)copy_in_file(client, root, request.copy_path);
    } else {
      (void)copy_out_file(client, root, request.copy_path);
    }
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_START) {
    if (use_rootfs && !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    if (network_requested && !network_ready) {
      (void)send_client_error_exit(client, 126, network_error[0] != '\0' ? network_error : "spore run: network unavailable\n");
      close_client(client);
      return;
    }
    if (request.generation_params[0] != '\0') {
      const char *root = generation_root_path(use_rootfs, rootfs_ready);
      const char *generation_error = apply_request_generation(generation, root, request.generation_params);
      if (generation_error != NULL) {
        (void)send_client_error_exit(client, 126, generation_error);
        close_client(client);
        return;
      }
    } else if (request.require_generation_ready && ensure_generation_ready(generation, generation_root) != 0) {
      (void)send_client_error_exit(client, 126, "spore run: generation metadata unavailable\n");
      close_client(client);
      return;
    }
    apply_resume_clock(request.resume_time_unix_ns);
    if (request.detached) {
      int rc = start_detached(request.argv, request.envp, request.working_dir, use_rootfs, detached);
      if (rc != 0) {
        (void)send_client_error_exit(client, rc, "spore run: exec setup failed\n");
        close_client(client);
        return;
      }
      (void)send_exit_frame(client->fd, 0);
      close_client(client);
      return;
    }
    int file_stdio = 0;
    if (session->started) {
      if (strcmp(request.session_id, session->session_id) == 0) {
        (void)attach_client(session, client, request.stdout_offset, request.stderr_offset);
        return;
      }
      if (!session_finished(session)) {
        run_transient_exec(client, &request, use_rootfs);
        return;
      }
      // ponytail: completed-base resumes lose pipe wakeups under ReleaseSafe; keep the file fallback resumed-only.
      file_stdio = request.tty ? 0 : 1;
      reset_session(session);
    }
    int rc = start_session(session, request.session_id, request.argv, request.envp, request.working_dir, use_rootfs, file_stdio, request.memory_pressure, request.stdin_enabled, request.tty, request.terminal_rows, request.terminal_cols);
    if (rc != 0) {
      (void)send_client_error_exit(client, rc, "spore run: exec setup failed\n");
      close_client(client);
      return;
    }
    client->stdout_offset = 0;
    client->stderr_offset = 0;
    return;
  }

  if (!session->started || strcmp(request.session_id, session->session_id) != 0) {
    (void)send_client_error_exit(client, 2, "spore run: no session\n");
    close_client(client);
    return;
  }

  if (request.generation_params[0] != '\0') {
    if (use_rootfs && !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = generation_root_path(use_rootfs, rootfs_ready);
    const char *generation_error = apply_request_generation(generation, root, request.generation_params);
    if (generation_error != NULL) {
      (void)send_client_error_exit(client, 126, generation_error);
      close_client(client);
      return;
    }
  }
  if (request.protocol_v1) {
    if (request.stdin_enabled) {
      if (!session->stdin_capable) {
        (void)send_client_error_exit(client, 2, "spore run: captured session has no interactive stdin\n");
        close_client(client);
        return;
      }
      if (!session->stdin_open) {
        (void)send_client_error_exit(client, 2, "spore run: captured session stdin is closed\n");
        close_client(client);
        return;
      }
      (void)attach_client(session, client, request.stdout_offset, request.stderr_offset);
      return;
    }
    if (request.tty) {
      if (!session->tty) {
        (void)send_client_error_exit(client, 2, "spore run: captured session has no terminal\n");
        close_client(client);
        return;
      }
      if (request.interactive && session->terminal_fd < 0) {
        (void)send_client_error_exit(client, 2, "spore run: captured session terminal is closed\n");
        close_client(client);
        return;
      }
      if (session->terminal_fd >= 0) {
        (void)apply_terminal_size(session->terminal_fd, request.terminal_rows, request.terminal_cols);
      }
      if (session->exited && !session->stdout_open) {
        (void)send_client_exit(client, session->exit_code);
        close_client(client);
      }
      return;
    }
  }
  (void)attach_client(session, client, request.stdout_offset, request.stderr_offset);
}

int main(void) {
  t_init_start = now_ms();
  mount_proc();
  mount_sysfs();
  mount_cgroup2_if_dir("/sys/fs/cgroup");
  prepare_dev();
  mkdir("/run", 0755);
  char cmdline[1024];
  read_cmdline(cmdline, sizeof(cmdline));
  int use_rootfs = cmdline_has_flag_in(cmdline, "spore_rootfs=1");
  int rootfs_writable = cmdline_has_flag_in(cmdline, "spore_rootfs_rw=1");
  int use_network = cmdline_has_flag_in(cmdline, "spore_net=1");
  int listener = listen_vsock(resolve_port_from_cmdline(cmdline));
  if (listener < 0) {
    dprintf(2, "listen vsock failed: errno=%d\n", errno);
    return 1;
  }
  (void)set_nonblock(listener);
  t_listen_ready = now_ms();

  int rootfs_ready = 1;
  char rootfs_error[128];
  rootfs_error[0] = '\0';
  if (use_rootfs && setup_rootfs(rootfs_writable, rootfs_error, sizeof(rootfs_error)) != 0) {
    rootfs_ready = 0;
    dprintf(2, "%s\n", rootfs_error);
    size_t len = strlen(rootfs_error);
    if (len + 1 < sizeof(rootfs_error)) {
      rootfs_error[len] = '\n';
      rootfs_error[len + 1] = '\0';
    }
  }
  int network_ready = 1;
  char network_error[160];
  network_error[0] = '\0';
  if (use_network && setup_network(use_rootfs, network_error, sizeof(network_error)) != 0) {
    network_ready = 0;
    dprintf(2, "%s\n", network_error);
    size_t len = strlen(network_error);
    if (len + 1 < sizeof(network_error)) {
      network_error[len] = '\n';
      network_error[len + 1] = '\0';
    }
  }
  if (setup_sigchld_wakeup() != 0) {
    dprintf(2, "sigchld wakeup setup failed: errno=%d\n", errno);
    return 1;
  }

  struct session session;
  memset(&session, 0, sizeof(session));
  session.stdin_fd = -1;
  session.terminal_fd = -1;
  session.stdout_fd = -1;
  session.stderr_fd = -1;
  session.memory_pressure_fd = -1;
  struct client client;
  memset(&client, 0, sizeof(client));
  client.fd = -1;
  struct detached_children detached;
  memset(&detached, 0, sizeof(detached));
  struct generation_monitor generation;
  memset(&generation, 0, sizeof(generation));
  generation.last_generation = UINT64_MAX;
  const char *generation_root = generation_root_path(use_rootfs, rootfs_ready);

  for (;;) {
    reap_detached_children(&detached);
    if (!use_rootfs || rootfs_ready) {
      (void)poll_generation(&generation, generation_root);
    }
    if (session.file_stdio && !session.exited) {
      pump_session_file(&session, &client, 1);
      pump_session_file(&session, &client, 0);
      poll_session_exit(&session, &client);
      maybe_send_session_exit(&session, &client);
    }

    struct pollfd fds[8];
    int roles[8];
    nfds_t nfds = 0;
    fds[nfds].fd = listener;
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    roles[nfds++] = 0;
    if (client.fd >= 0) {
      fds[nfds].fd = client.fd;
      fds[nfds].events = POLLHUP | POLLERR | (client.protocol_v1 ? POLLIN : 0);
      fds[nfds].revents = 0;
      roles[nfds++] = 1;
    }
    if (session.stdout_open && !session.file_stdio) {
      fds[nfds].fd = session.stdout_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      if (session.tty && session.terminal_pending_len != 0) fds[nfds].events |= POLLOUT;
      fds[nfds].revents = 0;
      roles[nfds++] = 2;
    }
    if (session.stderr_open && !session.file_stdio) {
      fds[nfds].fd = session.stderr_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 3;
    }
    fds[nfds].fd = sigchld_pipe[0];
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    roles[nfds++] = 4;
    if (session.memory_pressure_fd >= 0) {
      fds[nfds].fd = session.memory_pressure_fd;
      fds[nfds].events = POLLPRI | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 5;
    }
    if (session.stdin_open && session.stdin_pending_len != 0) {
      fds[nfds].fd = session.stdin_fd;
      fds[nfds].events = POLLOUT | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 6;
    }

    int poll_timeout_ms = session.file_stdio && session.started && !session.exited ? 10 : 100;
    int pr = poll(fds, nfds, poll_timeout_ms);
    if (pr < 0 && errno != EINTR) continue;
    if (pr > 0) {
      for (nfds_t i = 0; i < nfds; i++) {
        if (fds[i].revents == 0) continue;
        if (roles[i] == 0 && (fds[i].revents & POLLIN)) {
          accept_request(listener, &session, &client, &detached, &generation, generation_root, use_rootfs, rootfs_ready, rootfs_error, use_network, network_ready, network_error);
        } else if (roles[i] == 1) {
          if (fds[i].revents & POLLIN) {
            pump_client_v1(&session, &client);
          }
          if (fds[i].revents & (POLLHUP | POLLERR)) {
            close_client(&client);
          }
        } else if (roles[i] == 2) {
          if (session.tty) {
            if (fds[i].revents & POLLOUT) drain_session_terminal(&session);
            if (fds[i].revents & (POLLIN | POLLHUP | POLLERR)) pump_session_terminal(&session, &client);
          } else {
            pump_session_stream(&session, &client, 1);
          }
        } else if (roles[i] == 3) {
          pump_session_stream(&session, &client, 0);
        } else if (roles[i] == 4) {
          drain_sigchld_wakeup();
          reap_detached_children(&detached);
        } else if (roles[i] == 5 && (fds[i].revents & (POLLPRI | POLLERR))) {
          maybe_send_memory_pressure(&session, &client);
        } else if (roles[i] == 6) {
          drain_session_stdin(&session);
        }
      }
    }
    drain_session_stdin(&session);
    drain_session_terminal(&session);
    if (session.file_stdio && !session.exited) {
      pump_session_file(&session, &client, 1);
      pump_session_file(&session, &client, 0);
    }
    poll_session_exit(&session, &client);
    maybe_send_session_exit(&session, &client);
  }
}
