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

#define SPORE_INSPECT_BUNDLE_OPTIONS_VERSION 1u
#define SPORE_CREATE_NAMED_OPTIONS_VERSION 3u
#define SPORE_RESUME_NAMED_OPTIONS_VERSION 1u
#define SPORE_FORK_NAMED_OPTIONS_VERSION 1u
#define SPORE_EXEC_NAMED_OPTIONS_VERSION 2u
#define SPORE_SNAPSHOT_NAMED_OPTIONS_VERSION 1u
#define SPORE_SUSPEND_NAMED_OPTIONS_VERSION 1u
#define SPORE_REMOVE_NAMED_OPTIONS_VERSION 1u

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

/** Options for spore_resume_named_json(). */
typedef struct SporeResumeNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString spore_dir;
  SporeString name;
  SporeString spore_executable;
} SporeResumeNamedOptions;

/** Options for spore_fork_named_json(). */
typedef struct SporeForkNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString source_name;
  size_t count;
  SporeString name_pattern;
  SporeString spore_executable;
} SporeForkNamedOptions;

/** Options for spore_snapshot_named_json(). */
typedef struct SporeSnapshotNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
  SporeString out_dir;
  uint8_t continue_after;
} SporeSnapshotNamedOptions;

/** Options for spore_suspend_named_json(). */
typedef struct SporeSuspendNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
  SporeString out_dir;
} SporeSuspendNamedOptions;

/** Options for spore_remove_named_json(). */
typedef struct SporeRemoveNamedOptions {
  uint32_t size;
  uint32_t version;
  SporeString name;
} SporeRemoveNamedOptions;

/** Initialize inspect-bundle options with the current ABI size and version. */
SPORE_API void spore_inspect_bundle_options_init(SporeInspectBundleOptions *options);

/** Initialize create-named options with defaults. */
SPORE_API void spore_create_named_options_init(SporeCreateNamedOptions *options);

/** Initialize exec-named options with defaults. */
SPORE_API void spore_exec_named_options_init(SporeExecNamedOptions *options);

/** Initialize resume-named options with defaults. */
SPORE_API void spore_resume_named_options_init(SporeResumeNamedOptions *options);

/** Initialize fork-named options with defaults. */
SPORE_API void spore_fork_named_options_init(SporeForkNamedOptions *options);

/** Initialize snapshot-named options with defaults. */
SPORE_API void spore_snapshot_named_options_init(SporeSnapshotNamedOptions *options);

/** Initialize suspend-named options with defaults. */
SPORE_API void spore_suspend_named_options_init(SporeSuspendNamedOptions *options);

/** Initialize remove-named options with defaults. */
SPORE_API void spore_remove_named_options_init(SporeRemoveNamedOptions *options);

/**
 * Query compile-time library information.
 *
 * `out` must point to the type documented by `field`:
 * - SPORE_BUILD_INFO_VERSION_STRING: SporeString*
 * - SPORE_BUILD_INFO_ABI_VERSION: uint32_t*
 */
SPORE_API SporeResult spore_build_info(SporeBuildInfo field, void *out);

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

/** Create a named VM and return `spore.lifecycle.v1` JSON. */
SPORE_API SporeResult spore_create_named_json(SporeContext context,
                                              const SporeCreateNamedOptions *options,
                                              SporeOwnedString *out_json);

/** Execute a command in a named VM and return JSON output. */
SPORE_API SporeResult spore_exec_named_json(SporeContext context,
                                            const SporeExecNamedOptions *options,
                                            SporeOwnedString *out_json);

/** Resume a named VM from a spore checkpoint and return `spore.lifecycle.v1` JSON. */
SPORE_API SporeResult spore_resume_named_json(SporeContext context,
                                              const SporeResumeNamedOptions *options,
                                              SporeOwnedString *out_json);

/** Fork a named VM and return JSON output. */
SPORE_API SporeResult spore_fork_named_json(SporeContext context,
                                            const SporeForkNamedOptions *options,
                                            SporeOwnedString *out_json);

/** Snapshot a named VM and return `spore.lifecycle.v1` JSON. */
SPORE_API SporeResult spore_snapshot_named_json(SporeContext context,
                                                const SporeSnapshotNamedOptions *options,
                                                SporeOwnedString *out_json);

/** Suspend a named VM and return `spore.lifecycle.v1` JSON. */
SPORE_API SporeResult spore_suspend_named_json(SporeContext context,
                                               const SporeSuspendNamedOptions *options,
                                               SporeOwnedString *out_json);

/** Remove a named VM and return `spore.lifecycle.v1` JSON. */
SPORE_API SporeResult spore_remove_named_json(SporeContext context,
                                              const SporeRemoveNamedOptions *options,
                                              SporeOwnedString *out_json);

/** List named VMs and return JSON. */
SPORE_API SporeResult spore_list_named_json(SporeContext context, SporeOwnedString *out_json);

#ifdef __cplusplus
}
#endif

#endif /* SPORE_H */
