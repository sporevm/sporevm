// The rootfs disk: mount at boot, injected files, ext4 growth, and
// freeze/thaw for build snapshots.

#include "agent.h"

#define SPORE_INJECTED_INITRD_DIR "/run/sporevm/injected"
#define SPORE_INJECTED_ROOTFS_DIR "/mnt/rootfs/run/sporevm/injected"
#ifndef FIFREEZE
#define FIFREEZE _IOWR('X', 119, int)
#endif
#ifndef FITHAW
#define FITHAW _IOWR('X', 120, int)
#endif
#ifndef EXT4_IOC_RESIZE_FS
#define EXT4_IOC_RESIZE_FS _IOW('f', 16, uint64_t)
#endif
#ifndef BLKGETSIZE64
#define BLKGETSIZE64 _IOR(0x12, 114, size_t)
#endif
/* Fixed offsets in the little-endian ext4 on-disk superblock, not a C ABI. */
#define EXT4_PRIMARY_SUPER_OFFSET 1024
#define EXT4_SUPER_SIZE 1024
#define EXT4_SUPER_MAGIC 0xef53U
#define EXT4_STATE_ERROR 0x0002U
#define EXT4_STATE_ORPHAN 0x0004U
#define EXT4_FEATURE_COMPAT_HAS_JOURNAL 0x0004U
#define EXT4_FEATURE_INCOMPAT_RECOVER 0x0004U
#define EXT4_FEATURE_INCOMPAT_JOURNAL_DEV 0x0008U
#define EXT4_FEATURE_INCOMPAT_64BIT 0x0080U
#define EXT4_FEATURE_RO_COMPAT_ORPHAN_PRESENT 0x00010000U
#define EXT4_SUPER_BLOCKS_COUNT_LO_OFFSET 0x04
#define EXT4_SUPER_LOG_BLOCK_SIZE_OFFSET 0x18
#define EXT4_SUPER_BLOCKS_PER_GROUP_OFFSET 0x20
#define EXT4_SUPER_MAGIC_OFFSET 0x38
#define EXT4_SUPER_STATE_OFFSET 0x3a
#define EXT4_SUPER_FEATURE_COMPAT_OFFSET 0x5c
#define EXT4_SUPER_FEATURE_INCOMPAT_OFFSET 0x60
#define EXT4_SUPER_FEATURE_RO_COMPAT_OFFSET 0x64
#define EXT4_SUPER_LAST_ORPHAN_OFFSET 0xe8
#define EXT4_SUPER_BLOCKS_COUNT_HI_OFFSET 0x150

static int copy_injected_files_to_rootfs(char *error, size_t cap);
static int preflight_rootfs_growth_source(char *error, size_t cap);

static int mount_if_dir(const char *source, const char *target, const char *fstype, unsigned long flags, const char *data, char *error, size_t cap) {
  if (!path_is_dir(target)) return 0;
  if (mount(source, target, fstype, flags, data) != 0 && errno != EBUSY) {
    snprintf(error, cap, "rootfs runtime mount failed: %s errno=%d", target, errno);
    return -1;
  }
  return 0;
}

static int replace_symlink(const char *target, const char *path, char *error, size_t cap) {
  if (unlink(path) != 0 && errno != ENOENT) {
    snprintf(error, cap, "rootfs runtime symlink remove failed: %s errno=%d", path, errno);
    return -1;
  }
  if (symlink(target, path) != 0) {
    snprintf(error, cap, "rootfs runtime symlink failed: %s errno=%d", path, errno);
    return -1;
  }
  return 0;
}

static int setup_rootfs_dev(char *error, size_t cap) {
  const char *dev = "/mnt/rootfs/dev";
  const char *pts = "/mnt/rootfs/dev/pts";
  if (!path_is_dir(dev)) return 0;
  if (mount("devtmpfs", dev, "devtmpfs", MS_NOSUID, "") != 0 && errno != EBUSY) {
    snprintf(error, cap, "rootfs runtime mount failed: %s errno=%d", dev, errno);
    return -1;
  }
  if (mkdir(pts, 0755) != 0 && errno != EEXIST) {
    snprintf(error, cap, "rootfs runtime mkdir failed: %s errno=%d", pts, errno);
    return -1;
  }
  if (mount("devpts", pts, "devpts", 0, "mode=0620,ptmxmode=0666") != 0 && errno != EBUSY) {
    snprintf(error, cap, "rootfs runtime mount failed: %s errno=%d", pts, errno);
    return -1;
  }
  if (replace_symlink("/proc/self/fd", "/mnt/rootfs/dev/fd", error, cap) != 0) return -1;
  if (replace_symlink("/proc/self/fd/0", "/mnt/rootfs/dev/stdin", error, cap) != 0) return -1;
  if (replace_symlink("/proc/self/fd/1", "/mnt/rootfs/dev/stdout", error, cap) != 0) return -1;
  if (replace_symlink("/proc/self/fd/2", "/mnt/rootfs/dev/stderr", error, cap) != 0) return -1;
  if (replace_symlink("pts/ptmx", "/mnt/rootfs/dev/ptmx", error, cap) != 0) return -1;
  return 0;
}

