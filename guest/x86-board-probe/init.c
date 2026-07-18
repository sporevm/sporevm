#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <unistd.h>

#include <linux/reboot.h>

#define PROBE_PREFIX "sporevm-board-probe"
#define GENERATION_GPA UINT64_C(0xd0001000)
#define GENERATION_WINDOW_SIZE 0x1000U
#define GENERATION_MAGIC UINT32_C(0x4e475053)
#define POWEROFF_DOORBELL_OFFSET 0x020U
#define POWEROFF_COMMAND UINT32_C(0x46464f50)
#define MAX_TEXT_FILE 256U
#define MAX_COMMAND_LINE 4096U
#define MAX_VIRTIO_DEVICES 32U

enum probe_mode {
  PROBE_MODE_IDLE,
  PROBE_MODE_REBOOT,
  PROBE_MODE_POWEROFF_NATIVE,
  PROBE_MODE_POWEROFF,
};

struct virtio_device {
  unsigned index;
  uint32_t id;
};

_Noreturn static void idle_forever(void) {
  for (;;) {
    sleep(3600);
  }
}

_Noreturn static void fail_probe(const char *stage, const char *detail,
                                 int error_number) {
  if (error_number != 0) {
    printf(PROBE_PREFIX " status=fail stage=%s detail=%s errno=%d\n",
           stage, detail, error_number);
  } else {
    printf(PROBE_PREFIX " status=fail stage=%s detail=%s\n", stage, detail);
  }
  idle_forever();
}

static void ensure_directory(const char *path) {
  if (mkdir(path, 0755) != 0 && errno != EEXIST) {
    fail_probe("mount", path, errno);
  }
}

static void mount_filesystem(const char *source, const char *target,
                             const char *type) {
  ensure_directory(target);
  unsigned long flags = MS_NOSUID | MS_NOEXEC;
  if (strcmp(type, "devtmpfs") != 0) {
    flags |= MS_NODEV;
  }
  if (mount(source, target, type, flags, NULL) != 0 &&
      errno != EBUSY) {
    fail_probe("mount", target, errno);
  }
  printf(PROBE_PREFIX " mount=%s status=ok\n", target);
}

static size_t read_text_file(const char *path, char *buffer, size_t capacity) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    fail_probe("read", path, errno);
  }

  ssize_t count = read(fd, buffer, capacity - 1);
  if (count < 0) {
    int saved_errno = errno;
    close(fd);
    fail_probe("read", path, saved_errno);
  }
  if ((size_t)count == capacity - 1) {
    char extra;
    ssize_t extra_count = read(fd, &extra, 1);
    if (extra_count < 0) {
      int saved_errno = errno;
      close(fd);
      fail_probe("read", path, saved_errno);
    }
    if (extra_count != 0) {
      close(fd);
      fail_probe("read", "text-file-too-large", EOVERFLOW);
    }
  }
  close(fd);

  buffer[count] = '\0';
  while (count > 0 &&
         (buffer[count - 1] == '\n' || buffer[count - 1] == '\r' ||
          buffer[count - 1] == ' ' || buffer[count - 1] == '\t')) {
    buffer[--count] = '\0';
  }
  return (size_t)count;
}

static int is_space(char value) {
  return value == ' ' || value == '\t' || value == '\n' || value == '\r';
}

static int contains_word(const char *text, const char *word) {
  size_t word_length = strlen(word);
  const char *cursor = text;
  while (*cursor != '\0') {
    while (is_space(*cursor)) {
      cursor++;
    }
    const char *start = cursor;
    while (*cursor != '\0' && !is_space(*cursor)) {
      cursor++;
    }
    if ((size_t)(cursor - start) == word_length &&
        memcmp(start, word, word_length) == 0) {
      return 1;
    }
  }
  return 0;
}

static enum probe_mode parse_probe_mode(void) {
  static const char prefix[] = "sporevm.probe_mode=";
  char command_line[MAX_COMMAND_LINE];
  read_text_file("/proc/cmdline", command_line, sizeof(command_line));

  enum probe_mode mode = PROBE_MODE_IDLE;
  int found = 0;
  const char *cursor = command_line;
  while (*cursor != '\0') {
    while (is_space(*cursor)) {
      cursor++;
    }
    const char *start = cursor;
    while (*cursor != '\0' && !is_space(*cursor)) {
      cursor++;
    }
    size_t length = (size_t)(cursor - start);
    if (length < sizeof(prefix) - 1 ||
        memcmp(start, prefix, sizeof(prefix) - 1) != 0) {
      continue;
    }
    if (found) {
      fail_probe("probe-mode", "duplicate", 0);
    }
    found = 1;
    const char *value = start + sizeof(prefix) - 1;
    size_t value_length = length - (sizeof(prefix) - 1);
    if (value_length == 4 && memcmp(value, "idle", 4) == 0) {
      mode = PROBE_MODE_IDLE;
    } else if (value_length == 6 && memcmp(value, "reboot", 6) == 0) {
      mode = PROBE_MODE_REBOOT;
    } else if (value_length == 15 &&
               memcmp(value, "poweroff-native", 15) == 0) {
      mode = PROBE_MODE_POWEROFF_NATIVE;
    } else if (value_length == 8 && memcmp(value, "poweroff", 8) == 0) {
      mode = PROBE_MODE_POWEROFF;
    } else if (value_length == 0) {
      fail_probe("probe-mode", "empty", 0);
    } else {
      fail_probe("probe-mode", "unknown", 0);
    }
  }
  return mode;
}

