#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int32_t fixture_04_while_main(void);
int32_t main(void);

static int32_t fixture_04_while_main(void) {
  int32_t total = 0;
  int32_t i = 0;
  while (i < 5) {
    total += 1;
    i += 1;
  }
  return total;
}

int32_t main(void) {
  return fixture_04_while_main();
}
