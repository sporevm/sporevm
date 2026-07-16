#define _GNU_SOURCE
#include "build_run_sandbox.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/bpf.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <linux/audit.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SYS_bpf
#if defined(__aarch64__)
#define SYS_bpf 280
#elif defined(__x86_64__)
#define SYS_bpf 321
#endif
#endif

#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT 47
#define PR_CAP_AMBIENT_CLEAR_ALL 4
#endif

#define SPORE_BUILD_CAP_MASK 0xa80425fbULL

#if defined(__aarch64__)
#define SPORE_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__x86_64__)
#define SPORE_AUDIT_ARCH AUDIT_ARCH_X86_64
#else
#error unsupported RUN sandbox architecture
#endif
#define BPF_INSN(CODE, DST, SRC, OFF, IMM) \
  ((struct bpf_insn){ .code = (CODE), .dst_reg = (DST), .src_reg = (SRC), .off = (OFF), .imm = (IMM) })
#define BPF_LDX_MEM(SIZE, DST, SRC, OFF) BPF_INSN(BPF_LDX | BPF_MEM | (SIZE), (DST), (SRC), (OFF), 0)
#define BPF_ALU64_IMM(OP, DST, IMM) BPF_INSN(BPF_ALU64 | (OP) | BPF_K, (DST), 0, 0, (IMM))
#define BPF_JMP_IMM(OP, DST, IMM, OFF) BPF_INSN(BPF_JMP | (OP) | BPF_K, (DST), 0, (OFF), (IMM))
#define BPF_JMP_A(OFF) BPF_INSN(BPF_JMP | BPF_JA, 0, 0, (OFF), 0)
#define BPF_EXIT_INSN() BPF_INSN(BPF_JMP | BPF_EXIT, 0, 0, 0, 0)
#define FORWARD_OFFSET(FROM, TO) ((TO) - (FROM) - 1)

enum device_filter_instruction {
  DEVICE_LOAD_MKNOD_ACCESS,
  DEVICE_MASK_MKNOD_ACCESS,
  DEVICE_ALLOW_MKNOD,
  DEVICE_LOAD_DEVICE_TYPE,
  DEVICE_MASK_DEVICE_TYPE,
  DEVICE_REQUIRE_CHARACTER,
  DEVICE_LOAD_MAJOR,
  DEVICE_ALLOW_PTY,
  DEVICE_CHECK_MEMORY_MAJOR,
  DEVICE_CHECK_TTY_MAJOR,
  DEVICE_DENY_OTHER_MAJOR,
  DEVICE_LOAD_MEMORY_MINOR,
  DEVICE_ALLOW_NULL,
  DEVICE_ALLOW_ZERO,
  DEVICE_ALLOW_FULL,
  DEVICE_ALLOW_RANDOM,
  DEVICE_ALLOW_URANDOM,
  DEVICE_DENY_OTHER_MEMORY_MINOR,
  DEVICE_LOAD_TTY_MINOR,
  DEVICE_ALLOW_TTY,
  DEVICE_ALLOW_PTMX,
  DEVICE_DENY_OTHER_TTY_MINOR,
  DEVICE_DENY_RESULT,
  DEVICE_DENY_EXIT,
  DEVICE_ALLOW_RESULT,
  DEVICE_ALLOW_EXIT,
  DEVICE_FILTER_INSTRUCTION_COUNT,
};

static int set_error(char *error, size_t cap, const char *step) {
  int saved = errno;
  if (cap != 0) snprintf(error, cap, "RUN sandbox setup failed: %s errno=%d", step, saved);
  errno = saved;
  return -1;
}

static int bpf_syscall(enum bpf_cmd command, union bpf_attr *attr) {
  return (int)syscall(SYS_bpf, command, attr, sizeof(*attr));
}

