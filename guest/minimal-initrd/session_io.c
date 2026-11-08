// A running session's streams: replay, attach, output, stdin, terminal,
// client frames, exit, and transient execs beside a captured session.

#include "agent.h"

#define SPIO_RESIZE 4

static void replay_append(struct replay_buffer *replay, uint64_t offset, const unsigned char *buf, size_t len) {
  if (len > REPLAY_CAP) {
    buf += len - REPLAY_CAP;
    offset += len - REPLAY_CAP;
    len = REPLAY_CAP;
  }
  size_t at = (size_t)(offset % REPLAY_CAP);
  size_t first = len < REPLAY_CAP - at ? len : REPLAY_CAP - at;
  memcpy(replay->data + at, buf, first);
  memcpy(replay->data, buf + first, len - first);
  replay->len = replay->len + len < REPLAY_CAP ? replay->len + len : REPLAY_CAP;
  replay->base_offset = offset + len - replay->len;
}

int session_finished(const struct session *session) {
  return session->started && session->exited && !session->stdout_open && !session->stderr_open;
}

void reset_session(struct session *session) {
  close_session_cgroup(session);
  if (session->stdout_fd >= 0) close(session->stdout_fd);
  if (session->stderr_fd >= 0) close(session->stderr_fd);
  if (session->stdin_fd >= 0) close(session->stdin_fd);
  if (session->terminal_fd >= 0 && session->terminal_fd != session->stdout_fd) close(session->terminal_fd);
  memset(session, 0, sizeof(*session));
  session->stdout_fd = -1;
  session->stderr_fd = -1;
  session->stdin_fd = -1;
  session->terminal_fd = -1;
  session->memory_pressure_fd = -1;
}

static int replay_available(const struct replay_buffer *replay, uint64_t offset, uint64_t end_offset) {
  return offset >= replay->base_offset && offset <= end_offset;
}

static int send_replay(struct session *session, struct client *client, const struct replay_buffer *replay, const char *name, uint64_t *client_offset, uint64_t end_offset) {
  if (!replay_available(replay, *client_offset, end_offset)) return -1;
  uint64_t replay_end = replay->base_offset + replay->len;
  while (*client_offset < replay_end) {
    size_t at = (size_t)(*client_offset % REPLAY_CAP);
    size_t len = (size_t)(replay_end - *client_offset);
    if (len > REPLAY_CAP - at) len = REPLAY_CAP - at;
    if (send_client_output(session, client, name, client_offset, *client_offset, replay->data + at, len) != 0) return -1;
  }
  return 0;
}

int attach_client(struct session *session, struct client *client, uint64_t stdout_offset, uint64_t stderr_offset) {
  client->stdout_offset = stdout_offset;
  client->stderr_offset = stderr_offset;
  if (send_replay(session, client, &session->stdout_replay, "stdout", &client->stdout_offset, session->stdout_offset) != 0 ||
      send_replay(session, client, &session->stderr_replay, "stderr", &client->stderr_offset, session->stderr_offset) != 0) {
    (void)send_client_error_exit(client, 125, "spore run: requested replay offset is unavailable\n");
    close_client(client);
    return -1;
  }
  if (session->exited && !session->stdout_open && !session->stderr_open) {
    (void)send_client_exit(client, session->exit_code);
    close_client(client);
  }
  return 0;
}

