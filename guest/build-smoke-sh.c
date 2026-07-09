#include <fcntl.h>
#include <string.h>
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

int main(int argc, char **argv) {
  if (argc != 3 || strcmp(argv[1], "-c") != 0) {
    write_str(2, "build-smoke-sh: expected -c command\n");
    return 2;
  }

  const char *cmd = argv[2];
  if (strcmp(cmd, "step1") == 0) {
    write_str(1, "step1\n");
    return write_file("/step1", "one\n");
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