int spore_build_run_sandbox_attach_device_policy(
    const char *cgroup_path, char *error, size_t error_cap) {
  /* Allow mknod, the standard character devices, and devpts; deny other opens. */
  const struct bpf_insn program[] = {
    BPF_LDX_MEM(BPF_W, BPF_REG_0, BPF_REG_1, offsetof(struct bpf_cgroup_dev_ctx, access_type)),
    BPF_ALU64_IMM(BPF_AND, BPF_REG_0, BPF_DEVCG_ACC_MKNOD << 16),
    BPF_JMP_IMM(BPF_JNE, BPF_REG_0, 0,
                FORWARD_OFFSET(DEVICE_ALLOW_MKNOD, DEVICE_ALLOW_RESULT)),
    BPF_LDX_MEM(BPF_W, BPF_REG_0, BPF_REG_1, offsetof(struct bpf_cgroup_dev_ctx, access_type)),
    BPF_ALU64_IMM(BPF_AND, BPF_REG_0, 0xffffU),
    BPF_JMP_IMM(BPF_JNE, BPF_REG_0, BPF_DEVCG_DEV_CHAR,
                FORWARD_OFFSET(DEVICE_REQUIRE_CHARACTER, DEVICE_DENY_RESULT)),
    BPF_LDX_MEM(BPF_W, BPF_REG_0, BPF_REG_1, offsetof(struct bpf_cgroup_dev_ctx, major)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 136,
                FORWARD_OFFSET(DEVICE_ALLOW_PTY, DEVICE_ALLOW_RESULT)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 1,
                FORWARD_OFFSET(DEVICE_CHECK_MEMORY_MAJOR, DEVICE_LOAD_MEMORY_MINOR)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 5,
                FORWARD_OFFSET(DEVICE_CHECK_TTY_MAJOR, DEVICE_LOAD_TTY_MINOR)),
    BPF_JMP_A(FORWARD_OFFSET(DEVICE_DENY_OTHER_MAJOR, DEVICE_DENY_RESULT)),
    BPF_LDX_MEM(BPF_W, BPF_REG_0, BPF_REG_1, offsetof(struct bpf_cgroup_dev_ctx, minor)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 3,
                FORWARD_OFFSET(DEVICE_ALLOW_NULL, DEVICE_ALLOW_RESULT)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 5,
                FORWARD_OFFSET(DEVICE_ALLOW_ZERO, DEVICE_ALLOW_RESULT)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 7,
                FORWARD_OFFSET(DEVICE_ALLOW_FULL, DEVICE_ALLOW_RESULT)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 8,
                FORWARD_OFFSET(DEVICE_ALLOW_RANDOM, DEVICE_ALLOW_RESULT)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 9,
                FORWARD_OFFSET(DEVICE_ALLOW_URANDOM, DEVICE_ALLOW_RESULT)),
    BPF_JMP_A(FORWARD_OFFSET(DEVICE_DENY_OTHER_MEMORY_MINOR, DEVICE_DENY_RESULT)),
    BPF_LDX_MEM(BPF_W, BPF_REG_0, BPF_REG_1, offsetof(struct bpf_cgroup_dev_ctx, minor)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 0,
                FORWARD_OFFSET(DEVICE_ALLOW_TTY, DEVICE_ALLOW_RESULT)),
    BPF_JMP_IMM(BPF_JEQ, BPF_REG_0, 2,
                FORWARD_OFFSET(DEVICE_ALLOW_PTMX, DEVICE_ALLOW_RESULT)),
    BPF_JMP_A(FORWARD_OFFSET(DEVICE_DENY_OTHER_TTY_MINOR, DEVICE_DENY_RESULT)),
    BPF_ALU64_IMM(BPF_MOV, BPF_REG_0, 0),
    BPF_EXIT_INSN(),
    BPF_ALU64_IMM(BPF_MOV, BPF_REG_0, 1),
    BPF_EXIT_INSN(),
  };
  _Static_assert(sizeof(program) / sizeof(program[0]) == DEVICE_FILTER_INSTRUCTION_COUNT,
                 "device filter labels must describe every instruction");
  static char verifier_log[4096];
  static const char license[] = "GPL";
  memset(verifier_log, 0, sizeof(verifier_log));
  union bpf_attr load;
  memset(&load, 0, sizeof(load));
  load.prog_type = BPF_PROG_TYPE_CGROUP_DEVICE;
  load.insn_cnt = (uint32_t)(sizeof(program) / sizeof(program[0]));
  load.insns = (uint64_t)(uintptr_t)program;
  load.license = (uint64_t)(uintptr_t)license;
  load.log_buf = (uint64_t)(uintptr_t)verifier_log;
  load.log_size = sizeof(verifier_log);
  load.log_level = 1;
  int program_fd = bpf_syscall(BPF_PROG_LOAD, &load);
  if (program_fd < 0) {
    if (verifier_log[0] != '\0') dprintf(STDERR_FILENO, "RUN sandbox device verifier: %.4000s\n", verifier_log);
    return set_error(error, error_cap, "load device policy");
  }

  int cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (cgroup_fd < 0) {
    close(program_fd);
    return set_error(error, error_cap, "open operation cgroup");
  }
  union bpf_attr attach;
  memset(&attach, 0, sizeof(attach));
  attach.target_fd = (uint32_t)cgroup_fd;
  attach.attach_bpf_fd = (uint32_t)program_fd;
  attach.attach_type = BPF_CGROUP_DEVICE;
  int rc = bpf_syscall(BPF_PROG_ATTACH, &attach);
  int saved = errno;
  close(cgroup_fd);
  close(program_fd);
  errno = saved;
  if (rc != 0) return set_error(error, error_cap, "attach device policy");
  return 0;
}

