// Strict request parsing: one newline-terminated JSON object with a known
// type and exactly that type's members, each once.

#include "agent.h"

#define COPY_KIND_SYMLINK SPORE_BUILD_COPY_KIND_SYMLINK
#define COPY_KIND_AUTO SPORE_BUILD_COPY_KIND_AUTO
#define COPY_SOURCE_BUILD_INPUT SPORE_BUILD_COPY_SOURCE_BUILD_INPUT
#define COPY_DESTINATION_FOLLOW SPORE_BUILD_COPY_DESTINATION_FOLLOW
#define COPY_DESTINATION_LINK SPORE_BUILD_COPY_DESTINATION_LINK
#define MAX_BUILD_CONTEXT_COPY_ENTRIES SPORE_BUILD_COPY_MAX_ENTRIES
#define MAX_BUILD_NOFILE 1048576ULL

static int json_token_finished(char c);

static const char *skip_ws(const char *p) {
  while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
  return p;
}

static int json_hex_quad(const char *p, uint32_t *out) {
  uint32_t value = 0;
  for (size_t i = 0; i < 4; i++) {
    unsigned char c = (unsigned char)p[i];
    int digit = c >= '0' && c <= '9' ? c - '0' :
                c >= 'a' && c <= 'f' ? c - 'a' + 10 :
                c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
    if (digit < 0) return -1;
    value = (value << 4) | (uint32_t)digit;
  }
  *out = value;
  return 0;
}

static int append_json_codepoint(char *out, size_t cap, size_t *len, uint32_t codepoint) {
  unsigned char encoded[4];
  size_t encoded_len = 0;
  if (codepoint == 0 || codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff)) return -1;
  if (codepoint <= 0x7f) {
    encoded[0] = (unsigned char)codepoint;
    encoded_len = 1;
  } else if (codepoint <= 0x7ff) {
    encoded[0] = (unsigned char)(0xc0 | (codepoint >> 6));
    encoded[1] = (unsigned char)(0x80 | (codepoint & 0x3f));
    encoded_len = 2;
  } else if (codepoint <= 0xffff) {
    encoded[0] = (unsigned char)(0xe0 | (codepoint >> 12));
    encoded[1] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f));
    encoded[2] = (unsigned char)(0x80 | (codepoint & 0x3f));
    encoded_len = 3;
  } else {
    encoded[0] = (unsigned char)(0xf0 | (codepoint >> 18));
    encoded[1] = (unsigned char)(0x80 | ((codepoint >> 12) & 0x3f));
    encoded[2] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f));
    encoded[3] = (unsigned char)(0x80 | (codepoint & 0x3f));
    encoded_len = 4;
  }
  if (encoded_len >= cap - *len) return -1;
  memcpy(out + *len, encoded, encoded_len);
  *len += encoded_len;
  return 0;
}

static int raw_utf8_sequence_len(const unsigned char *p) {
  unsigned char c = p[0];
  if (c >= 0xc2 && c <= 0xdf) {
    unsigned char c1 = p[1];
    return c1 >= 0x80 && c1 <= 0xbf ? 2 : -1;
  }
  if (c >= 0xe0 && c <= 0xef) {
    unsigned char c1 = p[1];
    if (c1 == '\0') return -1;
    unsigned char c2 = p[2];
    if (c2 < 0x80 || c2 > 0xbf) return -1;
    if (c == 0xe0) return c1 >= 0xa0 && c1 <= 0xbf ? 3 : -1;
    if (c == 0xed) return c1 >= 0x80 && c1 <= 0x9f ? 3 : -1;
    return c1 >= 0x80 && c1 <= 0xbf ? 3 : -1;
  }
  if (c >= 0xf0 && c <= 0xf4) {
    unsigned char c1 = p[1];
    if (c1 == '\0') return -1;
    unsigned char c2 = p[2];
    if (c2 == '\0') return -1;
    unsigned char c3 = p[3];
    if (c2 < 0x80 || c2 > 0xbf || c3 < 0x80 || c3 > 0xbf) return -1;
    if (c == 0xf0) return c1 >= 0x90 && c1 <= 0xbf ? 4 : -1;
    if (c == 0xf4) return c1 >= 0x80 && c1 <= 0x8f ? 4 : -1;
    return c1 >= 0x80 && c1 <= 0xbf ? 4 : -1;
  }
  return -1;
}

static int parse_json_string(const char **cursor, char *out, size_t cap) {
  const char *p = *cursor;
  if (*p != '"') return -1;
  p++;
  size_t len = 0;
  while (*p != '\0' && *p != '"') {
    unsigned char c = (unsigned char)*p++;
    if (c == '\\') {
      c = (unsigned char)*p++;
      switch (c) {
        case '"':
        case '\\':
        case '/':
          break;
        case 'b':
          c = '\b';
          break;
        case 'f':
          c = '\f';
          break;
        case 'n':
          c = '\n';
          break;
        case 'r':
          c = '\r';
          break;
        case 't':
          c = '\t';
          break;
        case 'u': {
          uint32_t codepoint = 0;
          if (json_hex_quad(p, &codepoint) != 0) return -1;
          p += 4;
          if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
            uint32_t low = 0;
            if (p[0] != '\\' || p[1] != 'u' || json_hex_quad(p + 2, &low) != 0 || low < 0xdc00 || low > 0xdfff) return -1;
            p += 6;
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
          } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
            return -1;
          }
          if (append_json_codepoint(out, cap, &len, codepoint) != 0) return -1;
          continue;
        }
        default:
          return -1;
      }
    } else if (c < 0x20) {
      return -1;
    } else if (c >= 0x80) {
      const unsigned char *sequence = (const unsigned char *)(p - 1);
      int sequence_len = raw_utf8_sequence_len(sequence);
      if (sequence_len < 0 || (size_t)sequence_len >= cap - len) return -1;
      memcpy(out + len, sequence, (size_t)sequence_len);
      len += (size_t)sequence_len;
      p += sequence_len - 1;
      continue;
    }
    if (len + 1 >= cap) return -1;
    out[len++] = (char)c;
  }
  if (*p != '"') return -1;
  out[len] = '\0';
  *cursor = p + 1;
  return 0;
}

enum request_stdio {
  REQUEST_STDIO_NULL,
  REQUEST_STDIO_PIPE,
  REQUEST_STDIO_TTY,
};

