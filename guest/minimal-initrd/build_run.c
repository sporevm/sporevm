// Build RUN steps: command payload, cache and context mounts, descendant
// cleanup, and WORKDIR.

#include "agent.h"

#define BUILD_CACHE_ROOT "/run/sporevm/build-cache"
#define SPORE_PF_KTHREAD 0x00200000UL

__attribute__((noreturn)) void fail_closed_build_run_cleanup(const char *phase) {
  dprintf(2, "build RUN cleanup could not be verified: %s\n", phase);
  _exit(125);
}

int read_build_command_from_spio(struct client *client, uint64_t command_len, char *command, size_t cap, char *error, size_t error_cap) {
  if (command_len >= cap || command_len > MAX_BUILD_RUN_COMMAND_LEN) {
    snprintf(error, error_cap, "spore build: RUN shell command exceeds limit: limit=%llu bytes actual=%llu bytes\n", (unsigned long long)MAX_BUILD_RUN_COMMAND_LEN, (unsigned long long)command_len);
    return -1;
  }
  uint64_t expected_offset = 0;
  uint64_t received = 0;
  while (received < command_len) {
    uint8_t type = 0;
    uint32_t stream_id = 0;
    uint64_t offset = 0;
    uint32_t payload_len = 0;
    if (read_spio_header_blocking(client->fd, &type, &stream_id, &offset, &payload_len) != 0) {
      snprintf(error, error_cap, "spore build: RUN command payload read failed\n");
      return -1;
    }
    if (type != SPIO_DATA || stream_id != SPIO_STDIN_STREAM || offset != expected_offset) {
      snprintf(error, error_cap, "spore build: RUN command payload frame mismatch: expected_offset=%llu actual_offset=%llu\n", (unsigned long long)expected_offset, (unsigned long long)offset);
      return -1;
    }
    if (received + payload_len > command_len) {
      snprintf(error, error_cap, "spore build: RUN command payload exceeds declared length: limit=%llu bytes actual=%llu bytes\n", (unsigned long long)command_len, (unsigned long long)(received + payload_len));
      return -1;
    }
    if (payload_len > 0 && read_exact(client->fd, command + received, payload_len) != 0) {
      snprintf(error, error_cap, "spore build: RUN command payload read failed\n");
      return -1;
    }
    received += payload_len;
    expected_offset += payload_len;
  }
  uint8_t type = 0;
  uint32_t stream_id = 0;
  uint64_t offset = 0;
  uint32_t payload_len = 0;
  if (read_spio_header_blocking(client->fd, &type, &stream_id, &offset, &payload_len) != 0) {
    snprintf(error, error_cap, "spore build: RUN command payload close missing\n");
    return -1;
  }
  if (payload_len > 0) {
    unsigned char discard[MAX_FRAME_PAYLOAD];
    if (read_exact(client->fd, discard, payload_len) != 0) {
      snprintf(error, error_cap, "spore build: RUN command trailing payload read failed\n");
      return -1;
    }
  }
  if (type != SPIO_CLOSE || stream_id != SPIO_STDIN_STREAM || offset != expected_offset || payload_len != 0) {
    snprintf(error, error_cap, "spore build: RUN command payload has trailing data\n");
    return -1;
  }
  command[command_len] = '\0';
  return 0;
}

int build_workdir_apply(struct client *client, const char *root, const char *path) {
  int exit_code = spore_build_ensure_directory(root, path);
  if (exit_code != SPORE_BUILD_COPY_OK) {
    if (exit_code == SPORE_BUILD_COPY_INVALID) return send_client_error_exit(client, 2, "spore build: invalid WORKDIR path\n");
    if (exit_code == SPORE_BUILD_COPY_UNAVAILABLE) return send_client_error_exit(client, 126, "spore build: rootfs unavailable\n");
    if (errno == ENOSPC) return send_client_error_exit(client, 1, "spore build: SPORE_BUILD_ENOSPC WORKDIR creation failed\n");
    return send_client_error_exit(client, 1, "spore build: WORKDIR creation failed\n");
  }
  return send_client_exit(client, 0);
}

