#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int32_t fixture_11_compound_assign_main(void);
int32_t main(void);

static int32_t fixture_11_compound_assign_main(void) {
  int32_t total = 0;
  total += 1;
  total -= 2;
  total *= 3;
  total /= 2;
  return total;
}

int32_t main(void) {
  return fixture_11_compound_assign_main();
}
