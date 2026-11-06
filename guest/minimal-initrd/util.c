// Small file, fd, clock, and little-endian helpers shared by the agent.

#include "agent.h"

int64_t now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
  }
  return 0;
}

int wait_for_path(const char *path, int attempts, int sleep_us) {
  for (int i = 0; i < attempts; i++) {
    if (access(path, R_OK) == 0) return 0;
    usleep((useconds_t)sleep_us);
  }
  return -1;
}

int path_is_dir(const char *path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

int mkdir_p(const char *path, mode_t mode) {
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

ssize_t readlink_bounded(const char *path, char *out, size_t cap) {
  if (cap < 2) {
    errno = ENAMETOOLONG;
    return -1;
  }
  ssize_t len = readlink(path, out, cap);
  if (len <= 0) return -1;
  if ((size_t)len == cap) {
    errno = ENAMETOOLONG;
    return -1;
  }
  out[len] = '\0';
  return len;
}

static ssize_t readlinkat_bounded(int dir_fd, const char *path, char *out, size_t cap) {
  if (cap < 2) {
    errno = ENAMETOOLONG;
    return -1;
  }
  ssize_t len = readlinkat(dir_fd, path, out, cap);
  if (len <= 0) return -1;
  if ((size_t)len == cap) {
    errno = ENAMETOOLONG;
    return -1;
  }
  out[len] = '\0';
  return len;
}

ssize_t read_line(int fd, char *buf, size_t cap) {
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
  if (len + 1 == cap && (len == 0 || buf[len - 1] != '\n')) return -2;
  return (ssize_t)len;
}

int write_all(int fd, const void *raw, size_t len) {
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

int read_exact(int fd, void *raw, size_t len) {
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

int write_file_atomic(const char *path, const char *data, size_t len) {
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

int set_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

void write_le16(unsigned char *out, uint16_t value) {
  out[0] = (unsigned char)(value & 0xff);
  out[1] = (unsigned char)((value >> 8) & 0xff);
}

void write_le32(unsigned char *out, uint32_t value) {
  out[0] = (unsigned char)(value & 0xff);
  out[1] = (unsigned char)((value >> 8) & 0xff);
  out[2] = (unsigned char)((value >> 16) & 0xff);
  out[3] = (unsigned char)((value >> 24) & 0xff);
}

void write_le64(unsigned char *out, uint64_t value) {
  for (int i = 0; i < 8; i++) {
    out[i] = (unsigned char)((value >> (8 * i)) & 0xff);
  }
}

uint16_t read_le16(const unsigned char *in) {
  return (uint16_t)in[0] | ((uint16_t)in[1] << 8);
}

uint32_t read_le32(const unsigned char *in) {
  return (uint32_t)in[0] | ((uint32_t)in[1] << 8) | ((uint32_t)in[2] << 16) | ((uint32_t)in[3] << 24);
}

uint64_t read_le64(const unsigned char *in) {
  uint64_t value = 0;
  for (int i = 0; i < 8; i++) {
    value |= ((uint64_t)in[i]) << (8 * i);
  }
  return value;
}

int write_text_file(const char *path, const char *text) {
  int fd = open(path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  int rc = write_all(fd, text, strlen(text));
  close(fd);
  return rc;
}

int write_pid_file(const char *path, pid_t pid) {
  char buf[32];
  int n = snprintf(buf, sizeof(buf), "%ld\n", (long)pid);
  if (n <= 0 || (size_t)n >= sizeof(buf)) return -1;
  return write_text_file(path, buf);
}

int read_u64_file(const char *path, uint64_t *out) {
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

void close_fd_if_open(int *fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

void close_pipe_if_open(int pipefd[2]) {
  close_fd_if_open(&pipefd[0]);
  close_fd_if_open(&pipefd[1]);
}

#ifdef SPORE_AGENT_REQUEST_FUZZ
__attribute__((visibility("hidden"))) int spore_agent_test_bounded_readlink(
    const unsigned char *target_bytes, size_t target_len) {
  if (target_len == 0 || target_len >= 1024) return -1;
  char target[1024];
  memcpy(target, target_bytes, target_len);
  target[target_len] = '\0';

  char path[] = "/tmp/spore-agent-readlink-XXXXXX";
  int fd = mkstemp(path);
  if (fd < 0) return -1;
  int rc = close(fd);
  if (unlink(path) != 0) rc = -1;
  if (rc == 0 && symlink(target, path) != 0) rc = -1;
  if (rc == 0) {
    char out[512];
    rc = readlink_bounded(path, out, sizeof(out)) < 0 ? -1 : 0;
  }
  if (unlink(path) != 0 && errno != ENOENT) rc = -1;
  return rc;
}
#endif
