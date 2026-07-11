#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define LARGE_RUN_CHUNK_BYTES (1024 * 1024)
#define LARGE_RUN_FILE_BYTES ((off_t)512 * 1024 * 1024)
#define BLOCK_ENOSPC_CHUNK_BYTES ((off_t)256 * 1024 * 1024)
#define INODE_ENOSPC_FILES_PER_DIR 128U
#define INODE_ENOSPC_FILE_LIMIT 1000000U

static unsigned char large_run_chunk[LARGE_RUN_CHUNK_BYTES];

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

static int write_all(int fd, const unsigned char *data, size_t len) {
  while (len > 0) {
    ssize_t n = write(fd, data, len);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return 1;
    data += n;
    len -= (size_t)n;
  }
  return 0;
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

static int symlink_target_is(const char *path, const char *expected);

static void sleep_ms(long milliseconds) {
  struct timespec delay = {
    .tv_sec = milliseconds / 1000,
    .tv_nsec = (milliseconds % 1000) * 1000000,
  };
  while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
  }
}

static int move_to_root_cgroup(void) {
  int fd = open("/sys/fs/cgroup/cgroup.procs", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return 1;
  char pid[32];
  int len = snprintf(pid, sizeof(pid), "%ld\n", (long)getpid());
  ssize_t written = len > 0 && (size_t)len < sizeof(pid) ? write(fd, pid, (size_t)len) : -1;
  int close_rc = close(fd);
  return written == len && close_rc == 0 ? 0 : 1;
}

static int spawn_background_writer(void) {
  unlink("/background-survived");
  int ready[2];
  if (pipe(ready) != 0) return 7;
  pid_t pid = fork();
  if (pid < 0) {
    close(ready[0]);
    close(ready[1]);
    return 7;
  }
  if (pid == 0) {
    close(ready[0]);
    if (setsid() < 0 || move_to_root_cgroup() != 0 || write(ready[1], "1", 1) != 1) _exit(7);
    close(ready[1]);
    int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null_fd < 0 || dup2(null_fd, STDIN_FILENO) < 0 ||
        dup2(null_fd, STDOUT_FILENO) < 0 || dup2(null_fd, STDERR_FILENO) < 0) {
      _exit(7);
    }
    close(null_fd);
    sleep_ms(250);
    _exit(write_file("/background-survived", "bad\n"));
  }
  close(ready[1]);
  char moved = 0;
  ssize_t n;
  do {
    n = read(ready[0], &moved, 1);
  } while (n < 0 && errno == EINTR);
  close(ready[0]);
  if (n != 1 || moved != '1') {
    (void)waitpid(pid, NULL, 0);
    return 7;
  }
  write_str(1, "spawn-background\n");
  return 0;
}

static int verify_background_reaped(void) {
  sleep_ms(500);
  if (!path_absent("/background-survived")) {
    write_str(2, "build-smoke-sh: background RUN descendant survived\n");
    return 7;
  }
  write_str(1, "verify-background-reaped\n");
  return 0;
}

static int verify_clock(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_REALTIME, &now) != 0 || now.tv_sec < 1600000000) {
    write_str(2, "build-smoke-sh: realtime clock was not restored\n");
    return 7;
  }
  write_str(1, "verify-clock\n");
  return 0;
}

