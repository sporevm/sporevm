// Starting the requested command: stdio, PTY, cgroup, exec path lookup,
// and child reaping.

#include "agent.h"

#define MAX_EXEC_PATH_LEN (MAX_ENV_LEN - sizeof("PATH="))
#define MAX_EXEC_PATH_ENTRIES 64
#define MAX_EXEC_CANDIDATE_LEN 512

int sigchld_pipe[2] = { -1, -1 };

static const uint64_t memory_high_step_bytes = 1073741824ULL;
static const char memory_high_limit[] = "268435456\n";

int cgroup_child_path(char *out, size_t out_len, const char *dir, const char *file) {
  int n = snprintf(out, out_len, "%s/%s", dir, file);
  return (n > 0 && (size_t)n < out_len) ? 0 : -1;
}

void close_session_cgroup(struct session *session) {
  if (session->memory_pressure_fd >= 0) {
    close(session->memory_pressure_fd);
    session->memory_pressure_fd = -1;
  }
  if (session->cgroup_path[0] != '\0') {
    if (rmdir(session->cgroup_path) == 0 || errno == ENOENT) {
      session->cgroup_path[0] = '\0';
    }
  }
}

static int session_cgroup_setup_error(struct session *session, const char *step) {
  snprintf(session->setup_error, sizeof(session->setup_error),
           "spore build: RUN cgroup setup failed: %s errno=%d\n", step, errno);
  dprintf(2, "%s", session->setup_error);
  return -1;
}

static int setup_session_cgroup(struct session *session, pid_t pid, int memory_pressure) {
  if (memory_pressure && write_text_file("/sys/fs/cgroup/cgroup.subtree_control", "+memory\n") != 0) return session_cgroup_setup_error(session, "enable memory controller");
  int n = snprintf(session->cgroup_path, sizeof(session->cgroup_path), "/sys/fs/cgroup/spore-run-%ld", (long)pid);
  if (n <= 0 || (size_t)n >= sizeof(session->cgroup_path)) return session_cgroup_setup_error(session, "format cgroup path");
  if (mkdir(session->cgroup_path, 0755) != 0) return session_cgroup_setup_error(session, "create cgroup");

  char path[192];
  if (memory_pressure &&
      (cgroup_child_path(path, sizeof(path), session->cgroup_path, "memory.high") != 0 ||
       write_text_file(path, memory_high_limit) != 0)) return session_cgroup_setup_error(session, "set high limit");
  if (cgroup_child_path(path, sizeof(path), session->cgroup_path, "cgroup.procs") != 0 ||
      write_pid_file(path, pid) != 0) return session_cgroup_setup_error(session, "move process");
  if (session->build_run_isolation) {
    char sandbox_error[192];
    if (spore_build_run_sandbox_attach_device_policy(
            session->cgroup_path, sandbox_error, sizeof(sandbox_error)) != 0) {
      dprintf(2, "%s\n", sandbox_error);
      snprintf(session->setup_error, sizeof(session->setup_error), "%s\n", sandbox_error);
      return -1;
    }
  }
  if (!memory_pressure) return 0;
  if (cgroup_child_path(path, sizeof(path), session->cgroup_path, "memory.events") != 0) return session_cgroup_setup_error(session, "format events path");
  session->memory_pressure_fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  if (session->memory_pressure_fd < 0) return session_cgroup_setup_error(session, "open events");
  char buf[256];
  (void)read(session->memory_pressure_fd, buf, sizeof(buf));
  return 0;
}

int stop_session_processes(struct session *session, pid_t pid) {
  if (session->cgroup_path[0] != '\0') {
    char path[192];
    if (cgroup_child_path(path, sizeof(path), session->cgroup_path, "cgroup.kill") != 0 ||
        write_text_file(path, "1\n") != 0) {
      (void)kill(pid, SIGKILL);
    }
  } else {
    (void)kill(pid, SIGKILL);
  }
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }
  if (session->cgroup_path[0] != '\0') {
    int64_t deadline = now_ms() + 5000;
    for (;;) {
      int populated = session_cgroup_populated(session);
      if (populated == 0) break;
      if (populated < 0 || now_ms() >= deadline) return -1;
      usleep(1000);
    }
  }
  close_session_cgroup(session);
  return session->cgroup_path[0] == '\0' ? 0 : -1;
}

void drain_memory_pressure_events(struct session *session) {
  char buf[256];
  (void)lseek(session->memory_pressure_fd, 0, SEEK_SET);
  (void)read(session->memory_pressure_fd, buf, sizeof(buf));
}

