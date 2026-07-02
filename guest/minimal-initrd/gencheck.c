#include <stdio.h>
#include <string.h>

static int read_env_value(const char *key, char *out, size_t out_len) {
  FILE *f = fopen("/run/sporevm/env", "r");
  if (f == NULL) return 0;
  char line[256];
  size_t key_len = strlen(key);
  int found = 0;
  while (fgets(line, sizeof(line), f) != NULL) {
    if (strncmp(line, key, key_len) != 0 || line[key_len] != '=') continue;
    snprintf(out, out_len, "%s", line + key_len + 1);
    out[strcspn(out, "\r\n")] = '\0';
    found = out[0] != '\0';
    break;
  }
  fclose(f);
  return found;
}

int main(void) {
  char generation[32];
  char vm_id[96];
  char entropy[96];
  if (!read_env_value("SPORE_GENERATION", generation, sizeof(generation)) ||
      !read_env_value("SPORE_VM_ID", vm_id, sizeof(vm_id)) ||
      !read_env_value("SPORE_RESUME_ENTROPY_SEED", entropy, sizeof(entropy))) {
    fputs("spore generation metadata missing\n", stderr);
    return 1;
  }
  printf("spore generation ready generation=%s vm_id=%s entropy_len=%zu\n", generation, vm_id, strlen(entropy));
  return 0;
}
