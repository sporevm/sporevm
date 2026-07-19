#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
  static const char *paths[] = {"/dev/vda", "/dev/vdb", "/dev/vdc", "/dev/vdd"};
  uint8_t buffer[32];
  for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
    int fd = open(paths[index], O_RDONLY | O_CLOEXEC);
    if (fd < 0 || pread(fd, buffer, sizeof(buffer), 0) != (ssize_t)sizeof(buffer)) {
      fprintf(stderr, "block read failed path=%s errno=%d\n", paths[index], errno);
      if (fd >= 0) close(fd);
      return 1;
    }
    close(fd);
  }

  static const uint8_t pattern[] = "sporevm-x86-block";
  int root = open(paths[0], O_RDWR | O_CLOEXEC);
  if (root < 0 || pwrite(root, pattern, sizeof(pattern), 4096) != (ssize_t)sizeof(pattern)) {
    fprintf(stderr, "root block write failed errno=%d\n", errno);
    if (root >= 0) close(root);
    return 1;
  }
  memset(buffer, 0, sizeof(buffer));
  if (pread(root, buffer, sizeof(pattern), 4096) != (ssize_t)sizeof(pattern) ||
      memcmp(buffer, pattern, sizeof(pattern)) != 0) {
    fputs("root block readback failed\n", stderr);
    close(root);
    return 1;
  }
  close(root);

  for (size_t index = 1; index < sizeof(paths) / sizeof(paths[0]); index++) {
    int fd = open(paths[index], O_WRONLY | O_CLOEXEC | O_SYNC);
    if (fd >= 0) {
      (void)pwrite(fd, pattern, sizeof(pattern), 4096);
      (void)fsync(fd);
      close(fd);
    }
  }

  puts("block ok devices=4 root_rw=ok immutable_write_attempted=3");
  return 0;
}
