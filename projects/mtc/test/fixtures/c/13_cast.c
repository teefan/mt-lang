#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

typedef struct fixture_13_cast_Vec2 fixture_13_cast_Vec2;

struct fixture_13_cast_Vec2 {
  int32_t x;
  int32_t y;
};

static int32_t fixture_13_cast_main(void);
int32_t main(void);

static int32_t fixture_13_cast_main(void) {
  fixture_13_cast_Vec2 v = { .x = 3, .y = 4 };
  int32_t sum = v.x + v.y;
  return sum;
}

int32_t main(void) {
  return fixture_13_cast_main();
}
