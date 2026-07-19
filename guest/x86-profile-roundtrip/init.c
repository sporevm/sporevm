#define _GNU_SOURCE

#include <cpuid.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "mailbox_abi.h"

#define PROBE_PREFIX "sporevm-x86-profile-roundtrip"
#define MAILBOX_GPA UINT64_C(0xcffff000)
#define MAILBOX_BYTES 4096U
#define GENERATION_GPA UINT64_C(0xd0001000)
#define GENERATION_BYTES 4096U
#define CAPTURE_DOORBELL_OFFSET 0x028U
#define RESTORED_DOORBELL_OFFSET 0x02cU
#define RESTORED_COMMAND UINT32_C(0x52545352)

extern void profile_state_sequence(volatile uint32_t *capture_doorbell,
                                   struct profile_mailbox *mailbox);

static const uint8_t expected_x87[16] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
    0xff, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
static const uint8_t expected_xmm[16] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
};
static const uint8_t expected_ymm[32] = {
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
    0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f,
};

static _Noreturn void stop_forever(void) {
  for (;;) {
    pause();
  }
}

static _Noreturn void fail_probe(const char *stage, const char *detail) {
  printf(PROBE_PREFIX " status=fail stage=%s detail=%s errno=%d\n", stage,
         detail, errno);
  fflush(stdout);
  stop_forever();
}

static void ensure_directory(const char *path) {
  if (mkdir(path, 0755) != 0 && errno != EEXIST) {
    fail_probe("mount", path);
  }
}

static void mount_filesystem(const char *source, const char *target,
                             const char *type, unsigned long flags) {
  ensure_directory(target);
  if (mount(source, target, type, flags, NULL) != 0 && errno != EBUSY) {
    fail_probe("mount", target);
  }
}

static uint64_t parse_nonce(void) {
  static const char prefix[] = "sporevm.profile_nonce=";
  char buffer[4096];
  int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
  if (fd < 0) fail_probe("nonce", "open-cmdline");
  ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
  if (count < 0) fail_probe("nonce", "read-cmdline");
  close(fd);
  if ((size_t)count == sizeof(buffer) - 1) {
    errno = EOVERFLOW;
    fail_probe("nonce", "cmdline-too-large");
  }
  buffer[count] = '\0';

  const char *match = NULL;
  for (char *token = strtok(buffer, " \t\r\n"); token != NULL;
       token = strtok(NULL, " \t\r\n")) {
    if (strncmp(token, prefix, sizeof(prefix) - 1) != 0) continue;
    if (match != NULL) {
      errno = EINVAL;
      fail_probe("nonce", "duplicate");
    }
    match = token + sizeof(prefix) - 1;
  }
  if (match == NULL || strlen(match) != 16) {
    errno = EINVAL;
    fail_probe("nonce", "missing-or-invalid");
  }
  errno = 0;
  char *end = NULL;
  uintmax_t value = strtoumax(match, &end, 16);
  if (errno != 0 || end != match + 16 || value > UINT64_MAX) {
    errno = EINVAL;
    fail_probe("nonce", "invalid-hex");
  }
  return (uint64_t)value;
}

static void *map_physical(int fd, uint64_t address) {
  void *mapping = mmap(NULL, MAILBOX_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                       fd, (off_t)address);
  if (mapping == MAP_FAILED) fail_probe("mmap", "physical-page");
  return mapping;
}

static uint64_t read_xcr0(void) {
  uint32_t low;
  uint32_t high;
  __asm__ volatile("xgetbv" : "=a"(low), "=d"(high) : "c"(0));
  return ((uint64_t)high << 32) | low;
}

static void read_cpuid(struct cpuid_record *record, uint32_t function,
                       uint32_t index) {
  record->function = function;
  record->index = index;
  __cpuid_count(function, index, record->eax, record->ebx, record->ecx,
                record->edx);
}

static void sample_clock(struct clock_record *record, clockid_t id) {
  struct timespec value;
  if (clock_gettime(id, &value) != 0) fail_probe("clock", "clock-gettime");
  if (value.tv_nsec < 0 || value.tv_nsec >= 1000000000L) {
    errno = EINVAL;
    fail_probe("clock", "invalid-nanoseconds");
  }
  record->seconds = value.tv_sec;
  record->nanoseconds = (uint32_t)value.tv_nsec;
  record->reserved = 0;
}

static void sample_clocks(struct clock_record records[3]) {
  sample_clock(&records[0], CLOCK_MONOTONIC);
  sample_clock(&records[1], CLOCK_BOOTTIME);
  sample_clock(&records[2], CLOCK_REALTIME);
}

