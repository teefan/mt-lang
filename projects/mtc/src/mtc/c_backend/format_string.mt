## C format-string runtime emitter, extracted from c_backend/c_backend.mt.

import mtc.c_backend.c_backend as c_backend


public function emit_format_string_core(e: ref[c_backend.Emitter]) -> void:
    c_backend.emit_line(e, "static mt_str mt_format_str_make(uintptr_t len) {")
    c_backend.emit_line(e, "  if (len > UINTPTR_MAX - 1) mt_fatal(\"format string size overflow\");")
    c_backend.emit_line(e, "  char* data = (char*)malloc((size_t)(len + 1));")
    c_backend.emit_line(e, "  if (data == NULL) mt_fatal(\"format string allocation failed\");")
    c_backend.emit_line(e, "  data[len] = '\\0';")
    c_backend.emit_line(e, "  return (mt_str){ .data = data, .len = len };")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static void mt_format_str_release(mt_str value) {")
    c_backend.emit_line(e, "  free(value.data);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static void mt_format_check_capacity(mt_str target, uintptr_t offset, uintptr_t len) {")
    c_backend.emit_line(
        e,
        "  if (offset > target.len || len > target.len - offset) mt_fatal(\"format string append exceeds capacity\");"
    )
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(
        e,
        "static uintptr_t mt_format_append_bytes(mt_str target, uintptr_t offset, const char* data, uintptr_t len) {"
    )
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(e, "  if (len > 0) memcpy(target.data + offset, data, (size_t)len);")
    c_backend.emit_line(e, "  offset += len;")
    c_backend.emit_line(e, "  target.data[offset] = '\\0';")
    c_backend.emit_line(e, "  return offset;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_ptr_uint_len(uintptr_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = 1;")
    c_backend.emit_line(e, "  while (value >= 10) {")
    c_backend.emit_line(e, "    value /= 10;")
    c_backend.emit_line(e, "    len += 1;")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "  return len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_ulong_hex_len(uint64_t value) {")
    c_backend.emit_line(e, "  int written = snprintf(NULL, 0, \"%llx\", (unsigned long long)value);")
    c_backend.emit_line(e, "  if (written < 0) mt_fatal(\"format string could not measure unsigned hex\");")
    c_backend.emit_line(e, "  return (uintptr_t)written;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_long_hex_len(int64_t value) {")
    c_backend.emit_line(e, "  if (value < 0) return 1 + mt_format_ulong_hex_len(((uint64_t)(-(value + 1))) + 1);")
    c_backend.emit_line(e, "  return mt_format_ulong_hex_len((uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_ulong_oct_len(uint64_t value) {")
    c_backend.emit_line(e, "  int written = snprintf(NULL, 0, \"%llo\", (unsigned long long)value);")
    c_backend.emit_line(e, "  if (written < 0) mt_fatal(\"format string could not measure unsigned octal\");")
    c_backend.emit_line(e, "  return (uintptr_t)written;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_long_oct_len(int64_t value) {")
    c_backend.emit_line(e, "  if (value < 0) return 1 + mt_format_ulong_oct_len(((uint64_t)(-(value + 1))) + 1);")
    c_backend.emit_line(e, "  return mt_format_ulong_oct_len((uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_ulong_bin_len(uint64_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = 1;")
    c_backend.emit_line(e, "  while (value >= 2) {")
    c_backend.emit_line(e, "    value >>= 1;")
    c_backend.emit_line(e, "    len += 1;")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "  return len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_long_bin_len(int64_t value) {")
    c_backend.emit_line(e, "  if (value < 0) return 1 + mt_format_ulong_bin_len(((uint64_t)(-(value + 1))) + 1);")
    c_backend.emit_line(e, "  return mt_format_ulong_bin_len((uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_int_len(int32_t value) {")
    c_backend.emit_line(e, "  if (value < 0) return 1 + mt_format_ptr_uint_len((uintptr_t)(-((int64_t)value)));")
    c_backend.emit_line(e, "  return mt_format_ptr_uint_len((uintptr_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_str(mt_str target, uintptr_t offset, mt_str value) {")
    c_backend.emit_line(e, "  return mt_format_append_bytes(target, offset, value.data, value.len);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_ptr_uint(mt_str target, uintptr_t offset, uintptr_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_ptr_uint_len(value);")
    c_backend.emit_line(e, "  uintptr_t index = offset + len;")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(e, "  target.data[index] = '\\0';")
    c_backend.emit_line(e, "  do {")
    c_backend.emit_line(e, "    index -= 1;")
    c_backend.emit_line(e, "    target.data[index] = (char)('0' + (value % 10));")
    c_backend.emit_line(e, "    value /= 10;")
    c_backend.emit_line(e, "  } while (index > offset);")
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_int(mt_str target, uintptr_t offset, int32_t value) {")
    c_backend.emit_line(e, "  if (value < 0) {")
    c_backend.emit_line(e, "    offset = mt_format_append_bytes(target, offset, \"-\", 1);")
    c_backend.emit_line(e, "    return mt_format_append_ptr_uint(target, offset, (uintptr_t)(-((int64_t)value)));")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "  return mt_format_append_ptr_uint(target, offset, (uintptr_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")


