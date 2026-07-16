#define _GNU_SOURCE
#include "build_copy.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

#define MAX_COPY_PATH_LEN SPORE_BUILD_COPY_PATH_MAX
#define MAX_COPY_FULL_PATH_LEN 1024
#define MAX_FRAME_PAYLOAD 4096
#define COPY_KIND_FILE SPORE_BUILD_COPY_KIND_FILE
#define COPY_KIND_DIR SPORE_BUILD_COPY_KIND_DIR
#define COPY_KIND_SYMLINK SPORE_BUILD_COPY_KIND_SYMLINK
#define COPY_KIND_AUTO SPORE_BUILD_COPY_KIND_AUTO
#define MAX_BUILD_CONTEXT_COPY_ENTRIES SPORE_BUILD_COPY_MAX_ENTRIES
#define BUILD_AGENT_FD_BUDGET SPORE_BUILD_COPY_FD_BUDGET
#define MAX_COPY_XATTR_NAMES 512
#define MAX_COPY_XATTR_VALUE 256
#ifndef SYS_openat2
#if defined(__aarch64__) || defined(__x86_64__)
#define SYS_openat2 437
#endif
#endif
#ifndef RESOLVE_NO_MAGICLINKS
#define RESOLVE_NO_MAGICLINKS 0x02
#endif
#ifndef RESOLVE_IN_ROOT
#define RESOLVE_IN_ROOT 0x10
#endif
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif
#define MAX_SYMLINK_DEPTH 40

static int write_all(int fd, const void *raw, size_t len) {
  const unsigned char *buf = raw;
  while (len > 0) {
    ssize_t n = write(fd, buf, len);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) {
      errno = EIO;
      return -1;
    }
    buf += (size_t)n;
    len -= (size_t)n;
  }
  return 0;
}

static int read_exact(int fd, void *raw, size_t len) {
  unsigned char *buf = raw;
  while (len > 0) {
    ssize_t n = read(fd, buf, len);
    if (n == 0) return -1;
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    buf += (size_t)n;
    len -= (size_t)n;
  }
  return 0;
}

static ssize_t readlinkat_bounded(int dir_fd, const char *path, char *out, size_t cap) {
  if (cap < 2) {
    errno = ENAMETOOLONG;
    return -1;
  }
  ssize_t len = readlinkat(dir_fd, path, out, cap);
  if (len <= 0) return -1;
  if ((size_t)len == cap) {
    errno = ENAMETOOLONG;
    return -1;
  }
  out[len] = '\0';
  return len;
}

static int validate_spore_copy_entry_path(const char *path) {
  if (path[0] != '/' || path[1] == '\0') return -1;
  size_t len = strlen(path);
  if (len > MAX_COPY_PATH_LEN || path[len - 1] == '/') return -1;
  const char *p = path + 1;
  while (*p != '\0') {
    const char *start = p;
    while (*p != '\0' && *p != '/') {
      if (*p == '\0') return -1;
      p++;
    }
    size_t part_len = (size_t)(p - start);
    if (part_len == 0) return -1;
    if (part_len == 1 && start[0] == '.') return -1;
    if (part_len == 2 && start[0] == '.' && start[1] == '.') return -1;
    if (*p == '/') p++;
  }
  return 0;
}

static int append_path_component(char *path, size_t cap, const char *component, size_t component_len) {
  if (component_len == 0) return 0;
  size_t len = strlen(path);
  size_t need = len + (len == 0 ? 0 : 1) + component_len;
  if (need >= cap) {
    errno = ENAMETOOLONG;
    return -1;
  }
  if (len != 0) path[len++] = '/';
  memcpy(path + len, component, component_len);
  path[len + component_len] = '\0';
  return 0;
}

static void pop_path_component(char *path) {
  char *slash = strrchr(path, '/');
  if (slash == NULL) {
    path[0] = '\0';
    return;
  }
  *slash = '\0';
}

static int pop_pending_component(char *pending, char *component, size_t component_cap) {
  char *start = pending;
  while (*start == '/') start++;
  if (start != pending) memmove(pending, start, strlen(start) + 1);
  if (pending[0] == '\0') return 0;

  char *slash = strchr(pending, '/');
  size_t len = slash == NULL ? strlen(pending) : (size_t)(slash - pending);
  if (len == 0 || len >= component_cap) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(component, pending, len);
  component[len] = '\0';
  if (slash == NULL) {
    pending[0] = '\0';
  } else {
    memmove(pending, slash + 1, strlen(slash + 1) + 1);
  }
  return 1;
}

