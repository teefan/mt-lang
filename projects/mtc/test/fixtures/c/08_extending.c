#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

typedef struct fixture_08_extending_Counter fixture_08_extending_Counter;

struct fixture_08_extending_Counter {
  int32_t value;
};

static int32_t fixture_08_extending_Counter_read(fixture_08_extending_Counter this);
static int32_t fixture_08_extending_main(void);
int32_t main(void);

static int32_t fixture_08_extending_Counter_read(fixture_08_extending_Counter this) {
  return this.value;
}

static int32_t fixture_08_extending_main(void) {
  fixture_08_extending_Counter c = { .value = 42 };
  return fixture_08_extending_Counter_read(c);
}

int32_t main(void) {
  return fixture_08_extending_main();
}
