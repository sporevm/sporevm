#include <stdint.h>
#include <string.h>

#include "spore.h"

static int expect_success(SporeResult result) {
  return result == SPORE_SUCCESS ? 0 : 1;
}

int main(void) {
  SporeString version = {0};
  if (expect_success(spore_build_info(SPORE_BUILD_INFO_VERSION_STRING, &version)) != 0) return 1;
  if (version.ptr == 0 || version.len == 0) return 1;

  uint32_t abi_version = 0;
  if (expect_success(spore_build_info(SPORE_BUILD_INFO_ABI_VERSION, &abi_version)) != 0) return 1;
  if (abi_version != 12) return 1;

  SporeInspectBundleOptions options;
  spore_inspect_bundle_options_init(&options);
  if (options.size != sizeof(options)) return 1;
  if (options.version != SPORE_INSPECT_BUNDLE_OPTIONS_VERSION) return 1;

  SporeInspectSporeOptions inspect_spore_options;
  spore_inspect_spore_options_init(&inspect_spore_options);
  if (inspect_spore_options.size != sizeof(inspect_spore_options)) return 1;
  if (inspect_spore_options.version != SPORE_INSPECT_SPORE_OPTIONS_VERSION) return 1;

  SporePullOptions pull_options;
  spore_pull_options_init(&pull_options);
  if (pull_options.size != sizeof(pull_options)) return 1;
  if (pull_options.version != SPORE_PULL_OPTIONS_VERSION) return 1;
  if (pull_options.rootfs_cache.kind != SPORE_CACHE_ROOT_ENV) return 1;
  if (pull_options.bundle_cache.kind != SPORE_CACHE_ROOT_ENV) return 1;
  if (pull_options.allow_metadata_only_rootfs != 0) return 1;

  SporeSystemDfOptions df_options;
  spore_system_df_options_init(&df_options);
  if (df_options.size != sizeof(df_options)) return 1;
  if (df_options.version != SPORE_SYSTEM_DF_OPTIONS_VERSION) return 1;

  SporeSystemPruneOptions prune_options;
  spore_system_prune_options_init(&prune_options);
  if (prune_options.size != sizeof(prune_options)) return 1;
  if (prune_options.version != SPORE_SYSTEM_PRUNE_OPTIONS_VERSION) return 1;
  if (prune_options.dry_run != 1) return 1;
  if (prune_options.include_digest_artifacts != 0) return 1;

  SporeCreateNamedOptions create_options;
  spore_create_named_options_init(&create_options);
  if (create_options.size != sizeof(create_options)) return 1;
  if (create_options.version != SPORE_CREATE_NAMED_OPTIONS_VERSION) return 1;
  if (create_options.guest_port != 10700) return 1;
  if (create_options.network_enabled != 0) return 1;
  if (create_options.allow_cidr_count != 0) return 1;
  if (create_options.allow_host_count != 0) return 1;
  if (create_options.network_rule_count != 0) return 1;
  if (create_options.bound_unix_service_count != 0) return 1;
  if (create_options.annotation_count != 0) return 1;

  SporeExecNamedOptions exec_options;
  spore_exec_named_options_init(&exec_options);
  if (exec_options.size != sizeof(exec_options)) return 1;
  if (exec_options.version != SPORE_EXEC_NAMED_OPTIONS_VERSION) return 1;
  if (exec_options.has_network_policy != 0) return 1;

  SporeExecNamedStreamOptions stream_options;
  spore_exec_named_stream_options_init(&stream_options);
  if (stream_options.size != sizeof(stream_options)) return 1;
  if (stream_options.version != SPORE_EXEC_NAMED_STREAM_OPTIONS_VERSION) return 1;
  if (stream_options.terminal_rows != 24) return 1;
  if (stream_options.terminal_cols != 80) return 1;

  SporeCopyNamedOptions copy_options;
  spore_copy_named_options_init(&copy_options);
  if (copy_options.size != sizeof(copy_options)) return 1;
  if (copy_options.version != SPORE_COPY_NAMED_OPTIONS_VERSION) return 1;

  SporeResumeNamedOptions resume_options;
  spore_resume_named_options_init(&resume_options);
  if (resume_options.size != sizeof(resume_options)) return 1;
  if (resume_options.version != SPORE_RESUME_NAMED_OPTIONS_VERSION) return 1;
  if (resume_options.bound_unix_service_count != 0) return 1;

  SporeForkNamedOptions fork_options;
  spore_fork_named_options_init(&fork_options);
  if (fork_options.size != sizeof(fork_options)) return 1;
  if (fork_options.version != SPORE_FORK_NAMED_OPTIONS_VERSION) return 1;

  SporeSnapshotNamedOptions snapshot_options;
  spore_snapshot_named_options_init(&snapshot_options);
  if (snapshot_options.size != sizeof(snapshot_options)) return 1;
  if (snapshot_options.version != SPORE_SNAPSHOT_NAMED_OPTIONS_VERSION) return 1;
  if (snapshot_options.continue_after != 1) return 1;
  if (snapshot_options.annotation_count != 0) return 1;

  SporeSuspendNamedOptions suspend_options;
  spore_suspend_named_options_init(&suspend_options);
  if (suspend_options.size != sizeof(suspend_options)) return 1;
  if (suspend_options.version != SPORE_SUSPEND_NAMED_OPTIONS_VERSION) return 1;

  SporeRemoveNamedOptions remove_options;
  spore_remove_named_options_init(&remove_options);
  if (remove_options.size != sizeof(remove_options)) return 1;
  if (remove_options.version != SPORE_REMOVE_NAMED_OPTIONS_VERSION) return 1;

#if defined(SPORE_SMOKE_HOST_INFO)
  SporeContext context = 0;
  if (expect_success(spore_context_new(&context)) != 0) return 1;
  if (context == 0) return 1;

  SporeOwnedString json = {0};
  if (expect_success(spore_host_info_json(context, &json)) != 0) return 1;
  if (json.ptr == 0 || json.len == 0) return 1;
  if (strstr(json.ptr, "\"schema\": \"spore.host-info.v1\"") == 0) return 1;

  spore_free_string(context, json);

  SporeOwnedString capabilities_json = {0};
  if (expect_success(spore_network_capabilities_json(context, &capabilities_json)) != 0) return 1;
  if (capabilities_json.ptr == 0 || strstr(capabilities_json.ptr, "\"exact_host_port\": true") == 0) return 1;
  spore_free_string(context, capabilities_json);

  SporeString rootfs_cache = { "/tmp/sporevm-c-smoke-rootfs-empty", strlen("/tmp/sporevm-c-smoke-rootfs-empty") };
  df_options.rootfs_cache = rootfs_cache;
  SporeOwnedString df_json = {0};
  if (expect_success(spore_system_df_json(context, &df_options, &df_json)) != 0) return 1;
  if (df_json.ptr == 0 || strstr(df_json.ptr, "\"cache_root\": \"/tmp/sporevm-c-smoke-rootfs-empty\"") == 0) return 1;
  spore_free_string(context, df_json);

  prune_options.rootfs_cache = rootfs_cache;
  SporeOwnedString prune_json = {0};
  if (expect_success(spore_system_prune_json(context, &prune_options, &prune_json)) != 0) return 1;
  if (prune_json.ptr == 0 || strstr(prune_json.ptr, "\"dry_run\": true") == 0) return 1;
  spore_free_string(context, prune_json);

  SporeString env_name = { "SPOREVM_RUNTIME_DIR", strlen("SPOREVM_RUNTIME_DIR") };
  SporeString env_value = { "/tmp/sporevm-c-smoke-empty", strlen("/tmp/sporevm-c-smoke-empty") };
  if (expect_success(spore_context_set_env(context, env_name, env_value)) != 0) return 1;
  SporeOwnedString named_json = {0};
  if (expect_success(spore_list_named_json(context, &named_json)) != 0) return 1;
  if (named_json.ptr == 0 || strcmp(named_json.ptr, "[]\n") != 0) return 1;
  spore_free_string(context, named_json);

  spore_context_free(context);
#endif

  return 0;
}
