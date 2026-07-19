#ifndef SPOREVM_X86_PROFILE_MAILBOX_ABI_H
#define SPOREVM_X86_PROFILE_MAILBOX_ABI_H

#define MAILBOX_MAGIC 0x31505258
#define MAILBOX_VERSION 1
#define MAILBOX_HEADER_BYTES 64
#define MAILBOX_TOTAL_BYTES 512
#define MAILBOX_PHASE_OFFSET 12
#define MAILBOX_CAPTURE_TSC_OFFSET 40
#define MAILBOX_RESTORED_TSC_OFFSET 48
#define MAILBOX_CHECKSUM_OFFSET 56
#define MAILBOX_OBSERVED_X87_OFFSET 296
#define MAILBOX_OBSERVED_XMM_OFFSET 328
#define MAILBOX_OBSERVED_YMM_OFFSET 376
#define MAILBOX_PHASE_CAPTURE_READY 1
#define MAILBOX_PHASE_RESTORED_READY 2
#define MAILBOX_FLAG_AVX 1
#define CPUID_RECORD_COUNT 5
#define CAPTURE_COMMAND 0x54504143

#ifndef __ASSEMBLER__
#include <stddef.h>
#include <stdint.h>

struct clock_record { int64_t seconds; uint32_t nanoseconds; uint32_t reserved; } __attribute__((packed));
struct cpuid_record { uint32_t function, index, eax, ebx, ecx, edx; } __attribute__((packed));
struct profile_mailbox {
  uint32_t magic; uint16_t version, header_bytes; uint32_t total_bytes, phase, flags, cpuid_count;
  uint64_t nonce, xcr0, capture_tsc, restored_tsc, checksum;
  struct clock_record capture_clocks[3], restored_clocks[3];
  struct cpuid_record cpuid[CPUID_RECORD_COUNT];
  uint8_t expected_x87[16], observed_x87[16], expected_xmm[16], observed_xmm[16];
  uint8_t expected_ymm[32], observed_ymm[32], reserved[104];
} __attribute__((packed));

_Static_assert(sizeof(struct clock_record) == 16, "clock record ABI");
_Static_assert(sizeof(struct cpuid_record) == 24, "CPUID record ABI");
_Static_assert(sizeof(struct profile_mailbox) == MAILBOX_TOTAL_BYTES, "mailbox ABI");
_Static_assert(offsetof(struct profile_mailbox, phase) == MAILBOX_PHASE_OFFSET, "phase offset");
_Static_assert(offsetof(struct profile_mailbox, capture_tsc) == MAILBOX_CAPTURE_TSC_OFFSET, "capture TSC offset");
_Static_assert(offsetof(struct profile_mailbox, restored_tsc) == MAILBOX_RESTORED_TSC_OFFSET, "restored TSC offset");
_Static_assert(offsetof(struct profile_mailbox, checksum) == MAILBOX_CHECKSUM_OFFSET, "checksum offset");
_Static_assert(offsetof(struct profile_mailbox, observed_x87) == MAILBOX_OBSERVED_X87_OFFSET, "x87 offset");
_Static_assert(offsetof(struct profile_mailbox, observed_xmm) == MAILBOX_OBSERVED_XMM_OFFSET, "XMM offset");
_Static_assert(offsetof(struct profile_mailbox, observed_ymm) == MAILBOX_OBSERVED_YMM_OFFSET, "YMM offset");
#endif

#endif
