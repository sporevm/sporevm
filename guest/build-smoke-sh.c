#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void write_str(int fd, const char *data) {
  size_t len = strlen(data);
  while (len > 0) {
    ssize_t n = write(fd, data, len);
    if (n <= 0) return;
    data += n;
    len -= (size_t)n;
  }
}

static int write_file(const char *path, const char *data) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return 1;
  size_t len = strlen(data);
  ssize_t n = write(fd, data, len);
  int close_rc = close(fd);
  return n == (ssize_t)len && close_rc == 0 ? 0 : 1;
}

static int file_exists(const char *path) {
  return access(path, R_OK) == 0;
}

static int file_content_is(const char *path, const char *expected) {
  char buf[128];
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
  ssize_t n = read(fd, buf, sizeof(buf));
  int close_rc = close(fd);
  if (n < 0 || close_rc != 0) return 0;
  size_t expected_len = strlen(expected);
  return (size_t)n == expected_len && memcmp(buf, expected, expected_len) == 0;
}

static int file_content_starts(const char *path, const char *prefix) {
  char buf[128];
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
  ssize_t n = read(fd, buf, sizeof(buf));
  int close_rc = close(fd);
  if (n < 0 || close_rc != 0) return 0;
  size_t prefix_len = strlen(prefix);
  return (size_t)n >= prefix_len && memcmp(buf, prefix, prefix_len) == 0;
}

static int mode_is(const char *path, mode_t expected) {
  struct stat st;
  if (stat(path, &st) != 0) return 0;
  return (st.st_mode & 0777) == expected;
}

static int symlink_target_is(const char *path, const char *expected) {
  struct stat st;
  if (lstat(path, &st) != 0 || !S_ISLNK(st.st_mode)) return 0;
  char buf[128];
  ssize_t n = readlink(path, buf, sizeof(buf));
  if (n < 0) return 0;
  size_t expected_len = strlen(expected);
  return (size_t)n == expected_len && memcmp(buf, expected, expected_len) == 0;
}

static int verify_copy(void) {
  if (!file_exists("/step1")) {
    write_str(2, "build-smoke-sh: missing /step1\n");
    return 3;
  }
  if (!file_content_is("/work/app/a.txt", "merged\n")) {
    write_str(2, "build-smoke-sh: bad merged a.txt\n");
    return 4;
  }
  if (!file_content_starts("/work/app/b.txt", "beta")) {
    write_str(2, "build-smoke-sh: bad merged b.txt\n");
    return 4;
  }
  if (!symlink_target_is("/work/app/link", "a.txt")) {
    write_str(2, "build-smoke-sh: missing copied symlink\n");
    return 4;
  }
  if (!file_content_is("/work/app/mode.txt", "mode\n") || !mode_is("/work/app/mode.txt", 0640)) {
    write_str(2, "build-smoke-sh: bad copied mode\n");
    return 4;
  }
  if (!file_content_is("/work/multi/loose.txt", "loose\n")) {
    write_str(2, "build-smoke-sh: bad multi-source COPY\n");
    return 4;
  }
  if (!file_content_is("/work/wild/one.wild", "one\n") || !file_content_is("/work/wild/two.wild", "two\n")) {
    write_str(2, "build-smoke-sh: bad wildcard COPY\n");
    return 4;
  }
  write_str(1, "verify-copy\n");
  return write_file("/verified-copy", "ok\n");
}

int main(int argc, char **argv) {
  if (argc != 3 || strcmp(argv[1], "-c") != 0) {
    write_str(2, "build-smoke-sh: expected -c command\n");
    return 2;
  }

  const char *cmd = argv[2];
  if (strcmp(cmd, "resize2fs /dev/vda") == 0) {
    write_str(1, "resize2fs\n");
    return 0;
  }
  if (strcmp(cmd, "step1") == 0) {
    write_str(1, "step1\n");
    return write_file("/step1", "one\n");
  }
  if (strcmp(cmd, "verify-copy") == 0) {
    return verify_copy();
  }
  if (strcmp(cmd, "step2") == 0) {
    if (!file_exists("/step1")) {
      write_str(2, "build-smoke-sh: missing /step1\n");
      return 3;
    }
    write_str(1, "step2\n");
    return write_file("/step2", "two\n");
  }
  if (strcmp(cmd, "step2b") == 0) {
    if (!file_exists("/step1")) {
      write_str(2, "build-smoke-sh: missing /step1\n");
      return 3;
    }
    write_str(1, "step2b\n");
    return write_file("/step2", "two-b\n");
  }

  write_str(2, "build-smoke-sh: unsupported command: ");
  write_str(2, cmd);
  write_str(2, "\n");
  return 127;
}
