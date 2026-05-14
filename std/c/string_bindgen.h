#ifndef MT_LANG_STRING_BINDGEN_H
#define MT_LANG_STRING_BINDGEN_H

#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline void *mt_string_memcpy(void *destination, const void *source, size_t size_bytes) { return memcpy(destination, source, size_bytes); }
static inline void *mt_string_memmove(void *destination, const void *source, size_t size_bytes) { return memmove(destination, source, size_bytes); }
static inline void *mt_string_memset(void *destination, int value, size_t size_bytes) { return memset(destination, value, size_bytes); }
static inline int mt_string_memcmp(const void *left, const void *right, size_t size_bytes) { return memcmp(left, right, size_bytes); }
#ifdef __cplusplus
static inline void *mt_string_memchr(const void *source, int value, size_t size_bytes) { return const_cast<void *>(memchr(source, value, size_bytes)); }
#else
static inline void *mt_string_memchr(const void *source, int value, size_t size_bytes) { return memchr(source, value, size_bytes); }
#endif
static inline size_t mt_string_strlen(const char *text) { return strlen(text); }
static inline int mt_string_strcmp(const char *left, const char *right) { return strcmp(left, right); }
static inline int mt_string_strncmp(const char *left, const char *right, size_t size_bytes) { return strncmp(left, right, size_bytes); }
#ifdef __cplusplus
static inline char *mt_string_strchr(const char *text, int value) { return const_cast<char *>(strchr(text, value)); }
static inline char *mt_string_strrchr(const char *text, int value) { return const_cast<char *>(strrchr(text, value)); }
static inline char *mt_string_strstr(const char *haystack, const char *needle) { return const_cast<char *>(strstr(haystack, needle)); }
#else
static inline char *mt_string_strchr(const char *text, int value) { return strchr(text, value); }
static inline char *mt_string_strrchr(const char *text, int value) { return strrchr(text, value); }
static inline char *mt_string_strstr(const char *haystack, const char *needle) { return strstr(haystack, needle); }
#endif

#ifdef __cplusplus
}
#endif

#endif