int setup_rootfs(int writable, int growth_session, int noinit_itable, int build_mode, char *error, size_t cap) {
  mkdir("/mnt", 0755);
  mkdir("/mnt/rootfs", 0755);
  if (growth_session && !writable) {
    snprintf(error, cap, "rootfs growth requires a writable rootfs");
    return -1;
  }
  if (noinit_itable && !growth_session) {
    snprintf(error, cap, "rootfs noinit_itable requires a growth session");
    return -1;
  }
  if (wait_for_path("/dev/vda", 100, 50000) != 0) {
    snprintf(error, cap, "rootfs block device not found");
    return -1;
  }
  if (growth_session && preflight_rootfs_growth_source(error, cap) != 0) return -1;
  unsigned long rootfs_flags = writable ? 0 : MS_RDONLY;
  const char *rootfs_data = writable ? (noinit_itable ? "noinit_itable" : "") : "noload";
  if (mount("/dev/vda", "/mnt/rootfs", "ext4", rootfs_flags, rootfs_data) != 0) {
    snprintf(error, cap, "rootfs mount failed: errno=%d", errno);
    return -1;
  }
  if (!build_mode) {
    if (setup_rootfs_dev(error, cap) != 0) return -1;
    if (mount_if_dir("proc", "/mnt/rootfs/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, "", error, cap) != 0) return -1;
    if (mount_if_dir("sysfs", "/mnt/rootfs/sys", "sysfs", MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV, "", error, cap) != 0) return -1;
    mount_cgroup2_if_dir("/mnt/rootfs/sys/fs/cgroup");
    if (mount_if_dir("tmpfs", "/mnt/rootfs/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755", error, cap) != 0) return -1;
    if (mount_if_dir("tmpfs", "/mnt/rootfs/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777", error, cap) != 0) return -1;
    if (copy_injected_files_to_rootfs(error, cap) != 0) return -1;
  }
  return 0;
}

static int valid_injected_file_id(const char *id) {
  size_t len = strlen(id);
  if (len == 0 || len > 96) return 0;
  if (strcmp(id, ".") == 0 || strcmp(id, "..") == 0) return 0;
  for (size_t i = 0; i < len; i++) {
    char c = id[i];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') continue;
    return 0;
  }
  return 1;
}

static int copy_injected_file(const char *src, const char *dst) {
  int in = open(src, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (in < 0) return -1;
  struct stat st;
  if (fstat(in, &st) != 0 || !S_ISREG(st.st_mode)) {
    close(in);
    return -1;
  }
  int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0400);
  if (out < 0) {
    close(in);
    return -1;
  }
  char buf[4096];
  int rc = 0;
  for (;;) {
    ssize_t n = read(in, buf, sizeof(buf));
    if (n < 0) {
      if (errno == EINTR) continue;
      rc = -1;
      break;
    }
    if (n == 0) break;
    if (write_all(out, buf, (size_t)n) != 0) {
      rc = -1;
      break;
    }
  }
  if (fchmod(out, 0400) != 0) rc = -1;
  if (close(out) != 0) rc = -1;
  if (close(in) != 0) rc = -1;
  return rc;
}

static int copy_injected_files_to_rootfs(char *error, size_t cap) {
  DIR *dir = opendir(SPORE_INJECTED_INITRD_DIR);
  if (dir == NULL) {
    if (errno == ENOENT) return 0;
    snprintf(error, cap, "injected file setup failed: open injected dir errno=%d", errno);
    return -1;
  }
  if (mkdir_p(SPORE_INJECTED_ROOTFS_DIR, 0700) != 0) {
    snprintf(error, cap, "injected file setup failed: create rootfs dir errno=%d", errno);
    closedir(dir);
    return -1;
  }
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    if (!valid_injected_file_id(entry->d_name)) {
      snprintf(error, cap, "injected file setup failed: invalid injected id");
      closedir(dir);
      return -1;
    }
    char src[192];
    char dst[192];
    int src_len = snprintf(src, sizeof(src), "%s/%s", SPORE_INJECTED_INITRD_DIR, entry->d_name);
    int dst_len = snprintf(dst, sizeof(dst), "%s/%s", SPORE_INJECTED_ROOTFS_DIR, entry->d_name);
    if (src_len <= 0 || (size_t)src_len >= sizeof(src) || dst_len <= 0 || (size_t)dst_len >= sizeof(dst)) {
      snprintf(error, cap, "injected file setup failed: path too long");
      closedir(dir);
      return -1;
    }
    if (copy_injected_file(src, dst) != 0) {
      snprintf(error, cap, "injected file setup failed: copy %s errno=%d", entry->d_name, errno);
      closedir(dir);
      return -1;
    }
  }
  if (closedir(dir) != 0) {
    snprintf(error, cap, "injected file setup failed: close injected dir errno=%d", errno);
    return -1;
  }
  return 0;
}

struct ext4_disk_geometry {
  uint64_t blocks_count;
  uint32_t blocks_per_group;
  uint32_t block_size;
  uint16_t state;
  uint32_t feature_compat;
  uint32_t feature_incompat;
  uint32_t feature_ro_compat;
  uint32_t last_orphan;
};

static int decode_ext4_disk_geometry(const unsigned char *super, size_t len, struct ext4_disk_geometry *out) {
  if (len != EXT4_SUPER_SIZE || read_le16(super + EXT4_SUPER_MAGIC_OFFSET) != EXT4_SUPER_MAGIC) return -1;
  uint32_t log_block_size = read_le32(super + EXT4_SUPER_LOG_BLOCK_SIZE_OFFSET);
  if (log_block_size > 6) return -1;
  uint32_t block_size = 1024U << log_block_size;
  uint32_t blocks_per_group = read_le32(super + EXT4_SUPER_BLOCKS_PER_GROUP_OFFSET);
  uint32_t feature_incompat = read_le32(super + EXT4_SUPER_FEATURE_INCOMPAT_OFFSET);
  uint64_t blocks_count = read_le32(super + EXT4_SUPER_BLOCKS_COUNT_LO_OFFSET);
  if ((feature_incompat & EXT4_FEATURE_INCOMPAT_64BIT) != 0) {
    blocks_count |= (uint64_t)read_le32(super + EXT4_SUPER_BLOCKS_COUNT_HI_OFFSET) << 32;
  }
  if (blocks_count == 0 || blocks_per_group == 0) return -1;
  out->blocks_count = blocks_count;
  out->blocks_per_group = blocks_per_group;
  out->block_size = block_size;
  out->state = read_le16(super + EXT4_SUPER_STATE_OFFSET);
  out->feature_compat = read_le32(super + EXT4_SUPER_FEATURE_COMPAT_OFFSET);
  out->feature_incompat = feature_incompat;
  out->feature_ro_compat = read_le32(super + EXT4_SUPER_FEATURE_RO_COMPAT_OFFSET);
  out->last_orphan = read_le32(super + EXT4_SUPER_LAST_ORPHAN_OFFSET);
  return 0;
}

static int read_ext4_disk_geometry(int fd, struct ext4_disk_geometry *out) {
  unsigned char super[EXT4_SUPER_SIZE];
  size_t done = 0;
  while (done < sizeof(super)) {
    ssize_t n = pread(fd, super + done, sizeof(super) - done, EXT4_PRIMARY_SUPER_OFFSET + (off_t)done);
    if (n == 0) return -1;
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    done += (size_t)n;
  }
  return decode_ext4_disk_geometry(super, sizeof(super), out);
}

static int validate_ext4_growth_source(const struct ext4_disk_geometry *source) {
  if ((source->feature_compat & EXT4_FEATURE_COMPAT_HAS_JOURNAL) != 0) return -1;
  if ((source->feature_incompat & (EXT4_FEATURE_INCOMPAT_RECOVER | EXT4_FEATURE_INCOMPAT_JOURNAL_DEV)) != 0) return -1;
  if ((source->state & (EXT4_STATE_ERROR | EXT4_STATE_ORPHAN)) != 0) return -1;
  if (source->last_orphan != 0) return -1;
  if ((source->feature_ro_compat & EXT4_FEATURE_RO_COMPAT_ORPHAN_PRESENT) != 0) return -1;
  return 0;
}

static int preflight_rootfs_growth_source(char *error, size_t cap) {
  int fd = open("/dev/vda", O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    snprintf(error, cap, "rootfs growth source open failed");
    return -1;
  }
  struct ext4_disk_geometry source;
  int read_rc = read_ext4_disk_geometry(fd, &source);
  int close_rc = close(fd);
  if (read_rc != 0 || close_rc != 0) {
    snprintf(error, cap, "rootfs growth source validation failed");
    return -1;
  }
  if (validate_ext4_growth_source(&source) != 0) {
    snprintf(error, cap, "rootfs growth source is unsupported or requires recovery");
    return -1;
  }
  return 0;
}

static int validate_rootfs_grow_geometry(uint64_t target_blocks, const struct ext4_disk_geometry *before, const struct ext4_disk_geometry *after) {
  if (target_blocks == 0 || before->block_size != after->block_size || before->blocks_per_group != after->blocks_per_group) return -1;
  if (before->blocks_count == 0 || before->blocks_count >= target_blocks) return -1;
  if (after->blocks_count <= before->blocks_count || after->blocks_count > target_blocks) return -1;
  /* ext4 may drop an undersized terminal group or round bigalloc to a cluster. */
  if (target_blocks - after->blocks_count >= after->blocks_per_group) return -1;
  return 0;
}

int freeze_or_thaw_rootfs(struct client *client, int freeze) {
  int restore_build_resolv = !freeze && build_resolv.configured;
  if (freeze && unmount_build_resolv_for_snapshot(&build_resolv) != 0) {
    return send_client_error_exit(client, 126, "spore build: resolver cleanup before freeze failed\n");
  }
  int fd = open("/mnt/rootfs", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) return send_client_error_exit(client, 126, freeze ? "spore build: rootfs freeze open failed\n" : "spore build: rootfs thaw open failed\n");
  int arg = 0;
  int rc = 0;
  if (freeze) sync();
  if (ioctl(fd, freeze ? FIFREEZE : FITHAW, &arg) != 0) rc = -1;
  if (close(fd) != 0) rc = -1;
  if (rc != 0) return send_client_error_exit(client, 126, freeze ? "spore build: fsfreeze failed\n" : "spore build: fsthaw failed\n");
  if (restore_build_resolv) {
    char error[192];
    error[0] = '\0';
    if (bind_rootfs_resolv(1, error, sizeof(error)) != 0) {
      return send_client_error_exit(client, 126, "spore build: resolver restore after thaw failed\n");
    }
  }
  return send_client_exit(client, 0);
}

int grow_rootfs(struct client *client) {
  int device_fd = open("/dev/vda", O_RDONLY | O_CLOEXEC);
  if (device_fd < 0) return send_client_error_exit(client, 126, "spore build: rootfs grow device open failed\n");

  uint64_t device_bytes = 0;
  if (ioctl(device_fd, BLKGETSIZE64, &device_bytes) != 0 || device_bytes == 0) {
    close(device_fd);
    return send_client_error_exit(client, 126, "spore build: rootfs grow device geometry failed\n");
  }

  struct ext4_disk_geometry before_disk;
  if (read_ext4_disk_geometry(device_fd, &before_disk) != 0 ||
      validate_ext4_growth_source(&before_disk) != 0) {
    close(device_fd);
    return send_client_error_exit(client, 126, "spore build: rootfs grow ext4 geometry failed\n");
  }

  int fs_fd = open("/mnt/rootfs", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fs_fd < 0) {
    close(device_fd);
    return send_client_error_exit(client, 126, "spore build: rootfs grow mount open failed\n");
  }

  struct statfs before;
  if (fstatfs(fs_fd, &before) != 0 || before.f_bsize <= 0) {
    close(fs_fd);
    close(device_fd);
    return send_client_error_exit(client, 126, "spore build: rootfs grow filesystem geometry failed\n");
  }
  uint64_t block_size = before_disk.block_size;
  if ((uint64_t)before.f_bsize != block_size || before.f_blocks == 0 || before.f_bavail > before.f_blocks || device_bytes % block_size != 0) {
    close(fs_fd);
    close(device_fd);
    return send_client_error_exit(client, 126, "spore build: rootfs grow geometry is unaligned\n");
  }
  uint64_t target_blocks = device_bytes / block_size;
  if (before_disk.blocks_count >= target_blocks) {
    close(fs_fd);
    close(device_fd);
    return send_client_error_exit(client, 126, "spore build: rootfs grow target is not larger than the filesystem\n");
  }

  uint64_t resize_blocks = target_blocks;
  if (ioctl(fs_fd, EXT4_IOC_RESIZE_FS, &resize_blocks) != 0) {
    close(fs_fd);
    close(device_fd);
    return send_client_error_exit(client, 126, "spore build: rootfs grow ioctl failed\n");
  }
  if (syncfs(fs_fd) != 0) {
    close(fs_fd);
    close(device_fd);
    return send_client_error_exit(client, 126, "spore build: rootfs grow sync failed\n");
  }

  struct ext4_disk_geometry after_disk;
  struct statfs after;
  int verify_rc = read_ext4_disk_geometry(device_fd, &after_disk);
  if (verify_rc == 0 && validate_ext4_growth_source(&after_disk) != 0) verify_rc = -1;
  if (verify_rc == 0) verify_rc = fstatfs(fs_fd, &after);
  if (close(fs_fd) != 0) verify_rc = -1;
  if (close(device_fd) != 0) verify_rc = -1;
  if (verify_rc != 0 || after.f_bsize <= 0) {
    return send_client_error_exit(client, 126, "spore build: rootfs grow verification failed\n");
  }
  uint64_t after_block_size = (uint64_t)after.f_bsize;
  uint64_t usable_blocks = (uint64_t)after.f_blocks;
  if (validate_rootfs_grow_geometry(target_blocks, &before_disk, &after_disk) != 0 ||
      after_block_size != block_size || usable_blocks == 0 || usable_blocks > after_disk.blocks_count ||
      (uint64_t)after.f_bavail > usable_blocks || after.f_files == 0 || after.f_ffree > after.f_files) {
    return send_client_error_exit(client, 126, "spore build: rootfs grow geometry mismatch\n");
  }
  if ((uint64_t)after.f_bavail > UINT64_MAX / block_size) {
    return send_client_error_exit(client, 126, "spore build: rootfs grow free-space overflow\n");
  }

  char result[512];
  int n = snprintf(result, sizeof(result),
                   "spore-rootfs-grow-v1 device_bytes=%llu block_size=%llu target_blocks=%llu before_blocks=%llu filesystem_blocks=%llu blocks_per_group=%u usable_blocks=%llu free_bytes=%llu inodes=%llu free_inodes=%llu\n",
                   (unsigned long long)device_bytes,
                   (unsigned long long)block_size,
                   (unsigned long long)target_blocks,
                   (unsigned long long)before_disk.blocks_count,
                   (unsigned long long)after_disk.blocks_count,
                   after_disk.blocks_per_group,
                   (unsigned long long)usable_blocks,
                   (unsigned long long)((uint64_t)after.f_bavail * block_size),
                   (unsigned long long)after.f_files,
                   (unsigned long long)after.f_ffree);
  if (n <= 0 || (size_t)n >= sizeof(result) || send_client_stdout(client, result) != 0) return -1;
  return send_client_exit(client, 0);
}

#ifdef SPORE_AGENT_REQUEST_FUZZ
__attribute__((visibility("hidden"))) int spore_agent_fuzz_ext4_geometry(
    const unsigned char *super, size_t super_len,
    uint64_t *blocks_count, uint32_t *blocks_per_group, uint32_t *block_size) {
  struct ext4_disk_geometry geometry;
  if (decode_ext4_disk_geometry(super, super_len, &geometry) != 0) return 0;
  *blocks_count = geometry.blocks_count;
  *blocks_per_group = geometry.blocks_per_group;
  *block_size = geometry.block_size;
  return 1;
}

__attribute__((visibility("hidden"))) int spore_agent_fuzz_ext4_growth_source(
    const unsigned char *super, size_t super_len) {
  struct ext4_disk_geometry source;
  if (decode_ext4_disk_geometry(super, super_len, &source) != 0) return 0;
  return validate_ext4_growth_source(&source) == 0;
}

__attribute__((visibility("hidden"))) int spore_agent_fuzz_rootfs_grow_geometry(
    uint64_t target_blocks,
    uint64_t before_blocks, uint32_t before_blocks_per_group, uint32_t before_block_size,
    uint64_t after_blocks, uint32_t after_blocks_per_group, uint32_t after_block_size) {
  struct ext4_disk_geometry before = {
      .blocks_count = before_blocks,
      .blocks_per_group = before_blocks_per_group,
      .block_size = before_block_size,
  };
  struct ext4_disk_geometry after = {
      .blocks_count = after_blocks,
      .blocks_per_group = after_blocks_per_group,
      .block_size = after_block_size,
  };
  return validate_rootfs_grow_geometry(target_blocks, &before, &after) == 0;
}
#endif