static int parse_json_u64(const char **cursor, uint64_t *out) {
  const char *p = *cursor;
  if (*p < '0' || *p > '9') return -1;
  if (*p == '0' && p[1] >= '0' && p[1] <= '9') return -1;
  uint64_t value = 0;
  do {
    uint64_t digit = (uint64_t)(*p - '0');
    if (value > (UINT64_MAX - digit) / 10) return -1;
    value = value * 10 + digit;
    p++;
  } while (*p >= '0' && *p <= '9');
  *out = value;
  *cursor = p;
  return 0;
}

static int parse_json_bool(const char **cursor, int *out) {
  const char *p = *cursor;
  if (strncmp(p, "true", 4) == 0 && json_token_finished(p[4])) {
    *out = 1;
    *cursor = p + 4;
    return 0;
  }
  if (strncmp(p, "false", 5) == 0 && json_token_finished(p[5])) {
    *out = 0;
    *cursor = p + 5;
    return 0;
  }
  return -1;
}

static int parse_json_optional_i64(const char **cursor, int *present, int64_t *out) {
  const char *p = *cursor;
  if (strncmp(p, "null", 4) == 0 && json_token_finished(p[4])) {
    *present = 0;
    *out = 0;
    *cursor = p + 4;
    return 0;
  }
  int negative = 0;
  if (*p == '-') {
    negative = 1;
    p++;
  }
  uint64_t magnitude = 0;
  if (parse_json_u64(&p, &magnitude) != 0) return -1;
  if ((!negative && magnitude > INT64_MAX) ||
      (negative && magnitude > (uint64_t)INT64_MAX + 1)) return -1;
  *present = 1;
  *out = negative ? (magnitude == (uint64_t)INT64_MAX + 1 ? INT64_MIN : -(int64_t)magnitude) : (int64_t)magnitude;
  *cursor = p;
  return 0;
}

static int parse_exec_argv_value(const char **cursor, struct run_request *out) {
  const char *p = *cursor;
  if (*p != '[') return -1;
  p++;

  int argc = 0;
  size_t storage_len = 0;
  p = skip_ws(p);
  if (*p == ']') {
    out->argv[0] = NULL;
    *cursor = p + 1;
    return 0;
  }
  for (;;) {
    if (argc >= MAX_ARGC || storage_len >= sizeof(out->arg_storage)) return -1;
    out->argv[argc] = out->arg_storage + storage_len;
    if (parse_json_string(&p, out->argv[argc], sizeof(out->arg_storage) - storage_len) != 0) return -1;
    storage_len += strlen(out->argv[argc]) + 1;
    argc++;

    p = skip_ws(p);
    if (*p == ']') {
      p++;
      break;
    }
    if (*p != ',') return -1;
    p = skip_ws(p + 1);
    if (*p == ']') return -1;
  }
  if (out->argv[0][0] == '\0') return -1;
  out->argv[argc] = NULL;
  *cursor = p;
  return 0;
}

static int parse_exec_env_value(const char **cursor, struct run_request *out) {
  const char *p = *cursor;
  if (*p != '[') return -1;
  p++;

  int envc = 0;
  p = skip_ws(p);
  if (*p == ']') {
    out->envp[0] = NULL;
    *cursor = p + 1;
    return 0;
  }
  for (;;) {
    if (envc >= MAX_ENVC) return -1;
    if (parse_json_string(&p, out->env_storage[envc], MAX_ENV_LEN) != 0) return -1;
    out->envp[envc] = out->env_storage[envc];
    envc++;

    p = skip_ws(p);
    if (*p == ']') {
      p++;
      break;
    }
    if (*p != ',') return -1;
    p = skip_ws(p + 1);
    if (*p == ']') return -1;
  }
  out->envp[envc] = NULL;
  *cursor = p;
  return 0;
}

static int valid_build_cache_key(const char *key) {
  if (strlen(key) != MAX_BUILD_CACHE_KEY_LEN) return 0;
  for (size_t i = 0; i < MAX_BUILD_CACHE_KEY_LEN; i++) {
    if (!((key[i] >= '0' && key[i] <= '9') || (key[i] >= 'a' && key[i] <= 'f'))) return 0;
  }
  return 1;
}

static int valid_build_cache_target(const char *target) {
  size_t len = strlen(target);
  if (len < 2 || len > MAX_COPY_PATH_LEN || target[0] != '/' || target[len - 1] == '/') return 0;
  const char *p = target + 1;
  while (*p != '\0') {
    const char *slash = strchr(p, '/');
    size_t part_len = slash ? (size_t)(slash - p) : strlen(p);
    if (part_len == 0 || (part_len == 1 && p[0] == '.') ||
        (part_len == 2 && p[0] == '.' && p[1] == '.')) return 0;
    p += part_len;
    if (*p == '/') p++;
  }
  return 1;
}

static int build_cache_targets_overlap(const char *a, const char *b) {
  size_t a_len = strlen(a);
  size_t b_len = strlen(b);
  if (strcmp(a, b) == 0) return 1;
  if (a_len < b_len && strncmp(a, b, a_len) == 0 && b[a_len] == '/') return 1;
  if (b_len < a_len && strncmp(a, b, b_len) == 0 && a[b_len] == '/') return 1;
  return 0;
}

