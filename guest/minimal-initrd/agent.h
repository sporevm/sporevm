// Shared declarations for the guest agent. agent.c holds the event loop;
// the other files each own one concern.
#ifndef SPORE_AGENT_H
#define SPORE_AGENT_H

#define _GNU_SOURCE
#include "build_copy.h"
#include "build_run_sandbox.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <linux/fs.h>
#include <linux/openat2.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>
#include <sys/vfs.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_ARGC 16
#define MAX_ENVC 64
#define MAX_ENV_LEN 256
#define MAX_WORKDIR_LEN 256
#define MAX_REQUEST 8192
#define MAX_ARG_STORAGE MAX_REQUEST
#define MAX_FRAME_PAYLOAD 4096
#define MAX_COPY_PATH_LEN 512
#define MAX_COPY_FULL_PATH_LEN 1024
#define MAX_DETACHED_CHILDREN 32
#define INITIAL_OUTPUT_HEADER_LEN 3
#define INITIAL_OUTPUT_CAP (16 * 1024 - INITIAL_OUTPUT_HEADER_LEN)
// Each output stream keeps its last REPLAY_CAP bytes for an attach to resume
// from. A `spore run` save records how much output its host had received,
// which trails what the agent had read by at most the read the agent was still
// sending (SPIO_BATCH_FRAMES * MAX_FRAME_PAYLOAD, 60 KiB) plus the 64 KiB of
// vsock credit the host grants (host_stream_credit in src/virtio/vsock.zig):
// 124 KiB. The rest holds what the agent reads after a restore, before the
// attach arrives.
#define REPLAY_CAP (256 * 1024)
// The generation device's params region, generation.zig params_size, plus
// the NUL.
#define GEN_PARAMS_MAX 3841
#define SPIO_MAGIC "SPIO"
#define SPIO_VERSION 1
#define SPIO_HEADER_LEN 24
// Frames the agent packs into one vsock write; see spio.c.
#define SPIO_BATCH_FRAMES 15
#define SPIO_DATA 1
#define SPIO_CLOSE 2
#define SPIO_STDIN_STREAM 1
#define SPIO_STDOUT_STREAM 2
#define SPIO_STDERR_STREAM 3
#define SPIO_TERMINAL_STREAM 4
#define COPY_KIND_FILE SPORE_BUILD_COPY_KIND_FILE
#define COPY_KIND_DIR SPORE_BUILD_COPY_KIND_DIR
#define COPY_SOURCE_CONTEXT SPORE_BUILD_COPY_SOURCE_CONTEXT
#define MAX_BUILD_RUN_COMMAND_LEN 65536ULL
#define MAX_BUILD_EXEC_ARGS_BYTES 4096
#define BUILD_CONTEXT_ROOT "/mnt/build-context"
#define BUILD_INPUT_ROOT "/mnt/build-inputs"
#define MAX_BUILD_INPUT_DISKS 2
#define MAX_BUILD_CACHE_MOUNTS 8
#define MAX_BUILD_CONTEXT_BINDS 8
#define MAX_BUILD_CACHE_KEY_LEN 64
#define MAX_BUILD_RESOLV_COMPONENTS 64
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

// A ring: the byte at stream offset o is at data[o % REPLAY_CAP].
struct replay_buffer {
  unsigned char data[REPLAY_CAP];
  uint64_t base_offset;
  size_t len;
};

struct session {
  int started;
  int exited;
  int memory_pressure_fd;
  int build_run_isolation;
  int cancel_on_disconnect;
  char cgroup_path[128];
  char session_id[64];
  pid_t pid;
  int stdout_fd;
  int stderr_fd;
  int stdin_fd;
  int terminal_fd;
  int stdout_open;
  int stderr_open;
  int stdin_open;
  int stdin_capable;
  int stdin_close_pending;
  int tty;
  int terminal_close_pending;
  int exit_code;
  char setup_error[256];
  uint64_t stdout_offset;
  uint64_t stderr_offset;
  uint64_t stdin_offset;
  uint64_t terminal_offset;
  uint64_t terminal_input_offset;
  unsigned char stdin_pending[MAX_FRAME_PAYLOAD];
  size_t stdin_pending_len;
  size_t stdin_pending_off;
  unsigned char terminal_pending[MAX_FRAME_PAYLOAD];
  size_t terminal_pending_len;
  size_t terminal_pending_off;
  struct replay_buffer stdout_replay;
  struct replay_buffer stderr_replay;
};

