# frozen_string_literal: true

module MilkTea
  class CBackend
    INDENT = "  "

    def self.emit(program)
      new(program).emit
    end

    def initialize(program)
      @program = program
    end

    def emit
      lines = []
      constants = emitted_constants
      headers = @program.includes.map(&:header)
      if uses_panic_helper?
        headers << "<stdio.h>"
        headers << "<stdlib.h>"
      end
      headers.uniq.each do |header|
        lines << "#include #{header}"
      end
      lines << ""

      lines.concat(emit_string_type)
      lines << ""

      if uses_panic_helper?
        lines.concat(emit_panic_helper)
        lines << ""
      end

      if uses_text_buffer_helpers?
        lines.concat(emit_text_buffer_helpers)
        lines << ""
      end

      opaque_decls = @program.opaques
      struct_decls = sort_struct_decls(@program.structs + collect_generic_struct_decls + collect_result_decls + collect_str_builder_decls)

      forward_declarations = emit_forward_declarations(opaque_decls, struct_decls)
      unless forward_declarations.empty?
        lines.concat(forward_declarations)
        lines << ""
      end

      @program.enums.each do |enum_decl|
        lines.concat(emit_enum(enum_decl))
        lines << ""
      end

      collect_span_types.each do |type|
        lines.concat(emit_span_type(type))
        lines << ""
      end

      if uses_foreign_temp_cstr_helpers?
        lines.concat(emit_foreign_temp_cstr_helpers)
        lines << ""
      end

      if uses_str_builder_helpers?
        lines.concat(emit_str_builder_helpers)
        lines << ""
      end

      struct_decls.each do |struct_decl|
        lines.concat(emit_struct(struct_decl))
        lines << ""
      end

      @program.unions.each do |union_decl|
        lines.concat(emit_union(union_decl))
        lines << ""
      end

      array_return_types = collect_array_return_types
      array_return_types.each do |type|
        lines.concat(emit_array_return_wrapper(type))
        lines << ""
      end

      function_declarations = emit_function_declarations(@program.functions)
      unless function_declarations.empty?
        lines.concat(function_declarations)
        lines << ""
      end

      constants.each do |constant|
        lines << "#{constant_storage(constant.type)} #{c_declaration(constant.type, constant.c_name)} = #{emit_initializer(constant.value)};"
      end
      lines << "" unless constants.empty?

      @program.static_asserts.each do |statement|
        lines << emit_static_assert(statement)
      end
      lines << "" unless @program.static_asserts.empty?

      reinterpret_helpers = collect_reinterpret_helpers
      reinterpret_helpers.each do |helper|
        lines.concat(emit_reinterpret_helper(helper))
        lines << ""
      end

      checked_array_index_types = collect_checked_array_index_types
      checked_array_index_types.each do |type|
        lines.concat(emit_checked_array_index_helper(type))
        lines << ""
      end

      checked_span_index_types = collect_checked_span_index_types
      checked_span_index_types.each do |type|
        lines.concat(emit_checked_span_index_helper(type))
        lines << ""
      end

      @program.functions.each do |function|
        lines.concat(emit_function(function))
        lines << ""
      end

      lines.join("\n").rstrip + "\n"
    end

    private

    def emitted_constants
      @emitted_constants ||= begin
        constants_by_name = @program.constants.each_with_object({}) do |constant, result|
          result[constant.c_name] = constant
        end
        referenced_names = {}
        root_module_prefix = "#{@program.module_name.tr('.', '_')}_"

        @program.constants.each do |constant|
          next unless constant.c_name.start_with?(root_module_prefix)

          referenced_names[constant.c_name] = true
          collect_referenced_constant_names_from_expression(constant.value, constants_by_name, referenced_names)
        end

        @program.static_asserts.each do |statement|
          collect_referenced_constant_names_from_expression(statement.condition, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_expression(statement.message, constants_by_name, referenced_names)
        end

        @program.functions.each do |function|
          collect_referenced_constant_names_from_statements(function.body, constants_by_name, referenced_names)
        end

        @program.constants.select { |constant| referenced_names[constant.c_name] }
      end
    end

    def collect_referenced_constant_names_from_statements(statements, constants_by_name, referenced_names)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_referenced_constant_names_from_expression(statement.value, constants_by_name, referenced_names)
        when IR::Assignment
          collect_referenced_constant_names_from_expression(statement.target, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_expression(statement.value, constants_by_name, referenced_names)
        when IR::BlockStmt, IR::WhileStmt
          collect_referenced_constant_names_from_statements(statement.body, constants_by_name, referenced_names)
        when IR::IfStmt
          collect_referenced_constant_names_from_expression(statement.condition, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_statements(statement.then_body, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_statements(statement.else_body, constants_by_name, referenced_names) if statement.else_body
        when IR::SwitchStmt
          collect_referenced_constant_names_from_expression(statement.expression, constants_by_name, referenced_names)
          statement.cases.each do |switch_case|
            collect_referenced_constant_names_from_expression(switch_case.value, constants_by_name, referenced_names)
            collect_referenced_constant_names_from_statements(switch_case.body, constants_by_name, referenced_names)
          end
        when IR::StaticAssert
          collect_referenced_constant_names_from_expression(statement.condition, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_expression(statement.message, constants_by_name, referenced_names)
        when IR::ReturnStmt
          collect_referenced_constant_names_from_expression(statement.value, constants_by_name, referenced_names) if statement.value
        when IR::ExpressionStmt
          collect_referenced_constant_names_from_expression(statement.expression, constants_by_name, referenced_names)
        end
      end
    end

    def collect_referenced_constant_names_from_expression(expression, constants_by_name, referenced_names)
      case expression
      when IR::Name
        constant = constants_by_name[expression.name]
        return unless constant
        return if referenced_names[constant.c_name]

        referenced_names[constant.c_name] = true
        collect_referenced_constant_names_from_expression(constant.value, constants_by_name, referenced_names)
      when IR::Member
        collect_referenced_constant_names_from_expression(expression.receiver, constants_by_name, referenced_names)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_referenced_constant_names_from_expression(expression.receiver, constants_by_name, referenced_names)
        collect_referenced_constant_names_from_expression(expression.index, constants_by_name, referenced_names)
      when IR::Call
        collect_referenced_constant_names_from_expression(expression.callee, constants_by_name, referenced_names) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_referenced_constant_names_from_expression(argument, constants_by_name, referenced_names) }
      when IR::Unary
        collect_referenced_constant_names_from_expression(expression.operand, constants_by_name, referenced_names)
      when IR::Binary
        collect_referenced_constant_names_from_expression(expression.left, constants_by_name, referenced_names)
        collect_referenced_constant_names_from_expression(expression.right, constants_by_name, referenced_names)
      when IR::Conditional
        collect_referenced_constant_names_from_expression(expression.condition, constants_by_name, referenced_names)
        collect_referenced_constant_names_from_expression(expression.then_expression, constants_by_name, referenced_names)
        collect_referenced_constant_names_from_expression(expression.else_expression, constants_by_name, referenced_names)
      when IR::ReinterpretExpr, IR::AddressOf, IR::Cast
        collect_referenced_constant_names_from_expression(expression.expression, constants_by_name, referenced_names)
      when IR::AggregateLiteral
        expression.fields.each { |field| collect_referenced_constant_names_from_expression(field.value, constants_by_name, referenced_names) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_referenced_constant_names_from_expression(element, constants_by_name, referenced_names) }
      end
    end

    def uses_panic_helper?
      uses_mt_panic_helper? || uses_mt_panic_str_helper?
    end

    def uses_mt_panic_helper?
      collect_checked_array_index_types.any? || collect_checked_span_index_types.any? ||
        @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_panic mt_str_buffer_len mt_str_buffer_as_cstr mt_str_builder_len mt_str_builder_as_cstr mt_str_builder_assign mt_str_builder_append mt_foreign_str_to_cstr_temp mt_foreign_strs_to_cstrs_temp]) }
    end

    def uses_mt_panic_str_helper?
      @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_panic_str]) }
    end

    def uses_foreign_temp_cstr_helpers?
      @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_foreign_str_to_cstr_temp mt_free_foreign_cstr_temp mt_foreign_strs_to_cstrs_temp mt_free_foreign_cstrs_temp]) }
    end

    def uses_text_buffer_helpers?
      @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_len mt_str_buffer_clear mt_str_buffer_as_cstr mt_str_builder_len mt_str_builder_as_cstr mt_str_builder_clear mt_str_builder_assign mt_str_builder_append mt_str_builder_prepare_write]) }
    end

    def uses_str_builder_helpers?
      @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_len mt_str_builder_as_cstr mt_str_builder_clear mt_str_builder_assign mt_str_builder_append mt_str_builder_prepare_write]) }
    end

    def function_uses_named_call?(function, callees)
      function.body.any? { |statement| statement_uses_named_call?(statement, callees) }
    end

    def statement_uses_named_call?(statement, callees)
      case statement
      when IR::LocalDecl
        expression_uses_named_call?(statement.value, callees)
      when IR::Assignment
        expression_uses_named_call?(statement.target, callees) || expression_uses_named_call?(statement.value, callees)
      when IR::BlockStmt, IR::WhileStmt
        statement.body.any? { |inner| statement_uses_named_call?(inner, callees) }
      when IR::IfStmt
        expression_uses_named_call?(statement.condition, callees) ||
          statement.then_body.any? { |inner| statement_uses_named_call?(inner, callees) } ||
          (statement.else_body && statement.else_body.any? { |inner| statement_uses_named_call?(inner, callees) })
      when IR::SwitchStmt
        expression_uses_named_call?(statement.expression, callees) || statement.cases.any? { |switch_case| switch_case.body.any? { |inner| statement_uses_named_call?(inner, callees) } }
      when IR::StaticAssert
        expression_uses_named_call?(statement.condition, callees) || expression_uses_named_call?(statement.message, callees)
      when IR::ReturnStmt
        statement.value && expression_uses_named_call?(statement.value, callees)
      when IR::ExpressionStmt
        expression_uses_named_call?(statement.expression, callees)
      else
        false
      end
    end

    def expression_uses_named_call?(expression, callees)
      case expression
      when IR::Call
        callees.include?(expression.callee) ||
          (!expression.callee.is_a?(String) && expression_uses_named_call?(expression.callee, callees)) ||
          expression.arguments.any? { |argument| expression_uses_named_call?(argument, callees) }
      when IR::Member
        expression_uses_named_call?(expression.receiver, callees)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        expression_uses_named_call?(expression.receiver, callees) || expression_uses_named_call?(expression.index, callees)
      when IR::Unary
        expression_uses_named_call?(expression.operand, callees)
      when IR::Binary
        expression_uses_named_call?(expression.left, callees) || expression_uses_named_call?(expression.right, callees)
      when IR::Conditional
        expression_uses_named_call?(expression.condition, callees) || expression_uses_named_call?(expression.then_expression, callees) || expression_uses_named_call?(expression.else_expression, callees)
      when IR::ReinterpretExpr, IR::Cast, IR::AddressOf
        expression_uses_named_call?(expression.expression, callees)
      when IR::AggregateLiteral
        expression.fields.any? { |field| expression_uses_named_call?(field.value, callees) }
      when IR::ArrayLiteral
        expression.elements.any? { |element| expression_uses_named_call?(element, callees) }
      else
        false
      end
    end

    def emit_panic_helper
      lines = []

      if uses_mt_panic_helper?
        lines.concat([
          "static void mt_panic(const char* message) {",
          "#{INDENT}fputs(message, stderr);",
          "#{INDENT}fputc('\\n', stderr);",
          "#{INDENT}abort();",
          "}",
        ])
      end

      if uses_mt_panic_str_helper?
        lines << "" unless lines.empty?
        lines.concat([
          "static void mt_panic_str(mt_str message) {",
          "#{INDENT}fwrite(message.data, 1, message.len, stderr);",
          "#{INDENT}fputc('\\n', stderr);",
          "#{INDENT}abort();",
          "}",
        ])
      end

      lines
    end

    def emit_foreign_temp_cstr_helpers
      lines = []

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_foreign_str_to_cstr_temp]) }
        lines.concat([
          "static const char* mt_foreign_str_to_cstr_temp(mt_str value) {",
          "#{INDENT}char* data = (char*)malloc(value.len + 1);",
          "#{INDENT}uintptr_t index = 0;",
          "#{INDENT}if (data == NULL) mt_panic(\"foreign str temporary allocation failed\");",
          "#{INDENT}while (index < value.len) {",
          "#{INDENT * 2}data[index] = value.data[index];",
          "#{INDENT * 2}index++;",
          "#{INDENT}}",
          "#{INDENT}data[value.len] = '\\0';",
          "#{INDENT}return data;",
          "}",
        ])
      end

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_free_foreign_cstr_temp]) }
        lines << "" unless lines.empty?
        lines.concat([
          "static void mt_free_foreign_cstr_temp(const char* value) {",
          "#{INDENT}free((void*)value);",
          "}",
        ])
      end

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_foreign_strs_to_cstrs_temp]) }
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
          "#{INDENT * 2}if (items == NULL) mt_panic(\"foreign string-list temporary allocation failed\");",
          "#{INDENT}}",
          "#{INDENT}if (total_bytes > 0) {",
          "#{INDENT * 2}data = (char*)malloc(total_bytes);",
          "#{INDENT * 2}if (data == NULL) {",
          "#{INDENT * 3}free(items);",
          "#{INDENT * 3}mt_panic(\"foreign string-list temporary allocation failed\");",
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

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_free_foreign_cstrs_temp]) }
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
        "",
        "static uintptr_t mt_str_buffer_len(const char* data, uintptr_t cap) {",
        "#{INDENT}uintptr_t len = 0;",
        "#{INDENT}while (len < cap && data[len] != '\\0') {",
        "#{INDENT * 2}len++;",
        "#{INDENT}}",
        "#{INDENT}if (!mt_is_valid_utf8(data, len)) mt_panic(\"str_buffer text must be valid UTF-8\");",
        "#{INDENT}return len;",
        "}",
        "",
        "static const char* mt_str_buffer_as_cstr(const char* data, uintptr_t cap) {",
        "#{INDENT}if (mt_str_buffer_len(data, cap) == cap) mt_panic(\"str_buffer.as_cstr requires a trailing NUL within capacity\");",
        "#{INDENT}return data;",
        "}",
        "",
        "static void mt_str_buffer_clear(char* data, uintptr_t cap) {",
        "#{INDENT}memset(data, 0, cap);",
        "}",
      ]
    end

    def emit_str_builder_helpers
      lines = []

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_len mt_str_builder_as_cstr mt_str_builder_append]) }
        lines.concat([
          "static uintptr_t mt_str_builder_len(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
          "#{INDENT}if (*dirty) {",
          "#{INDENT * 2}uintptr_t current = 0;",
          "#{INDENT * 2}while (current < cap + 1 && data[current] != '\\0') {",
          "#{INDENT * 3}current++;",
          "#{INDENT * 2}}",
          "#{INDENT * 2}if (current > cap) mt_panic(\"str_builder text requires a trailing NUL within capacity\");",
          "#{INDENT * 2}if (!mt_is_valid_utf8(data, current)) mt_panic(\"str_builder text must be valid UTF-8\");",
          "#{INDENT * 2}*len = current;",
          "#{INDENT * 2}*dirty = false;",
          "#{INDENT}}",
          "#{INDENT}return *len;",
          "}",
        ])
      end

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_as_cstr]) }
        lines << "" unless lines.empty?
        lines.concat([
          "static const char* mt_str_builder_as_cstr(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
          "#{INDENT}(void)mt_str_builder_len(data, cap, len, dirty);",
          "#{INDENT}return data;",
          "}",
        ])
      end

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_clear]) }
        lines << "" unless lines.empty?
        lines.concat([
          "static void mt_str_builder_clear(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
          "#{INDENT}memset(data, 0, cap + 1);",
          "#{INDENT}*len = 0;",
          "#{INDENT}*dirty = false;",
          "}",
        ])
      end

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_assign]) }
        lines << "" unless lines.empty?
        lines.concat([
          "static void mt_str_builder_assign(mt_str value, char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
          "#{INDENT}if (value.len > cap) mt_panic(\"str_builder.assign exceeds capacity\");",
          "#{INDENT}memcpy(data, value.data, value.len);",
          "#{INDENT}data[value.len] = '\\0';",
          "#{INDENT}if (value.len < cap + 1) memset(data + value.len + 1, 0, cap - value.len);",
          "#{INDENT}*len = value.len;",
          "#{INDENT}*dirty = false;",
          "}",
        ])
      end

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_append]) }
        lines << "" unless lines.empty?
        lines.concat([
          "static void mt_str_builder_append(mt_str value, char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
          "#{INDENT}uintptr_t current = mt_str_builder_len(data, cap, len, dirty);",
          "#{INDENT}if (value.len > cap - current) mt_panic(\"str_builder.append exceeds capacity\");",
          "#{INDENT}memcpy(data + current, value.data, value.len);",
          "#{INDENT}current += value.len;",
          "#{INDENT}data[current] = '\\0';",
          "#{INDENT}*len = current;",
          "#{INDENT}*dirty = false;",
          "}",
        ])
      end

      if @program.functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_prepare_write]) }
        lines << "" unless lines.empty?
        lines.concat([
          "static char* mt_str_builder_prepare_write(char* data, uintptr_t cap, bool* dirty) {",
          "#{INDENT}data[cap] = '\\0';",
          "#{INDENT}*dirty = true;",
          "#{INDENT}return data;",
          "}",
        ])
      end

      lines
    end

    def emit_string_type
      [
        "typedef struct mt_str {",
        "#{INDENT}char* data;",
        "#{INDENT}uintptr_t len;",
        "} mt_str;",
      ]
    end

    def emit_checked_array_index_helper(type)
      helper_name = checked_array_index_helper_name(type)
      params = [c_declaration(type, '(*array)'), c_declaration(Types::Primitive.new('usize'), 'index')].join(', ')
      [
        "static inline #{c_function_declaration(pointer_to(array_element_type(type)), helper_name, params)} {",
        "#{INDENT}if (index >= #{array_length(type)}) mt_panic(\"array index out of bounds\");",
        "#{INDENT}return &(*array)[index];",
        "}",
      ]
    end

    def emit_checked_span_index_helper(type)
      helper_name = checked_span_index_helper_name(type)
      params = [c_declaration(type, 'span'), c_declaration(Types::Primitive.new('usize'), 'index')].join(', ')
      [
        "static inline #{c_function_declaration(pointer_to(type.element_type), helper_name, params)} {",
        "#{INDENT}if (index >= span.len) mt_panic(\"span index out of bounds\");",
        "#{INDENT}return &span.data[index];",
        "}",
      ]
    end

    def emit_forward_declarations(opaque_decls, struct_decls)
      lines = []
      opaque_decls.uniq { |opaque_decl| opaque_decl.c_name }.each do |opaque_decl|
        next unless opaque_decl.forward_declarable
        next unless opaque_decl.c_name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        lines << "typedef struct #{opaque_decl.c_name} #{opaque_decl.c_name};"
      end
      struct_decls.each do |struct_decl|
        lines << "typedef struct #{struct_decl.c_name} #{struct_decl.c_name};"
      end
      @program.unions.each do |union_decl|
        lines << "typedef union #{union_decl.c_name} #{union_decl.c_name};"
      end
      lines
    end

    def emit_struct(struct_decl)
      lines = []
      lines << "struct #{struct_decl.c_name} {"
      struct_decl.fields.each do |field|
        lines << "#{INDENT}#{c_declaration(field.type, field.name)};"
      end
      lines << "}#{struct_layout_attributes(struct_decl)};"
      lines
    end

    def emit_union(union_decl)
      lines = []
      lines << "union #{union_decl.c_name} {"
      union_decl.fields.each do |field|
        lines << "#{INDENT}#{c_declaration(field.type, field.name)};"
      end
      lines << "};"
      lines
    end

    def emit_enum(enum_decl)
      lines = ["typedef #{c_type(enum_decl.backing_type)} #{enum_decl.c_name};"]
      return lines if enum_decl.members.empty?

      lines << "enum {"
      enum_decl.members.each_with_index do |member, index|
        suffix = index == enum_decl.members.length - 1 ? "" : ","
        lines << "#{INDENT}#{member.c_name} = #{emit_expression(member.value)}#{suffix}"
      end
      lines << "};"
      lines
    end

    def emit_function_declarations(functions)
      functions.map { |function| "#{function_signature(function)};" }
    end

    def function_signature(function)
      prefix = function.entry_point ? "" : "static "
      "#{prefix}#{c_function_declaration(function.return_type, function.c_name, function_params(function))}"
    end

    def function_params(function)
      if function.params.empty?
        "void"
      else
        function.params.map { |param| c_declaration(param.pointer ? pointer_to(param.type) : param.type, param.c_name) }.join(", ")
      end
    end

    def emit_function(function)
      lines = ["#{function_signature(function)} {"]
      used_labels = collect_used_labels(function.body)
      if function.body.empty?
        lines << "#{INDENT}(void)0;"
      else
        function.body.each do |statement|
          lines.concat(emit_statement(statement, 1, function:, used_labels:))
        end
      end
      lines << "}"
      lines
    end

    def emit_statement(statement, level, function:, used_labels:)
      indent = INDENT * level

      case statement
      when IR::LocalDecl
        if array_type?(statement.type) && !statement.value.is_a?(IR::ArrayLiteral) && !statement.value.is_a?(IR::ZeroInit)
          lines = ["#{indent}#{c_declaration(statement.type, statement.c_name)};"]
          lines << emit_array_copy_statement(statement.c_name, statement.value, indent)
          lines
        else
          ["#{indent}#{c_declaration(statement.type, statement.c_name)} = #{emit_initializer(statement.value)};"]
        end
      when IR::Assignment
        if array_type?(statement.target.type) && statement.operator == "="
          [emit_array_copy_statement(emit_expression(statement.target), statement.value, indent)]
        else
          ["#{indent}#{emit_expression(statement.target)} #{statement.operator} #{emit_expression(statement.value)};"]
        end
      when IR::BlockStmt
        if block_requires_scope?(statement.body)
          lines = ["#{indent}{"]
          statement.body.each do |inner|
            lines.concat(emit_statement(inner, level + 1, function:, used_labels:))
          end
          lines << "#{indent}}"
          lines
        else
          statement.body.flat_map { |inner| emit_statement(inner, level, function:, used_labels:) }
        end
      when IR::ExpressionStmt
        ["#{indent}#{emit_expression(statement.expression)};"]
      when IR::ReturnStmt
        if statement.value
          if array_type?(function.return_type)
            emit_array_return(statement.value, function.return_type, indent)
          else
            ["#{indent}return #{emit_expression(statement.value)};"]
          end
        else
          ["#{indent}return;"]
        end
      when IR::WhileStmt
        lines = ["#{indent}while (#{emit_expression(statement.condition)}) {"]
        statement.body.each do |inner|
          lines.concat(emit_statement(inner, level + 1, function:, used_labels:))
        end
        lines << "#{indent}}"
        lines
      when IR::GotoStmt
        ["#{indent}goto #{statement.label};"]
      when IR::LabelStmt
        return [] unless used_labels.include?(statement.name)

        ["#{indent}#{statement.name}:;"]
      when IR::StaticAssert
        ["#{indent}#{emit_static_assert(statement)}"]
      when IR::IfStmt
        case constant_boolean_value(statement.condition)
        when true
          return emit_statement(IR::BlockStmt.new(body: statement.then_body), level, function:, used_labels:)
        when false
          return [] unless statement.else_body && !statement.else_body.empty?

          return emit_statement(IR::BlockStmt.new(body: statement.else_body), level, function:, used_labels:)
        end

        lines = ["#{indent}if (#{emit_expression(statement.condition)}) {"]
        statement.then_body.each do |inner|
          lines.concat(emit_statement(inner, level + 1, function:, used_labels:))
        end
        if statement.else_body && !statement.else_body.empty?
          lines << "#{indent}} else {"
          statement.else_body.each do |inner|
            lines.concat(emit_statement(inner, level + 1, function:, used_labels:))
          end
        end
        lines << "#{indent}}"
        lines
      when IR::SwitchStmt
        lines = ["#{indent}switch (#{emit_expression(statement.expression)}) {"]
        statement.cases.each do |switch_case|
          lines << "#{indent}#{INDENT}case #{emit_expression(switch_case.value)}: {"
          switch_case.body.each do |inner|
            lines.concat(emit_statement(inner, level + 2, function:, used_labels:))
          end
          lines << "#{indent}#{INDENT}#{INDENT}break;" unless body_terminates?(switch_case.body)
          lines << "#{indent}#{INDENT}}"
        end
        lines << "#{indent}}"
        lines
      else
        raise LoweringError, "unsupported IR statement #{statement.class.name}"
      end
    end

    def body_terminates?(statements)
      return false if statements.empty?

      statement_terminates?(statements.last)
    end

    def constant_boolean_value(expression)
      case expression
      when IR::BooleanLiteral
        expression.value
      when IR::Unary
        operand = constant_boolean_value(expression.operand)
        return nil if operand.nil? || expression.operator != "not"

        !operand
      when IR::Binary
        left_int = constant_integer_value(expression.left)
        right_int = constant_integer_value(expression.right)
        if !left_int.nil? && !right_int.nil?
          return left_int == right_int if expression.operator == "=="
          return left_int != right_int if expression.operator == "!="
          return left_int < right_int if expression.operator == "<"
          return left_int <= right_int if expression.operator == "<="
          return left_int > right_int if expression.operator == ">"
          return left_int >= right_int if expression.operator == ">="
        end

        left_bool = constant_boolean_value(expression.left)
        right_bool = constant_boolean_value(expression.right)
        if !left_bool.nil? && !right_bool.nil?
          return left_bool == right_bool if expression.operator == "=="
          return left_bool != right_bool if expression.operator == "!="
          return left_bool && right_bool if expression.operator == "and"
          return left_bool || right_bool if expression.operator == "or"
        end

        nil
      else
        nil
      end
    end

    def constant_integer_value(expression)
      case expression
      when IR::IntegerLiteral
        expression.value
      when IR::Unary
        operand = constant_integer_value(expression.operand)
        return nil if operand.nil?

        return operand if expression.operator == "+"
        return -operand if expression.operator == "-"

        nil
      else
        nil
      end
    end

    def statement_terminates?(statement)
      case statement
      when IR::ReturnStmt
        true
      when IR::GotoStmt
        true
      when IR::BlockStmt
        body_terminates?(statement.body)
      when IR::IfStmt
        statement.else_body && body_terminates?(statement.then_body) && body_terminates?(statement.else_body)
      when IR::SwitchStmt
        statement.cases.any? && statement.cases.all? { |switch_case| body_terminates?(switch_case.body) }
      else
        false
      end
    end

    def collect_used_labels(statements)
      labels = []
      collect_used_labels_from_statements(statements, labels)
      labels.uniq
    end

    def collect_used_labels_from_statements(statements, labels)
      statements.each do |statement|
        case statement
        when IR::BlockStmt, IR::WhileStmt
          collect_used_labels_from_statements(statement.body, labels)
        when IR::IfStmt
          collect_used_labels_from_statements(statement.then_body, labels)
          collect_used_labels_from_statements(statement.else_body, labels) if statement.else_body
        when IR::SwitchStmt
          statement.cases.each do |switch_case|
            collect_used_labels_from_statements(switch_case.body, labels)
          end
        when IR::GotoStmt
          labels << statement.label
        end
      end
    end

    def block_requires_scope?(statements)
      statements.any? { |statement| statement.is_a?(IR::LocalDecl) }
    end

    def emit_static_assert(statement)
      message = if statement.message.is_a?(IR::StringLiteral)
                  statement.message.value.inspect
                else
                  emit_expression(statement.message)
                end

      "_Static_assert(#{emit_expression(statement.condition)}, #{message});"
    end

    def emit_expression(expression)
      case expression
      when IR::Name
        expression.name
      when IR::Member
        operator = pointer_member_receiver?(expression.receiver) ? "->" : "."
        "#{wrap_member_receiver(expression.receiver)}#{operator}#{expression.member}"
      when IR::Index
        "#{wrap_index_receiver(expression.receiver)}[#{emit_expression(expression.index)}]"
      when IR::CheckedIndex
        "(*#{checked_array_index_helper_name(expression.receiver_type)}(&(#{emit_expression(expression.receiver)}), #{emit_expression(expression.index)}))"
      when IR::CheckedSpanIndex
        "(*#{checked_span_index_helper_name(expression.receiver_type)}(#{emit_expression(expression.receiver)}, #{emit_expression(expression.index)}))"
      when IR::Call
        call = emit_call_expression(expression)
        array_type?(expression.type) ? "#{call}.value" : call
      when IR::Unary
        if expression.operator == "not"
          "!#{wrap_expression(expression.operand)}"
        else
          "#{expression.operator}#{wrap_expression(expression.operand)}"
        end
      when IR::Binary
        "#{wrap_expression(expression.left)} #{c_operator(expression.operator)} #{wrap_expression(expression.right)}"
      when IR::Conditional
        "#{wrap_expression(expression.condition)} ? #{wrap_expression(expression.then_expression)} : #{wrap_expression(expression.else_expression)}"
      when IR::ReinterpretExpr
        if no_op_reinterpret?(expression.target_type, expression.source_type)
          emit_expression(expression.expression)
        else
          "#{reinterpret_helper_name(expression.target_type, expression.source_type)}(#{emit_expression(expression.expression)})"
        end
      when IR::SizeofExpr
        "sizeof(#{layout_type_expression(expression.target_type)})"
      when IR::AlignofExpr
        "_Alignof(#{layout_type_expression(expression.target_type)})"
      when IR::OffsetofExpr
        "offsetof(#{layout_type_expression(expression.target_type)}, #{expression.field})"
      when IR::IntegerLiteral
        expression.value.to_s
      when IR::FloatLiteral
        emit_float_literal(expression)
      when IR::StringLiteral
        expression.type.is_a?(Types::StringView) ? emit_str_literal(expression) : expression.value.inspect
      when IR::BooleanLiteral
        expression.value ? "true" : "false"
      when IR::NullLiteral
        "NULL"
      when IR::ZeroInit
        emit_zero_expression(expression.type)
      when IR::AddressOf
        "&#{wrap_expression(expression.expression)}"
      when IR::Cast
        if no_op_cast?(expression)
          emit_expression(expression.expression)
        else
          "((#{c_type(expression.target_type)}) #{wrap_expression(expression.expression)})"
        end
      when IR::AggregateLiteral
        emit_aggregate_literal(expression)
      when IR::ArrayLiteral
        emit_array_compound_literal(expression)
      else
        raise LoweringError, "unsupported IR expression #{expression.class.name}"
      end
    end

    def emit_initializer(expression)
      case expression
      when IR::ArrayLiteral
        emit_array_initializer(expression)
      when IR::ZeroInit
        emit_zero_initializer(expression.type)
      else
        emit_expression(expression)
      end
    end

    def emit_aggregate_literal(expression)
      return emit_zero_expression(expression.type) if expression.fields.empty?

      fields = expression.fields.map do |field|
        ".#{field.name} = #{emit_initializer(field.value)}"
      end.join(", ")
      "(#{c_type(expression.type)}){ #{fields} }"
    end

    def emit_array_initializer(expression)
      return "{ 0 }" if expression.elements.empty?

      elements = expression.elements.map { |element| emit_initializer(element) }.join(", ")
      "{ #{elements} }"
    end

    def emit_array_compound_literal(expression)
      "(#{c_declaration(expression.type, '')}) #{emit_array_initializer(expression)}"
    end

    def emit_zero_initializer(type)
      return "{ 0 }" if type.is_a?(Types::StringView)
      return "{ 0 }" if array_type?(type)
      return "NULL" if type.is_a?(Types::Nullable)
      return "false" if type.is_a?(Types::Primitive) && type.boolean?
      return "0.0" if type.is_a?(Types::Primitive) && type.float?
      return "0" if type.is_a?(Types::Primitive) && !type.void?
      return "(#{c_type(type)}) 0" if type.is_a?(Types::EnumBase)

      "{ 0 }"
    end

    def emit_zero_expression(type)
      return "(#{c_type(type)}) #{emit_zero_initializer(type)}" if type.is_a?(Types::StringView)
      return emit_zero_initializer(type) if type.is_a?(Types::Primitive) || type.is_a?(Types::Nullable)
      return emit_zero_initializer(type) if type.is_a?(Types::EnumBase)

      "(#{c_declaration(type, '')}) #{emit_zero_initializer(type)}"
    end

    def emit_str_literal(expression)
      "(mt_str){ .data = #{expression.value.inspect}, .len = #{expression.value.bytesize} }"
    end

    def emit_call_expression(expression)
      callee = expression.callee.is_a?(String) ? expression.callee : wrap_expression(expression.callee)
      "#{callee}(#{expression.arguments.map { |argument| emit_expression(argument) }.join(', ')})"
    end

    def emit_array_copy_statement(destination, source, indent)
      "#{indent}memcpy(#{destination}, #{emit_expression(source)}, sizeof(#{destination}));"
    end

    def emit_array_return(expression, type, indent)
      wrapper_type = array_return_wrapper_type_name(type)

      if expression.is_a?(IR::ArrayLiteral)
        return ["#{indent}return (#{wrapper_type}){ .value = #{emit_array_initializer(expression)} };"]
      end

      if expression.is_a?(IR::Call) && array_type?(expression.type)
        return ["#{indent}return #{emit_call_expression(expression)};"]
      end

      temp_name = "__mt_return_value"
      [
        "#{indent}#{wrapper_type} #{temp_name};",
        "#{indent}memcpy(#{temp_name}.value, #{emit_expression(expression)}, sizeof(#{temp_name}.value));",
        "#{indent}return #{temp_name};",
      ]
    end

    def emit_float_literal(expression)
      value = expression.value
      literal = if value.finite? && value == value.to_i
                  format("%.1f", value)
                else
                  value.to_s
                end
      expression.type.name == "f32" ? "#{literal}f" : literal
    end

    def wrap_expression(expression)
      case expression
      when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::ZeroInit, IR::Member, IR::Index, IR::Call, IR::AggregateLiteral, IR::ArrayLiteral, IR::ReinterpretExpr, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        emit_expression(expression)
      else
        "(#{emit_expression(expression)})"
      end
    end

    def layout_type_expression(type)
      c_declaration(type, "")
    end

    def collect_reinterpret_helpers
      helpers = []
      seen = {}

      @program.functions.each do |function|
        collect_reinterpret_helpers_from_statements(function.body, helpers, seen)
      end

      helpers
    end

    def collect_reinterpret_helpers_from_statements(statements, helpers, seen)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_reinterpret_helpers_from_expression(statement.value, helpers, seen)
        when IR::Assignment
          collect_reinterpret_helpers_from_expression(statement.target, helpers, seen)
          collect_reinterpret_helpers_from_expression(statement.value, helpers, seen)
        when IR::BlockStmt
          collect_reinterpret_helpers_from_statements(statement.body, helpers, seen)
        when IR::WhileStmt
          collect_reinterpret_helpers_from_expression(statement.condition, helpers, seen)
          collect_reinterpret_helpers_from_statements(statement.body, helpers, seen)
        when IR::IfStmt
          collect_reinterpret_helpers_from_expression(statement.condition, helpers, seen)
          collect_reinterpret_helpers_from_statements(statement.then_body, helpers, seen)
          collect_reinterpret_helpers_from_statements(statement.else_body, helpers, seen) if statement.else_body
        when IR::SwitchStmt
          collect_reinterpret_helpers_from_expression(statement.expression, helpers, seen)
          statement.cases.each do |switch_case|
            collect_reinterpret_helpers_from_statements(switch_case.body, helpers, seen)
          end
        when IR::StaticAssert
          collect_reinterpret_helpers_from_expression(statement.condition, helpers, seen)
          collect_reinterpret_helpers_from_expression(statement.message, helpers, seen)
        when IR::ReturnStmt
          collect_reinterpret_helpers_from_expression(statement.value, helpers, seen) if statement.value
        when IR::ExpressionStmt
          collect_reinterpret_helpers_from_expression(statement.expression, helpers, seen)
        end
      end
    end

    def collect_reinterpret_helpers_from_expression(expression, helpers, seen)
      case expression
      when IR::Member
        collect_reinterpret_helpers_from_expression(expression.receiver, helpers, seen)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_reinterpret_helpers_from_expression(expression.receiver, helpers, seen)
        collect_reinterpret_helpers_from_expression(expression.index, helpers, seen)
      when IR::Call
        collect_reinterpret_helpers_from_expression(expression.callee, helpers, seen) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_reinterpret_helpers_from_expression(argument, helpers, seen) }
      when IR::Unary
        collect_reinterpret_helpers_from_expression(expression.operand, helpers, seen)
      when IR::Binary
        collect_reinterpret_helpers_from_expression(expression.left, helpers, seen)
        collect_reinterpret_helpers_from_expression(expression.right, helpers, seen)
      when IR::Conditional
        collect_reinterpret_helpers_from_expression(expression.condition, helpers, seen)
        collect_reinterpret_helpers_from_expression(expression.then_expression, helpers, seen)
        collect_reinterpret_helpers_from_expression(expression.else_expression, helpers, seen)
      when IR::ReinterpretExpr
        return if no_op_reinterpret?(expression.target_type, expression.source_type)

        key = [expression.target_type, expression.source_type]
        unless seen[key]
          helpers << expression
          seen[key] = true
        end
        collect_reinterpret_helpers_from_expression(expression.expression, helpers, seen)
      when IR::AddressOf
        collect_reinterpret_helpers_from_expression(expression.expression, helpers, seen)
      when IR::Cast
        collect_reinterpret_helpers_from_expression(expression.expression, helpers, seen)
      when IR::AggregateLiteral
        expression.fields.each { |field| collect_reinterpret_helpers_from_expression(field.value, helpers, seen) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_reinterpret_helpers_from_expression(element, helpers, seen) }
      when IR::ZeroInit, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::Name, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        nil
      end
    end

    def emit_reinterpret_helper(expression)
      helper_name = reinterpret_helper_name(expression.target_type, expression.source_type)
      params = c_declaration(expression.source_type, 'value')
      [
        "static inline #{c_function_declaration(expression.target_type, helper_name, params)} {",
        "#{INDENT}_Static_assert(sizeof(#{layout_type_expression(expression.target_type)}) == sizeof(#{layout_type_expression(expression.source_type)}), \"reinterpret requires equal sizes\");",
        "#{INDENT}#{c_declaration(expression.target_type, 'result')};",
        "#{INDENT}memcpy(&result, &value, sizeof(result));",
        "#{INDENT}return result;",
        "}",
      ]
    end

    def reinterpret_helper_name(target_type, source_type)
      "mt_reinterpret_#{sanitize_identifier(target_type.to_s)}_from_#{sanitize_identifier(source_type.to_s)}"
    end

    def no_op_cast?(expression)
      return false if expression.expression.type.is_a?(Types::Null)

      c_type(expression.target_type) == c_type(expression.expression.type)
    rescue StandardError
      false
    end

    def no_op_reinterpret?(target_type, source_type)
      c_type(target_type) == c_type(source_type)
    end

    def checked_array_index_helper_name(type)
      "mt_checked_index_#{sanitize_identifier(type.to_s)}"
    end

    def checked_span_index_helper_name(type)
      "mt_checked_span_index_#{sanitize_identifier(type.to_s)}"
    end

    def wrap_member_receiver(expression)
      case expression
      when IR::Name, IR::Member, IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        emit_expression(expression)
      else
        "(#{emit_expression(expression)})"
      end
    end

    def pointer_member_receiver?(expression)
      (expression.is_a?(IR::Name) && expression.pointer) ||
        (expression.respond_to?(:type) && (raw_pointer_type?(expression.type) || ref_type?(expression.type)))
    end

    def wrap_index_receiver(expression)
      case expression
      when IR::Name, IR::Member, IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::Call
        emit_expression(expression)
      else
        "(#{emit_expression(expression)})"
      end
    end

    def c_operator(operator)
      operator == "and" ? "&&" : operator == "or" ? "||" : operator
    end

    def c_declaration(type, name)
      base, declarator = c_declaration_parts(type, name)
      declarator.empty? ? base : "#{base} #{declarator}"
    end

    def c_function_declaration(return_type, name, params)
      return "#{array_return_wrapper_type_name(return_type)} #{name}(#{params})" if array_type?(return_type)

      c_declaration(return_type, "#{name}(#{params})")
    end

    def c_function_return_type(type)
      array_type?(type) ? array_return_wrapper_type_name(type) : c_type(type)
    end

    def c_declaration_parts(type, name)
      name = name.to_s

      if array_type?(type)
        declarator = declarator_needs_grouping?(name) ? "(#{name})" : name
        return c_declaration_parts(array_element_type(type), "#{declarator}[#{array_length(type)}]")
      end

      if type.is_a?(Types::Function)
        params = type.params.each_with_index.map do |param, index|
          c_declaration(param.type, param.name || "arg#{index}")
        end
        params << "..." if type.variadic
        params = ["void"] if params.empty?
        return [c_function_return_type(type.return_type), "(*#{name})(#{params.join(', ')})"]
      end

      if mutable_pointer_type?(type)
        return c_declaration_parts(type.arguments.first, "*#{name}")
      end

      if const_pointer_type?(type)
        return [generic_c_type(type), name]
      end

      if ref_type?(type)
        return c_declaration_parts(type.arguments.first, "*#{name}")
      end

      [c_type(type), name]
    end

    def declarator_needs_grouping?(name)
      !name.empty? && (name.start_with?("*") || name.include?("["))
    end

    def c_type(type, pointer: false)
      case type
      when Types::Nullable
        base = c_type(type.base)
        base.end_with?("*") ? base : "#{base}*"
      when Types::StringView
        base = "mt_str"
        pointer ? "#{base}*" : base
      when Types::Primitive
        base = primitive_c_type(type.name)
        pointer ? "#{base}*" : base
      when Types::Span
        base = span_type_name(type)
        pointer ? "#{base}*" : base
      when Types::Result
        base = result_type_name(type)
        pointer ? "#{base}*" : base
      when Types::GenericInstance
        base = generic_c_type(type)
        pointer ? "#{base}*" : base
      when Types::Struct, Types::Union, Types::Enum, Types::Flags
        base = named_type_c_name(type)
        pointer ? "#{base}*" : base
      when Types::Opaque
        if type.external
          base = external_opaque_c_type(type)
          pointer ? "#{base}*" : base
        else
          base = named_type_c_name(type)
          pointer ? "#{base}**" : "#{base}*"
        end
      else
        raise LoweringError, "unsupported C type #{type.class.name}"
      end
    end

    def constant_storage(type)
      return "static const" if array_type?(type)

      c_type(type).start_with?("const ") ? "static" : "static const"
    end

    def collect_array_return_types
      @program.functions.map(&:return_type).select { |type| array_type?(type) }.uniq
    end

    def collect_checked_array_index_types
      array_types = []
      @program.functions.each do |function|
        collect_checked_array_index_types_from_statements(function.body, array_types)
      end
      array_types.uniq
    end

    def collect_checked_span_index_types
      span_types = []
      @program.functions.each do |function|
        collect_checked_span_index_types_from_statements(function.body, span_types)
      end
      span_types.uniq
    end

    def collect_checked_array_index_types_from_statements(statements, array_types)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_checked_array_index_types_from_expression(statement.value, array_types)
        when IR::Assignment
          collect_checked_array_index_types_from_expression(statement.target, array_types)
          collect_checked_array_index_types_from_expression(statement.value, array_types)
        when IR::BlockStmt, IR::WhileStmt
          collect_checked_array_index_types_from_statements(statement.body, array_types)
        when IR::IfStmt
          collect_checked_array_index_types_from_expression(statement.condition, array_types)
          collect_checked_array_index_types_from_statements(statement.then_body, array_types)
          collect_checked_array_index_types_from_statements(statement.else_body, array_types) if statement.else_body
        when IR::SwitchStmt
          collect_checked_array_index_types_from_expression(statement.expression, array_types)
          statement.cases.each do |switch_case|
            collect_checked_array_index_types_from_statements(switch_case.body, array_types)
          end
        when IR::StaticAssert
          collect_checked_array_index_types_from_expression(statement.condition, array_types)
          collect_checked_array_index_types_from_expression(statement.message, array_types)
        when IR::ReturnStmt
          collect_checked_array_index_types_from_expression(statement.value, array_types) if statement.value
        when IR::ExpressionStmt
          collect_checked_array_index_types_from_expression(statement.expression, array_types)
        end
      end
    end

    def collect_checked_array_index_types_from_expression(expression, array_types)
      case expression
      when IR::Member
        collect_checked_array_index_types_from_expression(expression.receiver, array_types)
      when IR::Index
        collect_checked_array_index_types_from_expression(expression.receiver, array_types)
        collect_checked_array_index_types_from_expression(expression.index, array_types)
      when IR::CheckedIndex
        array_types << expression.receiver_type
        collect_checked_array_index_types_from_expression(expression.receiver, array_types)
        collect_checked_array_index_types_from_expression(expression.index, array_types)
      when IR::Call
        collect_checked_array_index_types_from_expression(expression.callee, array_types) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_checked_array_index_types_from_expression(argument, array_types) }
      when IR::Unary
        collect_checked_array_index_types_from_expression(expression.operand, array_types)
      when IR::Binary
        collect_checked_array_index_types_from_expression(expression.left, array_types)
        collect_checked_array_index_types_from_expression(expression.right, array_types)
      when IR::Conditional
        collect_checked_array_index_types_from_expression(expression.condition, array_types)
        collect_checked_array_index_types_from_expression(expression.then_expression, array_types)
        collect_checked_array_index_types_from_expression(expression.else_expression, array_types)
      when IR::ReinterpretExpr
        collect_checked_array_index_types_from_expression(expression.expression, array_types)
      when IR::AddressOf
        collect_checked_array_index_types_from_expression(expression.expression, array_types)
      when IR::Cast
        collect_checked_array_index_types_from_expression(expression.expression, array_types)
      when IR::AggregateLiteral
        expression.fields.each { |field| collect_checked_array_index_types_from_expression(field.value, array_types) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_checked_array_index_types_from_expression(element, array_types) }
      end
    end

    def collect_checked_span_index_types_from_statements(statements, span_types)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_checked_span_index_types_from_expression(statement.value, span_types)
        when IR::Assignment
          collect_checked_span_index_types_from_expression(statement.target, span_types)
          collect_checked_span_index_types_from_expression(statement.value, span_types)
        when IR::BlockStmt, IR::WhileStmt
          collect_checked_span_index_types_from_statements(statement.body, span_types)
        when IR::IfStmt
          collect_checked_span_index_types_from_expression(statement.condition, span_types)
          collect_checked_span_index_types_from_statements(statement.then_body, span_types)
          collect_checked_span_index_types_from_statements(statement.else_body, span_types) if statement.else_body
        when IR::SwitchStmt
          collect_checked_span_index_types_from_expression(statement.expression, span_types)
          statement.cases.each do |switch_case|
            collect_checked_span_index_types_from_statements(switch_case.body, span_types)
          end
        when IR::StaticAssert
          collect_checked_span_index_types_from_expression(statement.condition, span_types)
          collect_checked_span_index_types_from_expression(statement.message, span_types)
        when IR::ReturnStmt
          collect_checked_span_index_types_from_expression(statement.value, span_types) if statement.value
        when IR::ExpressionStmt
          collect_checked_span_index_types_from_expression(statement.expression, span_types)
        end
      end
    end

    def collect_checked_span_index_types_from_expression(expression, span_types)
      case expression
      when IR::Member
        collect_checked_span_index_types_from_expression(expression.receiver, span_types)
      when IR::Index, IR::CheckedIndex
        collect_checked_span_index_types_from_expression(expression.receiver, span_types)
        collect_checked_span_index_types_from_expression(expression.index, span_types)
      when IR::CheckedSpanIndex
        span_types << expression.receiver_type
        collect_checked_span_index_types_from_expression(expression.receiver, span_types)
        collect_checked_span_index_types_from_expression(expression.index, span_types)
      when IR::Call
        collect_checked_span_index_types_from_expression(expression.callee, span_types) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_checked_span_index_types_from_expression(argument, span_types) }
      when IR::Unary
        collect_checked_span_index_types_from_expression(expression.operand, span_types)
      when IR::Binary
        collect_checked_span_index_types_from_expression(expression.left, span_types)
        collect_checked_span_index_types_from_expression(expression.right, span_types)
      when IR::Conditional
        collect_checked_span_index_types_from_expression(expression.condition, span_types)
        collect_checked_span_index_types_from_expression(expression.then_expression, span_types)
        collect_checked_span_index_types_from_expression(expression.else_expression, span_types)
      when IR::ReinterpretExpr
        collect_checked_span_index_types_from_expression(expression.expression, span_types)
      when IR::AddressOf
        collect_checked_span_index_types_from_expression(expression.expression, span_types)
      when IR::Cast
        collect_checked_span_index_types_from_expression(expression.expression, span_types)
      when IR::AggregateLiteral
        expression.fields.each { |field| collect_checked_span_index_types_from_expression(field.value, span_types) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_checked_span_index_types_from_expression(element, span_types) }
      end
    end

    def collect_span_types
      span_types = []
      visited = {}

      emitted_constants.each do |constant|
        collect_span_type(constant.type, span_types, visited)
      end

      @program.structs.each do |struct_decl|
        struct_decl.fields.each do |field|
          collect_span_type(field.type, span_types, visited)
        end
      end

      @program.unions.each do |union_decl|
        union_decl.fields.each do |field|
          collect_span_type(field.type, span_types, visited)
        end
      end

      @program.functions.each do |function|
        collect_span_type(function.return_type, span_types, visited)
        function.params.each do |param|
          collect_span_type(param.type, span_types, visited)
        end
        collect_span_types_from_statements(function.body, span_types, visited)
      end

      @program.static_asserts.each do |statement|
        collect_span_types_from_expression(statement.condition, span_types, visited)
        collect_span_types_from_expression(statement.message, span_types, visited)
      end

      span_types.uniq
    end

    def collect_generic_struct_decls
      collect_generic_struct_types.map do |type|
        IR::StructDecl.new(
          name: type.to_s,
          c_name: named_type_c_name(type),
          fields: type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
          packed: type.packed,
          alignment: type.alignment,
        )
      end
    end

    def collect_result_decls
      collect_result_types.map do |type|
        IR::StructDecl.new(
          name: type.to_s,
          c_name: result_type_name(type),
          fields: type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
          packed: false,
          alignment: nil,
        )
      end
    end

    def collect_str_builder_decls
      collect_str_builder_types.map do |type|
        IR::StructDecl.new(
          name: type.to_s,
          c_name: str_builder_type_name(type),
          fields: [
            IR::Field.new(name: "data", type: Types::GenericInstance.new("array", [Types::Primitive.new("char"), Types::LiteralTypeArg.new(str_builder_storage_capacity(type))])),
            IR::Field.new(name: "len", type: Types::Primitive.new("usize")),
            IR::Field.new(name: "dirty", type: Types::Primitive.new("bool")),
          ],
          packed: false,
          alignment: nil,
        )
      end
    end

    def collect_result_types
      result_types = []
      visited = {}

      emitted_constants.each do |constant|
        collect_result_type(constant.type, result_types, visited)
      end

      @program.structs.each do |struct_decl|
        struct_decl.fields.each do |field|
          collect_result_type(field.type, result_types, visited)
        end
      end

      @program.unions.each do |union_decl|
        union_decl.fields.each do |field|
          collect_result_type(field.type, result_types, visited)
        end
      end

      @program.functions.each do |function|
        collect_result_type(function.return_type, result_types, visited)
        function.params.each do |param|
          collect_result_type(param.type, result_types, visited)
        end
        collect_result_types_from_statements(function.body, result_types, visited)
      end

      @program.static_asserts.each do |statement|
        collect_result_types_from_expression(statement.condition, result_types, visited)
        collect_result_types_from_expression(statement.message, result_types, visited)
      end

      result_types
    end

    def collect_result_types_from_statements(statements, result_types, visited)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_result_type(statement.type, result_types, visited)
        when IR::BlockStmt
          collect_result_types_from_statements(statement.body, result_types, visited)
        when IR::WhileStmt
          collect_result_types_from_statements(statement.body, result_types, visited)
        when IR::IfStmt
          collect_result_types_from_statements(statement.then_body, result_types, visited)
          collect_result_types_from_statements(statement.else_body, result_types, visited) if statement.else_body
        when IR::SwitchStmt
          statement.cases.each do |switch_case|
            collect_result_types_from_statements(switch_case.body, result_types, visited)
          end
        when IR::StaticAssert
          collect_result_types_from_expression(statement.condition, result_types, visited)
          collect_result_types_from_expression(statement.message, result_types, visited)
        end
      end
    end

    def collect_result_types_from_expression(expression, result_types, visited)
      case expression
      when IR::Member
        collect_result_types_from_expression(expression.receiver, result_types, visited)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_result_types_from_expression(expression.receiver, result_types, visited)
        collect_result_types_from_expression(expression.index, result_types, visited)
      when IR::Call
        collect_result_types_from_expression(expression.callee, result_types, visited) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_result_types_from_expression(argument, result_types, visited) }
      when IR::Unary
        collect_result_types_from_expression(expression.operand, result_types, visited)
      when IR::Binary
        collect_result_types_from_expression(expression.left, result_types, visited)
        collect_result_types_from_expression(expression.right, result_types, visited)
      when IR::Conditional
        collect_result_types_from_expression(expression.condition, result_types, visited)
        collect_result_types_from_expression(expression.then_expression, result_types, visited)
        collect_result_types_from_expression(expression.else_expression, result_types, visited)
      when IR::ReinterpretExpr
        collect_result_type(expression.target_type, result_types, visited)
        collect_result_type(expression.source_type, result_types, visited)
        collect_result_types_from_expression(expression.expression, result_types, visited)
      when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        collect_result_type(expression.target_type, result_types, visited)
      when IR::AddressOf
        collect_result_types_from_expression(expression.expression, result_types, visited)
      when IR::Cast
        collect_result_types_from_expression(expression.expression, result_types, visited)
      when IR::AggregateLiteral
        expression.fields.each { |field| collect_result_types_from_expression(field.value, result_types, visited) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_result_types_from_expression(element, result_types, visited) }
      end
    end

    def collect_result_type(type, result_types, visited)
      return unless type
      return if visited[type]

      visited[type] = true

      case type
      when Types::Nullable
        collect_result_type(type.base, result_types, visited)
      when Types::Result
        result_types << type
        collect_result_type(type.ok_type, result_types, visited)
        collect_result_type(type.error_type, result_types, visited)
      when Types::Span
        collect_result_type(type.element_type, result_types, visited)
      when Types::StructInstance
        type.arguments.each do |argument|
          collect_result_type(argument, result_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
        type.fields.each_value do |field_type|
          collect_result_type(field_type, result_types, visited)
        end
      when Types::GenericInstance
        type.arguments.each do |argument|
          collect_result_type(argument, result_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
      when Types::Function
        type.params.each do |param|
          collect_result_type(param.type, result_types, visited)
        end
        collect_result_type(type.return_type, result_types, visited)
      when Types::Struct, Types::Union
        type.fields.each_value do |field_type|
          collect_result_type(field_type, result_types, visited)
        end
      end
    end

    def collect_generic_struct_types
      generic_struct_types = []
      visited = {}

      emitted_constants.each do |constant|
        collect_generic_struct_type(constant.type, generic_struct_types, visited)
      end

      @program.structs.each do |struct_decl|
        struct_decl.fields.each do |field|
          collect_generic_struct_type(field.type, generic_struct_types, visited)
        end
      end

      @program.unions.each do |union_decl|
        union_decl.fields.each do |field|
          collect_generic_struct_type(field.type, generic_struct_types, visited)
        end
      end

      @program.functions.each do |function|
        collect_generic_struct_type(function.return_type, generic_struct_types, visited)
        function.params.each do |param|
          collect_generic_struct_type(param.type, generic_struct_types, visited)
        end
        collect_generic_struct_types_from_statements(function.body, generic_struct_types, visited)
      end

      @program.static_asserts.each do |statement|
        collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
        collect_generic_struct_types_from_expression(statement.message, generic_struct_types, visited)
      end

      generic_struct_types
    end

    def collect_str_builder_types
      str_builder_types = []
      visited = {}

      emitted_constants.each do |constant|
        collect_str_builder_type(constant.type, str_builder_types, visited)
      end

      @program.structs.each do |struct_decl|
        struct_decl.fields.each do |field|
          collect_str_builder_type(field.type, str_builder_types, visited)
        end
      end

      @program.unions.each do |union_decl|
        union_decl.fields.each do |field|
          collect_str_builder_type(field.type, str_builder_types, visited)
        end
      end

      @program.functions.each do |function|
        collect_str_builder_type(function.return_type, str_builder_types, visited)
        function.params.each do |param|
          collect_str_builder_type(param.type, str_builder_types, visited)
        end
        collect_str_builder_types_from_statements(function.body, str_builder_types, visited)
      end

      @program.static_asserts.each do |statement|
        collect_str_builder_types_from_expression(statement.condition, str_builder_types, visited)
        collect_str_builder_types_from_expression(statement.message, str_builder_types, visited)
      end

      str_builder_types
    end

    def collect_str_builder_types_from_statements(statements, str_builder_types, visited)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_str_builder_type(statement.type, str_builder_types, visited)
          collect_str_builder_types_from_expression(statement.value, str_builder_types, visited)
        when IR::Assignment
          collect_str_builder_types_from_expression(statement.target, str_builder_types, visited)
          collect_str_builder_types_from_expression(statement.value, str_builder_types, visited)
        when IR::BlockStmt, IR::WhileStmt
          collect_str_builder_types_from_statements(statement.body, str_builder_types, visited)
        when IR::IfStmt
          collect_str_builder_types_from_expression(statement.condition, str_builder_types, visited)
          collect_str_builder_types_from_statements(statement.then_body, str_builder_types, visited)
          collect_str_builder_types_from_statements(statement.else_body, str_builder_types, visited) if statement.else_body
        when IR::SwitchStmt
          collect_str_builder_types_from_expression(statement.expression, str_builder_types, visited)
          statement.cases.each do |switch_case|
            collect_str_builder_types_from_statements(switch_case.body, str_builder_types, visited)
          end
        when IR::StaticAssert
          collect_str_builder_types_from_expression(statement.condition, str_builder_types, visited)
          collect_str_builder_types_from_expression(statement.message, str_builder_types, visited)
        when IR::ReturnStmt
          collect_str_builder_types_from_expression(statement.value, str_builder_types, visited) if statement.value
        when IR::ExpressionStmt
          collect_str_builder_types_from_expression(statement.expression, str_builder_types, visited)
        end
      end
    end

    def collect_str_builder_types_from_expression(expression, str_builder_types, visited)
      case expression
      when IR::Member
        collect_str_builder_types_from_expression(expression.receiver, str_builder_types, visited)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_str_builder_types_from_expression(expression.receiver, str_builder_types, visited)
        collect_str_builder_types_from_expression(expression.index, str_builder_types, visited)
      when IR::Call
        collect_str_builder_type(expression.type, str_builder_types, visited)
        collect_str_builder_types_from_expression(expression.callee, str_builder_types, visited) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_str_builder_types_from_expression(argument, str_builder_types, visited) }
      when IR::Unary
        collect_str_builder_types_from_expression(expression.operand, str_builder_types, visited)
      when IR::Binary
        collect_str_builder_types_from_expression(expression.left, str_builder_types, visited)
        collect_str_builder_types_from_expression(expression.right, str_builder_types, visited)
      when IR::Conditional
        collect_str_builder_types_from_expression(expression.condition, str_builder_types, visited)
        collect_str_builder_types_from_expression(expression.then_expression, str_builder_types, visited)
        collect_str_builder_types_from_expression(expression.else_expression, str_builder_types, visited)
      when IR::ReinterpretExpr
        collect_str_builder_type(expression.target_type, str_builder_types, visited)
        collect_str_builder_type(expression.source_type, str_builder_types, visited)
        collect_str_builder_types_from_expression(expression.expression, str_builder_types, visited)
      when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        collect_str_builder_type(expression.target_type, str_builder_types, visited)
      when IR::AddressOf, IR::Cast
        collect_str_builder_types_from_expression(expression.expression, str_builder_types, visited)
      when IR::AggregateLiteral
        collect_str_builder_type(expression.type, str_builder_types, visited)
        expression.fields.each { |field| collect_str_builder_types_from_expression(field.value, str_builder_types, visited) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_str_builder_types_from_expression(element, str_builder_types, visited) }
      end
    end

    def collect_str_builder_type(type, str_builder_types, visited)
      return unless type
      return if visited[type]

      visited[type] = true

      case type
      when Types::Nullable
        collect_str_builder_type(type.base, str_builder_types, visited)
      when Types::Span
        collect_str_builder_type(type.element_type, str_builder_types, visited)
      when Types::StructInstance
        type.arguments.each do |argument|
          collect_str_builder_type(argument, str_builder_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
        type.fields.each_value do |field_type|
          collect_str_builder_type(field_type, str_builder_types, visited)
        end
      when Types::GenericInstance
        str_builder_types << type if str_builder_type?(type)
        type.arguments.each do |argument|
          collect_str_builder_type(argument, str_builder_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
      when Types::Function
        type.params.each do |param|
          collect_str_builder_type(param.type, str_builder_types, visited)
        end
        collect_str_builder_type(type.return_type, str_builder_types, visited)
      when Types::Struct, Types::Union
        type.fields.each_value do |field_type|
          collect_str_builder_type(field_type, str_builder_types, visited)
        end
      end
    end

    def collect_generic_struct_types_from_statements(statements, generic_struct_types, visited)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_generic_struct_type(statement.type, generic_struct_types, visited)
        when IR::BlockStmt
          collect_generic_struct_types_from_statements(statement.body, generic_struct_types, visited)
        when IR::WhileStmt
          collect_generic_struct_types_from_statements(statement.body, generic_struct_types, visited)
        when IR::IfStmt
          collect_generic_struct_types_from_statements(statement.then_body, generic_struct_types, visited)
          collect_generic_struct_types_from_statements(statement.else_body, generic_struct_types, visited) if statement.else_body
        when IR::SwitchStmt
          statement.cases.each do |switch_case|
            collect_generic_struct_types_from_statements(switch_case.body, generic_struct_types, visited)
          end
        when IR::StaticAssert
          collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
          collect_generic_struct_types_from_expression(statement.message, generic_struct_types, visited)
        end
      end
    end

    def collect_generic_struct_types_from_expression(expression, generic_struct_types, visited)
      case expression
      when IR::Member
        collect_generic_struct_types_from_expression(expression.receiver, generic_struct_types, visited)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_generic_struct_types_from_expression(expression.receiver, generic_struct_types, visited)
        collect_generic_struct_types_from_expression(expression.index, generic_struct_types, visited)
      when IR::Call
        collect_generic_struct_types_from_expression(expression.callee, generic_struct_types, visited) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_generic_struct_types_from_expression(argument, generic_struct_types, visited) }
      when IR::Unary
        collect_generic_struct_types_from_expression(expression.operand, generic_struct_types, visited)
      when IR::Binary
        collect_generic_struct_types_from_expression(expression.left, generic_struct_types, visited)
        collect_generic_struct_types_from_expression(expression.right, generic_struct_types, visited)
      when IR::Conditional
        collect_generic_struct_types_from_expression(expression.condition, generic_struct_types, visited)
        collect_generic_struct_types_from_expression(expression.then_expression, generic_struct_types, visited)
        collect_generic_struct_types_from_expression(expression.else_expression, generic_struct_types, visited)
      when IR::ReinterpretExpr
        collect_generic_struct_type(expression.target_type, generic_struct_types, visited)
        collect_generic_struct_type(expression.source_type, generic_struct_types, visited)
        collect_generic_struct_types_from_expression(expression.expression, generic_struct_types, visited)
      when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        collect_generic_struct_type(expression.target_type, generic_struct_types, visited)
      when IR::AddressOf
        collect_generic_struct_types_from_expression(expression.expression, generic_struct_types, visited)
      when IR::Cast
        collect_generic_struct_types_from_expression(expression.expression, generic_struct_types, visited)
      when IR::AggregateLiteral
        expression.fields.each { |field| collect_generic_struct_types_from_expression(field.value, generic_struct_types, visited) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_generic_struct_types_from_expression(element, generic_struct_types, visited) }
      end
    end

    def collect_generic_struct_type(type, generic_struct_types, visited)
      return unless type
      return if visited[type]

      visited[type] = true

      case type
      when Types::Nullable
        collect_generic_struct_type(type.base, generic_struct_types, visited)
      when Types::Result
        collect_generic_struct_type(type.ok_type, generic_struct_types, visited)
        collect_generic_struct_type(type.error_type, generic_struct_types, visited)
      when Types::Span
        collect_generic_struct_type(type.element_type, generic_struct_types, visited)
      when Types::StructInstance
        generic_struct_types << type
        type.arguments.each do |argument|
          collect_generic_struct_type(argument, generic_struct_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
        type.fields.each_value do |field_type|
          collect_generic_struct_type(field_type, generic_struct_types, visited)
        end
      when Types::GenericInstance
        type.arguments.each do |argument|
          collect_generic_struct_type(argument, generic_struct_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
      when Types::Function
        type.params.each do |param|
          collect_generic_struct_type(param.type, generic_struct_types, visited)
        end
        collect_generic_struct_type(type.return_type, generic_struct_types, visited)
      when Types::Struct, Types::Union
        type.fields.each_value do |field_type|
          collect_generic_struct_type(field_type, generic_struct_types, visited)
        end
      end
    end

    def sort_struct_decls(struct_decls)
      by_c_name = struct_decls.each_with_object({}) do |struct_decl, declarations|
        declarations[struct_decl.c_name] = struct_decl
      end
      visiting = {}
      visited = {}
      sorted = []

      visit = lambda do |struct_decl|
        return if visited[struct_decl.c_name]
        raise LoweringError, "cyclic struct dependency involving #{struct_decl.c_name}" if visiting[struct_decl.c_name]

        visiting[struct_decl.c_name] = true
        struct_decl.fields.each do |field|
          struct_type_dependencies(field.type).each do |dependency|
            next unless by_c_name.key?(dependency)

            visit.call(by_c_name.fetch(dependency))
          end
        end
        visiting.delete(struct_decl.c_name)
        visited[struct_decl.c_name] = true
        sorted << struct_decl
      end

      struct_decls.each do |struct_decl|
        visit.call(struct_decl)
      end

      sorted
    end

    def struct_type_dependencies(type)
      case type
      when Types::Nullable
        struct_type_dependencies(type.base)
      when Types::Result
        [result_type_name(type)]
      when Types::GenericInstance
        if pointer_type?(type)
          []
        elsif array_type?(type)
          struct_type_dependencies(array_element_type(type))
        else
          []
        end
      when Types::Struct, Types::Union
        [named_type_c_name(type)]
      else
        []
      end
    end

    def collect_span_types_from_statements(statements, span_types, visited)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_span_type(statement.type, span_types, visited)
          collect_span_types_from_expression(statement.value, span_types, visited)
        when IR::Assignment
          collect_span_types_from_expression(statement.target, span_types, visited)
          collect_span_types_from_expression(statement.value, span_types, visited)
        when IR::BlockStmt
          collect_span_types_from_statements(statement.body, span_types, visited)
        when IR::WhileStmt
          collect_span_types_from_expression(statement.condition, span_types, visited)
          collect_span_types_from_statements(statement.body, span_types, visited)
        when IR::IfStmt
          collect_span_types_from_expression(statement.condition, span_types, visited)
          collect_span_types_from_statements(statement.then_body, span_types, visited)
          collect_span_types_from_statements(statement.else_body, span_types, visited) if statement.else_body
        when IR::SwitchStmt
          collect_span_types_from_expression(statement.expression, span_types, visited)
          statement.cases.each do |switch_case|
            collect_span_types_from_statements(switch_case.body, span_types, visited)
          end
        when IR::StaticAssert
          collect_span_types_from_expression(statement.condition, span_types, visited)
          collect_span_types_from_expression(statement.message, span_types, visited)
        when IR::ReturnStmt
          collect_span_types_from_expression(statement.value, span_types, visited) if statement.value
        when IR::ExpressionStmt
          collect_span_types_from_expression(statement.expression, span_types, visited)
        end
      end
    end

    def collect_span_types_from_expression(expression, span_types, visited)
      case expression
      when IR::Member
        collect_span_types_from_expression(expression.receiver, span_types, visited)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_span_types_from_expression(expression.receiver, span_types, visited)
        collect_span_types_from_expression(expression.index, span_types, visited)
      when IR::Call
        collect_span_type(expression.type, span_types, visited)
        collect_span_types_from_expression(expression.callee, span_types, visited) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_span_types_from_expression(argument, span_types, visited) }
      when IR::Unary
        collect_span_types_from_expression(expression.operand, span_types, visited)
      when IR::Binary
        collect_span_types_from_expression(expression.left, span_types, visited)
        collect_span_types_from_expression(expression.right, span_types, visited)
      when IR::Conditional
        collect_span_types_from_expression(expression.condition, span_types, visited)
        collect_span_types_from_expression(expression.then_expression, span_types, visited)
        collect_span_types_from_expression(expression.else_expression, span_types, visited)
      when IR::ReinterpretExpr
        collect_span_type(expression.target_type, span_types, visited)
        collect_span_type(expression.source_type, span_types, visited)
        collect_span_types_from_expression(expression.expression, span_types, visited)
      when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        collect_span_type(expression.target_type, span_types, visited)
      when IR::AddressOf
        collect_span_types_from_expression(expression.expression, span_types, visited)
      when IR::Cast
        collect_span_types_from_expression(expression.expression, span_types, visited)
      when IR::AggregateLiteral
        collect_span_type(expression.type, span_types, visited)
        expression.fields.each { |field| collect_span_types_from_expression(field.value, span_types, visited) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_span_types_from_expression(element, span_types, visited) }
      end
    end

    def collect_span_type(type, span_types, visited)
      return unless type
      return if visited[type.object_id]

      visited[type.object_id] = true

      case type
      when Types::Nullable
        collect_span_type(type.base, span_types, visited)
      when Types::Result
        collect_span_type(type.ok_type, span_types, visited)
        collect_span_type(type.error_type, span_types, visited)
      when Types::Span
        span_types << type
        collect_span_type(type.element_type, span_types, visited)
      when Types::GenericInstance
        type.arguments.each do |argument|
          collect_span_type(argument, span_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
      when Types::Function
        type.params.each do |param|
          collect_span_type(param.type, span_types, visited)
        end
        collect_span_type(type.return_type, span_types, visited)
      when Types::Struct, Types::Union
        type.fields.each_value do |field_type|
          collect_span_type(field_type, span_types, visited)
        end
      end
    end

    def emit_array_return_wrapper(type)
      wrapper_type = array_return_wrapper_type_name(type)
      [
        "typedef struct #{wrapper_type} {",
        "#{INDENT}#{c_declaration(type, 'value')};",
        "} #{wrapper_type};",
      ]
    end

    def emit_span_type(type)
      span_type = span_type_name(type)
      [
        "typedef struct #{span_type} {",
        "#{INDENT}#{c_declaration(pointer_to(type.element_type), 'data')};",
        "#{INDENT}#{c_declaration(Types::Primitive.new('usize'), 'len')};",
        "} #{span_type};",
      ]
    end

    def struct_layout_attributes(struct_decl)
      attributes = []
      attributes << "packed" if struct_decl.packed
      attributes << "aligned(#{struct_decl.alignment})" if struct_decl.alignment
      return "" if attributes.empty?

      " __attribute__((#{attributes.join(', ')}))"
    end

    def array_return_wrapper_type_name(type)
      "mt_array_return_#{sanitize_identifier(type.to_s)}"
    end

    def span_type_name(type)
      "mt_span_#{sanitize_identifier(type.element_type.to_s)}"
    end

    def result_type_name(type)
      "mt_result_#{sanitize_identifier(type.ok_type.to_s)}_#{sanitize_identifier(type.error_type.to_s)}"
    end

    def named_type_c_name(type)
      return result_type_name(type) if type.is_a?(Types::Result)

      base_name = type.module_name&.start_with?("std.c.") ? type.name : type.module_name ? "#{type.module_name.tr('.', '_')}_#{type.name}" : type.name
      return base_name unless type.is_a?(Types::StructInstance)

      "#{base_name}_#{sanitize_identifier(type.arguments.join('_'))}"
    end

    def external_opaque_c_type(type)
      type.c_name || type.name
    end

    def sanitize_identifier(text)
      identifier = text.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/_+/, "_").sub(/^_+/, "").sub(/_+$/, "")
      identifier.empty? ? "value" : identifier
    end

    def primitive_c_type(name)
      {
        "bool" => "bool",
        "byte" => "uint8_t",
        "char" => "char",
        "i8" => "int8_t",
        "i16" => "int16_t",
        "i32" => "int32_t",
        "i64" => "int64_t",
        "u8" => "uint8_t",
        "u16" => "uint16_t",
        "u32" => "uint32_t",
        "u64" => "uint64_t",
        "isize" => "intptr_t",
        "usize" => "uintptr_t",
        "f32" => "float",
        "f64" => "double",
        "void" => "void",
        "cstr" => "const char*",
      }.fetch(name)
    end

    def generic_c_type(type)
      case type.name
      when "ptr"
        raise LoweringError, "ptr requires exactly one type argument" unless type.arguments.length == 1

        "#{c_type(type.arguments.first)}*"
      when "const_ptr"
        raise LoweringError, "const_ptr requires exactly one type argument" unless type.arguments.length == 1

        "const #{c_type(type.arguments.first)}*"
      when "ref"
        raise LoweringError, "ref requires exactly one type argument" unless type.arguments.length == 1

        "#{c_type(type.arguments.first)}*"
      when "str_builder"
        raise LoweringError, "str_builder requires exactly one type argument" unless str_builder_type?(type)

        str_builder_type_name(type)
      else
        raise LoweringError, "unsupported generic C type #{type.name}"
      end
    end

    def mutable_pointer_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
    end

    def const_pointer_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "const_ptr" && type.arguments.length == 1
    end

    def pointer_type?(type)
      mutable_pointer_type?(type)
    end

    def raw_pointer_type?(type)
      mutable_pointer_type?(type) || const_pointer_type?(type)
    end

    def ref_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "ref" && type.arguments.length == 1
    end

    def array_type?(type)
      text_buffer_type?(type) ||
        (type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
        type.arguments[1].is_a?(Types::LiteralTypeArg))
    end

    def array_element_type(type)
      return Types::Primitive.new("char") if text_buffer_type?(type)

      type.arguments.first
    end

    def array_length(type)
      return type.arguments.first.value if text_buffer_type?(type)

      type.arguments[1].value
    end

    def str_builder_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "str_builder" && type.arguments.length == 1 &&
        type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments.first.value.is_a?(Integer)
    end

    def str_builder_capacity(type)
      type.arguments.first.value
    end

    def str_builder_storage_capacity(type)
      str_builder_capacity(type) + 1
    end

    def str_builder_type_name(type)
      "mt_str_builder_#{str_builder_capacity(type)}"
    end

    def text_buffer_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1 &&
        type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments.first.value.is_a?(Integer)
    end

    def pointer_to(type)
      Types::GenericInstance.new("ptr", [type])
    end
  end
end