static int parse_build_cache_mounts_value(const char **cursor, struct run_request *out) {
  const char *p = *cursor;
  if (*p != '[') return -1;
  p = skip_ws(p + 1);
  if (*p == ']') {
    out->build_cache_mount_count = 0;
    *cursor = p + 1;
    return 0;
  }
  size_t count = 0;
  for (;;) {
    if (count >= MAX_BUILD_CACHE_MOUNTS || *p != '{') return -1;
    p++;
    unsigned int seen = 0;
    for (;;) {
      p = skip_ws(p);
      if (*p == '}') {
        p++;
        break;
      }
      char field[16];
      if (parse_json_string(&p, field, sizeof(field)) != 0) return -1;
      p = skip_ws(p);
      if (*p != ':') return -1;
      p = skip_ws(p + 1);
      unsigned int bit = 0;
      if (strcmp(field, "target") == 0) {
        bit = 1u;
        if (parse_json_string(&p, out->build_cache_mounts[count].target,
                              sizeof(out->build_cache_mounts[count].target)) != 0 ||
            !valid_build_cache_target(out->build_cache_mounts[count].target)) return -1;
      } else if (strcmp(field, "key") == 0) {
        bit = 2u;
        if (parse_json_string(&p, out->build_cache_mounts[count].key,
                              sizeof(out->build_cache_mounts[count].key)) != 0 ||
            !valid_build_cache_key(out->build_cache_mounts[count].key)) return -1;
      } else {
        return -1;
      }
      if ((seen & bit) != 0) return -1;
      seen |= bit;
      p = skip_ws(p);
      if (*p == '}') {
        p++;
        break;
      }
      if (*p != ',') return -1;
      p = skip_ws(p + 1);
      if (*p == '}') return -1;
    }
    if (seen != 3u) return -1;
    for (size_t prior = 0; prior < count; prior++) {
      if (build_cache_targets_overlap(out->build_cache_mounts[prior].target,
                                      out->build_cache_mounts[count].target)) return -1;
    }
    count++;
    p = skip_ws(p);
    if (*p == ']') {
      p++;
      break;
    }
    if (*p != ',') return -1;
    p = skip_ws(p + 1);
    if (*p == ']') return -1;
  }
  out->build_cache_mount_count = count;
  *cursor = p;
  return 0;
}

static int valid_build_context_bind_source(const char *source) {
  size_t len = strlen(source);
  if (len == 0 || len > MAX_COPY_PATH_LEN || source[0] == '/' || source[len - 1] == '/') return 0;
  const char *p = source;
  while (*p != '\0') {
    const char *slash = strchr(p, '/');
    size_t part_len = slash ? (size_t)(slash - p) : strlen(p);
    if (part_len == 0 || (part_len == 1 && p[0] == '.') ||
        (part_len == 2 && p[0] == '.' && p[1] == '.')) return 0;
    p += part_len;
    if (*p == '/') p++;
  }
  return 1;
}

static int valid_build_context_bind_target(const char *target) {
  if (!valid_build_cache_target(target)) return 0;
  const char *owned[] = { "/proc", "/dev", "/sys", "/run/sporevm", "/run/buildkit", "/etc/resolv.conf" };
  for (size_t i = 0; i < sizeof(owned) / sizeof(owned[0]); i++) {
    if (build_cache_targets_overlap(target, owned[i])) return 0;
  }
  return 1;
}

static int parse_build_context_binds_value(const char **cursor, struct run_request *out) {
  const char *p = *cursor;
  if (*p != '[') return -1;
  p = skip_ws(p + 1);
  if (*p == ']') {
    out->build_context_bind_count = 0;
    *cursor = p + 1;
    return 0;
  }
  size_t count = 0;
  for (;;) {
    if (count >= MAX_BUILD_CONTEXT_BINDS || *p != '{') return -1;
    p++;
    unsigned int seen = 0;
    for (;;) {
      p = skip_ws(p);
      if (*p == '}') {
        p++;
        break;
      }
      char field[16];
      if (parse_json_string(&p, field, sizeof(field)) != 0) return -1;
      p = skip_ws(p);
      if (*p != ':') return -1;
      p = skip_ws(p + 1);
      unsigned int bit = 0;
      if (strcmp(field, "source") == 0) {
        bit = 1u;
        if (parse_json_string(&p, out->build_context_binds[count].source,
                              sizeof(out->build_context_binds[count].source)) != 0 ||
            !valid_build_context_bind_source(out->build_context_binds[count].source)) return -1;
      } else if (strcmp(field, "target") == 0) {
        bit = 2u;
        if (parse_json_string(&p, out->build_context_binds[count].target,
                              sizeof(out->build_context_binds[count].target)) != 0 ||
            !valid_build_context_bind_target(out->build_context_binds[count].target)) return -1;
      } else {
        return -1;
      }
      if ((seen & bit) != 0) return -1;
      seen |= bit;
      p = skip_ws(p);
      if (*p == '}') {
        p++;
        break;
      }
      if (*p != ',') return -1;
      p = skip_ws(p + 1);
      if (*p == '}') return -1;
    }
    if (seen != 3u) return -1;
    for (size_t prior = 0; prior < count; prior++) {
      if (build_cache_targets_overlap(out->build_context_binds[prior].target,
                                      out->build_context_binds[count].target)) return -1;
    }
    count++;
    p = skip_ws(p);
    if (*p == ']') {
      p++;
      break;
    }
    if (*p != ',') return -1;
    p = skip_ws(p + 1);
    if (*p == ']') return -1;
  }
  out->build_context_bind_count = count;
  *cursor = p;
  return 0;
}

static int json_token_finished(char c) {
  return c == '\0' || c == ',' || c == '}' || c == ']' || c == ' ' || c == '\n' || c == '\r' || c == '\t';
}

// Reads an object member's key and the colon, leaving the cursor at its value.
static int parse_json_key(const char **cursor, char *key, size_t cap) {
  if (parse_json_string(cursor, key, cap) != 0) return -1;
  const char *p = skip_ws(*cursor);
  if (*p != ':') return -1;
  *cursor = skip_ws(p + 1);
  return 0;
}

static int skip_json_number(const char **cursor) {
  const char *p = *cursor;
  if (*p == '-') p++;
  if (*p == '0') {
    p++;
  } else if (*p >= '1' && *p <= '9') {
    while (*p >= '0' && *p <= '9') p++;
  } else {
    return -1;
  }
  if (*p == '.') {
    p++;
    if (*p < '0' || *p > '9') return -1;
    while (*p >= '0' && *p <= '9') p++;
  }
  if (*p == 'e' || *p == 'E') {
    p++;
    if (*p == '+' || *p == '-') p++;
    if (*p < '0' || *p > '9') return -1;
    while (*p >= '0' && *p <= '9') p++;
  }
  if (!json_token_finished(*p)) return -1;
  *cursor = p;
  return 0;
}