struct client {
  int fd;
  uint64_t stdout_offset;
  uint64_t stderr_offset;
  uint64_t stdin_offset;
  uint64_t terminal_offset;
  uint64_t terminal_input_offset;
  int stdin_input_owner;
  int terminal_input_owner;
  unsigned char v1_header[SPIO_HEADER_LEN];
  size_t v1_header_len;
  uint8_t v1_type;
  uint32_t v1_stream_id;
  uint64_t v1_offset;
  uint32_t v1_payload_len;
  unsigned char v1_payload[MAX_FRAME_PAYLOAD];
  size_t v1_payload_read;
};

struct detached_children {
  pid_t pids[MAX_DETACHED_CHILDREN];
  int count;
  pid_t retained_pid;
  int retained_stdout_fd;
  int retained_stderr_fd;
  int retained_exited;
  int retained_exit_code;
  int retained_stdout_truncated;
  int retained_stderr_truncated;
  size_t retained_stdout_len;
  size_t retained_stderr_len;
  unsigned char retained_stdout[INITIAL_OUTPUT_CAP];
  unsigned char retained_stderr[INITIAL_OUTPUT_CAP];
};

struct generation_monitor {
  volatile uint8_t *base;
  uint64_t last_generation;
  int unavailable;
};

#define GENERATION_TEXT_MAX 128

enum generation_member {
  GENERATION_FORK_INDEX,
  GENERATION_FORK_COUNT,
  GENERATION_PARALLEL_INDEX,
  GENERATION_PARALLEL_COUNT,
  GENERATION_PARENT_GENERATION,
  GENERATION_GENERATION,
  GENERATION_RESUME_TIME,
  GENERATION_VM_ID,
  GENERATION_FORK_BATCH_ID,
  GENERATION_HOSTNAME,
  GENERATION_RESUME_ENTROPY_SEED,
  GENERATION_MEMBER_COUNT,
};

// The generation params members the agent reads. present has bit
// (1 << GENERATION_*) set for each member the params carried.
struct generation_params {
  unsigned present;
  uint64_t fork_index;
  uint64_t fork_count;
  uint64_t parallel_index;
  uint64_t parallel_count;
  uint64_t parent_generation;
  uint64_t generation;
  uint64_t resume_time_unix_ns;
  char vm_id[GENERATION_TEXT_MAX];
  char fork_batch_id[GENERATION_TEXT_MAX];
  char hostname[GENERATION_TEXT_MAX];
  char resume_entropy_seed[GENERATION_TEXT_MAX];
};

struct build_resolv_state {
  int configured;
  int mounted;
  int scaffold;
  int link_configured;
  int created_file;
  char link_path[1024];
  char logical_target[512];
  char mount_target[1024];
  size_t created_dir_lens[MAX_BUILD_RESOLV_COMPONENTS];
  size_t created_dir_count;
};

enum request_kind {
  REQUEST_READY,
  REQUEST_START,
  REQUEST_ATTACH,
  REQUEST_COPY_IN,
  REQUEST_COPY_OUT,
  REQUEST_BUILD_RUN,
  REQUEST_BUILD_COPY,
  REQUEST_BUILD_WORKDIR,
  REQUEST_ROOTFS_GROW,
  REQUEST_FSFREEZE,
  REQUEST_FSTHAW,
  REQUEST_INITIAL_OUTPUT,
};

struct run_request {
  enum request_kind kind;
  char session_id[64];
  uint64_t stdout_offset;
  uint64_t stderr_offset;
  uint64_t resume_time_unix_ns;
  int stdio;
  int stdin_enabled;
  int tty;
  int interactive;
  uint16_t terminal_rows;
  uint16_t terminal_cols;
  int memory_pressure;
  int detached;
  int retain_output;
  int cancel_on_disconnect;
  int require_generation_ready;
  char generation_params[GEN_PARAMS_MAX];
  char copy_path[MAX_COPY_PATH_LEN + 1];
  char copy_source[MAX_COPY_PATH_LEN + 1];
  char copy_dest[MAX_COPY_PATH_LEN + 1];
  uint64_t copy_entry_count;
  int copy_source_kind;
  int copy_source_disk;
  uint64_t copy_input_index;
  int copy_dest_is_dir;
  int copy_destination_policy;
  int copy_mtime_present;
  int64_t copy_mtime_unix_seconds;
  uint64_t build_command_len;
  int build_exec_form;
  uint64_t nofile_soft;
  uint64_t nofile_hard;
  char arg_storage[MAX_ARG_STORAGE];
  char *argv[MAX_ARGC + 1];
  char env_storage[MAX_ENVC][MAX_ENV_LEN];
  char *envp[MAX_ENVC + 1];
  char working_dir[MAX_WORKDIR_LEN];
  size_t build_cache_mount_count;
  struct {
    char target[MAX_COPY_PATH_LEN + 1];
    char key[MAX_BUILD_CACHE_KEY_LEN + 1];
  } build_cache_mounts[MAX_BUILD_CACHE_MOUNTS];
  size_t build_context_bind_count;
  struct {
    char source[MAX_COPY_PATH_LEN + 1];
    char target[MAX_COPY_PATH_LEN + 1];
  } build_context_binds[MAX_BUILD_CONTEXT_BINDS];
};

