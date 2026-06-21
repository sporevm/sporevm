#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

#ifndef CGROUP2_SUPER_MAGIC
#define CGROUP2_SUPER_MAGIC 0x63677270
#endif

static int read_file(const char *path, char *buf, size_t cap) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open %s failed: %s\n", path, strerror(errno));
    return -1;
  }
  ssize_t n = read(fd, buf, cap - 1);
  close(fd);
  if (n < 0) {
    fprintf(stderr, "read %s failed: %s\n", path, strerror(errno));
    return -1;
  }
  buf[n] = '\0';
  return 0;
}

static int write_text(const char *path, const char *text) {
  int fd = open(path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open %s for write failed: %s\n", path, strerror(errno));
    return -1;
  }
  size_t len = strlen(text);
  ssize_t n = write(fd, text, len);
  int saved_errno = errno;
  close(fd);
  if (n != (ssize_t)len) {
    fprintf(stderr, "write %s failed: %s\n", path, strerror(saved_errno));
    return -1;
  }
  return 0;
}

int main(void) {
  struct statfs fs;
  if (statfs("/sys/fs/cgroup", &fs) != 0) {
    fprintf(stderr, "statfs /sys/fs/cgroup failed: %s\n", strerror(errno));
    return 1;
  }
  if ((unsigned long)fs.f_type != (unsigned long)CGROUP2_SUPER_MAGIC) {
    fprintf(stderr, "/sys/fs/cgroup is not cgroup2: type=0x%lx\n", (unsigned long)fs.f_type);
    return 1;
  }

  char controllers[4096];
  if (read_file("/sys/fs/cgroup/cgroup.controllers", controllers, sizeof(controllers)) != 0) return 1;

  if (mkdir("/sys/fs/cgroup/sporevm-cgroupcheck", 0755) != 0 && errno != EEXIST) {
    fprintf(stderr, "mkdir test cgroup failed: %s\n", strerror(errno));
    return 1;
  }

  char pid[32];
  snprintf(pid, sizeof(pid), "%ld\n", (long)getpid());
  if (write_text("/sys/fs/cgroup/sporevm-cgroupcheck/cgroup.procs", pid) != 0) return 1;

  char cgroup[4096];
  if (read_file("/proc/self/cgroup", cgroup, sizeof(cgroup)) != 0) return 1;
  if (strstr(cgroup, "0::/sporevm-cgroupcheck") == NULL) {
    fprintf(stderr, "unexpected /proc/self/cgroup after move: %s\n", cgroup);
    return 1;
  }

  if (write_text("/sys/fs/cgroup/cgroup.procs", pid) != 0) return 1;
  if (rmdir("/sys/fs/cgroup/sporevm-cgroupcheck") != 0) {
    fprintf(stderr, "rmdir test cgroup failed: %s\n", strerror(errno));
    return 1;
  }

  puts("cgroup ok");
  return 0;
}
