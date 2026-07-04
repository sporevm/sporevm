#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char **next = calloc((size_t)argc + 1, sizeof(char *));
  if (!next) return 127;
  int out = 0;
  next[out++] = "sh";
  for (int i = 1; i < argc; i++) {
    if (i == 1 && strcmp(argv[i], "-lc") == 0) {
      next[out++] = "-c";
    } else if (i == 1 && strcmp(argv[i], "-l") == 0) {
      continue;
    } else {
      next[out++] = argv[i];
    }
  }
  next[out] = NULL;
  execv("/bin/toybox", next);
  fprintf(stderr, "sh: cannot exec /bin/toybox: %s\n", strerror(errno));
  return 127;
}