void pump_session_stream(struct session *session, struct client *client, int is_stdout) {
  int *fd = is_stdout ? &session->stdout_fd : &session->stderr_fd;
  int *open = is_stdout ? &session->stdout_open : &session->stderr_open;
  uint64_t *offset = is_stdout ? &session->stdout_offset : &session->stderr_offset;
  struct replay_buffer *replay = is_stdout ? &session->stdout_replay : &session->stderr_replay;
  const char *name = is_stdout ? "stdout" : "stderr";
  uint64_t *client_offset = is_stdout ? &client->stdout_offset : &client->stderr_offset;
  // A batch's worth per read, so each read leaves in one vsock write.
  static unsigned char buf[SPIO_BATCH_FRAMES * MAX_FRAME_PAYLOAD];

  if (!*open) return;
  for (;;) {
    ssize_t n = read(*fd, buf, sizeof(buf));
    if (n > 0) {
      uint64_t frame_offset = *offset;
      mirror_console(is_stdout, buf, (size_t)n);
      replay_append(replay, frame_offset, buf, (size_t)n);
      *offset += (uint64_t)n;
      if (client->fd >= 0) {
        (void)send_client_output(session, client, name, client_offset, frame_offset, buf, (size_t)n);
      }
      continue;
    }
    if (n == 0) {
      close(*fd);
      *fd = -1;
      *open = 0;
      return;
    }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    close(*fd);
    *fd = -1;
    *open = 0;
    return;
  }
}

static void pump_session_terminal(struct session *session, struct client *client) {
  if (!session->tty || !session->stdout_open || session->terminal_fd < 0) return;
  unsigned char buf[MAX_FRAME_PAYLOAD];
  for (;;) {
    ssize_t n = read(session->terminal_fd, buf, sizeof(buf));
    if (n > 0) {
      mirror_console(1, buf, (size_t)n);
      session->terminal_offset += (uint64_t)n;
      if (client->fd >= 0) {
        (void)send_client_terminal_output(session, client, client->terminal_offset, buf, (size_t)n);
      }
      continue;
    }
    if (n == 0) {
      close(session->terminal_fd);
      session->terminal_fd = -1;
      session->stdout_fd = -1;
      session->stdout_open = 0;
      return;
    }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    close(session->terminal_fd);
    session->terminal_fd = -1;
    session->stdout_fd = -1;
    session->stdout_open = 0;
    return;
  }
}

static void close_session_terminal_input(struct session *session) {
  if (!session->tty) return;
  if (session->terminal_pending_len == 0) {
    session->terminal_pending[0] = 4;
    session->terminal_pending_len = 1;
    session->terminal_pending_off = 0;
  } else {
    session->terminal_close_pending = 1;
  }
}

