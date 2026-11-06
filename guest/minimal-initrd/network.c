// Static guest network setup and the build-mode resolv.conf bind.

#include "agent.h"

#define SPORE_NET_IFACE "eth0"
#define SPORE_NET_GUEST_IP "100.96.0.2"
#define SPORE_NET_GATEWAY_IP "100.96.0.1"
#define SPORE_NET_NETMASK "255.255.255.252"
#define SPORE_NET_RESOLV_CONF "nameserver 100.96.0.1\n"

struct build_resolv_state build_resolv;

static int sockaddr_in_addr(struct sockaddr *sa, const char *ip) {
  struct sockaddr_in sin;
  memset(&sin, 0, sizeof(sin));
  sin.sin_family = AF_INET;
  if (inet_pton(AF_INET, ip, &sin.sin_addr) != 1) return -1;
  memcpy(sa, &sin, sizeof(sin));
  return 0;
}

static int wait_for_iface(int fd, const char *name, int attempts, int sleep_us) {
  for (int i = 0; i < attempts; i++) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) == 0) return 0;
    usleep((useconds_t)sleep_us);
  }
  return -1;
}

static int set_iface_sockaddr(int fd, const char *name, unsigned long request, const char *ip) {
  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
  if (sockaddr_in_addr(&ifr.ifr_addr, ip) != 0) return -1;
  return ioctl(fd, request, &ifr);
}

static int bring_iface_up(int fd, const char *name) {
  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", name);
  if (ioctl(fd, SIOCGIFFLAGS, &ifr) != 0) return -1;
  ifr.ifr_flags |= IFF_UP;
  return ioctl(fd, SIOCSIFFLAGS, &ifr);
}

static int add_default_route(int fd, const char *name, const char *gateway) {
  struct rtentry route;
  memset(&route, 0, sizeof(route));
  if (sockaddr_in_addr(&route.rt_dst, "0.0.0.0") != 0) return -1;
  if (sockaddr_in_addr(&route.rt_gateway, gateway) != 0) return -1;
  if (sockaddr_in_addr(&route.rt_genmask, "0.0.0.0") != 0) return -1;
  route.rt_flags = RTF_UP | RTF_GATEWAY;
  route.rt_dev = (char *)name;
  if (ioctl(fd, SIOCADDRT, &route) != 0 && errno != EEXIST) return -1;
  return 0;
}

static int write_resolv_conf_path(const char *path) {
  return write_file_atomic(path, SPORE_NET_RESOLV_CONF, sizeof(SPORE_NET_RESOLV_CONF) - 1);
}

static int write_resolv_conf_with_parent(const char *path) {
  char parent[192];
  size_t len = strlen(path);
  if (len == 0 || len >= sizeof(parent)) return -1;
  memcpy(parent, path, len + 1);
  char *slash = strrchr(parent, '/');
  if (slash == NULL || slash == parent) return -1;
  *slash = '\0';
  if (mkdir_p(parent, 0755) != 0) return -1;
  return write_resolv_conf_path(path);
}

static int prepare_rootfs_resolv_targets(void) {
  if (write_resolv_conf_with_parent("/mnt/rootfs/run/sporevm/resolv.conf") != 0) return -1;
  if (write_resolv_conf_with_parent("/mnt/rootfs/run/systemd/resolve/stub-resolv.conf") != 0) return -1;
  if (write_resolv_conf_with_parent("/mnt/rootfs/run/systemd/resolve/resolv.conf") != 0) return -1;
  if (write_resolv_conf_with_parent("/mnt/rootfs/run/resolvconf/resolv.conf") != 0) return -1;
  return 0;
}

