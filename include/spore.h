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

/** Initialize inspect-bundle options with the current ABI size and version. */
SPORE_API void spore_inspect_bundle_options_init(SporeInspectBundleOptions *options);

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

/** Free a string returned by this context. */
SPORE_API void spore_free_string(SporeContext context, SporeOwnedString string);

/**
 * Return host information as `spore.host-info.v1` JSON.
 *
 * The returned string is NUL-terminated for C convenience. `len` excludes the
 * trailing NUL and includes the final newline, matching CLI JSON output.
 */
SPORE_API SporeResult spore_host_info_json(SporeContext context, SporeOwnedString *out_json);

/**
 * Inspect a bundle and return `spore.bundle.inspect.v1` JSON.
 *
 * The returned string is NUL-terminated for C convenience. `len` excludes the
 * trailing NUL and includes the final newline, matching CLI JSON output.
 */
SPORE_API SporeResult spore_inspect_bundle_json(SporeContext context,
                                                const SporeInspectBundleOptions *options,
                                                SporeOwnedString *out_json);

#ifdef __cplusplus
}
#endif

#endif /* SPORE_H */