public function emit_format_string_length_helpers(e: ref[c_backend.Emitter]) -> void:
    # --- Additional length helpers ---
    c_backend.emit_line(e, "static uintptr_t mt_format_cstr_len(const char* value) { return (uintptr_t)strlen(value); }")
    c_backend.emit_line(e, "static uintptr_t mt_format_bool_len(bool value) { return value ? 4 : 5; }")
    c_backend.emit_line(e, "static uintptr_t mt_format_ulong_len(uint64_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = 1;")
    c_backend.emit_line(e, "  while (value >= 10) { value /= 10; len += 1; }")
    c_backend.emit_line(e, "  return len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(
        e,
        "static uintptr_t mt_format_uint_len(uint32_t value) { return mt_format_ptr_uint_len((uintptr_t)value); }"
    )
    c_backend.emit_line(e, "static uintptr_t mt_format_long_len(int64_t value) {")
    c_backend.emit_line(e, "  if (value < 0) return 1 + mt_format_ulong_len(((uint64_t)(-(value + 1))) + 1);")
    c_backend.emit_line(e, "  return mt_format_ulong_len((uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_float_len(float value) {")
    c_backend.emit_line(e, "  int written = snprintf(NULL, 0, \"%g\", (double)value);")
    c_backend.emit_line(e, "  if (written < 0) mt_fatal(\"format string could not measure float\");")
    c_backend.emit_line(e, "  return (uintptr_t)written;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_double_len(double value) {")
    c_backend.emit_line(e, "  int written = snprintf(NULL, 0, \"%g\", value);")
    c_backend.emit_line(e, "  if (written < 0) mt_fatal(\"format string could not measure double\");")
    c_backend.emit_line(e, "  return (uintptr_t)written;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_double_precision_len(double value, int32_t precision) {")
    c_backend.emit_line(e, "  int written = snprintf(NULL, 0, \"%.*f\", precision, value);")
    c_backend.emit_line(e, "  if (written < 0) mt_fatal(\"format string could not measure double precision\");")
    c_backend.emit_line(e, "  return (uintptr_t)written;")
    c_backend.emit_line(e, "}")


