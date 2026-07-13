/**
 * @file spore.h
 *
 * C ABI for libspore.
 */

#ifndef SPORE_H
#define SPORE_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#ifndef SPORE_API
#if defined(SPORE_STATIC)
#define SPORE_API
#elif defined(_WIN32) || defined(_WIN64)
#ifdef SPORE_BUILD_SHARED
#define SPORE_API __declspec(dllexport)
#else
#define SPORE_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) && __GNUC__ >= 4
#define SPORE_API __attribute__((visibility("default")))
#else
#define SPORE_API
#endif
#endif

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define SPORE_ENUM_TYPED : int
#else
#define SPORE_ENUM_TYPED
#endif
#define SPORE_ENUM_MAX_VALUE INT_MAX
#define SPORE_ABI_VERSION 15u

#ifdef __cplusplus
extern "C" {
#endif

/** Result codes returned by libspore C ABI functions. */
typedef enum SPORE_ENUM_TYPED {
  SPORE_SUCCESS = 0,
  SPORE_OUT_OF_MEMORY = -1,
  SPORE_INVALID_VALUE = -2,
  SPORE_ERROR = -3,
  SPORE_RESULT_MAX_VALUE = SPORE_ENUM_MAX_VALUE,
} SporeResult;

/** Build information fields for spore_build_info(). */
typedef enum SPORE_ENUM_TYPED {
  SPORE_BUILD_INFO_VERSION_STRING = 1,
  SPORE_BUILD_INFO_ABI_VERSION = 2,
  SPORE_BUILD_INFO_MAX_VALUE = SPORE_ENUM_MAX_VALUE,
} SporeBuildInfo;

/** Borrowed string. The producing function documents the lifetime. */
typedef struct SporeString {
  const char *ptr;
  size_t len;
} SporeString;

/** Owned string returned by libspore. Free with spore_free_string(). */
typedef struct SporeOwnedString {
  char *ptr;
  size_t len;
} SporeOwnedString;

/** Opaque process context for libspore C ABI calls. */
typedef struct SporeContextImpl *SporeContext;
typedef struct SporeExecNamedStreamImpl *SporeExecNamedStream;

#define SPORE_INSPECT_BUNDLE_OPTIONS_VERSION 1u
#define SPORE_PULL_OPTIONS_VERSION 1u
#define SPORE_SYSTEM_DF_OPTIONS_VERSION 1u
#define SPORE_SYSTEM_PRUNE_OPTIONS_VERSION 1u
#define SPORE_CREATE_NAMED_OPTIONS_VERSION 4u
#define SPORE_RESTORE_NAMED_OPTIONS_VERSION 1u
#define SPORE_FORK_NAMED_OPTIONS_VERSION 1u
#define SPORE_EXEC_NAMED_OPTIONS_VERSION 2u
#define SPORE_EXEC_NAMED_STREAM_OPTIONS_VERSION 1u
#define SPORE_COPY_NAMED_OPTIONS_VERSION 1u
#define SPORE_SAVE_NAMED_OPTIONS_VERSION 1u
#define SPORE_REMOVE_NAMED_OPTIONS_VERSION 1u
#define SPORE_REMOVE_SAVED_OPTIONS_VERSION 1u
#define SPORE_INSPECT_SPORE_OPTIONS_VERSION 1u
#define SPORE_REEXEC_CONTRACT_VERSION 1u

#define SPORE_CACHE_ROOT_ENV 0u
#define SPORE_CACHE_ROOT_NONE 1u
#define SPORE_CACHE_ROOT_PATH 2u

#define SPORE_EXEC_NAMED_STREAM_STDOUT 1
#define SPORE_EXEC_NAMED_STREAM_STDERR 2
#define SPORE_EXEC_NAMED_STREAM_TERMINAL 3
#define SPORE_EXEC_NAMED_STREAM_EXIT 4
#define SPORE_EXEC_NAMED_STREAM_ERROR 5

/** Options for spore_inspect_bundle_json(). */
typedef struct SporeInspectBundleOptions {
  uint32_t size;
  uint32_t version;
  SporeString source;
  SporeString child_id;
  uint8_t has_child_range;
  uint32_t child_range_start;
  uint32_t child_range_end;
} SporeInspectBundleOptions;

/** Options for spore_inspect_spore_json(). */
typedef struct SporeInspectSporeOptions {
  uint32_t size;
  uint32_t version;
  SporeString spore_dir;
} SporeInspectSporeOptions;

/** Cache-root selection for operations that can use SporeVM caches. */
typedef struct SporeCacheRoot {
  uint32_t kind;
  SporeString path;
} SporeCacheRoot;

/** Options for spore_pull_json(). */
typedef struct SporePullOptions {
  uint32_t size;
  uint32_t version;
  SporeString source;
  SporeString out_dir;
  SporeCacheRoot rootfs_cache;
  SporeCacheRoot bundle_cache;
  SporeString child_id;
  uint8_t allow_metadata_only_rootfs;
  SporeString aws_region;
  SporeString aws_executable;
} SporePullOptions;

/** Options for spore_system_df_json(). */
typedef struct SporeSystemDfOptions {
  uint32_t size;
  uint32_t version;
  SporeString rootfs_cache;
} SporeSystemDfOptions;

/** Options for spore_system_prune_json(). */
typedef struct SporeSystemPruneOptions {
  uint32_t size;
  uint32_t version;
  SporeString rootfs_cache;
  uint8_t dry_run;
  uint8_t include_digest_artifacts;
  uint8_t has_older_than_seconds;
  uint64_t older_than_seconds;
  uint8_t has_max_bytes;
  uint64_t max_bytes;
  uint8_t rootfs_only;
} SporeSystemPruneOptions;

/** Exact host plus port egress rule. */
typedef struct SporeNetworkRule {
  SporeString host;
  const uint16_t *ports;
  size_t port_count;
} SporeNetworkRule;

/** Host-provided Unix socket exposed to the guest as a named service. */
typedef struct SporeBoundUnixService {
  SporeString name;
  SporeString guest_host;
  uint16_t guest_port;
  SporeString unix_path;
} SporeBoundUnixService;

/** Restore-time Unix socket binding for a manifest-declared bound service. */
typedef struct SporeBoundUnixServiceBinding {
  SporeString name;
  SporeString unix_path;
} SporeBoundUnixServiceBinding;

/** Opaque manifest annotation key/value. Values are stored without interpretation. */
typedef struct SporeAnnotation {
  SporeString key;
  SporeString value;
} SporeAnnotation;

/** Options for spore_create_named_json(). */
typedef struct SporeCreateNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
  SporeString backend;
  SporeString kernel_path;
  SporeString initrd_path;
  SporeString rootfs_path;
  SporeString image_ref;
  SporeString spore_executable;
  uint64_t memory_bytes;
  uint32_t vcpus;
  uint32_t guest_port;
  uint64_t timeout_ms;
  SporeString console_log_path;
  uint8_t network_enabled;
  const SporeString *allow_cidrs;
  size_t allow_cidr_count;
  const SporeString *allow_hosts;
  size_t allow_host_count;
  const SporeNetworkRule *network_rules;
  size_t network_rule_count;
  const SporeBoundUnixService *bound_unix_services;
  size_t bound_unix_service_count;
  const SporeAnnotation *annotations;
  size_t annotation_count;
} SporeCreateNamedOptions;

