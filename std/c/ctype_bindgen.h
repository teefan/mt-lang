#ifndef MT_LANG_CTYPE_BINDGEN_H
#define MT_LANG_CTYPE_BINDGEN_H

#include <ctype.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline int mt_ctype_isalnum(int value) { return isalnum(value); }
static inline int mt_ctype_isalpha(int value) { return isalpha(value); }
static inline int mt_ctype_isblank(int value) { return isblank(value); }
static inline int mt_ctype_iscntrl(int value) { return iscntrl(value); }
static inline int mt_ctype_isdigit(int value) { return isdigit(value); }
static inline int mt_ctype_isgraph(int value) { return isgraph(value); }
static inline int mt_ctype_islower(int value) { return islower(value); }
static inline int mt_ctype_isprint(int value) { return isprint(value); }
static inline int mt_ctype_ispunct(int value) { return ispunct(value); }
static inline int mt_ctype_isspace(int value) { return isspace(value); }
static inline int mt_ctype_isupper(int value) { return isupper(value); }
static inline int mt_ctype_isxdigit(int value) { return isxdigit(value); }
static inline int mt_ctype_tolower(int value) { return tolower(value); }
static inline int mt_ctype_toupper(int value) { return toupper(value); }

#ifdef __cplusplus
}
#endif

#endif