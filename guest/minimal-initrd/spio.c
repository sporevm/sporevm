// SPIO frames to the attached client.

#include "agent.h"

#define SPIO_EXIT 3
#define SPIO_EVENT 7
#define SPIO_CONTROL_STREAM 0

static int send_spio_frame(int fd, uint8_t type, uint32_t stream_id, uint64_t offset, const unsigned char *payload, size_t len) {
  if (len > MAX_FRAME_PAYLOAD) return -1;
  unsigned char header[SPIO_HEADER_LEN];
  memcpy(header, SPIO_MAGIC, 4);
  header[4] = SPIO_VERSION;
  header[5] = type;
  write_le16(header + 6, 0);
  write_le32(header + 8, stream_id);
  write_le64(header + 12, offset);
  write_le32(header + 20, (uint32_t)len);
  if (write_all(fd, header, sizeof(header)) != 0) return -1;
  if (len > 0 && write_all(fd, payload, len) != 0) return -1;
  return 0;
}

int send_spio_data(int fd, uint32_t stream_id, uint64_t offset, const unsigned char *buf, size_t len) {
  size_t sent = 0;
  while (sent < len) {
    size_t chunk = len - sent;
    if (chunk > MAX_FRAME_PAYLOAD) chunk = MAX_FRAME_PAYLOAD;
    if (send_spio_frame(fd, SPIO_DATA, stream_id, offset + sent, buf + sent, chunk) != 0) return -1;
    sent += chunk;
  }
  return 0;
}

int send_spio_event(int fd, const char *event) {
  return send_spio_frame(fd, SPIO_EVENT, SPIO_CONTROL_STREAM, 0, (const unsigned char *)event, strlen(event));
}

static int send_spio_exit(int fd, int exit_code) {
  unsigned char payload[4];
  write_le32(payload, (uint32_t)exit_code);
  return send_spio_frame(fd, SPIO_EXIT, SPIO_CONTROL_STREAM, 0, payload, sizeof(payload));
}

static int format_timing(char *frame, size_t cap) {
  int64_t now = now_ms();
  int n = snprintf(frame, cap,
                   "timing listen=%lld accept=%lld decode=%lld spawn=%lld exit=%lld now=%lld user_us=%lld system_us=%lld\n",
                   (long long)(t_listen_ready ? t_listen_ready - t_init_start : -1),
                   (long long)(t_request_accept ? t_request_accept - t_init_start : -1),
                   (long long)(t_request_decode ? t_request_decode - t_init_start : -1),
                   (long long)(t_command_start ? t_command_start - t_init_start : -1),
                   (long long)(t_command_exit ? t_command_exit - t_init_start : -1),
                   (long long)(now ? now - t_init_start : -1),
                   (long long)t_command_user_us,
                   (long long)t_command_system_us);
  if (n <= 0 || (size_t)n >= cap) return -1;
  return n;
}

static int send_spio_timing_frame(int fd) {
  char frame[192];
  int n = format_timing(frame, sizeof(frame));
  if (n < 0) return -1;
  if (n > 0 && frame[n - 1] == '\n') n--;
  return send_spio_frame(fd, SPIO_EVENT, SPIO_CONTROL_STREAM, 0, (const unsigned char *)frame, (size_t)n);
}

void close_client(struct client *client) {
  if (client->fd >= 0) {
    close(client->fd);
    client->fd = -1;
  }
  client->stdout_offset = 0;
  client->stderr_offset = 0;
  client->stdin_offset = 0;
  client->terminal_offset = 0;
  client->terminal_input_offset = 0;
  client->stdin_input_owner = 0;
  client->terminal_input_owner = 0;
  client->v1_header_len = 0;
  client->v1_type = 0;
  client->v1_stream_id = 0;
  client->v1_offset = 0;
  client->v1_payload_len = 0;
  client->v1_payload_read = 0;
}

int send_client_output(struct session *session, struct client *client, const char *name, uint64_t *client_offset, uint64_t offset, const unsigned char *buf, size_t len) {
  if (client->fd < 0) return -1;
  if (*client_offset != offset) return 0;
  uint32_t stream_id = strcmp(name, "stdout") == 0 ? SPIO_STDOUT_STREAM : SPIO_STDERR_STREAM;
  if (send_spio_data(client->fd, stream_id, offset, buf, len) != 0) {
    close_client_input_lost(session, client);
    return -1;
  }
  *client_offset += len;
  return 0;
}

int send_client_terminal_output(struct session *session, struct client *client, uint64_t offset, const unsigned char *buf, size_t len) {
  if (client->fd < 0) return -1;
  if (client->terminal_offset != offset) return 0;
  if (send_spio_data(client->fd, SPIO_TERMINAL_STREAM, offset, buf, len) != 0) {
    close_client_input_lost(session, client);
    return -1;
  }
  client->terminal_offset += len;
  return 0;
}

void mirror_console(int is_stdout, const unsigned char *buf, size_t len) {
  int fd = is_stdout ? STDOUT_FILENO : STDERR_FILENO;
  (void)write_all(fd, buf, len);
}

int send_client_error_exit(struct client *client, int code, const char *message) {
  if (client->fd < 0) return -1;

  size_t len = strlen(message);
  if (len > 0) {
    if (send_spio_data(client->fd, SPIO_STDERR_STREAM, client->stderr_offset, (const unsigned char *)message, len) != 0) return -1;
    client->stderr_offset += len;
  }
  if (send_spio_timing_frame(client->fd) != 0) return -1;
  return send_spio_exit(client->fd, code);
}

int send_client_stdout(struct client *client, const char *message) {
  if (client->fd < 0) return -1;
  size_t len = strlen(message);
  if (len == 0) return 0;
  if (send_spio_data(client->fd, SPIO_STDOUT_STREAM, client->stdout_offset, (const unsigned char *)message, len) != 0) return -1;
  client->stdout_offset += len;
  return 0;
}

int send_client_exit(struct client *client, int code) {
  if (client->fd < 0) return -1;
  if (send_spio_timing_frame(client->fd) != 0) return -1;
  return send_spio_exit(client->fd, code);
}

int read_spio_header_blocking(int fd, uint8_t *type, uint32_t *stream_id, uint64_t *offset, uint32_t *payload_len) {
  unsigned char header[SPIO_HEADER_LEN];
  if (read_exact(fd, header, sizeof(header)) != 0) return -1;
  if (memcmp(header, SPIO_MAGIC, 4) != 0) return -1;
  if (header[4] != SPIO_VERSION) return -1;
  if (read_le16(header + 6) != 0) return -1;
  *type = header[5];
  *stream_id = read_le32(header + 8);
  *offset = read_le64(header + 12);
  *payload_len = read_le32(header + 20);
  if (*payload_len > MAX_FRAME_PAYLOAD) return -1;
  return 0;
}