static int ensure_dir(const char *path, mode_t mode, char *error, size_t cap) {
  if (mkdir(path, mode) != 0 && errno != EEXIST) return set_error(error, cap, path);
  struct stat state;
  if (lstat(path, &state) != 0) return set_error(error, cap, path);
  if (!S_ISDIR(state.st_mode)) {
    errno = ENOTDIR;
    return set_error(error, cap, path);
  }
  return 0;
}

static int detach_if_mounted(const char *path, char *error, size_t cap) {
  if (umount2(path, MNT_DETACH) == 0 || errno == EINVAL || errno == ENOENT) return 0;
  return set_error(error, cap, path);
}

static int mount_at(const char *source, const char *target, const char *type,
                    unsigned long flags, const char *data, char *error, size_t cap) {
  if (mount(source, target, type, flags, data) == 0) return 0;
  return set_error(error, cap, target);
}

static int readonly_bind_if_present(const char *path, char *error, size_t cap) {
  struct stat state;
  if (stat(path, &state) != 0) {
    if (errno == ENOENT) return 0;
    return set_error(error, cap, path);
  }
  if (mount(path, path, NULL, MS_BIND | MS_REC, NULL) != 0 ||
      mount(NULL, path, NULL,
            MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV,
            NULL) != 0) return set_error(error, cap, path);
  return 0;
}

static int mask_path_if_present(const char *path, char *error, size_t cap) {
  struct stat state;
  if (stat(path, &state) != 0) {
    if (errno == ENOENT) return 0;
    return set_error(error, cap, path);
  }
  if (S_ISDIR(state.st_mode)) {
    if (mount_at("tmpfs", path, "tmpfs",
                 MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV,
                 "mode=000,size=4096", error, cap) != 0) return -1;
    return 0;
  }
  if (mount("/dev/null", path, NULL, MS_BIND, NULL) != 0 ||
      mount(NULL, path, NULL,
            MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV,
            NULL) != 0) return set_error(error, cap, path);
  return 0;
}

static int make_device(const char *path, mode_t mode, unsigned int major_num,
                       unsigned int minor_num, char *error, size_t cap) {
  if (mknod(path, S_IFCHR | mode, makedev(major_num, minor_num)) == 0) return 0;
  return set_error(error, cap, path);
}