// Skips one JSON value of any type, validating it. Containers nest without
// recursion, up to one level per byte of generation params. Strings decode
// into scratch, which must hold any string in the input.
static int skip_json_value(const char **cursor, char *scratch, size_t scratch_cap) {
  char open[GEN_PARAMS_MAX];
  size_t depth = 0;
  const char *p = *cursor;
  for (;;) {
    if (*p == '{' || *p == '[') {
      if (depth == sizeof(open)) return -1;
      char kind = *p;
      open[depth++] = kind;
      p = skip_ws(p + 1);
      if (*p != (kind == '{' ? '}' : ']')) {
        if (kind == '{' && parse_json_key(&p, scratch, scratch_cap) != 0) return -1;
        continue;
      }
      p++;
      depth--;
    } else if (*p == '"') {
      if (parse_json_string(&p, scratch, scratch_cap) != 0) return -1;
    } else if (*p == 't' || *p == 'f') {
      int ignored = 0;
      if (parse_json_bool(&p, &ignored) != 0) return -1;
    } else if (strncmp(p, "null", 4) == 0 && json_token_finished(p[4])) {
      p += 4;
    } else if (skip_json_number(&p) != 0) {
      return -1;
    }
    // After a value: close finished containers, or move to the next element.
    for (;;) {
      if (depth == 0) {
        *cursor = p;
        return 0;
      }
      p = skip_ws(p);
      if (*p == (open[depth - 1] == '{' ? '}' : ']')) {
        p++;
        depth--;
        continue;
      }
      if (*p != ',') return -1;
      p = skip_ws(p + 1);
      if (open[depth - 1] == '{' && parse_json_key(&p, scratch, scratch_cap) != 0) return -1;
      break;
    }
  }
}

static const struct generation_member_spec {
  const char *name;
  size_t offset;
  int text;
} generation_members[GENERATION_MEMBER_COUNT] = {
  [GENERATION_FORK_INDEX] = {"fork_index", offsetof(struct generation_params, fork_index), 0},
  [GENERATION_FORK_COUNT] = {"fork_count", offsetof(struct generation_params, fork_count), 0},
  [GENERATION_PARALLEL_INDEX] = {"parallel_index", offsetof(struct generation_params, parallel_index), 0},
  [GENERATION_PARALLEL_COUNT] = {"parallel_count", offsetof(struct generation_params, parallel_count), 0},
  [GENERATION_PARENT_GENERATION] = {"parent_generation", offsetof(struct generation_params, parent_generation), 0},
  [GENERATION_GENERATION] = {"generation", offsetof(struct generation_params, generation), 0},
  [GENERATION_RESUME_TIME] = {"resume_time_unix_ns", offsetof(struct generation_params, resume_time_unix_ns), 0},
  [GENERATION_VM_ID] = {"vm_id", offsetof(struct generation_params, vm_id), 1},
  [GENERATION_FORK_BATCH_ID] = {"fork_batch_id", offsetof(struct generation_params, fork_batch_id), 1},
  [GENERATION_HOSTNAME] = {"hostname", offsetof(struct generation_params, hostname), 1},
  [GENERATION_RESUME_ENTROPY_SEED] = {"resume_entropy_seed", offsetof(struct generation_params, resume_entropy_seed), 1},
};

// Generation params, from the generation device or a request's params_json,
// are one JSON object. The members the agent reads must have their type and
// appear at most once; other members, such as the host's run_id and
// mac_address, may hold any JSON value and are skipped.
int parse_generation_params(const char *params, struct generation_params *out) {
  memset(out, 0, sizeof(*out));
  if (strlen(params) >= GEN_PARAMS_MAX) return -1;
  char scratch[GEN_PARAMS_MAX];
  const char *p = skip_ws(params);
  if (*p != '{') return -1;
  p = skip_ws(p + 1);
  if (*p == '}') return *skip_ws(p + 1) == '\0' ? 0 : -1;
  for (;;) {
    if (parse_json_key(&p, scratch, sizeof(scratch)) != 0) return -1;
    int member = GENERATION_MEMBER_COUNT;
    for (int i = 0; i < GENERATION_MEMBER_COUNT; i++) {
      if (strcmp(scratch, generation_members[i].name) == 0) member = i;
    }
    if (member == GENERATION_MEMBER_COUNT) {
      if (skip_json_value(&p, scratch, sizeof(scratch)) != 0) return -1;
    } else {
      const struct generation_member_spec *spec = &generation_members[member];
      if ((out->present & (1u << member)) != 0) return -1;
      void *field = (char *)out + spec->offset;
      int rc = spec->text ? parse_json_string(&p, field, GENERATION_TEXT_MAX) : parse_json_u64(&p, field);
      if (rc != 0) return -1;
      out->present |= 1u << member;
    }
    p = skip_ws(p);
    if (*p == '}') break;
    if (*p != ',') return -1;
    p = skip_ws(p + 1);
  }
  return *skip_ws(p + 1) == '\0' ? 0 : -1;
}

// Every request is one newline-terminated JSON object with a known type and
// exactly that type's members, each once. parse_request walks the object once,
// parsing each member into run_request, then checks the member set against
// the type and applies the per-kind rules below.
enum request_member {
  MEMBER_TYPE,
  MEMBER_SESSION_ID,
  MEMBER_RESUME_TIME,
  MEMBER_ARGV,
  MEMBER_ENV,
  MEMBER_WORKING_DIR,
  MEMBER_STDIO,
  MEMBER_TERM,
  MEMBER_TERMINAL_ROWS,
  MEMBER_TERMINAL_COLS,
  MEMBER_INTERACTIVE,
  MEMBER_MEMORY_PRESSURE,
  MEMBER_PARAMS_JSON,
  MEMBER_REQUIRE_GENERATION_READY,
  MEMBER_DETACHED,
  MEMBER_RETAIN_OUTPUT,
  MEMBER_CLOSED_ENV,
  MEMBER_STDOUT_OFFSET,
  MEMBER_STDERR_OFFSET,
  MEMBER_PATH,
  MEMBER_COMMAND_LEN,
  MEMBER_CACHE_MOUNTS,
  MEMBER_CONTEXT_BINDS,
  MEMBER_NOFILE_SOFT,
  MEMBER_NOFILE_HARD,
  MEMBER_SOURCE,
  MEMBER_DEST,
  MEMBER_SOURCE_KIND,
  MEMBER_DEST_IS_DIR,
  MEMBER_ENTRY_COUNT,
  MEMBER_SOURCE_DISK,
  MEMBER_INPUT_INDEX,
  MEMBER_MTIME,
  MEMBER_DESTINATION_POLICY,
  MEMBER_COUNT,
};

