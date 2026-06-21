#include <stdio.h>
#include <unistd.h>

int main(void) {
  puts("spore finite ready");
  fflush(stdout);
  for (int i = 0; i < 3; i++) {
    sleep(1);
    printf("spore finite tick %d\n", i);
    fflush(stdout);
  }
  puts("spore finite done");
  fflush(stdout);
  return 0;
}
