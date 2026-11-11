// Exercise guest-local TCP, not the userspace egress gateway.
#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

static void fail(const char *label) {
  perror(label);
  exit(1);
}

static void tcp_roundtrip(int family, const char *ip) {
  int server = socket(family, SOCK_STREAM, 0);
  if (server < 0) fail("loopcheck socket");
  struct sockaddr_storage address = {0};
  socklen_t len;
  if (family == AF_INET) {
    struct sockaddr_in *v4 = (struct sockaddr_in *)&address;
    v4->sin_family = AF_INET;
    if (inet_pton(family, ip, &v4->sin_addr) != 1) fail("loopcheck IPv4");
    len = sizeof(*v4);
  } else {
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&address;
    v6->sin6_family = AF_INET6;
    if (inet_pton(family, ip, &v6->sin6_addr) != 1) fail("loopcheck IPv6");
    len = sizeof(*v6);
  }
  if (bind(server, (struct sockaddr *)&address, len) != 0) fail("loopcheck bind");
  if (getsockname(server, (struct sockaddr *)&address, &len) != 0) fail("loopcheck port");
  if (listen(server, 1) != 0) fail("loopcheck listen");
  int client = socket(family, SOCK_STREAM, 0);
  if (client < 0 || connect(client, (struct sockaddr *)&address, len) != 0) fail("loopcheck connect");
  struct sockaddr_storage peer;
  socklen_t peer_len = sizeof(peer);
  int accepted = accept(server, (struct sockaddr *)&peer, &peer_len);
  if (accepted < 0) fail("loopcheck accept");
  if (family == AF_INET &&
      (ntohl(((struct sockaddr_in *)&peer)->sin_addr.s_addr) >> 24) != 127) {
    fprintf(stderr, "loopcheck: connection did not use a loopback source\n");
    exit(1);
  }
  char byte = 0;
  if (write(client, "L", 1) != 1 || read(accepted, &byte, 1) != 1 || byte != 'L' ||
      write(accepted, "R", 1) != 1 || read(client, &byte, 1) != 1 || byte != 'R') fail("loopcheck data");
  close(accepted);
  close(client);
  close(server);
}

int main(void) {
  alarm(5);
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) fail("loopcheck ioctl socket");
  struct ifreq ifr = {0};
  strcpy(ifr.ifr_name, "lo");
  if (ioctl(fd, SIOCGIFFLAGS, &ifr) != 0 || !(ifr.ifr_flags & IFF_UP)) {
    fprintf(stderr, "loopcheck: lo is not UP\n");
    return 1;
  }
  if (ioctl(fd, SIOCGIFADDR, &ifr) != 0 ||
      ntohl(((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr.s_addr) != 0x7f000001) {
    fprintf(stderr, "loopcheck: lo is not 127.0.0.1\n");
    return 1;
  }
  if (ioctl(fd, SIOCGIFNETMASK, &ifr) != 0 ||
      ntohl(((struct sockaddr_in *)&ifr.ifr_netmask)->sin_addr.s_addr) != 0xff000000) {
    fprintf(stderr, "loopcheck: lo is not /8\n");
    return 1;
  }
  close(fd);
  struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM};
  struct addrinfo *resolved = NULL;
  if (getaddrinfo("localhost", NULL, &hints, &resolved) != 0 || resolved == NULL ||
      ntohl(((struct sockaddr_in *)resolved->ai_addr)->sin_addr.s_addr) != 0x7f000001) {
    fprintf(stderr, "loopcheck: localhost does not resolve to 127.0.0.1\n");
    return 1;
  }
  freeaddrinfo(resolved);
  tcp_roundtrip(AF_INET, "127.0.0.1");
  tcp_roundtrip(AF_INET, "127.42.7.9");
  fd = socket(AF_INET6, SOCK_STREAM, 0);
  if (fd >= 0) {
    close(fd);
    tcp_roundtrip(AF_INET6, "::1");
    puts("loopcheck IPv6 ::1 ok");
  } else if (errno != EAFNOSUPPORT && errno != EPROTONOSUPPORT) {
    fail("loopcheck IPv6 socket");
  } else {
    puts("loopcheck IPv6 unavailable in kernel");
  }
  puts("spore-loopcheck ok");
  return 0;
}
