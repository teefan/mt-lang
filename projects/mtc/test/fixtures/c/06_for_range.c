#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int32_t fixture_06_for_range_main(void);
int32_t main(void);

static int32_t fixture_06_for_range_main(void) {
  int32_t total = 0;
  for (int32_t i = 0; i < 10; i += 1) {
    total += i;
  }
  return total;
}

int32_t main(void) {
  return fixture_06_for_range_main();
}
