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

// What the event loop works on: the listener, what boot set up, the captured
// or current session and its client, detached children, the generation
// device, and the exec op that holds the client while it runs.
struct agent {
  int listener;
  int use_rootfs;
  int rootfs_writable;
  int rootfs_growth_session;
  int rootfs_ready;
  const char *rootfs_error;
  int build_context_requested;
  int build_context_ready;
  const char *build_context_error;
  int build_input_count;
  int build_inputs_ready;
  const char *build_inputs_error;
  int network_ready;
  const char *network_error;
  const char *generation_root;
  struct session session;
  struct client client;
  struct detached_children detached;
  struct generation_monitor generation;
  struct exec_op op;
  // Never connected: takes the session's output and exit while the exec op
  // holds the client.
  struct client no_client;
};

static struct client *session_client(struct agent *a) {
  return a->op.kind == EXEC_OP_NONE ? &a->client : &a->no_client;
}

static void init_agent(struct agent *a) {
  memset(a, 0, sizeof(*a));
  a->session.stdin_fd = -1;
  a->session.terminal_fd = -1;
  a->session.stdout_fd = -1;
  a->session.stderr_fd = -1;
  a->session.memory_pressure_fd = -1;
  a->client.fd = -1;
  a->no_client.fd = -1;
  a->detached.retained_pid = -1;
  a->detached.retained_stdout_fd = -1;
  a->detached.retained_stderr_fd = -1;
  a->generation.last_generation = UINT64_MAX;
}

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