static const char *const request_member_names[MEMBER_COUNT] = {
  [MEMBER_TYPE] = "type",
  [MEMBER_SESSION_ID] = "session_id",
  [MEMBER_RESUME_TIME] = "resume_time_unix_ns",
  [MEMBER_ARGV] = "argv",
  [MEMBER_ENV] = "env",
  [MEMBER_WORKING_DIR] = "working_dir",
  [MEMBER_STDIO] = "stdio",
  [MEMBER_TERM] = "term",
  [MEMBER_TERMINAL_ROWS] = "terminal_rows",
  [MEMBER_TERMINAL_COLS] = "terminal_cols",
  [MEMBER_INTERACTIVE] = "interactive",
  [MEMBER_MEMORY_PRESSURE] = "memory_pressure",
  [MEMBER_PARAMS_JSON] = "params_json",
  [MEMBER_REQUIRE_GENERATION_READY] = "require_generation_ready",
  [MEMBER_DETACHED] = "detached",
  [MEMBER_RETAIN_OUTPUT] = "retain_output",
  [MEMBER_CLOSED_ENV] = "closed_env",
  [MEMBER_STDOUT_OFFSET] = "stdout_offset",
  [MEMBER_STDERR_OFFSET] = "stderr_offset",
  [MEMBER_PATH] = "path",
  [MEMBER_COMMAND_LEN] = "command_len",
  [MEMBER_CACHE_MOUNTS] = "cache_mounts",
  [MEMBER_CONTEXT_BINDS] = "context_binds",
  [MEMBER_NOFILE_SOFT] = "nofile_soft",
  [MEMBER_NOFILE_HARD] = "nofile_hard",
  [MEMBER_SOURCE] = "source",
  [MEMBER_DEST] = "dest",
  [MEMBER_SOURCE_KIND] = "source_kind",
  [MEMBER_DEST_IS_DIR] = "dest_is_dir",
  [MEMBER_ENTRY_COUNT] = "entry_count",
  [MEMBER_SOURCE_DISK] = "source_disk",
  [MEMBER_INPUT_INDEX] = "input_index",
  [MEMBER_MTIME] = "mtime_unix_seconds",
  [MEMBER_DESTINATION_POLICY] = "destination_policy",
};

#define MEMBER(name) (UINT64_C(1) << MEMBER_##name)
#define EXEC_STDIO_MEMBERS (MEMBER(STDIO) | MEMBER(TERMINAL_ROWS) | MEMBER(TERMINAL_COLS))

static const struct request_spec {
  const char *type;
  enum request_kind kind;
  uint64_t members;
} request_specs[] = {
  {"ready", REQUEST_READY, MEMBER(TYPE)},
  {"start-v1", REQUEST_START,
   MEMBER(TYPE) | MEMBER(SESSION_ID) | MEMBER(RESUME_TIME) | MEMBER(ARGV) | MEMBER(ENV) | MEMBER(WORKING_DIR) |
       EXEC_STDIO_MEMBERS | MEMBER(MEMORY_PRESSURE) | MEMBER(PARAMS_JSON) | MEMBER(REQUIRE_GENERATION_READY) |
       MEMBER(DETACHED) | MEMBER(RETAIN_OUTPUT) | MEMBER(CLOSED_ENV)},
  {"attach-v1", REQUEST_ATTACH,
   MEMBER(TYPE) | MEMBER(SESSION_ID) | MEMBER(STDOUT_OFFSET) | MEMBER(STDERR_OFFSET) | EXEC_STDIO_MEMBERS |
       MEMBER(INTERACTIVE) | MEMBER(PARAMS_JSON)},
  {"initial-output", REQUEST_INITIAL_OUTPUT, MEMBER(TYPE)},
  {"copy-in-v1", REQUEST_COPY_IN, MEMBER(TYPE) | MEMBER(SESSION_ID) | MEMBER(PATH)},
  {"copy-out-v1", REQUEST_COPY_OUT, MEMBER(TYPE) | MEMBER(SESSION_ID) | MEMBER(PATH)},
  {"spore-build-run-v4", REQUEST_BUILD_RUN,
   MEMBER(TYPE) | MEMBER(SESSION_ID) | MEMBER(RESUME_TIME) | MEMBER(COMMAND_LEN) | MEMBER(ARGV) | MEMBER(ENV) |
       MEMBER(WORKING_DIR) | MEMBER(CACHE_MOUNTS) | MEMBER(CONTEXT_BINDS) | EXEC_STDIO_MEMBERS | MEMBER(TERM) |
       MEMBER(MEMORY_PRESSURE) | MEMBER(NOFILE_SOFT) | MEMBER(NOFILE_HARD) | MEMBER(CLOSED_ENV)},
  {"spore-build-copy-v5", REQUEST_BUILD_COPY,
   MEMBER(TYPE) | MEMBER(SESSION_ID) | MEMBER(SOURCE) | MEMBER(DEST) | MEMBER(SOURCE_KIND) | MEMBER(DEST_IS_DIR) |
       MEMBER(ENTRY_COUNT) | MEMBER(SOURCE_DISK) | MEMBER(INPUT_INDEX) | MEMBER(MTIME) | MEMBER(DESTINATION_POLICY)},
  {"spore-build-workdir-v1", REQUEST_BUILD_WORKDIR, MEMBER(TYPE) | MEMBER(SESSION_ID) | MEMBER(WORKING_DIR)},
  {"spore-rootfs-grow-v1", REQUEST_ROOTFS_GROW, MEMBER(TYPE) | MEMBER(SESSION_ID)},
  {"fsfreeze-v1", REQUEST_FSFREEZE, MEMBER(TYPE) | MEMBER(SESSION_ID)},
  {"fsthaw-v1", REQUEST_FSTHAW, MEMBER(TYPE) | MEMBER(SESSION_ID)},
};

static int parse_terminal_dimension(const char **cursor, uint16_t *out) {
  uint64_t value = 0;
  if (parse_json_u64(cursor, &value) != 0 || value == 0 || value > UINT16_MAX) return -1;
  *out = (uint16_t)value;
  return 0;
}

