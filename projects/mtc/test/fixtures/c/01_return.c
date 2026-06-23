#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int32_t fixture_01_return_main(void);
int32_t main(void);

static int32_t fixture_01_return_main(void) {
  return 42;
}

int32_t main(void) {
  return fixture_01_return_main();
}