/** Options for spore_exec_named_json(). */
typedef struct SporeExecNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
  const SporeString *argv;
  size_t argc;
  uint8_t has_network_policy;
  const SporeNetworkRule *network_rules;
  size_t network_rule_count;
} SporeExecNamedOptions;

/** Options for spore_exec_named_stream_open(). */
typedef struct SporeExecNamedStreamOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
  const SporeString *argv;
  size_t argc;
  uint8_t interactive;
  uint8_t tty;
  SporeString terminal_name;
  uint16_t terminal_rows;
  uint16_t terminal_cols;
} SporeExecNamedStreamOptions;

/**
 * Streaming exec event.
 *
 * `bytes` is borrowed from the stream and remains valid until the next
 * operation on that stream or until the stream is freed.
 */
typedef struct SporeExecNamedStreamEvent {
  int type;
  SporeString bytes;
  uint8_t exit_code;
} SporeExecNamedStreamEvent;

/** Options for spore_copy_in_named() and spore_copy_out_named(). */
typedef struct SporeCopyNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
  SporeString host_path;
  SporeString guest_path;
} SporeCopyNamedOptions;

/** Options for spore_restore_named_json(). */
typedef struct SporeRestoreNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString spore_dir;
  SporeString name;
  SporeString spore_executable;
  const SporeBoundUnixServiceBinding *bound_unix_services;
  size_t bound_unix_service_count;
} SporeRestoreNamedOptions;