static int parse_request_member(enum request_member member, const char **cursor, struct run_request *out, char *type, size_t type_cap) {
  const char **p = cursor;
  switch (member) {
  case MEMBER_TYPE:
    return parse_json_string(p, type, type_cap);
  case MEMBER_SESSION_ID:
    return parse_json_string(p, out->session_id, sizeof(out->session_id)) != 0 || out->session_id[0] == '\0' ? -1 : 0;
  case MEMBER_RESUME_TIME:
    return parse_json_u64(p, &out->resume_time_unix_ns);
  case MEMBER_ARGV:
    return parse_exec_argv_value(p, out);
  case MEMBER_ENV:
    return parse_exec_env_value(p, out);
  case MEMBER_WORKING_DIR:
    return parse_json_string(p, out->working_dir, sizeof(out->working_dir));
  case MEMBER_STDIO: {
    char stdio[8];
    if (parse_json_string(p, stdio, sizeof(stdio)) != 0) return -1;
    if (strcmp(stdio, "null") == 0) out->stdio = REQUEST_STDIO_NULL;
    else if (strcmp(stdio, "pipe") == 0) out->stdio = REQUEST_STDIO_PIPE;
    else if (strcmp(stdio, "tty") == 0) out->stdio = REQUEST_STDIO_TTY;
    else return -1;
    return 0;
  }
  case MEMBER_TERM: {
    // Only build RUN carries term, and it is always xterm.
    char term[8];
    return parse_json_string(p, term, sizeof(term)) != 0 || strcmp(term, "xterm") != 0 ? -1 : 0;
  }
  case MEMBER_TERMINAL_ROWS:
    return parse_terminal_dimension(p, &out->terminal_rows);
  case MEMBER_TERMINAL_COLS:
    return parse_terminal_dimension(p, &out->terminal_cols);
  case MEMBER_INTERACTIVE:
    return parse_json_bool(p, &out->interactive);
  case MEMBER_MEMORY_PRESSURE:
    return parse_json_bool(p, &out->memory_pressure);
  case MEMBER_PARAMS_JSON:
    return parse_json_string(p, out->generation_params, sizeof(out->generation_params));
  case MEMBER_REQUIRE_GENERATION_READY:
    return parse_json_bool(p, &out->require_generation_ready);
  case MEMBER_DETACHED:
    return parse_json_bool(p, &out->detached);
  case MEMBER_RETAIN_OUTPUT:
    return parse_json_bool(p, &out->retain_output);
  case MEMBER_CLOSED_ENV: {
    int value = 0;
    return parse_json_bool(p, &value) != 0 || !value ? -1 : 0;
  }
  case MEMBER_STDOUT_OFFSET:
    return parse_json_u64(p, &out->stdout_offset);
  case MEMBER_STDERR_OFFSET:
    return parse_json_u64(p, &out->stderr_offset);
  case MEMBER_PATH:
    return parse_json_string(p, out->copy_path, sizeof(out->copy_path));
  case MEMBER_COMMAND_LEN:
    return parse_json_u64(p, &out->build_command_len) != 0 || out->build_command_len > MAX_BUILD_RUN_COMMAND_LEN ? -1 : 0;
  case MEMBER_CACHE_MOUNTS:
    return parse_build_cache_mounts_value(p, out);
  case MEMBER_CONTEXT_BINDS:
    return parse_build_context_binds_value(p, out);
  case MEMBER_NOFILE_SOFT:
    return parse_json_u64(p, &out->nofile_soft);
  case MEMBER_NOFILE_HARD:
    return parse_json_u64(p, &out->nofile_hard);
  case MEMBER_SOURCE:
    return parse_json_string(p, out->copy_source, sizeof(out->copy_source)) != 0 || out->copy_source[0] == '\0' ? -1 : 0;
  case MEMBER_DEST:
    return parse_json_string(p, out->copy_dest, sizeof(out->copy_dest)) != 0 || out->copy_dest[0] != '/' ? -1 : 0;
  case MEMBER_SOURCE_KIND: {
    char source_kind[16];
    if (parse_json_string(p, source_kind, sizeof(source_kind)) != 0) return -1;
    if (strcmp(source_kind, "directory") == 0) out->copy_source_kind = COPY_KIND_DIR;
    else if (strcmp(source_kind, "file") == 0) out->copy_source_kind = COPY_KIND_FILE;
    else if (strcmp(source_kind, "sym_link") == 0) out->copy_source_kind = COPY_KIND_SYMLINK;
    else if (strcmp(source_kind, "auto") == 0) out->copy_source_kind = COPY_KIND_AUTO;
    else return -1;
    return 0;
  }
  case MEMBER_DEST_IS_DIR:
    return parse_json_bool(p, &out->copy_dest_is_dir);
  case MEMBER_ENTRY_COUNT:
    return parse_json_u64(p, &out->copy_entry_count) != 0 || out->copy_entry_count > MAX_BUILD_CONTEXT_COPY_ENTRIES ? -1 : 0;
  case MEMBER_SOURCE_DISK: {
    char source_disk[24];
    if (parse_json_string(p, source_disk, sizeof(source_disk)) != 0) return -1;
    if (strcmp(source_disk, "context") == 0) out->copy_source_disk = COPY_SOURCE_CONTEXT;
    else if (strcmp(source_disk, "build_input") == 0) out->copy_source_disk = COPY_SOURCE_BUILD_INPUT;
    else return -1;
    return 0;
  }
  case MEMBER_INPUT_INDEX:
    return parse_json_u64(p, &out->copy_input_index) != 0 || out->copy_input_index >= MAX_BUILD_INPUT_DISKS ? -1 : 0;
  case MEMBER_MTIME:
    return parse_json_optional_i64(p, &out->copy_mtime_present, &out->copy_mtime_unix_seconds);
  case MEMBER_DESTINATION_POLICY: {
    char destination_policy[16];
    if (parse_json_string(p, destination_policy, sizeof(destination_policy)) != 0) return -1;
    if (strcmp(destination_policy, "follow") == 0) out->copy_destination_policy = COPY_DESTINATION_FOLLOW;
    else if (strcmp(destination_policy, "link") == 0) out->copy_destination_policy = COPY_DESTINATION_LINK;
    else return -1;
    return 0;
  }
  case MEMBER_COUNT:
    break;
  }
  return -1;
}

// start-v1 and attach-v1 select the session's stdio. A pipe carries host
// stdin, a tty gives the command a PTY, and null leaves stdin at /dev/null.
static int apply_exec_stdio(struct run_request *out) {
  out->stdin_enabled = out->stdio == REQUEST_STDIO_PIPE;
  out->tty = out->stdio == REQUEST_STDIO_TTY;
  return 0;
}