static int existing_rootfs_symlink_target(const char *link_path, char *out, size_t cap) {
  char target[512];
  if (readlink_bounded(link_path, target, sizeof(target)) < 0) return -1;

  char candidate[1024];
  int written = target[0] == '/'
      ? snprintf(candidate, sizeof(candidate), "/mnt/rootfs%s", target)
      : snprintf(candidate, sizeof(candidate), "/mnt/rootfs/etc/%s", target);
  if (written <= 0 || (size_t)written >= sizeof(candidate)) return -1;

  char resolved[1024];
  if (realpath(candidate, resolved) == NULL) return -1;
  const char prefix[] = "/mnt/rootfs";
  size_t prefix_len = sizeof(prefix) - 1;
  if (strncmp(resolved, prefix, prefix_len) != 0 || resolved[prefix_len] != '/') return -1;
  struct stat root_st;
  struct stat st;
  if (stat("/mnt/rootfs", &root_st) != 0) return -1;
  if (stat(resolved, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
  if (st.st_dev != root_st.st_dev) return -1;
  written = snprintf(out, cap, "%s", resolved);
  return written > 0 && (size_t)written < cap ? 0 : -1;
}

static void pop_build_resolv_component(char *path) {
  char *slash = strrchr(path, '/');
  if (slash == NULL) {
    path[0] = '\0';
  } else {
    *slash = '\0';
  }
}

static int append_build_resolv_component(char *path, size_t cap, const char *component) {
  size_t len = strlen(path);
  size_t component_len = strlen(component);
  if (component_len == 0 || len + (len == 0 ? 0 : 1) + component_len >= cap) return -1;
  if (len != 0) path[len++] = '/';
  memcpy(path + len, component, component_len + 1);
  return 0;
}

static int normalize_build_resolv_target(const char *raw_target, struct build_resolv_state *state) {
  size_t raw_len = strlen(raw_target);
  if (raw_len == 0 || raw_target[raw_len - 1] == '/') return -1;
  char pending[512];
  int written = snprintf(pending, sizeof(pending), "%s", raw_target);
  if (written <= 0 || (size_t)written >= sizeof(pending)) return -1;

  state->logical_target[0] = '\0';
  if (raw_target[0] != '/') {
    snprintf(state->logical_target, sizeof(state->logical_target), "%s", "etc");
  }
  char *save = NULL;
  for (char *component = strtok_r(pending, "/", &save); component != NULL; component = strtok_r(NULL, "/", &save)) {
    if (strcmp(component, ".") == 0) continue;
    if (strcmp(component, "..") == 0) {
      pop_build_resolv_component(state->logical_target);
      continue;
    }
    if (append_build_resolv_component(state->logical_target, sizeof(state->logical_target), component) != 0) return -1;
  }
  if (state->logical_target[0] == '\0') return -1;
  written = snprintf(state->mount_target, sizeof(state->mount_target), "/mnt/rootfs/%s", state->logical_target);
  return written > 0 && (size_t)written < sizeof(state->mount_target) ? 0 : -1;
}

static int cleanup_build_resolv_scaffold(struct build_resolv_state *state) {
  int rc = 0;
  if (state->created_file) {
    if (unlink(state->mount_target) != 0 && errno != ENOENT) rc = -1;
    state->created_file = 0;
  }
  for (size_t i = state->created_dir_count; i > 0; i--) {
    char path[sizeof(state->mount_target)];
    size_t len = state->created_dir_lens[i - 1];
    if (len == 0 || len >= sizeof(path)) {
      rc = -1;
      continue;
    }
    memcpy(path, state->mount_target, len);
    path[len] = '\0';
    if (rmdir(path) != 0 && errno != ENOENT && errno != ENOTEMPTY && errno != EEXIST) rc = -1;
  }
  state->created_dir_count = 0;
  return rc;
}

static int prepare_build_resolv_scaffold(struct build_resolv_state *state) {
  if (!state->scaffold) return 0;
  state->created_file = 0;
  state->created_dir_count = 0;

  char logical[sizeof(state->logical_target)];
  snprintf(logical, sizeof(logical), "%s", state->logical_target);
  char *components[MAX_BUILD_RESOLV_COMPONENTS];
  size_t component_count = 0;
  char *save = NULL;
  for (char *component = strtok_r(logical, "/", &save); component != NULL; component = strtok_r(NULL, "/", &save)) {
    if (component_count == MAX_BUILD_RESOLV_COMPONENTS) return -1;
    components[component_count++] = component;
  }
  if (component_count == 0) return -1;

  char path[sizeof(state->mount_target)];
  snprintf(path, sizeof(path), "%s", "/mnt/rootfs");
  struct stat root_st;
  if (stat(path, &root_st) != 0) return -1;
  for (size_t i = 0; i < component_count; i++) {
    size_t len = strlen(path);
    int written = snprintf(path + len, sizeof(path) - len, "/%s", components[i]);
    if (written <= 0 || (size_t)written >= sizeof(path) - len) goto fail;

    struct stat st;
    if (lstat(path, &st) == 0) {
      if (st.st_dev != root_st.st_dev) goto fail;
      if (i + 1 == component_count) {
        if (!S_ISREG(st.st_mode)) goto fail;
      } else if (!S_ISDIR(st.st_mode)) {
        goto fail;
      }
      continue;
    }
    if (errno != ENOENT) goto fail;
    if (i + 1 == component_count) {
      int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
      if (fd < 0) goto fail;
      state->created_file = 1;
      if (close(fd) != 0) goto fail;
    } else {
      if (mkdir(path, 0755) != 0) goto fail;
      state->created_dir_lens[state->created_dir_count++] = strlen(path);
    }
  }
  return 0;

fail:
  (void)cleanup_build_resolv_scaffold(state);
  return -1;
}

static int mount_build_resolv(struct build_resolv_state *state) {
  if (!state->configured || state->mounted) return 0;
  if (state->link_configured) {
    struct stat st;
    char target[512];
    struct build_resolv_state current;
    memset(&current, 0, sizeof(current));
    if (lstat(state->link_path, &st) != 0 || !S_ISLNK(st.st_mode) ||
        readlink_bounded(state->link_path, target, sizeof(target)) < 0 ||
        normalize_build_resolv_target(target, &current) != 0 ||
        strcmp(current.logical_target, state->logical_target) != 0 ||
        strcmp(current.mount_target, state->mount_target) != 0) {
      return -1;
    }
  }
  if (prepare_build_resolv_scaffold(state) != 0) return -1;
  if (mount("/run/sporevm/resolv.conf", state->mount_target, NULL, MS_BIND, NULL) != 0) {
    (void)cleanup_build_resolv_scaffold(state);
    return -1;
  }
  state->mounted = 1;
  return 0;
}

int unmount_build_resolv_for_snapshot(struct build_resolv_state *state) {
  if (!state->configured || !state->mounted) return 0;
  if (umount(state->mount_target) != 0) return -1;
  state->mounted = 0;
  return cleanup_build_resolv_scaffold(state);
}

static int configure_build_resolv_symlink(const char *link_path, struct build_resolv_state *state) {
  int link_written = snprintf(state->link_path, sizeof(state->link_path), "%s", link_path);
  if (link_written <= 0 || (size_t)link_written >= sizeof(state->link_path)) return -1;
  state->link_configured = 1;
  char target[512];
  if (existing_rootfs_symlink_target(link_path, state->mount_target, sizeof(state->mount_target)) == 0) {
    state->scaffold = 0;
  } else {
    if (readlink_bounded(link_path, target, sizeof(target)) < 0) return -1;
    if (normalize_build_resolv_target(target, state) != 0) return -1;
    state->scaffold = 1;
  }
  state->configured = 1;
  return mount_build_resolv(state);
}

int bind_rootfs_resolv(int build_mode, char *error, size_t cap) {
  if (!path_is_dir("/mnt/rootfs/etc")) {
    snprintf(error, cap, "network setup failed: rootfs /etc missing");
    return -1;
  }
  struct stat st;
  if (lstat("/mnt/rootfs/etc/resolv.conf", &st) != 0) {
    snprintf(error, cap, "network setup failed: rootfs /etc/resolv.conf missing");
    return -1;
  }
  if (build_mode) {
    if (write_resolv_conf_path("/run/sporevm/resolv.conf") != 0) {
      snprintf(error, cap, "network setup failed: refresh build resolver source errno=%d", errno);
      return -1;
    }
    memset(&build_resolv, 0, sizeof(build_resolv));
    int rc = -1;
    if (S_ISLNK(st.st_mode)) {
      rc = configure_build_resolv_symlink("/mnt/rootfs/etc/resolv.conf", &build_resolv);
    } else if (S_ISREG(st.st_mode)) {
      struct stat root_st;
      if (stat("/mnt/rootfs", &root_st) == 0 && st.st_dev == root_st.st_dev) {
        int written = snprintf(build_resolv.mount_target, sizeof(build_resolv.mount_target), "%s", "/mnt/rootfs/etc/resolv.conf");
        if (written > 0 && (size_t)written < sizeof(build_resolv.mount_target)) {
          build_resolv.configured = 1;
          rc = mount_build_resolv(&build_resolv);
        }
      }
    }
    if (rc != 0) {
      snprintf(error, cap, "network setup failed: build rootfs resolv target unavailable errno=%d", errno);
      return -1;
    }
    return 0;
  }
  if (S_ISLNK(st.st_mode)) {
    if (prepare_rootfs_resolv_targets() != 0) {
      snprintf(error, cap, "network setup failed: rootfs resolv target errno=%d", errno);
      return -1;
    }
    return 0;
  }
  if (prepare_rootfs_resolv_targets() != 0) {
    snprintf(error, cap, "network setup failed: rootfs resolv target errno=%d", errno);
    return -1;
  }
  if (mount("/run/sporevm/resolv.conf", "/mnt/rootfs/etc/resolv.conf", NULL, MS_BIND, NULL) != 0 && errno != EBUSY) {
    snprintf(error, cap, "network setup failed: rootfs resolv.conf bind errno=%d", errno);
    return -1;
  }
  return 0;
}

int setup_network(int use_rootfs, int build_mode, char *error, size_t cap) {
  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    snprintf(error, cap, "network setup failed: socket errno=%d", errno);
    return -1;
  }

  if (wait_for_iface(fd, SPORE_NET_IFACE, 100, 50000) != 0) {
    snprintf(error, cap, "network setup failed: %s not found", SPORE_NET_IFACE);
    close(fd);
    return -1;
  }
  if (set_iface_sockaddr(fd, SPORE_NET_IFACE, SIOCSIFADDR, SPORE_NET_GUEST_IP) != 0) {
    snprintf(error, cap, "network setup failed: set address errno=%d", errno);
    close(fd);
    return -1;
  }
  if (set_iface_sockaddr(fd, SPORE_NET_IFACE, SIOCSIFNETMASK, SPORE_NET_NETMASK) != 0) {
    snprintf(error, cap, "network setup failed: set netmask errno=%d", errno);
    close(fd);
    return -1;
  }
  if (bring_iface_up(fd, SPORE_NET_IFACE) != 0) {
    snprintf(error, cap, "network setup failed: bring link up errno=%d", errno);
    close(fd);
    return -1;
  }
  if (add_default_route(fd, SPORE_NET_IFACE, SPORE_NET_GATEWAY_IP) != 0) {
    snprintf(error, cap, "network setup failed: default route errno=%d", errno);
    close(fd);
    return -1;
  }
  close(fd);

  mkdir("/etc", 0755);
  if (write_resolv_conf_path("/etc/resolv.conf") != 0) {
    snprintf(error, cap, "network setup failed: write /etc/resolv.conf errno=%d", errno);
    return -1;
  }

  if (use_rootfs) {
    mkdir("/run/sporevm", 0755);
    if (write_resolv_conf_path("/run/sporevm/resolv.conf") != 0) {
      snprintf(error, cap, "network setup failed: write rootfs resolv source errno=%d", errno);
      return -1;
    }
    if (bind_rootfs_resolv(build_mode, error, cap) != 0) return -1;
  }
  return 0;
}

#ifdef SPORE_AGENT_REQUEST_FUZZ
__attribute__((visibility("hidden"))) int spore_agent_fuzz_build_resolv_target(
    const unsigned char *target_bytes, size_t target_len,
    unsigned char *logical_bytes, size_t logical_cap) {
  if (target_len >= 512 || logical_cap == 0) return -1;
  char target[512];
  memcpy(target, target_bytes, target_len);
  target[target_len] = '\0';
  struct build_resolv_state state;
  memset(&state, 0, sizeof(state));
  if (normalize_build_resolv_target(target, &state) != 0) return -1;
  size_t logical_len = strlen(state.logical_target);
  if (logical_len + 1 > logical_cap) return -1;
  memcpy(logical_bytes, state.logical_target, logical_len + 1);
  return 0;
}
#endif
