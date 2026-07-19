#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>

static int write_all(int fd, const char *bytes, unsigned long len) {
    while (len != 0) {
        ssize_t written = write(fd, bytes, len);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        bytes += written;
        len -= (unsigned long)written;
    }
    return 0;
}

int main(void) {
    uint8_t bytes[32];
    unsigned long used = 0;
    int fd = open("/dev/hwrng", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 2;
    while (used != sizeof(bytes)) {
        ssize_t got = read(fd, bytes + used, sizeof(bytes) - used);
        if (got < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return 3;
        }
        if (got == 0) {
            close(fd);
            return 4;
        }
        used += (unsigned long)got;
    }
    close(fd);

    uint8_t combined = 0;
    for (unsigned long i = 0; i < sizeof(bytes); ++i) combined |= bytes[i];
    if (combined == 0) return 5;
    return write_all(STDOUT_FILENO, "rng ok\n", 7) == 0 ? 0 : 6;
}