static int replace_link(const char *target, const char *path, char *error, size_t cap) {
  if (unlink(path) != 0 && errno != ENOENT) return set_error(error, cap, path);
  if (symlink(target, path) != 0) return set_error(error, cap, path);
  return 0;
}

static int setup_operation_mounts(const char *rootfs, char *error, size_t cap) {
  char path[256];
#define ROOT_PATH(SUFFIX) do { \
  int n = snprintf(path, sizeof(path), "%s%s", rootfs, (SUFFIX)); \
  if (n <= 0 || (size_t)n >= sizeof(path)) { errno = ENAMETOOLONG; return set_error(error, cap, (SUFFIX)); } \
} while (0)

  if (mount(rootfs, rootfs, NULL, MS_BIND | MS_REC, NULL) != 0) {
    return set_error(error, cap, "bind operation rootfs");
  }

  const char *detach_paths[] = {
    "/dev/pts", "/dev/mqueue", "/dev/shm", "/dev",
    "/proc", "/sys/fs/cgroup", "/sys",
  };
  for (size_t i = 0; i < sizeof(detach_paths) / sizeof(detach_paths[0]); i++) {
    ROOT_PATH(detach_paths[i]);
    if (detach_if_mounted(path, error, cap) != 0) return -1;
  }

  ROOT_PATH("/proc");
  if (ensure_dir(path, 0555, error, cap) != 0 ||
      mount_at("proc", path, "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, "", error, cap) != 0) return -1;
  const char *readonly_proc_paths[] = {
    "/proc/asound", "/proc/bus", "/proc/fs", "/proc/irq",
    "/proc/sys", "/proc/sysrq-trigger",
  };
  for (size_t i = 0; i < sizeof(readonly_proc_paths) / sizeof(readonly_proc_paths[0]); i++) {
    ROOT_PATH(readonly_proc_paths[i]);
    if (readonly_bind_if_present(path, error, cap) != 0) return -1;
  }
  const char *masked_proc_paths[] = {
    "/proc/acpi", "/proc/kcore", "/proc/keys", "/proc/latency_stats",
    "/proc/sched_debug", "/proc/scsi", "/proc/timer_list", "/proc/timer_stats",
  };
  for (size_t i = 0; i < sizeof(masked_proc_paths) / sizeof(masked_proc_paths[0]); i++) {
    ROOT_PATH(masked_proc_paths[i]);
    if (mask_path_if_present(path, error, cap) != 0) return -1;
  }

  ROOT_PATH("/dev");
  if (ensure_dir(path, 0755, error, cap) != 0 ||
      mount_at("tmpfs", path, "tmpfs", MS_NOSUID | MS_STRICTATIME, "mode=0755,size=65536k", error, cap) != 0) return -1;
  const struct {
    const char *name;
    mode_t mode;
    unsigned int major_num;
    unsigned int minor_num;
  } devices[] = {
    { "null", 0666, 1, 3 }, { "zero", 0666, 1, 5 },
    { "full", 0666, 1, 7 }, { "random", 0666, 1, 8 },
    { "urandom", 0666, 1, 9 }, { "tty", 0666, 5, 0 },
  };
  for (size_t i = 0; i < sizeof(devices) / sizeof(devices[0]); i++) {
    ROOT_PATH("/dev/");
    size_t base = strlen(path);
    if (base + strlen(devices[i].name) + 1 > sizeof(path)) { errno = ENAMETOOLONG; return set_error(error, cap, "device path"); }
    strcpy(path + base, devices[i].name);
    if (make_device(path, devices[i].mode, devices[i].major_num, devices[i].minor_num, error, cap) != 0) return -1;
  }

  ROOT_PATH("/dev/pts");
  if (ensure_dir(path, 0755, error, cap) != 0 ||
      mount_at("devpts", path, "devpts", MS_NOSUID | MS_NOEXEC,
               "newinstance,ptmxmode=0666,mode=0620,gid=5", error, cap) != 0) return -1;
  ROOT_PATH("/dev/ptmx");
  if (replace_link("pts/ptmx", path, error, cap) != 0) return -1;
  ROOT_PATH("/dev/fd");
  if (replace_link("/proc/self/fd", path, error, cap) != 0) return -1;
  ROOT_PATH("/dev/stdin");
  if (replace_link("/proc/self/fd/0", path, error, cap) != 0) return -1;
  ROOT_PATH("/dev/stdout");
  if (replace_link("/proc/self/fd/1", path, error, cap) != 0) return -1;
  ROOT_PATH("/dev/stderr");
  if (replace_link("/proc/self/fd/2", path, error, cap) != 0) return -1;

  ROOT_PATH("/dev/shm");
  if (ensure_dir(path, 01777, error, cap) != 0 ||
      mount_at("shm", path, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC,
               "mode=1777,size=65536k", error, cap) != 0) return -1;
  ROOT_PATH("/dev/mqueue");
  if (ensure_dir(path, 01777, error, cap) != 0 ||
      mount_at("mqueue", path, "mqueue", MS_NOSUID | MS_NODEV | MS_NOEXEC,
               "", error, cap) != 0) return -1;

  ROOT_PATH("/sys");
  if (ensure_dir(path, 0555, error, cap) != 0 ||
      mount_at("sysfs", path, "sysfs", MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV,
               "", error, cap) != 0) return -1;
  const char *masked_sys_paths[] = {
    "/sys/firmware", "/sys/devices/virtual/powercap",
  };
  for (size_t i = 0; i < sizeof(masked_sys_paths) / sizeof(masked_sys_paths[0]); i++) {
    ROOT_PATH(masked_sys_paths[i]);
    if (mask_path_if_present(path, error, cap) != 0) return -1;
  }
  ROOT_PATH("/sys/fs");
  if (ensure_dir(path, 0555, error, cap) != 0) return -1;
  ROOT_PATH("/sys/fs/cgroup");
  if (ensure_dir(path, 0555, error, cap) != 0 ||
      mount_at("cgroup2", path, "cgroup2", MS_RDONLY | MS_NOSUID | MS_NOEXEC | MS_NODEV,
               "", error, cap) != 0) return -1;

#undef ROOT_PATH
  return 0;
}

static int drop_capabilities(char *error, size_t cap) {
  for (int capability = 0; capability <= CAP_LAST_CAP; capability++) {
    if ((SPORE_BUILD_CAP_MASK & (1ULL << capability)) != 0) continue;
    if (prctl(PR_CAPBSET_DROP, capability, 0, 0, 0) != 0) return set_error(error, cap, "drop capability bound");
  }
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0 && errno != EINVAL) {
    return set_error(error, cap, "clear ambient capabilities");
  }
  struct __user_cap_header_struct header;
  struct __user_cap_data_struct data[2];
  memset(&header, 0, sizeof(header));
  memset(data, 0, sizeof(data));
  header.version = _LINUX_CAPABILITY_VERSION_3;
  header.pid = 0;
  data[0].effective = (uint32_t)SPORE_BUILD_CAP_MASK;
  data[0].permitted = (uint32_t)SPORE_BUILD_CAP_MASK;
  if (syscall(SYS_capset, &header, data) != 0) return set_error(error, cap, "set capabilities");
  return 0;
}

