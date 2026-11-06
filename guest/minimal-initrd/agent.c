// The guest agent runs as /init: it sets up the guest, then serves host
// requests over vsock from one event loop.

#include "agent.h"

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xffffffffU
#endif
#define BUILD_AGENT_FD_BUDGET SPORE_BUILD_COPY_FD_BUDGET

struct sockaddr_vm {
  sa_family_t svm_family;
  unsigned short svm_reserved1;
  unsigned int svm_port;
  unsigned int svm_cid;
  unsigned char svm_zero[sizeof(struct sockaddr) - sizeof(sa_family_t) - sizeof(unsigned short) - sizeof(unsigned int) - sizeof(unsigned int)];
};

int64_t t_init_start = 0;
int64_t t_listen_ready = 0;
int64_t t_request_accept = 0;
int64_t t_request_decode = 0;
int64_t t_command_start = 0;
int64_t t_command_exit = 0;
int64_t t_command_user_us = -1;
int64_t t_command_system_us = -1;

int proc_dir_fd = -1;

static int listen_vsock(uint32_t port) {
  int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  struct sockaddr_vm sa;
  memset(&sa, 0, sizeof(sa));
  sa.svm_family = AF_VSOCK;
  sa.svm_cid = VMADDR_CID_ANY;
  sa.svm_port = port;
  if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
    close(fd);
    return -1;
  }
  if (listen(fd, 16) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static void accept_request(int listener, struct session *session, struct client *client, struct detached_children *detached, struct generation_monitor *generation, const char *generation_root, int use_rootfs, int rootfs_writable, int rootfs_growth_session, int rootfs_ready, const char *rootfs_error, int build_context_requested, int build_context_ready, const char *build_context_error, int build_input_count, int build_inputs_ready, const char *build_inputs_error, int network_requested, int network_ready, const char *network_error) {
  int conn = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
  if (conn < 0) {
    if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
      dprintf(2, "accept failed: errno=%d\n", errno);
    }
    return;
  }
  t_request_accept = now_ms();

  char req[MAX_REQUEST];
  ssize_t req_len = read_line(conn, req, sizeof(req));
  if (req_len <= 0) {
    close(conn);
    return;
  }
  t_request_decode = now_ms();

  struct run_request request;
  if (parse_request(req, (size_t)req_len, &request) != 0) {
    // Keep the attached client; answer only the rejected connection.
    struct client rejected;
    memset(&rejected, 0, sizeof(rejected));
    rejected.fd = conn;
    (void)send_client_error_exit(&rejected, 2, "spore run: bad request\n");
    close(conn);
    return;
  }

  close_client(client);
  client->fd = conn;
  client->stdin_input_owner = request.stdin_enabled;
  client->terminal_input_owner = request.tty && (request.kind == REQUEST_START || request.interactive);

  if (build_run_mount_cleanup_poisoned) {
    (void)send_client_error_exit(client, 125, "spore build: prior RUN mount cleanup failed\n");
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_READY) {
    if (use_rootfs && !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    if (network_requested && !network_ready) {
      (void)send_client_error_exit(client, 126, network_error[0] != '\0' ? network_error : "spore run: network unavailable\n");
      close_client(client);
      return;
    }
    (void)send_client_exit(client, 0);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_INITIAL_OUTPUT) {
    (void)send_retained_output(client, detached);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_COPY_IN || request.kind == REQUEST_COPY_OUT) {
    if (use_rootfs && !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = use_rootfs && rootfs_ready ? "/mnt/rootfs" : "";
    if (request.kind == REQUEST_COPY_IN) {
      (void)copy_in_file(client, root, request.copy_path);
    } else {
      (void)copy_out_file(client, root, request.copy_path);
    }
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_BUILD_RUN) {
    if (!use_rootfs || !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    char command[MAX_BUILD_RUN_COMMAND_LEN + 1];
    char error[256];
    error[0] = '\0';
    if (!request.build_exec_form && read_build_command_from_spio(client, request.build_command_len, command, sizeof(command), error, sizeof(error)) != 0) {
      (void)send_client_error_exit(client, 2, error[0] != '\0' ? error : "spore build: RUN command payload invalid\n");
      close_client(client);
      return;
    }
    struct build_cache_mount_state cache_state;
    struct build_context_bind_mount_state bind_state;
    const char *root = "/mnt/rootfs";
    int cache_setup_rc = setup_build_cache_mounts(&request, root, build_context_requested, build_input_count,
                                                  &cache_state, error, sizeof(error));
    if (cache_setup_rc != 0) {
      (void)send_client_error_exit(client, cache_setup_rc == -2 ? 125 : 126,
                                   error[0] != '\0' ? error : "spore build: cache mount setup failed\n");
      close_client(client);
      return;
    }
    int bind_setup_rc = setup_build_context_binds(&request, root, build_context_requested, build_context_ready,
                                                  &bind_state, error, sizeof(error));
    if (bind_setup_rc != 0) {
      if (cleanup_build_cache_mounts(&cache_state, root) != 0) {
        poison_build_run_mount_cleanup("context bind setup cache rollback");
        bind_setup_rc = -2;
        snprintf(error, sizeof(error), "spore build: RUN mount cleanup failed\n");
      }
      (void)send_client_error_exit(client, bind_setup_rc == -2 ? 125 : 126,
                                   error[0] != '\0' ? error : "spore build: context bind mount setup failed\n");
      close_client(client);
      return;
    }
    apply_resume_clock(request.resume_time_unix_ns);
    run_build_exec(client, &request, command, use_rootfs, &cache_state, &bind_state, root);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_BUILD_COPY) {
    if (!use_rootfs || !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    char source_root[64];
    if (request.copy_source_disk == COPY_SOURCE_CONTEXT) {
      if (!build_context_requested || !build_context_ready) {
        (void)send_client_error_exit(client, 126, build_context_error[0] != '\0' ? build_context_error : "spore build: context disk unavailable\n");
        close_client(client);
        return;
      }
      snprintf(source_root, sizeof(source_root), "%s", BUILD_CONTEXT_ROOT);
    } else {
      if (!build_inputs_ready || request.copy_input_index >= (uint64_t)build_input_count) {
        (void)send_client_error_exit(client, 126, build_inputs_error[0] != '\0' ? build_inputs_error : "spore build: input disk unavailable\n");
        close_client(client);
        return;
      }
      int n = snprintf(source_root, sizeof(source_root), "%s/%llu", BUILD_INPUT_ROOT, (unsigned long long)request.copy_input_index);
      if (n <= 0 || (size_t)n >= sizeof(source_root)) {
        (void)send_client_error_exit(client, 2, "spore build: input disk path is too long\n");
        close_client(client);
        return;
      }
    }
    char error[384];
    int exit_code = spore_build_copy_apply(
        "/mnt/rootfs", source_root,
        request.copy_source, request.copy_dest,
        request.copy_source_kind, request.copy_dest_is_dir,
        request.copy_entry_count,
        request.copy_destination_policy,
        request.copy_mtime_present, request.copy_mtime_unix_seconds,
        error, sizeof(error));
    if (exit_code == SPORE_BUILD_COPY_OK) {
      (void)send_client_exit(client, 0);
    } else {
      (void)send_client_error_exit(client, exit_code, error[0] != '\0' ? error : "spore build: COPY apply failed\n");
    }
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_BUILD_WORKDIR) {
    if (!use_rootfs || !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    (void)build_workdir_apply(client, "/mnt/rootfs", request.working_dir);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_ROOTFS_GROW) {
    if (!use_rootfs || !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    if (!rootfs_writable || !rootfs_growth_session) {
      (void)send_client_error_exit(client, 126, "spore build: rootfs growth is not enabled\n");
      close_client(client);
      return;
    }
    (void)grow_rootfs(client);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_FSFREEZE || request.kind == REQUEST_FSTHAW) {
    if (!use_rootfs || !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    (void)freeze_or_thaw_rootfs(client, request.kind == REQUEST_FSFREEZE);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_START) {
    if (use_rootfs && !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    if (network_requested && !network_ready) {
      (void)send_client_error_exit(client, 126, network_error[0] != '\0' ? network_error : "spore run: network unavailable\n");
      close_client(client);
      return;
    }
    if (request.generation_params[0] != '\0') {
      const char *root = generation_root_path(use_rootfs, rootfs_ready);
      const char *generation_error = apply_request_generation(generation, root, request.generation_params);
      if (generation_error != NULL) {
        (void)send_client_error_exit(client, 126, generation_error);
        close_client(client);
        return;
      }
    } else if (request.require_generation_ready && ensure_generation_ready(generation, generation_root) != 0) {
      (void)send_client_error_exit(client, 126, "spore run: generation metadata unavailable\n");
      close_client(client);
      return;
    }
    apply_resume_clock(request.resume_time_unix_ns);
    if (request.detached) {
      int rc = start_detached(request.argv, request.envp, request.working_dir, use_rootfs,
                              request.retain_output, detached);
      if (rc != 0) {
        (void)send_client_error_exit(client, rc, "spore run: exec setup failed\n");
        close_client(client);
        return;
      }
      (void)send_client_exit(client, 0);
      close_client(client);
      return;
    }
    int file_stdio = 0;
    if (session->started) {
      if (strcmp(request.session_id, session->session_id) == 0) {
        (void)attach_client(session, client, request.stdout_offset, request.stderr_offset);
        return;
      }
      if (!session_finished(session)) {
        run_transient_exec(session, client, &request, use_rootfs);
        return;
      }
      // ponytail: completed-base resumes lose pipe wakeups under ReleaseSafe; keep the file fallback resumed-only.
      file_stdio = request.tty ? 0 : 1;
      reset_session(session);
    }
    const struct session_start_options options = {
      .use_rootfs = use_rootfs,
      .file_stdio = file_stdio,
      .memory_pressure = request.memory_pressure,
      .exec_lookup = EXEC_LOOKUP_PATH,
      .stdin_enabled = request.stdin_enabled,
      .tty = request.tty,
      .terminal_rows = request.terminal_rows,
      .terminal_cols = request.terminal_cols,
    };
    int rc = start_session(session, request.session_id, request.argv, request.envp, request.working_dir, &options);
    if (rc != 0) {
      (void)send_client_error_exit(client, rc, "spore run: exec setup failed\n");
      close_client(client);
      return;
    }
    client->stdout_offset = 0;
    client->stderr_offset = 0;
    return;
  }

  if (!session->started || strcmp(request.session_id, session->session_id) != 0) {
    (void)send_client_error_exit(client, 2, "spore run: no session\n");
    close_client(client);
    return;
  }

  if (request.generation_params[0] != '\0') {
    if (use_rootfs && !rootfs_ready) {
      (void)send_client_error_exit(client, 126, rootfs_error[0] != '\0' ? rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = generation_root_path(use_rootfs, rootfs_ready);
    const char *generation_error = apply_request_generation(generation, root, request.generation_params);
    if (generation_error != NULL) {
      (void)send_client_error_exit(client, 126, generation_error);
      close_client(client);
      return;
    }
  }
  if (request.stdin_enabled) {
    if (!session->stdin_capable) {
      (void)send_client_error_exit(client, 2, "spore run: captured session has no interactive stdin\n");
      close_client(client);
      return;
    }
    if (!session->stdin_open) {
      (void)send_client_error_exit(client, 2, "spore run: captured session stdin is closed\n");
      close_client(client);
      return;
    }
    (void)attach_client(session, client, request.stdout_offset, request.stderr_offset);
    return;
  }
  if (request.tty) {
    if (!session->tty) {
      (void)send_client_error_exit(client, 2, "spore run: captured session has no terminal\n");
      close_client(client);
      return;
    }
    if (request.interactive && session->terminal_fd < 0) {
      (void)send_client_error_exit(client, 2, "spore run: captured session terminal is closed\n");
      close_client(client);
      return;
    }
    if (session->terminal_fd >= 0) {
      (void)apply_terminal_size(session->terminal_fd, request.terminal_rows, request.terminal_cols);
    }
    if (session->exited && !session->stdout_open) {
      (void)send_client_exit(client, session->exit_code);
      close_client(client);
    }
    return;
  }
  (void)attach_client(session, client, request.stdout_offset, request.stderr_offset);
}

#ifndef SPORE_AGENT_REQUEST_FUZZ
int main(void) {
  t_init_start = now_ms();
  mount_proc();
  proc_dir_fd = open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (proc_dir_fd < 0) {
    dprintf(2, "open proc failed: errno=%d\n", errno);
    return 1;
  }
  mount_sysfs();
  mount_cgroup2_if_dir("/sys/fs/cgroup");
  prepare_dev();
  mkdir("/run", 0755);
  char cmdline[1024];
  read_cmdline(cmdline, sizeof(cmdline));
  int use_rootfs = cmdline_has_flag_in(cmdline, "spore_rootfs=1");
  int rootfs_writable = cmdline_has_flag_in(cmdline, "spore_rootfs_rw=1");
  int rootfs_growth_session = cmdline_has_flag_in(cmdline, "spore_rootfs_growth=1");
  int rootfs_noinit_itable = cmdline_has_flag_in(cmdline, "spore_rootfs_noinit_itable=1");
  int use_build_context = cmdline_has_flag_in(cmdline, "spore_build_context=1");
  int build_input_count = resolve_build_input_count(cmdline);
  int build_mode = cmdline_has_flag_in(cmdline, "spore_build=1");
  if (build_mode && spore_build_copy_ensure_fd_budget() != 0) {
    dprintf(2, "build agent fd budget unavailable: required=%llu errno=%d\n", (unsigned long long)BUILD_AGENT_FD_BUDGET, errno);
    return 1;
  }
  int use_network = cmdline_has_flag_in(cmdline, "spore_net=1");
  int listener = listen_vsock(resolve_port_from_cmdline(cmdline));
  if (listener < 0) {
    dprintf(2, "listen vsock failed: errno=%d\n", errno);
    return 1;
  }
  (void)set_nonblock(listener);
  t_listen_ready = now_ms();

  int rootfs_ready = 1;
  char rootfs_error[128];
  rootfs_error[0] = '\0';
  if (use_rootfs && setup_rootfs(rootfs_writable, rootfs_growth_session, rootfs_noinit_itable, build_mode, rootfs_error, sizeof(rootfs_error)) != 0) {
    rootfs_ready = 0;
    dprintf(2, "%s\n", rootfs_error);
    size_t len = strlen(rootfs_error);
    if (len + 1 < sizeof(rootfs_error)) {
      rootfs_error[len] = '\n';
      rootfs_error[len + 1] = '\0';
    }
  }
  int build_context_ready = 1;
  char build_context_error[160];
  build_context_error[0] = '\0';
  if (use_build_context && setup_build_context(build_context_error, sizeof(build_context_error)) != 0) {
    build_context_ready = 0;
    dprintf(2, "%s\n", build_context_error);
    size_t len = strlen(build_context_error);
    if (len + 1 < sizeof(build_context_error)) {
      build_context_error[len] = '\n';
      build_context_error[len + 1] = '\0';
    }
  }
  int build_inputs_ready = build_input_count >= 0;
  char build_inputs_error[192];
  build_inputs_error[0] = '\0';
  if (build_input_count < 0) {
    snprintf(build_inputs_error, sizeof(build_inputs_error), "invalid build input count");
    build_input_count = 0;
  } else if (build_input_count > 0 && setup_build_inputs(build_input_count, use_build_context, build_inputs_error, sizeof(build_inputs_error)) != 0) {
    build_inputs_ready = 0;
    dprintf(2, "%s\n", build_inputs_error);
    size_t len = strlen(build_inputs_error);
    if (len + 1 < sizeof(build_inputs_error)) {
      build_inputs_error[len] = '\n';
      build_inputs_error[len + 1] = '\0';
    }
  }
  int network_ready = 1;
  char network_error[160];
  network_error[0] = '\0';
  if (use_network && setup_network(use_rootfs, build_mode, network_error, sizeof(network_error)) != 0) {
    network_ready = 0;
    dprintf(2, "%s\n", network_error);
    size_t len = strlen(network_error);
    if (len + 1 < sizeof(network_error)) {
      network_error[len] = '\n';
      network_error[len + 1] = '\0';
    }
  }
  if (setup_sigchld_wakeup() != 0) {
    dprintf(2, "sigchld wakeup setup failed: errno=%d\n", errno);
    return 1;
  }

  struct session session;
  memset(&session, 0, sizeof(session));
  session.stdin_fd = -1;
  session.terminal_fd = -1;
  session.stdout_fd = -1;
  session.stderr_fd = -1;
  session.memory_pressure_fd = -1;
  struct client client;
  memset(&client, 0, sizeof(client));
  client.fd = -1;
  struct detached_children detached;
  memset(&detached, 0, sizeof(detached));
  detached.retained_pid = -1;
  detached.retained_stdout_fd = -1;
  detached.retained_stderr_fd = -1;
  struct generation_monitor generation;
  memset(&generation, 0, sizeof(generation));
  generation.last_generation = UINT64_MAX;
  const char *generation_root = generation_root_path(use_rootfs, rootfs_ready);

  for (;;) {
    reap_detached_children(&detached);
    drain_retained_output(&detached);
    if (!use_rootfs || rootfs_ready) {
      (void)poll_generation(&generation, generation_root);
    }
    if (session.file_stdio && !session.exited) {
      pump_session_file(&session, &client, 1);
      pump_session_file(&session, &client, 0);
      poll_session_exit(&session, &client);
      maybe_send_session_exit(&session, &client);
    }

    struct pollfd fds[10];
    int roles[10];
    nfds_t nfds = 0;
    fds[nfds].fd = listener;
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    roles[nfds++] = 0;
    if (client.fd >= 0) {
      fds[nfds].fd = client.fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 1;
    }
    add_session_output_fds(&session, fds, roles, &nfds, 2);
    fds[nfds].fd = sigchld_pipe[0];
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    roles[nfds++] = 4;
    if (session.memory_pressure_fd >= 0) {
      fds[nfds].fd = session.memory_pressure_fd;
      fds[nfds].events = POLLPRI | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 5;
    }
    if (session.stdin_open && session.stdin_pending_len != 0) {
      fds[nfds].fd = session.stdin_fd;
      fds[nfds].events = POLLOUT | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 6;
    }
    if (detached.retained_stdout_fd >= 0) {
      fds[nfds].fd = detached.retained_stdout_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 7;
    }
    if (detached.retained_stderr_fd >= 0) {
      fds[nfds].fd = detached.retained_stderr_fd;
      fds[nfds].events = POLLIN | POLLHUP | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 8;
    }

    int poll_timeout_ms = session.file_stdio && session.started && !session.exited ? 10 : 100;
    int pr = poll(fds, nfds, poll_timeout_ms);
    if (pr < 0 && errno != EINTR) continue;
    if (pr > 0) {
      for (nfds_t i = 0; i < nfds; i++) {
        if (fds[i].revents == 0) continue;
        if (roles[i] == 0 && (fds[i].revents & POLLIN)) {
          accept_request(listener, &session, &client, &detached, &generation, generation_root, use_rootfs, rootfs_writable, rootfs_growth_session, rootfs_ready, rootfs_error, use_build_context, build_context_ready, build_context_error, build_input_count, build_inputs_ready, build_inputs_error, use_network, network_ready, network_error);
        } else if (roles[i] == 1) {
          if (fds[i].revents & POLLIN) {
            pump_client_v1(&session, &client);
          }
          if (fds[i].revents & (POLLHUP | POLLERR)) {
            close_client(&client);
          }
        } else if (roles[i] == 2 || roles[i] == 3) {
          pump_session_output(&session, &client, roles[i] == 2, fds[i].revents);
        } else if (roles[i] == 4) {
          drain_sigchld_wakeup();
          reap_detached_children(&detached);
        } else if (roles[i] == 5 && (fds[i].revents & (POLLPRI | POLLERR))) {
          maybe_send_memory_pressure(&session, &client);
        } else if (roles[i] == 6) {
          drain_session_stdin(&session);
        } else if (roles[i] == 7 || roles[i] == 8) {
          drain_retained_output(&detached);
        }
      }
    }
    drain_session_stdin(&session);
    drain_session_terminal(&session);
    if (session.file_stdio && !session.exited) {
      pump_session_file(&session, &client, 1);
      pump_session_file(&session, &client, 0);
    }
    poll_session_exit(&session, &client);
    maybe_send_session_exit(&session, &client);
  }
}
#endif

#ifdef SPORE_AGENT_REQUEST_FUZZ
#include <stddef.h>
#include <sys/un.h>

// Starts `/bin/sh -c captured_script` as a captured session, the state of a
// named VM restored from a live capture, then sends request_bytes and
// input_bytes as a second client while it runs. Copies the frames the agent
// answers with into response and returns their length, or -1 when the harness
// itself fails. *captured_stdout gets how many bytes of the captured
// session's stdout the agent had read when the second client finished.
__attribute__((visibility("hidden"))) ssize_t spore_agent_test_exec_beside_running_session(
    const char *captured_script,
    const unsigned char *request_bytes, size_t request_len,
    const unsigned char *input_bytes, size_t input_len,
    unsigned char *response, size_t response_cap, uint64_t *captured_stdout) {
  static struct session session;
  static struct detached_children detached;
  *captured_stdout = 0;
  char *captured_argv[] = { "/bin/sh", "-c", (char *)captured_script, NULL };
  char *empty_envp[] = { NULL };
  const struct session_start_options captured_options = {
    .exec_lookup = EXEC_LOOKUP_PATH,
    .stdin_enabled = 1,
  };
  if (start_session(&session, "captured", captured_argv, empty_envp, "", &captured_options) != 0) return -1;

  struct client client;
  memset(&client, 0, sizeof(client));
  client.fd = -1;
  memset(&detached, 0, sizeof(detached));
  detached.retained_pid = -1;
  detached.retained_stdout_fd = -1;
  detached.retained_stderr_fd = -1;
  struct generation_monitor generation = { .base = NULL, .last_generation = UINT64_MAX, .unavailable = 1 };
  ssize_t total = -1;
  int peer = -1;
  int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  int name_len = snprintf(addr.sun_path + 1, sizeof(addr.sun_path) - 1, "spore-agent-test-%d", (int)getpid());
  socklen_t addr_len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + (size_t)name_len);
  if (listener < 0 || bind(listener, (struct sockaddr *)&addr, addr_len) != 0 || listen(listener, 1) != 0) goto done;
  peer = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (peer < 0 || connect(peer, (struct sockaddr *)&addr, addr_len) != 0) goto done;
  if (write_all(peer, request_bytes, request_len) != 0 || write_all(peer, input_bytes, input_len) != 0) goto done;

  // The agent mirrors session output to its console; keep it off the test
  // runner's stdout, which may carry the build protocol.
  int saved_stdout = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 0);
  int null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
  if (saved_stdout < 0 || null_fd < 0 || dup2(null_fd, STDOUT_FILENO) < 0) {
    if (saved_stdout >= 0) close(saved_stdout);
    if (null_fd >= 0) close(null_fd);
    goto done;
  }
  accept_request(listener, &session, &client, &detached, &generation, "/run/sporevm", 0, 0, 0, 1, "", 0, 1, "", 0, 1, "", 0, 1, "");
  close_client(&client);
  *captured_stdout = session.stdout_offset;
  (void)dup2(saved_stdout, STDOUT_FILENO);
  close(saved_stdout);
  close(null_fd);

  total = 0;
  while ((size_t)total < response_cap) {
    ssize_t n = read(peer, response + total, response_cap - (size_t)total);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    total += n;
  }

done:
  if (peer >= 0) close(peer);
  if (listener >= 0) close(listener);
  // The captured script may still be running or blocked on a full pipe. A
  // child it started dies on EPIPE once reset_session closes the pipes.
  (void)kill(session.pid, SIGKILL);
  wait_child_blocking(session.pid);
  reset_session(&session);
  return total;
}
#endif
