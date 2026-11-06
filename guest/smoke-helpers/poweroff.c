#include <stdio.h>
#include <stdlib.h>
#include <sys/reboot.h>
#include <unistd.h>

int main(int argc, char **argv) {
  unsigned int seconds = argc > 1 ? (unsigned int)strtoul(argv[1], NULL, 10) : 0;
  puts("spore poweroff ready");
  fflush(stdout);
  sleep(seconds);
  reboot(RB_POWER_OFF);
  perror("poweroff: reboot");
  return 1;
}
