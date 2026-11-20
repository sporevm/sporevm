/* Exercise live data, page return and reuse across save/restore/fork. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ns(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) exit(1);
  return (uint64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void check(const unsigned char *p, size_t len, unsigned char value) {
  for (size_t i = 0; i < len; i++) {
    if (p[i] != value) {
      fprintf(stderr, "memory mismatch offset=%zu expected=%u got=%u\n", i,
              (unsigned)value, (unsigned)p[i]);
      exit(1);
    }
  }
}

static unsigned char *allocate(size_t len) {
  void *p = mmap(NULL, len, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) { perror("mmap"); exit(1); }
  return p;
}

int main(int argc, char **argv) {
  size_t mib = argc > 1 ? strtoul(argv[1], NULL, 10) : 256;
  unsigned cycles = argc > 2 ? strtoul(argv[2], NULL, 10) : 3;
  unsigned hold = argc > 3 ? strtoul(argv[3], NULL, 10) : 4;
  if (!mib || mib > 1024 || !cycles || cycles > 100 || hold > 60) return 2;
  size_t len = mib * 1024 * 1024;
  const size_t guard_len = 8 * 1024 * 1024;
  unsigned char *guard = allocate(guard_len);
  memset(guard, 0xd3, guard_len);
  setvbuf(stdout, NULL, _IOLBF, 0);
  for (unsigned cycle = 0; cycle < cycles; cycle++) {
    unsigned char *p = allocate(len);
    uint64_t start = now_ns();
    check(p, len, 0);
    unsigned char pattern = (unsigned char)(0x31 + cycle);
    memset(p, pattern, len);
    check(p, len, pattern);
    uint64_t elapsed = now_ns() - start;
    printf("memreport allocated cycle=%u mib=%zu work_ns=%llu\n", cycle, mib,
           (unsigned long long)elapsed);
    sleep(hold);
    check(p, len, pattern);
    check(guard, guard_len, 0xd3);
    if (munmap(p, len)) { perror("munmap"); return 1; }
    printf("memreport freed cycle=%u\n", cycle);
    sleep(hold);
    check(guard, guard_len, 0xd3);
  }
  puts("memreport verified");
  return munmap(guard, guard_len) != 0;
}