static uint64_t mailbox_checksum(struct profile_mailbox *mailbox) {
  const uint64_t basis = UINT64_C(14695981039346656037);
  const uint64_t prime = UINT64_C(1099511628211);
  mailbox->checksum = 0;
  uint64_t hash = basis;
  const uint8_t *bytes = (const uint8_t *)mailbox;
  for (size_t index = 0; index < sizeof(*mailbox); index++) {
    hash ^= bytes[index];
    hash *= prime;
  }
  return hash;
}

static void validate_restored(const struct profile_mailbox *mailbox) {
  if (mailbox->restored_tsc < mailbox->capture_tsc) {
    errno = EINVAL;
    fail_probe("restore", "tsc-moved-backwards");
  }
  if (memcmp(mailbox->expected_x87, mailbox->observed_x87,
             sizeof(mailbox->expected_x87)) != 0) {
    errno = EINVAL;
    fail_probe("restore", "x87-mismatch");
  }
  if (memcmp(mailbox->expected_xmm, mailbox->observed_xmm,
             sizeof(mailbox->expected_xmm)) != 0) {
    errno = EINVAL;
    fail_probe("restore", "xmm-mismatch");
  }
  if (memcmp(mailbox->expected_ymm, mailbox->observed_ymm,
             sizeof(mailbox->expected_ymm)) != 0) {
    errno = EINVAL;
    fail_probe("restore", "ymm-mismatch");
  }
}

int main(void) {
  mount_filesystem("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC);
  mount_filesystem("devtmpfs", "/dev", "devtmpfs", MS_NOSUID | MS_NOEXEC);

  int memory_fd = open("/dev/mem", O_RDWR | O_CLOEXEC | O_SYNC);
  if (memory_fd < 0) fail_probe("open", "devmem");
  struct profile_mailbox *mailbox = map_physical(memory_fd, MAILBOX_GPA);
  volatile uint8_t *generation = map_physical(memory_fd, GENERATION_GPA);
  close(memory_fd);

  memset(mailbox, 0, sizeof(*mailbox));
  mailbox->magic = MAILBOX_MAGIC;
  mailbox->version = MAILBOX_VERSION;
  mailbox->header_bytes = MAILBOX_HEADER_BYTES;
  mailbox->total_bytes = MAILBOX_TOTAL_BYTES;
  mailbox->flags = MAILBOX_FLAG_AVX;
  mailbox->cpuid_count = CPUID_RECORD_COUNT;
  mailbox->nonce = parse_nonce();

  read_cpuid(&mailbox->cpuid[0], 0, 0);
  read_cpuid(&mailbox->cpuid[1], 1, 0);
  read_cpuid(&mailbox->cpuid[2], 7, 0);
  read_cpuid(&mailbox->cpuid[3], 0x0d, 0);
  read_cpuid(&mailbox->cpuid[4], 0x0d, 1);
  if ((mailbox->cpuid[1].ecx & (UINT32_C(1) << 27)) == 0 ||
      (mailbox->cpuid[1].ecx & (UINT32_C(1) << 28)) == 0) {
    errno = ENOTSUP;
    fail_probe("cpuid", "osxsave-or-avx-missing");
  }
  mailbox->xcr0 = read_xcr0();
  if ((mailbox->xcr0 & UINT64_C(0x6)) != UINT64_C(0x6)) {
    errno = ENOTSUP;
    fail_probe("xcr0", "sse-or-avx-disabled");
  }

  memcpy(mailbox->expected_x87, expected_x87, sizeof(expected_x87));
  memcpy(mailbox->expected_xmm, expected_xmm, sizeof(expected_xmm));
  memcpy(mailbox->expected_ymm, expected_ymm, sizeof(expected_ymm));
  sample_clocks(mailbox->capture_clocks);

  printf(PROBE_PREFIX " status=capture-ready nonce=%016" PRIx64
         " mailbox=0x%" PRIx64 "\n",
         mailbox->nonce, MAILBOX_GPA);
  fflush(stdout);
  profile_state_sequence(
      (volatile uint32_t *)(generation + CAPTURE_DOORBELL_OFFSET), mailbox);

  validate_restored(mailbox);
  sample_clocks(mailbox->restored_clocks);
  mailbox->phase = MAILBOX_PHASE_RESTORED_READY;
  mailbox->checksum = mailbox_checksum(mailbox);
  printf(PROBE_PREFIX " status=restored nonce=%016" PRIx64
         " capture_tsc=%" PRIu64 " restored_tsc=%" PRIu64 "\n",
         mailbox->nonce, mailbox->capture_tsc, mailbox->restored_tsc);
  fflush(stdout);
  *(volatile uint32_t *)(generation + RESTORED_DOORBELL_OFFSET) =
      RESTORED_COMMAND;
  stop_forever();
}