/** Options for spore_fork_named_json(). */
typedef struct SporeForkNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString source_name;
  size_t count;
  SporeString name_pattern;
  SporeString spore_executable;
} SporeForkNamedOptions;

/** Options for spore_save_named_json(). */
typedef struct SporeSaveNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
  SporeString out_dir;
  uint8_t stop;
  const SporeAnnotation *annotations;
  size_t annotation_count;
} SporeSaveNamedOptions;

/** Options for spore_remove_named_json(). */
typedef struct SporeRemoveNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
} SporeRemoveNamedOptions;

/** Options for spore_remove_saved_json(). */
typedef struct SporeRemoveSavedOptions {
  uint32_t size;
  uint32_t version;
  SporeString spore_dir;
} SporeRemoveSavedOptions;

/** Initialize inspect-bundle options with the current ABI size and version. */
SPORE_API void spore_inspect_bundle_options_init(SporeInspectBundleOptions *options);

/** Initialize inspect-spore options with the current ABI size and version. */
SPORE_API void spore_inspect_spore_options_init(SporeInspectSporeOptions *options);

/** Initialize pull options with defaults. */
SPORE_API void spore_pull_options_init(SporePullOptions *options);

/** Initialize system-df options with defaults. */
SPORE_API void spore_system_df_options_init(SporeSystemDfOptions *options);

/** Initialize system-prune options with defaults. */
SPORE_API void spore_system_prune_options_init(SporeSystemPruneOptions *options);

/** Initialize create-named options with defaults. */
SPORE_API void spore_create_named_options_init(SporeCreateNamedOptions *options);

/** Initialize exec-named options with defaults. */
SPORE_API void spore_exec_named_options_init(SporeExecNamedOptions *options);

/** Initialize streaming exec options with defaults. */
SPORE_API void spore_exec_named_stream_options_init(SporeExecNamedStreamOptions *options);

/** Initialize named copy options with defaults. */
SPORE_API void spore_copy_named_options_init(SporeCopyNamedOptions *options);

/** Initialize restore-named options with defaults. */
SPORE_API void spore_restore_named_options_init(SporeRestoreNamedOptions *options);

/** Initialize fork-named options with defaults. */
SPORE_API void spore_fork_named_options_init(SporeForkNamedOptions *options);

/** Initialize save-named options with defaults. */
SPORE_API void spore_save_named_options_init(SporeSaveNamedOptions *options);

/** Initialize remove-named options with defaults. */
SPORE_API void spore_remove_named_options_init(SporeRemoveNamedOptions *options);
SPORE_API void spore_remove_saved_options_init(SporeRemoveSavedOptions *options);

/**
 * Query compile-time library information.
 *
 * `out` must point to the type documented by `field`:
 * - SPORE_BUILD_INFO_VERSION_STRING: SporeString*
 * - SPORE_BUILD_INFO_ABI_VERSION: uint32_t*
 */
