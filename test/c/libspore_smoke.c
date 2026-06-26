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
  if (abi_version != 1) return 1;

  SporeInspectBundleOptions options;
  spore_inspect_bundle_options_init(&options);
  if (options.size != sizeof(options)) return 1;
  if (options.version != SPORE_INSPECT_BUNDLE_OPTIONS_VERSION) return 1;

#if defined(SPORE_SMOKE_HOST_INFO)
  SporeContext context = 0;
  if (expect_success(spore_context_new(&context)) != 0) return 1;
  if (context == 0) return 1;

  SporeOwnedString json = {0};
  if (expect_success(spore_host_info_json(context, &json)) != 0) return 1;
  if (json.ptr == 0 || json.len == 0) return 1;
  if (strstr(json.ptr, "\"schema\": \"spore.host-info.v1\"") == 0) return 1;

  spore_free_string(context, json);
  spore_context_free(context);
#endif

  return 0;
}