enum syscall_filter_instruction {
  SYSCALL_LOAD_ARCH,
  SYSCALL_REQUIRE_ARCH,
  SYSCALL_KILL_WRONG_ARCH,
  SYSCALL_LOAD_NUMBER,
  SYSCALL_DENY_IO_URING,
  SYSCALL_CHECK_SOCKET,
  SYSCALL_CHECK_SOCKETPAIR,
  SYSCALL_ALLOW_OTHER_CALL,
  SYSCALL_LOAD_SOCKET_FAMILY,
  SYSCALL_DENY_VSOCK,
  SYSCALL_ALLOW_OTHER_FAMILY,
  SYSCALL_DENY_RESULT,
  SYSCALL_ALLOW_RESULT,
  SYSCALL_FILTER_INSTRUCTION_COUNT,
};

static int install_syscall_policy(char *error, size_t cap) {
  const struct sock_filter filter[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SPORE_AUDIT_ARCH,
             FORWARD_OFFSET(SYSCALL_REQUIRE_ARCH, SYSCALL_LOAD_NUMBER), 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_io_uring_setup,
             FORWARD_OFFSET(SYSCALL_DENY_IO_URING, SYSCALL_DENY_RESULT), 0),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket,
             FORWARD_OFFSET(SYSCALL_CHECK_SOCKET, SYSCALL_LOAD_SOCKET_FAMILY), 0),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socketpair,
             FORWARD_OFFSET(SYSCALL_CHECK_SOCKETPAIR, SYSCALL_LOAD_SOCKET_FAMILY), 0),
    BPF_STMT(BPF_JMP | BPF_JA,
             FORWARD_OFFSET(SYSCALL_ALLOW_OTHER_CALL, SYSCALL_ALLOW_RESULT)),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_VSOCK,
             FORWARD_OFFSET(SYSCALL_DENY_VSOCK, SYSCALL_DENY_RESULT), 0),
    BPF_STMT(BPF_JMP | BPF_JA,
             FORWARD_OFFSET(SYSCALL_ALLOW_OTHER_FAMILY, SYSCALL_ALLOW_RESULT)),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  _Static_assert(sizeof(filter) / sizeof(filter[0]) == SYSCALL_FILTER_INSTRUCTION_COUNT,
                 "syscall filter labels must describe every instruction");
  const struct sock_fprog program = {
    .len = (unsigned short)(sizeof(filter) / sizeof(filter[0])),
    .filter = (struct sock_filter *)filter,
  };
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0) {
    return set_error(error, cap, "install syscall policy");
  }
  return 0;
}

