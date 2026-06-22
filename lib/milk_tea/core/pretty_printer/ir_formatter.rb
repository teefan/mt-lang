# frozen_string_literal: true

module MilkTea
  module PrettyPrinter
    class IRFormatter < BaseFormatter
      IF_EXPRESSION_PRECEDENCE = 5
      POSTFIX_PRECEDENCE = 90
      UNARY_PRECEDENCE = 80

      def format(node)
        emit_program(node)
        finish
      end

      private

      def emit_program(program)
        module_name = program.module_name || "(anonymous)"
        line("program #{module_name}")
        emit_section("includes", program.includes) { |include_directive| line("include #{include_directive.header}") }
        emit_section("constants", program.constants) { |constant| emit_constant(constant) }
        emit_section("structs", program.structs) { |struct_decl| emit_struct(struct_decl) }
        emit_section("unions", program.unions) { |union_decl| emit_union(union_decl) }
        emit_section("enums", program.enums) { |enum_decl| emit_enum(enum_decl) }
        emit_section("static_asserts", program.static_asserts) { |static_assert| emit_static_assert(static_assert) }
        emit_section("functions", program.functions) { |function| emit_function(function) }
      end

      def emit_section(title, items)
        return if items.empty?

        blank_line
        line("#{title}:")
        with_indent do
          items.each_with_index do |item, index|
            yield(item)
            blank_line if index < (items.length - 1)
          end
        end
      end

      def emit_constant(constant)
        line("const #{binding_name(constant.name, constant.linkage_name)}: #{constant.type} = #{render_expression(constant.value)}")
      end

      def emit_struct(struct_decl)
        header = "struct #{binding_name(struct_decl.name, struct_decl.linkage_name)}"
        params = []
        if struct_decl.respond_to?(:lifetime_params) && struct_decl.lifetime_params&.any?
          params.push(*struct_decl.lifetime_params)
        end
        modifiers = []
        modifiers << "packed" if struct_decl.respond_to?(:packed) && struct_decl.packed
        modifiers << "align(#{struct_decl.alignment})" if struct_decl.respond_to?(:alignment) && struct_decl.alignment
        params.concat(modifiers) unless modifiers.empty?
        header += " [#{params.join(', ')}]" unless params.empty?
        header += ":"
        line(header)
        with_indent do
          struct_decl.fields.each do |field|
            line("#{field.name}: #{field.type}")
          end
        end
      end

      def emit_union(union_decl)
        line("union #{binding_name(union_decl.name, union_decl.linkage_name)}:")
        with_indent do
          union_decl.fields.each do |field|
            line("#{field.name}: #{field.type}")
          end
        end
      end

      def emit_enum(enum_decl)
        kind = enum_decl.flags ? "flags" : "enum"
        line("#{kind} #{binding_name(enum_decl.name, enum_decl.linkage_name)}: #{enum_decl.backing_type}")
        with_indent do
          enum_decl.members.each do |member|
            line("#{binding_name(member.name, member.linkage_name)} = #{render_expression(member.value)}")
          end
        end
      end

      def emit_static_assert(static_assert)
        line("static_assert(#{render_expression(static_assert.condition)}, #{render_expression(static_assert.message)})")
      end

      def emit_function(function)
        header = "fn #{binding_name(function.name || function.linkage_name, function.linkage_name)}(#{function.params.map { |param| render_param(param) }.join(', ')}) -> #{function.return_type}"
        header += " [entry]" if function.entry_point
        header += ":"
        line(header)
        with_indent do
          function.body.each do |statement|
            emit_statement(statement)
          end
        end
      end

      def render_param(param)
        type = param.pointer ? "ptr[#{param.type}]" : param.type.to_s
        "#{binding_name(param.name, param.linkage_name)}: #{type}"
      end

      def emit_statement(statement)
        case statement
        when IR::LocalDecl
          line("let #{binding_name(statement.name, statement.linkage_name)}: #{statement.type} = #{render_expression(statement.value)}")
        when IR::Assignment
          line("#{render_expression(statement.target)} #{statement.operator} #{render_expression(statement.value)}")
        when IR::BlockStmt
          line("block:")
          with_indent do
            statement.body.each { |nested| emit_statement(nested) }
          end
        when IR::IfStmt
          line("if #{render_expression(statement.condition)}:")
          with_indent do
            statement.then_body.each { |nested| emit_statement(nested) }
          end
          if statement.else_body && !statement.else_body.empty?
            line("else:")
            with_indent do
              statement.else_body.each { |nested| emit_statement(nested) }
            end
          end
        when IR::SwitchStmt
          line("switch #{render_expression(statement.expression)}:")
          with_indent do
            statement.cases.each do |switch_case|
              if switch_case.is_a?(IR::SwitchDefaultCase)
                line("default:")
              else
                line("case #{render_expression(switch_case.value)}:")
              end
              with_indent do
                switch_case.body.each { |nested| emit_statement(nested) }
              end
            end
          end
        when IR::WhileStmt
          line("while #{render_expression(statement.condition)}:")
          with_indent do
            statement.body.each { |nested| emit_statement(nested) }
          end
        when IR::ForStmt
          init = render_for_clause_statement(statement.init)
          post = render_for_clause_statement(statement.post)
          line("for #{init}; #{render_expression(statement.condition)}; #{post}:")
          with_indent do
            statement.body.each { |nested| emit_statement(nested) }
          end
        when IR::BreakStmt
          line("break")
        when IR::ContinueStmt
          line("continue")
        when IR::GotoStmt
          line("goto #{statement.label}")
        when IR::LabelStmt
          line("label #{statement.name}")
        when IR::StaticAssert
          emit_static_assert(statement)
        when IR::ReturnStmt
          line(statement.value ? "return #{render_expression(statement.value)}" : "return")
        when IR::ExpressionStmt
          line(render_expression(statement.expression))
        else
          raise ArgumentError, "unsupported IR statement #{statement.class.name}"
        end
      end

      def render_expression(expression, parent_precedence = 0)
        case expression
        when IR::Name
          expression.name
        when IR::Member
          operator = pointer_receiver_expression?(expression.receiver) ? "->" : "."
          wrap("#{render_postfix(expression.receiver)}#{operator}#{expression.member}", parent_precedence, POSTFIX_PRECEDENCE)
        when IR::Index
          wrap("#{render_postfix(expression.receiver)}[#{render_expression(expression.index)}]", parent_precedence, POSTFIX_PRECEDENCE)
        when IR::CheckedIndex
          "checked_index<#{expression.receiver_type}>(#{render_expression(expression.receiver)}, #{render_expression(expression.index)})"
        when IR::CheckedSpanIndex
          "checked_span_index<#{expression.receiver_type}>(#{render_expression(expression.receiver)}, #{render_expression(expression.index)})"
        when IR::NullableIndex
          "nullable_index<#{expression.receiver_type}>(#{render_expression(expression.receiver)}, #{render_expression(expression.index)})"
        when IR::NullableSpanIndex
          "nullable_span_index<#{expression.receiver_type}>(#{render_expression(expression.receiver)}, #{render_expression(expression.index)})"
        when IR::Call
          wrap("#{expression.callee}(#{expression.arguments.map { |argument| render_expression(argument) }.join(', ')})", parent_precedence, POSTFIX_PRECEDENCE)
        when IR::Unary
          operand = render_expression(expression.operand, UNARY_PRECEDENCE)
          text = expression.operator == "not" ? "not #{operand}" : "#{expression.operator}#{operand}"
          wrap(text, parent_precedence, UNARY_PRECEDENCE)
        when IR::Binary
          current_precedence = precedence(expression.operator)
          left = render_expression(expression.left, current_precedence)
          right = render_expression(expression.right, current_precedence + 1)
          wrap("#{left} #{expression.operator} #{right}", parent_precedence, current_precedence)
        when IR::Conditional
          condition = render_expression(expression.condition, IF_EXPRESSION_PRECEDENCE)
          then_expression = render_expression(expression.then_expression, IF_EXPRESSION_PRECEDENCE)
          else_expression = render_expression(expression.else_expression, IF_EXPRESSION_PRECEDENCE)
          wrap("if #{condition}: #{then_expression} else: #{else_expression}", parent_precedence, IF_EXPRESSION_PRECEDENCE)
        when IR::ReinterpretExpr
          "reinterpret[#{expression.target_type} <- #{expression.source_type}](#{render_expression(expression.expression)})"
        when IR::SizeofExpr
          "size_of(#{expression.target_type})"
        when IR::AlignofExpr
          "align_of(#{expression.target_type})"
        when IR::OffsetofExpr
          "offset_of(#{expression.target_type}, #{expression.field})"
        when IR::IntegerLiteral, IR::FloatLiteral
          expression.value.to_s
        when IR::StringLiteral
          expression.cstring ? "c#{expression.value.inspect}" : expression.value.inspect
        when IR::BooleanLiteral
          expression.value ? "true" : "false"
        when IR::NullLiteral
          "null"
        when IR::ZeroInit
          "zero[#{expression.type}]"
        when IR::AddressOf
          wrap("&#{render_expression(expression.expression, UNARY_PRECEDENCE)}", parent_precedence, UNARY_PRECEDENCE)
        when IR::Cast
          "#{expression.target_type}<-#{render_expression(expression.expression)}"
        when IR::AggregateLiteral
          "#{expression.type}(#{expression.fields.map { |field| "#{field.name} = #{render_expression(field.value)}" }.join(', ')})"
        when IR::VariantLiteral
          if expression.fields.empty?
            "#{expression.type}.#{expression.arm_name}"
          else
            "#{expression.type}.#{expression.arm_name}(#{expression.fields.map { |field| "#{field.name} = #{render_expression(field.value)}" }.join(', ')})"
          end
        when IR::ArrayLiteral
          "#{expression.type}(#{expression.elements.map { |element| render_expression(element) }.join(', ')})"
        else
          raise ArgumentError, "unsupported IR expression #{expression.class.name}"
        end
      end

      def render_for_clause_statement(statement)
        case statement
        when IR::LocalDecl
          "#{statement.linkage_name}: #{statement.type} = #{render_expression(statement.value)}"
        when IR::Assignment
          "#{render_expression(statement.target)} #{statement.operator} #{render_expression(statement.value)}"
        when IR::ExpressionStmt
          render_expression(statement.expression)
        else
          raise ArgumentError, "unsupported for clause #{statement.class.name}"
        end
      end

      def render_postfix(expression)
        return render_expression(expression, POSTFIX_PRECEDENCE) if postfix_expression?(expression)

        "(#{render_expression(expression)})"
      end

      def postfix_expression?(expression)
        expression.is_a?(IR::Name) || expression.is_a?(IR::Member) || expression.is_a?(IR::Index) || expression.is_a?(IR::Call)
      end

      def pointer_receiver_expression?(expression)
        (expression.is_a?(IR::Name) && expression.pointer) || (expression.respond_to?(:type) && pointer_type?(expression.type))
      end

      def pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
      end
    end
  end
end
