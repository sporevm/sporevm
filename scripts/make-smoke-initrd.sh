#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/make-smoke-initrd.sh [--mode ticker|idle|fork|dirty] <out.cpio>

Build a tiny newc initrd containing a static /init for KVM/HVF smoke tests.

Modes:
  ticker  print the restore-smoke ticker only (default)
  idle    print readiness once, then sleep without intentional guest writes
  fork    poll the SporeVM generation device, apply fork identity fields, log
          the resume-time params, and ack the generation interrupt last
  dirty   continuously write through an anonymous working set for dirty
          tracking pressure benchmarks

Environment:
  CC   C compiler command to use (default: cc). May include simple arguments,
       for example: CC="zig cc -target aarch64-linux-musl". Must produce an
       aarch64 static binary for the current guest profile.
EOF
}

mode="ticker"
if [[ "${1:-}" == "--mode" ]]; then
  mode="${2:-}"
  shift 2
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  [[ $# -eq 1 ]] && exit 0 || exit 2
fi
case "${mode}" in
  ticker|idle|fork|dirty) ;;
  *)
    echo "error: --mode must be ticker, idle, fork, or dirty" >&2
    exit 2
    ;;
esac

out="$1"
read -r -a cc_cmd <<<"${CC:-cc}"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-initrd.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/root"
if [[ "${mode}" == "ticker" ]]; then
  cat >"${workdir}/init.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
  for (unsigned long i = 0;; i++) {
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "sporevm-initrd-tick %lu\n", i);
    if (n > 0) {
      ssize_t ignored = write(1, buf, (size_t)n);
      (void)ignored;
    }
    sleep(1);
  }
}
EOF
elif [[ "${mode}" == "idle" ]]; then
  cat >"${workdir}/init.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define GEN_BASE 0x0c001000ULL
#define GEN_WINDOW_SIZE 0x1000U
#define REG_MAGIC 0x000U

int main(void) {
  mkdir("/dev", 0755);
  if (mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1)) != 0 && errno != EEXIST) {
    printf("sporevm-idle-smoke error=mknod-devmem errno=%d\n", errno);
    fflush(stdout);
    for (;;) sleep(3600);
  }
  int fd = open("/dev/mem", O_RDONLY | O_SYNC);
  if (fd < 0) {
    printf("sporevm-idle-smoke error=open-devmem errno=%d\n", errno);
    fflush(stdout);
    for (;;) sleep(3600);
  }
  void *mapped = mmap(NULL, GEN_WINDOW_SIZE, PROT_READ, MAP_SHARED, fd, (off_t)GEN_BASE);
  close(fd);
  if (mapped == MAP_FAILED) {
    printf("sporevm-idle-smoke error=mmap-generation errno=%d\n", errno);
    fflush(stdout);
    for (;;) sleep(3600);
  }

  volatile uint32_t *generation_magic = (volatile uint32_t *)((volatile uint8_t *)mapped + REG_MAGIC);
  puts("sporevm-idle-smoke ready");
  fflush(stdout);
  for (;;) {
    volatile uint32_t ignored = *generation_magic;
    (void)ignored;
    sleep(1);
  }
}
EOF
elif [[ "${mode}" == "dirty" ]]; then
  cat >"${workdir}/init.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define WORKING_SET_MIB 1024UL
#define MIN_WORKING_SET_MIB 128UL
#define PAGE_SIZE_BYTES 4096UL

static unsigned long long monotonic_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  return (unsigned long long)ts.tv_sec * 1000ULL + (unsigned long long)ts.tv_nsec / 1000000ULL;
}