static unsigned count_online_cpus(const char *text) {
  const char *cursor = text;
  unsigned long long total = 0;

  if (*cursor == '\0') {
    fail_probe("cpu-enumeration", "empty-online-set", 0);
  }
  for (;;) {
    errno = 0;
    char *end = NULL;
    unsigned long first = strtoul(cursor, &end, 10);
    if (errno != 0 || end == cursor || first > UINT_MAX) {
      fail_probe("cpu-enumeration", "invalid-online-set", errno);
    }
    cursor = end;

    unsigned long last = first;
    if (*cursor == '-') {
      cursor++;
      errno = 0;
      last = strtoul(cursor, &end, 10);
      if (errno != 0 || end == cursor || last > UINT_MAX || last < first) {
        fail_probe("cpu-enumeration", "invalid-online-range", errno);
      }
      cursor = end;
    }

    total += (unsigned long long)last - first + 1;
    if (total > UINT_MAX) {
      fail_probe("cpu-enumeration", "online-count-overflow", EOVERFLOW);
    }
    if (*cursor == '\0') {
      break;
    }
    if (*cursor != ',') {
      fail_probe("cpu-enumeration", "invalid-online-separator", 0);
    }
    cursor++;
  }
  return (unsigned)total;
}

static unsigned parse_virtio_index(const char *name) {
  static const char prefix[] = "virtio";
  if (strncmp(name, prefix, sizeof(prefix) - 1) != 0) {
    return UINT_MAX;
  }

  const char *digits = name + sizeof(prefix) - 1;
  if (*digits == '\0') {
    return UINT_MAX;
  }
  errno = 0;
  char *end = NULL;
  unsigned long index = strtoul(digits, &end, 10);
  if (errno != 0 || *end != '\0' || index > UINT_MAX) {
    return UINT_MAX;
  }
  return (unsigned)index;
}

static uint32_t read_virtio_device_id(unsigned index) {
  char path[PATH_MAX];
  int length = snprintf(path, sizeof(path),
                        "/sys/bus/virtio/devices/virtio%u/device", index);
  if (length < 0 || (size_t)length >= sizeof(path)) {
    fail_probe("virtio-enumeration", "device-path-too-long", EOVERFLOW);
  }

  char text[MAX_TEXT_FILE];
  read_text_file(path, text, sizeof(text));
  errno = 0;
  char *end = NULL;
  unsigned long id = strtoul(text, &end, 0);
  if (errno != 0 || end == text || *end != '\0' || id > UINT32_MAX) {
    fail_probe("virtio-enumeration", "invalid-device-id", errno);
  }
  return (uint32_t)id;
}

static int compare_virtio_devices(const void *left_value,
                                  const void *right_value) {
  const struct virtio_device *left = left_value;
  const struct virtio_device *right = right_value;
  if (left->index < right->index) {
    return -1;
  }
  if (left->index > right->index) {
    return 1;
  }
  return 0;
}

static size_t enumerate_virtio(struct virtio_device *devices, size_t capacity) {
  DIR *directory = opendir("/sys/bus/virtio/devices");
  if (directory == NULL) {
    fail_probe("virtio-enumeration", "open-sysfs-directory", errno);
  }

  size_t count = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(directory);
    if (entry == NULL) {
      break;
    }
    unsigned index = parse_virtio_index(entry->d_name);
    if (index == UINT_MAX) {
      continue;
    }
    if (count == capacity) {
      closedir(directory);
      fail_probe("virtio-enumeration", "too-many-devices", EOVERFLOW);
    }
    devices[count].index = index;
    devices[count].id = read_virtio_device_id(index);
    count++;
  }
  int saved_errno = errno;
  closedir(directory);
  if (saved_errno != 0) {
    fail_probe("virtio-enumeration", "read-sysfs-directory", saved_errno);
  }
  if (count == 0) {
    fail_probe("virtio-enumeration", "no-devices", 0);
  }

  qsort(devices, count, sizeof(devices[0]), compare_virtio_devices);
  return count;
}