int rearm_memory_pressure_limit(struct session *session) {
  char path[192];
  uint64_t current = 0;
  if (cgroup_child_path(path, sizeof(path), session->cgroup_path, "memory.current") != 0 ||
      read_u64_file(path, &current) != 0) return -1;
  uint64_t next = current + memory_high_step_bytes;
  if (next < current) return -1;
  if (cgroup_child_path(path, sizeof(path), session->cgroup_path, "memory.high") != 0) return -1;
  char limit[32];
  int n = snprintf(limit, sizeof(limit), "%llu\n", (unsigned long long)next);
  if (n <= 0 || (size_t)n >= sizeof(limit)) return -1;
  return write_text_file(path, limit);
}

int wait_child(pid_t pid, int *status, struct rusage *usage) {
  for (;;) {
    pid_t rc = wait4(pid, status, WNOHANG, usage);
    if (rc == pid) return 1;
    if (rc == 0) return 0;
    if (errno == EINTR) continue;
    return -1;
  }
}

static void sigchld_handler(int signum) {
  (void)signum;
  int saved_errno = errno;
  if (sigchld_pipe[1] >= 0) {
    char byte = 1;
    (void)write(sigchld_pipe[1], &byte, 1);
  }
  errno = saved_errno;
}

int setup_sigchld_wakeup(void) {
  if (pipe2(sigchld_pipe, O_CLOEXEC | O_NONBLOCK) != 0) return -1;

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = sigchld_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_NOCLDSTOP | SA_RESTART;
  return sigaction(SIGCHLD, &sa, NULL);
}

void drain_sigchld_wakeup(void) {
  char buf[32];
  while (read(sigchld_pipe[0], buf, sizeof(buf)) > 0) {
  }
}

int apply_terminal_size(int fd, uint16_t rows, uint16_t cols) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = rows;
  ws.ws_col = cols;
  return ioctl(fd, TIOCSWINSZ, &ws);
}