static int verify_dev(void) {
  struct statfs fs;
  if (statfs("/dev/pts", &fs) != 0 || (unsigned long)fs.f_type != 0x1cd1UL) {
    write_str(2, "build-smoke-sh: /dev/pts is not devpts\n");
    return 7;
  }
  if (!symlink_target_is("/dev/fd", "/proc/self/fd") ||
      !symlink_target_is("/dev/stdin", "/proc/self/fd/0") ||
      !symlink_target_is("/dev/stdout", "/proc/self/fd/1") ||
      !symlink_target_is("/dev/stderr", "/proc/self/fd/2") ||
      !symlink_target_is("/dev/ptmx", "pts/ptmx")) {
    write_str(2, "build-smoke-sh: rootfs /dev links are incomplete\n");
    return 7;
  }
  int ptmx = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (ptmx < 0 || close(ptmx) != 0) {
    write_str(2, "build-smoke-sh: /dev/ptmx is unusable\n");
    return 7;
  }
  write_str(1, "verify-dev\n");
  return 0;
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

static int file_size_is(const char *path, off_t expected) {
  struct stat st;
  if (stat(path, &st) != 0) return 0;
  return S_ISREG(st.st_mode) && st.st_size == expected;
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
      make_dir("/work/multi", 0755) != 0 ||
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
  if (chown("/sentinel.txt", 123, 456) != 0) {
    write_str(2, "build-smoke-sh: cannot change sentinel ownership\n");
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

static int verify_large_copy(void) {
  const off_t size = (off_t)805306368LL;
  if (!file_size_is("/opt/deps/one.bin", size) ||
      !file_size_is("/opt/deps/two.bin", size) ||
      !file_size_is("/opt/deps/three.bin", size)) {
    write_str(2, "build-smoke-sh: bad large COPY file sizes\n");
    return 6;
  }
  write_str(1, "verify-large-copy\n");
  return write_file("/verified-large-copy", "ok\n");
}

static void fill_large_run_chunk(void) {
  for (size_t i = 0; i < sizeof(large_run_chunk); i++) {
    large_run_chunk[i] = (unsigned char)(((i * 131U + 17U) % 251U) + 1U);
  }
}

static void stamp_large_run_chunk(uint64_t block_index) {
  const size_t cas_chunk_bytes = 64 * 1024;
  for (size_t subchunk = 0; subchunk < sizeof(large_run_chunk) / cas_chunk_bytes;
       subchunk++) {
    uint64_t logical_chunk = block_index *
                             (sizeof(large_run_chunk) / cas_chunk_bytes) +
                             subchunk;
    for (size_t nibble = 0; nibble < 8; nibble++) {
      large_run_chunk[subchunk * cas_chunk_bytes + nibble] =
          (unsigned char)(((logical_chunk >> (nibble * 4)) & 0xfU) + 1U);
    }
  }
}

static int generate_large_run(void) {
  fill_large_run_chunk();
  int fd = open("/large-run.bin", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return 8;
  for (off_t offset = 0; offset < LARGE_RUN_FILE_BYTES;
       offset += (off_t)sizeof(large_run_chunk)) {
    stamp_large_run_chunk((uint64_t)offset / sizeof(large_run_chunk));
    if (write_all(fd, large_run_chunk, sizeof(large_run_chunk)) != 0) {
      close(fd);
      return 8;
    }
  }
  if (close(fd) != 0) return 8;
  write_str(1, "generate-large-run\n");
  return 0;
}

static int verify_large_run(void) {
  fill_large_run_chunk();
  int fd = open("/large-run.bin", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 8;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
      st.st_size != LARGE_RUN_FILE_BYTES) {
    close(fd);
    return 8;
  }
  unsigned char read_buf[LARGE_RUN_CHUNK_BYTES];
  for (off_t offset = 0; offset < LARGE_RUN_FILE_BYTES;
       offset += (off_t)sizeof(read_buf)) {
    stamp_large_run_chunk((uint64_t)offset / sizeof(read_buf));
    size_t done = 0;
    while (done < sizeof(read_buf)) {
      ssize_t n = read(fd, read_buf + done, sizeof(read_buf) - done);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) {
        close(fd);
        return 8;
      }
      done += (size_t)n;
    }
    if (memcmp(read_buf, large_run_chunk, sizeof(read_buf)) != 0) {
      close(fd);
      return 8;
    }
  }
  unsigned char trailing;
  if (read(fd, &trailing, 1) != 0 || close(fd) != 0) return 8;
  write_str(1, "verify-large-run\n");
  return write_file("/verified-large-run", "ok\n");
}

static int exhaust_blocks(void) {
  int fd = open("/block-enospc", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return 9;
  unsigned long flags = 0;
  if (ioctl(fd, FS_IOC_GETFLAGS, &flags) != 0 || (flags & FS_EXTENT_FL) == 0) {
    write_str(2, "build-smoke-sh: block ENOSPC file is not extent mapped\n");
    close(fd);
    return 9;
  }
  for (off_t offset = 0; offset < (off_t)1024 * 1024 * 1024 * 1024;
       offset += BLOCK_ENOSPC_CHUNK_BYTES) {
    if (fallocate(fd, 0, offset, BLOCK_ENOSPC_CHUNK_BYTES) == 0) continue;
    int saved_errno = errno;
    close(fd);
    if (saved_errno == ENOSPC) {
      write_str(2, "SPORE_BUILD_ENOSPC block\n");
      return ENOSPC;
    }
    write_str(2, "build-smoke-sh: fallocate failed before block ENOSPC\n");
    return 9;
  }
  close(fd);
  write_str(2, "build-smoke-sh: block ENOSPC limit was not reached\n");
  return 9;
}

static int inode_enospc(void) {
  write_str(2, "SPORE_BUILD_ENOSPC inode\n");
  return ENOSPC;
}

static int exhaust_inodes(void) {
  if (make_dir("/inode-enospc", 0755) != 0) {
    return errno == ENOSPC ? inode_enospc() : 10;
  }
  char dir[64];
  char path[96];
  for (unsigned int i = 0; i < INODE_ENOSPC_FILE_LIMIT; i++) {
    if (i % INODE_ENOSPC_FILES_PER_DIR == 0) {
      int len = snprintf(dir, sizeof(dir), "/inode-enospc/d%06u",
                         i / INODE_ENOSPC_FILES_PER_DIR);
      if (len <= 0 || (size_t)len >= sizeof(dir)) return 10;
      if (mkdir(dir, 0755) != 0) {
        return errno == ENOSPC ? inode_enospc() : 10;
      }
    }
    int len = snprintf(path, sizeof(path), "%s/f%03u", dir,
                       i % INODE_ENOSPC_FILES_PER_DIR);
    if (len <= 0 || (size_t)len >= sizeof(path)) return 10;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) return errno == ENOSPC ? inode_enospc() : 10;
    if (close(fd) != 0) return errno == ENOSPC ? inode_enospc() : 10;
  }
  write_str(2, "build-smoke-sh: inode ENOSPC limit was not reached\n");
  return 10;
}

int main(int argc, char **argv) {
  if (argc != 3 || strcmp(argv[1], "-c") != 0) {
    write_str(2, "build-smoke-sh: expected -c command\n");
    return 2;
  }

  const char *cmd = argv[2];
  if (strcmp(cmd, "verify-clock") == 0) {
    return verify_clock();
  }
  if (strcmp(cmd, "verify-dev") == 0) {
    return verify_dev();
  }
  if (strcmp(cmd, "spawn-background") == 0) {
    return spawn_background_writer();
  }
  if (strcmp(cmd, "verify-background-reaped") == 0) {
    return verify_background_reaped();
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
  if (strcmp(cmd, "verify-large-copy") == 0) {
    return verify_large_copy();
  }
  if (strcmp(cmd, "generate-large-run") == 0) {
    return generate_large_run();
  }
  if (strcmp(cmd, "verify-large-run") == 0) {
    return verify_large_run();
  }
  if (strcmp(cmd, "exhaust-blocks") == 0) {
    return exhaust_blocks();
  }
  if (strcmp(cmd, "exhaust-inodes") == 0) {
    return exhaust_inodes();
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
