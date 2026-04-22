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

      @program.structs.each do |struct_decl|
        lines.concat(emit_struct(struct_decl))
        lines << ""
      end

      @program.unions.each do |union_decl|
        lines.concat(emit_union(union_decl))
        lines << ""
      end

      @program.enums.each do |enum_decl|
        lines.concat(emit_enum(enum_decl))
        lines << ""
      end

      @program.constants.each do |constant|
        lines << "#{constant_storage(constant.type)} #{c_type(constant.type)} #{constant.c_name} = #{emit_expression(constant.value)};"
      end
      lines << "" unless @program.constants.empty?

      @program.functions.each do |function|
        lines.concat(emit_function(function))
        lines << ""
      end

      lines.join("\n").rstrip + "\n"
    end

    private

    def emit_struct(struct_decl)
      lines = []
      lines << "typedef struct #{struct_decl.c_name} {"
      struct_decl.fields.each do |field|
        lines << "#{INDENT}#{c_type(field.type)} #{field.name};"
      end
      lines << "} #{struct_decl.c_name};"
      lines
    end

    def emit_union(union_decl)
      lines = []
      lines << "typedef union #{union_decl.c_name} {"
      union_decl.fields.each do |field|
        lines << "#{INDENT}#{c_type(field.type)} #{field.name};"
      end
      lines << "} #{union_decl.c_name};"
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
                 function.params.map { |param| "#{c_type(param.type, pointer: param.pointer)} #{param.c_name}" }.join(", ")
               end

      prefix = function.entry_point ? "" : "static "
      lines = ["#{prefix}#{c_type(function.return_type)} #{function.c_name}(#{params}) {"]
      if function.body.empty?
        lines << "#{INDENT}(void)0;"
      else
        function.body.each do |statement|
          lines.concat(emit_statement(statement, 1))
        end
      end
      lines << "}"
      lines
    end

    def emit_statement(statement, level)
      indent = INDENT * level

      case statement
      when IR::LocalDecl
        ["#{indent}#{c_type(statement.type)} #{statement.c_name} = #{emit_expression(statement.value)};"]
      when IR::Assignment
        ["#{indent}#{emit_expression(statement.target)} #{statement.operator} #{emit_expression(statement.value)};"]
      when IR::ExpressionStmt
        ["#{indent}#{emit_expression(statement.expression)};"]
      when IR::ReturnStmt
        if statement.value
          ["#{indent}return #{emit_expression(statement.value)};"]
        else
          ["#{indent}return;"]
        end
      when IR::WhileStmt
        lines = ["#{indent}while (#{emit_expression(statement.condition)}) {"]
        statement.body.each do |inner|
          lines.concat(emit_statement(inner, level + 1))
        end
        lines << "#{indent}}"
        lines
      when IR::IfStmt
        lines = ["#{indent}if (#{emit_expression(statement.condition)}) {"]
        statement.then_body.each do |inner|
          lines.concat(emit_statement(inner, level + 1))
        end
        if statement.else_body && !statement.else_body.empty?
          lines << "#{indent}} else {"
          statement.else_body.each do |inner|
            lines.concat(emit_statement(inner, level + 1))
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
      when IR::Call
        "#{expression.callee}(#{expression.arguments.map { |argument| emit_expression(argument) }.join(', ')})"
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
      else
        raise LoweringError, "unsupported IR expression #{expression.class.name}"
      end
    end

    def emit_aggregate_literal(expression)
      fields = expression.fields.map do |field|
        ".#{field.name} = #{emit_expression(field.value)}"
      end.join(", ")
      "(#{c_type(expression.type)}){ #{fields} }"
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
      when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::Member, IR::Call, IR::AggregateLiteral
        emit_expression(expression)
      else
        "(#{emit_expression(expression)})"
      end
    end

    def wrap_member_receiver(expression)
      case expression
      when IR::Name, IR::Member
        emit_expression(expression)
      else
        "(#{emit_expression(expression)})"
      end
    end

    def c_operator(operator)
      operator == "and" ? "&&" : operator == "or" ? "||" : operator
    end

    def c_type(type, pointer: false)
      case type
      when Types::Nullable
        "#{c_type(type.base)}*"
      when Types::Primitive
        base = primitive_c_type(type.name)
        pointer ? "#{base}*" : base
      when Types::Struct, Types::Union, Types::Enum, Types::Flags
        base = type.module_name&.start_with?("std.c.") ? type.name : type.module_name ? type.module_name.tr('.', '_') + "_" + type.name : type.name
        pointer ? "#{base}*" : base
      when Types::Opaque
        "#{type.name}*"
      else
        raise LoweringError, "unsupported C type #{type.class.name}"
      end
    end

    def constant_storage(type)
      c_type(type).start_with?("const ") ? "static" : "static const"
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
  end
end
