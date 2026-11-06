// Named `spore cp` copy-in and copy-out archives.

#include "agent.h"

#define COPY_ARCHIVE_HEADER_LEN 16
#define COPY_KIND_END 'E'

static int validate_copy_path(const char *path) {
  if (path[0] != '/' || path[1] == '\0') return -1;
  size_t len = strlen(path);
  if (len > MAX_COPY_PATH_LEN || path[len - 1] == '/') return -1;
  const char *p = path + 1;
  while (*p != '\0') {
    const char *start = p;
    while (*p != '\0' && *p != '/') p++;
    size_t part_len = (size_t)(p - start);
    if (part_len == 0) return -1;
    if (part_len == 1 && start[0] == '.') return -1;
    if (part_len == 2 && start[0] == '.' && start[1] == '.') return -1;
    if (*p == '/') p++;
  }
  return 0;
}

static int build_copy_path(char *out, size_t cap, const char *root, const char *guest_path) {
  int n = root[0] == '\0'
      ? snprintf(out, cap, "%s", guest_path)
      : snprintf(out, cap, "%s%s", root, guest_path);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int build_copy_tmp_path(char *out, size_t cap, const char *path, unsigned attempt) {
  const char *slash = strrchr(path, '/');
  if (slash == NULL || slash[1] == '\0') return -1;
  const char *name = slash + 1;
  int n;
  if (slash == path) {
    n = snprintf(out, cap, "/.%s.spore-copy.%ld.%u.tmp", name, (long)getpid(), attempt);
  } else {
    n = snprintf(out, cap, "%.*s/.%s.spore-copy.%ld.%u.tmp", (int)(slash - path), path, name, (long)getpid(), attempt);
  }
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int reserve_copy_tmp_dir(char *out, size_t cap, const char *path) {
  for (unsigned attempt = 0; attempt < 16; attempt++) {
    if (build_copy_tmp_path(out, cap, path, attempt) != 0) return -1;
    if (mkdir(out, 0700) == 0) return 0;
    if (errno != EEXIST) return -1;
  }
  errno = EEXIST;
  return -1;
}

static const unsigned char copy_archive_magic[8] = { 'S', 'P', 'C', 'P', '1', '\n', '\0', '\n' };

struct copy_record {
  int kind;
  char path[MAX_COPY_PATH_LEN + 1];
  size_t path_len;
  uint32_t mode;
  uint64_t size;
};

static int validate_copy_archive_path(const char *path, size_t len, int allow_root) {
  if (len == 0) return allow_root ? 0 : -1;
  if (len > MAX_COPY_PATH_LEN || path[0] == '/' || path[len - 1] == '/') return -1;
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
    if (i < len && path[i] == '/') i++;
  }
  return 0;
}

static int build_copy_archive_target(char *out, size_t cap, const char *root, const char *rel) {
  int n = rel[0] == '\0'
      ? snprintf(out, cap, "%s", root)
      : snprintf(out, cap, "%s/%s", root, rel);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int remove_tree(const char *path) {
  struct stat st;
  if (lstat(path, &st) != 0) return -1;
  if (!S_ISDIR(st.st_mode)) return unlink(path);

  int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return -1;
  DIR *dir = fdopendir(fd);
  if (dir == NULL) {
    close(fd);
    return -1;
  }

  struct dirent *entry;
  int rc = 0;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    char child[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
    int n = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
    if (n <= 0 || (size_t)n >= sizeof(child) || remove_tree(child) != 0) rc = -1;
  }
  if (closedir(dir) != 0) rc = -1;
  if (rmdir(path) != 0) rc = -1;
  return rc;
}

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif

static int rename_noreplace(const char *old_path, const char *new_path) {
#ifdef SYS_renameat2
  if (syscall(SYS_renameat2, AT_FDCWD, old_path, AT_FDCWD, new_path, RENAME_NOREPLACE) == 0) return 0;
  return -1;
#else
  errno = ENOSYS;
  return -1;
#endif
}

static int receive_lifecycle_copy_archive_from_spio(struct client *client, const char *archive_path) {
  int fd = open(archive_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return -1;

  uint64_t expected = 0;
  unsigned char payload[MAX_FRAME_PAYLOAD];
  int rc = 0;
  for (;;) {
    uint8_t type = 0;
    uint32_t stream_id = 0;
    uint64_t offset = 0;
    uint32_t payload_len = 0;
    if (read_spio_header_blocking(client->fd, &type, &stream_id, &offset, &payload_len) != 0) {
      rc = -1;
      break;
    }
    if (payload_len > 0 && read_exact(client->fd, payload, payload_len) != 0) {
      rc = -1;
      break;
    }
    if (type == SPIO_DATA) {
      if (stream_id != SPIO_STDIN_STREAM || offset != expected) {
        rc = -1;
        break;
      }
      if (payload_len > 0 && write_all(fd, payload, payload_len) != 0) {
        rc = -1;
        break;
      }
      expected += payload_len;
      continue;
    }
    if (type == SPIO_CLOSE && stream_id == SPIO_STDIN_STREAM && offset == expected && payload_len == 0) {
      break;
    }
    rc = -1;
    break;
  }

  if (close(fd) != 0) rc = -1;
  if (rc != 0) unlink(archive_path);
  return rc;
}

static int read_copy_record(int fd, struct copy_record *record) {
  unsigned char header[COPY_ARCHIVE_HEADER_LEN];
  if (read_exact(fd, header, sizeof(header)) != 0) return -1;
  record->kind = header[0];
  record->path_len = read_le16(header + 1);
  uint32_t raw_mode = read_le32(header + 3);
  record->mode = raw_mode;
  record->size = read_le64(header + 7);
  if (header[15] != 0 || record->path_len > MAX_COPY_PATH_LEN || (raw_mode & ~0777U) != 0) return -1;
  if (record->path_len > 0 && read_exact(fd, record->path, record->path_len) != 0) return -1;
  record->path[record->path_len] = '\0';

  if (record->kind == COPY_KIND_END) {
    return record->path_len == 0 && record->mode == 0 && record->size == 0 ? 0 : -1;
  }
  if (record->kind != COPY_KIND_FILE && record->kind != COPY_KIND_DIR) return -1;
  if (record->kind == COPY_KIND_DIR && record->size != 0) return -1;
  return validate_copy_archive_path(record->path, record->path_len, 1);
}

static int expect_archive_eof(int fd) {
  unsigned char byte;
  for (;;) {
    ssize_t n = read(fd, &byte, 1);
    if (n == 0) return 0;
    if (n > 0) return -1;
    if (errno == EINTR) continue;
    return -1;
  }
}

static int copy_archive_file_to_fd(int archive_fd, int out_fd, uint64_t size) {
  unsigned char buf[MAX_FRAME_PAYLOAD];
  uint64_t remaining = size;
  while (remaining > 0) {
    size_t take = remaining > sizeof(buf) ? sizeof(buf) : (size_t)remaining;
    if (read_exact(archive_fd, buf, take) != 0) return -1;
    if (write_all(out_fd, buf, take) != 0) return -1;
    remaining -= take;
  }
  return 0;
}

static int create_copy_archive_file(int archive_fd, const char *path, mode_t mode, uint64_t size) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return -1;
  int rc = copy_archive_file_to_fd(archive_fd, fd, size);
  if (rc == 0 && fchmod(fd, mode & 0777) != 0) rc = -1;
  if (close(fd) != 0) rc = -1;
  if (rc != 0) unlink(path);
  return rc;
}

static int create_copy_archive_dir(const char *path, mode_t mode) {
  return mkdir(path, (mode & 0777) | 0700);
}

static int extract_copy_archive(const char *archive_path, const char *target_path, int *root_kind) {
  int fd = open(archive_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return -1;

  unsigned char magic[sizeof(copy_archive_magic)];
  int rc = 0;
  if (read_exact(fd, magic, sizeof(magic)) != 0 || memcmp(magic, copy_archive_magic, sizeof(magic)) != 0) rc = -1;

  struct copy_record record;
  if (rc == 0 && read_copy_record(fd, &record) != 0) rc = -1;
  if (rc == 0 && record.path_len != 0) rc = -1;
  if (rc == 0) {
    *root_kind = record.kind;
    if (record.kind == COPY_KIND_FILE) {
      if (create_copy_archive_file(fd, target_path, (mode_t)record.mode, record.size) != 0) rc = -1;
      if (rc == 0 && read_copy_record(fd, &record) != 0) rc = -1;
      if (rc == 0 && record.kind != COPY_KIND_END) rc = -1;
      if (rc == 0 && expect_archive_eof(fd) != 0) rc = -1;
    } else if (record.kind == COPY_KIND_DIR) {
      if (create_copy_archive_dir(target_path, (mode_t)record.mode) != 0) rc = -1;
      while (rc == 0) {
        if (read_copy_record(fd, &record) != 0) {
          rc = -1;
          break;
        }
        if (record.kind == COPY_KIND_END) break;
        if (record.path_len == 0) {
          rc = -1;
          break;
        }
        char child[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
        if (build_copy_archive_target(child, sizeof(child), target_path, record.path) != 0) {
          rc = -1;
          break;
        }
        if (record.kind == COPY_KIND_FILE) {
          if (create_copy_archive_file(fd, child, (mode_t)record.mode, record.size) != 0) rc = -1;
        } else if (record.kind == COPY_KIND_DIR) {
          if (create_copy_archive_dir(child, (mode_t)record.mode) != 0) rc = -1;
        } else {
          rc = -1;
        }
      }
      if (rc == 0 && expect_archive_eof(fd) != 0) rc = -1;
    } else {
      rc = -1;
    }
  }

  if (close(fd) != 0) rc = -1;
  return rc;
}

static int send_copy_stdout(struct client *client, const unsigned char *buf, size_t len) {
  if (len == 0) return 0;
  if (send_spio_data(client->fd, SPIO_STDOUT_STREAM, client->stdout_offset, buf, len) != 0) return -1;
  client->stdout_offset += len;
  return 0;
}

static int send_copy_record(struct client *client, int kind, const char *rel, mode_t mode, uint64_t size) {
  size_t rel_len = strlen(rel);
  if (rel_len > MAX_COPY_PATH_LEN || (kind != COPY_KIND_END && validate_copy_archive_path(rel, rel_len, 1) != 0)) return -1;
  unsigned char header[COPY_ARCHIVE_HEADER_LEN];
  header[0] = (unsigned char)kind;
  write_le16(header + 1, (uint16_t)rel_len);
  write_le32(header + 3, (uint32_t)(mode & 0777));
  write_le64(header + 7, size);
  header[15] = 0;
  if (send_copy_stdout(client, header, sizeof(header)) != 0) return -1;
  if (rel_len > 0 && send_copy_stdout(client, (const unsigned char *)rel, rel_len) != 0) return -1;
  return 0;
}

static int emit_copy_entry(struct client *client, const char *path, const char *rel) {
  struct stat st;
  if (lstat(path, &st) != 0) return -1;

  if (S_ISREG(st.st_mode)) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat opened;
    if (fstat(fd, &opened) != 0 || !S_ISREG(opened.st_mode)) {
      close(fd);
      return -1;
    }
    if (send_copy_record(client, COPY_KIND_FILE, rel, opened.st_mode, (uint64_t)opened.st_size) != 0) {
      close(fd);
      return -1;
    }
    static unsigned char buf[SPIO_BATCH_FRAMES * MAX_FRAME_PAYLOAD];
    int rc = 0;
    for (;;) {
      ssize_t n = read(fd, buf, sizeof(buf));
      if (n > 0) {
        if (send_copy_stdout(client, buf, (size_t)n) != 0) {
          rc = -1;
          break;
        }
        continue;
      }
      if (n == 0) break;
      if (errno == EINTR) continue;
      rc = -1;
      break;
    }
    if (close(fd) != 0) rc = -1;
    return rc;
  }

  if (!S_ISDIR(st.st_mode)) return -1;
  if (send_copy_record(client, COPY_KIND_DIR, rel, st.st_mode, 0) != 0) return -1;

  int dir_fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (dir_fd < 0) return -1;
  DIR *dir = fdopendir(dir_fd);
  if (dir == NULL) {
    close(dir_fd);
    return -1;
  }
  int rc = 0;
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    char child_path[MAX_COPY_FULL_PATH_LEN + MAX_COPY_PATH_LEN + 2];
    char child_rel[MAX_COPY_PATH_LEN + 1];
    int path_n = snprintf(child_path, sizeof(child_path), "%s/%s", path, entry->d_name);
    int rel_n = rel[0] == '\0'
        ? snprintf(child_rel, sizeof(child_rel), "%s", entry->d_name)
        : snprintf(child_rel, sizeof(child_rel), "%s/%s", rel, entry->d_name);
    if (path_n <= 0 || (size_t)path_n >= sizeof(child_path) ||
        rel_n <= 0 || (size_t)rel_n >= sizeof(child_rel) ||
        validate_copy_archive_path(child_rel, strlen(child_rel), 0) != 0 ||
        emit_copy_entry(client, child_path, child_rel) != 0) {
      rc = -1;
      break;
    }
  }
  if (closedir(dir) != 0) rc = -1;
  return rc;
}

int copy_in_file(struct client *client, const char *root, const char *guest_path) {
  if (validate_copy_path(guest_path) != 0) return send_client_error_exit(client, 2, "spore copy-in: invalid guest path\n");

  char path[MAX_COPY_FULL_PATH_LEN];
  char tmp_dir[MAX_COPY_FULL_PATH_LEN + 96];
  char tmp[MAX_COPY_FULL_PATH_LEN + 112];
  if (build_copy_path(path, sizeof(path), root, guest_path) != 0) {
    return send_client_error_exit(client, 2, "spore copy-in: guest path is too long\n");
  }
  if (reserve_copy_tmp_dir(tmp_dir, sizeof(tmp_dir), path) != 0) {
    return send_client_error_exit(client, 1, "spore copy-in: cannot create guest transfer temp\n");
  }
  int tmp_n = snprintf(tmp, sizeof(tmp), "%s/payload", tmp_dir);
  if (tmp_n <= 0 || (size_t)tmp_n >= sizeof(tmp)) {
    remove_tree(tmp_dir);
    return send_client_error_exit(client, 2, "spore copy-in: guest path is too long\n");
  }

  char archive_tmp[MAX_COPY_FULL_PATH_LEN + 112];
  int archive_n = snprintf(archive_tmp, sizeof(archive_tmp), "%s/archive", tmp_dir);
  if (archive_n <= 0 || (size_t)archive_n >= sizeof(archive_tmp)) {
    remove_tree(tmp_dir);
    return send_client_error_exit(client, 1, "spore copy-in: cannot create guest transfer archive\n");
  }

  if (receive_lifecycle_copy_archive_from_spio(client, archive_tmp) != 0) {
    remove_tree(tmp_dir);
    return send_client_error_exit(client, 1, "spore copy-in: transfer failed\n");
  }

  int root_kind = 0;
  if (extract_copy_archive(archive_tmp, tmp, &root_kind) != 0) {
    remove_tree(tmp_dir);
    return send_client_error_exit(client, 1, "spore copy-in: cannot write guest path\n");
  }
  unlink(archive_tmp);

  int publish_rc = root_kind == COPY_KIND_FILE ? link(tmp, path) : rename_noreplace(tmp, path);
  if (publish_rc != 0) {
    int exists = errno == EEXIST;
    remove_tree(tmp_dir);
    if (exists) return send_client_error_exit(client, 1, "spore copy-in: guest path already exists\n");
    return send_client_error_exit(client, 1, "spore copy-in: cannot publish guest path\n");
  }
  remove_tree(tmp_dir);
  return send_client_exit(client, 0);
}

int copy_out_file(struct client *client, const char *root, const char *guest_path) {
  if (validate_copy_path(guest_path) != 0) return send_client_error_exit(client, 2, "spore copy-out: invalid guest path\n");

  char path[MAX_COPY_FULL_PATH_LEN];
  if (build_copy_path(path, sizeof(path), root, guest_path) != 0) {
    return send_client_error_exit(client, 2, "spore copy-out: guest path is too long\n");
  }

  if (send_copy_stdout(client, copy_archive_magic, sizeof(copy_archive_magic)) != 0 ||
      emit_copy_entry(client, path, "") != 0 ||
      send_copy_record(client, COPY_KIND_END, "", 0, 0) != 0) {
    return send_client_error_exit(client, 1, "spore copy-out: cannot read guest path\n");
  }
  return send_client_exit(client, 0);
}