// Shell form streams command_len bytes after the request and sends an empty
// argv; exec form sends argv with command_len 0. Context binds are shell-only,
// matching the host planner. The session and terminal members are fixed.
static int validate_build_run_request(struct run_request *out) {
  if (out->working_dir[0] != '/' || out->stdio != REQUEST_STDIO_PIPE ||
      out->terminal_rows != 24 || out->terminal_cols != 80 || out->memory_pressure) return -1;
  if (out->nofile_soft == 0 || out->nofile_soft > out->nofile_hard || out->nofile_hard > MAX_BUILD_NOFILE) return -1;
  size_t decoded_len = 0;
  for (size_t i = 0; out->argv[i] != NULL; i++) decoded_len += strlen(out->argv[i]);
  if (decoded_len > MAX_BUILD_EXEC_ARGS_BYTES) return -1;
  out->build_exec_form = out->argv[0] != NULL;
  if (out->build_exec_form && (out->build_command_len != 0 || out->build_context_bind_count != 0)) return -1;
  if (!out->build_exec_form && out->build_command_len == 0) return -1;
  for (size_t i = 0; i < out->build_context_bind_count; i++) {
    for (size_t j = 0; j < out->build_cache_mount_count; j++) {
      if (build_cache_targets_overlap(out->build_context_binds[i].target,
                                      out->build_cache_mounts[j].target)) return -1;
    }
  }
  return 0;
}

static int validate_build_copy_request(const struct run_request *out) {
  if (out->copy_source_disk == COPY_SOURCE_CONTEXT) {
    if (out->copy_source_kind == COPY_KIND_AUTO || out->copy_entry_count == 0 || out->copy_input_index != 0) return -1;
  } else if (out->copy_source_kind != COPY_KIND_AUTO || out->copy_entry_count != 0) {
    return -1;
  }
  if (out->copy_destination_policy == COPY_DESTINATION_LINK && out->copy_source_disk != COPY_SOURCE_BUILD_INPUT) return -1;
  return 0;
}

static int validate_request(struct run_request *out) {
  switch (out->kind) {
  case REQUEST_START:
    if (out->argv[0] == NULL) return -1;
    if (out->working_dir[0] != '\0' && out->working_dir[0] != '/') return -1;
    if (out->retain_output && !out->detached) return -1;
    if (out->detached && out->stdio != REQUEST_STDIO_NULL) return -1;
    return apply_exec_stdio(out);
  case REQUEST_ATTACH:
    if (out->stdio == REQUEST_STDIO_PIPE && !out->interactive) return -1;
    if (out->stdio == REQUEST_STDIO_NULL && out->interactive) return -1;
    return apply_exec_stdio(out);
  case REQUEST_BUILD_WORKDIR:
    return out->working_dir[0] == '/' ? 0 : -1;
  case REQUEST_BUILD_RUN:
    return validate_build_run_request(out);
  case REQUEST_BUILD_COPY:
    return validate_build_copy_request(out);
  default:
    return 0;
  }
}

int parse_request(const char *req, size_t req_len, struct run_request *out) {
  if (req_len == 0 || strlen(req) != req_len || req[req_len - 1] != '\n') return -1;
  memset(out, 0, sizeof(*out));

  const char *p = skip_ws(req);
  if (*p != '{') return -1;
  p = skip_ws(p + 1);
  char type[32];
  type[0] = '\0';
  uint64_t seen = 0;
  for (;;) {
    char key[32];
    if (parse_json_string(&p, key, sizeof(key)) != 0) return -1;
    p = skip_ws(p);
    if (*p != ':') return -1;
    p = skip_ws(p + 1);
    enum request_member member = MEMBER_COUNT;
    for (int i = 0; i < MEMBER_COUNT; i++) {
      if (strcmp(key, request_member_names[i]) == 0) member = (enum request_member)i;
    }
    if (member == MEMBER_COUNT || (seen & (UINT64_C(1) << member)) != 0) return -1;
    if (parse_request_member(member, &p, out, type, sizeof(type)) != 0) return -1;
    seen |= UINT64_C(1) << member;
    p = skip_ws(p);
    if (*p == '}') break;
    if (*p != ',') return -1;
    p = skip_ws(p + 1);
  }
  if (*skip_ws(p + 1) != '\0') return -1;

  for (size_t i = 0; i < sizeof(request_specs) / sizeof(request_specs[0]); i++) {
    if (strcmp(type, request_specs[i].type) != 0) continue;
    if (seen != request_specs[i].members) return -1;
    out->kind = request_specs[i].kind;
    return validate_request(out);
  }
  return -1;
}

#ifdef SPORE_AGENT_REQUEST_FUZZ
enum spore_agent_fuzz_result {
  SPORE_AGENT_FUZZ_INVALID = 0,
  SPORE_AGENT_FUZZ_RUN_REQUEST = 1,
  SPORE_AGENT_FUZZ_COPY_REQUEST = 2,
  SPORE_AGENT_FUZZ_RUN_COMPLETE = 3,
  SPORE_AGENT_FUZZ_WORKDIR_REQUEST = 4,
  SPORE_AGENT_FUZZ_READY_REQUEST = 5,
  SPORE_AGENT_FUZZ_GROW_REQUEST = 6,
  SPORE_AGENT_FUZZ_OTHER_REQUEST = 7,
  SPORE_AGENT_FUZZ_START_REQUEST = 8,
  SPORE_AGENT_FUZZ_ATTACH_REQUEST = 9,
};

