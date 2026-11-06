#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int read_parallel_env(char *job, size_t job_len, char *count, size_t count_len) {
  FILE *f = fopen("/run/sporevm/env", "r");
  if (f == NULL) return 0;
  char line[128];
  int have_job = 0;
  int have_count = 0;
  while (fgets(line, sizeof(line), f) != NULL) {
    const char *job_key = "SPORE_PARALLEL_JOB=";
    const char *count_key = "SPORE_PARALLEL_JOB_COUNT=";
    if (strncmp(line, job_key, strlen(job_key)) == 0) {
      snprintf(job, job_len, "%s", line + strlen(job_key));
      job[strcspn(job, "\r\n")] = '\0';
      have_job = 1;
    } else if (strncmp(line, count_key, strlen(count_key)) == 0) {
      snprintf(count, count_len, "%s", line + strlen(count_key));
      count[strcspn(count, "\r\n")] = '\0';
      have_count = 1;
    }
  }
  fclose(f);
  return have_job && have_count;
}

int main(void) {
  unsigned long i = 0;
  int printed_parallel = 0;
  for (;;) {
    if (!printed_parallel) {
      char job[32];
      char count[32];
      if (read_parallel_env(job, sizeof(job), count, sizeof(count))) {
        printf("spore parallel job %s/%s\n", job, count);
        printed_parallel = 1;
      }
    }
    printf("spore counter %lu\n", i++);
    fflush(stdout);
    sleep(1);
  }
}