static int prepend_symlink_target(char *pending, size_t pending_cap, const char *target) {
  if (target[0] == '\0') {
    errno = EINVAL;
    return -1;
  }
  char next[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
  const char *target_rel = target;
  while (*target_rel == '/') target_rel++;
  int n = pending[0] == '\0'
      ? snprintf(next, sizeof(next), "%s", target_rel)
      : snprintf(next, sizeof(next), "%s/%s", target_rel, pending);
  if (n < 0 || (size_t)n >= sizeof(next) || (size_t)n >= pending_cap) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(pending, next, (size_t)n + 1);
  return 0;
}

static int open_resolved_path_nofollow(int root_fd, const char *logical, int flags, mode_t mode) {
  if (logical[0] == '\0') return dup(root_fd);

  char pending[MAX_COPY_FULL_PATH_LEN];
  int n = snprintf(pending, sizeof(pending), "%s", logical);
  if (n < 0 || (size_t)n >= sizeof(pending)) {
    errno = ENAMETOOLONG;
    return -1;
  }

  int dir_fd = dup(root_fd);
  if (dir_fd < 0) return -1;

  for (;;) {
    char component[MAX_COPY_PATH_LEN + 1];
    int next = pop_pending_component(pending, component, sizeof(component));
    if (next <= 0) {
      int saved = next < 0 ? errno : EINVAL;
      close(dir_fd);
      errno = saved;
      return -1;
    }

    if (pending[0] == '\0') {
      int fd = openat(dir_fd, component, flags | O_NOFOLLOW | O_CLOEXEC, mode);
      int saved = errno;
      if (close(dir_fd) != 0 && fd >= 0) {
        close(fd);
        return -1;
      }
      errno = saved;
      return fd;
    }

    int next_fd = openat(dir_fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int saved = errno;
    if (close(dir_fd) != 0 && next_fd >= 0) {
      close(next_fd);
      return -1;
    }
    if (next_fd < 0) {
      errno = saved;
      return -1;
    }
    dir_fd = next_fd;
  }
}

static int confined_open_path_fallback(int root_fd, const char *raw_path, int flags, mode_t mode) {
  const char *rel = raw_path[0] == '/' ? raw_path + 1 : raw_path;
  if (rel[0] == '\0') return dup(root_fd);
  if (strlen(rel) > MAX_COPY_PATH_LEN) {
    errno = ENAMETOOLONG;
    return -1;
  }

  char pending[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
  char logical[MAX_COPY_FULL_PATH_LEN];
  logical[0] = '\0';
  int n = snprintf(pending, sizeof(pending), "%s", rel);
  if (n < 0 || (size_t)n >= sizeof(pending)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  unsigned symlink_depth = 0;

  for (;;) {
    char component[MAX_COPY_PATH_LEN + 1];
    int next = pop_pending_component(pending, component, sizeof(component));
    if (next < 0) return -1;
    if (next == 0) break;
    if (strcmp(component, ".") == 0) continue;
    if (strcmp(component, "..") == 0) {
      pop_path_component(logical);
      continue;
    }

    char candidate[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
    snprintf(candidate, sizeof(candidate), "%s", logical);
    if (append_path_component(candidate, sizeof(candidate), component, strlen(component)) != 0) return -1;

    struct stat st;
    if (fstatat(root_fd, candidate, &st, AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno == ENOENT && pending[0] == '\0' && (flags & O_CREAT) != 0) {
        if (append_path_component(logical, sizeof(logical), component, strlen(component)) != 0) return -1;
        break;
      }
      return -1;
    }
    if (S_ISLNK(st.st_mode)) {
      if (++symlink_depth > MAX_SYMLINK_DEPTH) {
        errno = ELOOP;
        return -1;
      }
      char target[MAX_COPY_PATH_LEN + 1];
      ssize_t len = readlinkat(root_fd, candidate, target, sizeof(target) - 1);
      if (len < 0) return -1;
      target[len] = '\0';
      if (target[0] == '/') logical[0] = '\0';
      if (prepend_symlink_target(pending, sizeof(pending), target) != 0) return -1;
      continue;
    }

    if (append_path_component(logical, sizeof(logical), component, strlen(component)) != 0) return -1;
  }

  return open_resolved_path_nofollow(root_fd, logical, flags, mode);
}

static int confined_open_path(int root_fd, const char *path, int flags, mode_t mode) {
  const char *rel = path[0] == '/' ? path + 1 : path;
  if (rel[0] == '\0') return dup(root_fd);
#ifdef SYS_openat2
  struct open_how how = {
      .flags = (uint64_t)(flags | O_CLOEXEC),
      .mode = (uint64_t)mode,
      .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
  };
  int fd = (int)syscall(SYS_openat2, root_fd, rel, &how, sizeof(how));
  if (fd >= 0) return fd;
  if (errno != ENOSYS) return -1;
#endif
  return confined_open_path_fallback(root_fd, path, flags, mode);
}

static int confined_open_existing(int root_fd, const char *path, int flags) {
  return confined_open_path(root_fd, path, flags, 0);
}

static int confined_parent_fd(int root_fd, const char *path, char *name, size_t name_cap) {
  const char *rel = path[0] == '/' ? path + 1 : path;
  if (rel[0] == '\0') {
    errno = EINVAL;
    return -1;
  }
  const char *slash = strrchr(rel, '/');
  const char *base = slash == NULL ? rel : slash + 1;
  size_t base_len = strlen(base);
  if (base_len == 0 || base_len >= name_cap) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(name, base, base_len + 1);

  if (slash == NULL) return dup(root_fd);

  char parent[MAX_COPY_PATH_LEN + 1];
  size_t parent_len = (size_t)(slash - rel);
  if (parent_len == 0 || parent_len >= sizeof(parent)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(parent, rel, parent_len);
  parent[parent_len] = '\0';
  return confined_open_existing(root_fd, parent, O_RDONLY | O_DIRECTORY);
}

static int ensure_parent_dirs(int root_fd, const char *path) {
  const char *rel = path[0] == '/' ? path + 1 : path;
  char prefix[MAX_COPY_PATH_LEN + 1];
  size_t prefix_len = 0;
  for (const char *p = rel; *p != '\0'; p++) {
    if (*p != '/') {
      if (prefix_len + 1 >= sizeof(prefix)) {
        errno = ENAMETOOLONG;
        return -1;
      }
      prefix[prefix_len++] = *p;
      continue;
    }
    if (prefix_len == 0) {
      errno = EINVAL;
      return -1;
    }
    prefix[prefix_len] = '\0';
    int fd = confined_open_existing(root_fd, prefix, O_RDONLY | O_DIRECTORY);
    if (fd >= 0) {
      if (close(fd) != 0) return -1;
    } else {
      if (errno != ENOENT) return -1;
      char name[MAX_COPY_PATH_LEN + 1];
      int parent_fd = confined_parent_fd(root_fd, prefix, name, sizeof(name));
      if (parent_fd < 0) return -1;
      int rc = mkdirat(parent_fd, name, 0755);
      int saved = errno;
      if (close(parent_fd) != 0 && rc == 0) return -1;
      if (rc != 0 && saved != EEXIST) {
        errno = saved;
        return -1;
      }
    }
    if (prefix_len + 1 >= sizeof(prefix)) {
      errno = ENAMETOOLONG;
      return -1;
    }
    prefix[prefix_len++] = *p;
    continue;
  }
  return 0;
}

static int reject_security_xattrs_at(int parent_fd, const char *name);

static int prepare_overwrite_path(int root_fd, const char *path, int allow_existing_dir) {
  char name[MAX_COPY_PATH_LEN + 1];
  int parent_fd = confined_parent_fd(root_fd, path, name, sizeof(name));
  if (parent_fd < 0) return -1;
  struct stat st;
  if (fstatat(parent_fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
    int saved = errno;
    close(parent_fd);
    errno = saved;
    return errno == ENOENT ? 0 : -1;
  }
  if (reject_security_xattrs_at(parent_fd, name) != 0) {
    int saved = errno;
    close(parent_fd);
    errno = saved;
    return -1;
  }
  if (S_ISDIR(st.st_mode)) {
    if (close(parent_fd) != 0) return -1;
    return allow_existing_dir ? 0 : -1;
  }
  int rc = unlinkat(parent_fd, name, 0);
  int saved = errno;
  if (close(parent_fd) != 0 && rc == 0) return -1;
  errno = saved;
  return rc;
}

struct supported_copy_xattrs {
  int has_capability;
  size_t capability_len;
  unsigned char capability[MAX_COPY_XATTR_VALUE];
};

// The only accepted security namespace entry is a capability attached to a
// regular source file. Directory/symlink sources and every pre-existing
// destination must reject all visible security.* metadata.
static int copy_security_xattr_allowed(int regular_source, int existing_destination, const char *name) {
  if (strncmp(name, "security.", 9) != 0) return 1;
  return regular_source && !existing_destination && strcmp(name, "security.capability") == 0;
}

static int read_supported_xattrs(int source_fd, struct supported_copy_xattrs *out) {
  memset(out, 0, sizeof(*out));
  char names[MAX_COPY_XATTR_NAMES + 1];
  ssize_t names_len = flistxattr(source_fd, names, sizeof(names));
  if (names_len < 0) return -1;
  if ((size_t)names_len > MAX_COPY_XATTR_NAMES) {
    errno = E2BIG;
    return -1;
  }
  for (size_t offset = 0; offset < (size_t)names_len;) {
    const char *name = names + offset;
    size_t remaining = (size_t)names_len - offset;
    size_t name_len = strnlen(name, remaining);
    if (name_len == remaining) {
      errno = EIO;
      return -1;
    }
    if (strncmp(name, "security.", 9) == 0) {
      if (!copy_security_xattr_allowed(1, 0, name)) {
        errno = EOPNOTSUPP;
        return -1;
      }
      ssize_t value_len = fgetxattr(source_fd, name, out->capability, sizeof(out->capability));
      if (value_len < 0) return -1;
      if ((size_t)value_len > sizeof(out->capability)) {
        errno = E2BIG;
        return -1;
      }
      out->has_capability = 1;
      out->capability_len = (size_t)value_len;
    }
    offset += name_len + 1;
  }
  return 0;
}

static int apply_supported_xattrs(int dest_fd, const struct supported_copy_xattrs *attrs) {
  if (!attrs->has_capability) return 0;
  return fsetxattr(dest_fd, "security.capability", attrs->capability, attrs->capability_len, 0);
}

static int reject_security_xattrs_at(int parent_fd, const char *name) {
  char path[MAX_COPY_PATH_LEN + 64];
  int path_len = snprintf(path, sizeof(path), "/proc/self/fd/%d/%s", parent_fd, name);
  if (path_len <= 0 || (size_t)path_len >= sizeof(path)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  char names[MAX_COPY_XATTR_NAMES + 1];
  ssize_t names_len = llistxattr(path, names, sizeof(names));
  if (names_len < 0) return -1;
  if ((size_t)names_len > MAX_COPY_XATTR_NAMES) {
    errno = E2BIG;
    return -1;
  }
  for (size_t offset = 0; offset < (size_t)names_len;) {
    const char *xattr_name = names + offset;
    size_t remaining = (size_t)names_len - offset;
    size_t name_len = strnlen(xattr_name, remaining);
    if (name_len == remaining) {
      errno = EIO;
      return -1;
    }
    if (!copy_security_xattr_allowed(0, 0, xattr_name)) {
      errno = EOPNOTSUPP;
      return -1;
    }
    offset += name_len + 1;
  }
  return 0;
}

static int reject_security_xattrs_fd(int fd) {
  char names[MAX_COPY_XATTR_NAMES + 1];
  ssize_t names_len = flistxattr(fd, names, sizeof(names));
  if (names_len < 0) return -1;
  if ((size_t)names_len > MAX_COPY_XATTR_NAMES) {
    errno = E2BIG;
    return -1;
  }
  for (size_t offset = 0; offset < (size_t)names_len;) {
    const char *name = names + offset;
    size_t remaining = (size_t)names_len - offset;
    size_t name_len = strnlen(name, remaining);
    if (name_len == remaining) {
      errno = EIO;
      return -1;
    }
    if (!copy_security_xattr_allowed(0, 0, name)) {
      errno = EOPNOTSUPP;
      return -1;
    }
    offset += name_len + 1;
  }
  return 0;
}

static int set_fd_mtime(int fd, const struct stat *source_stat) {
  struct timespec times[2] = {
    { .tv_sec = 0, .tv_nsec = UTIME_OMIT },
    source_stat->st_mtim,
  };
  return futimens(fd, times);
}

static int set_symlink_mtime(int parent_fd, const char *name, const struct stat *source_stat) {
  struct timespec times[2] = {
    { .tv_sec = 0, .tv_nsec = UTIME_OMIT },
    source_stat->st_mtim,
  };
  return utimensat(parent_fd, name, times, AT_SYMLINK_NOFOLLOW);
}

static int set_path_mtime(int root_fd, const char *path, const struct stat *source_stat) {
  int fd = confined_open_existing(root_fd, path, O_RDONLY | O_DIRECTORY);
  if (fd < 0) return -1;
  int rc = set_fd_mtime(fd, source_stat);
  int saved = errno;
  if (close(fd) != 0 && rc == 0) rc = -1;
  errno = saved;
  return rc;
}

struct copied_hardlink {
  dev_t dev;
  ino_t ino;
  int dest_fd;
};

struct copy_tree_state {
  uint64_t expected_entries;
  uint64_t seen_entries;
  struct copied_hardlink *hardlinks;
  size_t hardlink_count;
  size_t hardlink_capacity;
};

static void copy_tree_state_deinit(struct copy_tree_state *state) {
  for (size_t i = 0; i < state->hardlink_count; i++) close(state->hardlinks[i].dest_fd);
  free(state->hardlinks);
  memset(state, 0, sizeof(*state));
}

static int apply_existing_hardlink(int root_fd, const struct stat *source_stat, const char *dest_path, struct copy_tree_state *state) {
  if (source_stat->st_nlink < 2) return 0;
  int existing_fd = -1;
  for (size_t i = 0; i < state->hardlink_count; i++) {
    if (state->hardlinks[i].dev == source_stat->st_dev && state->hardlinks[i].ino == source_stat->st_ino) {
      existing_fd = state->hardlinks[i].dest_fd;
      break;
    }
  }
  if (existing_fd < 0) return 0;
  if (ensure_parent_dirs(root_fd, dest_path) != 0 || prepare_overwrite_path(root_fd, dest_path, 0) != 0) return -1;

  char dest_name[MAX_COPY_PATH_LEN + 1];
  int dest_parent_fd = confined_parent_fd(root_fd, dest_path, dest_name, sizeof(dest_name));
  if (dest_parent_fd < 0) return -1;
  int rc = linkat(existing_fd, "", dest_parent_fd, dest_name, AT_EMPTY_PATH);
  int saved = errno;
  if (close(dest_parent_fd) != 0 && rc == 0) rc = -1;
  errno = saved;
  return rc == 0 ? 1 : -1;
}

static int record_hardlink(const struct stat *source_stat, int dest_fd, struct copy_tree_state *state) {
  if (source_stat->st_nlink < 2) return 0;
  if (state->hardlink_count >= state->hardlink_capacity) {
    if (state->hardlink_capacity >= MAX_BUILD_CONTEXT_COPY_ENTRIES) {
      errno = E2BIG;
      return -1;
    }
    size_t next_capacity = state->hardlink_capacity == 0 ? 8 : state->hardlink_capacity * 2;
    if (next_capacity > MAX_BUILD_CONTEXT_COPY_ENTRIES) next_capacity = MAX_BUILD_CONTEXT_COPY_ENTRIES;
    struct copied_hardlink *grown = realloc(state->hardlinks, next_capacity * sizeof(*grown));
    if (grown == NULL) return -1;
    state->hardlinks = grown;
    state->hardlink_capacity = next_capacity;
  }
  int owned_fd = fcntl(dest_fd, F_DUPFD_CLOEXEC, 0);
  if (owned_fd < 0) return -1;
  state->hardlinks[state->hardlink_count++] = (struct copied_hardlink){
    .dev = source_stat->st_dev,
    .ino = source_stat->st_ino,
    .dest_fd = owned_fd,
  };
  return 0;
}

static int apply_context_copy_dir(int root_fd, const char *path, mode_t mode, uid_t uid, gid_t gid) {
  if (ensure_parent_dirs(root_fd, path) != 0) return -1;
  char name[MAX_COPY_PATH_LEN + 1];
  int parent_fd = confined_parent_fd(root_fd, path, name, sizeof(name));
  if (parent_fd < 0) return -1;

  struct stat existing;
  int exists = fstatat(parent_fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0;
  if (exists && reject_security_xattrs_at(parent_fd, name) != 0) {
    int saved = errno;
    close(parent_fd);
    errno = saved;
    return -1;
  }
  if (!exists && errno != ENOENT) {
    int saved = errno;
    close(parent_fd);
    errno = saved;
    return -1;
  }

  int dir_fd = -1;
  if (exists) {
    // Docker directory COPY merges through an existing confined symlink to a
    // directory. Validate both the path inode above and the actual directory
    // inode before changing its metadata or copying children into it.
    dir_fd = confined_open_existing(root_fd, path, O_RDONLY | O_DIRECTORY);
    if (dir_fd >= 0 && reject_security_xattrs_fd(dir_fd) != 0) {
      int saved = errno;
      close(dir_fd);
      close(parent_fd);
      errno = saved;
      return -1;
    }
  }

  if (dir_fd < 0) {
    if (exists) {
      if (prepare_overwrite_path(root_fd, path, 1) != 0) {
        int saved = errno;
        close(parent_fd);
        errno = saved;
        return -1;
      }
    }
    int rc = mkdirat(parent_fd, name, mode & 07777);
    if (rc != 0 && errno != EEXIST) {
      int saved = errno;
      close(parent_fd);
      errno = saved;
      return -1;
    }
    dir_fd = confined_open_existing(root_fd, path, O_RDONLY | O_DIRECTORY);
    if (dir_fd < 0 || reject_security_xattrs_fd(dir_fd) != 0) {
      int saved = errno;
      if (dir_fd >= 0) close(dir_fd);
      close(parent_fd);
      errno = saved;
      return -1;
    }
  }

  int rc = fchown(dir_fd, uid, gid);
  if (rc == 0) rc = fchmod(dir_fd, mode & 07777);
  int saved = errno;
  if (close(dir_fd) != 0 && rc == 0) return -1;
  if (close(parent_fd) != 0 && rc == 0) return -1;
  errno = saved;
  return rc;
}

static int ensure_context_copy_root_dir(int root_fd, const char *path) {
  if (strcmp(path, "/") == 0) {
    if (reject_security_xattrs_fd(root_fd) != 0) return -1;
    return 0;
  }
  if (ensure_parent_dirs(root_fd, path) != 0) return -1;

  char name[MAX_COPY_PATH_LEN + 1];
  int parent_fd = confined_parent_fd(root_fd, path, name, sizeof(name));
  if (parent_fd < 0) return -1;
  struct stat existing;
  int exists = fstatat(parent_fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0;
  if (exists && reject_security_xattrs_at(parent_fd, name) != 0) {
    int saved = errno;
    close(parent_fd);
    errno = saved;
    return -1;
  }
  if (!exists && errno != ENOENT) {
    int saved = errno;
    close(parent_fd);
    errno = saved;
    return -1;
  }

  int existing_fd = confined_open_existing(root_fd, path, O_RDONLY | O_DIRECTORY);
  if (existing_fd >= 0) {
    int rc = reject_security_xattrs_fd(existing_fd);
    int saved = errno;
    if (close(existing_fd) != 0 && rc == 0) rc = -1;
    if (close(parent_fd) != 0 && rc == 0) rc = -1;
    errno = saved;
    return rc;
  }
  if (exists && prepare_overwrite_path(root_fd, path, 1) != 0) {
    int saved = errno;
    close(parent_fd);
    errno = saved;
    return -1;
  }

  int rc = mkdirat(parent_fd, name, 0700);
  int saved = errno;
  if (close(parent_fd) != 0 && rc == 0) return -1;
  errno = saved;
  if (rc != 0) {
    if (errno != EEXIST) return -1;
    existing_fd = confined_open_existing(root_fd, path, O_RDONLY | O_DIRECTORY);
    if (existing_fd < 0) return -1;
    return close(existing_fd);
  }

  int dir_fd = confined_open_existing(root_fd, path, O_RDONLY | O_DIRECTORY);
  if (dir_fd < 0) return -1;
  rc = fchown(dir_fd, 0, 0);
  if (rc == 0) rc = fchmod(dir_fd, 0755);
  saved = errno;
  if (close(dir_fd) != 0 && rc == 0) return -1;
  errno = saved;
  return rc;
}

static int copy_fd_to_fd(int in_fd, int out_fd, const char *path, uint64_t size, char *error, size_t cap) {
  unsigned char buf[MAX_FRAME_PAYLOAD];
  uint64_t remaining = size;
  while (remaining > 0) {
    size_t take = remaining > sizeof(buf) ? sizeof(buf) : (size_t)remaining;
    if (read_exact(in_fd, buf, take) != 0) {
      snprintf(error, cap, "spore build: COPY source read failed: path=%s expected=%llu remaining=%llu errno=%d\n", path, (unsigned long long)size, (unsigned long long)remaining, errno);
      return -1;
    }
    if (write_all(out_fd, buf, take) != 0) {
      snprintf(error, cap, "spore build: COPY apply failed: path=%s errno=%d\n", path, errno);
      return -1;
    }
    remaining -= take;
  }
  return 0;
}

static int apply_context_copy_file(int root_fd, int source_parent_fd, const char *source_name, const char *source_path, const char *dest_path, int preserve_owner, struct copy_tree_state *state, char *error, size_t cap) {
  int in_fd = openat(source_parent_fd, source_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (in_fd < 0) {
    snprintf(error, cap, "spore build: COPY source open failed: path=%s errno=%d\n", source_path, errno);
    return -1;
  }
  struct stat source_stat;
  if (fstat(in_fd, &source_stat) != 0 || !S_ISREG(source_stat.st_mode)) {
    int saved = errno;
    close(in_fd);
    snprintf(error, cap, "spore build: COPY source is not a regular file: path=%s errno=%d\n", source_path, saved);
    return -1;
  }
  if (source_stat.st_size < 0) {
    close(in_fd);
    errno = EFBIG;
    return -1;
  }
  struct supported_copy_xattrs source_xattrs;
  if (read_supported_xattrs(in_fd, &source_xattrs) != 0) {
    int saved = errno;
    close(in_fd);
    errno = saved;
    return -1;
  }

  int hardlink_rc = apply_existing_hardlink(root_fd, &source_stat, dest_path, state);
  if (hardlink_rc != 0) {
    int saved = errno;
    close(in_fd);
    errno = saved;
    return hardlink_rc < 0 ? -1 : 0;
  }

  const char *path = dest_path;
  if (ensure_parent_dirs(root_fd, path) != 0) {
    close(in_fd);
    return -1;
  }
  char name[MAX_COPY_PATH_LEN + 1];
  int parent_fd = confined_parent_fd(root_fd, path, name, sizeof(name));
  if (parent_fd < 0) {
    close(in_fd);
    return -1;
  }

  struct stat st;
  int cleanup_on_error = 1;
  if (fstatat(parent_fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
    if (reject_security_xattrs_at(parent_fd, name) != 0) {
      int saved = errno;
      close(parent_fd);
      close(in_fd);
      errno = saved;
      return -1;
    }
    cleanup_on_error = !S_ISLNK(st.st_mode);
  } else if (errno != ENOENT) {
    int saved = errno;
    close(parent_fd);
    close(in_fd);
    errno = saved;
    return -1;
  }

  int fd = confined_open_path(root_fd, path, O_WRONLY | O_CREAT, source_stat.st_mode & 07777);
  if (fd < 0) {
    int saved = errno;
    close(parent_fd);
    close(in_fd);
    errno = saved;
    return -1;
  }
  int rc = reject_security_xattrs_fd(fd);
  if (rc == 0) rc = ftruncate(fd, 0);
  if (rc == 0) rc = copy_fd_to_fd(in_fd, fd, path, (uint64_t)source_stat.st_size, error, cap);
  int saved = rc != 0 ? errno : 0;
  if (rc == 0 && fchown(fd, preserve_owner ? source_stat.st_uid : 0, preserve_owner ? source_stat.st_gid : 0) != 0) {
    rc = -1;
    saved = errno;
  }
  if (rc == 0 && fchmod(fd, source_stat.st_mode & 07777) != 0) {
    rc = -1;
    saved = errno;
  }
  if (rc == 0 && apply_supported_xattrs(fd, &source_xattrs) != 0) {
    rc = -1;
    saved = errno;
  }
  if (rc == 0 && set_fd_mtime(fd, &source_stat) != 0) {
    rc = -1;
    saved = errno;
  }
  if (rc == 0 && record_hardlink(&source_stat, fd, state) != 0) {
    rc = -1;
    saved = errno;
  }
  if (close(fd) != 0 && rc == 0) {
    rc = -1;
    saved = errno;
  }
  if (close(in_fd) != 0 && rc == 0) {
    rc = -1;
    saved = errno;
  }
  if (rc != 0 && cleanup_on_error) unlinkat(parent_fd, name, 0);
  if (close(parent_fd) != 0 && rc == 0) return -1;
  errno = saved;
  return rc;
}

static int apply_context_copy_symlink(int root_fd, int source_parent_fd, const char *source_name, const char *source_path, const char *dest_path, uid_t uid, gid_t gid, const struct stat *source_stat, char *error, size_t cap) {
  char target[MAX_COPY_PATH_LEN + 1];
  if (readlinkat_bounded(source_parent_fd, source_name, target, sizeof(target)) < 0) {
    snprintf(error, cap, "spore build: COPY symlink read failed: path=%s errno=%d\n", source_path, errno);
    return -1;
  }
  const char *path = dest_path;
  if (ensure_parent_dirs(root_fd, path) != 0) return -1;
  if (prepare_overwrite_path(root_fd, path, 0) != 0) return -1;
  char name[MAX_COPY_PATH_LEN + 1];
  int parent_fd = confined_parent_fd(root_fd, path, name, sizeof(name));
  if (parent_fd < 0) return -1;
  mode_t previous_umask = umask(0);
  int rc = symlinkat(target, parent_fd, name);
  int saved = errno;
  umask(previous_umask);
  errno = saved;
  if (rc == 0 && fchownat(parent_fd, name, uid, gid, AT_SYMLINK_NOFOLLOW) != 0) rc = -1;
  if (rc == 0 && set_symlink_mtime(parent_fd, name, source_stat) != 0) rc = -1;
  saved = errno;
  if (close(parent_fd) != 0 && rc == 0) return -1;
  errno = saved;
  return rc;
}

static int join_dest_path(char *out, size_t cap, const char *base, const char *name) {
  if (name[0] == '\0') {
    int n = snprintf(out, cap, "%s", base);
    return n > 0 && (size_t)n < cap ? 0 : -1;
  }
  int n;
  if (strcmp(base, "/") == 0) {
    n = snprintf(out, cap, "/%s", name);
  } else {
    n = snprintf(out, cap, "%s/%s", base, name);
  }
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int join_source_path(char *out, size_t cap, const char *base, const char *name) {
  int n = snprintf(out, cap, "%s/%s", base, name);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int copy_context_tree(int root_fd, int source_parent_fd, const char *source_name, const char *source_path, const char *dest_path, int source_root, int preserve_owner, struct copy_tree_state *state, char *error, size_t cap) {
  uint64_t traversal_limit = state->expected_entries == 0 ? MAX_BUILD_CONTEXT_COPY_ENTRIES : state->expected_entries;
  if (state->seen_entries >= traversal_limit) {
    snprintf(error, cap, "spore build: COPY context entry count exceeds request: path=%s limit=%llu actual=%llu\n", source_path, (unsigned long long)traversal_limit, (unsigned long long)(state->seen_entries + 1));
    return -1;
  }
  struct stat st;
  if (fstatat(source_parent_fd, source_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
    snprintf(error, cap, "spore build: COPY source subtree missing on context disk: path=%s errno=%d\n", source_path, errno);
    return -1;
  }
  state->seen_entries++;
  if (!S_ISREG(st.st_mode) && reject_security_xattrs_at(source_parent_fd, source_name) != 0) {
    snprintf(error, cap, "spore build: COPY source has unsupported security xattr: path=%s errno=%d\n", source_path, errno);
    return -1;
  }
  if (S_ISDIR(st.st_mode)) {
    int dir_rc = source_root
        ? ensure_context_copy_root_dir(root_fd, dest_path)
        : apply_context_copy_dir(root_fd, dest_path, st.st_mode & 07777, preserve_owner ? st.st_uid : 0, preserve_owner ? st.st_gid : 0);
    if (dir_rc != 0) {
      snprintf(error, cap, "spore build: COPY directory apply failed: path=%s errno=%d\n", dest_path, errno);
      return -1;
    }
    int source_dir_fd = openat(source_parent_fd, source_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (source_dir_fd < 0) {
      snprintf(error, cap, "spore build: COPY source directory open failed: path=%s errno=%d\n", source_path, errno);
      return -1;
    }
    DIR *dir = fdopendir(source_dir_fd);
    if (dir == NULL) {
      close(source_dir_fd);
      snprintf(error, cap, "spore build: COPY source directory open failed: path=%s errno=%d\n", source_path, errno);
      return -1;
    }
    int rc = 0;
    int saved = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
      if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
      char child_source[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
      char child_dest[MAX_COPY_PATH_LEN + 1];
      if (join_source_path(child_source, sizeof(child_source), source_path, entry->d_name) != 0 ||
          join_dest_path(child_dest, sizeof(child_dest), dest_path, entry->d_name) != 0 ||
          copy_context_tree(root_fd, dirfd(dir), entry->d_name, child_source, child_dest, 0, preserve_owner, state, error, cap) != 0) {
        rc = -1;
        saved = errno;
        break;
      }
    }
    if (closedir(dir) != 0 && rc == 0) {
      rc = -1;
      saved = errno;
    }
    if (!source_root && rc == 0 && set_path_mtime(root_fd, dest_path, &st) != 0) {
      rc = -1;
      saved = errno;
    }
    if (rc != 0) errno = saved;
    return rc;
  }
  if (S_ISREG(st.st_mode)) {
    return apply_context_copy_file(root_fd, source_parent_fd, source_name, source_path, dest_path, preserve_owner, state, error, cap);
  }
  if (S_ISLNK(st.st_mode)) {
    return apply_context_copy_symlink(root_fd, source_parent_fd, source_name, source_path, dest_path, preserve_owner ? st.st_uid : 0, preserve_owner ? st.st_gid : 0, &st, error, cap);
  }
  snprintf(error, cap, "spore build: COPY source has unsupported type: path=%s\n", source_path);
  return -1;
}

int spore_build_copy_ensure_fd_budget(void) {
  struct rlimit limit;
  if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return -1;
  const rlim_t required = (rlim_t)BUILD_AGENT_FD_BUDGET;
  if (limit.rlim_cur >= required) return 0;
  if (limit.rlim_max != RLIM_INFINITY && limit.rlim_max < required) {
    limit.rlim_max = required;
  }
  limit.rlim_cur = required;
  if (setrlimit(RLIMIT_NOFILE, &limit) != 0) return -1;
  if (getrlimit(RLIMIT_NOFILE, &limit) != 0 || limit.rlim_cur < required) {
    errno = EMFILE;
    return -1;
  }
  return 0;
}

static int validate_build_context_source_path(const char *path) {
  if (strcmp(path, ".") == 0) return 0;
  size_t len = strlen(path);
  if (len == 0 || len > MAX_COPY_PATH_LEN || path[0] == '/' || path[len - 1] == '/') return -1;
  size_t i = 0;
  while (i < len) {
    size_t start = i;
    while (i < len && path[i] != '/') {
      if (path[i] == '\0') return -1;
      i++;
    }
    size_t part_len = i - start;
    if (part_len == 0) return -1;
    if (part_len == 1 && path[start] == '.') return -1;
    if (part_len == 2 && path[start] == '.' && path[start + 1] == '.') return -1;
    if (i < len) i++;
  }
  return 0;
}

static int build_copy_source_path(char *out, size_t cap, const char *source_root, const char *source) {
  int n;
  if (strcmp(source, ".") == 0) {
    n = snprintf(out, cap, "%s", source_root);
  } else {
    n = snprintf(out, cap, "%s/%s", source_root, source);
  }
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int ensure_confined_directory(int root_fd, const char *path, mode_t mode) {
  int existing_fd = confined_open_existing(root_fd, path, O_RDONLY | O_DIRECTORY);
  if (existing_fd >= 0) return close(existing_fd);
  if (errno != ENOENT) return -1;
  if (ensure_parent_dirs(root_fd, path) != 0) return -1;

  char name[MAX_COPY_PATH_LEN + 1];
  int parent_fd = confined_parent_fd(root_fd, path, name, sizeof(name));
  if (parent_fd < 0) return -1;
  int rc = mkdirat(parent_fd, name, mode);
  int saved = errno;
  if (close(parent_fd) != 0 && rc == 0) return -1;
  if (rc == 0) return 0;
  errno = saved;
  if (errno != EEXIST) return -1;
  existing_fd = confined_open_existing(root_fd, path, O_RDONLY | O_DIRECTORY);
  if (existing_fd < 0) return -1;
  return close(existing_fd);
}

int spore_build_ensure_directory(const char *root, const char *path) {
  if (path[0] != '/' || (path[1] != '\0' && validate_spore_copy_entry_path(path) != 0)) {
    errno = EINVAL;
    return SPORE_BUILD_COPY_INVALID;
  }
  int root_fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (root_fd < 0) return SPORE_BUILD_COPY_UNAVAILABLE;
  int rc = ensure_confined_directory(root_fd, path, 0755);
  int saved = rc != 0 ? errno : 0;
  if (close(root_fd) != 0 && rc == 0) {
    rc = -1;
    saved = errno;
  }
  errno = saved;
  return rc == 0 ? SPORE_BUILD_COPY_OK : SPORE_BUILD_COPY_APPLY_FAILED;
}

static int copy_result(char *error, size_t error_cap, int code, const char *message) {
  if (error_cap > 0) snprintf(error, error_cap, "%s", message);
  return code;
}

static int set_confined_mtime(int root_fd, const char *path, int64_t unix_seconds) {
  int fd = confined_open_existing(root_fd, path, O_RDONLY);
  if (fd < 0) return -1;
  time_t seconds = (time_t)unix_seconds;
  if ((int64_t)seconds != unix_seconds) {
    close(fd);
    errno = EOVERFLOW;
    return -1;
  }
  struct timespec times[2] = {
    { .tv_sec = 0, .tv_nsec = UTIME_OMIT },
    { .tv_sec = seconds, .tv_nsec = 0 },
  };
  int rc = futimens(fd, times);
  int saved = errno;
  if (close(fd) != 0 && rc == 0) return -1;
  errno = saved;
  return rc;
}

int spore_build_copy_apply(
    const char *root, const char *source_root,
    const char *source, const char *dest,
    int source_kind, int dest_is_dir, uint64_t entry_count,
    int mtime_present, int64_t mtime_unix_seconds,
    char *error, size_t error_cap) {
  if (error_cap > 0) error[0] = '\0';
  if (validate_build_context_source_path(source) != 0) {
    return copy_result(error, error_cap, SPORE_BUILD_COPY_INVALID, "spore build: invalid COPY source path on context disk\n");
  }
  if (dest[0] != '/' || (dest[1] != '\0' && validate_spore_copy_entry_path(dest) != 0)) {
    return copy_result(error, error_cap, SPORE_BUILD_COPY_INVALID, "spore build: invalid COPY destination\n");
  }
  if ((source_kind != COPY_KIND_AUTO && entry_count == 0) || entry_count > MAX_BUILD_CONTEXT_COPY_ENTRIES) {
    if (error_cap > 0) snprintf(error, error_cap, "spore build: COPY entry count exceeds limit: path=%s limit=%llu actual=%llu\n", source, (unsigned long long)MAX_BUILD_CONTEXT_COPY_ENTRIES, (unsigned long long)entry_count);
    return SPORE_BUILD_COPY_INVALID;
  }
  int root_fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (root_fd < 0) {
    return copy_result(error, error_cap, SPORE_BUILD_COPY_UNAVAILABLE, "spore build: rootfs unavailable\n");
  }
  int source_root_fd = open(source_root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (source_root_fd < 0) {
    close(root_fd);
    return copy_result(error, error_cap, SPORE_BUILD_COPY_UNAVAILABLE, "spore build: COPY source root unavailable\n");
  }

  char source_path[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
  if (build_copy_source_path(source_path, sizeof(source_path), source_root, source) != 0) {
    close(source_root_fd);
    close(root_fd);
    return copy_result(error, error_cap, SPORE_BUILD_COPY_INVALID, "spore build: COPY source path is too long for context disk\n");
  }
  char source_name[MAX_COPY_PATH_LEN + 1];
  int source_parent_fd;
  if (strcmp(source, ".") == 0) {
    source_parent_fd = dup(source_root_fd);
    snprintf(source_name, sizeof(source_name), ".");
  } else {
    source_parent_fd = confined_parent_fd(source_root_fd, source, source_name, sizeof(source_name));
  }
  close(source_root_fd);
  if (source_parent_fd < 0) {
    close(root_fd);
    return copy_result(error, error_cap, SPORE_BUILD_COPY_APPLY_FAILED, "spore build: COPY source path escapes input root\n");
  }
  struct stat st;
  if (fstatat(source_parent_fd, source_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
    if (error_cap > 0) snprintf(error, error_cap, "spore build: COPY source subtree missing on context disk: path=%s errno=%d\n", source, errno);
    close(source_parent_fd);
    close(root_fd);
    return SPORE_BUILD_COPY_APPLY_FAILED;
  }
  int preserve_owner = source_kind == COPY_KIND_AUTO;
  if (source_kind == COPY_KIND_AUTO) {
    if (S_ISDIR(st.st_mode)) source_kind = COPY_KIND_DIR;
    else if (S_ISREG(st.st_mode)) source_kind = COPY_KIND_FILE;
    else if (S_ISLNK(st.st_mode)) source_kind = COPY_KIND_SYMLINK;
    else source_kind = 0;
  }
  if ((source_kind == COPY_KIND_DIR && !S_ISDIR(st.st_mode)) ||
      (source_kind == COPY_KIND_FILE && !S_ISREG(st.st_mode)) ||
      (source_kind == COPY_KIND_SYMLINK && !S_ISLNK(st.st_mode))) {
    if (error_cap > 0) snprintf(error, error_cap, "spore build: COPY source kind mismatch on context disk: path=%s\n", source);
    close(source_parent_fd);
    close(root_fd);
    return SPORE_BUILD_COPY_APPLY_FAILED;
  }

  int resolved_dest_is_dir = dest_is_dir;
  if (source_kind != COPY_KIND_DIR && !resolved_dest_is_dir) {
    int dest_fd = confined_open_existing(root_fd, dest, O_RDONLY | O_DIRECTORY);
    if (dest_fd >= 0) {
      resolved_dest_is_dir = 1;
      if (close(dest_fd) != 0) {
        close(source_parent_fd);
        close(root_fd);
        return copy_result(error, error_cap, SPORE_BUILD_COPY_APPLY_FAILED, "spore build: COPY destination inspection failed\n");
      }
    } else if (errno != ENOENT && errno != ENOTDIR) {
      close(source_parent_fd);
      close(root_fd);
      return copy_result(error, error_cap, SPORE_BUILD_COPY_APPLY_FAILED, "spore build: COPY destination inspection failed\n");
    }
  }

  char dest_path[MAX_COPY_PATH_LEN + 1];
  if (source_kind == COPY_KIND_DIR) {
    snprintf(dest_path, sizeof(dest_path), "%s", dest);
  } else if (resolved_dest_is_dir) {
    const char *base = strrchr(source, '/');
    base = base == NULL ? source : base + 1;
    if (join_dest_path(dest_path, sizeof(dest_path), dest, base) != 0) {
      close(source_parent_fd);
      close(root_fd);
      return copy_result(error, error_cap, SPORE_BUILD_COPY_INVALID, "spore build: COPY destination path is too long\n");
    }
  } else {
    snprintf(dest_path, sizeof(dest_path), "%s", dest);
  }

  struct copy_tree_state copy_state;
  memset(&copy_state, 0, sizeof(copy_state));
  copy_state.expected_entries = entry_count;
  if (copy_context_tree(root_fd, source_parent_fd, source_name, source_path, dest_path, 1, preserve_owner, &copy_state, error, error_cap) != 0) {
    int copy_errno = errno;
    copy_tree_state_deinit(&copy_state);
    close(source_parent_fd);
    close(root_fd);
    if (copy_errno == ENOSPC) {
      return copy_result(error, error_cap, SPORE_BUILD_COPY_APPLY_FAILED, "spore build: SPORE_BUILD_ENOSPC COPY apply failed\n");
    }
    if (error_cap == 0 || error[0] == '\0') copy_result(error, error_cap, SPORE_BUILD_COPY_APPLY_FAILED, "spore build: COPY apply failed\n");
    return SPORE_BUILD_COPY_APPLY_FAILED;
  }
  if (entry_count != 0 && copy_state.seen_entries != entry_count) {
    if (error_cap > 0) snprintf(error, error_cap, "spore build: COPY context entry count mismatch: path=%s limit=%llu actual=%llu\n", source, (unsigned long long)entry_count, (unsigned long long)copy_state.seen_entries);
    copy_tree_state_deinit(&copy_state);
    close(source_parent_fd);
    close(root_fd);
    return SPORE_BUILD_COPY_APPLY_FAILED;
  }
  if (mtime_present && set_confined_mtime(root_fd, dest_path, mtime_unix_seconds) != 0) {
    copy_tree_state_deinit(&copy_state);
    close(source_parent_fd);
    close(root_fd);
    return copy_result(error, error_cap, SPORE_BUILD_COPY_APPLY_FAILED, "spore build: COPY destination mtime apply failed\n");
  }
  copy_tree_state_deinit(&copy_state);
  int close_rc = close(source_parent_fd);
  if (close(root_fd) != 0) close_rc = -1;
  if (close_rc != 0) {
    return copy_result(error, error_cap, SPORE_BUILD_COPY_APPLY_FAILED, "spore build: COPY apply failed\n");
  }
  return SPORE_BUILD_COPY_OK;
}

#ifdef SPORE_AGENT_REQUEST_FUZZ
static int test_mkdir_p(const char *path, mode_t mode) {
  char copy[1200];
  size_t len = strlen(path);
  if (len == 0 || len >= sizeof(copy)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(copy, path, len + 1);
  for (char *p = copy + 1; *p != '\0'; p++) {
    if (*p != '/') continue;
    *p = '\0';
    if (mkdir(copy, mode) != 0 && errno != EEXIST) return -1;
    *p = '/';
  }
  return mkdir(copy, mode) == 0 || errno == EEXIST ? 0 : -1;
}

__attribute__((visibility("hidden"))) int spore_build_copy_test_confined_source_parent(
    const unsigned char *root_bytes, size_t root_len,
    const unsigned char *path_bytes, size_t path_len) {
  if (root_len == 0 || root_len >= 1024 || path_len == 0 || path_len > MAX_COPY_PATH_LEN) return -1;
  char root[1024];
  char path[MAX_COPY_PATH_LEN + 1];
  memcpy(root, root_bytes, root_len);
  root[root_len] = '\0';
  memcpy(path, path_bytes, path_len);
  path[path_len] = '\0';
  int root_fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (root_fd < 0) return -1;
  char name[MAX_COPY_PATH_LEN + 1];
  int parent_fd = confined_parent_fd(root_fd, path, name, sizeof(name));
  close(root_fd);
  if (parent_fd < 0) return -1;
  int rc = fstatat(parent_fd, name, &(struct stat){0}, AT_SYMLINK_NOFOLLOW);
  close(parent_fd);
  return rc;
}

__attribute__((visibility("hidden"))) int spore_build_copy_test_confined_mtime(
    const unsigned char *root_bytes, size_t root_len,
    const unsigned char *path_bytes, size_t path_len, int64_t unix_seconds) {
  if (root_len == 0 || root_len >= 1024 || path_len == 0 || path_len > MAX_COPY_PATH_LEN) return -1;
  char root[1024];
  char path[MAX_COPY_PATH_LEN + 1];
  memcpy(root, root_bytes, root_len);
  root[root_len] = '\0';
  memcpy(path, path_bytes, path_len);
  path[path_len] = '\0';
  int root_fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (root_fd < 0) return -1;
  int rc = set_confined_mtime(root_fd, path, unix_seconds);
  int saved = errno;
  if (close(root_fd) != 0 && rc == 0) return -1;
  errno = saved;
  return rc;
}

__attribute__((visibility("hidden"))) int spore_build_copy_fuzz_tree(
    const unsigned char *source_root_bytes, size_t source_root_len,
    const unsigned char *dest_root_bytes, size_t dest_root_len,
    const unsigned char *fuzz, size_t fuzz_len) {
  if (source_root_len == 0 || source_root_len >= 1024 || dest_root_len == 0 || dest_root_len >= 1024 || fuzz_len > 256) return -1;
  char source_root[1024];
  char dest_root[1024];
  memcpy(source_root, source_root_bytes, source_root_len);
  source_root[source_root_len] = '\0';
  memcpy(dest_root, dest_root_bytes, dest_root_len);
  dest_root[dest_root_len] = '\0';

  char tree[1200];
  if (snprintf(tree, sizeof(tree), "%s/tree", source_root) <= 0 || test_mkdir_p(tree, 0755) != 0) return -1;
  size_t entry_count = fuzz_len > 16 ? 16 : fuzz_len;
  char first_file[1200];
  first_file[0] = '\0';
  for (size_t i = 0; i < entry_count; i++) {
    char path[1200];
    int n = snprintf(path, sizeof(path), "%s/tree/e%02zu", source_root, i);
    if (n <= 0 || (size_t)n >= sizeof(path)) return -1;
    switch (fuzz[i] % 6) {
      case 0: {
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600 | (fuzz[i] & 077));
        if (fd < 0) return -1;
        int rc = write_all(fd, fuzz, fuzz_len);
        if (close(fd) != 0 && rc == 0) rc = -1;
        if (rc != 0) return -1;
        if (first_file[0] == '\0') snprintf(first_file, sizeof(first_file), "%s", path);
        break;
      }
      case 1: {
        if (mkdir(path, 0700 | (fuzz[i] & 077)) != 0) return -1;
        char nested[1200];
        snprintf(nested, sizeof(nested), "%s", path);
        size_t depth = 1 + (fuzz[i] >> 6);
        for (size_t level = 0; level < depth; level++) {
          size_t used = strlen(nested);
          int written = snprintf(nested + used, sizeof(nested) - used, "/d%zu", level);
          if (written <= 0 || (size_t)written >= sizeof(nested) - used || mkdir(nested, 0755) != 0) return -1;
        }
        size_t used = strlen(nested);
        int written = snprintf(nested + used, sizeof(nested) - used, "/leaf");
        if (written <= 0 || (size_t)written >= sizeof(nested) - used) return -1;
        int fd = open(nested, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (fd < 0 || close(fd) != 0) return -1;
        break;
      }
      case 2:
        if (symlink("../../outside", path) != 0) return -1;
        break;
      case 3: {
        char target[MAX_COPY_PATH_LEN];
        size_t target_len = 1 + (fuzz[i] % (sizeof(target) - 1));
        memset(target, 'x', target_len);
        target[target_len] = '\0';
        if (symlink(target, path) != 0) return -1;
        break;
      }
      case 4:
        if (mkfifo(path, 0600) != 0) return -1;
        break;
      case 5:
        if (first_file[0] != '\0') {
          if (link(first_file, path) != 0) return -1;
        } else if (mkdir(path, 0755) != 0) {
          return -1;
        }
        break;
    }
  }

  int source_fd = open(source_root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  int dest_fd = open(dest_root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (source_fd < 0 || dest_fd < 0) {
    if (source_fd >= 0) close(source_fd);
    if (dest_fd >= 0) close(dest_fd);
    return -1;
  }
  uint64_t expected = fuzz_len > 1 && (fuzz[1] & 1) != 0
      ? 64
      : (fuzz_len == 0 ? 1 : 1 + (uint64_t)(fuzz[0] % (entry_count + 1)));
  struct copy_tree_state state = {
    .expected_entries = expected,
    .hardlink_capacity = (size_t)expected,
  };
  state.hardlinks = calloc(state.hardlink_capacity, sizeof(*state.hardlinks));
  if (state.hardlinks == NULL) {
    close(source_fd);
    close(dest_fd);
    return -1;
  }
  char error[384];
  int rc = copy_context_tree(dest_fd, source_fd, "tree", tree, "/copy", 1, 1, &state, error, sizeof(error));
  copy_tree_state_deinit(&state);
  close(source_fd);
  close(dest_fd);
  return rc;
}

__attribute__((visibility("hidden"))) uint64_t spore_build_copy_test_fd_budget(void) {
  return BUILD_AGENT_FD_BUDGET;
}

__attribute__((visibility("hidden"))) int spore_build_copy_test_security_xattr_long_name(const unsigned char *root_bytes, size_t root_len) {
  if (root_len == 0 || root_len >= 1024) return -1;
  char root[1024];
  memcpy(root, root_bytes, root_len);
  root[root_len] = '\0';
  int root_fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (root_fd < 0) return -1;
  char name[256];
  memset(name, 'n', sizeof(name) - 1);
  name[sizeof(name) - 1] = '\0';
  int fd = openat(root_fd, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (fd < 0) {
    close(root_fd);
    return -1;
  }
  if (close(fd) != 0) {
    close(root_fd);
    return -1;
  }
  int rc = reject_security_xattrs_at(root_fd, name);
  unlinkat(root_fd, name, 0);
  close(root_fd);
  return rc;
}

__attribute__((visibility("hidden"))) int spore_build_copy_test_security_xattr_policy(int regular_source, int existing_destination, const unsigned char *name_bytes, size_t name_len) {
  if (name_len == 0 || name_len > 255 || memchr(name_bytes, '\0', name_len) != NULL) return -1;
  char name[256];
  memcpy(name, name_bytes, name_len);
  name[name_len] = '\0';
  return copy_security_xattr_allowed(regular_source, existing_destination, name) ? 0 : -1;
}
#endif