static int open_session_pty(int *master_out, int *slave_out, uint16_t rows, uint16_t cols) {
  int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (master < 0) return -1;
  if (grantpt(master) != 0 || unlockpt(master) != 0) {
    close(master);
    return -1;
  }
  char *slave_path = ptsname(master);
  if (slave_path == NULL) {
    close(master);
    return -1;
  }
  int slave = open(slave_path, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (slave < 0) {
    close(master);
    return -1;
  }
  if (set_nonblock(master) != 0) {
    close(slave);
    close(master);
    return -1;
  }
  (void)apply_terminal_size(slave, rows, cols);
  *master_out = master;
  *slave_out = slave;
  return 0;
}

static int exec_failure_code(int err) {
  return err == ENOENT || err == ENOTDIR ? 127 : 126;
}

static const char *env_value(char *const envp[], const char *name) {
  size_t name_len = strlen(name);
  for (size_t i = 0; envp[i] != NULL; i++) {
    if (strncmp(envp[i], name, name_len) == 0 && envp[i][name_len] == '=') return envp[i] + name_len + 1;
  }
  return NULL;
}

static int resolve_exec_path(const char *command, const char *path, char *executable, size_t executable_cap) {
  if (path == NULL || path[0] == '\0') {
    errno = ENOENT;
    return -1;
  }
  size_t path_len = strnlen(path, MAX_EXEC_PATH_LEN + 1);
  if (path_len > MAX_EXEC_PATH_LEN) {
    errno = ENAMETOOLONG;
    return -1;
  }

  size_t entry_count = 1;
  for (size_t i = 0; i < path_len; i++) {
    if (path[i] == ':' && ++entry_count > MAX_EXEC_PATH_ENTRIES) {
      errno = E2BIG;
      return -1;
    }
  }

  size_t command_len = strlen(command);
  const char *entry = path;
  for (;;) {
    const char *end = strchr(entry, ':');
    size_t dir_len = end != NULL ? (size_t)(end - entry) : strlen(entry);
    const char *dir = dir_len == 0 ? "." : entry;
    if (dir_len == 0) dir_len = 1;
    if (dir_len + 1 + command_len + 1 > MAX_EXEC_CANDIDATE_LEN ||
        dir_len + 1 + command_len + 1 > executable_cap) {
      errno = ENAMETOOLONG;
      return -1;
    }

    memcpy(executable, dir, dir_len);
    executable[dir_len] = '/';
    memcpy(executable + dir_len + 1, command, command_len + 1);
    struct stat candidate_stat;
    if (stat(executable, &candidate_stat) == 0 &&
        S_ISREG(candidate_stat.st_mode) && access(executable, X_OK) == 0) {
      if (dir[0] != '/') {
        errno = EACCES;
        return -1;
      }
      return 0;
    }
    if (end == NULL) break;
    entry = end + 1;
  }
  errno = ENOENT;
  return -1;
}

void execve_or_report(
    char *const argv[], char *const envp[], int use_rootfs, int failure_fd,
    enum exec_lookup_mode exec_lookup) {
  char *const empty_env[] = { NULL };
  char *const *effective_env = envp[0] != NULL ? envp : empty_env;
  if (exec_lookup == EXEC_LOOKUP_PATH && strchr(argv[0], '/') == NULL) {
    const char *path = env_value(envp, "PATH");
    char executable[MAX_EXEC_CANDIDATE_LEN];
    if (resolve_exec_path(argv[0], path, executable, sizeof(executable)) == 0) {
      execve(executable, argv, effective_env);
    }
  } else {
    execve(argv[0], argv, effective_env);
  }
  int err = errno;
  if (!use_rootfs && (err == ENOENT || err == ENOTDIR)) {
    dprintf(STDERR_FILENO, "spore run: initrd cannot execute %s: not found; use --image, --rootfs, or provide an initrd containing the command\n", argv[0]);
  } else {
    dprintf(STDERR_FILENO, "spore run: exec %s failed: %s\n", argv[0], strerror(err));
  }
  if (failure_fd >= 0) (void)write_all(failure_fd, "!", 1);
  _exit(exec_failure_code(err));
}

__attribute__((noreturn)) static void exit_session_setup_error(
    int ready_fd, const char *message) {
  char result[256];
  result[0] = 0;
  int n = snprintf(result + 1, sizeof(result) - 1, "%s\n", message);
  size_t result_len = n > 0 && (size_t)n < sizeof(result) - 1
      ? (size_t)n + 1
      : sizeof(result);
  (void)write_all(ready_fd, result, result_len);
  close(ready_fd);
  _exit(126);
}

__attribute__((noreturn)) static void exit_session_setup_errno(
    int ready_fd, const char *step) {
  int saved = errno;
  char message[192];
  snprintf(message, sizeof(message),
           "spore build: RUN sandbox setup failed: %s errno=%d", step, saved);
  exit_session_setup_error(ready_fd, message);
}

int start_session(struct session *session, const char *session_id, char *const argv[], char *const envp[], const char *working_dir, const struct session_start_options *options) {
  memset(session, 0, sizeof(*session));
  session->memory_pressure_fd = -1;
  int use_rootfs = options->use_rootfs;
  int memory_pressure = options->memory_pressure;
  int build_run_isolation = options->build_run_isolation;
  uint64_t nofile_soft = options->nofile_soft;
  uint64_t nofile_hard = options->nofile_hard;
  int stdin_enabled = options->stdin_enabled;
  int tty = options->tty;
  uint16_t terminal_rows = options->terminal_rows;
  uint16_t terminal_cols = options->terminal_cols;
  t_command_start = now_ms();
  t_command_exit = 0;
  t_command_user_us = -1;
  t_command_system_us = -1;
  int stdin_pipe[2] = { -1, -1 };
  int stdout_pipe[2] = { -1, -1 };
  int stderr_pipe[2] = { -1, -1 };
  int pty_master = -1;
  int pty_slave = -1;
  int start_pipe[2] = { -1, -1 };
  int ready_pipe[2] = { -1, -1 };
  if (tty) {
    if (open_session_pty(&pty_master, &pty_slave, terminal_rows, terminal_cols) != 0) {
      t_command_exit = now_ms();
      return 127;
    }
  } else {
    if (pipe2(stdout_pipe, O_CLOEXEC) != 0) {
      t_command_exit = now_ms();
      return 127;
    }
    if (pipe2(stderr_pipe, O_CLOEXEC) != 0) {
      close(stdout_pipe[0]);
      close(stdout_pipe[1]);
      t_command_exit = now_ms();
      return 127;
    }
    if (set_nonblock(stdout_pipe[0]) != 0 || set_nonblock(stderr_pipe[0]) != 0) {
      close(stdout_pipe[0]);
      close(stdout_pipe[1]);
      close(stderr_pipe[0]);
      close(stderr_pipe[1]);
      t_command_exit = now_ms();
      return 127;
    }
  }
  if (stdin_enabled) {
    if (pipe2(stdin_pipe, O_CLOEXEC) != 0) {
      if (pty_master >= 0) close(pty_master);
      if (pty_slave >= 0) close(pty_slave);
      if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
      if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
      if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
      if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
      t_command_exit = now_ms();
      return 127;
    }
    if (set_nonblock(stdin_pipe[1]) != 0) {
      close(stdin_pipe[0]);
      close(stdin_pipe[1]);
      if (pty_master >= 0) close(pty_master);
      if (pty_slave >= 0) close(pty_slave);
      if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
      if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
      if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
      if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
      t_command_exit = now_ms();
      return 127;
    }
  }
  if (pipe2(start_pipe, O_CLOEXEC) != 0) {
    if (stdin_pipe[0] >= 0) close(stdin_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (pty_slave >= 0) close(pty_slave);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
    t_command_exit = now_ms();
    return 127;
  }
  if (pipe2(ready_pipe, O_CLOEXEC) != 0) {
    close(start_pipe[0]);
    close(start_pipe[1]);
    if (stdin_pipe[0] >= 0) close(stdin_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (pty_slave >= 0) close(pty_slave);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
    t_command_exit = now_ms();
    return 127;
  }

  pid_t pid = fork();
  if (pid == 0) {
    close(start_pipe[1]);
    close(ready_pipe[0]);
    char start_byte = 0;
    while (read(start_pipe[0], &start_byte, 1) < 0 && errno == EINTR) {
    }
    if (start_byte != 1) _exit(127);
    if (nofile_hard != 0) {
      struct rlimit nofile_limit;
      nofile_limit.rlim_cur = (rlim_t)nofile_soft;
      nofile_limit.rlim_max = (rlim_t)nofile_hard;
      if (setrlimit(RLIMIT_NOFILE, &nofile_limit) != 0) {
        exit_session_setup_errno(ready_pipe[1], "set nofile limit");
      }
    }
    close(start_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (tty) {
      if (setsid() < 0) _exit(127);
      (void)ioctl(pty_slave, TIOCSCTTY, 0);
      if (dup2(pty_slave, STDIN_FILENO) < 0) _exit(127);
      if (dup2(pty_slave, STDOUT_FILENO) < 0) _exit(127);
      if (dup2(pty_slave, STDERR_FILENO) < 0) _exit(127);
      close(pty_slave);
    } else if (stdin_enabled) {
      if (dup2(stdin_pipe[0], STDIN_FILENO) < 0) _exit(127);
      close(stdin_pipe[0]);
    } else {
      int null_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
      if (null_fd < 0) _exit(127);
      if (dup2(null_fd, STDIN_FILENO) < 0) _exit(127);
      close(null_fd);
    }
    if (!tty) {
      if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0) _exit(127);
      if (dup2(stderr_pipe[1], STDERR_FILENO) < 0) _exit(127);
      close(stdout_pipe[1]);
      close(stderr_pipe[1]);
    }
    if (build_run_isolation) {
      if (!use_rootfs) exit_session_setup_error(ready_pipe[1], "spore build: RUN sandbox requires a rootfs");
      char sandbox_error[192];
      if (spore_build_run_sandbox_enter(
              "/mnt/rootfs", ready_pipe[1], sandbox_error, sizeof(sandbox_error)) != 0) {
        exit_session_setup_error(ready_pipe[1], sandbox_error);
      }
    } else if (use_rootfs) {
      if (chroot("/mnt/rootfs") != 0) _exit(126);
    }
    const char *cwd = working_dir[0] != '\0' ? working_dir : "/";
    if (chdir(cwd) != 0) exit_session_setup_errno(ready_pipe[1], "enter working directory");
    if (write_all(ready_pipe[1], "\1", 1) != 0) _exit(127);
    close(ready_pipe[1]);
    execve_or_report(argv, envp, use_rootfs, -1, options->exec_lookup);
  }
  if (stdin_pipe[0] >= 0) close(stdin_pipe[0]);
  if (pty_slave >= 0) close(pty_slave);
  if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
  if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
  close(start_pipe[0]);
  close(ready_pipe[1]);
  if (pid < 0) {
    close(start_pipe[1]);
    close(ready_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    t_command_exit = now_ms();
    return 127;
  }
  session->build_run_isolation = build_run_isolation;
  session->cancel_on_disconnect = options->cancel_on_disconnect;
  if (((memory_pressure || build_run_isolation || options->cancel_on_disconnect) && setup_session_cgroup(session, pid, memory_pressure) != 0) || write_all(start_pipe[1], "\1", 1) != 0) {
    close(start_pipe[1]);
    close(ready_pipe[0]);
    int cleanup_rc = stop_session_processes(session, pid);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (cleanup_rc != 0) fail_closed_build_run_cleanup("setup");
    t_command_exit = now_ms();
    return 127;
  }
  close(start_pipe[1]);
  unsigned char ready_result[256];
  memset(ready_result, 0, sizeof(ready_result));
  ssize_t ready_read = -1;
  int ready_errno = 0;
  if (build_run_isolation) {
    struct pollfd ready_poll = {
      .fd = ready_pipe[0],
      .events = POLLIN | POLLHUP | POLLERR,
    };
    int poll_result;
    do {
      poll_result = poll(&ready_poll, 1, 5000);
    } while (poll_result < 0 && errno == EINTR);
    if (poll_result > 0) {
      do {
        ready_read = read(ready_pipe[0], ready_result, sizeof(ready_result) - 1);
      } while (ready_read < 0 && errno == EINTR);
      if (ready_read < 0) ready_errno = errno;
    } else if (poll_result == 0) {
      ready_errno = ETIMEDOUT;
    } else {
      ready_errno = errno;
    }
  } else {
    do {
      ready_read = read(ready_pipe[0], ready_result, sizeof(ready_result) - 1);
    } while (ready_read < 0 && errno == EINTR);
    if (ready_read < 0) ready_errno = errno;
  }
  close(ready_pipe[0]);
  if (ready_read != 1 || ready_result[0] != 1) {
    int cleanup_rc = stop_session_processes(session, pid);
    if (ready_read > 1 && ready_result[0] == 0) {
      size_t message_len = (size_t)ready_read - 1;
      if (message_len >= sizeof(session->setup_error)) message_len = sizeof(session->setup_error) - 1;
      memcpy(session->setup_error, ready_result + 1, message_len);
      session->setup_error[message_len] = '\0';
    }
    if (session->setup_error[0] == '\0' && ready_errno == ETIMEDOUT) {
      snprintf(session->setup_error, sizeof(session->setup_error),
               "spore build: RUN sandbox setup timed out\n");
    }
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (pty_master >= 0) close(pty_master);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (cleanup_rc != 0) fail_closed_build_run_cleanup("readiness");
    t_command_exit = now_ms();
    return 127;
  }

  session->started = 1;
  snprintf(session->session_id, sizeof(session->session_id), "%s", session_id);
  session->pid = pid;
  session->stdin_fd = stdin_pipe[1];
  session->terminal_fd = pty_master;
  session->stdout_fd = tty ? pty_master : stdout_pipe[0];
  session->stderr_fd = stderr_pipe[0];
  session->stdin_open = stdin_pipe[1] >= 0;
  session->stdin_capable = stdin_enabled;
  session->tty = tty;
  session->stdout_open = tty ? pty_master >= 0 : 1;
  session->stderr_open = tty ? 0 : 1;
  return 0;
}

void wait_child_blocking(pid_t pid) {
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }
}

int session_cgroup_populated(struct session *session) {
  char path[192];
  if (cgroup_child_path(path, sizeof(path), session->cgroup_path, "cgroup.procs") != 0) return -1;
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  char byte = 0;
  ssize_t n;
  do {
    n = read(fd, &byte, 1);
  } while (n < 0 && errno == EINTR);
  close(fd);
  if (n < 0) return -1;
  return n == 0 ? 0 : 1;
}

void reap_exited_children(void) {
  for (;;) {
    int status = 0;
    pid_t rc = waitpid(-1, &status, WNOHANG);
    if (rc > 0) continue;
    if (rc < 0 && errno == EINTR) continue;
    return;
  }
}

#ifdef SPORE_AGENT_REQUEST_FUZZ
__attribute__((visibility("hidden"))) int spore_agent_test_resolve_exec_path(
    const unsigned char *command_bytes, size_t command_len,
    const unsigned char *path_bytes, size_t path_len, int path_present,
    unsigned char *resolved, size_t resolved_cap) {
  if (command_len == 0 || command_len > MAX_BUILD_EXEC_ARGS_BYTES ||
      path_len > MAX_EXEC_PATH_LEN + 1 || resolved_cap < MAX_EXEC_CANDIDATE_LEN) return EINVAL;
  char command[MAX_BUILD_EXEC_ARGS_BYTES + 1];
  char path[MAX_EXEC_PATH_LEN + 2];
  memcpy(command, command_bytes, command_len);
  command[command_len] = '\0';
  memcpy(path, path_bytes, path_len);
  path[path_len] = '\0';
  if (memchr(command, '\0', command_len) != NULL || memchr(path, '\0', path_len) != NULL) return EINVAL;

  char executable[MAX_EXEC_CANDIDATE_LEN];
  if (resolve_exec_path(command, path_present ? path : NULL, executable, sizeof(executable)) != 0) return errno;
  size_t executable_len = strlen(executable);
  memcpy(resolved, executable, executable_len + 1);
  return 0;
}
#endif