static void supervisor_exit_with_status(int status) {
  if (WIFEXITED(status)) _exit(WEXITSTATUS(status));
  if (WIFSIGNALED(status)) {
    int signal_number = WTERMSIG(status);
    signal(signal_number, SIG_DFL);
    (void)kill(getpid(), signal_number);
    _exit(128 + signal_number);
  }
  _exit(125);
}

int spore_build_run_sandbox_enter(
    const char *rootfs, int ready_fd, char *error, size_t error_cap) {
  int namespace_flags = CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWCGROUP |
                        CLONE_NEWIPC | CLONE_NEWUTS;
  if (unshare(namespace_flags) != 0) return set_error(error, error_cap, "create namespaces");
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
    return set_error(error, error_cap, "make mount propagation private");
  }

  pid_t command_pid = fork();
  if (command_pid < 0) return set_error(error, error_cap, "create namespace PID 1");
  if (command_pid > 0) {
    close(ready_fd);
    int status = 0;
    while (waitpid(command_pid, &status, 0) < 0) {
      if (errno == EINTR) continue;
      _exit(125);
    }
    supervisor_exit_with_status(status);
  }

  if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() == 1) {
    return set_error(error, error_cap, "bind command to supervisor lifetime");
  }
  if (setup_operation_mounts(rootfs, error, error_cap) != 0) return -1;

  /*
   * The initramfs rootfs cannot be a pivot_root old root. A private mount
   * namespace plus a descriptor-clean chroot is the equivalent confinement:
   * scoped procfs contains no ancestor task, and exec closes every initrd fd.
   */
  if (chdir(rootfs) != 0 || chroot(".") != 0 || chdir("/") != 0) {
    return set_error(error, error_cap, "enter operation rootfs");
  }
  if (install_syscall_policy(error, error_cap) != 0) return -1;
  if (drop_capabilities(error, error_cap) != 0) return -1;
  return 0;
}
