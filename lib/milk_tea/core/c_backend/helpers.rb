# frozen_string_literal: true

module MilkTea
  class CBackend
    module CBackendHelpers
      private

          def emit_fatal_helper
            lines = []

            if uses_mt_fatal_helper?
              lines.concat([
                "static void mt_fatal(const char* message) {",
                "#{INDENT}fputs(message, stderr);",
                "#{INDENT}fputc('\\n', stderr);",
                "#{INDENT}abort();",
                "}",
              ])
            end

            if uses_mt_fatal_str_helper?
              lines << "" unless lines.empty?
              lines.concat([
                "static void mt_fatal_str(mt_str message) {",
                "#{INDENT}fwrite(message.data, 1, message.len, stderr);",
                "#{INDENT}fputc('\\n', stderr);",
                "#{INDENT}abort();",
                "}",
              ])
            end

            lines
          end

          def emit_str_equality_helper
            [
              "static bool mt_str_equal(mt_str left, mt_str right) {",
              "#{INDENT}if (left.len != right.len) return false;",
              "#{INDENT}for (uintptr_t index = 0; index < left.len; index++) {",
              "#{INDENT * 2}if (left.data[index] != right.data[index]) return false;",
              "#{INDENT}}",
              "#{INDENT}return true;",
              "}",
            ]
          end

          def emit_async_memory_helpers
            [
              "#define MT_ASYNC_HEADER_SIZE (sizeof(uint64_t) + sizeof(uintptr_t))",
              "#define MT_ASYNC_MAGIC UINT64_C(0x4D5441464D454D00)",
              "",
              "static void* mt_async_alloc(uintptr_t size) {",
              "#{INDENT}char* raw = (char*) calloc(1, (size_t)(MT_ASYNC_HEADER_SIZE + size));",
              "#{INDENT}if (raw == NULL) {",
              "#{INDENT * 2}abort();",
              "#{INDENT}}",
              "#{INDENT}*(uint64_t*)raw = MT_ASYNC_MAGIC;",
              "#{INDENT}*(uintptr_t*)(raw + sizeof(uint64_t)) = 1;",
              "#{INDENT}return raw + MT_ASYNC_HEADER_SIZE;",
              "}",
              "",
              "static void mt_async_retain(void* frame) {",
              "#{INDENT}char* raw = (char*)frame - MT_ASYNC_HEADER_SIZE;",
              "#{INDENT}if (*(uint64_t*)raw != MT_ASYNC_MAGIC) return;",
              "#{INDENT}uintptr_t* ref = (uintptr_t*)(raw + sizeof(uint64_t));",
              "#{INDENT}(*ref)++;",
              "}",
              "",
              "static void mt_async_free(void* frame) {",
              "#{INDENT}char* raw = (char*)frame - MT_ASYNC_HEADER_SIZE;",
              "#{INDENT}if (*(uint64_t*)raw != MT_ASYNC_MAGIC) return;",
              "#{INDENT}uintptr_t* ref = (uintptr_t*)(raw + sizeof(uint64_t));",
              "#{INDENT}if (--(*ref) == 0) {",
              "#{INDENT * 2}free(raw);",
              "#{INDENT}}",
              "}",
            ]
          end

          def emit_parallel_for_helper
            [
              "typedef struct {",
              "#{INDENT}void (*work)(void* data, int64_t start, int64_t end);",
              "#{INDENT}void* data;",
              "#{INDENT}int64_t start;",
              "#{INDENT}int64_t end;",
              "} mt_pfor_chunk;",
              "",
              "static void mt_pfor_runner(void* arg) {",
              "#{INDENT}mt_pfor_chunk* chunk = (mt_pfor_chunk*)arg;",
              "#{INDENT}chunk->work(chunk->data, chunk->start, chunk->end);",
              "}",
              "",
              "static void mt_parallel_for(void (*work)(void* data, int64_t start, int64_t end), void* data, int64_t count) {",
              "#{INDENT}if (count <= 0) return;",
              "#{INDENT}uv_cpu_info_t* cpu_info;",
              "#{INDENT}int ncpu = 1;",
              "#{INDENT}if (uv_cpu_info(&cpu_info, &ncpu) == 0) {",
              "#{INDENT * 2}uv_free_cpu_info(cpu_info, ncpu);",
              "#{INDENT}}",
              "#{INDENT}if (ncpu < 1) ncpu = 1;",
              "#{INDENT}if (ncpu > 64) ncpu = 64;",
              "#{INDENT}if (count < (int64_t)ncpu) ncpu = (int)count;",
              "#{INDENT}int64_t chunk_size = (count + ncpu - 1) / ncpu;",
              "#{INDENT}mt_pfor_chunk chunks[64];",
              "#{INDENT}uv_thread_t threads[64];",
              "#{INDENT}int nworkers = 0;",
              "#{INDENT}for (int t = 1; t < ncpu; t++) {",
              "#{INDENT * 2}int64_t s = t * chunk_size;",
              "#{INDENT * 2}int64_t e = s + chunk_size;",
              "#{INDENT * 2}if (e > count) e = count;",
              "#{INDENT * 2}if (s >= count) break;",
              "#{INDENT * 2}chunks[nworkers].work = work;",
              "#{INDENT * 2}chunks[nworkers].data = data;",
              "#{INDENT * 2}chunks[nworkers].start = s;",
              "#{INDENT * 2}chunks[nworkers].end = e;",
              "#{INDENT * 2}uv_thread_create(&threads[nworkers], mt_pfor_runner, &chunks[nworkers]);",
              "#{INDENT * 2}nworkers++;",
              "#{INDENT}}",
              "#{INDENT}int64_t first_end = chunk_size < count ? chunk_size : count;",
              "#{INDENT}work(data, 0, first_end);",
              "#{INDENT}for (int t = 0; t < nworkers; t++) {",
              "#{INDENT * 2}uv_thread_join(&threads[t]);",
              "#{INDENT}}",
              "}",
            ]
          end

          def emit_spawn_all_helper
            [
              "typedef struct {",
              "#{INDENT}void (*work)(void* data);",
              "#{INDENT}void* data;",
              "} mt_spawn_item;",
              "",
              "static void mt_spawn_item_runner(void* arg) {",
              "#{INDENT}mt_spawn_item* item = (mt_spawn_item*)arg;",
              "#{INDENT}item->work(item->data);",
              "}",
              "",
              "static void mt_spawn_all(mt_spawn_item* items, int count) {",
              "#{INDENT}if (count <= 0) return;",
              "#{INDENT}uv_thread_t threads[64];",
              "#{INDENT}int nworkers = 0;",
              "#{INDENT}for (int t = 1; t < count && nworkers < 63; t++) {",
              "#{INDENT * 2}uv_thread_create(&threads[nworkers], mt_spawn_item_runner, &items[t]);",
              "#{INDENT * 2}nworkers++;",
              "#{INDENT}}",
              "#{INDENT}items[0].work(items[0].data);",
              "#{INDENT}for (int t = 0; t < nworkers; t++) {",
              "#{INDENT * 2}uv_thread_join(&threads[t]);",
              "#{INDENT}}",
              "}",
            ]
          end

          def emit_format_helpers
            helpers = used_format_helpers
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

          def emit_foreign_temp_cstr_helpers
            lines = []

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_foreign_str_to_cstr_temp]) }
              lines.concat([
                "static const char* mt_foreign_str_to_cstr_temp(mt_str value) {",
                "#{INDENT}char* data = (char*)malloc(value.len + 1);",
                "#{INDENT}uintptr_t index = 0;",
                "#{INDENT}if (data == NULL) mt_fatal(\"foreign str temporary allocation failed\");",
                "#{INDENT}while (index < value.len) {",
                "#{INDENT * 2}data[index] = value.data[index];",
                "#{INDENT * 2}index++;",
                "#{INDENT}}",
                "#{INDENT}data[value.len] = '\\0';",
                "#{INDENT}return data;",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_free_foreign_cstr_temp]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static void mt_free_foreign_cstr_temp(const char* value) {",
                "#{INDENT}free((void*)value);",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_foreign_strs_to_cstrs_temp]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static void mt_foreign_strs_to_cstrs_temp(mt_span_str values, char*** items_out, char** data_out, uintptr_t* len_out) {",
                "#{INDENT}uintptr_t total_bytes = 0;",
                "#{INDENT}uintptr_t index = 0;",
                "#{INDENT}uintptr_t offset = 0;",
                "#{INDENT}char** items = NULL;",
                "#{INDENT}char* data = NULL;",
                "#{INDENT}while (index < values.len) {",
                "#{INDENT * 2}total_bytes += values.data[index].len + 1;",
                "#{INDENT * 2}index++;",
                "#{INDENT}}",
                "#{INDENT}if (values.len > 0) {",
                "#{INDENT * 2}items = (char**)malloc(values.len * sizeof(char*));",
                "#{INDENT * 2}if (items == NULL) mt_fatal(\"foreign string-list temporary allocation failed\");",
                "#{INDENT}}",
                "#{INDENT}if (total_bytes > 0) {",
                "#{INDENT * 2}data = (char*)malloc(total_bytes);",
                "#{INDENT * 2}if (data == NULL) {",
                "#{INDENT * 3}free(items);",
                "#{INDENT * 3}mt_fatal(\"foreign string-list temporary allocation failed\");",
                "#{INDENT * 2}}",
                "#{INDENT}}",
                "#{INDENT}index = 0;",
                "#{INDENT}while (index < values.len) {",
                "#{INDENT * 2}mt_str value = values.data[index];",
                "#{INDENT * 2}uintptr_t byte_index = 0;",
                "#{INDENT * 2}items[index] = data + offset;",
                "#{INDENT * 2}while (byte_index < value.len) {",
                "#{INDENT * 3}data[offset + byte_index] = value.data[byte_index];",
                "#{INDENT * 3}byte_index++;",
                "#{INDENT * 2}}",
                "#{INDENT * 2}data[offset + value.len] = '\\0';",
                "#{INDENT * 2}offset += value.len + 1;",
                "#{INDENT * 2}index++;",
                "#{INDENT}}",
                "#{INDENT}*items_out = items;",
                "#{INDENT}*data_out = data;",
                "#{INDENT}*len_out = values.len;",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_free_foreign_cstrs_temp]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static void mt_free_foreign_cstrs_temp(char** items, char* data) {",
                "#{INDENT}free(items);",
                "#{INDENT}free(data);",
                "}",
              ])
            end

            lines
          end

          def emit_entrypoint_argv_helpers
            lines = []

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_entry_argv_to_span_str]) }
              lines.concat([
                "static mt_span_str mt_entry_argv_to_span_str(int32_t argc, char** argv, mt_str** items_out) {",
                "#{INDENT}uintptr_t len = argc > 1 ? (uintptr_t)(argc - 1) : 0;",
                "#{INDENT}mt_str* items = NULL;",
                "#{INDENT}uintptr_t index = 0;",
                "#{INDENT}if (len > 0) {",
                "#{INDENT * 2}items = (mt_str*)malloc(len * sizeof(mt_str));",
                "#{INDENT * 2}if (items == NULL) abort();",
                "#{INDENT}}",
                "#{INDENT}while (index < len) {",
                "#{INDENT * 2}char* value = argv[index + 1];",
                "#{INDENT * 2}items[index] = (mt_str){ .data = value, .len = (uintptr_t)strlen(value) };",
                "#{INDENT * 2}index++;",
                "#{INDENT}}",
                "#{INDENT}*items_out = items;",
                "#{INDENT}return (mt_span_str){ .data = items, .len = len };",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_free_entry_argv_strs]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static void mt_free_entry_argv_strs(mt_str* items) {",
                "#{INDENT}free(items);",
                "}",
              ])
            end

            lines
          end

          def emit_text_buffer_helpers
            [
              "static bool mt_is_utf8_continuation_byte(unsigned char byte) {",
              "#{INDENT}return (byte & 0xC0u) == 0x80u;",
              "}",
              "",
              "static bool mt_is_valid_utf8(const char* data, uintptr_t len) {",
              "#{INDENT}uintptr_t index = 0;",
              "#{INDENT}while (index < len) {",
              "#{INDENT * 2}unsigned char lead = (unsigned char) data[index];",
              "#{INDENT * 2}if (lead < 0x80u) {",
              "#{INDENT * 3}index++;",
              "#{INDENT * 3}continue;",
              "#{INDENT * 2}}",
              "#{INDENT * 2}if (lead < 0xC2u) return false;",
              "#{INDENT * 2}if (lead < 0xE0u) {",
              "#{INDENT * 3}if (index + 1 >= len) return false;",
              "#{INDENT * 3}unsigned char byte1 = (unsigned char) data[index + 1];",
              "#{INDENT * 3}if (!mt_is_utf8_continuation_byte(byte1)) return false;",
              "#{INDENT * 3}index += 2;",
              "#{INDENT * 3}continue;",
              "#{INDENT * 2}}",
              "#{INDENT * 2}if (lead < 0xF0u) {",
              "#{INDENT * 3}if (index + 2 >= len) return false;",
              "#{INDENT * 3}unsigned char byte1 = (unsigned char) data[index + 1];",
              "#{INDENT * 3}unsigned char byte2 = (unsigned char) data[index + 2];",
              "#{INDENT * 3}if (lead == 0xE0u) {",
              "#{INDENT * 4}if (byte1 < 0xA0u || byte1 > 0xBFu) return false;",
              "#{INDENT * 3}} else if (lead == 0xEDu) {",
              "#{INDENT * 4}if (byte1 < 0x80u || byte1 > 0x9Fu) return false;",
              "#{INDENT * 3}} else if (!mt_is_utf8_continuation_byte(byte1)) {",
              "#{INDENT * 4}return false;",
              "#{INDENT * 3}}",
              "#{INDENT * 3}if (!mt_is_utf8_continuation_byte(byte2)) return false;",
              "#{INDENT * 3}index += 3;",
              "#{INDENT * 3}continue;",
              "#{INDENT * 2}}",
              "#{INDENT * 2}if (lead < 0xF5u) {",
              "#{INDENT * 3}if (index + 3 >= len) return false;",
              "#{INDENT * 3}unsigned char byte1 = (unsigned char) data[index + 1];",
              "#{INDENT * 3}unsigned char byte2 = (unsigned char) data[index + 2];",
              "#{INDENT * 3}unsigned char byte3 = (unsigned char) data[index + 3];",
              "#{INDENT * 3}if (lead == 0xF0u) {",
              "#{INDENT * 4}if (byte1 < 0x90u || byte1 > 0xBFu) return false;",
              "#{INDENT * 3}} else if (lead == 0xF4u) {",
              "#{INDENT * 4}if (byte1 < 0x80u || byte1 > 0x8Fu) return false;",
              "#{INDENT * 3}} else if (!mt_is_utf8_continuation_byte(byte1)) {",
              "#{INDENT * 4}return false;",
              "#{INDENT * 3}}",
              "#{INDENT * 3}if (!mt_is_utf8_continuation_byte(byte2) || !mt_is_utf8_continuation_byte(byte3)) return false;",
              "#{INDENT * 3}index += 4;",
              "#{INDENT * 3}continue;",
              "#{INDENT * 2}}",
              "#{INDENT * 2}return false;",
              "#{INDENT}}",
              "#{INDENT}return true;",
              "}",
            ]
          end

          def emit_str_buffer_helpers
            lines = []

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_len mt_str_buffer_as_cstr mt_str_buffer_append]) }
              lines.concat([
                "static uintptr_t mt_str_buffer_len(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
                "#{INDENT}if (*dirty) {",
                "#{INDENT * 2}uintptr_t current = 0;",
                "#{INDENT * 2}while (current < cap + 1 && data[current] != '\\0') {",
                "#{INDENT * 3}current++;",
                "#{INDENT * 2}}",
                "#{INDENT * 2}if (current > cap) mt_fatal(\"str_buffer text requires a trailing NUL within capacity\");",
                "#{INDENT * 2}if (!mt_is_valid_utf8(data, current)) mt_fatal(\"str_buffer text must be valid UTF-8\");",
                "#{INDENT * 2}*len = current;",
                "#{INDENT * 2}*dirty = false;",
                "#{INDENT}}",
                "#{INDENT}return *len;",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_as_cstr]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static const char* mt_str_buffer_as_cstr(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
                "#{INDENT}(void)mt_str_buffer_len(data, cap, len, dirty);",
                "#{INDENT}return data;",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_clear]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static void mt_str_buffer_clear(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
                "#{INDENT}memset(data, 0, cap + 1);",
                "#{INDENT}*len = 0;",
                "#{INDENT}*dirty = false;",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_assign]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static void mt_str_buffer_assign(mt_str value, char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
                "#{INDENT}if (value.len > cap) mt_fatal(\"str_buffer.assign exceeds capacity\");",
                "#{INDENT}memcpy(data, value.data, value.len);",
                "#{INDENT}data[value.len] = '\\0';",
                "#{INDENT}if (value.len < cap + 1) memset(data + value.len + 1, 0, cap - value.len);",
                "#{INDENT}*len = value.len;",
                "#{INDENT}*dirty = false;",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_append]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static void mt_str_buffer_append(mt_str value, char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
                "#{INDENT}uintptr_t current = mt_str_buffer_len(data, cap, len, dirty);",
                "#{INDENT}if (value.len > cap - current) mt_fatal(\"str_buffer.append exceeds capacity\");",
                "#{INDENT}memcpy(data + current, value.data, value.len);",
                "#{INDENT}current += value.len;",
                "#{INDENT}data[current] = '\\0';",
                "#{INDENT}*len = current;",
                "#{INDENT}*dirty = false;",
                "}",
              ])
            end

            if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_prepare_write]) }
              lines << "" unless lines.empty?
              lines.concat([
                "static char* mt_str_buffer_prepare_write(char* data, uintptr_t cap, bool* dirty) {",
                "#{INDENT}data[cap] = '\\0';",
                "#{INDENT}*dirty = true;",
                "#{INDENT}return data;",
                "}",
              ])
            end

            lines
          end

          def emit_checked_array_index_helper(type)
            helper_name = checked_array_index_helper_name(type)
            params = [c_declaration(type, '(*array)'), c_declaration(Types::Primitive.new('ptr_uint'), 'index')].join(', ')
            [
              "static inline #{c_function_declaration(pointer_to(array_element_type(type)), helper_name, params)} {",
              "#{INDENT}if (index >= #{array_length(type)}) mt_fatal(\"array index out of bounds\");",
              "#{INDENT}return &(*array)[index];",
              "}",
            ]
          end

          def emit_checked_span_index_helper(type)
            helper_name = checked_span_index_helper_name(type)
            params = [c_declaration(type, 'span'), c_declaration(Types::Primitive.new('ptr_uint'), 'index')].join(', ')
            [
              "static inline #{c_function_declaration(pointer_to(type.element_type), helper_name, params)} {",
              "#{INDENT}if (index >= span.len) mt_fatal(\"span index out of bounds\");",
              "#{INDENT}return &span.data[index];",
              "}",
            ]
          end

          def emit_nullable_array_index_helper(type)
            helper_name = nullable_array_index_helper_name(type)
            params = [c_declaration(type, '(*array)'), c_declaration(Types::Primitive.new('ptr_uint'), 'index')].join(', ')
            [
              "static inline #{c_function_declaration(pointer_to(array_element_type(type)), helper_name, params)} {",
              "#{INDENT}if (index >= #{array_length(type)}) return NULL;",
              "#{INDENT}return &(*array)[index];",
              "}",
            ]
          end

          def emit_nullable_span_index_helper(type)
            helper_name = nullable_span_index_helper_name(type)
            params = [c_declaration(type, 'span'), c_declaration(Types::Primitive.new('ptr_uint'), 'index')].join(', ')
            [
              "static inline #{c_function_declaration(pointer_to(type.element_type), helper_name, params)} {",
              "#{INDENT}if (index >= span.len) return NULL;",
              "#{INDENT}return &span.data[index];",
              "}",
            ]
          end

          def emit_str_literal_constants(literals)
            literals.each_with_index.map do |value, i|
              "static const mt_str #{str_literal_name(i)} = { .data = #{value.inspect}, .len = #{value.bytesize} };"
            end
          end

          def str_literal_name(index)
            "mt_str_lit_#{index}"
          end
    end
  end
end
