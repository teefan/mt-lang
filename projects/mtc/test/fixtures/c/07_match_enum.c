#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

typedef int32_t fixture_07_match_enum_Kind;
enum {
  fixture_07_match_enum_Kind_none = 0,
  fixture_07_match_enum_Kind_first = 1,
  fixture_07_match_enum_Kind_second = 2
};

static int32_t fixture_07_match_enum_classify(fixture_07_match_enum_Kind k);
static int32_t fixture_07_match_enum_main(void);
int32_t main(void);

static int32_t fixture_07_match_enum_classify(fixture_07_match_enum_Kind k) {
  switch (k) {
    case fixture_07_match_enum_Kind_none: {
      return 0;
    }
    case fixture_07_match_enum_Kind_first: {
      return 10;
    }
    case fixture_07_match_enum_Kind_second: {
      return 20;
    }
    default: {
      return 99;
    }
  }
}

static int32_t fixture_07_match_enum_main(void) {
  return fixture_07_match_enum_classify(fixture_07_match_enum_Kind_second);
}

int32_t main(void) {
  return fixture_07_match_enum_main();
}