int main(void) {
  unsigned long working_set_mib = WORKING_SET_MIB;
  size_t len = 0;
  volatile uint8_t *buf = MAP_FAILED;
  while (working_set_mib >= MIN_WORKING_SET_MIB) {
    len = working_set_mib * 1024UL * 1024UL;
    buf = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf != MAP_FAILED) break;
    working_set_mib /= 2;
  }
  if (buf == MAP_FAILED) {
    printf("sporevm-dirty-smoke error=mmap min_working_set_mib=%lu\n", MIN_WORKING_SET_MIB);
    for (;;) sleep(3600);
  }

  unsigned long pass = 0;
  unsigned long long last_log_ms = monotonic_ms();
  for (;;) {
    for (size_t offset = 0; offset < len; offset += PAGE_SIZE_BYTES) {
      buf[offset] = (uint8_t)(pass + offset);
    }
    pass++;
    unsigned long long now = monotonic_ms();
    if (now - last_log_ms >= 1000ULL) {
      printf("sporevm-dirty-smoke pass=%lu working_set_mib=%lu\n", pass, working_set_mib);
      fflush(stdout);
      last_log_ms = now;
    }
  }
}
EOF
else
  cat >"${workdir}/init.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#define GEN_BASE 0x0c001000ULL
#define GEN_WINDOW_SIZE 0x1000U
#define GEN_MAGIC 0x4e475053U
#define GEN_IRQ_GENERATION_CHANGED 1U

#define REG_MAGIC 0x000U
#define REG_VERSION 0x004U
#define REG_PARAMS_OFFSET 0x008U
#define REG_PARAMS_SIZE 0x00cU
#define REG_IRQ_STATUS 0x010U
#define REG_IRQ_ACK 0x014U
#define REG_GENERATION 0x018U

static volatile uint8_t *generation_map(void) {
  mkdir("/dev", 0755);
  if (mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1)) != 0 && errno != EEXIST) {
    printf("sporevm-fork-smoke error=mknod-devmem errno=%d\n", errno);
    return NULL;
  }
  int fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (fd < 0) {
    printf("sporevm-fork-smoke error=open-devmem errno=%d\n", errno);
    return NULL;
  }
  void *mapped = mmap(NULL, GEN_WINDOW_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GEN_BASE);
  close(fd);
  if (mapped == MAP_FAILED) {
    printf("sporevm-fork-smoke error=mmap-generation errno=%d\n", errno);
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

static int json_string(const char *json, const char *key, char *out, size_t out_len) {
  char pattern[96];
  snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
  const char *start = strstr(json, pattern);
  if (start == NULL) return 0;
  start += strlen(pattern);
  const char *end = strchr(start, '"');
  if (end == NULL) return 0;
  size_t len = (size_t)(end - start);
  if (len >= out_len) len = out_len - 1;
  memcpy(out, start, len);
  out[len] = '\0';
  return 1;
}

static int json_u64(const char *json, const char *key, unsigned long long *out) {
  char pattern[96];
  snprintf(pattern, sizeof(pattern), "\"%s\":", key);
  const char *start = strstr(json, pattern);
  if (start == NULL) return 0;
  start += strlen(pattern);
  char *end = NULL;
  unsigned long long value = strtoull(start, &end, 10);
  if (end == start) return 0;
  *out = value;
  return 1;
}

static void write_file(const char *path, const char *value) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  ssize_t ignored = write(fd, value, strlen(value));
  (void)ignored;
  close(fd);
}

static void mix_entropy(const char *seed) {
  if (mknod("/dev/urandom", S_IFCHR | 0600, makedev(1, 9)) != 0 && errno != EEXIST) return;
  int fd = open("/dev/urandom", O_WRONLY);
  if (fd < 0) return;
  ssize_t ignored = write(fd, seed, strlen(seed));
  (void)ignored;
  close(fd);
}

static void apply_clock(unsigned long long unix_ns) {
  struct timespec ts;
  ts.tv_sec = (time_t)(unix_ns / 1000000000ULL);
  ts.tv_nsec = (long)(unix_ns % 1000000000ULL);
  if (clock_settime(CLOCK_REALTIME, &ts) != 0) {
    printf("sporevm-fork-smoke clock_settime_errno=%d\n", errno);
  }
}

