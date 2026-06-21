#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>

int main(void) {
  const char *path = "/tmp/sporevm-flockcheck.lock";
  int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
  if (fd < 0) {
    fprintf(stderr, "open %s failed: %s\n", path, strerror(errno));
    return 1;
  }

  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    fprintf(stderr, "initial flock failed: %s\n", strerror(errno));
    close(fd);
    return 1;
  }

  pid_t child = fork();
  if (child < 0) {
    fprintf(stderr, "fork failed: %s\n", strerror(errno));
    close(fd);
    return 1;
  }

  if (child == 0) {
    int child_fd = open(path, O_RDWR | O_CLOEXEC);
    if (child_fd < 0) {
      fprintf(stderr, "child open failed: %s\n", strerror(errno));
      _exit(10);
    }
    if (flock(child_fd, LOCK_EX | LOCK_NB) == 0) {
      fprintf(stderr, "child flock unexpectedly acquired a conflicting lock\n");
      close(child_fd);
      _exit(11);
    }
    if (errno != EWOULDBLOCK && errno != EAGAIN) {
      fprintf(stderr, "child flock failed with unexpected errno: %s\n", strerror(errno));
      close(child_fd);
      _exit(12);
    }
    close(child_fd);
    _exit(0);
  }

  int status = 0;
  if (waitpid(child, &status, 0) != child) {
    fprintf(stderr, "waitpid failed: %s\n", strerror(errno));
    close(fd);
    return 1;
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fprintf(stderr, "child lock conflict check failed: status=%d\n", status);
    close(fd);
    return 1;
  }

  if (flock(fd, LOCK_UN) != 0) {
    fprintf(stderr, "unlock failed: %s\n", strerror(errno));
    close(fd);
    return 1;
  }

  int second_fd = open(path, O_RDWR | O_CLOEXEC);
  if (second_fd < 0) {
    fprintf(stderr, "second open failed: %s\n", strerror(errno));
    close(fd);
    return 1;
  }
  if (flock(second_fd, LOCK_EX | LOCK_NB) != 0) {
    fprintf(stderr, "post-unlock flock failed: %s\n", strerror(errno));
    close(second_fd);
    close(fd);
    return 1;
  }

  close(second_fd);
  close(fd);
  puts("flock ok");
  return 0;
}
