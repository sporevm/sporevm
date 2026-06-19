#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#define SPORE_NET_IFACE "eth0"
#define SPORE_NET_MAC "02:53:50:4f:52:45"
#define SPORE_NET_GATEWAY_MAC "02:53:50:4f:52:01"
#define SPORE_NET_GUEST_IP "100.96.0.2"
#define SPORE_NET_GATEWAY_IP "100.96.0.1"
#define SPORE_NET_NETMASK "255.255.255.252"

static int read_file(const char *path, char *buf, size_t cap) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  ssize_t n = read(fd, buf, cap - 1);
  close(fd);
  if (n < 0) return -1;
  buf[n] = '\0';
  return 0;
}

static int iface_sockaddr(const char *name, unsigned long request, char *out, size_t cap) {
  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
  int rc = ioctl(fd, request, &ifr);
  close(fd);
  if (rc != 0) return -1;
  const struct sockaddr_in *sin = (const struct sockaddr_in *)&ifr.ifr_addr;
  return inet_ntop(AF_INET, &sin->sin_addr, out, cap) == NULL ? -1 : 0;
}

static int iface_mac(const char *name, char *out, size_t cap) {
  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
  int rc = ioctl(fd, SIOCGIFHWADDR, &ifr);
  close(fd);
  if (rc != 0) return -1;
  const unsigned char *mac = (const unsigned char *)ifr.ifr_hwaddr.sa_data;
  int n = snprintf(out, cap, "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int iface_is_up(const char *name) {
  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return 0;
  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
  int rc = ioctl(fd, SIOCGIFFLAGS, &ifr);
  close(fd);
  return rc == 0 && (ifr.ifr_flags & IFF_UP) != 0;
}

static uint32_t route_value(const char *ip) {
  struct in_addr addr;
  if (inet_pton(AF_INET, ip, &addr) != 1) return 0;
  uint32_t value = 0;
  memcpy(&value, &addr.s_addr, sizeof(value));
  return value;
}

static int have_default_route(void) {
  char buf[8192];
  if (read_file("/proc/net/route", buf, sizeof(buf)) != 0) return 0;
  const uint32_t gateway = route_value(SPORE_NET_GATEWAY_IP);
  char *save = NULL;
  for (char *line = strtok_r(buf, "\n", &save); line != NULL; line = strtok_r(NULL, "\n", &save)) {
    char iface[32];
    unsigned long destination = 0;
    unsigned long route_gateway = 0;
    unsigned long flags = 0;
    unsigned long mask = 0;
    int fields = sscanf(line, "%31s %lx %lx %lx %*s %*s %*s %lx", iface, &destination, &route_gateway, &flags, &mask);
    if (fields == 5 &&
        strcmp(iface, SPORE_NET_IFACE) == 0 &&
        destination == 0 &&
        mask == 0 &&
        route_gateway == gateway &&
        (flags & 0x3) == 0x3) {
      return 1;
    }
  }
  return 0;
}

static int have_resolver(void) {
  char buf[1024];
  if (read_file("/etc/resolv.conf", buf, sizeof(buf)) != 0) return 0;
  return strstr(buf, "nameserver " SPORE_NET_GATEWAY_IP) != NULL;
}

static int trigger_gateway_arp(void) {
  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(53);
  int rc = -1;
  if (inet_pton(AF_INET, SPORE_NET_GATEWAY_IP, &sa.sin_addr) == 1) {
    char b = '\0';
    rc = sendto(fd, &b, sizeof(b), 0, (struct sockaddr *)&sa, sizeof(sa)) == sizeof(b) ? 0 : -1;
  }
  int saved = errno;
  close(fd);
  errno = saved;
  return rc;
}

static int have_gateway_arp(int *send_errno) {
  for (int attempt = 0; attempt < 20; attempt++) {
    if (trigger_gateway_arp() != 0 && send_errno != NULL && *send_errno == 0) *send_errno = errno;
    usleep(50000);
    char buf[4096];
    if (read_file("/proc/net/arp", buf, sizeof(buf)) == 0) {
      char *save = NULL;
      for (char *line = strtok_r(buf, "\n", &save); line != NULL; line = strtok_r(NULL, "\n", &save)) {
        char ip[64];
        char hw_type[16];
        char flags[16];
        char mac[32];
        char mask[16];
        char dev[32];
        if (sscanf(line, "%63s %15s %15s %31s %15s %31s", ip, hw_type, flags, mac, mask, dev) == 6 &&
            strcmp(ip, SPORE_NET_GATEWAY_IP) == 0 &&
            strcmp(mac, SPORE_NET_GATEWAY_MAC) == 0 &&
            strcmp(dev, SPORE_NET_IFACE) == 0) {
          return 1;
        }
      }
    }
  }
  return 0;
}

int main(void) {
  int ok = 1;
  char mac[32];
  char ip[64];
  char netmask[64];

  if (iface_mac(SPORE_NET_IFACE, mac, sizeof(mac)) != 0 || strcmp(mac, SPORE_NET_MAC) != 0) {
    dprintf(2, "spore-netcheck: expected %s mac %s\n", SPORE_NET_IFACE, SPORE_NET_MAC);
    ok = 0;
  }
  if (iface_sockaddr(SPORE_NET_IFACE, SIOCGIFADDR, ip, sizeof(ip)) != 0 || strcmp(ip, SPORE_NET_GUEST_IP) != 0) {
    dprintf(2, "spore-netcheck: expected %s address %s\n", SPORE_NET_IFACE, SPORE_NET_GUEST_IP);
    ok = 0;
  }
  if (iface_sockaddr(SPORE_NET_IFACE, SIOCGIFNETMASK, netmask, sizeof(netmask)) != 0 || strcmp(netmask, SPORE_NET_NETMASK) != 0) {
    dprintf(2, "spore-netcheck: expected %s netmask %s\n", SPORE_NET_IFACE, SPORE_NET_NETMASK);
    ok = 0;
  }
  if (!iface_is_up(SPORE_NET_IFACE)) {
    dprintf(2, "spore-netcheck: expected %s up\n", SPORE_NET_IFACE);
    ok = 0;
  }
  if (!have_default_route()) {
    dprintf(2, "spore-netcheck: expected default route via %s\n", SPORE_NET_GATEWAY_IP);
    ok = 0;
  }
  if (!have_resolver()) {
    dprintf(2, "spore-netcheck: expected resolver %s\n", SPORE_NET_GATEWAY_IP);
    ok = 0;
  }
  int arp_send_errno = 0;
  if (!have_gateway_arp(&arp_send_errno)) {
    char arp_table[4096];
    if (arp_send_errno != 0) {
      dprintf(2, "spore-netcheck: expected ARP entry %s %s; UDP probe errno=%d\n", SPORE_NET_GATEWAY_IP, SPORE_NET_GATEWAY_MAC, arp_send_errno);
    } else {
      dprintf(2, "spore-netcheck: expected ARP entry %s %s\n", SPORE_NET_GATEWAY_IP, SPORE_NET_GATEWAY_MAC);
    }
    if (read_file("/proc/net/arp", arp_table, sizeof(arp_table)) == 0) {
      dprintf(2, "spore-netcheck: /proc/net/arp:\n%s", arp_table);
    }
    ok = 0;
  }

  if (!ok) return 1;
  printf("spore-netcheck ok iface=%s mac=%s ip=%s netmask=%s gateway=%s dns=%s arp=%s\n",
         SPORE_NET_IFACE,
         mac,
         ip,
         netmask,
         SPORE_NET_GATEWAY_IP,
         SPORE_NET_GATEWAY_IP,
         SPORE_NET_GATEWAY_MAC);
  return 0;
}
