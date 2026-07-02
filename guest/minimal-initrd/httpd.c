#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int parse_port(const char *raw) {
  char *end = NULL;
  long value = strtol(raw, &end, 10);
  if (raw[0] == '\0' || *end != '\0' || value <= 0 || value > 65535) return -1;
  return (int)value;
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

int main(int argc, char **argv) {
  int port = 8080;
  if (argc == 2) {
    port = parse_port(argv[1]);
    if (port < 0) {
      fprintf(stderr, "httpd: invalid port\n");
      return 2;
    }
  } else if (argc != 1) {
    fprintf(stderr, "usage: httpd [port]\n");
    return 2;
  }

  int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (listener < 0) {
    perror("httpd: socket");
    return 1;
  }

  int reuse = 1;
  (void)setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = htons((uint16_t)port);
  if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    perror("httpd: bind");
    close(listener);
    return 1;
  }
  if (listen(listener, 8) != 0) {
    perror("httpd: listen");
    close(listener);
    return 1;
  }
  printf("httpd ready\n");
  fflush(stdout);

  int conn;
  do {
    conn = accept(listener, NULL, NULL);
  } while (conn < 0 && errno == EINTR);
  close(listener);
  if (conn < 0) {
    perror("httpd: accept");
    return 1;
  }

  char request[512];
  (void)recv(conn, request, sizeof(request), 0);
  const char response[] = "HTTP/1.1 200 OK\r\nContent-Length: 17\r\nConnection: close\r\n\r\nspore forward ok\n";
  int rc = write_all(conn, response, sizeof(response) - 1);
  close(conn);
  return rc == 0 ? 0 : 1;
}
