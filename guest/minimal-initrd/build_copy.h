#ifndef SPORE_BUILD_COPY_H
#define SPORE_BUILD_COPY_H

#include <stddef.h>
#include <stdint.h>

#define SPORE_BUILD_COPY_KIND_FILE 'F'
#define SPORE_BUILD_COPY_KIND_DIR 'D'
#define SPORE_BUILD_COPY_KIND_SYMLINK 'L'
#define SPORE_BUILD_COPY_KIND_AUTO 'A'

#define SPORE_BUILD_COPY_SOURCE_CONTEXT 0
#define SPORE_BUILD_COPY_SOURCE_BUILD_INPUT 1

#define SPORE_BUILD_COPY_PATH_MAX 512
#define SPORE_BUILD_COPY_MAX_ENTRIES 65536ULL
#define SPORE_BUILD_COPY_FD_BUDGET (SPORE_BUILD_COPY_MAX_ENTRIES + 256ULL)

enum spore_build_copy_exit {
  SPORE_BUILD_COPY_OK = 0,
  SPORE_BUILD_COPY_APPLY_FAILED = 1,
  SPORE_BUILD_COPY_INVALID = 2,
  SPORE_BUILD_COPY_UNAVAILABLE = 126,
};

int spore_build_copy_apply(
    const char *root, const char *source_root,
    const char *source, const char *dest,
    int source_kind, int dest_is_dir, uint64_t entry_count,
    int mtime_present, int64_t mtime_unix_seconds,
    char *error, size_t error_cap);

int spore_build_ensure_directory(const char *root, const char *path);
int spore_build_copy_ensure_fd_budget(void);

#endif
