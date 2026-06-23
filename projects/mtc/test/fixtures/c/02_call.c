#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int32_t fixture_02_call_add(int32_t a, int32_t b);
static int32_t fixture_02_call_main(void);
int32_t main(void);

static int32_t fixture_02_call_add(int32_t a, int32_t b) {
  return a + b;
}

static int32_t fixture_02_call_main(void) {
  return fixture_02_call_add(2, 3);
}

int32_t main(void) {
  return fixture_02_call_main();
}
