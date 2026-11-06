#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define DNS_MAX 512
#define DEFAULT_SERVER "100.96.0.1"
#define DNS_PORT 53

static uint16_t read_be16(const unsigned char *p) {
  return (uint16_t)((uint16_t)p[0] << 8 | p[1]);
}

static void write_be16(unsigned char *p, uint16_t value) {
  p[0] = (unsigned char)(value >> 8);
  p[1] = (unsigned char)(value & 0xff);
}

static int encode_qname(const char *name, unsigned char *out, size_t cap, size_t *len) {
  size_t pos = 0;
  const char *label = name;
  if (name[0] == '\0') return -1;
  while (*label != '\0') {
    const char *dot = strchr(label, '.');
    size_t label_len = dot == NULL ? strlen(label) : (size_t)(dot - label);
    if (label_len == 0 || label_len > 63 || pos + 1 + label_len + 1 > cap) return -1;
    out[pos++] = (unsigned char)label_len;
    memcpy(out + pos, label, label_len);
    pos += label_len;
    if (dot == NULL) break;
    label = dot + 1;
  }
  out[pos++] = 0;
  *len = pos;
  return 0;
}

static int build_query(const char *name, unsigned char *out, size_t cap, uint16_t id, size_t *len) {
  if (cap < 18) return -1;
  memset(out, 0, cap);
  write_be16(out + 0, id);
  write_be16(out + 2, 0x0100);
  write_be16(out + 4, 1);
  size_t pos = 12;
  size_t qname_len = 0;
  if (encode_qname(name, out + pos, cap - pos, &qname_len) != 0) return -1;
  pos += qname_len;
  if (pos + 4 > cap) return -1;
  write_be16(out + pos, 1);
  write_be16(out + pos + 2, 1);
  *len = pos + 4;
  return 0;
}

static int skip_dns_name(const unsigned char *msg, size_t n, size_t *offset) {
  size_t pos = *offset;
  size_t end = 0;
  size_t jumps = 0;
  size_t total = 0;
  int jumped = 0;
  for (;;) {
    if (pos >= n) return -1;
    unsigned char len = msg[pos];
    if ((len & 0xc0) == 0xc0) {
      if (pos + 1 >= n) return -1;
      size_t ptr = (size_t)(len & 0x3f) << 8 | msg[pos + 1];
      if (ptr >= n) return -1;
      if (!jumped) {
        end = pos + 2;
        jumped = 1;
      }
      if (++jumps > 16) return -1;
      pos = ptr;
      continue;
    }
    if ((len & 0xc0) != 0) return -1;
    pos++;
    if (len == 0) {
      *offset = jumped ? end : pos;
      return 0;
    }
    if (len > 63 || pos + len > n) return -1;
    total += (size_t)len + 1;
    if (total > 255) return -1;
    pos += len;
  }
}

static int read_resolver(char *out, size_t cap) {
  snprintf(out, cap, "%s", DEFAULT_SERVER);
  int fd = open("/etc/resolv.conf", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
  char buf[1024];
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n <= 0) return 0;
  buf[n] = '\0';

  char *save = NULL;
  for (char *line = strtok_r(buf, "\n", &save); line != NULL; line = strtok_r(NULL, "\n", &save)) {
    while (*line == ' ' || *line == '\t') line++;
    if (strncmp(line, "nameserver", 10) != 0) continue;
    if (line[10] != ' ' && line[10] != '\t') continue;
    line += 10;
    while (*line == ' ' || *line == '\t') line++;
    char candidate[64];
    size_t len = 0;
    while (line[len] != '\0' && line[len] != ' ' && line[len] != '\t' && line[len] != '#') len++;
    if (len == 0 || len >= sizeof(candidate)) continue;
    memcpy(candidate, line, len);
    candidate[len] = '\0';
    struct in_addr addr;
    if (inet_pton(AF_INET, candidate, &addr) == 1) {
      snprintf(out, cap, "%s", candidate);
      return 0;
    }
  }
  return 0;
}

static int find_a_answer(const unsigned char *response, size_t n, uint16_t id, char *addr, size_t cap) {
  if (n < 12) return -1;
  if (read_be16(response) != id) return -1;
  uint16_t flags = read_be16(response + 2);
  if ((flags & 0x8000) == 0 || (flags & 0x000f) != 0) return -1;
  uint16_t qdcount = read_be16(response + 4);
  uint16_t ancount = read_be16(response + 6);
  size_t off = 12;
  for (uint16_t i = 0; i < qdcount; i++) {
    if (skip_dns_name(response, n, &off) != 0 || off + 4 > n) return -1;
    off += 4;
  }
  for (uint16_t i = 0; i < ancount; i++) {
    if (skip_dns_name(response, n, &off) != 0 || off + 10 > n) return -1;
    uint16_t type = read_be16(response + off);
    uint16_t klass = read_be16(response + off + 2);
    uint16_t rdlen = read_be16(response + off + 8);
    off += 10;
    if (off + rdlen > n) return -1;
    if (type == 1 && klass == 1 && rdlen == 4) {
      return inet_ntop(AF_INET, response + off, addr, cap) == NULL ? -1 : 0;
    }
    off += rdlen;
  }
  return -1;
}

int main(int argc, char **argv) {
  const char *name = argc > 1 ? argv[1] : "example.com";
  char server[64];
  read_resolver(server, sizeof(server));

  unsigned char query[DNS_MAX];
  size_t query_len = 0;
  uint16_t id = (uint16_t)((unsigned int)getpid() ^ 0x5350u);
  if (build_query(name, query, sizeof(query), id, &query_len) != 0) {
    dprintf(2, "nslookup: invalid name: %s\n", name);
    return 2;
  }

  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    dprintf(2, "nslookup: socket failed errno=%d\n", errno);
    return 2;
  }
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(DNS_PORT);
  if (inet_pton(AF_INET, server, &sa.sin_addr) != 1) {
    dprintf(2, "nslookup: invalid resolver: %s\n", server);
    close(fd);
    return 2;
  }
  if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
    dprintf(2, "nslookup: connect failed errno=%d\n", errno);
    close(fd);
    return 2;
  }
  if (send(fd, query, query_len, 0) != (ssize_t)query_len) {
    dprintf(2, "nslookup: send failed errno=%d\n", errno);
    close(fd);
    return 2;
  }

  struct pollfd pfd;
  memset(&pfd, 0, sizeof(pfd));
  pfd.fd = fd;
  pfd.events = POLLIN;
  int ready = poll(&pfd, 1, 2000);
  if (ready <= 0) {
    dprintf(2, "nslookup: DNS timeout\n");
    close(fd);
    return 1;
  }

  unsigned char response[DNS_MAX];
  ssize_t n = recv(fd, response, sizeof(response), 0);
  close(fd);
  if (n <= 0) {
    dprintf(2, "nslookup: receive failed errno=%d\n", errno);
    return 1;
  }

  char address[INET_ADDRSTRLEN];
  if (find_a_answer(response, (size_t)n, id, address, sizeof(address)) != 0) {
    dprintf(2, "nslookup: no A answer for %s\n", name);
    return 1;
  }

  printf("Server: %s\n", server);
  printf("Name: %s\n", name);
  printf("Address: %s\n", address);
  return 0;
}
