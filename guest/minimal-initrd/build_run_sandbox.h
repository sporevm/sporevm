#ifndef SPORE_BUILD_RUN_SANDBOX_H
#define SPORE_BUILD_RUN_SANDBOX_H

#include <stddef.h>

int spore_build_run_sandbox_attach_device_policy(
    const char *cgroup_path, char *error, size_t error_cap);

/*
 * Enter the operation namespaces and return only in the command-side PID 1.
 * The trusted supervisor waits for that process and exits with the same status.
 */
int spore_build_run_sandbox_enter(
    const char *rootfs, int ready_fd, char *error, size_t error_cap);

#endif