static int parse_proc_stat_kernel_thread(const char *stat) {
  const char *comm_end = strrchr(stat, ')');
  if (comm_end == NULL) return -1;
  char state = 0;
  long ppid = 0;
  long pgrp = 0;
  long session = 0;
  long tty_nr = 0;
  long tpgid = 0;
  unsigned long flags = 0;
  if (sscanf(comm_end + 1, " %c %ld %ld %ld %ld %ld %lu", &state, &ppid, &pgrp, &session, &tty_nr, &tpgid, &flags) != 7) return -1;
  return (flags & SPORE_PF_KTHREAD) != 0;
}

static int process_is_kernel_thread(const char *pid_name) {
  char path[64];
  int path_len = snprintf(path, sizeof(path), "%s/stat", pid_name);
  if (path_len <= 0 || (size_t)path_len >= sizeof(path)) return -1;
  int fd = openat(proc_dir_fd, path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return errno == ENOENT ? 1 : -1;
  char stat[4096];
  ssize_t n;
  do {
    n = read(fd, stat, sizeof(stat) - 1);
  } while (n < 0 && errno == EINTR);
  close(fd);
  if (n <= 0) return -1;
  stat[n] = '\0';
  return parse_proc_stat_kernel_thread(stat);
}

static int kill_other_userspace_processes(void) {
  if (proc_dir_fd < 0) return -1;
  int scan_fd = openat(proc_dir_fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (scan_fd < 0) return -1;
  DIR *proc = fdopendir(scan_fd);
  if (proc == NULL) {
    close(scan_fd);
    return -1;
  }
  pid_t self = getpid();
  int found = 0;
  struct dirent *entry;
  while ((entry = readdir(proc)) != NULL) {
    char *end = NULL;
    errno = 0;
    long value = strtol(entry->d_name, &end, 10);
    if (errno != 0 || end == entry->d_name || *end != '\0' || value <= 0 || value > INT32_MAX) continue;
    pid_t pid = (pid_t)value;
    if (pid == self) continue;
    int is_kernel_thread = process_is_kernel_thread(entry->d_name);
    if (is_kernel_thread != 0) {
      if (is_kernel_thread > 0) continue;
      closedir(proc);
      return -1;
    }
    found = 1;
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
      closedir(proc);
      return -1;
    }
  }
  closedir(proc);
  return found;
}

static int clean_build_run_processes(struct session *session) {
  if (session->cgroup_path[0] == '\0') return -1;

  char path[192];
  if (cgroup_child_path(path, sizeof(path), session->cgroup_path, "cgroup.kill") != 0 ||
      write_text_file(path, "1\n") != 0) {
    dprintf(2, "build RUN cleanup failed: kill cgroup errno=%d\n", errno);
    return -1;
  }

  int64_t deadline = now_ms() + 5000;
  for (;;) {
    int populated = session_cgroup_populated(session);
    if (populated == 0) break;
    if (populated < 0) {
      dprintf(2, "build RUN cleanup failed: read cgroup processes errno=%d\n", errno);
      return -1;
    }
    if (now_ms() >= deadline) {
      dprintf(2, "build RUN cleanup failed: cgroup remained populated\n");
      return -1;
    }
    usleep(1000);
  }

  if (!session->exited) {
    wait_child_blocking(session->pid);
    session->exited = 1;
  }
  for (;;) {
    reap_exited_children();
    int found = kill_other_userspace_processes();
    if (found == 0) break;
    if (found < 0) {
      dprintf(2, "build RUN cleanup failed: scan guest processes errno=%d\n", errno);
      return -1;
    }
    if (now_ms() >= deadline) {
      dprintf(2, "build RUN cleanup failed: guest processes remained alive\n");
      return -1;
    }
    usleep(1000);
  }
  reap_exited_children();
  if (rmdir(session->cgroup_path) != 0 && errno != ENOENT) {
    dprintf(2, "build RUN cleanup failed: remove cgroup errno=%d\n", errno);
    return -1;
  }
  session->cgroup_path[0] = '\0';
  return 0;
}

int build_run_mount_cleanup_poisoned = 0;

void poison_build_run_mount_cleanup(const char *phase) {
  dprintf(2, "build RUN mount cleanup could not be verified: %s\n", phase);
  build_run_mount_cleanup_poisoned = 1;
}

static int build_cache_fd_path(char *out, size_t cap, int fd) {
  int n = snprintf(out, cap, "/proc/self/fd/%d", fd);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

int cleanup_build_cache_mounts(struct build_cache_mount_state *state, const char *root) {
  int failed = 0;
  for (size_t i = state->count; i > 0; i--) {
    size_t index = i - 1;
    if (state->mounts[index].bound) {
      char target_fd_path[64];
      if (build_cache_fd_path(target_fd_path, sizeof(target_fd_path), state->mounts[index].target_fd) != 0 ||
          umount2(target_fd_path, 0) != 0) failed = 1;
      state->mounts[index].bound = 0;
    }
  }
  if (state->cache_root_fd >= 0 && syncfs(state->cache_root_fd) != 0) failed = 1;
  for (size_t i = 0; i < state->count; i++) {
    if (state->mounts[i].source_fd >= 0 && close(state->mounts[i].source_fd) != 0) failed = 1;
    if (state->mounts[i].target_fd >= 0 && close(state->mounts[i].target_fd) != 0) failed = 1;
    state->mounts[i].source_fd = -1;
    state->mounts[i].target_fd = -1;
  }
  if (state->cache_root_fd >= 0 && close(state->cache_root_fd) != 0) failed = 1;
  state->cache_root_fd = -1;
  if (state->cache_mounted && umount2(BUILD_CACHE_ROOT, 0) != 0) failed = 1;
  state->cache_mounted = 0;
  for (size_t i = state->count; i > 0; i--) {
    size_t index = i - 1;
    if (state->mounts[index].target_cleanup_required &&
        spore_build_cache_target_cleanup(root, state->mounts[index].target,
                                         &state->mounts[index].target_identity,
                                         state->mounts[index].created_component_ids,
                                         state->mounts[index].created_components) != 0) failed = 1;
    state->mounts[index].target_cleanup_required = 0;
    state->mounts[index].created_components = 0;
  }
  state->count = 0;
  return failed ? -1 : 0;
}

int setup_build_cache_mounts(const struct run_request *request, const char *root,
                                    int has_context, int build_input_count,
                                    struct build_cache_mount_state *state,
                                    char *error, size_t error_cap) {
  memset(state, 0, sizeof(*state));
  state->cache_root_fd = -1;
  for (size_t i = 0; i < MAX_BUILD_CACHE_MOUNTS; i++) {
    state->mounts[i].source_fd = -1;
    state->mounts[i].target_fd = -1;
  }
  if (request->build_cache_mount_count == 0) return 0;
  mkdir("/run/sporevm", 0755);
  mkdir(BUILD_CACHE_ROOT, 0755);
  char device[32];
  int letter = 'b' + has_context + build_input_count;
  int dn = snprintf(device, sizeof(device), "/dev/vd%c", letter);
  if (dn <= 0 || (size_t)dn >= sizeof(device) || wait_for_path(device, 100, 50000) != 0) {
    snprintf(error, error_cap, "spore build: cache mount block device unavailable\n");
    return -1;
  }
  if (mount(device, BUILD_CACHE_ROOT, "ext4", 0, "") != 0) {
    snprintf(error, error_cap, "spore build: cache mount filesystem unavailable\n");
    return -1;
  }
  state->cache_mounted = 1;
  state->cache_root_fd = open(BUILD_CACHE_ROOT, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (state->cache_root_fd < 0) goto fail;

  for (size_t i = 0; i < request->build_cache_mount_count; i++) {
    state->count = i + 1;
    snprintf(state->mounts[i].target, sizeof(state->mounts[i].target), "%s",
             request->build_cache_mounts[i].target);
    if (mkdirat(state->cache_root_fd, request->build_cache_mounts[i].key, 0755) != 0 && errno != EEXIST) goto fail;
    state->mounts[i].source_fd = openat(state->cache_root_fd, request->build_cache_mounts[i].key,
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (state->mounts[i].source_fd < 0) goto fail;
    if (spore_build_cache_target_prepare(root, state->mounts[i].target,
                                         &state->mounts[i].target_fd,
                                         &state->mounts[i].target_identity,
                                         state->mounts[i].created_component_ids,
                                         &state->mounts[i].created_components) != 0) {
      state->mounts[i].target_cleanup_required = state->mounts[i].created_components != 0;
      goto fail;
    }
    state->mounts[i].target_cleanup_required = 1;
    char source_fd_path[64];
    char target_fd_path[64];
    if (build_cache_fd_path(source_fd_path, sizeof(source_fd_path), state->mounts[i].source_fd) != 0 ||
        build_cache_fd_path(target_fd_path, sizeof(target_fd_path), state->mounts[i].target_fd) != 0 ||
        mount(source_fd_path, target_fd_path, NULL, MS_BIND, NULL) != 0) goto fail;
    state->mounts[i].bound = 1;
  }
  return 0;

fail:
  snprintf(error, error_cap, "spore build: cache mount setup failed\n");
  if (cleanup_build_cache_mounts(state, root) != 0) {
    poison_build_run_mount_cleanup("cache setup");
    snprintf(error, error_cap, "spore build: RUN cache mount cleanup failed\n");
    return -2;
  }
  return -1;
}

static int cleanup_build_context_binds(struct build_context_bind_mount_state *state, const char *root) {
  int failed = 0;
  for (size_t i = state->count; i > 0; i--) {
    size_t index = i - 1;
    if (state->mounts[index].bound) {
      char target_fd_path[64];
      if (build_cache_fd_path(target_fd_path, sizeof(target_fd_path), state->mounts[index].target_fd) != 0 ||
          umount2(target_fd_path, 0) != 0) failed = 1;
      state->mounts[index].bound = 0;
    }
  }
  for (size_t i = 0; i < state->count; i++) {
    if (state->mounts[i].source_fd >= 0 && close(state->mounts[i].source_fd) != 0) failed = 1;
    if (state->mounts[i].target_fd >= 0 && close(state->mounts[i].target_fd) != 0) failed = 1;
    state->mounts[i].source_fd = -1;
    state->mounts[i].target_fd = -1;
  }
  for (size_t i = state->count; i > 0; i--) {
    size_t index = i - 1;
    if (state->mounts[index].target_cleanup_required &&
        spore_build_context_bind_target_cleanup(
            root, state->mounts[index].target, state->mounts[index].target_created,
            &state->mounts[index].target_identity,
            state->mounts[index].created_component_ids,
            state->mounts[index].created_components) != 0) failed = 1;
    state->mounts[index].target_cleanup_required = 0;
    state->mounts[index].created_components = 0;
  }
  state->count = 0;
  return failed ? -1 : 0;
}

int setup_build_context_binds(const struct run_request *request, const char *root,
                                     int build_context_requested, int build_context_ready,
                                     struct build_context_bind_mount_state *state,
                                     char *error, size_t error_cap) {
  int setup_cleanup_uncertain = 0;
  memset(state, 0, sizeof(*state));
  for (size_t i = 0; i < MAX_BUILD_CONTEXT_BINDS; i++) {
    state->mounts[i].source_fd = -1;
    state->mounts[i].target_fd = -1;
  }
  if (request->build_context_bind_count == 0) return 0;
  if (!build_context_requested || !build_context_ready) {
    snprintf(error, error_cap, "spore build: context bind source unavailable\n");
    return -1;
  }
  for (size_t i = 0; i < request->build_context_bind_count; i++) {
    state->count = i + 1;
    snprintf(state->mounts[i].target, sizeof(state->mounts[i].target), "%s",
             request->build_context_binds[i].target);
    int source_rc = spore_build_context_bind_source_open(
        BUILD_CONTEXT_ROOT, request->build_context_binds[i].source);
    if (source_rc < 0) {
      setup_cleanup_uncertain = source_rc == -2;
      goto fail;
    }
    state->mounts[i].source_fd = source_rc;
    int prepare_rc = spore_build_context_bind_target_prepare(
            root, state->mounts[i].target,
            &state->mounts[i].target_fd,
            &state->mounts[i].target_created,
            &state->mounts[i].target_identity,
            state->mounts[i].created_component_ids,
            &state->mounts[i].created_components);
    if (prepare_rc != 0) {
      setup_cleanup_uncertain = prepare_rc == -2;
      goto fail;
    }
    state->mounts[i].target_cleanup_required = 1;
    char source_fd_path[64];
    char target_fd_path[64];
    if (build_cache_fd_path(source_fd_path, sizeof(source_fd_path), state->mounts[i].source_fd) != 0 ||
        build_cache_fd_path(target_fd_path, sizeof(target_fd_path), state->mounts[i].target_fd) != 0 ||
        mount(source_fd_path, target_fd_path, NULL, MS_BIND, NULL) != 0) {
      goto fail;
    }
    state->mounts[i].bound = 1;
    char target_path[MAX_COPY_FULL_PATH_LEN];
    int target_n = snprintf(target_path, sizeof(target_path), "%s%s", root, state->mounts[i].target);
    if (target_n <= 0 || (size_t)target_n >= sizeof(target_path) ||
        mount(NULL, target_path, NULL, MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV, NULL) != 0) goto fail;
  }
  return 0;

fail:
  snprintf(error, error_cap, "spore build: context bind mount setup failed\n");
  if (cleanup_build_context_binds(state, root) != 0) {
    poison_build_run_mount_cleanup("context bind setup");
    snprintf(error, error_cap, "spore build: RUN mount cleanup failed\n");
    return -2;
  }
  if (setup_cleanup_uncertain) {
    poison_build_run_mount_cleanup("context bind setup ownership");
    snprintf(error, error_cap, "spore build: RUN mount cleanup failed\n");
    return -2;
  }
  return -1;
}

static int cleanup_build_run_mounts(struct build_context_bind_mount_state *bind_state,
                                    struct build_cache_mount_state *cache_state,
                                    const char *root) {
  int bind_rc = cleanup_build_context_binds(bind_state, root);
  int cache_rc = cleanup_build_cache_mounts(cache_state, root);
  return bind_rc != 0 || cache_rc != 0 ? -1 : 0;
}

void run_build_exec(struct client *client, const struct run_request *request, char *command, int use_rootfs,
                           struct build_cache_mount_state *cache_state,
                           struct build_context_bind_mount_state *bind_state,
                           const char *root) {
  char *argv[4];
  char *const *effective_argv = request->argv;
  if (!request->build_exec_form) {
    argv[0] = "/bin/sh";
    argv[1] = "-c";
    argv[2] = command;
    argv[3] = NULL;
    effective_argv = argv;
  }

  struct session transient;
  const struct session_start_options options = {
    .use_rootfs = use_rootfs,
    .build_run_isolation = 1,
    .exec_lookup = request->build_exec_form ? EXEC_LOOKUP_PATH : EXEC_LOOKUP_EXACT,
    .nofile_soft = request->nofile_soft,
    .nofile_hard = request->nofile_hard,
    .terminal_rows = request->terminal_rows,
    .terminal_cols = request->terminal_cols,
  };
  int rc = start_session(&transient, request->session_id, effective_argv, request->envp, request->working_dir, &options);
  if (rc != 0) {
    int mount_cleanup_rc = cleanup_build_run_mounts(bind_state, cache_state, root);
    if (mount_cleanup_rc != 0) {
      poison_build_run_mount_cleanup("RUN setup");
      (void)send_client_error_exit(client, 125, "spore build: RUN mount cleanup failed\n");
    } else {
      (void)send_client_error_exit(
          client, rc, transient.setup_error[0] != '\0' ? transient.setup_error :
          "spore build: RUN exec setup failed\n");
    }
    close_client(client);
    return;
  }

  int descendants_cleaned = 0;
  while (client->fd >= 0 && (!transient.exited || transient.stdout_open || transient.stderr_open)) {
    struct pollfd fds[4];
    int roles[4];
    nfds_t nfds = 0;
    if (transient.stdout_open) {
      fds[nfds].fd = transient.stdout_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 1;
    }
    if (transient.stderr_open) {
      fds[nfds].fd = transient.stderr_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 2;
    }
    if (sigchld_pipe[0] >= 0) {
      fds[nfds].fd = sigchld_pipe[0];
      fds[nfds].events = POLLIN;
      fds[nfds].revents = 0;
      roles[nfds++] = 4;
    }
    fds[nfds].fd = client->fd;
    fds[nfds].events = POLLHUP | POLLERR;
    fds[nfds].revents = 0;
    roles[nfds++] = 3;

    int pr = poll(fds, nfds, 100);
    if (pr > 0) {
      for (nfds_t i = 0; i < nfds; i++) {
        if (fds[i].revents == 0) continue;
        if (roles[i] == 1) {
          pump_session_stream(&transient, client, 1);
        } else if (roles[i] == 2) {
          pump_session_stream(&transient, client, 0);
        } else if (roles[i] == 3 && (fds[i].revents & (POLLHUP | POLLERR))) {
          close_client(client);
        } else if (roles[i] == 4) {
          drain_sigchld_wakeup();
        }
      }
    }
    poll_session_exit(&transient, client);
    if (transient.exited && !descendants_cleaned) {
      if (clean_build_run_processes(&transient) != 0) {
        (void)send_client_error_exit(client, 125, "spore build: RUN descendant cleanup failed\n");
        close_client(client);
        fail_closed_build_run_cleanup("command exit");
      }
      descendants_cleaned = 1;
      if (cleanup_build_run_mounts(bind_state, cache_state, root) != 0) {
        poison_build_run_mount_cleanup("command exit");
        (void)send_client_error_exit(client, 125, "spore build: RUN mount cleanup failed\n");
        close_client(client);
        break;
      }
    }
    if (descendants_cleaned) maybe_send_session_exit(&transient, client);
  }

  if (client->fd < 0 && transient.started && !descendants_cleaned) {
    if (clean_build_run_processes(&transient) != 0) {
      fail_closed_build_run_cleanup("control loss");
    }
  }
  if (cache_state->count != 0 || cache_state->cache_mounted || bind_state->count != 0) {
    if (cleanup_build_run_mounts(bind_state, cache_state, root) != 0) {
      poison_build_run_mount_cleanup("control loss");
    }
  }
  reset_session(&transient);
}

#ifdef SPORE_AGENT_REQUEST_FUZZ
__attribute__((visibility("hidden"))) int spore_agent_fuzz_proc_stat(
    const unsigned char *stat_bytes, size_t stat_len) {
  if (stat_len >= 4096) return -1;
  char stat[4096];
  memcpy(stat, stat_bytes, stat_len);
  stat[stat_len] = '\0';
  return parse_proc_stat_kernel_thread(stat);
}
#endif