enum exec_lookup_mode {
  EXEC_LOOKUP_EXACT = 0,
  EXEC_LOOKUP_PATH = 1,
};

struct session_start_options {
  int use_rootfs;
  int memory_pressure;
  int build_run_isolation;
  int cancel_on_disconnect;
  enum exec_lookup_mode exec_lookup;
  uint64_t nofile_soft;
  uint64_t nofile_hard;
  int stdin_enabled;
  int tty;
  uint16_t terminal_rows;
  uint16_t terminal_cols;
};

struct build_cache_mount_state {
  int cache_mounted;
  int cache_root_fd;
  size_t count;
  struct {
    int source_fd;
    int target_fd;
    int bound;
    int target_cleanup_required;
    size_t created_components;
    struct spore_build_cache_created_component target_identity;
    struct spore_build_cache_created_component created_component_ids[SPORE_BUILD_CACHE_MAX_CREATED_COMPONENTS];
    char target[MAX_COPY_PATH_LEN + 1];
  } mounts[MAX_BUILD_CACHE_MOUNTS];
};

struct build_context_bind_mount_state {
  size_t count;
  struct {
    int source_fd;
    int target_fd;
    int bound;
    int target_created;
    int target_cleanup_required;
    size_t created_components;
    struct spore_build_cache_created_component target_identity;
    struct spore_build_cache_created_component created_component_ids[SPORE_BUILD_CACHE_MAX_CREATED_COMPONENTS];
    char target[MAX_COPY_PATH_LEN + 1];
  } mounts[MAX_BUILD_CONTEXT_BINDS];
};

enum exec_op_kind {
  EXEC_OP_NONE,
  EXEC_OP_TRANSIENT,
  EXEC_OP_BUILD_RUN,
};

// An exec that holds the client until it finishes: a transient exec beside a
// running captured session, or a build RUN step. The event loop runs it, and
// the next request waits until it is done.
struct exec_op {
  enum exec_op_kind kind;
  struct session session;
  int descendants_cleaned;
  struct build_cache_mount_state cache_state;
  struct build_context_bind_mount_state bind_state;
  const char *root;
};

extern int64_t t_init_start;
extern int64_t t_listen_ready;
extern int64_t t_request_accept;
extern int64_t t_request_decode;
extern int64_t t_command_start;
extern int64_t t_command_exit;
extern int64_t t_command_user_us;
extern int64_t t_command_system_us;
extern int sigchld_pipe[2];
extern int proc_dir_fd;
extern int console_mirror;
extern struct build_resolv_state build_resolv;
extern int build_run_mount_cleanup_poisoned;

