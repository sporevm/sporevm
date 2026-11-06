// Detached starts and their bounded retained output.

#include "agent.h"

void reap_detached_children(struct detached_children *children) {
  int i = 0;
  while (i < children->count) {
    int status = 0;
    pid_t rc = waitpid(children->pids[i], &status, WNOHANG);
    if (rc == children->pids[i] || (rc < 0 && errno == ECHILD)) {
      if (children->pids[i] == children->retained_pid && !children->retained_exited) {
        children->retained_exited = 1;
        if (rc == children->pids[i] && WIFEXITED(status)) {
          children->retained_exit_code = WEXITSTATUS(status);
        } else if (rc == children->pids[i] && WIFSIGNALED(status)) {
          children->retained_exit_code = 128 + WTERMSIG(status);
          if (children->retained_exit_code > 255) children->retained_exit_code = 255;
        } else {
          children->retained_exit_code = 255;
        }
      }
      children->count--;
      if (i < children->count) {
        children->pids[i] = children->pids[children->count];
      }
      continue;
    }
    if (rc < 0 && errno == EINTR) continue;
    i++;
  }
}

static void drain_retained_stream(int *fd, unsigned char *output, size_t *output_len, int *truncated) {
  if (*fd < 0) return;
  unsigned char discard[MAX_FRAME_PAYLOAD];
  for (;;) {
    unsigned char *target = discard;
    size_t capacity = sizeof(discard);
    if (*output_len < INITIAL_OUTPUT_CAP) {
      target = output + *output_len;
      capacity = INITIAL_OUTPUT_CAP - *output_len;
    }
    ssize_t n = read(*fd, target, capacity);
    if (n > 0) {
      if (target == discard) {
        *truncated = 1;
      } else {
        *output_len += (size_t)n;
      }
      continue;
    }
    if (n == 0) {
      close_fd_if_open(fd);
      return;
    }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    close_fd_if_open(fd);
    return;
  }
}

void drain_retained_output(struct detached_children *children) {
  drain_retained_stream(&children->retained_stdout_fd, children->retained_stdout,
                        &children->retained_stdout_len, &children->retained_stdout_truncated);
  drain_retained_stream(&children->retained_stderr_fd, children->retained_stderr,
                        &children->retained_stderr_len, &children->retained_stderr_truncated);
}

int send_retained_output(struct client *client, struct detached_children *children) {
  reap_detached_children(children);
  drain_retained_output(children);
  if (children->retained_pid <= 0) {
    return send_client_error_exit(client, 2, "spore create: initial output was not retained\n");
  }
  /* status (running/exited), exit code, then stdout/stderr truncation bits. */
  unsigned char header[INITIAL_OUTPUT_HEADER_LEN] = {
    children->retained_exited ? 1 : 0,
    children->retained_exited ? (unsigned char)children->retained_exit_code : 0,
    (unsigned char)((children->retained_stdout_truncated ? 1 : 0) |
                    (children->retained_stderr_truncated ? 2 : 0)),
  };
  if (send_spio_data(client->fd, SPIO_STDOUT_STREAM, 0, header, sizeof(header)) != 0 ||
      send_spio_data(client->fd, SPIO_STDOUT_STREAM, sizeof(header), children->retained_stdout,
                     children->retained_stdout_len) != 0 ||
      send_spio_data(client->fd, SPIO_STDERR_STREAM, 0, children->retained_stderr,
                     children->retained_stderr_len) != 0 ||
      send_client_exit(client, 0) != 0) {
    return -1;
  }
  return 0;
}

static void detached_child_fail(int status_fd) {
  if (status_fd >= 0) {
    (void)write_all(status_fd, "!", 1);
  }
  _exit(127);
}