void drain_session_terminal(struct session *session) {
  while (session->tty && session->terminal_fd >= 0 && session->terminal_pending_off < session->terminal_pending_len) {
    size_t remaining = session->terminal_pending_len - session->terminal_pending_off;
    ssize_t n = write(session->terminal_fd, session->terminal_pending + session->terminal_pending_off, remaining);
    if (n > 0) {
      session->terminal_pending_off += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    session->terminal_pending_len = 0;
    session->terminal_pending_off = 0;
    session->terminal_close_pending = 0;
    return;
  }
  if (session->terminal_pending_off >= session->terminal_pending_len) {
    session->terminal_pending_off = 0;
    session->terminal_pending_len = 0;
    if (session->terminal_close_pending) {
      session->terminal_close_pending = 0;
      close_session_terminal_input(session);
    }
  }
}

// Adds the session's stdout and stderr pipes to a poll set, as roles
// stdout_role and stdout_role + 1. pump_session_output handles their events.
void add_session_output_fds(const struct session *session, struct pollfd *fds, int *roles, nfds_t *nfds, int stdout_role) {
  if (session->stdout_open) {
    fds[*nfds].fd = session->stdout_fd;
    fds[*nfds].events = POLLIN | POLLHUP | POLLERR;
    if (session->tty && session->terminal_pending_len != 0) fds[*nfds].events |= POLLOUT;
    fds[*nfds].revents = 0;
    roles[(*nfds)++] = stdout_role;
  }
  if (session->stderr_open) {
    fds[*nfds].fd = session->stderr_fd;
    fds[*nfds].events = POLLIN | POLLHUP | POLLERR;
    fds[*nfds].revents = 0;
    roles[(*nfds)++] = stdout_role + 1;
  }
}

void pump_session_output(struct session *session, struct client *client, int is_stdout, short revents) {
  if (is_stdout && session->tty) {
    if (revents & POLLOUT) drain_session_terminal(session);
    if (revents & (POLLIN | POLLHUP | POLLERR)) pump_session_terminal(session, client);
  } else {
    pump_session_stream(session, client, is_stdout);
  }
}

static void close_session_stdin(struct session *session) {
  if (session->stdin_fd >= 0) {
    close(session->stdin_fd);
    session->stdin_fd = -1;
  }
  session->stdin_open = 0;
  session->stdin_pending_len = 0;
  session->stdin_pending_off = 0;
  session->stdin_close_pending = 0;
}

void drain_session_stdin(struct session *session) {
  while (session->stdin_open && session->stdin_pending_off < session->stdin_pending_len) {
    size_t remaining = session->stdin_pending_len - session->stdin_pending_off;
    ssize_t n = write(session->stdin_fd, session->stdin_pending + session->stdin_pending_off, remaining);
    if (n > 0) {
      session->stdin_pending_off += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    close_session_stdin(session);
    return;
  }
  if (session->stdin_pending_off >= session->stdin_pending_len) {
    session->stdin_pending_off = 0;
    session->stdin_pending_len = 0;
    if (session->stdin_close_pending) close_session_stdin(session);
  }
}

static int parse_spio_header(struct client *client) {
  if (memcmp(client->v1_header, SPIO_MAGIC, 4) != 0) return -1;
  if (client->v1_header[4] != SPIO_VERSION) return -1;
  client->v1_type = client->v1_header[5];
  uint16_t flags = read_le16(client->v1_header + 6);
  if (flags != 0) return -1;
  client->v1_stream_id = read_le32(client->v1_header + 8);
  client->v1_offset = read_le64(client->v1_header + 12);
  client->v1_payload_len = read_le32(client->v1_header + 20);
  if (client->v1_payload_len > MAX_FRAME_PAYLOAD) return -1;
  client->v1_payload_read = 0;
  return 0;
}

static int handle_spio_frame(struct session *session, struct client *client) {
  if (client->v1_type == SPIO_DATA) {
    if (client->v1_stream_id == SPIO_TERMINAL_STREAM) {
      if (!session->tty || session->terminal_fd < 0) return -1;
      if (!client->terminal_input_owner) return -1;
      if (client->v1_offset != client->terminal_input_offset) return -1;
      if (session->terminal_pending_len != 0) return -1;
      memcpy(session->terminal_pending, client->v1_payload, client->v1_payload_len);
      session->terminal_pending_len = client->v1_payload_len;
      session->terminal_pending_off = 0;
      client->terminal_input_offset += client->v1_payload_len;
      session->terminal_input_offset = client->terminal_input_offset;
      drain_session_terminal(session);
      return 0;
    }
    if (client->v1_stream_id != SPIO_STDIN_STREAM) return -1;
    if (!client->stdin_input_owner) return -1;
    if (!session->stdin_open) return -1;
    if (client->v1_offset != client->stdin_offset) return -1;
    if (session->stdin_pending_len != 0) return -1;
    memcpy(session->stdin_pending, client->v1_payload, client->v1_payload_len);
    session->stdin_pending_len = client->v1_payload_len;
    session->stdin_pending_off = 0;
    client->stdin_offset += client->v1_payload_len;
    session->stdin_offset = client->stdin_offset;
    drain_session_stdin(session);
    return 0;
  }
  if (client->v1_type == SPIO_CLOSE) {
    if (client->v1_stream_id == SPIO_TERMINAL_STREAM) {
      if (!session->tty || client->v1_payload_len != 0) return -1;
      if (!client->terminal_input_owner) return -1;
      if (client->v1_offset != client->terminal_input_offset) return -1;
      close_session_terminal_input(session);
      return 0;
    }
    if (client->v1_stream_id != SPIO_STDIN_STREAM || client->v1_payload_len != 0) return -1;
    if (!client->stdin_input_owner) return -1;
    if (client->v1_offset != client->stdin_offset) return -1;
    if (session->stdin_pending_len == 0) {
      close_session_stdin(session);
    } else {
      session->stdin_close_pending = 1;
    }
    return 0;
  }
  if (client->v1_type == SPIO_RESIZE) {
    if (!session->tty || client->v1_stream_id != SPIO_TERMINAL_STREAM || client->v1_payload_len != 4) return -1;
    uint16_t rows = read_le16(client->v1_payload);
    uint16_t cols = read_le16(client->v1_payload + 2);
    if (rows == 0 || cols == 0) return -1;
    if (session->terminal_fd >= 0) (void)apply_terminal_size(session->terminal_fd, rows, cols);
    return 0;
  }
  return -1;
}

// The v1 client owning session input disconnected or violated the stream
// protocol, so its stdin/terminal ownership can never produce more input.
// Close the session's input pipes so the child observes EOF and can finish;
// otherwise the session blocks forever and later execs fail with "session
// already started".
void close_client_input_lost(struct session *session, struct client *client) {
  if (session->started && !session->exited) {
    if (client->stdin_input_owner) close_session_stdin(session);
    if (client->terminal_input_owner) close_session_terminal_input(session);
  }
  close_client(client);
}

void pump_client_v1(struct session *session, struct client *client) {
  if (client->fd < 0) return;
  if (session->stdin_pending_len != 0 || session->terminal_pending_len != 0) return;

  for (;;) {
    if (client->v1_header_len < SPIO_HEADER_LEN) {
      ssize_t n = recv(client->fd, client->v1_header + client->v1_header_len, SPIO_HEADER_LEN - client->v1_header_len, MSG_DONTWAIT);
      if (n > 0) {
        client->v1_header_len += (size_t)n;
        if (client->v1_header_len < SPIO_HEADER_LEN) return;
        if (parse_spio_header(client) != 0) {
          close_client_input_lost(session, client);
          return;
        }
        if (client->v1_payload_len == 0) {
          if (handle_spio_frame(session, client) != 0) close_client_input_lost(session, client);
          client->v1_header_len = 0;
          return;
        }
      } else if (n == 0) {
        close_client_input_lost(session, client);
        return;
      } else {
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        close_client_input_lost(session, client);
        return;
      }
    }

    while (client->v1_payload_read < client->v1_payload_len) {
      ssize_t n = recv(client->fd, client->v1_payload + client->v1_payload_read, client->v1_payload_len - client->v1_payload_read, MSG_DONTWAIT);
      if (n > 0) {
        client->v1_payload_read += (size_t)n;
        continue;
      }
      if (n == 0) {
        close_client_input_lost(session, client);
        return;
      }
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) return;
      close_client_input_lost(session, client);
      return;
    }

    if (handle_spio_frame(session, client) != 0) {
      close_client_input_lost(session, client);
      return;
    }
    client->v1_header_len = 0;
    client->v1_payload_len = 0;
    client->v1_payload_read = 0;
    if (session->stdin_pending_len != 0 || session->terminal_pending_len != 0) return;
  }
}

void poll_session_exit(struct session *session, struct client *client) {
  if (!session->started || session->exited) return;

  int status = 0;
  struct rusage usage;
  memset(&usage, 0, sizeof(usage));
  int wr = wait_child(session->pid, &status, &usage);
  if (wr == 0) return;
  t_command_exit = now_ms();
  if (wr > 0) {
    t_command_user_us = (int64_t)usage.ru_utime.tv_sec * 1000000LL + usage.ru_utime.tv_usec;
    t_command_system_us = (int64_t)usage.ru_stime.tv_sec * 1000000LL + usage.ru_stime.tv_usec;
  }
  if (wr < 0) {
    session->exit_code = 127;
  } else if (WIFEXITED(status)) {
    session->exit_code = WEXITSTATUS(status);
  } else if (WIFSIGNALED(status)) {
    session->exit_code = 128 + WTERMSIG(status);
  } else {
    session->exit_code = 1;
  }
  session->exited = 1;
  close_session_stdin(session);

  /*
   * Do not wait indefinitely for pipe EOF after the direct command exits;
   * inherited fds from daemonized children must not block the run result.
   */
  if (session->tty) {
    pump_session_terminal(session, client);
    if (session->terminal_fd >= 0) {
      close(session->terminal_fd);
      session->terminal_fd = -1;
      session->stdout_fd = -1;
      session->stdout_open = 0;
    }
  } else {
    pump_session_stream(session, client, 1);
    pump_session_stream(session, client, 0);
    if (session->stdout_open) {
      close(session->stdout_fd);
      session->stdout_fd = -1;
      session->stdout_open = 0;
    }
    if (session->stderr_open) {
      close(session->stderr_fd);
      session->stderr_fd = -1;
      session->stderr_open = 0;
    }
  }
  if (session->cancel_on_disconnect) {
    if (stop_session_processes(session, session->pid) != 0) {
      dprintf(2, "spore exec: process cleanup failed\n");
      _exit(125);
    }
  } else if (!session->build_run_isolation) {
    close_session_cgroup(session);
  }
}

void maybe_send_session_exit(struct session *session, struct client *client) {
  if (client->fd < 0) return;
  if (!session->started || !session->exited || session->stdout_open || session->stderr_open) return;
  (void)send_client_exit(client, session->exit_code);
  close_client(client);
}

void maybe_send_memory_pressure(struct session *session, struct client *client) {
  if (session->memory_pressure_fd < 0) return;
  // Read the event even with no client to tell, or it stays pending and the
  // event loop wakes on it forever. A workload still over memory.high raises
  // another event, which a client attached by then hears.
  drain_memory_pressure_events(session);
  if (client->fd < 0 || !session->started || session->exited) return;
  if (send_spio_event(client->fd, "memory-pressure") != 0) {
    close_client(client);
    return;
  }
  if (rearm_memory_pressure_limit(session) != 0) {
    dprintf(2, "memory pressure setup failed: rearm high limit errno=%d\n", errno);
    close(session->memory_pressure_fd);
    session->memory_pressure_fd = -1;
  }
}

// Starts an exec beside a captured session that is still running, such as a
// named VM restored from a live capture, as the exec op. Named exec sends
// start-v1 with pipe stdin, so the event loop forwards its stdin frames;
// terminals and memory pressure need the primary session slot. Until the
// exec finishes, the loop keeps draining the captured session's output into
// its replay buffer, as it does with no client attached, so the captured
// workload never blocks on a full pipe. Other execs and copies to the VM wait
// for this one to finish. On failure, answers and closes the client and
// returns nonzero.
int start_transient_exec(struct exec_op *op, struct client *client, const struct run_request *request, int use_rootfs) {
  if (request->tty || request->memory_pressure) {
    (void)send_client_error_exit(client, 2, "spore run: session already started\n");
    close_client(client);
    return -1;
  }

  const struct session_start_options options = {
    .use_rootfs = use_rootfs,
    .cancel_on_disconnect = request->cancel_on_disconnect,
    .exec_lookup = EXEC_LOOKUP_PATH,
    .stdin_enabled = request->stdin_enabled,
    .terminal_rows = request->terminal_rows,
    .terminal_cols = request->terminal_cols,
  };
  int rc = start_session(&op->session, request->session_id, request->argv, request->envp, request->working_dir, &options);
  if (rc != 0) {
    (void)send_client_error_exit(client, rc, "spore run: exec setup failed\n");
    close_client(client);
    return -1;
  }
  op->kind = EXEC_OP_TRANSIENT;
  return 0;
}

// Ends the transient exec once its client has the exit status or is gone,
// killing the command if the client went first.
void finish_transient_exec(struct exec_op *op, struct client *client) {
  if (client->fd < 0 && op->session.started && !op->session.exited) {
    if (stop_session_processes(&op->session, op->session.pid) != 0) {
      dprintf(2, "spore exec: process cleanup failed\n");
      _exit(125);
    }
  }
  reset_session(&op->session);
  close_client(client);
}