public function emit_format_string_append_helpers(e: ref[c_backend.Emitter]) -> void:
    # --- Additional append helpers ---
    c_backend.emit_line(e, "static uintptr_t mt_format_append_cstr(mt_str target, uintptr_t offset, const char* value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_cstr_len(value);")
    c_backend.emit_line(e, "  return mt_format_append_bytes(target, offset, value, len);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_bool(mt_str target, uintptr_t offset, bool value) {")
    c_backend.emit_line(
        e,
        "  return value ? mt_format_append_bytes(target, offset, \"true\", 4) : mt_format_append_bytes(target, offset, \"false\", 5);"
    )
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_ulong(mt_str target, uintptr_t offset, uint64_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_ulong_len(value);")
    c_backend.emit_line(e, "  uintptr_t index = offset + len;")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(e, "  target.data[index] = '\\0';")
    c_backend.emit_line(
        e,
        "  do { index -= 1; target.data[index] = (char)('0' + (value % 10)); value /= 10; } while (index > offset);"
    )
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_uint(mt_str target, uintptr_t offset, uint32_t value) {")
    c_backend.emit_line(e, "  return mt_format_append_ptr_uint(target, offset, (uintptr_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_long(mt_str target, uintptr_t offset, int64_t value) {")
    c_backend.emit_line(e, "  if (value < 0) {")
    c_backend.emit_line(e, "    offset = mt_format_append_bytes(target, offset, \"-\", 1);")
    c_backend.emit_line(e, "    return mt_format_append_ulong(target, offset, ((uint64_t)(-(value + 1))) + 1);")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "  return mt_format_append_ulong(target, offset, (uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_ulong_hex(mt_str target, uintptr_t offset, uint64_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_ulong_hex_len(value);")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(
        e,
        "  int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%llx\", (unsigned long long)value);"
    )
    c_backend.emit_line(
        e,
        "  if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format unsigned hex\");"
    )
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_ulong_hex_upper(mt_str target, uintptr_t offset, uint64_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_ulong_hex_len(value);")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(
        e,
        "  int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%llX\", (unsigned long long)value);"
    )
    c_backend.emit_line(
        e,
        "  if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format unsigned hex\");"
    )
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_long_hex(mt_str target, uintptr_t offset, int64_t value) {")
    c_backend.emit_line(
        e,
        "  if (value < 0) { offset = mt_format_append_bytes(target, offset, \"-\", 1); return mt_format_append_ulong_hex(target, offset, ((uint64_t)(-(value + 1))) + 1); }"
    )
    c_backend.emit_line(e, "  return mt_format_append_ulong_hex(target, offset, (uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_long_hex_upper(mt_str target, uintptr_t offset, int64_t value) {")
    c_backend.emit_line(
        e,
        "  if (value < 0) { offset = mt_format_append_bytes(target, offset, \"-\", 1); return mt_format_append_ulong_hex_upper(target, offset, ((uint64_t)(-(value + 1))) + 1); }"
    )
    c_backend.emit_line(e, "  return mt_format_append_ulong_hex_upper(target, offset, (uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_ulong_oct(mt_str target, uintptr_t offset, uint64_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_ulong_oct_len(value);")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(
        e,
        "  int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%llo\", (unsigned long long)value);"
    )
    c_backend.emit_line(
        e,
        "  if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format unsigned octal\");"
    )
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_long_oct(mt_str target, uintptr_t offset, int64_t value) {")
    c_backend.emit_line(
        e,
        "  if (value < 0) { offset = mt_format_append_bytes(target, offset, \"-\", 1); return mt_format_append_ulong_oct(target, offset, ((uint64_t)(-(value + 1))) + 1); }"
    )
    c_backend.emit_line(e, "  return mt_format_append_ulong_oct(target, offset, (uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_ulong_bin(mt_str target, uintptr_t offset, uint64_t value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_ulong_bin_len(value);")
    c_backend.emit_line(e, "  uintptr_t index = offset + len;")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(e, "  target.data[index] = '\\0';")
    c_backend.emit_line(
        e,
        "  do { index -= 1; target.data[index] = (char)('0' + (value & 1)); value >>= 1; } while (index > offset);"
    )
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_long_bin(mt_str target, uintptr_t offset, int64_t value) {")
    c_backend.emit_line(
        e,
        "  if (value < 0) { offset = mt_format_append_bytes(target, offset, \"-\", 1); return mt_format_append_ulong_bin(target, offset, ((uint64_t)(-(value + 1))) + 1); }"
    )
    c_backend.emit_line(e, "  return mt_format_append_ulong_bin(target, offset, (uint64_t)value);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_float(mt_str target, uintptr_t offset, float value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_float_len(value);")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(
        e,
        "  int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%g\", (double)value);"
    )
    c_backend.emit_line(e, "  if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format float\");")
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "static uintptr_t mt_format_append_double(mt_str target, uintptr_t offset, double value) {")
    c_backend.emit_line(e, "  uintptr_t len = mt_format_double_len(value);")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(e, "  int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%g\", value);")
    c_backend.emit_line(e, "  if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format double\");")
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(
        e,
        "static uintptr_t mt_format_append_double_precision(mt_str target, uintptr_t offset, double value, int32_t precision) {"
    )
    c_backend.emit_line(e, "  uintptr_t len = mt_format_double_precision_len(value, precision);")
    c_backend.emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    c_backend.emit_line(
        e,
        "  int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%.*f\", precision, value);"
    )
    c_backend.emit_line(
        e,
        "  if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format double precision\");"
    )
    c_backend.emit_line(e, "  return offset + len;")
    c_backend.emit_line(e, "}")

# =============================================================================
#  Event runtime helpers
# =============================================================================

#  Parallel / detach runtime helpers

# =============================================================================
