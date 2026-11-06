// The generation device: fan-out identity files, resume entropy, and
// the resume clock.

#include "agent.h"

#ifndef SPORE_GENERATION_BASE
#error "SPORE_GENERATION_BASE must come from the selected SporeVM board"
#endif
#define GEN_BASE SPORE_GENERATION_BASE
#define GEN_WINDOW_SIZE 0x1000U
#define GEN_MAGIC 0x4e475053U
#define GEN_IRQ_GENERATION_CHANGED 1U
#define REG_MAGIC 0x000U
#define REG_PARAMS_OFFSET 0x008U
#define REG_PARAMS_SIZE 0x00cU
#define REG_IRQ_STATUS 0x010U
#define REG_IRQ_ACK 0x014U
#define REG_GENERATION 0x018U
#define NSEC_PER_SEC 1000000000ULL

void apply_resume_clock(uint64_t unix_ns) {
  if (unix_ns == 0) return;
  struct timespec ts;
  ts.tv_sec = (time_t)(unix_ns / NSEC_PER_SEC);
  ts.tv_nsec = (long)(unix_ns % NSEC_PER_SEC);
  if (clock_settime(CLOCK_REALTIME, &ts) != 0) {
    dprintf(2, "spore generation: clock_settime failed errno=%d\n", errno);
  }
}

const char *generation_root_path(int use_rootfs, int rootfs_ready) {
  if (use_rootfs && rootfs_ready) return "/mnt/rootfs";
  return "";
}

static void env_append(char *env, size_t *len, const char *key, const char *value) {
  if (value[0] == '\0' || *len >= 2048) return;
  int n = snprintf(env + *len, 2048 - *len, "%s=%s\n", key, value);
  if (n > 0 && (size_t)n < 2048 - *len) *len += (size_t)n;
}

static void env_append_u64(char *env, size_t *len, const char *key, uint64_t value) {
  if (*len >= 2048) return;
  int n = snprintf(env + *len, 2048 - *len, "%s=%llu\n", key, (unsigned long long)value);
  if (n > 0 && (size_t)n < 2048 - *len) *len += (size_t)n;
}

static int build_path(char *out, size_t cap, const char *root, const char *suffix) {
  int n = snprintf(out, cap, "%s%s", root, suffix);
  return n > 0 && (size_t)n < cap ? 0 : -1;
}

static int has_member(const struct generation_params *params, enum generation_member member) {
  return (params->present & (1u << member)) != 0;
}

static int write_generation_files(const char *root, const char *raw_params, const struct generation_params *params) {
  char run_dir[128];
  char spore_dir[160];
  char generation_path[192];
  char env_path[192];
  if (build_path(run_dir, sizeof(run_dir), root, "/run") != 0) return -1;
  if (build_path(spore_dir, sizeof(spore_dir), root, "/run/sporevm") != 0) return -1;
  if (build_path(generation_path, sizeof(generation_path), spore_dir, "/generation.json") != 0) return -1;
  if (build_path(env_path, sizeof(env_path), spore_dir, "/env") != 0) return -1;

  if (mkdir(run_dir, 0755) != 0 && errno != EEXIST) return -1;
  if (mkdir(spore_dir, 0755) != 0 && errno != EEXIST) return -1;

  char json_with_newline[GEN_PARAMS_MAX + 2];
  size_t params_len = strlen(raw_params);
  if (params_len + 1 >= sizeof(json_with_newline)) return -1;
  memcpy(json_with_newline, raw_params, params_len);
  json_with_newline[params_len] = '\n';
  json_with_newline[params_len + 1] = '\0';
  if (write_file_atomic(generation_path, json_with_newline, params_len + 1) != 0) return -1;

  char env[2048];
  size_t env_len = 0;
  env[0] = '\0';

  // Params without a parallel position use the fork position.
  int have_parallel_index = has_member(params, GENERATION_PARALLEL_INDEX);
  int have_parallel_count = has_member(params, GENERATION_PARALLEL_COUNT);
  uint64_t parallel_index = params->parallel_index;
  uint64_t parallel_count = params->parallel_count;
  if (!have_parallel_index && has_member(params, GENERATION_FORK_INDEX)) {
    parallel_index = params->fork_index;
    have_parallel_index = 1;
  }
  if (!have_parallel_count && has_member(params, GENERATION_FORK_COUNT)) {
    parallel_count = params->fork_count;
    have_parallel_count = 1;
  }
  if (have_parallel_index) env_append_u64(env, &env_len, "SPORE_PARALLEL_JOB", parallel_index);
  if (have_parallel_count) env_append_u64(env, &env_len, "SPORE_PARALLEL_JOB_COUNT", parallel_count);
  if (has_member(params, GENERATION_FORK_INDEX)) env_append_u64(env, &env_len, "SPORE_FORK_INDEX", params->fork_index);
  if (has_member(params, GENERATION_FORK_COUNT)) env_append_u64(env, &env_len, "SPORE_FORK_COUNT", params->fork_count);
  if (has_member(params, GENERATION_PARENT_GENERATION)) env_append_u64(env, &env_len, "SPORE_PARENT_GENERATION", params->parent_generation);
  if (has_member(params, GENERATION_GENERATION)) env_append_u64(env, &env_len, "SPORE_GENERATION", params->generation);
  if (has_member(params, GENERATION_RESUME_TIME)) env_append_u64(env, &env_len, "SPORE_RESUME_TIME_UNIX_NS", params->resume_time_unix_ns);
  env_append(env, &env_len, "SPORE_VM_ID", params->vm_id);
  env_append(env, &env_len, "SPORE_FORK_BATCH_ID", params->fork_batch_id);
  env_append(env, &env_len, "SPORE_HOSTNAME", params->hostname);
  env_append(env, &env_len, "SPORE_RESUME_ENTROPY_SEED", params->resume_entropy_seed);

  return write_file_atomic(env_path, env, env_len);
}