int start_detached(char *const argv[], char *const envp[], const char *working_dir, int use_rootfs, int retain_output, struct detached_children *children) {
  t_command_start = now_ms();
  reap_detached_children(children);
  if (children->count >= MAX_DETACHED_CHILDREN) {
    t_command_exit = now_ms();
    return 127;
  }

  if (retain_output && children->retained_pid > 0) {
    t_command_exit = now_ms();
    return 127;
  }

  int devnull = open("/dev/null", O_RDWR | O_CLOEXEC);
  int start_pipe[2] = { -1, -1 };
  int exec_pipe[2] = { -1, -1 };
  int stdout_pipe[2] = { -1, -1 };
  int stderr_pipe[2] = { -1, -1 };
  if (devnull < 0 || pipe2(start_pipe, O_CLOEXEC) != 0 || pipe2(exec_pipe, O_CLOEXEC) != 0 ||
      (retain_output && (pipe2(stdout_pipe, O_CLOEXEC) != 0 || pipe2(stderr_pipe, O_CLOEXEC) != 0))) {
    close_fd_if_open(&devnull);
    close_pipe_if_open(start_pipe);
    close_pipe_if_open(exec_pipe);
    close_pipe_if_open(stdout_pipe);
    close_pipe_if_open(stderr_pipe);
    t_command_exit = now_ms();
    return 127;
  }

  pid_t pid = fork();
  if (pid == 0) {
    close(start_pipe[1]);
    close(exec_pipe[0]);
    close_fd_if_open(&stdout_pipe[0]);
    close_fd_if_open(&stderr_pipe[0]);
    char start_byte = 0;
    ssize_t sr = 0;
    do {
      sr = read(start_pipe[0], &start_byte, 1);
    } while (sr < 0 && errno == EINTR);
    if (sr != 1 || start_byte != 1) detached_child_fail(exec_pipe[1]);
    close(start_pipe[0]);
    if (dup2(devnull, STDIN_FILENO) < 0 ||
        dup2(retain_output ? stdout_pipe[1] : devnull, STDOUT_FILENO) < 0 ||
        dup2(retain_output ? stderr_pipe[1] : devnull, STDERR_FILENO) < 0) {
      detached_child_fail(exec_pipe[1]);
    }
    close_fd_if_open(&stdout_pipe[1]);
    close_fd_if_open(&stderr_pipe[1]);
    close(devnull);
    if (use_rootfs) {
      if (chroot("/mnt/rootfs") != 0) detached_child_fail(exec_pipe[1]);
    }
    const char *cwd = working_dir[0] != '\0' ? working_dir : "/";
    if (chdir(cwd) != 0) detached_child_fail(exec_pipe[1]);
    execve_or_report(argv, envp, use_rootfs, exec_pipe[1], EXEC_LOOKUP_PATH);
  }

  close_fd_if_open(&devnull);
  close_fd_if_open(&start_pipe[0]);
  close_fd_if_open(&exec_pipe[1]);
  close_fd_if_open(&stdout_pipe[1]);
  close_fd_if_open(&stderr_pipe[1]);
  if (pid < 0) {
    close_pipe_if_open(start_pipe);
    close_pipe_if_open(exec_pipe);
    close_pipe_if_open(stdout_pipe);
    close_pipe_if_open(stderr_pipe);
    t_command_exit = now_ms();
    return 127;
  }

  if (write_all(start_pipe[1], "\1", 1) != 0) {
    close_pipe_if_open(start_pipe);
    close_pipe_if_open(exec_pipe);
    close_pipe_if_open(stdout_pipe);
    close_pipe_if_open(stderr_pipe);
    (void)kill(pid, SIGKILL);
    wait_child_blocking(pid);
    t_command_exit = now_ms();
    return 127;
  }
  close_fd_if_open(&start_pipe[1]);

  char failure = 0;
  ssize_t n = 0;
  do {
    n = read(exec_pipe[0], &failure, 1);
  } while (n < 0 && errno == EINTR);
  close_fd_if_open(&exec_pipe[0]);
  if (n != 0) {
    close_pipe_if_open(stdout_pipe);
    close_pipe_if_open(stderr_pipe);
    (void)kill(pid, SIGKILL);
    wait_child_blocking(pid);
    t_command_exit = now_ms();
    return 127;
  }

  children->pids[children->count++] = pid;
  if (retain_output) {
    if (set_nonblock(stdout_pipe[0]) != 0 || set_nonblock(stderr_pipe[0]) != 0) {
      close_pipe_if_open(stdout_pipe);
      close_pipe_if_open(stderr_pipe);
      (void)kill(pid, SIGKILL);
      wait_child_blocking(pid);
      children->count--;
      t_command_exit = now_ms();
      return 127;
    }
    children->retained_pid = pid;
    children->retained_stdout_fd = stdout_pipe[0];
    children->retained_stderr_fd = stderr_pipe[0];
    children->retained_exited = 0;
    children->retained_exit_code = 0;
    children->retained_stdout_truncated = 0;
    children->retained_stderr_truncated = 0;
    children->retained_stdout_len = 0;
    children->retained_stderr_len = 0;
  }
  t_command_exit = now_ms();
  return 0;
}
