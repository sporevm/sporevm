#include <unistd.h>

int main(void) {
  write(1, "spore stdout\n", 13);
  write(2, "spore stderr\n", 13);
  return 0;
}