static volatile uint8_t *generation_map(void) {
  mkdir("/dev", 0755);
  if (mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1)) != 0 && errno != EEXIST) {
    dprintf(2, "spore generation: mknod /dev/mem failed errno=%d\n", errno);
    return NULL;
  }
  int fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
  if (fd < 0) {
    dprintf(2, "spore generation: open /dev/mem failed errno=%d\n", errno);
    return NULL;
  }
  void *mapped = mmap(NULL, GEN_WINDOW_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GEN_BASE);
  close(fd);
  if (mapped == MAP_FAILED) {
    dprintf(2, "spore generation: mmap failed errno=%d\n", errno);
    return NULL;
  }
  return (volatile uint8_t *)mapped;
}

static uint32_t mmio_read32(volatile uint8_t *base, unsigned offset) {
  volatile uint32_t *p = (volatile uint32_t *)(base + offset);
  return *p;
}

static uint64_t mmio_read64(volatile uint8_t *base, unsigned offset) {
  uint64_t lo = mmio_read32(base, offset);
  uint64_t hi = mmio_read32(base, offset + 4);
  return lo | (hi << 32);
}

static void mmio_write32(volatile uint8_t *base, unsigned offset, uint32_t value) {
  volatile uint32_t *p = (volatile uint32_t *)(base + offset);
  *p = value;
}

static int mix_resume_entropy(const char *entropy_seed) {
  if (entropy_seed[0] == '\0') return 0;
  if (mknod("/dev/urandom", S_IFCHR | 0600, makedev(1, 9)) != 0 && errno != EEXIST) return -1;
  int fd = open("/dev/urandom", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  int write_rc = write_all(fd, entropy_seed, strlen(entropy_seed));
  if (close(fd) != 0) write_rc = -1;
  return write_rc;
}

static int apply_generation_identity(const struct generation_params *params) {
  if (params->hostname[0] != '\0') {
    (void)sethostname(params->hostname, strlen(params->hostname));
  }
  if (mix_resume_entropy(params->resume_entropy_seed) != 0) return -1;
  if (has_member(params, GENERATION_RESUME_TIME)) {
    apply_resume_clock(params->resume_time_unix_ns);
  }
  return 0;
}

int poll_generation(struct generation_monitor *monitor, const char *root) {
  if (monitor->unavailable) return 0;
  if (monitor->base == NULL) {
    monitor->base = generation_map();
    if (monitor->base == NULL) {
      monitor->unavailable = 1;
      return 0;
    }
  }

  if (mmio_read32(monitor->base, REG_MAGIC) != GEN_MAGIC) return 0;
  uint32_t params_offset = mmio_read32(monitor->base, REG_PARAMS_OFFSET);
  uint32_t params_size = mmio_read32(monitor->base, REG_PARAMS_SIZE);
  if (params_offset >= GEN_WINDOW_SIZE || params_size > GEN_WINDOW_SIZE - params_offset) return 0;

  uint64_t generation = mmio_read64(monitor->base, REG_GENERATION);
  if (generation == monitor->last_generation) return 0;

  char params[GEN_PARAMS_MAX];
  size_t limit = params_size;
  if (limit >= sizeof(params)) limit = sizeof(params) - 1;
  size_t i = 0;
  for (; i < limit; i++) {
    params[i] = (char)*(monitor->base + params_offset + i);
    if (params[i] == '\0') break;
  }
  params[i] = '\0';
  if (params[0] == '\0') return 0;

  struct generation_params parsed;
  if (parse_generation_params(params, &parsed) != 0) return -1;
  if (write_generation_files(root, params, &parsed) != 0) return -1;
  uint32_t irq_status = mmio_read32(monitor->base, REG_IRQ_STATUS);
  if (apply_generation_identity(&parsed) != 0) return -1;
  monitor->last_generation = generation;
  if ((irq_status & GEN_IRQ_GENERATION_CHANGED) != 0) {
    mmio_write32(monitor->base, REG_IRQ_ACK, GEN_IRQ_GENERATION_CHANGED);
  }
  return 0;
}

int ensure_generation_ready(struct generation_monitor *monitor, const char *root) {
  if (poll_generation(monitor, root) != 0) return -1;
  return monitor->last_generation == UINT64_MAX ? -1 : 0;
}

static void ack_applied_generation(struct generation_monitor *monitor, const struct generation_params *params) {
  if (!has_member(params, GENERATION_GENERATION) || monitor->unavailable) return;
  uint64_t applied_generation = params->generation;
  if (monitor->base == NULL) {
    monitor->base = generation_map();
    if (monitor->base == NULL) {
      monitor->unavailable = 1;
      return;
    }
  }
  if (mmio_read32(monitor->base, REG_MAGIC) != GEN_MAGIC) return;
  if (mmio_read64(monitor->base, REG_GENERATION) != applied_generation) return;
  monitor->last_generation = applied_generation;
  if ((mmio_read32(monitor->base, REG_IRQ_STATUS) & GEN_IRQ_GENERATION_CHANGED) != 0) {
    mmio_write32(monitor->base, REG_IRQ_ACK, GEN_IRQ_GENERATION_CHANGED);
  }
}

const char *apply_request_generation(struct generation_monitor *generation, const char *root, const char *params) {
  struct generation_params parsed;
  if (parse_generation_params(params, &parsed) != 0) return "spore run: malformed generation params\n";
  if (write_generation_files(root, params, &parsed) != 0) return "spore run: generation helper write failed\n";
  if (apply_generation_identity(&parsed) != 0) return "spore run: generation helper apply failed\n";
  ack_applied_generation(generation, &parsed);
  return NULL;
}
