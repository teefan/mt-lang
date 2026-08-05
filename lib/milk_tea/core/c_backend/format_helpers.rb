# frozen_string_literal: true

module MilkTea
  class CBackend
    module FormatHelpers
      def emit_format_helpers
        helpers = required_format_helper_callees
        lines = []

        if helpers['mt_format_str_make']
          lines.concat([
            "static mt_str mt_format_str_make(uintptr_t len) {",
            "#{INDENT}char* data = (char*)malloc((size_t)(len + 1));",
            "#{INDENT}if (data == NULL) mt_fatal(\"format string allocation failed\");",
            "#{INDENT}data[len] = '\\0';",
            "#{INDENT}return (mt_str){ .data = data, .len = len };",
            "}",
          ])
        end

        if helpers['mt_format_str_release']
          lines << "" unless lines.empty?
          lines.concat([
            "static void mt_format_str_release(mt_str value) {",
            "#{INDENT}free(value.data);",
            "}",
          ])
        end

        if helpers['mt_format_check_capacity']
          lines << "" unless lines.empty?
          lines.concat([
            "static void mt_format_check_capacity(mt_str target, uintptr_t offset, uintptr_t len) {",
            "#{INDENT}if (offset > target.len || len > target.len - offset) mt_fatal(\"format string append exceeds capacity\");",
            "}",
          ])
        end

        if helpers['mt_format_append_bytes']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_bytes(mt_str target, uintptr_t offset, const char* data, uintptr_t len) {",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}if (len > 0) memcpy(target.data + offset, data, (size_t)len);",
            "#{INDENT}offset += len;",
            "#{INDENT}target.data[offset] = '\\0';",
            "#{INDENT}return offset;",
            "}",
          ])
        end

        if helpers['mt_format_cstr_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_cstr_len(const char* value) {",
            "#{INDENT}return (uintptr_t)strlen(value);",
            "}",
          ])
        end

        if helpers['mt_format_bool_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_bool_len(bool value) {",
            "#{INDENT}return value ? 4 : 5;",
            "}",
          ])
        end

        if helpers['mt_format_ptr_uint_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_ptr_uint_len(uintptr_t value) {",
            "#{INDENT}uintptr_t len = 1;",
            "#{INDENT}while (value >= 10) {",
            "#{INDENT * 2}value /= 10;",
            "#{INDENT * 2}len += 1;",
            "#{INDENT}}",
            "#{INDENT}return len;",
            "}",
          ])
        end

        if helpers['mt_format_ulong_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_ulong_len(uint64_t value) {",
            "#{INDENT}uintptr_t len = 1;",
            "#{INDENT}while (value >= 10) {",
            "#{INDENT * 2}value /= 10;",
            "#{INDENT * 2}len += 1;",
            "#{INDENT}}",
            "#{INDENT}return len;",
            "}",
          ])
        end

        if helpers['mt_format_ulong_hex_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_ulong_hex_len(uint64_t value) {",
            "#{INDENT}int written = snprintf(NULL, 0, \"%llx\", (unsigned long long)value);",
            "#{INDENT}if (written < 0) mt_fatal(\"format string could not measure unsigned hex\");",
            "#{INDENT}return (uintptr_t)written;",
            "}",
          ])
        end

        if helpers['mt_format_uint_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_uint_len(uint32_t value) {",
            "#{INDENT}return mt_format_ptr_uint_len((uintptr_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_long_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_long_len(int64_t value) {",
            "#{INDENT}if (value < 0) return 1 + mt_format_ulong_len(((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}return mt_format_ulong_len((uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_long_hex_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_long_hex_len(int64_t value) {",
            "#{INDENT}if (value < 0) return 1 + mt_format_ulong_hex_len(((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}return mt_format_ulong_hex_len((uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_ulong_oct_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_ulong_oct_len(uint64_t value) {",
            "#{INDENT}int written = snprintf(NULL, 0, \"%llo\", (unsigned long long)value);",
            "#{INDENT}if (written < 0) mt_fatal(\"format string could not measure unsigned octal\");",
            "#{INDENT}return (uintptr_t)written;",
            "}",
          ])
        end

        if helpers['mt_format_long_oct_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_long_oct_len(int64_t value) {",
            "#{INDENT}if (value < 0) return 1 + mt_format_ulong_oct_len(((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}return mt_format_ulong_oct_len((uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_ulong_bin_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_ulong_bin_len(uint64_t value) {",
            "#{INDENT}uintptr_t len = 1;",
            "#{INDENT}while (value >= 2) {",
            "#{INDENT * 2}value >>= 1;",
            "#{INDENT * 2}len += 1;",
            "#{INDENT}}",
            "#{INDENT}return len;",
            "}",
          ])
        end

        if helpers['mt_format_long_bin_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_long_bin_len(int64_t value) {",
            "#{INDENT}if (value < 0) return 1 + mt_format_ulong_bin_len(((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}return mt_format_ulong_bin_len((uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_int_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_int_len(int32_t value) {",
            "#{INDENT}if (value < 0) return 1 + mt_format_ptr_uint_len((uintptr_t)(-((int64_t)value)));",
            "#{INDENT}return mt_format_ptr_uint_len((uintptr_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_float_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_float_len(float value) {",
            "#{INDENT}int written = snprintf(NULL, 0, \"%g\", (double)value);",
            "#{INDENT}if (written < 0) mt_fatal(\"format string could not measure float\");",
            "#{INDENT}return (uintptr_t)written;",
            "}",
          ])
        end

        if helpers['mt_format_double_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_double_len(double value) {",
            "#{INDENT}int written = snprintf(NULL, 0, \"%g\", value);",
            "#{INDENT}if (written < 0) mt_fatal(\"format string could not measure double\");",
            "#{INDENT}return (uintptr_t)written;",
            "}",
          ])
        end

        if helpers['mt_format_double_precision_len']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_double_precision_len(double value, int32_t precision) {",
            "#{INDENT}int written = snprintf(NULL, 0, \"%.*f\", precision, value);",
            "#{INDENT}if (written < 0) mt_fatal(\"format string could not measure double precision\");",
            "#{INDENT}return (uintptr_t)written;",
            "}",
          ])
        end

        if helpers['mt_format_append_str']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_str(mt_str target, uintptr_t offset, mt_str value) {",
            "#{INDENT}return mt_format_append_bytes(target, offset, value.data, value.len);",
            "}",
          ])
        end

        if helpers['mt_format_append_cstr']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_cstr(mt_str target, uintptr_t offset, const char* value) {",
            "#{INDENT}uintptr_t len = mt_format_cstr_len(value);",
            "#{INDENT}return mt_format_append_bytes(target, offset, value, len);",
            "}",
          ])
        end

        if helpers['mt_format_append_bool']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_bool(mt_str target, uintptr_t offset, bool value) {",
            "#{INDENT}return value ? mt_format_append_bytes(target, offset, \"true\", 4) : mt_format_append_bytes(target, offset, \"false\", 5);",
            "}",
          ])
        end

        if helpers['mt_format_append_ptr_uint']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_ptr_uint(mt_str target, uintptr_t offset, uintptr_t value) {",
            "#{INDENT}uintptr_t len = mt_format_ptr_uint_len(value);",
            "#{INDENT}uintptr_t index = offset + len;",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}target.data[index] = '\\0';",
            "#{INDENT}do {",
            "#{INDENT * 2}index -= 1;",
            "#{INDENT * 2}target.data[index] = (char)('0' + (value % 10));",
            "#{INDENT * 2}value /= 10;",
            "#{INDENT}} while (index > offset);",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        if helpers['mt_format_append_ulong']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_ulong(mt_str target, uintptr_t offset, uint64_t value) {",
            "#{INDENT}uintptr_t len = mt_format_ulong_len(value);",
            "#{INDENT}uintptr_t index = offset + len;",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}target.data[index] = '\\0';",
            "#{INDENT}do {",
            "#{INDENT * 2}index -= 1;",
            "#{INDENT * 2}target.data[index] = (char)('0' + (value % 10));",
            "#{INDENT * 2}value /= 10;",
            "#{INDENT}} while (index > offset);",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        if helpers['mt_format_append_uint']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_uint(mt_str target, uintptr_t offset, uint32_t value) {",
            "#{INDENT}return mt_format_append_ptr_uint(target, offset, (uintptr_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_append_long']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_long(mt_str target, uintptr_t offset, int64_t value) {",
            "#{INDENT}if (value < 0) {",
            "#{INDENT * 2}offset = mt_format_append_bytes(target, offset, \"-\", 1);",
            "#{INDENT * 2}return mt_format_append_ulong(target, offset, ((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}}",
            "#{INDENT}return mt_format_append_ulong(target, offset, (uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_append_ulong_hex']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_ulong_hex(mt_str target, uintptr_t offset, uint64_t value) {",
            "#{INDENT}uintptr_t len = mt_format_ulong_hex_len(value);",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%llx\", (unsigned long long)value);",
            "#{INDENT}if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format unsigned hex\");",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        if helpers['mt_format_append_ulong_hex_upper']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_ulong_hex_upper(mt_str target, uintptr_t offset, uint64_t value) {",
            "#{INDENT}uintptr_t len = mt_format_ulong_hex_len(value);",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%llX\", (unsigned long long)value);",
            "#{INDENT}if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format unsigned hex\");",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        if helpers['mt_format_append_long_hex']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_long_hex(mt_str target, uintptr_t offset, int64_t value) {",
            "#{INDENT}if (value < 0) {",
            "#{INDENT * 2}offset = mt_format_append_bytes(target, offset, \"-\", 1);",
            "#{INDENT * 2}return mt_format_append_ulong_hex(target, offset, ((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}}",
            "#{INDENT}return mt_format_append_ulong_hex(target, offset, (uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_append_long_hex_upper']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_long_hex_upper(mt_str target, uintptr_t offset, int64_t value) {",
            "#{INDENT}if (value < 0) {",
            "#{INDENT * 2}offset = mt_format_append_bytes(target, offset, \"-\", 1);",
            "#{INDENT * 2}return mt_format_append_ulong_hex_upper(target, offset, ((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}}",
            "#{INDENT}return mt_format_append_ulong_hex_upper(target, offset, (uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_append_ulong_oct']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_ulong_oct(mt_str target, uintptr_t offset, uint64_t value) {",
            "#{INDENT}uintptr_t len = mt_format_ulong_oct_len(value);",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%llo\", (unsigned long long)value);",
            "#{INDENT}if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format unsigned octal\");",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        if helpers['mt_format_append_long_oct']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_long_oct(mt_str target, uintptr_t offset, int64_t value) {",
            "#{INDENT}if (value < 0) {",
            "#{INDENT * 2}offset = mt_format_append_bytes(target, offset, \"-\", 1);",
            "#{INDENT * 2}return mt_format_append_ulong_oct(target, offset, ((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}}",
            "#{INDENT}return mt_format_append_ulong_oct(target, offset, (uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_append_ulong_bin']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_ulong_bin(mt_str target, uintptr_t offset, uint64_t value) {",
            "#{INDENT}uintptr_t len = mt_format_ulong_bin_len(value);",
            "#{INDENT}uintptr_t index = offset + len;",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}target.data[index] = '\\0';",
            "#{INDENT}do {",
            "#{INDENT * 2}index -= 1;",
            "#{INDENT * 2}target.data[index] = (char)('0' + (value & 1));",
            "#{INDENT * 2}value >>= 1;",
            "#{INDENT}} while (index > offset);",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        if helpers['mt_format_append_long_bin']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_long_bin(mt_str target, uintptr_t offset, int64_t value) {",
            "#{INDENT}if (value < 0) {",
            "#{INDENT * 2}offset = mt_format_append_bytes(target, offset, \"-\", 1);",
            "#{INDENT * 2}return mt_format_append_ulong_bin(target, offset, ((uint64_t)(-(value + 1))) + 1);",
            "#{INDENT}}",
            "#{INDENT}return mt_format_append_ulong_bin(target, offset, (uint64_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_append_int']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_int(mt_str target, uintptr_t offset, int32_t value) {",
            "#{INDENT}if (value < 0) {",
            "#{INDENT * 2}offset = mt_format_append_bytes(target, offset, \"-\", 1);",
            "#{INDENT * 2}return mt_format_append_ptr_uint(target, offset, (uintptr_t)(-((int64_t)value)));",
            "#{INDENT}}",
            "#{INDENT}return mt_format_append_ptr_uint(target, offset, (uintptr_t)value);",
            "}",
          ])
        end

        if helpers['mt_format_append_float']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_float(mt_str target, uintptr_t offset, float value) {",
            "#{INDENT}uintptr_t len = mt_format_float_len(value);",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%g\", (double)value);",
            "#{INDENT}if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format float\");",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        if helpers['mt_format_append_double']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_double(mt_str target, uintptr_t offset, double value) {",
            "#{INDENT}uintptr_t len = mt_format_double_len(value);",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%g\", value);",
            "#{INDENT}if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format double\");",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        if helpers['mt_format_append_double_precision']
          lines << "" unless lines.empty?
          lines.concat([
            "static uintptr_t mt_format_append_double_precision(mt_str target, uintptr_t offset, double value, int32_t precision) {",
            "#{INDENT}uintptr_t len = mt_format_double_precision_len(value, precision);",
            "#{INDENT}mt_format_check_capacity(target, offset, len);",
            "#{INDENT}int written = snprintf(target.data + offset, (size_t)(target.len - offset + 1), \"%.*f\", precision, value);",
            "#{INDENT}if (written < 0 || (uintptr_t)written != len) mt_fatal(\"format string could not format double precision\");",
            "#{INDENT}return offset + len;",
            "}",
          ])
        end

        lines
      end

      def emit_fmt_builder_helpers
        return [] unless uses_fmt_builder?

        [
          "typedef struct {",
          "#{INDENT}char* data;",
          "#{INDENT}uintptr_t capacity;",
          "#{INDENT}uintptr_t offset;",
          "} mt_fmt_builder;",
          "",
          "static inline mt_fmt_builder mt_fmt_begin(uintptr_t capacity) {",
          "#{INDENT}mt_fmt_builder b;",
          "#{INDENT}b.data = (char*)malloc((size_t)capacity);",
          "#{INDENT}b.capacity = capacity;",
          "#{INDENT}b.offset = 0;",
          "#{INDENT}return b;",
          "}",
          "",
          "static inline void mt_fmt_cleanup(mt_fmt_builder b) {",
          "#{INDENT}free(b.data);",
          "}",
          "",
          "static inline mt_str mt_fmt_finish(mt_fmt_builder* b) {",
          "#{INDENT}return (mt_str){ .data = b->data, .len = b->offset };",
          "}",
          "",
          "static inline void mt_fmt_write_bytes(mt_fmt_builder* b, const char* data, uintptr_t len) {",
          "#{INDENT}mt_fmt_builder buf = *b;",
          "#{INDENT}b->offset = mt_format_append_bytes((mt_str){ .data = buf.data, .len = buf.capacity }, buf.offset, data, len);",
          "}",
          "",
          "static inline void mt_fmt_write_str(mt_fmt_builder* b, mt_str value) {",
          "#{INDENT}mt_fmt_write_bytes(b, value.data, value.len);",
          "}",
          "",
          "static inline void mt_fmt_write_int(mt_fmt_builder* b, int32_t value) {",
          "#{INDENT}mt_fmt_builder buf = *b;",
          "#{INDENT}b->offset = mt_format_append_int((mt_str){ .data = buf.data, .len = buf.capacity }, buf.offset, value);",
          "}",
          "",
          "static inline void mt_fmt_write_ptr_uint(mt_fmt_builder* b, uintptr_t value) {",
          "#{INDENT}mt_fmt_builder buf = *b;",
          "#{INDENT}b->offset = mt_format_append_ptr_uint((mt_str){ .data = buf.data, .len = buf.capacity }, buf.offset, value);",
          "}",
          "",
          "static inline void mt_fmt_write_long_hex(mt_fmt_builder* b, int64_t value) {",
          "#{INDENT}mt_fmt_builder buf = *b;",
          "#{INDENT}b->offset = mt_format_append_long_hex((mt_str){ .data = buf.data, .len = buf.capacity }, buf.offset, value);",
          "}",
          "",
          "static inline void mt_fmt_write_long_hex_upper(mt_fmt_builder* b, int64_t value) {",
          "#{INDENT}mt_fmt_builder buf = *b;",
          "#{INDENT}b->offset = mt_format_append_long_hex_upper((mt_str){ .data = buf.data, .len = buf.capacity }, buf.offset, value);",
          "}",
          "",
          "static inline void mt_fmt_write_long_oct(mt_fmt_builder* b, int64_t value) {",
          "#{INDENT}mt_fmt_builder buf = *b;",
          "#{INDENT}b->offset = mt_format_append_long_oct((mt_str){ .data = buf.data, .len = buf.capacity }, buf.offset, value);",
          "}",
          "",
          "static inline void mt_fmt_write_long_bin(mt_fmt_builder* b, int64_t value) {",
          "#{INDENT}mt_fmt_builder buf = *b;",
          "#{INDENT}b->offset = mt_format_append_long_bin((mt_str){ .data = buf.data, .len = buf.capacity }, buf.offset, value);",
          "}",
          "",
          "static inline void mt_fmt_write_double_precision(mt_fmt_builder* b, double value, int32_t precision) {",
          "#{INDENT}mt_fmt_builder buf = *b;",
          "#{INDENT}b->offset = mt_format_append_double_precision((mt_str){ .data = buf.data, .len = buf.capacity }, buf.offset, value, precision);",
          "}",
        ]
      end
    end
  end
end