static void accept_request(struct agent *a) {
  struct session *session = &a->session;
  struct client *client = &a->client;
  int conn = accept4(a->listener, NULL, NULL, SOCK_CLOEXEC);
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

  // A reset and the next connection can be ready in the same poll. Finish
  // the previous client-owned command before replacing its client, even if
  // the listener's event is handled before that client's hangup.
  if (session->started && !session->exited && session->cancel_on_disconnect) {
    if (stop_session_processes(session, session->pid) != 0) {
      dprintf(2, "spore exec: process cleanup failed\n");
      _exit(125);
    }
    reset_session(session);
  }
  close_client(client);
  client->fd = conn;
  if (request.kind == REQUEST_ATTACH) {
    // The host expects every frame, a refusal's stderr included, at the
    // offsets it asked to resume from.
    client->stdout_offset = request.stdout_offset;
    client->stderr_offset = request.stderr_offset;
  }
  client->stdin_input_owner = request.stdin_enabled;
  client->terminal_input_owner = request.tty && (request.kind == REQUEST_START || request.interactive);

  if (build_run_mount_cleanup_poisoned) {
    (void)send_client_error_exit(client, 125, "spore build: prior RUN mount cleanup failed\n");
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_READY) {
    if (a->use_rootfs && !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    if (!a->network_ready) {
      (void)send_client_error_exit(client, 126, a->network_error[0] != '\0' ? a->network_error : "spore run: network unavailable\n");
      close_client(client);
      return;
    }
    (void)send_client_exit(client, 0);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_INITIAL_OUTPUT) {
    (void)send_retained_output(client, &a->detached);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_COPY_IN || request.kind == REQUEST_COPY_OUT) {
    if (a->use_rootfs && !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = a->use_rootfs && a->rootfs_ready ? "/mnt/rootfs" : "";
    if (request.kind == REQUEST_COPY_IN) {
      (void)copy_in_file(client, root, request.copy_path);
    } else {
      (void)copy_out_file(client, root, request.copy_path);
    }
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_BUILD_RUN) {
    if (!a->use_rootfs || !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore build: rootfs unavailable\n");
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
    struct build_cache_mount_state *cache_state = &a->op.cache_state;
    struct build_context_bind_mount_state *bind_state = &a->op.bind_state;
    const char *root = "/mnt/rootfs";
    int cache_setup_rc = setup_build_cache_mounts(&request, root, a->build_context_requested, a->build_input_count,
                                                  cache_state, error, sizeof(error));
    if (cache_setup_rc != 0) {
      (void)send_client_error_exit(client, cache_setup_rc == -2 ? 125 : 126,
                                   error[0] != '\0' ? error : "spore build: cache mount setup failed\n");
      close_client(client);
      return;
    }
    int bind_setup_rc = setup_build_context_binds(&request, root, a->build_context_requested, a->build_context_ready,
                                                  bind_state, error, sizeof(error));
    if (bind_setup_rc != 0) {
      if (cleanup_build_cache_mounts(cache_state, root) != 0) {
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
    (void)start_build_exec(&a->op, client, &request, command, a->use_rootfs, root);
    return;
  }

  if (request.kind == REQUEST_BUILD_COPY) {
    if (!a->use_rootfs || !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    char source_root[64];
    if (request.copy_source_disk == COPY_SOURCE_CONTEXT) {
      if (!a->build_context_requested || !a->build_context_ready) {
        (void)send_client_error_exit(client, 126, a->build_context_error[0] != '\0' ? a->build_context_error : "spore build: context disk unavailable\n");
        close_client(client);
        return;
      }
      snprintf(source_root, sizeof(source_root), "%s", BUILD_CONTEXT_ROOT);
    } else {
      if (!a->build_inputs_ready || request.copy_input_index >= (uint64_t)a->build_input_count) {
        (void)send_client_error_exit(client, 126, a->build_inputs_error[0] != '\0' ? a->build_inputs_error : "spore build: input disk unavailable\n");
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
    if (!a->use_rootfs || !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    (void)build_workdir_apply(client, "/mnt/rootfs", request.working_dir);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_ROOTFS_GROW) {
    if (!a->use_rootfs || !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    if (!a->rootfs_writable || !a->rootfs_growth_session) {
      (void)send_client_error_exit(client, 126, "spore build: rootfs growth is not enabled\n");
      close_client(client);
      return;
    }
    (void)grow_rootfs(client);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_FSFREEZE || request.kind == REQUEST_FSTHAW) {
    if (!a->use_rootfs || !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore build: rootfs unavailable\n");
      close_client(client);
      return;
    }
    (void)freeze_or_thaw_rootfs(client, request.kind == REQUEST_FSFREEZE);
    close_client(client);
    return;
  }

  if (request.kind == REQUEST_START) {
    if (a->use_rootfs && !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    if (!a->network_ready) {
      (void)send_client_error_exit(client, 126, a->network_error[0] != '\0' ? a->network_error : "spore run: network unavailable\n");
      close_client(client);
      return;
    }
    if (request.generation_params[0] != '\0') {
      const char *root = generation_root_path(a->use_rootfs, a->rootfs_ready);
      const char *generation_error = apply_request_generation(&a->generation, root, request.generation_params);
      if (generation_error != NULL) {
        (void)send_client_error_exit(client, 126, generation_error);
        close_client(client);
        return;
      }
    } else if (request.require_generation_ready && ensure_generation_ready(&a->generation, a->generation_root) != 0) {
      (void)send_client_error_exit(client, 126, "spore run: generation metadata unavailable\n");
      close_client(client);
      return;
    }
    apply_resume_clock(request.resume_time_unix_ns);
    if (request.detached) {
      int rc = start_detached(request.argv, request.envp, request.working_dir, a->use_rootfs,
                              request.retain_output, &a->detached);
      if (rc != 0) {
        (void)send_client_error_exit(client, rc, "spore run: exec setup failed\n");
        close_client(client);
        return;
      }
      (void)send_client_exit(client, 0);
      close_client(client);
      return;
    }
    if (session->started) {
      if (strcmp(request.session_id, session->session_id) == 0) {
        (void)attach_client(session, client, request.stdout_offset, request.stderr_offset);
        return;
      }
      if (!session_finished(session)) {
        (void)start_transient_exec(&a->op, client, &request, a->use_rootfs);
        return;
      }
      reset_session(session);
    }
    const struct session_start_options options = {
      .use_rootfs = a->use_rootfs,
      .memory_pressure = request.memory_pressure,
      .cancel_on_disconnect = request.cancel_on_disconnect,
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
    if (a->use_rootfs && !a->rootfs_ready) {
      (void)send_client_error_exit(client, 126, a->rootfs_error[0] != '\0' ? a->rootfs_error : "spore run: rootfs unavailable\n");
      close_client(client);
      return;
    }
    const char *root = generation_root_path(a->use_rootfs, a->rootfs_ready);
    const char *generation_error = apply_request_generation(&a->generation, root, request.generation_params);
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

// One pass of the event loop: waits up to 100 ms (10 ms while the session's
// output goes through files) for the listener, the client, session
// output, child exits, memory pressure, stdin space, and retained output, then
// handles what is ready. While an exec op holds the client, the listener
// waits, client frames go to the op, and the session's output goes only to
// its replay buffer and the console.
static void poll_agent(struct agent *a) {
  struct session *session = &a->session;
  struct exec_op *op = &a->op;

  reap_detached_children(&a->detached);
  drain_retained_output(&a->detached);
  if (!a->use_rootfs || a->rootfs_ready) {
    (void)poll_generation(&a->generation, a->generation_root);
  }

  struct pollfd fds[13];
  int roles[13];
  nfds_t nfds = 0;
  if (op->kind == EXEC_OP_NONE) {
    fds[nfds].fd = a->listener;
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    roles[nfds++] = 0;
  }
  if (a->client.fd >= 0) {
    fds[nfds].fd = a->client.fd;
    // A build RUN reads nothing more from its client; it only notices a hangup.
    fds[nfds].events = op->kind == EXEC_OP_BUILD_RUN ? POLLHUP | POLLERR : POLLIN | POLLHUP | POLLERR;
    fds[nfds].revents = 0;
    roles[nfds++] = 1;
  }
  add_session_output_fds(session, fds, roles, &nfds, 2);
  fds[nfds].fd = sigchld_pipe[0];
  fds[nfds].events = POLLIN;
  fds[nfds].revents = 0;
  roles[nfds++] = 4;
  if (session->memory_pressure_fd >= 0) {
    fds[nfds].fd = session->memory_pressure_fd;
    fds[nfds].events = POLLPRI | POLLERR;
    fds[nfds].revents = 0;
    roles[nfds++] = 5;
  }
  if (session->stdin_open && session->stdin_pending_len != 0) {
    fds[nfds].fd = session->stdin_fd;
    fds[nfds].events = POLLOUT | POLLERR;
    fds[nfds].revents = 0;
    roles[nfds++] = 6;
  }
  if (a->detached.retained_stdout_fd >= 0) {
    fds[nfds].fd = a->detached.retained_stdout_fd;
    fds[nfds].events = POLLIN | POLLHUP | POLLERR;
    fds[nfds].revents = 0;
    roles[nfds++] = 7;
  }
  if (a->detached.retained_stderr_fd >= 0) {
    fds[nfds].fd = a->detached.retained_stderr_fd;
    fds[nfds].events = POLLIN | POLLHUP | POLLERR;
    fds[nfds].revents = 0;
    roles[nfds++] = 8;
  }
  if (op->kind != EXEC_OP_NONE) {
    add_session_output_fds(&op->session, fds, roles, &nfds, 9);
    if (op->session.stdin_open && op->session.stdin_pending_len != 0) {
      fds[nfds].fd = op->session.stdin_fd;
      fds[nfds].events = POLLOUT | POLLERR;
      fds[nfds].revents = 0;
      roles[nfds++] = 11;
    }
  }

  int pr = poll(fds, nfds, 100);
  if (pr < 0 && errno != EINTR) return;
  if (pr > 0) {
    for (nfds_t i = 0; i < nfds; i++) {
      if (fds[i].revents == 0) continue;
      if (roles[i] == 0 && (fds[i].revents & POLLIN)) {
        accept_request(a);
      } else if (roles[i] == 1 && fds[i].fd == a->client.fd) {
        // accept_request may have replaced the client polled here; the
        // replaced client's events, such as its hangup, are not the new one's.
        if ((fds[i].revents & POLLIN) && op->kind != EXEC_OP_BUILD_RUN) {
          pump_client_v1(op->kind == EXEC_OP_TRANSIENT ? &op->session : session, &a->client);
        }
        if (fds[i].revents & (POLLHUP | POLLERR)) {
          close_client(&a->client);
        }
      } else if (roles[i] == 2 || roles[i] == 3) {
        pump_session_output(session, session_client(a), roles[i] == 2, fds[i].revents);
      } else if (roles[i] == 4) {
        drain_sigchld_wakeup();
        reap_detached_children(&a->detached);
      } else if (roles[i] == 5 && (fds[i].revents & (POLLPRI | POLLERR))) {
        maybe_send_memory_pressure(session, session_client(a));
      } else if (roles[i] == 6) {
        drain_session_stdin(session);
      } else if (roles[i] == 7 || roles[i] == 8) {
        drain_retained_output(&a->detached);
      } else if (roles[i] == 9 || roles[i] == 10) {
        pump_session_output(&op->session, &a->client, roles[i] == 9, fds[i].revents);
      } else if (roles[i] == 11) {
        drain_session_stdin(&op->session);
      }
    }
  }
  if (op->kind == EXEC_OP_NONE && a->client.fd < 0 && session->started &&
      !session->exited && session->cancel_on_disconnect) {
    if (stop_session_processes(session, session->pid) != 0) {
      dprintf(2, "spore exec: process cleanup failed\n");
      _exit(125);
    }
    reset_session(session);
  }
  drain_session_stdin(session);
  drain_session_terminal(session);
  poll_session_exit(session, session_client(a));
  maybe_send_session_exit(session, session_client(a));
  if (op->kind == EXEC_OP_NONE) return;

  if (op->kind == EXEC_OP_TRANSIENT) {
    poll_session_exit(&op->session, &a->client);
    maybe_send_session_exit(&op->session, &a->client);
  } else {
    step_build_exec(op, &a->client);
  }
  if (a->client.fd >= 0 && !session_finished(&op->session)) return;
  if (op->kind == EXEC_OP_TRANSIENT) {
    finish_transient_exec(op, &a->client);
  } else {
    finish_build_exec(op, &a->client);
  }
  op->kind = EXEC_OP_NONE;
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
  console_mirror = cmdline_has_flag_in(cmdline, "spore_console_mirror=1");
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
  if (setup_network(use_network, use_rootfs, build_mode, network_error, sizeof(network_error)) != 0) {
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

  static struct agent a;
  init_agent(&a);
  a.listener = listener;
  a.use_rootfs = use_rootfs;
  a.rootfs_writable = rootfs_writable;
  a.rootfs_growth_session = rootfs_growth_session;
  a.rootfs_ready = rootfs_ready;
  a.rootfs_error = rootfs_error;
  a.build_context_requested = use_build_context;
  a.build_context_ready = build_context_ready;
  a.build_context_error = build_context_error;
  a.build_input_count = build_input_count;
  a.build_inputs_ready = build_inputs_ready;
  a.build_inputs_error = build_inputs_error;
  a.network_ready = network_ready;
  a.network_error = network_error;
  a.generation_root = generation_root_path(use_rootfs, rootfs_ready);
  for (;;) poll_agent(&a);
}
#endif

#ifdef SPORE_AGENT_REQUEST_FUZZ
#include <stddef.h>
#include <sys/un.h>

// Starts `/bin/sh -c captured_script` as the captured session, the state of
// a named VM restored from a capture. With captured_finishes set, waits for
// the script to exit, as in a VM captured after its command finished. With
// attach_len nonzero, a client then sends attach_bytes and stays attached
// until the first request's client connects, then hangs up, so the agent sees
// both in the same poll. Serves request_count requests, each a request line
// and its input frames back to back in requests with its length in
// request_lens, as one client after another, waiting for each to be answered.
// Copies the frames the agent answers the last request with into response and
// returns their length, or -1 when the harness itself fails. *captured_stdout
// gets how many bytes of the captured session's stdout the agent had read when
// the last client finished.
__attribute__((visibility("hidden"))) ssize_t spore_agent_test_serve_requests(
    const char *captured_script, int captured_finishes,
    const unsigned char *attach_bytes, size_t attach_len,
    const unsigned char *requests, const size_t *request_lens, size_t request_count,
    unsigned char *response, size_t response_cap, uint64_t *captured_stdout) {
  static struct agent a;
  init_agent(&a);
  a.rootfs_ready = 1;
  a.rootfs_error = "";
  a.build_context_ready = 1;
  a.build_context_error = "";
  a.build_inputs_ready = 1;
  a.build_inputs_error = "";
  a.network_ready = 1;
  a.network_error = "";
  a.generation_root = "/run/sporevm";
  a.generation.unavailable = 1;
  struct session *session = &a.session;
  *captured_stdout = 0;

  // Keep what the agent writes to its console off the test runner's stdout,
  // which may carry the build protocol, and stderr.
  int saved_stdout = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 0);
  int saved_stderr = fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, 0);
  int null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
  if (saved_stdout < 0 || saved_stderr < 0 || null_fd < 0 ||
      dup2(null_fd, STDOUT_FILENO) < 0 || dup2(null_fd, STDERR_FILENO) < 0) {
    if (saved_stdout >= 0) {
      (void)dup2(saved_stdout, STDOUT_FILENO);
      close(saved_stdout);
    }
    if (saved_stderr >= 0) close(saved_stderr);
    if (null_fd >= 0) close(null_fd);
    return -1;
  }

  ssize_t total = -1;
  int attached = -1;
  int peer = -1;
  int listener = -1;
  char *captured_argv[] = { "/bin/sh", "-c", (char *)captured_script, NULL };
  char *empty_envp[] = { NULL };
  const struct session_start_options captured_options = {
    .exec_lookup = EXEC_LOOKUP_PATH,
    .stdin_enabled = 1,
  };
  listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  int name_len = snprintf(addr.sun_path + 1, sizeof(addr.sun_path) - 1, "spore-agent-test-%d", (int)getpid());
  socklen_t addr_len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + (size_t)name_len);
  if (listener < 0 || bind(listener, (struct sockaddr *)&addr, addr_len) != 0 || listen(listener, 1) != 0) goto done;
  a.listener = listener;
  if (start_session(session, "captured", captured_argv, empty_envp, "", &captured_options) != 0) goto done;
  while (captured_finishes && !session_finished(session)) poll_agent(&a);
  if (attach_len > 0) {
    attached = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (attached < 0 || connect(attached, (struct sockaddr *)&addr, addr_len) != 0 ||
        write_all(attached, attach_bytes, attach_len) != 0) goto done;
    accept_request(&a);
    if (a.client.fd < 0) goto done;
  }

  for (size_t i = 0; i < request_count; i++) {
    if (peer >= 0) close(peer);
    peer = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (peer < 0 || connect(peer, (struct sockaddr *)&addr, addr_len) != 0) goto done;
    if (write_all(peer, requests, request_lens[i]) != 0) goto done;
    requests += request_lens[i];
    if (attached >= 0) {
      close(attached);
      attached = -1;
    }
    // Accept the request through the event loop, which sees an attached
    // client's hangup in the same poll.
    struct pollfd pending = { .fd = listener, .events = POLLIN };
    do {
      poll_agent(&a);
    } while (poll(&pending, 1, 0) > 0);
    while (a.op.kind != EXEC_OP_NONE || a.client.fd >= 0) poll_agent(&a);

    total = 0;
    while ((size_t)total < response_cap) {
      ssize_t n = read(peer, response + total, response_cap - (size_t)total);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) break;
      total += n;
    }
  }
  *captured_stdout = session->stdout_offset;

done:
  (void)dup2(saved_stdout, STDOUT_FILENO);
  (void)dup2(saved_stderr, STDERR_FILENO);
  close(saved_stdout);
  close(saved_stderr);
  close(null_fd);
  if (attached >= 0) close(attached);
  if (peer >= 0) close(peer);
  if (listener >= 0) close(listener);
  // The captured script may still be running or blocked on a full pipe. A
  // child it started dies on EPIPE once reset_session closes the pipes.
  if (session->started && !session->exited) {
    (void)kill(session->pid, SIGKILL);
    wait_child_blocking(session->pid);
  }
  reset_session(session);
  return total;
}
#endif