int64_t now_ms(void);
void apply_resume_clock(uint64_t unix_ns);
void mount_proc(void);
void mount_sysfs(void);
void mount_cgroup2_if_dir(const char *target);
void prepare_dev(void);
void read_cmdline(char *buf, size_t cap);
uint32_t resolve_port_from_cmdline(const char *buf);
int cmdline_has_flag_in(const char *buf, const char *flag);
int wait_for_path(const char *path, int attempts, int sleep_us);
int path_is_dir(const char *path);
const char *generation_root_path(int use_rootfs, int rootfs_ready);
int setup_rootfs(int writable, int growth_session, int noinit_itable, int build_mode, char *error, size_t cap);
int setup_build_context(char *error, size_t cap);
int resolve_build_input_count(const char *buf);
int setup_build_inputs(int count, int has_context, char *error, size_t cap);
int mkdir_p(const char *path, mode_t mode);
ssize_t readlink_bounded(const char *path, char *out, size_t cap);
int unmount_build_resolv_for_snapshot(struct build_resolv_state *state);
int bind_rootfs_resolv(int build_mode, char *error, size_t cap);
int setup_network(int use_rootfs, int build_mode, char *error, size_t cap);
ssize_t read_line(int fd, char *buf, size_t cap);
int write_all(int fd, const void *raw, size_t len);
int read_exact(int fd, void *raw, size_t len);
int write_file_atomic(const char *path, const char *data, size_t len);
int poll_generation(struct generation_monitor *monitor, const char *root);
int ensure_generation_ready(struct generation_monitor *monitor, const char *root);
int set_nonblock(int fd);
void write_le16(unsigned char *out, uint16_t value);
void write_le32(unsigned char *out, uint32_t value);
void write_le64(unsigned char *out, uint64_t value);
uint16_t read_le16(const unsigned char *in);
uint32_t read_le32(const unsigned char *in);
uint64_t read_le64(const unsigned char *in);
int send_spio_data(int fd, uint32_t stream_id, uint64_t offset, const unsigned char *buf, size_t len);
int send_spio_event(int fd, const char *event);
int write_text_file(const char *path, const char *text);
int write_pid_file(const char *path, pid_t pid);
int read_u64_file(const char *path, uint64_t *out);
int cgroup_child_path(char *out, size_t out_len, const char *dir, const char *file);
void close_session_cgroup(struct session *session);
int stop_session_processes(struct session *session, pid_t pid);
__attribute__((noreturn)) void fail_closed_build_run_cleanup(const char *phase);
void drain_memory_pressure_events(struct session *session);
int rearm_memory_pressure_limit(struct session *session);
void close_client(struct client *client);
int send_client_output(struct session *session, struct client *client, const char *name, uint64_t *client_offset, uint64_t offset, const unsigned char *buf, size_t len);
int send_client_terminal_output(struct session *session, struct client *client, uint64_t offset, const unsigned char *buf, size_t len);
void mirror_console(int is_stdout, const unsigned char *buf, size_t len);
int wait_child(pid_t pid, int *status, struct rusage *usage);
int setup_sigchld_wakeup(void);
void drain_sigchld_wakeup(void);
int parse_generation_params(const char *params, struct generation_params *out);
int parse_request(const char *req, size_t req_len, struct run_request *out);
int send_client_error_exit(struct client *client, int code, const char *message);
int send_client_stdout(struct client *client, const char *message);
int send_client_exit(struct client *client, int code);
int read_build_command_from_spio(struct client *client, uint64_t command_len, char *command, size_t cap, char *error, size_t error_cap);
int read_spio_header_blocking(int fd, uint8_t *type, uint32_t *stream_id, uint64_t *offset, uint32_t *payload_len);
int copy_in_file(struct client *client, const char *root, const char *guest_path);
int copy_out_file(struct client *client, const char *root, const char *guest_path);
int build_workdir_apply(struct client *client, const char *root, const char *path);
int freeze_or_thaw_rootfs(struct client *client, int freeze);
int grow_rootfs(struct client *client);
int apply_terminal_size(int fd, uint16_t rows, uint16_t cols);
void execve_or_report( char *const argv[], char *const envp[], int use_rootfs, int failure_fd, enum exec_lookup_mode exec_lookup);
int start_session(struct session *session, const char *session_id, char *const argv[], char *const envp[], const char *working_dir, const struct session_start_options *options);
void wait_child_blocking(pid_t pid);
int session_cgroup_populated(struct session *session);
void reap_exited_children(void);
void reap_detached_children(struct detached_children *children);
void drain_retained_output(struct detached_children *children);
int send_retained_output(struct client *client, struct detached_children *children);
void close_fd_if_open(int *fd);
void close_pipe_if_open(int pipefd[2]);
int start_detached(char *const argv[], char *const envp[], const char *working_dir, int use_rootfs, int retain_output, struct detached_children *children);
int session_finished(const struct session *session);
void reset_session(struct session *session);
int attach_client(struct session *session, struct client *client, uint64_t stdout_offset, uint64_t stderr_offset);
void pump_session_stream(struct session *session, struct client *client, int is_stdout);
void drain_session_terminal(struct session *session);
void add_session_output_fds(const struct session *session, struct pollfd *fds, int *roles, nfds_t *nfds, int stdout_role);
void pump_session_output(struct session *session, struct client *client, int is_stdout, short revents);
void drain_session_stdin(struct session *session);
void close_client_input_lost(struct session *session, struct client *client);
void pump_client_v1(struct session *session, struct client *client);
void poll_session_exit(struct session *session, struct client *client);
void maybe_send_session_exit(struct session *session, struct client *client);
void maybe_send_memory_pressure(struct session *session, struct client *client);
int start_transient_exec(struct exec_op *op, struct client *client, const struct run_request *request, int use_rootfs);
void finish_transient_exec(struct exec_op *op, struct client *client);
void poison_build_run_mount_cleanup(const char *phase);
int cleanup_build_cache_mounts(struct build_cache_mount_state *state, const char *root);
int setup_build_cache_mounts(const struct run_request *request, const char *root, int has_context, int build_input_count, struct build_cache_mount_state *state, char *error, size_t error_cap);
int setup_build_context_binds(const struct run_request *request, const char *root, int build_context_requested, int build_context_ready, struct build_context_bind_mount_state *state, char *error, size_t error_cap);
int start_build_exec(struct exec_op *op, struct client *client, const struct run_request *request, char *command, int use_rootfs, const char *root);
void step_build_exec(struct exec_op *op, struct client *client);
void finish_build_exec(struct exec_op *op, struct client *client);
const char *apply_request_generation(struct generation_monitor *generation, const char *root, const char *params);

#endif
