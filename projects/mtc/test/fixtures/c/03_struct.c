#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

typedef struct fixture_03_struct_Vec2 fixture_03_struct_Vec2;

struct fixture_03_struct_Vec2 {
  int32_t x;
  int32_t y;
};

static int32_t fixture_03_struct_main(void);
int32_t main(void);

static int32_t fixture_03_struct_main(void) {
  fixture_03_struct_Vec2 v = { .x = 10, .y = 20 };
  return v.x + v.y;
}

int32_t main(void) {
  return fixture_03_struct_main();
}
