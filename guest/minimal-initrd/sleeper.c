#include <stdio.h>
#include <unistd.h>

int main(void) {
  puts("spore run ready");
  fflush(stdout);
  unsigned long i = 0;
  for (;;) {
    sleep(1);
    printf("spore sleeper tick %lu\n", i++);
    fflush(stdout);
  }
}
