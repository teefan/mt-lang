# frozen_string_literal: true

module MilkTea
  class CBackend
    module RuntimeHelpers
      def emit_fatal_helper
        lines = []

        if uses_mt_fatal_helper?
          lines.concat([
            "static _Noreturn void mt_fatal(const char* message) {",
            "#{INDENT}fputs(message, stderr);",
            "#{INDENT}fputc('\\n', stderr);",
            "#{INDENT}abort();",
            "}",
          ])
        end

        if uses_mt_fatal_str_helper?
          lines << "" unless lines.empty?
          lines.concat([
            "static _Noreturn void mt_fatal_str(mt_str message) {",
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

      def emit_variant_equality_helpers
        emitted_aggregate_variants.flat_map { |variant_decl| emit_variant_equality_helper(variant_decl) }
      end

      def emit_variant_equality_helper(variant_decl)
        outer_c = variant_decl.linkage_name
        lines = ["static bool mt_variant_eq_#{outer_c}(struct #{outer_c} left, struct #{outer_c} right) {"]
        lines << "#{INDENT}if (left.kind != right.kind) return false;"
        lines << "#{INDENT}switch (left.kind) {"

        variant_decl.arms.each do |arm|
          lines << "#{INDENT * 2}case #{outer_c}_kind_#{arm.name}:"
          if arm.fields.empty?
            lines << "#{INDENT * 3}return true;"
          else
            arm.fields.each do |field|
              field_type = field.type
              left_expr = "left.data.#{sanitize_c_identifier(arm.name)}.#{sanitize_c_identifier(field.name)}"
              right_expr = "right.data.#{sanitize_c_identifier(arm.name)}.#{sanitize_c_identifier(field.name)}"
              if field_type.is_a?(Types::StringView)
                lines << "#{INDENT * 3}if (!mt_str_equal(#{left_expr}, #{right_expr})) return false;"
              elsif field_type.is_a?(Types::Variant)
                lines << "#{INDENT * 3}if (!mt_variant_eq_#{named_type_c_name(field_type)}(#{left_expr}, #{right_expr})) return false;"
              elsif field_type.is_a?(Types::Primitive) || field_type.is_a?(Types::EnumBase) || field_type.is_a?(Types::Nullable)
                lines << "#{INDENT * 3}if (#{left_expr} != #{right_expr}) return false;"
              else
                lines << "#{INDENT * 3}if (#{left_expr} != #{right_expr}) return false;"
              end
            end
            lines << "#{INDENT * 3}return true;"
          end
        end

        lines << "#{INDENT * 2}default: return true;"
        lines << "#{INDENT}}"
        lines << "}"
        lines
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

      def emit_detach_helpers
        [
          "typedef struct {",
          "#{INDENT}uv_thread_t thread;",
          "} mt_detach_handle;",
          "",
          "static void* mt_detach_run(void (*work)(void*), void* cap) {",
          "#{INDENT}mt_detach_handle* h = (mt_detach_handle*)malloc(sizeof(mt_detach_handle));",
          "#{INDENT}uv_thread_create(&h->thread, work, cap);",
          "#{INDENT}return h;",
          "}",
          "",
          "static void mt_detach_join(void* handle) {",
          "#{INDENT}if (!handle) return;",
          "#{INDENT}mt_detach_handle* h = (mt_detach_handle*)handle;",
          "#{INDENT}uv_thread_join(&h->thread);",
          "#{INDENT}free(h);",
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
            "#{INDENT}uintptr_t len = argc > 0 ? (uintptr_t)argc : 0;",
            "#{INDENT}mt_str* items = NULL;",
            "#{INDENT}uintptr_t index = 0;",
            "#{INDENT}if (len > 0) {",
            "#{INDENT * 2}items = (mt_str*)malloc(len * sizeof(mt_str));",
            "#{INDENT * 2}if (items == NULL) abort();",
            "#{INDENT}}",
            "#{INDENT}while (index < len) {",
            "#{INDENT * 2}char* value = argv[index];",
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
        params = [c_declaration(type, '(*array)'), c_declaration(Types::Registry.primitive('ptr_uint'), 'index')].join(', ')
        [
          "static inline #{c_function_declaration(pointer_to(array_element_type(type)), helper_name, params)} {",
          "#{INDENT}if (index >= #{array_length(type)}) mt_fatal(\"array index out of bounds\");",
          "#{INDENT}return &(*array)[index];",
          "}",
        ]
      end

      def emit_checked_span_index_helper(type)
        helper_name = checked_span_index_helper_name(type)
        params = [c_declaration(type, 'span'), c_declaration(Types::Registry.primitive('ptr_uint'), 'index')].join(', ')
        [
          "static inline #{c_function_declaration(pointer_to(type.element_type), helper_name, params)} {",
          "#{INDENT}if (index >= span.len) mt_fatal(\"span index out of bounds\");",
          "#{INDENT}return &span.data[index];",
          "}",
        ]
      end

      def emit_nullable_array_index_helper(type)
        helper_name = nullable_array_index_helper_name(type)
        params = [c_declaration(type, '(*array)'), c_declaration(Types::Registry.primitive('ptr_uint'), 'index')].join(', ')
        [
          "static inline #{c_function_declaration(pointer_to(array_element_type(type)), helper_name, params)} {",
          "#{INDENT}if (index >= #{array_length(type)}) return NULL;",
          "#{INDENT}return &(*array)[index];",
          "}",
        ]
      end

      def emit_nullable_span_index_helper(type)
        helper_name = nullable_span_index_helper_name(type)
        params = [c_declaration(type, 'span'), c_declaration(Types::Registry.primitive('ptr_uint'), 'index')].join(', ')
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