static void probe_generation_device(void) {
  int fd = open("/dev/mem", O_RDONLY | O_CLOEXEC | O_SYNC);
  if (fd < 0) {
    fail_probe("generation", "open-devmem", errno);
  }
  void *mapping = mmap(NULL, GENERATION_WINDOW_SIZE, PROT_READ, MAP_SHARED, fd,
                       (off_t)GENERATION_GPA);
  int saved_errno = errno;
  close(fd);
  if (mapping == MAP_FAILED) {
    fail_probe("generation", "mmap", saved_errno);
  }

  uint32_t magic = *(volatile const uint32_t *)mapping;
  if (munmap(mapping, GENERATION_WINDOW_SIZE) != 0) {
    fail_probe("generation", "munmap", errno);
  }
  if (magic != GENERATION_MAGIC) {
    printf(PROBE_PREFIX
           " status=fail stage=generation detail=bad-magic "
           "gpa=0x%llx expected=0x%08x actual=0x%08x\n",
           (unsigned long long)GENERATION_GPA, GENERATION_MAGIC, magic);
    idle_forever();
  }
  printf(PROBE_PREFIX " generation_gpa=0x%llx magic=0x%08x status=ok\n",
         (unsigned long long)GENERATION_GPA, magic);
}

_Noreturn static void issue_reboot_command(int command, const char *mode) {
  printf(PROBE_PREFIX " action=%s status=requested\n", mode);
  sync();
  errno = 0;
  long result = syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                        command, NULL);
  fail_probe("lifecycle", result < 0 ? "reboot-syscall" : "reboot-returned",
             result < 0 ? errno : 0);
}

_Noreturn static void issue_poweroff_doorbell(void) {
  int fd = open("/dev/mem", O_RDWR | O_CLOEXEC | O_SYNC);
  if (fd < 0) {
    fail_probe("poweroff-doorbell", "open-devmem", errno);
  }
  void *mapping = mmap(NULL, GENERATION_WINDOW_SIZE, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, (off_t)GENERATION_GPA);
  int saved_errno = errno;
  close(fd);
  if (mapping == MAP_FAILED) {
    fail_probe("poweroff-doorbell", "mmap", saved_errno);
  }

  printf(PROBE_PREFIX
         " action=poweroff gpa=0x%llx offset=0x%x value=0x%08x "
         "status=requested\n",
         (unsigned long long)GENERATION_GPA, POWEROFF_DOORBELL_OFFSET,
         POWEROFF_COMMAND);
  sync();
  *(volatile uint32_t *)((volatile unsigned char *)mapping +
                         POWEROFF_DOORBELL_OFFSET) = POWEROFF_COMMAND;
  fail_probe("poweroff-doorbell", "write-returned", 0);
}

int main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  printf(PROBE_PREFIX " status=start\n");

  mount_filesystem("proc", "/proc", "proc");
  mount_filesystem("sysfs", "/sys", "sysfs");
  mount_filesystem("devtmpfs", "/dev", "devtmpfs");
  enum probe_mode mode = parse_probe_mode();

  char online[MAX_TEXT_FILE];
  read_text_file("/sys/devices/system/cpu/online", online, sizeof(online));
  unsigned online_count = count_online_cpus(online);
  printf(PROBE_PREFIX " cpu_online=%s cpu_count=%u status=ok\n", online,
         online_count);

  struct virtio_device devices[MAX_VIRTIO_DEVICES];
  size_t device_count = enumerate_virtio(devices, MAX_VIRTIO_DEVICES);
  for (size_t index = 0; index < device_count; index++) {
    printf(PROBE_PREFIX
           " virtio=virtio%u device_id=%u device_id_hex=0x%08x status=ok\n",
           devices[index].index, devices[index].id, devices[index].id);
  }
  printf(PROBE_PREFIX " virtio_count=%zu status=ok\n", device_count);

  char active_consoles[MAX_TEXT_FILE];
  read_text_file("/sys/class/tty/console/active", active_consoles,
                 sizeof(active_consoles));
  if (!contains_word(active_consoles, "hvc0")) {
    fail_probe("console", "hvc0-not-active", 0);
  }
  if (fcntl(STDOUT_FILENO, F_GETFL) < 0) {
    fail_probe("console", "stdout-not-open", errno);
  }
  printf(PROBE_PREFIX " console=hvc0 stdout=ok status=ok\n");

  probe_generation_device();
  printf(PROBE_PREFIX " status=ready\n");
  switch (mode) {
    case PROBE_MODE_IDLE:
      printf(PROBE_PREFIX " action=idle status=ok\n");
      idle_forever();
    case PROBE_MODE_REBOOT:
      issue_reboot_command(LINUX_REBOOT_CMD_RESTART, "reboot");
    case PROBE_MODE_POWEROFF_NATIVE:
      issue_reboot_command(LINUX_REBOOT_CMD_POWER_OFF, "poweroff-native");
    case PROBE_MODE_POWEROFF:
      issue_poweroff_doorbell();
  }
}
