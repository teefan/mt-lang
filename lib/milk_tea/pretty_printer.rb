# frozen_string_literal: true

module MilkTea
  module PrettyPrinter
    def self.format_ast(node)
      ASTFormatter.new.format(node)
    end

    def self.format_ir(node)
      IRFormatter.new.format(node)
    end

    class BaseFormatter
      INDENT = "    "

      def initialize
        @lines = []
        @indent = 0
      end

      private

      def finish
        @lines.join("\n") + "\n"
      end

      def line(text = "")
        content = "#{INDENT * @indent}#{text}"
        @lines << content.rstrip
      end

      def blank_line
        @lines << "" unless @lines.empty? || @lines.last.empty?
      end

      def with_indent
        @indent += 1
        yield
      ensure
        @indent -= 1
      end

      def binding_name(name, c_name)
        return c_name if name.nil? || name.empty? || name == c_name

        "#{name} as #{c_name}"
      end

      def precedence(operator)
        case operator
        when "or"
          10
        when "and"
          20
        when "==", "!=", "<", "<=", ">", ">="
          30
        when "|"
          40
        when "^"
          45
        when "&"
          50
        when "<<", ">>"
          55
        when "+", "-"
          60
        when "*", "/", "%"
          70
        else
          0
        end
      end

      def wrap(text, parent_precedence, current_precedence)
        return text if current_precedence >= parent_precedence

        "(#{text})"
      end
    end

    class ASTFormatter < BaseFormatter
      POSTFIX_PRECEDENCE = 90
      UNARY_PRECEDENCE = 80

      def format(node)
        emit_source_file(node)
        finish
      end

      private

      def emit_source_file(source_file)
        module_name = source_file.module_name ? source_file.module_name.to_s : "(anonymous)"
        header = source_file.module_kind == :extern_module ? "extern module #{module_name}:" : "module #{module_name}"
        line(header)

        if source_file.module_kind == :extern_module
          with_indent { emit_module_body(source_file) }
        else
          blank_line unless source_file.imports.empty? && source_file.directives.empty? && source_file.declarations.empty?
          emit_module_body(source_file)
        end
      end

      def emit_module_body(source_file)
        wrote_section = false

        unless source_file.imports.empty?
          source_file.imports.each { |import| line(render_import(import)) }
          wrote_section = true
        end

        unless source_file.directives.empty?
          blank_line if wrote_section
          source_file.directives.each { |directive| line(render_directive(directive)) }
          wrote_section = true
        end

        return if source_file.declarations.empty?

        blank_line if wrote_section
        source_file.declarations.each_with_index do |declaration, index|
          emit_declaration(declaration)
          blank_line if index < (source_file.declarations.length - 1)
        end
      end

      def emit_declaration(declaration)
        case declaration
        when AST::ConstDecl
          header = "const #{declaration.name}"
          header += ": #{render_type(declaration.type)}" if declaration.type
          line("#{header} = #{render_expression(declaration.value)}")
        when AST::TypeAliasDecl
          line("type #{declaration.name} = #{render_type(declaration.target)}")
        when AST::StructDecl
          prefixes = []
          prefixes << "packed" if declaration.packed
          prefixes << "align(#{declaration.alignment})" if declaration.alignment
          header = +""
          header << "#{prefixes.join(' ')} " unless prefixes.empty?
          header << "struct #{declaration.name}#{render_type_params(declaration.type_params)}:"
          line(header)
          with_indent do
            declaration.fields.each do |field|
              line("#{field.name}: #{render_type(field.type)}")
            end
          end
        when AST::UnionDecl
          line("union #{declaration.name}:")
          with_indent do
            declaration.fields.each do |field|
              line("#{field.name}: #{render_type(field.type)}")
            end
          end
        when AST::EnumDecl
          emit_enum_like("enum", declaration.name, declaration.backing_type, declaration.members)
        when AST::FlagsDecl
          emit_enum_like("flags", declaration.name, declaration.backing_type, declaration.members)
        when AST::OpaqueDecl
          line("opaque #{declaration.name}")
        when AST::MethodsBlock
          line("methods #{declaration.type_name}:")
          with_indent do
            declaration.methods.each_with_index do |method, index|
              emit_function(method)
              blank_line if index < (declaration.methods.length - 1)
            end
          end
        when AST::FunctionDef
          emit_function(declaration)
        when AST::ExternFunctionDecl
          line("#{render_function_signature(declaration, prefix: 'extern ')}")
        else
          raise ArgumentError, "unsupported AST declaration #{declaration.class.name}"
        end
      end

      def emit_enum_like(kind, name, backing_type, members)
        header = "#{kind} #{name}"
        header += ": #{render_type(backing_type)}" if backing_type
        line(header)
        with_indent do
          members.each do |member|
            text = member.name
            text += " = #{render_expression(member.value)}" if member.value
            line(text)
          end
        end
      end

      def emit_function(function)
        line("#{render_function_signature(function)}:")
        with_indent do
          function.body.each do |statement|
            emit_statement(statement)
          end
        end
      end

      def render_function_signature(function, prefix: "")
        signature_prefix = if function.is_a?(AST::MethodDef)
                             case function.kind
                             when :edit
                               "edit def "
                             when :static
                               "static def "
                             else
                               "def "
                             end
                           else
                             "def "
                           end
        text = +"#{prefix}#{signature_prefix}#{function.name}#{render_type_params(function.type_params)}(#{render_signature_params(function)})"
        text << " -> #{render_type(function.return_type)}" if function.return_type
        text
      end

      def render_signature_params(function)
        params = function.params.map { |param| render_param(param) }
        params << "..." if function.respond_to?(:variadic) && function.variadic
        params.join(', ')
      end

      def render_type_params(type_params)
        return "" if type_params.empty?

        "[#{type_params.map(&:name).join(', ')}]"
      end

      def render_import(import)
        text = "import #{import.path}"
        text += " as #{import.alias_name}" if import.alias_name
        text
      end

      def render_directive(directive)
        case directive
        when AST::LinkDirective
          "link #{directive.value.inspect}"
        when AST::IncludeDirective
          "include #{directive.value.inspect}"
        else
          raise ArgumentError, "unsupported AST directive #{directive.class.name}"
        end
      end

      def emit_statement(statement)
        case statement
        when AST::LocalDecl
          text = "#{statement.kind} #{statement.name}"
          text += ": #{render_type(statement.type)}" if statement.type
          text += " = #{render_expression(statement.value)}" if statement.value
          line(text)
        when AST::Assignment
          line("#{render_expression(statement.target)} #{statement.operator} #{render_expression(statement.value)}")
        when AST::IfStmt
          emit_if(statement)
        when AST::MatchStmt
          line("match #{render_expression(statement.expression)}:")
          with_indent do
            statement.arms.each do |arm|
              line("#{render_expression(arm.pattern)}:")
              with_indent do
                arm.body.each { |nested| emit_statement(nested) }
              end
            end
          end
        when AST::UnsafeStmt
          line("unsafe:")
          with_indent do
            statement.body.each { |nested| emit_statement(nested) }
          end
        when AST::StaticAssert
          line("static_assert(#{render_expression(statement.condition)}, #{render_expression(statement.message)})")
        when AST::ForStmt
          line("for #{statement.name} in #{render_expression(statement.iterable)}:")
          with_indent do
            statement.body.each { |nested| emit_statement(nested) }
          end
        when AST::WhileStmt
          line("while #{render_expression(statement.condition)}:")
          with_indent do
            statement.body.each { |nested| emit_statement(nested) }
          end
        when AST::BreakStmt
          line("break")
        when AST::ContinueStmt
          line("continue")
        when AST::ReturnStmt
          line(statement.value ? "return #{render_expression(statement.value)}" : "return")
        when AST::DeferStmt
          line("defer #{render_expression(statement.expression)}")
        when AST::ExpressionStmt
          line(render_expression(statement.expression))
        else
          raise ArgumentError, "unsupported AST statement #{statement.class.name}"
        end
      end

      def emit_if(statement)
        first_branch, *rest = statement.branches
        line("if #{render_expression(first_branch.condition)}:")
        with_indent do
          first_branch.body.each { |nested| emit_statement(nested) }
        end

        rest.each do |branch|
          line("elif #{render_expression(branch.condition)}:")
          with_indent do
            branch.body.each { |nested| emit_statement(nested) }
          end
        end

        else_body = statement.else_body || []
        return if else_body.empty?

        line("else:")
        with_indent do
          else_body.each { |nested| emit_statement(nested) }
        end
      end

      def render_param(param)
        prefix = param.mutable ? "mut " : ""
        return "#{prefix}#{param.name}" unless param.type

        "#{prefix}#{param.name}: #{render_type(param.type)}"
      end

      def render_type(type)
        case type
        when AST::TypeRef
          text = type.name.to_s
          unless type.arguments.empty?
            text += "[#{type.arguments.map { |argument| render_type_argument(argument.value) }.join(', ')}]"
          end
          type.nullable ? "#{text}?" : text
        when AST::FunctionType
          "fn(#{type.params.map { |param| render_param(param) }.join(', ')}) -> #{render_type(type.return_type)}"
        else
          type.to_s
        end
      end

      def render_type_argument(argument)
        case argument
        when AST::IntegerLiteral, AST::FloatLiteral
          argument.lexeme
        else
          render_type(argument)
        end
      end

      def render_expression(expression, parent_precedence = 0)
        case expression
        when AST::Identifier
          expression.name
        when AST::MemberAccess
          wrap("#{render_postfix(expression.receiver)}.#{expression.member}", parent_precedence, POSTFIX_PRECEDENCE)
        when AST::PointerMemberAccess
          wrap("#{render_postfix(expression.receiver)}->#{expression.member}", parent_precedence, POSTFIX_PRECEDENCE)
        when AST::IndexAccess
          wrap("#{render_postfix(expression.receiver)}[#{render_expression(expression.index)}]", parent_precedence, POSTFIX_PRECEDENCE)
        when AST::Specialization
          wrap("#{render_postfix(expression.callee)}[#{expression.arguments.map { |argument| render_type_argument(argument.value) }.join(', ')}]", parent_precedence, POSTFIX_PRECEDENCE)
        when AST::Call
          wrap("#{render_postfix(expression.callee)}(#{expression.arguments.map { |argument| render_argument(argument) }.join(', ')})", parent_precedence, POSTFIX_PRECEDENCE)
        when AST::UnaryOp
          operand = render_expression(expression.operand, UNARY_PRECEDENCE)
          text = expression.operator == "not" ? "not #{operand}" : "#{expression.operator}#{operand}"
          wrap(text, parent_precedence, UNARY_PRECEDENCE)
        when AST::BinaryOp
          current_precedence = precedence(expression.operator)
          left = render_expression(expression.left, current_precedence)
          right = render_expression(expression.right, current_precedence + 1)
          wrap("#{left} #{expression.operator} #{right}", parent_precedence, current_precedence)
        when AST::SizeofExpr
          "sizeof(#{render_type(expression.type)})"
        when AST::AlignofExpr
          "alignof(#{render_type(expression.type)})"
        when AST::OffsetofExpr
          "offsetof(#{render_type(expression.type)}, #{expression.field})"
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral
          expression.lexeme
        when AST::BooleanLiteral
          expression.value ? "true" : "false"
        when AST::NullLiteral
          "null"
        else
          raise ArgumentError, "unsupported AST expression #{expression.class.name}"
        end
      end

      def render_argument(argument)
        return render_expression(argument.value) unless argument.name

        "#{argument.name} = #{render_expression(argument.value)}"
      end

      def render_postfix(expression)
        return render_expression(expression, POSTFIX_PRECEDENCE) if postfix_expression?(expression)

        "(#{render_expression(expression)})"
      end

      def postfix_expression?(expression)
        expression.is_a?(AST::Identifier) || expression.is_a?(AST::MemberAccess) || expression.is_a?(AST::PointerMemberAccess) || expression.is_a?(AST::IndexAccess) ||
          expression.is_a?(AST::Specialization) || expression.is_a?(AST::Call)
      end
    end

    class IRFormatter < BaseFormatter
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
        line("const #{binding_name(constant.name, constant.c_name)}: #{constant.type} = #{render_expression(constant.value)}")
      end

      def emit_struct(struct_decl)
        header = "struct #{binding_name(struct_decl.name, struct_decl.c_name)}"
        modifiers = []
        modifiers << "packed" if struct_decl.packed
        modifiers << "align(#{struct_decl.alignment})" if struct_decl.alignment
        header += " [#{modifiers.join(', ')}]" unless modifiers.empty?
        header += ":"
        line(header)
        with_indent do
          struct_decl.fields.each do |field|
            line("#{field.name}: #{field.type}")
          end
        end
      end

      def emit_union(union_decl)
        line("union #{binding_name(union_decl.name, union_decl.c_name)}:")
        with_indent do
          union_decl.fields.each do |field|
            line("#{field.name}: #{field.type}")
          end
        end
      end

      def emit_enum(enum_decl)
        kind = enum_decl.flags ? "flags" : "enum"
        line("#{kind} #{binding_name(enum_decl.name, enum_decl.c_name)}: #{enum_decl.backing_type}")
        with_indent do
          enum_decl.members.each do |member|
            line("#{binding_name(member.name, member.c_name)} = #{render_expression(member.value)}")
          end
        end
      end

      def emit_static_assert(static_assert)
        line("static_assert(#{render_expression(static_assert.condition)}, #{render_expression(static_assert.message)})")
      end

      def emit_function(function)
        header = "fn #{binding_name(function.name || function.c_name, function.c_name)}(#{function.params.map { |param| render_param(param) }.join(', ')}) -> #{function.return_type}"
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
        "#{binding_name(param.name, param.c_name)}: #{type}"
      end

      def emit_statement(statement)
        case statement
        when IR::LocalDecl
          line("let #{binding_name(statement.name, statement.c_name)}: #{statement.type} = #{render_expression(statement.value)}")
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
          unless statement.else_body.empty?
            line("else:")
            with_indent do
              statement.else_body.each { |nested| emit_statement(nested) }
            end
          end
        when IR::SwitchStmt
          line("switch #{render_expression(statement.expression)}:")
          with_indent do
            statement.cases.each do |switch_case|
              line("case #{render_expression(switch_case.value)}:")
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
        when IR::ReinterpretExpr
          "reinterpret[#{expression.target_type} <- #{expression.source_type}](#{render_expression(expression.expression)})"
        when IR::SizeofExpr
          "sizeof(#{expression.target_type})"
        when IR::AlignofExpr
          "alignof(#{expression.target_type})"
        when IR::OffsetofExpr
          "offsetof(#{expression.target_type}, #{expression.field})"
        when IR::IntegerLiteral, IR::FloatLiteral
          expression.value.to_s
        when IR::StringLiteral
          expression.cstring ? "c#{expression.value.inspect}" : expression.value.inspect
        when IR::BooleanLiteral
          expression.value ? "true" : "false"
        when IR::NullLiteral
          "null"
        when IR::AddressOf
          wrap("&#{render_expression(expression.expression, UNARY_PRECEDENCE)}", parent_precedence, UNARY_PRECEDENCE)
        when IR::Cast
          "cast[#{expression.target_type}](#{render_expression(expression.expression)})"
        when IR::AggregateLiteral
          "#{expression.type}(#{expression.fields.map { |field| "#{field.name} = #{render_expression(field.value)}" }.join(', ')})"
        when IR::ArrayLiteral
          "#{expression.type}(#{expression.elements.map { |element| render_expression(element) }.join(', ')})"
        else
          raise ArgumentError, "unsupported IR expression #{expression.class.name}"
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
