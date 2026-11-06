#include <stdio.h>
#include <unistd.h>

int main(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n < 1) n = 1;
  printf("spore nproc %ld\n", n);
  return 0;
}