SPORE_API SporeResult spore_build_info(SporeBuildInfo field, void *out);

/**
 * Run a hidden SporeVM re-exec role selected by SPORE_REEXEC_ROLE.
 *
 * Returns SPORE_INVALID_VALUE when argv or environment do not describe a
 * SporeVM re-exec child. On success, out_exit_code is the role exit code.
 */
SPORE_API SporeResult spore_reexec_main(int argc,
                                        const char *const *argv,
                                        int *out_exit_code);

/** Create a libspore context. */
SPORE_API SporeResult spore_context_new(SporeContext *out_context);

/** Free a libspore context. */
SPORE_API void spore_context_free(SporeContext context);

/**
 * Return the last context-local error message.
 *
 * The string is borrowed from the context and remains valid until the next
 * libspore call using the same context, or until the context is freed.
 */
SPORE_API SporeString spore_context_last_error(SporeContext context);

/** Set a context-local environment variable used by libspore operations. */
SPORE_API SporeResult spore_context_set_env(SporeContext context, SporeString name, SporeString value);

/** Free a string returned by this context. */
SPORE_API void spore_free_string(SporeContext context, SporeOwnedString string);

/**
 * Return host information as `spore.host-info.v1` JSON.
 *
 * The returned string is NUL-terminated for C convenience. `len` excludes the
 * trailing NUL and includes the final newline, matching CLI JSON output.
 */
SPORE_API SporeResult spore_host_info_json(SporeContext context, SporeOwnedString *out_json);

/** Return libspore network capability facts as JSON. */
SPORE_API SporeResult spore_network_capabilities_json(SporeContext context, SporeOwnedString *out_json);

/**
 * Inspect a bundle and return `spore.bundle.inspect.v1` JSON.
 *
 * The returned string is NUL-terminated for C convenience. `len` excludes the
 * trailing NUL and includes the final newline, matching CLI JSON output.
 */
SPORE_API SporeResult spore_inspect_bundle_json(SporeContext context,
                                                const SporeInspectBundleOptions *options,
                                                SporeOwnedString *out_json);

/**
 * Inspect a local spore artifact and return JSON including annotation
 * key/value pairs.
 *
 * The returned string is NUL-terminated for C convenience. `len` excludes the
 * trailing NUL and includes the final newline, matching CLI JSON output.
 */
SPORE_API SporeResult spore_inspect_spore_json(SporeContext context,
                                               const SporeInspectSporeOptions *options,
                                               SporeOwnedString *out_json);

/**
 * Pull a bundle into a local spore directory and return `spore.pull.result.v1`
 * JSON.
 *
 * Cache roots default to SPORE_CACHE_ROOT_ENV. Use SPORE_CACHE_ROOT_NONE to
 * disable a cache or SPORE_CACHE_ROOT_PATH with a non-empty path to select one
 * explicitly.
 */
SPORE_API SporeResult spore_pull_json(SporeContext context,
                                      const SporePullOptions *options,
                                      SporeOwnedString *out_json);

/** Return rootfs cache usage as JSON. */
SPORE_API SporeResult spore_system_df_json(SporeContext context,
                                           const SporeSystemDfOptions *options,
                                           SporeOwnedString *out_json);

/** Prune local system state and return JSON output. */
SPORE_API SporeResult spore_system_prune_json(SporeContext context,
                                              const SporeSystemPruneOptions *options,
                                              SporeOwnedString *out_json);

/** Create a named VM and return `spore.lifecycle.v1` JSON. */
SPORE_API SporeResult spore_create_named_json(SporeContext context,
                                              const SporeCreateNamedOptions *options,
                                              SporeOwnedString *out_json);

