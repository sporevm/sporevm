#include "mailbox_abi.h"

/*
 * State-critical Stage 0b.2 sequence. The direct MMIO store exits from CPL3;
 * no syscall or compiler-generated code can save or replace this task's FPU
 * state before KVM captures it. On restore, observations are the first
 * instructions executed after completion of the capture doorbell.
 */

        .text
        .globl profile_state_sequence
        .type profile_state_sequence,@function
profile_state_sequence:
        /* rdi = capture doorbell, rsi = fixed mailbox mapping. */
        lfence
        rdtsc
        shlq    $32, %rdx
        orq     %rdx, %rax
        movq    %rax, MAILBOX_CAPTURE_TSC_OFFSET(%rsi)
        movl    $MAILBOX_PHASE_CAPTURE_READY, MAILBOX_PHASE_OFFSET(%rsi)
        movq    $0, MAILBOX_CHECKSUM_OFFSET(%rsi)

        /* FNV-1a over the complete 512-byte mailbox with checksum zeroed. */
        movabsq $14695981039346656037, %r8
        movabsq $1099511628211, %r9
        xorl    %ecx, %ecx
.Lchecksum_capture:
        movzbl  (%rsi,%rcx), %eax
        xorq    %rax, %r8
        imulq   %r9, %r8
        incq    %rcx
        cmpq    $MAILBOX_TOTAL_BYTES, %rcx
        jne     .Lchecksum_capture
        movq    %r8, MAILBOX_CHECKSUM_OFFSET(%rsi)

        fldt    .Lexpected_x87(%rip)
        movdqu  .Lexpected_xmm(%rip), %xmm0
        vmovdqu .Lexpected_ymm(%rip), %ymm1
        movl    $CAPTURE_COMMAND, (%rdi)

        /* The restore process resumes here after completing the MMIO exit. */
        fstpt   MAILBOX_OBSERVED_X87_OFFSET(%rsi)
        movdqu  %xmm0, MAILBOX_OBSERVED_XMM_OFFSET(%rsi)
        vmovdqu %ymm1, MAILBOX_OBSERVED_YMM_OFFSET(%rsi)
        vzeroupper
        lfence
        rdtsc
        shlq    $32, %rdx
        orq     %rdx, %rax
        movq    %rax, MAILBOX_RESTORED_TSC_OFFSET(%rsi)
        ret
        .size profile_state_sequence, .-profile_state_sequence

        .section .rodata
        .align 16
.Lexpected_x87:
        .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x80,0xff,0x3f
        .align 16
.Lexpected_xmm:
        .byte 0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07
        .byte 0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f
        .align 32
.Lexpected_ymm:
        .byte 0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27
        .byte 0x28,0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f
        .byte 0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37
        .byte 0x38,0x39,0x3a,0x3b,0x3c,0x3d,0x3e,0x3f

        .section .note.GNU-stack,"",@progbits
