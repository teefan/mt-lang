# frozen_string_literal: true

module MilkTea
  module PrettyPrinter
    class ASTFormatter < BaseFormatter
      IF_EXPRESSION_PRECEDENCE = 5
      POSTFIX_PRECEDENCE = 90
      UNARY_PRECEDENCE = 80
      IS_PRECEDENCE = 25

      def format(node, trivia: [])
        @comment_map = build_comment_map(trivia)
        emit_source_file(node)
        finish
      end

      private

      def build_comment_map(trivia)
        @blank_line_set = {}
        map = {}
        trivia.each do |t|
          case t.kind
          when :comment
            (map[t.line] ||= []) << t.text.strip
          when :blank_line
            @blank_line_set[t.line] = true
          end
        end
        map
      end

      def flush_leading_comments_before(stmt_line)
        return unless stmt_line

        @comment_map.keys.select { |line| line < stmt_line }.sort.each do |line_no|
          @comment_map.delete(line_no)&.each { |text| line(text) }
        end
      end

      def attach_inline_comment(line_no, header_idx)
        return unless line_no && header_idx < @lines.length
        return unless @comment_map.key?(line_no)

        comments = @comment_map.delete(line_no)
        return if comments.empty?

        @lines[header_idx] = "#{@lines[header_idx]}  #{comments.first}"
      end

      def emit_source_file(source_file)
        @current_module_kind = source_file.module_kind
        if source_file.module_kind == :raw_module
          flush_leading_comments_before(source_file.line) if source_file.line
          line("external")
          attach_inline_comment(source_file.line, @lines.length - 1)
          blank_line unless source_file.imports.empty? && source_file.directives.empty? && source_file.declarations.empty?
        end

        emit_module_body(source_file)
      end

      def emit_module_body(source_file)
        wrote_section = false

        unless source_file.imports.empty?
          source_file.imports.each do |import|
            flush_leading_comments_before(import.line)
            line(render_import(import))
            attach_inline_comment(import.line, @lines.length - 1)
          end
          wrote_section = true
        end

        unless source_file.directives.empty?
          blank_line if wrote_section
          source_file.directives.each { |directive| line(render_directive(directive)) }
          wrote_section = true
        end

        if source_file.declarations.empty?
          flush_remaining_comments
          return
        end

        blank_line if wrote_section
        source_file.declarations.each_with_index do |declaration, index|
          emit_declaration(declaration)
          next_decl = source_file.declarations[index + 1]
          if next_decl && declaration_separator_required?(declaration, next_decl)
            blank_line
          end
        end

        flush_remaining_comments
      end

      def flush_remaining_comments
        sorted = @comment_map.keys.sort
        sorted.each do |l|
          @comment_map.delete(l)&.each { |text| line(text) }
        end
      end

      BLOCK_DECLARATION_TYPES = [
        AST::FunctionDef, AST::ForeignFunctionDecl, AST::InterfaceDecl, AST::ExtendingBlock,
        AST::StructDecl, AST::UnionDecl, AST::EnumDecl, AST::FlagsDecl, AST::VariantDecl,
      ].freeze

      def block_declaration?(declaration)
        BLOCK_DECLARATION_TYPES.any? { |t| declaration.is_a?(t) }
      end

      def declaration_separator_required?(declaration, next_decl)
        if @current_module_kind == :raw_module
          return raw_module_separator_required?(declaration, next_decl)
        end

        block_declaration?(declaration) || block_declaration?(next_decl)
      end

      def raw_module_separator_required?(declaration, next_decl)
        return true if raw_module_block_declaration?(declaration) || raw_module_block_declaration?(next_decl)

        raw_module_declaration_group(declaration) != raw_module_declaration_group(next_decl)
      end

      def raw_module_block_declaration?(declaration)
        declaration.is_a?(AST::StructDecl) ||
          declaration.is_a?(AST::UnionDecl) ||
          declaration.is_a?(AST::EnumDecl) ||
          declaration.is_a?(AST::FlagsDecl)
      end

      def raw_module_declaration_group(declaration)
        case declaration
        when AST::OpaqueDecl, AST::TypeAliasDecl
          :types
        when AST::ConstDecl
          :values
        when AST::ExternFunctionDecl
          :functions
        else
          declaration.class.name
        end
      end

      def emit_declaration(declaration)
        decl_line = declaration.respond_to?(:line) ? declaration.line : nil
        flush_leading_comments_before(decl_line)
        header_idx = @lines.length

        case declaration
        when AST::ConstDecl
          emit_const(declaration)
        when AST::VarDecl
          header = "#{visibility_prefix(declaration)}var #{declaration.name}"
          header += ": #{render_type(declaration.type)}" if declaration.type
          if declaration.value
            line("#{header} = #{render_expression(declaration.value)}")
          else
            line(header)
          end
        when AST::EventDecl
          emit_attribute_applications(declaration.attributes)
          line(render_event_declaration(declaration))
        when AST::TypeAliasDecl
          line("#{visibility_prefix(declaration)}type #{declaration.name} = #{render_type(declaration.target)}")
        when AST::AttributeDecl
          text = "#{visibility_prefix(declaration)}attribute[#{declaration.targets.join(', ')}] #{declaration.name}"
          text += "(#{declaration.params.map { |param| render_param(param) }.join(', ')})" unless declaration.params.empty?
          line(text)
        when AST::StaticAssert
          line("static_assert(#{render_expression(declaration.condition)}, #{render_expression(declaration.message)})")
        when AST::StructDecl
          emit_attribute_applications(declaration.attributes)
          header_idx = @lines.length
          header = +""
          header << visibility_prefix(declaration)
          header << "struct #{declaration.name}#{render_struct_params(declaration.lifetime_params, declaration.type_params)}"
          header << render_implements_clause(declaration.implements)
          header << " = c#{declaration.c_name.inspect}" if declaration.c_name
          header << ":"
          line(header)
          with_indent do
            declaration.fields.each do |field|
              emit_attribute_applications(field.attributes)
              line("#{field.name}: #{render_type(field.type)}")
            end
            declaration.nested_types.each do |nested|
              emit_declaration(nested)
            end
            declaration.events.each do |event|
              line(render_event_declaration(event))
            end
          end
        when AST::UnionDecl
          emit_attribute_applications(declaration.attributes)
          header = "#{visibility_prefix(declaration)}union #{declaration.name}"
          header += " = c#{declaration.c_name.inspect}" if declaration.c_name
          line("#{header}:")
          with_indent do
            declaration.fields.each do |field|
              line("#{field.name}: #{render_type(field.type)}")
            end
          end
        when AST::EnumDecl
          emit_attribute_applications(declaration.attributes)
          emit_enum_like("enum", declaration.name, declaration.backing_type, declaration.members, declaration.visibility)
        when AST::FlagsDecl
          emit_attribute_applications(declaration.attributes)
          emit_enum_like("flags", declaration.name, declaration.backing_type, declaration.members, declaration.visibility)
        when AST::VariantDecl
          emit_attribute_applications(declaration.attributes)
          header = "#{visibility_prefix(declaration)}variant #{declaration.name}"
          header += render_type_params(declaration.type_params) if declaration.type_params.any?
          line("#{header}:")
          with_indent do
            declaration.arms.each do |arm|
              arm_text = +"#{arm.name}"
              if arm.fields.any?
                field_strs = arm.fields.map { |f| "#{f.name}: #{render_type(f.type)}" }
                arm_text += "(#{field_strs.join(', ')})"
              end
              line(arm_text)
            end
          end
        when AST::OpaqueDecl
          text = "#{visibility_prefix(declaration)}opaque #{declaration.name}"
          text += render_implements_clause(declaration.implements)
          text += " = c#{declaration.c_name.inspect}" if declaration.c_name
          line(text)
        when AST::InterfaceDecl
          header = "#{visibility_prefix(declaration)}interface #{declaration.name}"
          header += render_type_params(declaration.type_params) if declaration.type_params.any?
          line("#{header}:")
          with_indent do
            declaration.methods.each do |method|
              emit_attribute_applications(method.attributes)
              line(render_interface_method_signature(method))
            end
          end
        when AST::ExtendingBlock
          line("extending #{render_type(declaration.type_name)}:")
          with_indent do
            declaration.methods.each_with_index do |method, index|
              emit_function(method)
              blank_line if index < (declaration.methods.length - 1)
            end
          end
        when AST::FunctionDef
          emit_function(declaration)
        when AST::ExternFunctionDecl
          emit_attribute_applications(declaration.attributes)
          header_idx = @lines.length
          line = "#{render_function_signature(declaration, prefix: 'external ')}"
          line += " = #{render_expression(declaration.mapping)}" if declaration.mapping
          line(line)
        when AST::ForeignFunctionDecl
          emit_attribute_applications(declaration.attributes)
          header_idx = @lines.length
          line("#{render_function_signature(declaration)} = #{render_expression(declaration.mapping)}")
        when AST::WhenStmt
          emit_when(declaration)
        else
          raise ArgumentError, "unsupported AST declaration #{declaration.class.name}"
        end

        attach_inline_comment(decl_line, header_idx)
      end

      def emit_enum_like(kind, name, backing_type, members, visibility)
        header = "#{visibility_prefix(visibility)}#{kind} #{name}"
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

      def render_event_declaration(declaration)
        text = +"#{visibility_prefix(declaration)}event #{declaration.name}[#{declaration.capacity}]"
        text << "(#{render_type(declaration.payload_type)})" if declaration.payload_type
        text
      end

      def emit_function(function)
        emit_attribute_applications(function.attributes)
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
                             when :editable
                               "editable function "
                             when :static
                               "static function "
                             else
                               "function "
                             end
                           elsif function.is_a?(AST::ForeignFunctionDecl)
                             "foreign function "
                           else
                             "function "
                           end
        async_prefix = function.respond_to?(:async) && function.async ? "async " : ""
        text = +"#{prefix}#{visibility_prefix(function)}#{async_prefix}#{signature_prefix}#{function.name}#{render_type_params(function.type_params)}(#{render_signature_params(function)})"
        text << " -> #{render_type(function.return_type)}" if function.return_type
        text
      end

      def visibility_prefix(declaration_or_visibility)
        return "" if @current_module_kind == :raw_module

        visibility = if declaration_or_visibility.is_a?(Symbol)
                       declaration_or_visibility
                     elsif declaration_or_visibility.respond_to?(:visibility)
                       declaration_or_visibility.visibility
                     end

        visibility == :public ? "public " : ""
      end

      def render_signature_params(function)
        params = function.params.map { |param| render_param(param) }
        params << "..." if function.respond_to?(:variadic) && function.variadic
        params.join(', ')
      end

      def render_type_params(type_params)
        return "" if type_params.empty?

        rendered = type_params.map do |type_param|
          if type_param.is_a?(AST::ValueTypeParam)
            next "#{type_param.name}: #{render_type(type_param.type)}"
          end

          next type_param.name if type_param.constraints.empty?

          "#{type_param.name} #{render_type_param_constraints(type_param.constraints)}"
        end
        "[#{rendered.join(', ')}]"
      end

      def render_struct_params(lifetime_params, type_params)
        parts = []
        parts.push(*lifetime_params) if lifetime_params&.any?
        parts.concat(type_params.map(&:name))
        return "" if parts.empty?

        "[#{parts.join(', ')}]"
      end

      def render_type_param_constraints(constraints)
        parts = []
        index = 0
        while index < constraints.length
          constraint = constraints[index]
          if constraint.kind == :interface
            interfaces = [constraint.interface_ref.to_s]
            index += 1
            while index < constraints.length && constraints[index].kind == :interface
              interfaces << constraints[index].interface_ref.to_s
              index += 1
            end
            parts << "implements #{interfaces.join(' and ')}"
          else
            raise "unsupported type parameter constraint #{constraint.kind}"
          end
        end

        parts.join(' and ')
      end

      def render_implements_clause(implements)
        return "" if implements.empty?

        " implements #{implements.map(&:to_s).join(', ')}"
      end

      def emit_attribute_applications(attributes)
        attributes.each do |attribute|
          line(render_attribute_application(attribute))
        end
      end

      def render_attribute_application(attribute)
        text = +"@[#{attribute.name}"
        unless attribute.arguments.empty?
          rendered_arguments = attribute.arguments.map do |argument|
            if argument.name
              "#{argument.name} = #{render_expression(argument.value)}"
            else
              render_expression(argument.value)
            end
          end
          text << "(#{rendered_arguments.join(', ')})"
        end
        text << "]"
        text
      end

      def render_interface_method_signature(method)
        prefix = +""
        prefix << "async " if method.async
        prefix << case method.kind
                  when :editable
                    "editable function "
                  else
                    "function "
                  end

        text = "#{prefix}#{method.name}(#{method.params.map { |param| render_param(param) }.join(', ')})"
        text << " -> #{render_type(method.return_type)}" if method.return_type
        text
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
        when AST::CompilerFlagDirective
          "compiler_flag #{directive.value.inspect}"
        else
          raise ArgumentError, "unsupported AST directive #{directive.class.name}"
        end
      end

      def emit_statement(statement)
        stmt_line = statement.respond_to?(:line) ? statement.line : nil
        flush_leading_comments_before(stmt_line)
        header_idx = @lines.length

        case statement
        when AST::LocalDecl
          if statement.destructure_bindings
            text = "#{statement.kind} #{render_destructure_target(statement)}"
          else
            text = "#{statement.kind} #{statement.name}"
            text += ": #{render_type(statement.type)}" if statement.type
          end
          text += " = #{render_expression(statement.value)}" if statement.value
          if statement.else_body
            else_header = statement.else_binding ? "else as #{statement.else_binding.name}:" : "else:"
            line("#{text} #{else_header}")
            with_indent do
              statement.else_body.each { |nested| emit_statement(nested) }
            end
          else
            line(text)
          end
        when AST::Assignment
          line("#{render_expression(statement.target)} #{statement.operator} #{render_expression(statement.value)}")
        when AST::IfStmt
          emit_if(statement)
        when AST::MatchStmt
          prefix = statement.inline ? "inline match" : "match"
          line("#{prefix} #{render_expression(statement.expression)}:")
          with_indent do
            statement.arms.each do |arm|
              binding = arm.binding_name ? " as #{arm.binding_name}" : ""
              line("#{render_expression(arm.pattern)}#{binding}:")
              with_indent do
                arm.body.each { |nested| emit_statement(nested) }
              end
            end
          end
        when AST::UnsafeStmt
          if (inline = render_inline_unsafe(statement))
            line(inline)
          else
            line("unsafe:")
            with_indent do
              statement.body.each { |nested| emit_statement(nested) }
            end
          end
        when AST::StaticAssert
          line("static_assert(#{render_expression(statement.condition)}, #{render_expression(statement.message)})")
        when AST::EmitStmt
          before = @lines.length
          emit_declaration(statement.declaration)
          @lines[before] = @lines[before].sub(/\A(\s*)/, "\\1emit ") if @lines[before]
        when AST::ForStmt
          prefix = +""
          prefix << "parallel " if statement.threaded
          prefix << "inline " if statement.inline
          bindings = statement.bindings.map(&:name).join(", ")
          iterables = statement.iterables.map { |iterable| render_expression(iterable) }.join(", ")
          line("#{prefix}for #{bindings} in #{iterables}:")
          with_indent do
            statement.body.each { |nested| emit_statement(nested) }
          end
        when AST::WhileStmt
          prefix = statement.inline ? "inline while" : "while"
          line("#{prefix} #{render_expression(statement.condition)}:")
          with_indent do
            statement.body.each { |nested| emit_statement(nested) }
          end
        when AST::PassStmt
          line("pass")
        when AST::BreakStmt
          line("break")
        when AST::ContinueStmt
          line("continue")
        when AST::ReturnStmt
          line(statement.value ? "return #{render_expression(statement.value)}" : "return")
        when AST::DeferStmt
          if statement.body
            line("defer:")
            with_indent do
              statement.body.each { |nested| emit_statement(nested) }
            end
          else
            line("defer #{render_expression(statement.expression)}")
          end
        when AST::ExpressionStmt
          line(render_expression(statement.expression))
        when AST::ParallelBlockStmt
          line("parallel:")
          with_indent do
            statement.bodies.each do |body|
              body.each { |nested| emit_statement(nested) }
            end
          end
        when AST::GatherStmt
          line("gather #{statement.handles.map { |handle| render_expression(handle) }.join(', ')}")
        when AST::WhenStmt
          emit_when(statement)
        when AST::ConstDecl
          emit_const(statement)
        else
          raise ArgumentError, "unsupported AST statement #{statement.class.name}"
        end

        attach_inline_comment(stmt_line, header_idx)
      end

      def emit_when(statement)
        line("when #{render_expression(statement.discriminant)}:")
        with_indent do
          statement.branches.each do |branch|
            binding = branch.binding_name ? " as #{branch.binding_name}" : ""
            line("#{render_expression(branch.pattern)}#{binding}:")
            with_indent do
              branch.body.each { |nested| emit_block_item(nested) }
            end
          end
          if statement.else_body
            line("else:")
            with_indent do
              statement.else_body.each { |nested| emit_block_item(nested) }
            end
          end
        end
      end

      # A `when` branch body is statements at function level but declarations at
      # module level; dispatch on the node kind.
      def emit_block_item(node)
        if declaration_node?(node)
          emit_declaration(node)
        else
          emit_statement(node)
        end
      end

      def declaration_node?(node)
        case node
        when AST::FunctionDef, AST::StructDecl, AST::UnionDecl, AST::EnumDecl,
             AST::FlagsDecl, AST::VariantDecl, AST::OpaqueDecl, AST::InterfaceDecl,
             AST::ExtendingBlock, AST::TypeAliasDecl, AST::AttributeDecl, AST::EventDecl,
             AST::ExternFunctionDecl, AST::ForeignFunctionDecl, AST::VarDecl, AST::MethodDef
          true
        else
          false
        end
      end

      def render_destructure_target(statement)
        names = statement.destructure_bindings.join(", ")
        type_name = statement.destructure_type_name
        return "(#{names})" unless type_name

        prefix = type_name.is_a?(Array) ? type_name.join(".") : type_name
        "#{prefix}(#{names})"
      end

      def emit_const(declaration)
        emit_attribute_applications(declaration.attributes)
        header = "#{visibility_prefix(declaration)}const #{declaration.name}"
        if declaration.block_body
          line("#{header} -> #{render_type(declaration.type)}:")
          with_indent do
            declaration.block_body.each { |nested| emit_statement(nested) }
          end
        else
          header += ": #{render_type(declaration.type)}" if declaration.type
          line("#{header} = #{render_expression(declaration.value)}")
        end
      end

      def render_inline_unsafe(statement)
        return nil unless statement.body.length == 1

        nested = statement.body.first
        return nil if nested.is_a?(AST::LocalDecl)

        inline = render_inline_statement(nested)
        return nil unless inline
        return nil if unsafe_inline_trivia_conflict?(statement, nested)

        "unsafe: #{inline}"
      end

      def render_inline_statement(statement)
        case statement
        when AST::LocalDecl
          return nil if statement.else_body

          text = +"#{statement.kind} #{statement.name}"
          text << ": #{render_type(statement.type)}" if statement.type
          text << " = #{render_expression(statement.value)}" if statement.value
          text
        when AST::Assignment
          "#{render_expression(statement.target)} #{statement.operator} #{render_expression(statement.value)}"
        when AST::StaticAssert
          "static_assert(#{render_expression(statement.condition)}, #{render_expression(statement.message)})"
        when AST::PassStmt
          "pass"
        when AST::BreakStmt
          "break"
        when AST::ContinueStmt
          "continue"
        when AST::ReturnStmt
          statement.value ? "return #{render_expression(statement.value)}" : "return"
        when AST::DeferStmt
          return nil if statement.body

          "defer #{render_expression(statement.expression)}"
        when AST::ExpressionStmt
          render_expression(statement.expression)
        else
          nil
        end
      end

      def unsafe_inline_trivia_conflict?(unsafe_stmt, nested)
        unsafe_line = unsafe_stmt.respond_to?(:line) ? unsafe_stmt.line : nil
        nested_line = nested.respond_to?(:line) ? nested.line : nil
        return false unless unsafe_line && nested_line && nested_line > unsafe_line

        @comment_map.keys.any? { |line| line >= unsafe_line + 1 && line <= nested_line } ||
          @blank_line_set.keys.any? { |line| line >= unsafe_line + 1 && line < nested_line }
      end

      def emit_if(statement)
        first_branch, *rest = statement.branches
        prefix = statement.inline ? "inline if" : "if"
        line("#{prefix} #{render_expression(first_branch.condition)}:")
        with_indent do
          first_branch.body.each { |nested| emit_statement(nested) }
        end

        rest.each do |branch|
          line("else if #{render_expression(branch.condition)}:")
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
        if param.is_a?(AST::ForeignParam)
          text = +""
          text << "#{param.mode} " unless param.mode == :plain
          text << "#{param.name}: #{render_type(param.type)}"
          text << " as #{render_type(param.boundary_type)}" if param.boundary_type
          return text
        end

        return param.name unless param.type

        "#{param.name}: #{render_type(param.type)}"
      end

      def render_type(type)
        case type
        when AST::TypeRef
          text = type.name.to_s
          args = []
          args << type.lifetime if type.lifetime
          args.concat(type.arguments.map { |argument| render_type_argument(argument.value) })
          text += "[#{args.join(', ')}]" unless args.empty?
          type.nullable ? "#{text}?" : text
        when AST::FunctionType
          "fn(#{type.params.map { |param| render_param(param) }.join(', ')}) -> #{render_type(type.return_type)}"
        when AST::ProcType
          "proc(#{type.params.map { |param| render_param(param) }.join(', ')}) -> #{render_type(type.return_type)}"
        when AST::DynType
          if type.interface.type_arguments.any?
            "dyn[#{type.interface.parts.join('.')}[#{type.interface.type_arguments.map { |a| render_type(a) }.join(', ')}]]"
          else
            "dyn[#{type.interface.parts.join('.')}]"
          end
        when AST::TupleType
          text = "(#{type.element_types.map { |element| render_type(element) }.join(', ')})"
          type.nullable ? "#{text}?" : text
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
        when AST::IndexAccess
          wrap("#{render_postfix(expression.receiver)}[#{render_expression(expression.index)}]", parent_precedence, POSTFIX_PRECEDENCE)
        when AST::Specialization
          wrap("#{render_postfix(expression.callee)}[#{expression.arguments.map { |argument| render_type_argument(argument.value) }.join(', ')}]", parent_precedence, POSTFIX_PRECEDENCE)
        when AST::Call
          wrap("#{render_postfix(expression.callee)}(#{expression.arguments.map { |argument| render_argument(argument) }.join(', ')})", parent_precedence, POSTFIX_PRECEDENCE)
        when AST::PrefixCast
          wrap("#{render_type(expression.target_type)}<-#{render_expression(expression.expression, UNARY_PRECEDENCE)}", parent_precedence, UNARY_PRECEDENCE)
        when AST::UnaryOp
          if expression.operator == "?"
            return wrap("#{render_postfix(expression.operand)}?", parent_precedence, POSTFIX_PRECEDENCE)
          end

          operand = render_expression(expression.operand, UNARY_PRECEDENCE)
          text = %w[not out in inout].include?(expression.operator) ? "#{expression.operator} #{operand}" : "#{expression.operator}#{operand}"
          wrap(text, parent_precedence, UNARY_PRECEDENCE)
        when AST::BinaryOp
          current_precedence = precedence(expression.operator)
          left = render_expression(expression.left, current_precedence)
          right = render_expression(expression.right, current_precedence + 1)
          wrap("#{left} #{expression.operator} #{right}", parent_precedence, current_precedence)
        when AST::RangeExpr
          left = render_expression(expression.start_expr)
          right = render_expression(expression.end_expr)
          "#{left}..#{right}"
        when AST::ExpressionList
          "(#{expression.elements.map { |element| render_list_element(element) }.join(', ')})"
        when AST::IfExpr
          condition = render_expression(expression.condition, IF_EXPRESSION_PRECEDENCE)
          then_expression = render_expression(expression.then_expression, IF_EXPRESSION_PRECEDENCE)
          else_expression = render_expression(expression.else_expression, IF_EXPRESSION_PRECEDENCE)
          wrap("if #{condition}: #{then_expression} else: #{else_expression}", parent_precedence, IF_EXPRESSION_PRECEDENCE)
        when AST::MatchExpr
          sugared = render_is_expression(expression, parent_precedence)
          return sugared if sugared

          rendered_expression = render_expression(expression.expression, IF_EXPRESSION_PRECEDENCE)
          arm_indent = INDENT * (@indent + 1)
          rendered_arms = expression.arms.map do |arm|
            binding = arm.binding_name ? " as #{arm.binding_name}" : ""
            "#{render_expression(arm.pattern)}#{binding}: #{render_expression(arm.value, IF_EXPRESSION_PRECEDENCE)}"
          end.join("\n#{arm_indent}")
          "match #{rendered_expression}:\n#{arm_indent}#{rendered_arms}"
        when AST::UnsafeExpr
          inner = render_expression(expression.expression, IF_EXPRESSION_PRECEDENCE)
          wrap("unsafe: #{inner}", parent_precedence, IF_EXPRESSION_PRECEDENCE)
        when AST::ProcExpr
          params = expression.params.map { |param| render_param(param) }.join(', ')
          if expression.body.length == 1 && expression.body.first.is_a?(AST::ReturnStmt) && expression.body.first.value
            body_expression = render_expression(expression.body.first.value, IF_EXPRESSION_PRECEDENCE)
            wrap("proc(#{params}) -> #{render_type(expression.return_type)}: #{body_expression}", parent_precedence, IF_EXPRESSION_PRECEDENCE)
          else
            body_lines = capture_lines do
              with_indent do
                expression.body.each { |statement| emit_statement(statement) }
              end
            end
            "proc(#{params}) -> #{render_type(expression.return_type)}:\n#{body_lines.join("\n")}"
          end
        when AST::AwaitExpr
          wrap("await #{render_expression(expression.expression, UNARY_PRECEDENCE)}", parent_precedence, UNARY_PRECEDENCE)
        when AST::SizeofExpr
          "size_of(#{render_type(expression.type)})"
        when AST::AlignofExpr
          "align_of(#{render_type(expression.type)})"
        when AST::OffsetofExpr
          "offset_of(#{render_type(expression.type)}, #{expression.field})"
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::CharLiteral
          expression.lexeme
        when AST::FormatString
          "f\"#{expression.parts.map { |part| render_format_string_part(part) }.join}\""
        when AST::BooleanLiteral
          expression.value ? "true" : "false"
        when AST::NullLiteral
          expression.type ? "null[#{render_type(expression.type)}]" : "null"
        when AST::DetachExpr
          wrap("detach #{render_expression(expression.body.first.expression, UNARY_PRECEDENCE)}", parent_precedence, UNARY_PRECEDENCE)
        else
          raise ArgumentError, "unsupported AST expression #{expression.class.name}"
        end
      end

      def render_argument(argument)
        return render_expression(argument.value) unless argument.name

        "#{argument.name} = #{render_expression(argument.value)}"
      end

      def render_list_element(element)
        return render_argument(element) if element.is_a?(AST::Argument)

        render_expression(element)
      end

      def render_format_string_part(part)
        case part
        when AST::FormatTextPart
          escape_format_text(part.value)
        when AST::FormatExprPart
          spec = case part.format_spec&.fetch(:kind)
                 when :precision then ":.#{part.format_spec[:value]}"
                 when :hex then part.format_spec[:uppercase] ? ":X" : ":x"
                 when :oct then part.format_spec[:uppercase] ? ":O" : ":o"
                 when :bin then part.format_spec[:uppercase] ? ":B" : ":b"
                 end
          "\#{#{render_expression(part.expression)}#{spec}}"
        else
          raise ArgumentError, "unsupported format string part #{part.class.name}"
        end
      end

      def escape_format_text(value)
        value.gsub(/[\\"\n\r\t\0]/) do |char|
          case char
          when "\\" then "\\\\"
          when '"' then '\\"'
          when "\n" then "\\n"
          when "\r" then "\\r"
          when "\t" then "\\t"
          when "\0" then "\\0"
          end
        end
      end

      # `expr is Arm` desugars at parse time to `match expr: Arm: true; _: false`;
      # re-sugar that exact shape back to `is` so the formatter round-trips (and a
      # multi-line match does not break when used as a statement condition).
      def render_is_expression(expression, parent_precedence)
        arms = expression.arms
        return nil unless arms.length == 2

        first, second = arms
        return nil if first.binding_name || second.binding_name
        return nil unless boolean_literal?(first.value, true) && boolean_literal?(second.value, false)
        return nil unless wildcard_pattern?(second.pattern)
        return nil if first.pattern.is_a?(AST::Call) && first.pattern.arguments.any?

        scrutinee = render_expression(expression.expression, IS_PRECEDENCE)
        arm = render_expression(first.pattern, IS_PRECEDENCE)
        wrap("#{scrutinee} is #{arm}", parent_precedence, IS_PRECEDENCE)
      end

      def boolean_literal?(node, value)
        node.is_a?(AST::BooleanLiteral) && node.value == value
      end

      def wildcard_pattern?(node)
        node.is_a?(AST::Identifier) && node.name == "_"
      end

      def render_postfix(expression)
        return render_expression(expression, POSTFIX_PRECEDENCE) if postfix_expression?(expression)

        "(#{render_expression(expression)})"
      end

      def postfix_expression?(expression)
        expression.is_a?(AST::Identifier) || expression.is_a?(AST::MemberAccess) || expression.is_a?(AST::IndexAccess) ||
          expression.is_a?(AST::Specialization) || expression.is_a?(AST::Call) ||
          (expression.is_a?(AST::UnaryOp) && expression.operator == "?")
      end
    end
  end
end
