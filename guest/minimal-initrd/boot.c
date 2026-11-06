// Boot-time guest setup: pseudo filesystems, kernel cmdline flags, and
// the build context and input disks.

#include "agent.h"

void mount_proc(void) {
  mkdir("/proc", 0755);
  if (mount("proc", "/proc", "proc", 0, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount proc failed: errno=%d\n", errno);
  }
}

void mount_sysfs(void) {
  mkdir("/sys", 0755);
  if (mount("sysfs", "/sys", "sysfs", MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount sysfs failed: errno=%d\n", errno);
  }
}

void mount_cgroup2_if_dir(const char *target) {
  if (!path_is_dir(target)) return;
  if (mount("none", target, "cgroup2", MS_NOSUID | MS_NOEXEC | MS_NODEV, "") != 0 && errno != EBUSY) {
    dprintf(2, "mount cgroup2 failed: target=%s errno=%d\n", target, errno);
  }
}

void prepare_dev(void) {
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

void read_cmdline(char *buf, size_t cap) {
  if (cap == 0) return;
  buf[0] = '\0';
  int fd = open("/proc/cmdline", O_RDONLY);
  if (fd < 0) return;
  ssize_t n = read(fd, buf, cap - 1);
  close(fd);
  if (n <= 0) return;
  buf[n] = '\0';
}

uint32_t resolve_port_from_cmdline(const char *buf) {
  if (buf[0] == '\0') return 10700;
  const char *key = "cleanroom_guest_port=";
  const char *p = strstr(buf, key);
  if (p == NULL) return 10700;
  p += strlen(key);
  unsigned long value = strtoul(p, NULL, 10);
  if (value == 0 || value > 65535) return 10700;
  return (uint32_t)value;
}

int cmdline_has_flag_in(const char *buf, const char *flag) {
  return strstr(buf, flag) != NULL;
}

int setup_build_context(char *error, size_t cap) {
  mkdir("/mnt", 0755);
  mkdir(BUILD_CONTEXT_ROOT, 0755);
  if (wait_for_path("/dev/vdb", 100, 50000) != 0) {
    snprintf(error, cap, "build context block device not found: path=/dev/vdb");
    return -1;
  }
  if (mount("/dev/vdb", BUILD_CONTEXT_ROOT, "ext4", MS_RDONLY, "noload") != 0) {
    snprintf(error, cap, "build context mount failed: path=/dev/vdb target=%s errno=%d", BUILD_CONTEXT_ROOT, errno);
    return -1;
  }
  return 0;
}

int resolve_build_input_count(const char *buf) {
  const char *key = "spore_build_inputs=";
  const char *p = strstr(buf, key);
  if (p == NULL) return 0;
  p += strlen(key);
  char *end = NULL;
  unsigned long value = strtoul(p, &end, 10);
  if (end == p || value > MAX_BUILD_INPUT_DISKS) return -1;
  return (int)value;
}

int setup_build_inputs(int count, int has_context, char *error, size_t cap) {
  mkdir("/mnt", 0755);
  mkdir(BUILD_INPUT_ROOT, 0755);
  for (int i = 0; i < count; i++) {
    char device[32];
    char target[64];
    int letter = 'b' + has_context + i;
    int dn = snprintf(device, sizeof(device), "/dev/vd%c", letter);
    int tn = snprintf(target, sizeof(target), "%s/%d", BUILD_INPUT_ROOT, i);
    if (dn <= 0 || (size_t)dn >= sizeof(device) || tn <= 0 || (size_t)tn >= sizeof(target)) return -1;
    mkdir(target, 0755);
    if (wait_for_path(device, 100, 50000) != 0) {
      snprintf(error, cap, "build input block device not found: index=%d path=%s", i, device);
      return -1;
    }
    if (mount(device, target, "ext4", MS_RDONLY, "noload") != 0) {
      snprintf(error, cap, "build input mount failed: index=%d path=%s target=%s errno=%d", i, device, target, errno);
      return -1;
    }
  }
  return 0;
}
