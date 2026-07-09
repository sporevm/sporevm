#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
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

static int make_dir(const char *path, mode_t mode) {
  if (mkdir(path, mode) == 0 || errno == EEXIST) return 0;
  return 1;
}

static int file_exists(const char *path) {
  return access(path, F_OK) == 0;
}

static int path_absent(const char *path) {
  return access(path, F_OK) != 0 && errno == ENOENT;
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

static int dir_exists(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0) return 0;
  return S_ISDIR(st.st_mode);
}

static int owner_is_root(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0) return 0;
  return st.st_uid == 0 && st.st_gid == 0;
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
  if (!symlink_target_is("/work/symlinked-dir", "/work/real-internal") ||
      !file_content_is("/work/real-internal/internal.txt", "internal\n")) {
    write_str(2, "build-smoke-sh: bad internal symlink COPY\n");
    return 4;
  }
  if (!symlink_target_is("/work/abs-link", "/etc/rootfs-absolute-copy")) {
    write_str(2, "build-smoke-sh: missing absolute symlink\n");
    return 4;
  }
  if (!file_content_is("/etc/rootfs-absolute-copy/absolute.txt", "absolute\n")) {
    write_str(2, "build-smoke-sh: bad absolute symlink target file\n");
    return 4;
  }
  if (!dir_exists("/proc/1/root")) {
    write_str(2, "build-smoke-sh: missing initrd root view\n");
    return 4;
  }
  if (!file_content_is("/escape.txt", "escape\n") ||
      !path_absent("/proc/1/root/escape.txt")) {
    write_str(2, "build-smoke-sh: bad confined absolute symlink escape COPY\n");
    return 4;
  }
  if (!symlink_target_is("/work/write-file", "/sentinel.txt") ||
      !file_content_is("/sentinel.txt", "through\n") ||
      !mode_is("/sentinel.txt", 0600) ||
      !path_absent("/proc/1/root/sentinel.txt")) {
    write_str(2, "build-smoke-sh: bad file symlink write-through COPY\n");
    return 4;
  }
  if (!symlink_target_is("/work/dir-link", "/dir-target") ||
      !file_content_is("/dir-target/dir-file.txt", "dir\n") ||
      !dir_exists("/dir-target/empty")) {
    write_str(2, "build-smoke-sh: bad directory symlink merge COPY\n");
    return 4;
  }
  if (!symlink_target_is("/work/dangling-file", "/dangling-target.txt") ||
      !file_content_is("/dangling-target.txt", "dangling\n")) {
    write_str(2, "build-smoke-sh: bad dangling symlink COPY\n");
    return 4;
  }
  if (!owner_is_root("/work/app") ||
      !owner_is_root("/work/app/mode.txt") ||
      !owner_is_root("/work/multi") ||
      !owner_is_root("/escape.txt") ||
      !owner_is_root("/sentinel.txt") ||
      !owner_is_root("/dir-target/dir-file.txt") ||
      !owner_is_root("/dir-target/empty") ||
      !owner_is_root("/dangling-target.txt")) {
    write_str(2, "build-smoke-sh: copied entries are not root-owned\n");
    return 4;
  }
  write_str(1, "verify-copy\n");
  return write_file("/verified-copy", "ok\n");
}

static int setup_symlink_targets(void) {
  if (make_dir("/work", 0755) != 0 ||
      make_dir("/work/real-internal", 0755) != 0 ||
      make_dir("/dir-target", 0755) != 0 ||
      make_dir("/etc/rootfs-absolute-copy", 0755) != 0) {
    write_str(2, "build-smoke-sh: cannot create symlink targets\n");
    return 5;
  }
  unlink("/work/symlinked-dir");
  unlink("/work/abs-link");
  unlink("/work/evil");
  unlink("/work/write-file");
  unlink("/work/dir-link");
  unlink("/work/dangling-file");
  unlink("/escape.txt");
  unlink("/sentinel.txt");
  unlink("/dangling-target.txt");
  if (write_file("/sentinel.txt", "old\n") != 0) {
    write_str(2, "build-smoke-sh: cannot create sentinel\n");
    return 5;
  }
  if (symlink("/work/real-internal", "/work/symlinked-dir") != 0 ||
      symlink("/etc/rootfs-absolute-copy", "/work/abs-link") != 0 ||
      symlink("/", "/work/evil") != 0 ||
      symlink("/sentinel.txt", "/work/write-file") != 0 ||
      symlink("/dir-target", "/work/dir-link") != 0 ||
      symlink("/dangling-target.txt", "/work/dangling-file") != 0) {
    write_str(2, "build-smoke-sh: cannot create symlink fixtures\n");
    return 5;
  }
  write_str(1, "setup-symlink-targets\n");
  return 0;
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
  if (strcmp(cmd, "setup-symlink-targets") == 0) {
    return setup_symlink_targets();
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