/** Execute a command in a named VM and return JSON output. */
SPORE_API SporeResult spore_exec_named_json(SporeContext context,
                                            const SporeExecNamedOptions *options,
                                            SporeOwnedString *out_json);

/** Open a streaming exec session in a named VM. Free with spore_exec_named_stream_free(). */
SPORE_API SporeResult spore_exec_named_stream_open(SporeContext context,
                                                   const SporeExecNamedStreamOptions *options,
                                                   SporeExecNamedStream *out_stream);

/** Read the next stdout, stderr, terminal, exit, or error event. */
SPORE_API SporeResult spore_exec_named_stream_next(SporeContext context,
                                                   SporeExecNamedStream stream,
                                                   SporeExecNamedStreamEvent *out_event);

/** Send pipe stdin bytes to a streaming exec session. */
SPORE_API SporeResult spore_exec_named_stream_write_stdin(SporeContext context,
                                                          SporeExecNamedStream stream,
                                                          SporeString bytes);

/** Send terminal input bytes to a streaming exec session. */
SPORE_API SporeResult spore_exec_named_stream_write_terminal(SporeContext context,
                                                             SporeExecNamedStream stream,
                                                             SporeString bytes);

/** Close pipe stdin for a streaming exec session. */
SPORE_API SporeResult spore_exec_named_stream_close_stdin(SporeContext context,
                                                          SporeExecNamedStream stream);

/** Close terminal input for a streaming exec session. */
SPORE_API SporeResult spore_exec_named_stream_close_terminal(SporeContext context,
                                                             SporeExecNamedStream stream);

/** Resize the guest terminal for a streaming exec session. */
SPORE_API SporeResult spore_exec_named_stream_resize_terminal(SporeContext context,
                                                              SporeExecNamedStream stream,
                                                              uint16_t rows,
                                                              uint16_t cols);

/** Free a streaming exec session. */
SPORE_API void spore_exec_named_stream_free(SporeContext context,
                                            SporeExecNamedStream stream);

/** Copy an explicit host file or directory into a named VM. */
SPORE_API SporeResult spore_copy_in_named(SporeContext context,
                                          const SporeCopyNamedOptions *options);

/** Copy an explicit guest file or directory out of a named VM. */
SPORE_API SporeResult spore_copy_out_named(SporeContext context,
                                           const SporeCopyNamedOptions *options);

/**
 * Restore a named VM from a spore and return `spore.lifecycle.v1`
 * JSON.
 *
 * If the manifest declares bound Unix services, `bound_unix_services` must
 * provide one live socket path for each declared service name. Host paths are
 * used only for this restore attempt and are not written into the spore
 * manifest.
 */
SPORE_API SporeResult spore_restore_named_json(SporeContext context,
                                               const SporeRestoreNamedOptions *options,
                                               SporeOwnedString *out_json);

/** Fork a named VM and return JSON output. */
SPORE_API SporeResult spore_fork_named_json(SporeContext context,
                                            const SporeForkNamedOptions *options,
                                            SporeOwnedString *out_json);

/** Save a named VM and return `spore.lifecycle.v1` JSON. */
SPORE_API SporeResult spore_save_named_json(SporeContext context,
                                            const SporeSaveNamedOptions *options,
                                            SporeOwnedString *out_json);

/** Remove a named VM and return `spore.lifecycle.v1` JSON. */
SPORE_API SporeResult spore_remove_named_json(SporeContext context,
                                              const SporeRemoveNamedOptions *options,
                                              SporeOwnedString *out_json);

/** Remove a machine-local saved spore and unregister its durable CAS pin when present. */
SPORE_API SporeResult spore_remove_saved_json(SporeContext context,
                                              const SporeRemoveSavedOptions *options,
                                              SporeOwnedString *out_json);

/** List named VMs and return JSON. */
SPORE_API SporeResult spore_list_named_json(SporeContext context, SporeOwnedString *out_json);

#ifdef __cplusplus
}
#endif

#endif /* SPORE_H */
