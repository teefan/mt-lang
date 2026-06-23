#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int32_t fixture_12_match_multi_classify(int32_t v);
static int32_t fixture_12_match_multi_main(void);
int32_t main(void);

static int32_t fixture_12_match_multi_classify(int32_t v) {
  switch (v) {
    case 0: {
      return 0;
    }
    case 1: {
      return 1;
    }
    case 2: {
      return 1;
    }
    case 3: {
      return 1;
    }
    case 4: {
      return 2;
    }
    case 5: {
      return 2;
    }
    default: {
      return 9;
    }
  }
}

static int32_t fixture_12_match_multi_main(void) {
  return fixture_12_match_multi_classify(3);
}

int32_t main(void) {
  return fixture_12_match_multi_main();
}
