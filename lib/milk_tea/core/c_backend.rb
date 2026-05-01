# frozen_string_literal: true

module MilkTea
  class CBackend
    INDENT = "  "

    def self.emit(program)
      new(program).emit
    end

    def initialize(program)
      @program = program
      @source_path = program.source_path
      @checked_index_alias_stack = []
      @checked_index_alias_id = 0
    end

    def emit
      lines = []
      constants = emitted_constants
      headers = @program.includes.map(&:header)
      if uses_panic_helper?
        headers << "<stdio.h>"
        headers << "<stdlib.h>"
      end
      headers << "<stdlib.h>" if uses_async_memory_helpers?
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

      if uses_async_memory_helpers?
        lines.concat(emit_async_memory_helpers)
        lines << ""
      end

      opaque_decls = @program.opaques
      struct_decls = sort_struct_decls(@program.structs + collect_generic_struct_decls + collect_result_decls + collect_task_decls + collect_proc_decls + collect_str_builder_decls)

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

      @program.variants.each do |variant_decl|
        lines.concat(emit_variant(variant_decl))
        lines << ""
      end

      collect_generic_variant_decls.each do |variant_decl|
        lines.concat(emit_variant(variant_decl))
        lines << ""
      end

      array_return_types = collect_array_return_types
      array_return_types.each do |type|
        lines.concat(emit_array_return_wrapper(type))
        lines << ""
      end

      function_declarations = emit_function_declarations(emitted_functions)
      unless function_declarations.empty?
        lines.concat(function_declarations)
        lines << ""
      end

      constants.each do |constant|
        lines << "#{constant_storage(constant.type)} #{c_declaration(constant.type, constant.c_name)} = #{emit_initializer(constant.value)};"
      end
      @program.globals.each do |global|
        lines << "#{global_storage(global.type)} #{c_declaration(global.type, global.c_name)} = #{emit_initializer(global.value)};"
      end
      lines << "" unless constants.empty? && @program.globals.empty?

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

      emitted_functions.each do |function|
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

        @program.globals.each do |global|
          collect_referenced_constant_names_from_expression(global.value, constants_by_name, referenced_names)
        end

        @program.static_asserts.each do |statement|
          collect_referenced_constant_names_from_expression(statement.condition, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_expression(statement.message, constants_by_name, referenced_names)
        end

        emitted_functions.each do |function|
          collect_referenced_constant_names_from_statements(function.body, constants_by_name, referenced_names)
        end

        @program.constants.select { |constant| referenced_names[constant.c_name] }
      end
    end

    def emitted_functions
      @emitted_functions ||= begin
        functions_by_name = @program.functions.each_with_object({}) do |function, result|
          result[function.c_name] = function
        end

        seeds = @program.functions.select(&:entry_point)
        if seeds.empty?
          root_module_prefix = "#{@program.module_name.tr('.', '_')}_"
          seeds = @program.functions.select { |function| function.c_name.start_with?(root_module_prefix) }
        end

        reachable_names = {}
        worklist = seeds.dup

        until worklist.empty?
          function = worklist.shift
          next if reachable_names[function.c_name]

          reachable_names[function.c_name] = true
          collect_called_function_names_from_statements(function.body, functions_by_name, reachable_names, worklist)
        end

        (@program.constants + @program.globals).each do |value|
          collect_called_function_names_from_expression(value.value, functions_by_name, reachable_names, worklist)
        end

        until worklist.empty?
          function = worklist.shift
          next if reachable_names[function.c_name]

          reachable_names[function.c_name] = true
          collect_called_function_names_from_statements(function.body, functions_by_name, reachable_names, worklist)
        end

        @program.functions.select { |function| reachable_names[function.c_name] }
      end
    end

    def all_emitted_top_level_values
      emitted_constants + @program.globals
    end

    def collect_called_function_names_from_statements(statements, functions_by_name, reachable_names, worklist)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_called_function_names_from_expression(statement.value, functions_by_name, reachable_names, worklist)
        when IR::Assignment
          collect_called_function_names_from_expression(statement.target, functions_by_name, reachable_names, worklist)
          collect_called_function_names_from_expression(statement.value, functions_by_name, reachable_names, worklist)
        when IR::BlockStmt
          collect_called_function_names_from_statements(statement.body, functions_by_name, reachable_names, worklist)
        when IR::WhileStmt
          collect_called_function_names_from_expression(statement.condition, functions_by_name, reachable_names, worklist)
          collect_called_function_names_from_statements(statement.body, functions_by_name, reachable_names, worklist)
        when IR::ForStmt
          collect_called_function_names_from_statements([statement.init], functions_by_name, reachable_names, worklist)
          collect_called_function_names_from_expression(statement.condition, functions_by_name, reachable_names, worklist)
          collect_called_function_names_from_statements(statement.body, functions_by_name, reachable_names, worklist)
          collect_called_function_names_from_statements([statement.post], functions_by_name, reachable_names, worklist)
        when IR::IfStmt
          collect_called_function_names_from_expression(statement.condition, functions_by_name, reachable_names, worklist)
          collect_called_function_names_from_statements(statement.then_body, functions_by_name, reachable_names, worklist)
          collect_called_function_names_from_statements(statement.else_body, functions_by_name, reachable_names, worklist) if statement.else_body
        when IR::SwitchStmt
          collect_called_function_names_from_expression(statement.expression, functions_by_name, reachable_names, worklist)
          statement.cases.each do |switch_case|
            collect_called_function_names_from_statements(switch_case.body, functions_by_name, reachable_names, worklist)
          end
        when IR::StaticAssert
          collect_called_function_names_from_expression(statement.condition, functions_by_name, reachable_names, worklist)
          collect_called_function_names_from_expression(statement.message, functions_by_name, reachable_names, worklist)
        when IR::ReturnStmt
          collect_called_function_names_from_expression(statement.value, functions_by_name, reachable_names, worklist) if statement.value
        when IR::ExpressionStmt
          collect_called_function_names_from_expression(statement.expression, functions_by_name, reachable_names, worklist)
        end
      end
    end

    def collect_called_function_names_from_expression(expression, functions_by_name, reachable_names, worklist)
      case expression
      when IR::Name
        callee = functions_by_name[expression.name]
        if callee && !reachable_names[callee.c_name]
          worklist << callee
        end
      when IR::Member
        collect_called_function_names_from_expression(expression.receiver, functions_by_name, reachable_names, worklist)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_called_function_names_from_expression(expression.receiver, functions_by_name, reachable_names, worklist)
        collect_called_function_names_from_expression(expression.index, functions_by_name, reachable_names, worklist)
      when IR::Call
        if expression.callee.is_a?(String)
          callee = functions_by_name[expression.callee]
          if callee && !reachable_names[callee.c_name]
            worklist << callee
          end
        else
          collect_called_function_names_from_expression(expression.callee, functions_by_name, reachable_names, worklist)
        end
        expression.arguments.each do |argument|
          collect_called_function_names_from_expression(argument, functions_by_name, reachable_names, worklist)
        end
      when IR::Unary
        collect_called_function_names_from_expression(expression.operand, functions_by_name, reachable_names, worklist)
      when IR::Binary
        collect_called_function_names_from_expression(expression.left, functions_by_name, reachable_names, worklist)
        collect_called_function_names_from_expression(expression.right, functions_by_name, reachable_names, worklist)
      when IR::Conditional
        collect_called_function_names_from_expression(expression.condition, functions_by_name, reachable_names, worklist)
        collect_called_function_names_from_expression(expression.then_expression, functions_by_name, reachable_names, worklist)
        collect_called_function_names_from_expression(expression.else_expression, functions_by_name, reachable_names, worklist)
      when IR::ReinterpretExpr, IR::AddressOf, IR::Cast
        collect_called_function_names_from_expression(expression.expression, functions_by_name, reachable_names, worklist)
      when IR::AggregateLiteral
        expression.fields.each do |field|
          collect_called_function_names_from_expression(field.value, functions_by_name, reachable_names, worklist)
        end
      when IR::ArrayLiteral
        expression.elements.each do |element|
          collect_called_function_names_from_expression(element, functions_by_name, reachable_names, worklist)
        end
      when IR::VariantLiteral
        expression.fields.each do |field|
          collect_called_function_names_from_expression(field.value, functions_by_name, reachable_names, worklist)
        end
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
        when IR::BlockStmt
          collect_referenced_constant_names_from_statements(statement.body, constants_by_name, referenced_names)
        when IR::WhileStmt
          collect_referenced_constant_names_from_expression(statement.condition, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_statements(statement.body, constants_by_name, referenced_names)
        when IR::ForStmt
          collect_referenced_constant_names_from_statements([statement.init], constants_by_name, referenced_names)
          collect_referenced_constant_names_from_expression(statement.condition, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_statements(statement.body, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_statements([statement.post], constants_by_name, referenced_names)
        when IR::IfStmt
          collect_referenced_constant_names_from_expression(statement.condition, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_statements(statement.then_body, constants_by_name, referenced_names)
          collect_referenced_constant_names_from_statements(statement.else_body, constants_by_name, referenced_names) if statement.else_body
        when IR::SwitchStmt
          collect_referenced_constant_names_from_expression(statement.expression, constants_by_name, referenced_names)
          statement.cases.each do |switch_case|
            collect_referenced_constant_names_from_expression(switch_case.value, constants_by_name, referenced_names) if switch_case.is_a?(IR::SwitchCase)
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
      when IR::VariantLiteral
        expression.fields.each { |field| collect_referenced_constant_names_from_expression(field.value, constants_by_name, referenced_names) }
      end
    end

    def uses_panic_helper?
      uses_mt_panic_helper? || uses_mt_panic_str_helper?
    end

    def uses_mt_panic_helper?
      collect_checked_array_index_types.any? || collect_checked_span_index_types.any? ||
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_panic mt_str_builder_len mt_str_builder_as_cstr mt_str_builder_assign mt_str_builder_append mt_foreign_str_to_cstr_temp mt_foreign_strs_to_cstrs_temp]) }
    end

    def uses_mt_panic_str_helper?
      emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_panic_str]) }
    end

    def uses_foreign_temp_cstr_helpers?
      emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_foreign_str_to_cstr_temp mt_free_foreign_cstr_temp mt_foreign_strs_to_cstrs_temp mt_free_foreign_cstrs_temp]) }
    end

    def uses_text_buffer_helpers?
      emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_len mt_str_builder_as_cstr mt_str_builder_clear mt_str_builder_assign mt_str_builder_append mt_str_builder_prepare_write]) }
    end

    def uses_str_builder_helpers?
      emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_len mt_str_builder_as_cstr mt_str_builder_clear mt_str_builder_assign mt_str_builder_append mt_str_builder_prepare_write]) }
    end

    def uses_async_memory_helpers?
      emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_async_alloc mt_async_free]) }
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
      when IR::BlockStmt
        statement.body.any? { |inner| statement_uses_named_call?(inner, callees) }
      when IR::WhileStmt
        expression_uses_named_call?(statement.condition, callees) || statement.body.any? { |inner| statement_uses_named_call?(inner, callees) }
      when IR::ForStmt
        statement_uses_named_call?(statement.init, callees) ||
          expression_uses_named_call?(statement.condition, callees) ||
          statement.body.any? { |inner| statement_uses_named_call?(inner, callees) } ||
          statement_uses_named_call?(statement.post, callees)
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

    def emit_async_memory_helpers
      [
        "static void* mt_async_alloc(uintptr_t size) {",
        "#{INDENT}void* memory = calloc(1, (size_t) size);",
        "#{INDENT}if (memory == NULL) {",
        "#{INDENT * 2}abort();",
        "#{INDENT}}",
        "#{INDENT}return memory;",
        "}",
        "",
        "static void mt_async_free(void* memory) {",
        "#{INDENT}free(memory);",
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

    def emit_str_builder_helpers
      lines = []

      if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_len mt_str_builder_as_cstr mt_str_builder_append]) }
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

      if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_as_cstr]) }
        lines << "" unless lines.empty?
        lines.concat([
          "static const char* mt_str_builder_as_cstr(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
          "#{INDENT}(void)mt_str_builder_len(data, cap, len, dirty);",
          "#{INDENT}return data;",
          "}",
        ])
      end

      if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_clear]) }
        lines << "" unless lines.empty?
        lines.concat([
          "static void mt_str_builder_clear(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {",
          "#{INDENT}memset(data, 0, cap + 1);",
          "#{INDENT}*len = 0;",
          "#{INDENT}*dirty = false;",
          "}",
        ])
      end

      if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_assign]) }
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

      if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_append]) }
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

      if emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_builder_prepare_write]) }
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

    def emit_variant(variant_decl)
      lines = []
      outer_c = variant_decl.c_name
      payload_arms = variant_decl.arms.select { |a| a.fields.any? }

      # Per-arm payload structs
      payload_arms.each do |arm|
        lines << "struct #{arm.c_name} {"
        arm.fields.each do |field|
          lines << "#{INDENT}#{c_declaration(field.type, field.name)};"
        end
        lines << "};"
        lines << "typedef struct #{arm.c_name} #{arm.c_name};"
      end

      # Kind enum
      lines << "typedef int32_t #{outer_c}_kind;"
      unless variant_decl.arms.empty?
        lines << "enum {"
        variant_decl.arms.each_with_index do |arm, index|
          suffix = index == variant_decl.arms.length - 1 ? "" : ","
          lines << "#{INDENT}#{outer_c}_kind_#{arm.name} = #{index}#{suffix}"
        end
        lines << "};"
      end

      # Data union (only if at least one arm has payload)
      if payload_arms.any?
        lines << "union #{outer_c}__data {"
        payload_arms.each do |arm|
          lines << "#{INDENT}struct #{arm.c_name} #{arm.name};"
        end
        lines << "};"
      end

      # Outer struct
      lines << "struct #{outer_c} {"
      lines << "#{INDENT}#{outer_c}_kind kind;"
      lines << "#{INDENT}union #{outer_c}__data data;" if payload_arms.any?
      lines << "};"
      lines << "typedef struct #{outer_c} #{outer_c};"
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
      @checked_index_alias_id = 0
      body = compact_generated_statement_sequence(function.body)
      lines = ["#{function_signature(function)} {"]
      used_labels = collect_used_labels(body)
      if body.empty?
        lines << "#{INDENT}(void)0;"
      else
        lines.concat(emit_statement_sequence(body, 1, function:, used_labels:))
      end
      lines << "}"
      lines
    end

    def emit_statement_sequence(statements, level, function:, used_labels:)
      statements.flat_map { |statement| emit_statement(statement, level, function:, used_labels:) }
    end

    def emit_statement(statement, level, function:, used_labels:)
      indent = INDENT * level
      aliases = checked_index_aliases_for_statement(statement)
      alias_lines = emit_checked_index_alias_declarations(aliases, indent)
      line_directive = if statement.respond_to?(:line) && statement.line
                         sp = (statement.respond_to?(:source_path) && statement.source_path) || @source_path
                         sp ? ["#line #{statement.line} #{sp.inspect}"] : []
                       else
                         []
                       end
      statement_lines = with_checked_index_aliases(aliases) do
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
            lines.concat(emit_statement_sequence(statement.body, level + 1, function:, used_labels:))
            lines << "#{indent}}"
            lines
          else
            emit_statement_sequence(statement.body, level, function:, used_labels:)
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
          lines.concat(emit_statement_sequence(statement.body, level + 1, function:, used_labels:))
          lines << "#{indent}}"
          lines
        when IR::ForStmt
          lines = ["#{indent}for (#{emit_for_clause_statement(statement.init)}; #{emit_expression(statement.condition)}; #{emit_for_clause_statement(statement.post)}) {"]
          lines.concat(emit_statement_sequence(statement.body, level + 1, function:, used_labels:))
          lines << "#{indent}}"
          lines
        when IR::BreakStmt
          ["#{indent}break;"]
        when IR::ContinueStmt
          ["#{indent}continue;"]
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
          lines.concat(emit_statement_sequence(statement.then_body, level + 1, function:, used_labels:))
          if statement.else_body && !statement.else_body.empty?
            lines << "#{indent}} else {"
            lines.concat(emit_statement_sequence(statement.else_body, level + 1, function:, used_labels:))
          end
          lines << "#{indent}}"
          lines
        when IR::SwitchStmt
          lines = ["#{indent}switch (#{emit_expression(statement.expression)}) {"]
          statement.cases.each do |switch_case|
            if switch_case.is_a?(IR::SwitchDefaultCase)
              lines << "#{indent}#{INDENT}default: {"
            else
              lines << "#{indent}#{INDENT}case #{emit_expression(switch_case.value)}: {"
            end
            lines.concat(emit_statement_sequence(switch_case.body, level + 2, function:, used_labels:))
            lines << "#{indent}#{INDENT}#{INDENT}break;" unless body_terminates?(switch_case.body)
            lines << "#{indent}#{INDENT}}"
          end
          lines << "#{indent}}"
          lines
        else
          raise LoweringError, "unsupported IR statement #{statement.class.name}"
        end
      end

      alias_lines + line_directive + statement_lines
    end

    def compact_generated_statement_sequence(statements)
      transformed = statements.map { |statement| transform_compactable_nested_bodies(statement) }
      compacted = []
      index = 0

      while index < transformed.length
        current = transformed[index]
        following = transformed[index + 1]
        remaining = transformed[(index + 2)..] || []

        if following && (folded_local_alias = fold_single_use_local_alias(current, following, remaining))
          compacted << folded_local_alias
          index += 2
          next
        end

        if following && (folded_if = fold_single_use_bool_if_temp(current, following, remaining))
          compacted << folded_if
          index += 2
          next
        end

        compacted << current
        index += 1
      end

      compacted
    end

    def transform_compactable_nested_bodies(statement)
      case statement
      when IR::BlockStmt
        IR::BlockStmt.new(body: compact_generated_statement_sequence(statement.body))
      when IR::WhileStmt
        IR::WhileStmt.new(condition: statement.condition, body: compact_generated_statement_sequence(statement.body))
      when IR::ForStmt
        IR::ForStmt.new(
          init: statement.init,
          condition: statement.condition,
          post: statement.post,
          body: compact_generated_statement_sequence(statement.body),
        )
      when IR::IfStmt
        IR::IfStmt.new(
          condition: statement.condition,
          then_body: compact_generated_statement_sequence(statement.then_body),
          else_body: statement.else_body ? compact_generated_statement_sequence(statement.else_body) : nil,
        )
      when IR::SwitchStmt
        IR::SwitchStmt.new(
          expression: statement.expression,
          cases: statement.cases.map do |switch_case|
            if switch_case.is_a?(IR::SwitchDefaultCase)
              IR::SwitchDefaultCase.new(body: compact_generated_statement_sequence(switch_case.body))
            else
              IR::SwitchCase.new(value: switch_case.value, body: compact_generated_statement_sequence(switch_case.body))
            end
          end,
        )
      else
        statement
      end
    end

    def fold_single_use_local_alias(source_decl, alias_decl, remaining_statements)
      return unless source_decl.is_a?(IR::LocalDecl)
      return unless alias_decl.is_a?(IR::LocalDecl)
      return unless compiler_generated_local_name?(source_decl.c_name)
      return if array_type?(source_decl.type) || array_type?(alias_decl.type)
      return unless source_decl.type == alias_decl.type
      return unless alias_decl.value.is_a?(IR::Name) && alias_decl.value.name == source_decl.c_name
      return unless name_reference_count_in_statements(remaining_statements, source_decl.c_name).zero?

      IR::LocalDecl.new(name: alias_decl.name, c_name: alias_decl.c_name, type: alias_decl.type, value: source_decl.value)
    end

    def compiler_generated_local_name?(name)
      name.start_with?("__mt_")
    end

    def fold_single_use_bool_if_temp(local_decl, if_stmt, remaining_statements)
      return unless local_decl.is_a?(IR::LocalDecl)
      return unless if_stmt.is_a?(IR::IfStmt)
      return unless bool_type?(local_decl.type)

      condition_kind = single_use_bool_if_condition_kind(if_stmt.condition, local_decl.c_name)
      return unless condition_kind
      return unless name_reference_count_in_statements(if_stmt.then_body, local_decl.c_name).zero?
      return unless name_reference_count_in_statements(if_stmt.else_body || [], local_decl.c_name).zero?
      return unless name_reference_count_in_statements(remaining_statements, local_decl.c_name).zero?

      condition = if condition_kind == :direct
                    local_decl.value
                  else
                    IR::Unary.new(operator: "not", operand: local_decl.value, type: local_decl.type)
                  end

      IR::IfStmt.new(condition:, then_body: if_stmt.then_body, else_body: if_stmt.else_body)
    end

    def single_use_bool_if_condition_kind(condition, temp_name)
      return :direct if condition.is_a?(IR::Name) && condition.name == temp_name

      if condition.is_a?(IR::Unary) && condition.operator == "not" && condition.operand.is_a?(IR::Name) && condition.operand.name == temp_name
        return :negated
      end

      nil
    end

    def name_reference_count_in_statements(statements, name)
      statements.sum { |statement| name_reference_count_in_statement(statement, name) }
    end

    def name_reference_count_in_statement(statement, name)
      case statement
      when IR::LocalDecl
        name_reference_count_in_expression(statement.value, name)
      when IR::Assignment
        name_reference_count_in_expression(statement.target, name) + name_reference_count_in_expression(statement.value, name)
      when IR::BlockStmt, IR::WhileStmt, IR::ForStmt
        count = name_reference_count_in_statements(statement.body, name)
        return count unless statement.is_a?(IR::WhileStmt) || statement.is_a?(IR::ForStmt)

        count += name_reference_count_in_expression(statement.condition, name)
        count += name_reference_count_in_statement(statement.init, name) if statement.is_a?(IR::ForStmt)
        count += name_reference_count_in_statement(statement.post, name) if statement.is_a?(IR::ForStmt)
        count
      when IR::IfStmt
        name_reference_count_in_expression(statement.condition, name) +
          name_reference_count_in_statements(statement.then_body, name) +
          name_reference_count_in_statements(statement.else_body || [], name)
      when IR::SwitchStmt
        name_reference_count_in_expression(statement.expression, name) +
          statement.cases.sum { |switch_case| (switch_case.is_a?(IR::SwitchCase) ? name_reference_count_in_expression(switch_case.value, name) : 0) + name_reference_count_in_statements(switch_case.body, name) }
      when IR::StaticAssert
        name_reference_count_in_expression(statement.condition, name) + name_reference_count_in_expression(statement.message, name)
      when IR::ReturnStmt
        statement.value ? name_reference_count_in_expression(statement.value, name) : 0
      when IR::ExpressionStmt
        name_reference_count_in_expression(statement.expression, name)
      else
        0
      end
    end

    def name_reference_count_in_expression(expression, name)
      case expression
      when IR::Name
        expression.name == name ? 1 : 0
      when IR::Member
        name_reference_count_in_expression(expression.receiver, name)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        name_reference_count_in_expression(expression.receiver, name) + name_reference_count_in_expression(expression.index, name)
      when IR::Call
        callee_count = expression.callee.is_a?(String) ? 0 : name_reference_count_in_expression(expression.callee, name)
        callee_count + expression.arguments.sum { |argument| name_reference_count_in_expression(argument, name) }
      when IR::Unary
        name_reference_count_in_expression(expression.operand, name)
      when IR::Binary
        name_reference_count_in_expression(expression.left, name) + name_reference_count_in_expression(expression.right, name)
      when IR::Conditional
        name_reference_count_in_expression(expression.condition, name) +
          name_reference_count_in_expression(expression.then_expression, name) +
          name_reference_count_in_expression(expression.else_expression, name)
      when IR::ReinterpretExpr
        name_reference_count_in_expression(expression.expression, name)
      when IR::AddressOf, IR::Cast
        name_reference_count_in_expression(expression.expression, name)
      when IR::AggregateLiteral
        expression.fields.sum { |field| name_reference_count_in_expression(field.value, name) }
      when IR::ArrayLiteral
        expression.elements.sum { |element| name_reference_count_in_expression(element, name) }
      when IR::VariantLiteral
        expression.fields.sum { |field| name_reference_count_in_expression(field.value, name) }
      else
        0
      end
    end

    def bool_type?(type)
      type.is_a?(Types::Primitive) && type.name == "bool"
    end

    def checked_index_aliases_for_statement(statement)
      expressions = case statement
                    when IR::LocalDecl
                      [statement.value]
                    when IR::Assignment
                      [statement.target, statement.value]
                    when IR::ExpressionStmt
                      [statement.expression]
                    when IR::ReturnStmt
                      statement.value ? [statement.value] : []
                    else
                      []
                    end

      collect_checked_index_aliases(expressions.compact)
    end

    def collect_checked_index_aliases(expressions)
      counts = Hash.new(0)
      order = []
      expressions.each do |expression|
        collect_checked_index_alias_candidates(expression, counts, order)
      end

      order.each_with_object({}) do |expression, aliases|
        next unless counts[expression] > 1
        next unless hoistable_checked_index_alias?(expression)

        aliases[expression] = fresh_checked_index_alias_name
      end
    end

    def collect_checked_index_alias_candidates(expression, counts, order)
      case expression
      when IR::Member
        collect_checked_index_alias_candidates(expression.receiver, counts, order)
      when IR::Index
        collect_checked_index_alias_candidates(expression.receiver, counts, order)
        collect_checked_index_alias_candidates(expression.index, counts, order)
      when IR::CheckedIndex, IR::CheckedSpanIndex
        order << expression unless counts.key?(expression)
        counts[expression] += 1
        collect_checked_index_alias_candidates(expression.receiver, counts, order)
        collect_checked_index_alias_candidates(expression.index, counts, order)
      when IR::Call
        collect_checked_index_alias_candidates(expression.callee, counts, order) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_checked_index_alias_candidates(argument, counts, order) }
      when IR::Unary
        collect_checked_index_alias_candidates(expression.operand, counts, order)
      when IR::Binary
        collect_checked_index_alias_candidates(expression.left, counts, order)
        collect_checked_index_alias_candidates(expression.right, counts, order)
      when IR::Conditional
        collect_checked_index_alias_candidates(expression.condition, counts, order)
        collect_checked_index_alias_candidates(expression.then_expression, counts, order)
        collect_checked_index_alias_candidates(expression.else_expression, counts, order)
      when IR::ReinterpretExpr, IR::AddressOf, IR::Cast
        collect_checked_index_alias_candidates(expression.expression, counts, order)
      when IR::AggregateLiteral
        expression.fields.each { |field| collect_checked_index_alias_candidates(field.value, counts, order) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_checked_index_alias_candidates(element, counts, order) }
      when IR::VariantLiteral
        expression.fields.each { |field| collect_checked_index_alias_candidates(field.value, counts, order) }
      end
    end

    def hoistable_checked_index_alias?(expression)
      side_effect_free_expression?(expression.receiver) && side_effect_free_expression?(expression.index)
    end

    def side_effect_free_expression?(expression)
      case expression
      when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::ZeroInit, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        true
      when IR::Member
        side_effect_free_expression?(expression.receiver)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        side_effect_free_expression?(expression.receiver) && side_effect_free_expression?(expression.index)
      when IR::Unary
        side_effect_free_expression?(expression.operand)
      when IR::Binary
        side_effect_free_expression?(expression.left) && side_effect_free_expression?(expression.right)
      when IR::Conditional
        side_effect_free_expression?(expression.condition) &&
          side_effect_free_expression?(expression.then_expression) &&
          side_effect_free_expression?(expression.else_expression)
      when IR::ReinterpretExpr, IR::AddressOf, IR::Cast
        side_effect_free_expression?(expression.expression)
      when IR::AggregateLiteral
        expression.fields.all? { |field| side_effect_free_expression?(field.value) }
      when IR::ArrayLiteral
        expression.elements.all? { |element| side_effect_free_expression?(element) }
      when IR::Call
        false
      else
        false
      end
    end

    def emit_checked_index_alias_declarations(aliases, indent)
      aliases.map do |expression, alias_name|
        "#{indent}#{c_declaration(pointer_to(expression.type), alias_name)} = #{emit_checked_index_pointer(expression)};"
      end
    end

    def emit_checked_index_pointer(expression)
      case expression
      when IR::CheckedIndex
        "#{checked_array_index_helper_name(expression.receiver_type)}(&(#{emit_expression(expression.receiver)}), #{emit_expression(expression.index)})"
      when IR::CheckedSpanIndex
        "#{checked_span_index_helper_name(expression.receiver_type)}(#{emit_expression(expression.receiver)}, #{emit_expression(expression.index)})"
      else
        raise LoweringError, "unsupported checked index alias expression #{expression.class.name}"
      end
    end

    def fresh_checked_index_alias_name
      @checked_index_alias_id += 1
      "__mt_checked_index_ptr_#{@checked_index_alias_id}"
    end

    def with_checked_index_aliases(aliases)
      @checked_index_alias_stack << aliases
      yield
    ensure
      @checked_index_alias_stack.pop
    end

    def checked_index_alias(expression)
      @checked_index_alias_stack.reverse_each do |aliases|
        alias_name = aliases[expression]
        return alias_name if alias_name
      end

      nil
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
      when IR::BreakStmt, IR::ContinueStmt
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
        when IR::BlockStmt, IR::WhileStmt, IR::ForStmt
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

    def emit_for_clause_statement(statement)
      case statement
      when IR::LocalDecl
        raise LoweringError, "array for-loop init declarations are unsupported" if array_type?(statement.type)

        "#{c_declaration(statement.type, statement.c_name)} = #{emit_initializer(statement.value)}"
      when IR::Assignment
        if array_type?(statement.target.type) && statement.operator == "="
          raise LoweringError, "array for-loop assignment clauses are unsupported"
        end

        "#{emit_expression(statement.target)} #{statement.operator} #{emit_expression(statement.value)}"
      when IR::ExpressionStmt
        emit_expression(statement.expression)
      else
        raise LoweringError, "unsupported for-loop clause #{statement.class.name}"
      end
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
        if (alias_name = checked_index_alias(expression))
          "(*#{alias_name})"
        else
          "(*#{checked_array_index_helper_name(expression.receiver_type)}(&(#{emit_expression(expression.receiver)}), #{emit_expression(expression.index)}))"
        end
      when IR::CheckedSpanIndex
        if (alias_name = checked_index_alias(expression))
          "(*#{alias_name})"
        else
          "(*#{checked_span_index_helper_name(expression.receiver_type)}(#{emit_expression(expression.receiver)}, #{emit_expression(expression.index)}))"
        end
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
        case expression.expression
        when IR::CheckedIndex
          alias_name = checked_index_alias(expression.expression)
          alias_name || "#{checked_array_index_helper_name(expression.expression.receiver_type)}(&(#{emit_expression(expression.expression.receiver)}), #{emit_expression(expression.expression.index)})"
        when IR::CheckedSpanIndex
          alias_name = checked_index_alias(expression.expression)
          alias_name || "#{checked_span_index_helper_name(expression.expression.receiver_type)}(#{emit_expression(expression.expression.receiver)}, #{emit_expression(expression.expression.index)})"
        else
          "&#{wrap_expression(expression.expression)}"
        end
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
      when IR::VariantLiteral
        emit_variant_literal(expression)
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

    def emit_variant_literal(expression)
      outer_c = named_type_c_name(expression.type)
      kind_constant = "#{outer_c}_kind_#{expression.arm_name}"
      if expression.fields.empty?
        "(#{outer_c}){ .kind = #{kind_constant} }"
      else
        arm_c = "#{outer_c}_#{expression.arm_name}"
        payload_fields = expression.fields.map { |f| ".#{f.name} = #{emit_initializer(f.value)}" }.join(", ")
        "(#{outer_c}){ .kind = #{kind_constant}, .data.#{expression.arm_name} = (struct #{arm_c}){ #{payload_fields} } }"
      end
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

      emitted_functions.each do |function|
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
        when IR::ForStmt
          collect_reinterpret_helpers_from_statements([statement.init], helpers, seen)
          collect_reinterpret_helpers_from_expression(statement.condition, helpers, seen)
          collect_reinterpret_helpers_from_statements(statement.body, helpers, seen)
          collect_reinterpret_helpers_from_statements([statement.post], helpers, seen)
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
      when IR::CheckedIndex, IR::CheckedSpanIndex
        checked_index_alias(expression) || emit_expression(expression)
      when IR::Name, IR::Member, IR::Index
        emit_expression(expression)
      else
        "(#{emit_expression(expression)})"
      end
    end

    def pointer_member_receiver?(expression)
      return true if checked_index_alias(expression)

      (expression.is_a?(IR::Name) && expression.pointer) ||
        (expression.respond_to?(:type) && (raw_pointer_type?(expression.type) || ref_type?(expression.type)))
    end

    def wrap_index_receiver(expression)
      case expression
      when IR::CheckedIndex, IR::CheckedSpanIndex
        if (alias_name = checked_index_alias(expression))
          "(*#{alias_name})"
        else
          emit_expression(expression)
        end
      when IR::Name, IR::Member, IR::Index, IR::Call
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

      if type.is_a?(Types::Proc)
        return [proc_type_name(type), name]
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
      when Types::Task
        base = task_type_name(type)
        pointer ? "#{base}*" : base
      when Types::Proc
        base = proc_type_name(type)
        pointer ? "#{base}*" : base
      when Types::GenericInstance
        base = generic_c_type(type)
        pointer ? "#{base}*" : base
      when Types::Struct, Types::StructInstance, Types::Union, Types::Enum, Types::Flags, Types::Variant, Types::VariantInstance, Types::VariantArmPayload
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

    def global_storage(_type)
      "static"
    end

    def collect_array_return_types
      emitted_functions.map(&:return_type).select { |type| array_type?(type) }.uniq
    end

    def collect_checked_array_index_types
      array_types = []
      emitted_functions.each do |function|
        collect_checked_array_index_types_from_statements(function.body, array_types)
      end
      array_types.uniq
    end

    def collect_checked_span_index_types
      span_types = []
      emitted_functions.each do |function|
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
        when IR::BlockStmt
          collect_checked_array_index_types_from_statements(statement.body, array_types)
        when IR::WhileStmt
          collect_checked_array_index_types_from_expression(statement.condition, array_types)
          collect_checked_array_index_types_from_statements(statement.body, array_types)
        when IR::ForStmt
          collect_checked_array_index_types_from_statements([statement.init], array_types)
          collect_checked_array_index_types_from_expression(statement.condition, array_types)
          collect_checked_array_index_types_from_statements(statement.body, array_types)
          collect_checked_array_index_types_from_statements([statement.post], array_types)
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
        when IR::BlockStmt
          collect_checked_span_index_types_from_statements(statement.body, span_types)
        when IR::WhileStmt
          collect_checked_span_index_types_from_expression(statement.condition, span_types)
          collect_checked_span_index_types_from_statements(statement.body, span_types)
        when IR::ForStmt
          collect_checked_span_index_types_from_statements([statement.init], span_types)
          collect_checked_span_index_types_from_expression(statement.condition, span_types)
          collect_checked_span_index_types_from_statements(statement.body, span_types)
          collect_checked_span_index_types_from_statements([statement.post], span_types)
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

      all_emitted_top_level_values.each do |value|
        collect_span_type(value.type, span_types, visited)
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

      each_variant_arm_field_type do |field_type|
        collect_span_type(field_type, span_types, visited)
      end

      emitted_functions.each do |function|
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

    def collect_task_decls
      collect_task_types.map do |type|
        IR::StructDecl.new(
          name: type.to_s,
          c_name: task_type_name(type),
          fields: type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
          packed: false,
          alignment: nil,
        )
      end
    end

    def collect_proc_decls
      collect_proc_types.map do |type|
        IR::StructDecl.new(
          name: type.to_s,
          c_name: proc_type_name(type),
          fields: [
            IR::Field.new(name: "env", type: Types::GenericInstance.new("ptr", [Types::Primitive.new("void")])),
            IR::Field.new(name: "invoke", type: Types::Function.new(nil, params: [Types::Parameter.new("env", Types::GenericInstance.new("ptr", [Types::Primitive.new("void")]))] + type.params, return_type: type.return_type)),
            IR::Field.new(name: "release", type: Types::Function.new(nil, params: [Types::Parameter.new("env", Types::GenericInstance.new("ptr", [Types::Primitive.new("void")]))], return_type: Types::Primitive.new("void"))),
            IR::Field.new(name: "retain", type: Types::Function.new(nil, params: [Types::Parameter.new("env", Types::GenericInstance.new("ptr", [Types::Primitive.new("void")]))], return_type: Types::Primitive.new("void"))),
          ],
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

    def collect_generic_variant_decls
      collect_generic_variant_types.map do |type|
        outer_c = named_type_c_name(type)
        arms = type.arm_names.map do |arm_name|
          fields = type.arm(arm_name)
          IR::VariantArm.new(
            name: arm_name,
            c_name: "#{outer_c}_#{arm_name}",
            fields: fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
          )
        end
        IR::VariantDecl.new(name: type.to_s, c_name: outer_c, arms:)
      end
    end

    def collect_result_types
      result_types = []
      visited = {}

      all_emitted_top_level_values.each do |value|
        collect_result_type(value.type, result_types, visited)
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

      each_variant_arm_field_type do |field_type|
        collect_result_type(field_type, result_types, visited)
      end

      emitted_functions.each do |function|
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

    def collect_task_types
      task_types = []
      visited = {}

      all_emitted_top_level_values.each do |value|
        collect_task_type(value.type, task_types, visited)
      end

      @program.structs.each do |struct_decl|
        struct_decl.fields.each do |field|
          collect_task_type(field.type, task_types, visited)
        end
      end

      @program.unions.each do |union_decl|
        union_decl.fields.each do |field|
          collect_task_type(field.type, task_types, visited)
        end
      end

      each_variant_arm_field_type do |field_type|
        collect_task_type(field_type, task_types, visited)
      end

      emitted_functions.each do |function|
        collect_task_type(function.return_type, task_types, visited)
        function.params.each do |param|
          collect_task_type(param.type, task_types, visited)
        end
        collect_task_types_from_statements(function.body, task_types, visited)
      end

      @program.static_asserts.each do |statement|
        collect_task_types_from_expression(statement.condition, task_types, visited)
        collect_task_types_from_expression(statement.message, task_types, visited)
      end

      task_types
    end

    def collect_proc_types
      proc_types = []
      visited = {}

      all_emitted_top_level_values.each do |value|
        collect_proc_type(value.type, proc_types, visited)
      end

      @program.structs.each do |struct_decl|
        struct_decl.fields.each do |field|
          collect_proc_type(field.type, proc_types, visited)
        end
      end

      @program.unions.each do |union_decl|
        union_decl.fields.each do |field|
          collect_proc_type(field.type, proc_types, visited)
        end
      end

      each_variant_arm_field_type do |field_type|
        collect_proc_type(field_type, proc_types, visited)
      end

      emitted_functions.each do |function|
        collect_proc_type(function.return_type, proc_types, visited)
        function.params.each do |param|
          collect_proc_type(param.type, proc_types, visited)
        end
        collect_proc_types_from_statements(function.body, proc_types, visited)
      end

      @program.static_asserts.each do |statement|
        collect_proc_types_from_expression(statement.condition, proc_types, visited)
        collect_proc_types_from_expression(statement.message, proc_types, visited)
      end

      proc_types
    end

    def collect_proc_types_from_statements(statements, proc_types, visited)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_proc_type(statement.type, proc_types, visited)
          collect_proc_types_from_expression(statement.value, proc_types, visited)
        when IR::Assignment
          collect_proc_types_from_expression(statement.target, proc_types, visited)
          collect_proc_types_from_expression(statement.value, proc_types, visited)
        when IR::BlockStmt
          collect_proc_types_from_statements(statement.body, proc_types, visited)
        when IR::WhileStmt
          collect_proc_types_from_expression(statement.condition, proc_types, visited)
          collect_proc_types_from_statements(statement.body, proc_types, visited)
        when IR::ForStmt
          collect_proc_types_from_statements([statement.init], proc_types, visited)
          collect_proc_types_from_expression(statement.condition, proc_types, visited)
          collect_proc_types_from_statements(statement.body, proc_types, visited)
          collect_proc_types_from_statements([statement.post], proc_types, visited)
        when IR::IfStmt
          collect_proc_types_from_expression(statement.condition, proc_types, visited)
          collect_proc_types_from_statements(statement.then_body, proc_types, visited)
          collect_proc_types_from_statements(statement.else_body, proc_types, visited) if statement.else_body
        when IR::SwitchStmt
          collect_proc_types_from_expression(statement.expression, proc_types, visited)
          statement.cases.each do |switch_case|
            collect_proc_types_from_statements(switch_case.body, proc_types, visited)
          end
        when IR::StaticAssert
          collect_proc_types_from_expression(statement.condition, proc_types, visited)
          collect_proc_types_from_expression(statement.message, proc_types, visited)
        when IR::ReturnStmt
          collect_proc_types_from_expression(statement.value, proc_types, visited) if statement.value
        when IR::ExpressionStmt
          collect_proc_types_from_expression(statement.expression, proc_types, visited)
        end
      end
    end

    def collect_proc_types_from_expression(expression, proc_types, visited)
      case expression
      when IR::Member
        collect_proc_types_from_expression(expression.receiver, proc_types, visited)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_proc_types_from_expression(expression.receiver, proc_types, visited)
        collect_proc_types_from_expression(expression.index, proc_types, visited)
      when IR::Call
        collect_proc_type(expression.type, proc_types, visited)
        collect_proc_types_from_expression(expression.callee, proc_types, visited) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_proc_types_from_expression(argument, proc_types, visited) }
      when IR::Unary
        collect_proc_types_from_expression(expression.operand, proc_types, visited)
      when IR::Binary
        collect_proc_types_from_expression(expression.left, proc_types, visited)
        collect_proc_types_from_expression(expression.right, proc_types, visited)
      when IR::Conditional
        collect_proc_types_from_expression(expression.condition, proc_types, visited)
        collect_proc_types_from_expression(expression.then_expression, proc_types, visited)
        collect_proc_types_from_expression(expression.else_expression, proc_types, visited)
      when IR::ReinterpretExpr
        collect_proc_type(expression.target_type, proc_types, visited)
        collect_proc_type(expression.source_type, proc_types, visited)
        collect_proc_types_from_expression(expression.expression, proc_types, visited)
      when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        collect_proc_type(expression.target_type, proc_types, visited)
      when IR::AddressOf, IR::Cast
        collect_proc_types_from_expression(expression.expression, proc_types, visited)
      when IR::AggregateLiteral
        collect_proc_type(expression.type, proc_types, visited)
        expression.fields.each { |field| collect_proc_types_from_expression(field.value, proc_types, visited) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_proc_types_from_expression(element, proc_types, visited) }
      end
    end

    def collect_proc_type(type, proc_types, visited)
      return unless type
      return if visited[type]

      visited[type] = true

      case type
      when Types::Nullable
        collect_proc_type(type.base, proc_types, visited)
      when Types::Result
        collect_proc_type(type.ok_type, proc_types, visited)
        collect_proc_type(type.error_type, proc_types, visited)
      when Types::Task
        collect_proc_type(type.result_type, proc_types, visited)
      when Types::Proc
        proc_types << type
        type.params.each do |param|
          collect_proc_type(param.type, proc_types, visited)
        end
        collect_proc_type(type.return_type, proc_types, visited)
      when Types::Span
        collect_proc_type(type.element_type, proc_types, visited)
      when Types::StructInstance
        type.arguments.each do |argument|
          collect_proc_type(argument, proc_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
        type.fields.each_value do |field_type|
          collect_proc_type(field_type, proc_types, visited)
        end
      when Types::GenericInstance
        type.arguments.each do |argument|
          collect_proc_type(argument, proc_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
      when Types::Function
        type.params.each do |param|
          collect_proc_type(param.type, proc_types, visited)
        end
        collect_proc_type(type.return_type, proc_types, visited)
      when Types::Struct, Types::Union
        type.fields.each_value do |field_type|
          collect_proc_type(field_type, proc_types, visited)
        end
      when Types::Variant
        type.arm_names.each do |arm_name|
          type.arm(arm_name).each_value do |field_type|
            collect_proc_type(field_type, proc_types, visited)
          end
        end
      end
    end

    def collect_task_types_from_statements(statements, task_types, visited)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_task_type(statement.type, task_types, visited)
          collect_task_types_from_expression(statement.value, task_types, visited)
        when IR::Assignment
          collect_task_types_from_expression(statement.target, task_types, visited)
          collect_task_types_from_expression(statement.value, task_types, visited)
        when IR::BlockStmt
          collect_task_types_from_statements(statement.body, task_types, visited)
        when IR::WhileStmt
          collect_task_types_from_expression(statement.condition, task_types, visited)
          collect_task_types_from_statements(statement.body, task_types, visited)
        when IR::ForStmt
          collect_task_types_from_statements([statement.init], task_types, visited)
          collect_task_types_from_expression(statement.condition, task_types, visited)
          collect_task_types_from_statements(statement.body, task_types, visited)
          collect_task_types_from_statements([statement.post], task_types, visited)
        when IR::IfStmt
          collect_task_types_from_expression(statement.condition, task_types, visited)
          collect_task_types_from_statements(statement.then_body, task_types, visited)
          collect_task_types_from_statements(statement.else_body, task_types, visited) if statement.else_body
        when IR::SwitchStmt
          collect_task_types_from_expression(statement.expression, task_types, visited)
          statement.cases.each do |switch_case|
            collect_task_types_from_statements(switch_case.body, task_types, visited)
          end
        when IR::StaticAssert
          collect_task_types_from_expression(statement.condition, task_types, visited)
          collect_task_types_from_expression(statement.message, task_types, visited)
        when IR::ReturnStmt
          collect_task_types_from_expression(statement.value, task_types, visited) if statement.value
        when IR::ExpressionStmt
          collect_task_types_from_expression(statement.expression, task_types, visited)
        end
      end
    end

    def collect_task_types_from_expression(expression, task_types, visited)
      case expression
      when IR::Member
        collect_task_types_from_expression(expression.receiver, task_types, visited)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_task_types_from_expression(expression.receiver, task_types, visited)
        collect_task_types_from_expression(expression.index, task_types, visited)
      when IR::Call
        collect_task_type(expression.type, task_types, visited)
        collect_task_types_from_expression(expression.callee, task_types, visited) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_task_types_from_expression(argument, task_types, visited) }
      when IR::Unary
        collect_task_types_from_expression(expression.operand, task_types, visited)
      when IR::Binary
        collect_task_types_from_expression(expression.left, task_types, visited)
        collect_task_types_from_expression(expression.right, task_types, visited)
      when IR::Conditional
        collect_task_types_from_expression(expression.condition, task_types, visited)
        collect_task_types_from_expression(expression.then_expression, task_types, visited)
        collect_task_types_from_expression(expression.else_expression, task_types, visited)
      when IR::ReinterpretExpr
        collect_task_type(expression.target_type, task_types, visited)
        collect_task_type(expression.source_type, task_types, visited)
        collect_task_types_from_expression(expression.expression, task_types, visited)
      when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        collect_task_type(expression.target_type, task_types, visited)
      when IR::AddressOf, IR::Cast
        collect_task_types_from_expression(expression.expression, task_types, visited)
      when IR::AggregateLiteral
        collect_task_type(expression.type, task_types, visited)
        expression.fields.each { |field| collect_task_types_from_expression(field.value, task_types, visited) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_task_types_from_expression(element, task_types, visited) }
      end
    end

    def collect_task_type(type, task_types, visited)
      return unless type
      return if visited[type]

      visited[type] = true

      case type
      when Types::Nullable
        collect_task_type(type.base, task_types, visited)
      when Types::Result
        collect_task_type(type.ok_type, task_types, visited)
        collect_task_type(type.error_type, task_types, visited)
      when Types::Task
        task_types << type
        collect_task_type(type.result_type, task_types, visited)
      when Types::Span
        collect_task_type(type.element_type, task_types, visited)
      when Types::StructInstance
        type.arguments.each do |argument|
          collect_task_type(argument, task_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
        type.fields.each_value do |field_type|
          collect_task_type(field_type, task_types, visited)
        end
      when Types::GenericInstance
        type.arguments.each do |argument|
          collect_task_type(argument, task_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
      when Types::Function
        type.params.each do |param|
          collect_task_type(param.type, task_types, visited)
        end
        collect_task_type(type.return_type, task_types, visited)
      when Types::Struct, Types::Union
        type.fields.each_value do |field_type|
          collect_task_type(field_type, task_types, visited)
        end
      when Types::Variant
        type.arm_names.each do |arm_name|
          type.arm(arm_name).each_value do |field_type|
            collect_task_type(field_type, task_types, visited)
          end
        end
      end
    end

    def collect_result_types_from_statements(statements, result_types, visited)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_result_type(statement.type, result_types, visited)
        when IR::BlockStmt
          collect_result_types_from_statements(statement.body, result_types, visited)
        when IR::WhileStmt
          collect_result_types_from_expression(statement.condition, result_types, visited)
          collect_result_types_from_statements(statement.body, result_types, visited)
        when IR::ForStmt
          collect_result_types_from_statements([statement.init], result_types, visited)
          collect_result_types_from_expression(statement.condition, result_types, visited)
          collect_result_types_from_statements(statement.body, result_types, visited)
          collect_result_types_from_statements([statement.post], result_types, visited)
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
      when Types::Variant
        type.arm_names.each do |arm_name|
          type.arm(arm_name).each_value do |field_type|
            collect_result_type(field_type, result_types, visited)
          end
        end
      end
    end

    def collect_generic_variant_types
      generic_variant_types = []
      visited = {}

      all_emitted_top_level_values.each do |value|
        collect_generic_variant_type(value.type, generic_variant_types, visited)
      end

      @program.structs.each do |struct_decl|
        struct_decl.fields.each do |field|
          collect_generic_variant_type(field.type, generic_variant_types, visited)
        end
      end

      @program.unions.each do |union_decl|
        union_decl.fields.each do |field|
          collect_generic_variant_type(field.type, generic_variant_types, visited)
        end
      end

      each_variant_arm_field_type do |field_type|
        collect_generic_variant_type(field_type, generic_variant_types, visited)
      end

      emitted_functions.each do |function|
        collect_generic_variant_type(function.return_type, generic_variant_types, visited)
        function.params.each do |param|
          collect_generic_variant_type(param.type, generic_variant_types, visited)
        end
        collect_generic_variant_types_from_statements(function.body, generic_variant_types, visited)
      end

      @program.static_asserts.each do |statement|
        collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
        collect_generic_variant_types_from_expression(statement.message, generic_variant_types, visited)
      end

      generic_variant_types
    end

    def collect_generic_variant_types_from_statements(statements, generic_variant_types, visited)
      statements.each do |statement|
        case statement
        when IR::LocalDecl
          collect_generic_variant_type(statement.type, generic_variant_types, visited)
          collect_generic_variant_types_from_expression(statement.value, generic_variant_types, visited)
        when IR::Assignment
          collect_generic_variant_types_from_expression(statement.target, generic_variant_types, visited)
          collect_generic_variant_types_from_expression(statement.value, generic_variant_types, visited)
        when IR::BlockStmt
          collect_generic_variant_types_from_statements(statement.body, generic_variant_types, visited)
        when IR::WhileStmt
          collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
          collect_generic_variant_types_from_statements(statement.body, generic_variant_types, visited)
        when IR::ForStmt
          collect_generic_variant_types_from_statements([statement.init], generic_variant_types, visited)
          collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
          collect_generic_variant_types_from_statements(statement.body, generic_variant_types, visited)
          collect_generic_variant_types_from_statements([statement.post], generic_variant_types, visited)
        when IR::IfStmt
          collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
          collect_generic_variant_types_from_statements(statement.then_body, generic_variant_types, visited)
          collect_generic_variant_types_from_statements(statement.else_body, generic_variant_types, visited) if statement.else_body
        when IR::SwitchStmt
          collect_generic_variant_types_from_expression(statement.expression, generic_variant_types, visited)
          statement.cases.each do |switch_case|
            collect_generic_variant_types_from_statements(switch_case.body, generic_variant_types, visited)
          end
        when IR::StaticAssert
          collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
          collect_generic_variant_types_from_expression(statement.message, generic_variant_types, visited)
        when IR::ReturnStmt
          collect_generic_variant_types_from_expression(statement.value, generic_variant_types, visited) if statement.value
        when IR::ExpressionStmt
          collect_generic_variant_types_from_expression(statement.expression, generic_variant_types, visited)
        end
      end
    end

    def collect_generic_variant_types_from_expression(expression, generic_variant_types, visited)
      case expression
      when IR::Member
        collect_generic_variant_types_from_expression(expression.receiver, generic_variant_types, visited)
      when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
        collect_generic_variant_types_from_expression(expression.receiver, generic_variant_types, visited)
        collect_generic_variant_types_from_expression(expression.index, generic_variant_types, visited)
      when IR::Call
        collect_generic_variant_type(expression.type, generic_variant_types, visited)
        collect_generic_variant_types_from_expression(expression.callee, generic_variant_types, visited) unless expression.callee.is_a?(String)
        expression.arguments.each { |argument| collect_generic_variant_types_from_expression(argument, generic_variant_types, visited) }
      when IR::Unary
        collect_generic_variant_types_from_expression(expression.operand, generic_variant_types, visited)
      when IR::Binary
        collect_generic_variant_types_from_expression(expression.left, generic_variant_types, visited)
        collect_generic_variant_types_from_expression(expression.right, generic_variant_types, visited)
      when IR::Conditional
        collect_generic_variant_types_from_expression(expression.condition, generic_variant_types, visited)
        collect_generic_variant_types_from_expression(expression.then_expression, generic_variant_types, visited)
        collect_generic_variant_types_from_expression(expression.else_expression, generic_variant_types, visited)
      when IR::ReinterpretExpr
        collect_generic_variant_type(expression.target_type, generic_variant_types, visited)
        collect_generic_variant_type(expression.source_type, generic_variant_types, visited)
        collect_generic_variant_types_from_expression(expression.expression, generic_variant_types, visited)
      when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
        collect_generic_variant_type(expression.target_type, generic_variant_types, visited)
      when IR::AddressOf, IR::Cast
        collect_generic_variant_types_from_expression(expression.expression, generic_variant_types, visited)
      when IR::AggregateLiteral
        collect_generic_variant_type(expression.type, generic_variant_types, visited)
        expression.fields.each { |field| collect_generic_variant_types_from_expression(field.value, generic_variant_types, visited) }
      when IR::ArrayLiteral
        expression.elements.each { |element| collect_generic_variant_types_from_expression(element, generic_variant_types, visited) }
      end
    end

    def collect_generic_variant_type(type, generic_variant_types, visited)
      return unless type
      return if visited[type]

      visited[type] = true

      case type
      when Types::Nullable
        collect_generic_variant_type(type.base, generic_variant_types, visited)
      when Types::Result
        collect_generic_variant_type(type.ok_type, generic_variant_types, visited)
        collect_generic_variant_type(type.error_type, generic_variant_types, visited)
      when Types::Task
        collect_generic_variant_type(type.result_type, generic_variant_types, visited)
      when Types::Span
        collect_generic_variant_type(type.element_type, generic_variant_types, visited)
      when Types::VariantInstance
        generic_variant_types << type
        type.arguments.each do |argument|
          collect_generic_variant_type(argument, generic_variant_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
        type.arm_names.each do |arm_name|
          type.arm(arm_name).each_value do |field_type|
            collect_generic_variant_type(field_type, generic_variant_types, visited)
          end
        end
      when Types::StructInstance
        type.arguments.each do |argument|
          collect_generic_variant_type(argument, generic_variant_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
        type.fields.each_value do |field_type|
          collect_generic_variant_type(field_type, generic_variant_types, visited)
        end
      when Types::GenericInstance
        type.arguments.each do |argument|
          collect_generic_variant_type(argument, generic_variant_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
        end
      when Types::Function, Types::Proc
        type.params.each do |param|
          collect_generic_variant_type(param.type, generic_variant_types, visited)
        end
        collect_generic_variant_type(type.return_type, generic_variant_types, visited)
      when Types::Struct, Types::Union
        type.fields.each_value do |field_type|
          collect_generic_variant_type(field_type, generic_variant_types, visited)
        end
      when Types::Variant
        type.arm_names.each do |arm_name|
          type.arm(arm_name).each_value do |field_type|
            collect_generic_variant_type(field_type, generic_variant_types, visited)
          end
        end
      end
    end

    def collect_generic_struct_types
      generic_struct_types = []
      visited = {}

      all_emitted_top_level_values.each do |value|
        collect_generic_struct_type(value.type, generic_struct_types, visited)
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

      each_variant_arm_field_type do |field_type|
        collect_generic_struct_type(field_type, generic_struct_types, visited)
      end

      emitted_functions.each do |function|
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

      all_emitted_top_level_values.each do |value|
        collect_str_builder_type(value.type, str_builder_types, visited)
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

      each_variant_arm_field_type do |field_type|
        collect_str_builder_type(field_type, str_builder_types, visited)
      end

      emitted_functions.each do |function|
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
        when IR::BlockStmt
          collect_str_builder_types_from_statements(statement.body, str_builder_types, visited)
        when IR::WhileStmt
          collect_str_builder_types_from_expression(statement.condition, str_builder_types, visited)
          collect_str_builder_types_from_statements(statement.body, str_builder_types, visited)
        when IR::ForStmt
          collect_str_builder_types_from_statements([statement.init], str_builder_types, visited)
          collect_str_builder_types_from_expression(statement.condition, str_builder_types, visited)
          collect_str_builder_types_from_statements(statement.body, str_builder_types, visited)
          collect_str_builder_types_from_statements([statement.post], str_builder_types, visited)
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
      when Types::Variant
        type.arm_names.each do |arm_name|
          type.arm(arm_name).each_value do |field_type|
            collect_str_builder_type(field_type, str_builder_types, visited)
          end
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
          collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
          collect_generic_struct_types_from_statements(statement.body, generic_struct_types, visited)
        when IR::ForStmt
          collect_generic_struct_types_from_statements([statement.init], generic_struct_types, visited)
          collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
          collect_generic_struct_types_from_statements(statement.body, generic_struct_types, visited)
          collect_generic_struct_types_from_statements([statement.post], generic_struct_types, visited)
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
      when Types::Variant
        type.arm_names.each do |arm_name|
          type.arm(arm_name).each_value do |field_type|
            collect_generic_struct_type(field_type, generic_struct_types, visited)
          end
        end
      end
    end

    def each_variant_arm_field_type
      @program.variants.each do |variant_decl|
        variant_decl.arms.each do |arm|
          arm.fields.each do |field|
            yield field.type
          end
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
      when Types::Task
        [task_type_name(type)] + struct_type_dependencies(type.result_type)
      when Types::GenericInstance
        if pointer_type?(type)
          []
        elsif array_type?(type)
          struct_type_dependencies(array_element_type(type))
        else
          []
        end
      when Types::Function
        type.params.flat_map { |param| struct_type_dependencies(param.type) } + struct_type_dependencies(type.return_type)
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
        when IR::ForStmt
          collect_span_types_from_statements([statement.init], span_types, visited)
          collect_span_types_from_expression(statement.condition, span_types, visited)
          collect_span_types_from_statements(statement.body, span_types, visited)
          collect_span_types_from_statements([statement.post], span_types, visited)
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
      when Types::Variant
        type.arm_names.each do |arm_name|
          type.arm(arm_name).each_value do |field_type|
            collect_span_type(field_type, span_types, visited)
          end
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

    def task_type_name(type)
      "mt_task_#{sanitize_identifier(type.result_type.to_s)}"
    end

    def proc_type_name(type)
      "mt_proc_#{sanitize_identifier(type.to_s)}"
    end

    def named_type_c_name(type)
      return result_type_name(type) if type.is_a?(Types::Result)
      return task_type_name(type) if type.is_a?(Types::Task)
      if type.is_a?(Types::VariantArmPayload)
        return "#{named_type_c_name(type.variant_type)}_#{type.arm_name}"
      end

      base_name = type.module_name&.start_with?("std.c.") ? type.name : type.module_name ? "#{type.module_name.tr('.', '_')}_#{type.name}" : type.name
      return base_name unless type.is_a?(Types::StructInstance) || type.is_a?(Types::VariantInstance)

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
      type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
        type.arguments[1].is_a?(Types::LiteralTypeArg)
    end

    def array_element_type(type)
      type.arguments.first
    end

    def array_length(type)
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

    def pointer_to(type)
      Types::GenericInstance.new("ptr", [type])
    end
  end
end
