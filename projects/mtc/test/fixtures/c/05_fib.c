#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int32_t fixture_05_fib_fib(int32_t n);
static int32_t fixture_05_fib_main(void);
int32_t main(void);

static int32_t fixture_05_fib_fib(int32_t n) {
  if (n <= 1) {
    return n;
  }
  return fixture_05_fib_fib(n - 1) + fixture_05_fib_fib(n - 2);
}

static int32_t fixture_05_fib_main(void) {
  return fixture_05_fib_fib(6);
}

int32_t main(void) {
  return fixture_05_fib_main();
}
