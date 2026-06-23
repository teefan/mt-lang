#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int32_t fixture_09_type_alias_add(int32_t a, int32_t b);
static int32_t fixture_09_type_alias_main(void);
int32_t main(void);

static int32_t fixture_09_type_alias_add(int32_t a, int32_t b) {
  return a + b;
}

static int32_t fixture_09_type_alias_main(void) {
  return fixture_09_type_alias_add(10, 20);
}

int32_t main(void) {
  return fixture_09_type_alias_main();
}
