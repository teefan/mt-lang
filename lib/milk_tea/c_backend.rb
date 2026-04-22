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
      @program.includes.each do |include_node|
        lines << "#include #{include_node.header}"
      end
      lines << ""

      struct_decls = sort_struct_decls(@program.structs + collect_generic_struct_decls + collect_result_decls)

      forward_declarations = emit_forward_declarations(struct_decls)
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

      @program.constants.each do |constant|
        lines << "#{constant_storage(constant.type)} #{c_declaration(constant.type, constant.c_name)} = #{emit_initializer(constant.value)};"
      end
      lines << "" unless @program.constants.empty?

      @program.functions.each do |function|
        lines.concat(emit_function(function))
        lines << ""
      end

      lines.join("\n").rstrip + "\n"
    end

    private

    def emit_forward_declarations(struct_decls)
      lines = []
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
      lines << "};"
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

    def emit_function(function)
      params = if function.params.empty?
                 "void"
               else
                 function.params.map { |param| c_declaration(param.pointer ? pointer_to(param.type) : param.type, param.c_name) }.join(", ")
               end

      prefix = function.entry_point ? "" : "static "
      lines = ["#{prefix}#{c_function_return_type(function.return_type)} #{function.c_name}(#{params}) {"]
      if function.body.empty?
        lines << "#{INDENT}(void)0;"
      else
        function.body.each do |statement|
          lines.concat(emit_statement(statement, 1, function:))
        end
      end
      lines << "}"
      lines
    end

    def emit_statement(statement, level, function:)
      indent = INDENT * level

      case statement
      when IR::LocalDecl
        if array_type?(statement.type) && !statement.value.is_a?(IR::ArrayLiteral)
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
        lines = ["#{indent}{"]
        statement.body.each do |inner|
          lines.concat(emit_statement(inner, level + 1, function:))
        end
        lines << "#{indent}}"
        lines
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
          lines.concat(emit_statement(inner, level + 1, function:))
        end
        lines << "#{indent}}"
        lines
      when IR::IfStmt
        lines = ["#{indent}if (#{emit_expression(statement.condition)}) {"]
        statement.then_body.each do |inner|
          lines.concat(emit_statement(inner, level + 1, function:))
        end
        if statement.else_body && !statement.else_body.empty?
          lines << "#{indent}} else {"
          statement.else_body.each do |inner|
            lines.concat(emit_statement(inner, level + 1, function:))
          end
        end
        lines << "#{indent}}"
        lines
      else
        raise LoweringError, "unsupported IR statement #{statement.class.name}"
      end
    end

    def emit_expression(expression)
      case expression
      when IR::Name
        expression.name
      when IR::Member
        operator = expression.receiver.is_a?(IR::Name) && expression.receiver.pointer ? "->" : "."
        "#{wrap_member_receiver(expression.receiver)}#{operator}#{expression.member}"
      when IR::Index
        "#{wrap_index_receiver(expression.receiver)}[#{emit_expression(expression.index)}]"
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
      when IR::IntegerLiteral
        expression.value.to_s
      when IR::FloatLiteral
        emit_float_literal(expression)
      when IR::StringLiteral
        expression.value.inspect
      when IR::BooleanLiteral
        expression.value ? "true" : "false"
      when IR::NullLiteral
        "NULL"
      when IR::AddressOf
        "&#{wrap_expression(expression.expression)}"
      when IR::Cast
        "((#{c_type(expression.target_type)}) #{wrap_expression(expression.expression)})"
      when IR::AggregateLiteral
        emit_aggregate_literal(expression)
      when IR::ArrayLiteral
        emit_array_compound_literal(expression)
      else
        raise LoweringError, "unsupported IR expression #{expression.class.name}"
      end
    end

    def emit_initializer(expression)
      expression.is_a?(IR::ArrayLiteral) ? emit_array_initializer(expression) : emit_expression(expression)
    end

    def emit_aggregate_literal(expression)
      fields = expression.fields.map do |field|
        ".#{field.name} = #{emit_initializer(field.value)}"
      end.join(", ")
      "(#{c_type(expression.type)}){ #{fields} }"
    end

    def emit_array_initializer(expression)
      elements = expression.elements.map { |element| emit_initializer(element) }.join(", ")
      "{ #{elements} }"
    end

    def emit_array_compound_literal(expression)
      "(#{c_declaration(expression.type, '')}) #{emit_array_initializer(expression)}"
    end

    def emit_call_expression(expression)
      "#{expression.callee}(#{expression.arguments.map { |argument| emit_expression(argument) }.join(', ')})"
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
      when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::Member, IR::Index, IR::Call, IR::AggregateLiteral, IR::ArrayLiteral
        emit_expression(expression)
      else
        "(#{emit_expression(expression)})"
      end
    end

    def wrap_member_receiver(expression)
      case expression
      when IR::Name, IR::Member, IR::Index
        emit_expression(expression)
      else
        "(#{emit_expression(expression)})"
      end
    end

    def wrap_index_receiver(expression)
      case expression
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

    def c_function_return_type(type)
      array_type?(type) ? array_return_wrapper_type_name(type) : c_type(type)
    end

    def c_declaration_parts(type, name)
      name = name.to_s

      if array_type?(type)
        declarator = declarator_needs_grouping?(name) ? "(#{name})" : name
        return c_declaration_parts(array_element_type(type), "#{declarator}[#{array_length(type)}]")
      end

      if pointer_type?(type)
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
        "#{type.name}*"
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

    def collect_span_types
      span_types = []
      visited = {}

      @program.constants.each do |constant|
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

      span_types.uniq
    end

    def collect_generic_struct_decls
      collect_generic_struct_types.map do |type|
        IR::StructDecl.new(
          name: type.to_s,
          c_name: named_type_c_name(type),
          fields: type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
        )
      end
    end

    def collect_result_decls
      collect_result_types.map do |type|
        IR::StructDecl.new(
          name: type.to_s,
          c_name: result_type_name(type),
          fields: type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
        )
      end
    end

    def collect_result_types
      result_types = []
      visited = {}

      @program.constants.each do |constant|
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
        end
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

      @program.constants.each do |constant|
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

      generic_struct_types
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
        end
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
        when IR::BlockStmt
          collect_span_types_from_statements(statement.body, span_types, visited)
        when IR::WhileStmt
          collect_span_types_from_statements(statement.body, span_types, visited)
        when IR::IfStmt
          collect_span_types_from_statements(statement.then_body, span_types, visited)
          collect_span_types_from_statements(statement.else_body, span_types, visited) if statement.else_body
        end
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
        "str" => "const char*",
        "cstr" => "const char*",
      }.fetch(name)
    end

    def generic_c_type(type)
      case type.name
      when "ptr"
        raise LoweringError, "ptr requires exactly one type argument" unless type.arguments.length == 1

        "#{c_type(type.arguments.first)}*"
      else
        raise LoweringError, "unsupported generic C type #{type.name}"
      end
    end

    def pointer_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
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

    def pointer_to(type)
      Types::GenericInstance.new("ptr", [type])
    end
  end
end