__attribute__((visibility("hidden"))) int spore_agent_fuzz_build_request(
    const unsigned char *request_bytes, size_t request_len,
    const unsigned char *stream_bytes, size_t stream_len) {
  if (request_len >= MAX_REQUEST || stream_len > MAX_FRAME_PAYLOAD) return SPORE_AGENT_FUZZ_INVALID;
  char request[MAX_REQUEST];
  memcpy(request, request_bytes, request_len);
  request[request_len] = '\0';

  struct run_request parsed;
  if (parse_request(request, request_len, &parsed) != 0) return SPORE_AGENT_FUZZ_INVALID;
  if (parsed.kind == REQUEST_READY) return SPORE_AGENT_FUZZ_READY_REQUEST;
  if (parsed.kind == REQUEST_BUILD_COPY) return SPORE_AGENT_FUZZ_COPY_REQUEST;
  if (parsed.kind == REQUEST_BUILD_WORKDIR) return SPORE_AGENT_FUZZ_WORKDIR_REQUEST;
  if (parsed.kind == REQUEST_ROOTFS_GROW) return SPORE_AGENT_FUZZ_GROW_REQUEST;
  if (parsed.kind == REQUEST_START || parsed.kind == REQUEST_ATTACH) {
    if (parsed.generation_params[0] != '\0') {
      struct generation_params params;
      (void)parse_generation_params(parsed.generation_params, &params);
    }
    return parsed.kind == REQUEST_START ? SPORE_AGENT_FUZZ_START_REQUEST : SPORE_AGENT_FUZZ_ATTACH_REQUEST;
  }
  if (parsed.kind != REQUEST_BUILD_RUN) return SPORE_AGENT_FUZZ_OTHER_REQUEST;
  if (parsed.build_exec_form) return SPORE_AGENT_FUZZ_RUN_COMPLETE;

  int pipe_fds[2];
  if (pipe2(pipe_fds, O_CLOEXEC) != 0) return SPORE_AGENT_FUZZ_RUN_REQUEST;
  if (stream_len > 0 && write_all(pipe_fds[1], stream_bytes, stream_len) != 0) {
    close(pipe_fds[0]);
    close(pipe_fds[1]);
    return SPORE_AGENT_FUZZ_RUN_REQUEST;
  }
  close(pipe_fds[1]);

  struct client client;
  memset(&client, 0, sizeof(client));
  client.fd = pipe_fds[0];
  char command[MAX_BUILD_RUN_COMMAND_LEN + 1];
  char error[256];
  int rc = read_build_command_from_spio(&client, parsed.build_command_len, command, sizeof(command), error, sizeof(error));
  close(pipe_fds[0]);
  return rc == 0 ? SPORE_AGENT_FUZZ_RUN_COMPLETE : SPORE_AGENT_FUZZ_RUN_REQUEST;
}

// The largest value each request bound accepts, for the host parity test.
struct spore_agent_request_limits {
  uint64_t request_bytes;
  uint64_t argc;
  uint64_t exec_args_bytes;
  uint64_t shell_command_bytes;
  uint64_t envc;
  uint64_t env_bytes;
  uint64_t working_dir_bytes;
  uint64_t cache_mounts;
  uint64_t context_binds;
  uint64_t copy_path_bytes;
  uint64_t copy_entries;
  uint64_t build_input_disks;
  uint64_t nofile;
  uint64_t session_id_bytes;
  uint64_t generation_params_bytes;
  uint64_t frame_payload_bytes;
  uint64_t initial_output_bytes;
  uint64_t output_read_bytes;
  uint64_t replay_bytes;
};

__attribute__((visibility("hidden"))) void spore_agent_test_request_limits(struct spore_agent_request_limits *out) {
  // read_line and parse_json_string keep one byte of each buffer for the NUL.
  out->request_bytes = MAX_REQUEST - 1;
  out->argc = MAX_ARGC;
  out->exec_args_bytes = MAX_BUILD_EXEC_ARGS_BYTES;
  out->shell_command_bytes = MAX_BUILD_RUN_COMMAND_LEN;
  out->envc = MAX_ENVC;
  out->env_bytes = MAX_ENV_LEN - 1;
  out->working_dir_bytes = MAX_WORKDIR_LEN - 1;
  out->cache_mounts = MAX_BUILD_CACHE_MOUNTS;
  out->context_binds = MAX_BUILD_CONTEXT_BINDS;
  // Also bounds cache-mount targets and context-bind paths.
  out->copy_path_bytes = MAX_COPY_PATH_LEN;
  out->copy_entries = MAX_BUILD_CONTEXT_COPY_ENTRIES;
  out->build_input_disks = MAX_BUILD_INPUT_DISKS;
  out->nofile = MAX_BUILD_NOFILE;
  out->session_id_bytes = sizeof(((struct run_request *)0)->session_id) - 1;
  out->generation_params_bytes = sizeof(((struct run_request *)0)->generation_params) - 1;
  out->frame_payload_bytes = MAX_FRAME_PAYLOAD;
  out->initial_output_bytes = INITIAL_OUTPUT_CAP;
  out->output_read_bytes = SPIO_BATCH_FRAMES * MAX_FRAME_PAYLOAD;
  out->replay_bytes = REPLAY_CAP;
}

// Returns -1 when the params are refused, 1 with *generation set when they
// carry a generation, and 0 otherwise. Parsed params also set *fork_index and
// vm_id (a GENERATION_TEXT_MAX buffer), to 0 and "" when absent.
__attribute__((visibility("hidden"))) int spore_agent_test_generation_params(
    const unsigned char *params_bytes, size_t params_len, uint64_t *generation, uint64_t *fork_index, char *vm_id) {
  if (params_len >= GEN_PARAMS_MAX) return -1;
  char params[GEN_PARAMS_MAX];
  memcpy(params, params_bytes, params_len);
  params[params_len] = '\0';
  struct generation_params parsed;
  if (parse_generation_params(params, &parsed) != 0) return -1;
  *fork_index = parsed.fork_index;
  memcpy(vm_id, parsed.vm_id, sizeof(parsed.vm_id));
  if ((parsed.present & (1u << GENERATION_GENERATION)) == 0) return 0;
  *generation = parsed.generation;
  return 1;
}

__attribute__((visibility("hidden"))) int spore_agent_fuzz_exec_arg_equals(
    const unsigned char *request_bytes, size_t request_len, size_t arg_index,
    const unsigned char *expected, size_t expected_len) {
  if (request_len >= MAX_REQUEST || arg_index >= MAX_ARGC) return 0;
  char request[MAX_REQUEST];
  memcpy(request, request_bytes, request_len);
  request[request_len] = '\0';

  struct run_request parsed;
  if (parse_request(request, request_len, &parsed) != 0 || !parsed.build_exec_form || parsed.argv[arg_index] == NULL) return 0;
  size_t actual_len = strlen(parsed.argv[arg_index]);
  return actual_len == expected_len && memcmp(parsed.argv[arg_index], expected, expected_len) == 0;
}
#endif
