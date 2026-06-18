#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define WGET_TIMEOUT_MS 5000
#define WGET_MAX_BODY (1024 * 1024)

struct url_parts {
  char host[256];
  char port[8];
  char path[512];
};

static int parse_http_url(const char *url, struct url_parts *out) {
  const char *prefix = "http://";
  size_t prefix_len = strlen(prefix);
  if (strncmp(url, prefix, prefix_len) != 0) return -1;
  const char *rest = url + prefix_len;
  const char *slash = strchr(rest, '/');
  const char *host_end = slash == NULL ? rest + strlen(rest) : slash;
  if (host_end == rest) return -1;

  const char *colon = memchr(rest, ':', (size_t)(host_end - rest));
  const char *name_end = colon == NULL ? host_end : colon;
  size_t host_len = (size_t)(name_end - rest);
  if (host_len == 0 || host_len >= sizeof(out->host)) return -1;
  memcpy(out->host, rest, host_len);
  out->host[host_len] = '\0';

  if (colon != NULL) {
    size_t port_len = (size_t)(host_end - colon - 1);
    if (port_len == 0 || port_len >= sizeof(out->port)) return -1;
    memcpy(out->port, colon + 1, port_len);
    out->port[port_len] = '\0';
  } else {
    snprintf(out->port, sizeof(out->port), "80");
  }

  const char *path = slash == NULL ? "/" : slash;
  if (strlen(path) >= sizeof(out->path)) return -1;
  snprintf(out->path, sizeof(out->path), "%s", path);
  return 0;
}

static int wait_fd(int fd, short events) {
  struct pollfd pfd;
  memset(&pfd, 0, sizeof(pfd));
  pfd.fd = fd;
  pfd.events = events;
  int rc = poll(&pfd, 1, WGET_TIMEOUT_MS);
  if (rc <= 0) return -1;
  if ((pfd.revents & (POLLERR | POLLNVAL)) != 0) return -1;
  return (pfd.revents & events) != 0 ? 0 : -1;
}

static int connect_timeout(const struct addrinfo *ai) {
  int fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
  if (fd < 0) return -1;
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
    close(fd);
    return -1;
  }
  if (connect(fd, ai->ai_addr, ai->ai_addrlen) != 0) {
    if (errno != EINPROGRESS) {
      close(fd);
      return -1;
    }
    if (wait_fd(fd, POLLOUT) != 0) {
      close(fd);
      return -1;
    }
    int err = 0;
    socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
      close(fd);
      return -1;
    }
  }
  (void)fcntl(fd, F_SETFL, flags);
  return fd;
}

static int write_all(int fd, const char *buf, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = send(fd, buf + done, len - done, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return -1;
    done += (size_t)n;
  }
  return 0;
}

static int write_stdout_all(const char *buf, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = write(STDOUT_FILENO, buf + done, len - done);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return -1;
    done += (size_t)n;
  }
  return 0;
}

static int find_header_end(const char *buf, size_t len) {
  for (size_t i = 3; i < len; i++) {
    if (buf[i - 3] == '\r' && buf[i - 2] == '\n' && buf[i - 1] == '\r' && buf[i] == '\n') {
      return (int)(i + 1);
    }
  }
  return -1;
}

static int status_ok(const char *buf, size_t len) {
  if (len < 12 || strncmp(buf, "HTTP/", 5) != 0) return 0;
  const char *space = memchr(buf, ' ', len);
  if (space == NULL || space + 3 >= buf + len) return 0;
  int code = (space[1] - '0') * 100 + (space[2] - '0') * 10 + (space[3] - '0');
  return code >= 200 && code < 400;
}

int main(int argc, char **argv) {
  const char *url = NULL;
  if (argc == 2) {
    url = argv[1];
  } else if (argc == 3 && strcmp(argv[1], "-qO-") == 0) {
    url = argv[2];
  } else {
    dprintf(2, "wget: usage: wget [-qO-] http://host[:port]/path\n");
    return 2;
  }

  struct url_parts parts;
  if (parse_http_url(url, &parts) != 0) {
    dprintf(2, "wget: unsupported URL: %s\n", url);
    return 2;
  }

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *res = NULL;
  int gai = getaddrinfo(parts.host, parts.port, &hints, &res);
  if (gai != 0) {
    dprintf(2, "wget: resolve failed for %s: %s\n", parts.host, gai_strerror(gai));
    return 1;
  }

  int fd = -1;
  for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
    fd = connect_timeout(ai);
    if (fd >= 0) break;
  }
  freeaddrinfo(res);
  if (fd < 0) {
    dprintf(2, "wget: connect failed for %s:%s errno=%d\n", parts.host, parts.port, errno);
    return 1;
  }

  char request[1024];
  int request_len = snprintf(request, sizeof(request),
                             "GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: sporevm-wget\r\nConnection: close\r\n\r\n",
                             parts.path, parts.host);
  if (request_len <= 0 || (size_t)request_len >= sizeof(request) ||
      write_all(fd, request, (size_t)request_len) != 0) {
    dprintf(2, "wget: request failed errno=%d\n", errno);
    close(fd);
    return 1;
  }

  char buf[4096];
  char header[8192];
  size_t header_len = 0;
  int headers_done = 0;
  size_t body_len = 0;

  for (;;) {
    if (wait_fd(fd, POLLIN) != 0) {
      dprintf(2, "wget: receive timeout\n");
      close(fd);
      return 1;
    }
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      dprintf(2, "wget: receive failed errno=%d\n", errno);
      close(fd);
      return 1;
    }
    if (n == 0) break;

    const char *chunk = buf;
    size_t chunk_len = (size_t)n;
    if (!headers_done) {
      if (header_len + chunk_len > sizeof(header)) {
        dprintf(2, "wget: response headers too large\n");
        close(fd);
        return 1;
      }
      memcpy(header + header_len, chunk, chunk_len);
      header_len += chunk_len;
      int header_end = find_header_end(header, header_len);
      if (header_end < 0) continue;
      if (!status_ok(header, header_len)) {
        dprintf(2, "wget: HTTP status was not successful\n");
        close(fd);
        return 1;
      }
      headers_done = 1;
      chunk = header + header_end;
      chunk_len = header_len - (size_t)header_end;
    }

    if (chunk_len > 0) {
      body_len += chunk_len;
      if (body_len > WGET_MAX_BODY) {
        dprintf(2, "wget: response body too large\n");
        close(fd);
        return 1;
      }
      if (write_stdout_all(chunk, chunk_len) != 0) {
        close(fd);
        return 1;
      }
    }
  }

  close(fd);
  return headers_done ? 0 : 1;
}
