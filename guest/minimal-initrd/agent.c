#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <poll.h>
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

static int path_is_dir(const char *path);

struct replay_buffer {
  unsigned char data[REPLAY_CAP];
  uint64_t base_offset;
  size_t len;
};

struct session {
  int started;
  int exited;
  char session_id[64];
  pid_t pid;
  int stdout_fd;
  int stderr_fd;
  int stdout_open;
  int stderr_open;
  int file_stdio;
  int exit_code;
  uint64_t stdout_offset;
  uint64_t stderr_offset;
  struct replay_buffer stdout_replay;
  struct replay_buffer stderr_replay;
};

struct client {
  int fd;
  uint64_t stdout_offset;
  uint64_t stderr_offset;
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

static void apply_generation_identity(const char *params) {
  char hostname[128];
  if (parse_string_field(params, "hostname", hostname, sizeof(hostname)) > 0 && hostname[0] != '\0') {
    (void)sethostname(hostname, strlen(hostname));
  }
  uint64_t resume_time_unix_ns = 0;
  if (parse_u64_field(params, "resume_time_unix_ns", &resume_time_unix_ns) > 0) {
    apply_resume_clock(resume_time_unix_ns);
  }
}

static void poll_generation(struct generation_monitor *monitor, const char *root) {
  if (monitor->unavailable) return;
  if (monitor->base == NULL) {
    monitor->base = generation_map();
    if (monitor->base == NULL) {
      monitor->unavailable = 1;
      return;
    }
  }

  if (mmio_read32(monitor->base, REG_MAGIC) != GEN_MAGIC) return;
  uint32_t params_offset = mmio_read32(monitor->base, REG_PARAMS_OFFSET);
  uint32_t params_size = mmio_read32(monitor->base, REG_PARAMS_SIZE);
  if (params_offset >= GEN_WINDOW_SIZE || params_size > GEN_WINDOW_SIZE - params_offset) return;

  uint64_t generation = mmio_read64(monitor->base, REG_GENERATION);
  if (generation == monitor->last_generation) return;

  char params[GEN_PARAMS_MAX];
  size_t limit = params_size;
  if (limit >= sizeof(params)) limit = sizeof(params) - 1;
  size_t i = 0;
  for (; i < limit; i++) {
    params[i] = (char)*(monitor->base + params_offset + i);
    if (params[i] == '\0') break;
  }
  params[i] = '\0';
  if (params[0] == '\0') return;

  if (write_generation_files(root, params) == 0) {
    uint32_t irq_status = mmio_read32(monitor->base, REG_IRQ_STATUS);
    apply_generation_identity(params);
    monitor->last_generation = generation;
    if ((irq_status & GEN_IRQ_GENERATION_CHANGED) != 0) {
      mmio_write32(monitor->base, REG_IRQ_ACK, GEN_IRQ_GENERATION_CHANGED);
    }
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

static int send_timing_frame(int fd) {
  int64_t now = now_ms();
  char frame[128];
  int n = snprintf(frame, sizeof(frame),
                   "timing listen=%lld accept=%lld decode=%lld spawn=%lld exit=%lld now=%lld\n",
                   (long long)(t_listen_ready ? t_listen_ready - t_init_start : -1),
                   (long long)(t_request_accept ? t_request_accept - t_init_start : -1),
                   (long long)(t_request_decode ? t_request_decode - t_init_start : -1),
                   (long long)(t_command_start ? t_command_start - t_init_start : -1),
                   (long long)(t_command_exit ? t_command_exit - t_init_start : -1),
                   (long long)(now ? now - t_init_start : -1));
  if (n <= 0 || (size_t)n >= sizeof(frame)) return -1;
  return write_all(fd, frame, (size_t)n);
}

static int send_exit_frame(int fd, int exit_code) {
  char frame[32];
  int n = snprintf(frame, sizeof(frame), "exit %d\n", exit_code);
  if (n <= 0 || (size_t)n >= sizeof(frame)) return -1;
  (void)send_timing_frame(fd);
  return write_all(fd, frame, (size_t)n);
}

static void close_client(struct client *client) {
  if (client->fd >= 0) {
    close(client->fd);
    client->fd = -1;
  }
}

static int send_client_output(struct client *client, const char *name, uint64_t *client_offset, uint64_t offset, const unsigned char *buf, size_t len) {
  if (client->fd < 0) return -1;
  if (*client_offset != offset) return 0;
  if (send_stream_data(client->fd, name, offset, buf, len) != 0) {
    close_client(client);
    return -1;
  }
  *client_offset += len;
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
};

struct run_request {
  enum request_kind kind;
  char session_id[64];
  uint64_t stdout_offset;
  uint64_t stderr_offset;
  uint64_t resume_time_unix_ns;
  char generation_params[GEN_PARAMS_MAX];
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

static int parse_request(const char *req, struct run_request *out) {
  memset(out, 0, sizeof(*out));
  out->kind = REQUEST_START;

  char type[32];
  int type_rc = parse_string_field(req, "type", type, sizeof(type));
  if (type_rc < 0) return -1;
  if (type_rc > 0) {
    if (strcmp(type, "start") == 0) {
      out->kind = REQUEST_START;
    } else if (strcmp(type, "attach") == 0) {
      out->kind = REQUEST_ATTACH;
    } else if (strcmp(type, "generation") == 0) {
      out->kind = REQUEST_GENERATION;
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

  if (out->kind == REQUEST_GENERATION || out->kind == REQUEST_ATTACH) {
    int params_rc = parse_string_field(req, "params_json", out->generation_params, sizeof(out->generation_params));
    if (out->kind == REQUEST_GENERATION && params_rc <= 0) return -1;
    if (params_rc < 0) return -1;
  }
  if (out->kind == REQUEST_START) {
    if (parse_argv(req, out->arg_storage, out->argv) <= 0) return -1;
    if (parse_env(req, out->env_storage, out->envp) < 0) return -1;
    int working_dir_rc = parse_string_field(req, "working_dir", out->working_dir, sizeof(out->working_dir));
    if (working_dir_rc < 0) return -1;
    if (working_dir_rc == 0) out->working_dir[0] = '\0';
  }
  return 0;
}

static int send_error_exit(int fd, int code, const char *message) {
  (void)send_stream_data(fd, "stderr", 0, (const unsigned char *)message, strlen(message));
  return send_exit_frame(fd, code);
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
      if (client->fd >= 0) (void)send_client_output(client, name, client_offset, frame_offset, buf, (size_t)n);
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

static int start_session(struct session *session, const char *session_id, char *const argv[], char *const envp[], const char *working_dir, int use_rootfs, int file_stdio) {
  t_command_start = now_ms();
  int stdout_pipe[2];
  int stderr_pipe[2];
  if (file_stdio) {
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

  pid_t pid = fork();
  if (pid == 0) {
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0) _exit(127);
    if (dup2(stderr_pipe[1], STDERR_FILENO) < 0) _exit(127);
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    if (use_rootfs) {
      if (chroot("/mnt/rootfs") != 0) _exit(126);
    }
    const char *cwd = working_dir[0] != '\0' ? working_dir : "/";
    if (chdir(cwd) != 0) _exit(126);
    char *const empty_env[] = { NULL };
    execve(argv[0], argv, envp[0] != NULL ? envp : empty_env);
    _exit(127);
  }
  close(stdout_pipe[1]);
  close(stderr_pipe[1]);
  if (pid < 0) {
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    t_command_exit = now_ms();
    return 127;
  }

  memset(session, 0, sizeof(*session));
  session->started = 1;
  snprintf(session->session_id, sizeof(session->session_id), "%s", session_id);
  session->pid = pid;
  session->stdout_fd = stdout_pipe[0];
  session->stderr_fd = stderr_pipe[0];
  session->stdout_open = 1;
  session->stderr_open = 1;
  session->file_stdio = file_stdio;
  return 0;
}

static int session_finished(const struct session *session) {
  return session->started && session->exited && !session->stdout_open && !session->stderr_open;
}

static void reset_session(struct session *session) {
  if (session->stdout_fd >= 0) close(session->stdout_fd);
  if (session->stderr_fd >= 0) close(session->stderr_fd);
  memset(session, 0, sizeof(*session));
  session->stdout_fd = -1;
  session->stderr_fd = -1;
}

static int replay_available(const struct replay_buffer *replay, uint64_t offset, uint64_t end_offset) {
  return offset >= replay->base_offset && offset <= end_offset;
}

static int send_replay(struct client *client, const struct replay_buffer *replay, const char *name, uint64_t *client_offset, uint64_t end_offset) {
  if (!replay_available(replay, *client_offset, end_offset)) return -1;
  uint64_t replay_end = replay->base_offset + replay->len;
  if (*client_offset >= replay_end) return 0;
  size_t start = (size_t)(*client_offset - replay->base_offset);
  size_t len = replay->len - start;
  if (send_stream_data(client->fd, name, *client_offset, replay->data + start, len) != 0) return -1;
  *client_offset += len;
  return 0;
}

static int attach_client(struct session *session, struct client *client, uint64_t stdout_offset, uint64_t stderr_offset) {
  client->stdout_offset = stdout_offset;
  client->stderr_offset = stderr_offset;
  if (send_replay(client, &session->stdout_replay, "stdout", &client->stdout_offset, session->stdout_offset) != 0 ||
      send_replay(client, &session->stderr_replay, "stderr", &client->stderr_offset, session->stderr_offset) != 0) {
    (void)send_error_exit(client->fd, 125, "spore run: requested replay offset is unavailable\n");
    close_client(client);
    return -1;
  }
  if (session->exited && !session->stdout_open && !session->stderr_open) {
    (void)send_exit_frame(client->fd, session->exit_code);
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
        (void)send_client_output(client, name, client_offset, frame_offset, buf, (size_t)n);
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

  /*
   * Do not wait indefinitely for pipe EOF after the direct command exits;
   * inherited fds from daemonized children must not block the run result.
   */
  if (session->file_stdio) {
    pump_session_file(session, client, 1);
    pump_session_file(session, client, 0);
    close_file_stdio(session);
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
}

static void maybe_send_session_exit(struct session *session, struct client *client) {
  if (client->fd < 0) return;
  if (!session->started || !session->exited || session->stdout_open || session->stderr_open) return;
  if (send_exit_frame(client->fd, session->exit_code) != 0) {
    close_client(client);
    return;
  }
  close_client(client);
}

static void accept_request(int listener, struct session *session, struct client *client, int use_rootfs, int rootfs_ready, const char *rootfs_error, int network_requested, int network_ready, const char *network_error) {
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

  if (request.kind == REQUEST_GENERATION) {
    if (use_rootfs && !rootfs_ready) {
      (void)send_error_exit(client->fd, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = generation_root_path(use_rootfs, rootfs_ready);
    if (write_generation_files(root, request.generation_params) != 0) {
      (void)send_error_exit(client->fd, 126, "spore run: generation helper write failed\n");
      close_client(client);
      return;
    }
    apply_generation_identity(request.generation_params);
    (void)send_exit_frame(client->fd, 0);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_START) {
    int file_stdio = 0;
    if (session->started) {
      if (strcmp(request.session_id, session->session_id) == 0) {
        (void)attach_client(session, client, request.stdout_offset, request.stderr_offset);
        return;
      }
      if (!session_finished(session)) {
        (void)send_error_exit(client->fd, 2, "spore run: session already started\n");
        close_client(client);
        return;
      }
      // ponytail: completed-base resumes lose pipe wakeups under ReleaseSafe; keep the file fallback resumed-only.
      file_stdio = 1;
      reset_session(session);
    }
    if (use_rootfs && !rootfs_ready) {
      (void)send_error_exit(client->fd, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    if (network_requested && !network_ready) {
      (void)send_error_exit(client->fd, 126, network_error[0] != '\0' ? network_error : "spore run: network unavailable\n");
      close_client(client);
      return;
    }
    apply_resume_clock(request.resume_time_unix_ns);
    int rc = start_session(session, request.session_id, request.argv, request.envp, request.working_dir, use_rootfs, file_stdio);
    if (rc != 0) {
      (void)send_error_exit(client->fd, rc, "spore run: exec setup failed\n");
      close_client(client);
      return;
    }
    client->stdout_offset = 0;
    client->stderr_offset = 0;
    return;
  }

  if (!session->started || strcmp(request.session_id, session->session_id) != 0) {
    (void)send_error_exit(client->fd, 2, "spore run: no session\n");
    close_client(client);
    return;
  }

  if (request.generation_params[0] != '\0') {
    if (use_rootfs && !rootfs_ready) {
      (void)send_error_exit(client->fd, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = generation_root_path(use_rootfs, rootfs_ready);
    if (write_generation_files(root, request.generation_params) != 0) {
      (void)send_error_exit(client->fd, 126, "spore run: generation helper write failed\n");
      close_client(client);
      return;
    }
    apply_generation_identity(request.generation_params);
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
  int use_rootfs = cmdline_has_flag("spore_rootfs=1");
  int rootfs_writable = cmdline_has_flag("spore_rootfs_rw=1");
  int use_network = cmdline_has_flag("spore_net=1");
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

  int listener = listen_vsock(resolve_port());
  if (listener < 0) {
    dprintf(2, "listen vsock failed: errno=%d\n", errno);
    return 1;
  }
  (void)set_nonblock(listener);
  t_listen_ready = now_ms();

  struct session session;
  memset(&session, 0, sizeof(session));
  session.stdout_fd = -1;
  session.stderr_fd = -1;
  struct client client;
  memset(&client, 0, sizeof(client));
  client.fd = -1;
  struct generation_monitor generation;
  memset(&generation, 0, sizeof(generation));
  generation.last_generation = UINT64_MAX;
  const char *generation_root = generation_root_path(use_rootfs, rootfs_ready);

  for (;;) {
    if (!use_rootfs || rootfs_ready) {
      poll_generation(&generation, generation_root);
    }

    struct pollfd fds[4];
    int roles[4];
    nfds_t nfds = 0;
    fds[nfds].fd = listener;
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    roles[nfds++] = 0;
    if (client.fd >= 0) {
      fds[nfds].fd = client.fd;
      fds[nfds].events = POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 1;
    }
    if (session.stdout_open && !session.file_stdio) {
      fds[nfds].fd = session.stdout_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 2;
    }
    if (session.stderr_open && !session.file_stdio) {
      fds[nfds].fd = session.stderr_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 3;
    }

    // ponytail: polling for child exit; use SIGCHLD/self-pipe if quiet long-running commands make wakeups matter.
    int timeout_ms = session.started && !session.exited ? 10 : 100;
    int pr = poll(fds, nfds, timeout_ms);
    if (pr < 0 && errno != EINTR) continue;
    if (pr > 0) {
      for (nfds_t i = 0; i < nfds; i++) {
        if (fds[i].revents == 0) continue;
        if (roles[i] == 0 && (fds[i].revents & POLLIN)) {
          accept_request(listener, &session, &client, use_rootfs, rootfs_ready, rootfs_error, use_network, network_ready, network_error);
        } else if (roles[i] == 1 && (fds[i].revents & (POLLHUP | POLLERR))) {
          close_client(&client);
        } else if (roles[i] == 2) {
          pump_session_stream(&session, &client, 1);
        } else if (roles[i] == 3) {
          pump_session_stream(&session, &client, 0);
        }
      }
    }
    if (session.file_stdio && !session.exited) {
      pump_session_file(&session, &client, 1);
      pump_session_file(&session, &client, 0);
    }
    poll_session_exit(&session, &client);
    maybe_send_session_exit(&session, &client);
  }
}