static void process_generation(volatile uint8_t *gen, uint64_t generation, uint32_t irq_status, const char *params) {
  char vm_id[80] = {0};
  char hostname[80] = {0};
  char mac_address[32] = {0};
  char entropy_seed[80] = {0};
  unsigned long long parent_generation = 0;
  unsigned long long fork_index = 0;
  unsigned long long fork_count = 0;
  unsigned long long parallel_index = 0;
  unsigned long long parallel_count = 0;
  unsigned long long resume_time_unix_ns = 0;

  json_string(params, "vm_id", vm_id, sizeof(vm_id));
  json_string(params, "hostname", hostname, sizeof(hostname));
  json_string(params, "mac_address", mac_address, sizeof(mac_address));
  json_string(params, "resume_entropy_seed", entropy_seed, sizeof(entropy_seed));
  json_u64(params, "parent_generation", &parent_generation);
  json_u64(params, "fork_index", &fork_index);
  json_u64(params, "fork_count", &fork_count);
  json_u64(params, "parallel_index", &parallel_index);
  json_u64(params, "parallel_count", &parallel_count);
  json_u64(params, "resume_time_unix_ns", &resume_time_unix_ns);

  if (hostname[0] != '\0') {
    sethostname(hostname, strlen(hostname));
  }
  if (vm_id[0] != '\0') {
    mkdir("/etc", 0755);
    write_file("/etc/machine-id", vm_id);
  }
  if (entropy_seed[0] != '\0') {
    mix_entropy(entropy_seed);
  }
  if (resume_time_unix_ns != 0) {
    apply_clock(resume_time_unix_ns);
  }

  printf("sporevm-fork-smoke generation=%llu parent_generation=%llu fork_index=%llu fork_count=%llu parallel_index=%llu parallel_count=%llu irq_status=%u\n",
         (unsigned long long)generation, parent_generation, fork_index, fork_count, parallel_index, parallel_count, irq_status);
  printf("sporevm-fork-smoke vm_id=%s hostname=%s mac_address=%s resume_time_unix_ns=%llu entropy_seed=%s\n",
         vm_id, hostname, mac_address, resume_time_unix_ns, entropy_seed);
  printf("sporevm-fork-smoke params=%s\n", params);

  mmio_write32(gen, REG_IRQ_ACK, GEN_IRQ_GENERATION_CHANGED);
  printf("sporevm-fork-smoke acked_generation=%llu irq_status_after_ack=%u\n",
         (unsigned long long)generation, mmio_read32(gen, REG_IRQ_STATUS));
}

int main(void) {
  volatile uint8_t *gen = NULL;
  uint64_t last_processed_generation = UINT64_MAX;

  for (unsigned long tick = 0;; tick++) {
    printf("sporevm-initrd-tick %lu\n", tick);
    if (gen == NULL) {
      gen = generation_map();
    }
    if (gen != NULL) {
      uint32_t magic = mmio_read32(gen, REG_MAGIC);
      if (magic != GEN_MAGIC) {
        printf("sporevm-fork-smoke error=bad-magic value=0x%x\n", magic);
      } else {
        uint32_t params_offset = mmio_read32(gen, REG_PARAMS_OFFSET);
        uint32_t params_size = mmio_read32(gen, REG_PARAMS_SIZE);
        uint32_t irq_status = mmio_read32(gen, REG_IRQ_STATUS);
        uint64_t generation = mmio_read64(gen, REG_GENERATION);
        if (params_offset < GEN_WINDOW_SIZE && params_size <= GEN_WINDOW_SIZE - params_offset) {
          char params[GEN_WINDOW_SIZE];
          size_t limit = params_size;
          if (limit >= sizeof(params)) limit = sizeof(params) - 1;
          size_t i = 0;
          for (; i < limit; i++) {
            params[i] = (char)*(gen + params_offset + i);
            if (params[i] == '\0') break;
          }
          params[i] = '\0';
          if (params[0] != '\0' && generation != last_processed_generation) {
            process_generation(gen, generation, irq_status, params);
            last_processed_generation = generation;
          }
        }
      }
    }
    fflush(stdout);
    sleep(1);
  }
}
EOF
fi

"${cc_cmd[@]}" -static -Os -s "${workdir}/init.c" -o "${workdir}/root/init"
chmod 0755 "${workdir}/root/init"

mkdir -p "$(dirname "${out}")"
(
  cd "${workdir}/root"
  find . | LC_ALL=C sort | cpio -o -H newc >"${out}"
)

echo "wrote ${out}"
