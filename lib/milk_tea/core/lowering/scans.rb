# frozen_string_literal: true

module MilkTea
  module LowererScans
    private

      def collect_structs
        @ctx.ast.declarations.each do |decl|
          case decl
          when AST::WhenStmt
            body = lower_when_chosen_body(decl)
            body&.each { |nested| collect_struct_from_decl(nested) }
          when AST::OpaqueDecl
            @ctx.opaque_types[decl.name] = @ctx.types.fetch(decl.name)
          when AST::StructDecl
            @ctx.struct_types[decl.name] = @ctx.types.fetch(decl.name)
            collect_nested_structs(decl)
          when AST::UnionDecl
            @ctx.union_types[decl.name] = @ctx.types.fetch(decl.name)
          end
        end
      end

      def collect_struct_from_decl(decl)
        case decl
        when AST::OpaqueDecl
          @ctx.opaque_types[decl.name] = @ctx.types.fetch(decl.name)
        when AST::StructDecl
          @ctx.struct_types[decl.name] = @ctx.types.fetch(decl.name)
          collect_nested_structs(decl)
        when AST::UnionDecl
          @ctx.union_types[decl.name] = @ctx.types.fetch(decl.name)
        when AST::WhenStmt
          body = lower_when_chosen_body(decl)
          body&.each { |nested| collect_struct_from_decl(nested) }
        end
      end

      def lower_when_chosen_body(decl)
        val = compile_time_const_value(decl.discriminant)
        return nil if val.nil?

        chosen = decl.branches.find { |b| val == compile_time_const_value(b.pattern) }
        chosen&.body || decl.else_body
      end

      def collect_nested_structs(parent_decl, parent_name: parent_decl.name)
        parent_decl.nested_types.each do |nested|
          qualified_name = "#{parent_name}.#{nested.name}"
          @ctx.struct_types[qualified_name] = @ctx.types.fetch(qualified_name)
          collect_nested_structs(nested, parent_name: qualified_name)
        end
      end

      def collect_includes
        headers = ["<stdbool.h>", "<stdint.h>", "<string.h>"]
        headers << "<stddef.h>" if program_uses_offsetof?
        headers << "<stdio.h>" if program_uses_fatal?

        each_raw_module_analysis do |analysis|
          analysis.directives.grep(AST::IncludeDirective).each do |directive|
            headers << normalized_include_header(directive.value)
          end
        end

        headers.uniq.map { |header| IR::Include.new(header:) }
      end

      def normalized_include_header(header_name)
        return "<#{header_name}>" if standard_c_runtime_header?(header_name)

        %("#{header_name}")
      end

      def standard_c_runtime_header?(header_name)
        %w[stdbool.h stdint.h stdlib.h string.h stddef.h stdio.h time.h].include?(header_name)
      end

      def program_uses_fatal?
        each_non_raw_module_analysis.any? do |analysis|
          analysis_uses_fatal?(analysis)
        end
      end

      def program_uses_offsetof?
        each_non_raw_module_analysis.any? do |analysis|
          analysis_uses_offsetof?(analysis)
        end
      end

      def analysis_uses_fatal?(analysis)
        analysis.ast.declarations.any? do |decl|
          case decl
          when AST::FunctionDef
            block_uses_fatal?(decl.body)
          when AST::ExtendingBlock
            decl.methods.any? { |method| block_uses_fatal?(method.body) }
          else
            false
          end
        end
      end

      def analysis_uses_offsetof?(analysis)
        analysis.ast.declarations.any? do |decl|
          case decl
          when AST::FunctionDef
            block_uses_offsetof?(decl.body)
          when AST::ExtendingBlock
            decl.methods.any? { |method| block_uses_offsetof?(method.body) }
          else
            false
          end
        end
      end

      def block_uses_fatal?(statements)
        block_uses_expression_pattern?(statements) { |expression| fatal_expression?(expression) }
      end

      def block_uses_offsetof?(statements)
        block_uses_expression_pattern?(statements) { |expression| offsetof_expression?(expression) }
      end

      def block_uses_expression_pattern?(statements, &predicate)
        statements.any? { |statement| statement_uses_expression_pattern?(statement, &predicate) }
      end

      def statement_uses_expression_pattern?(statement, &predicate)
        case statement
        when AST::LocalDecl
          expression_uses_pattern?(statement.value, &predicate)
        when AST::Assignment
          expression_uses_pattern?(statement.target, &predicate) || expression_uses_pattern?(statement.value, &predicate)
        when AST::IfStmt
          statement.branches.any? { |branch| expression_uses_pattern?(branch.condition, &predicate) || block_uses_expression_pattern?(branch.body, &predicate) } ||
            (statement.else_body && block_uses_expression_pattern?(statement.else_body, &predicate))
        when AST::MatchStmt
          expression_uses_pattern?(statement.expression, &predicate) || statement.arms.any? { |arm| expression_uses_pattern?(arm.pattern, &predicate) || block_uses_expression_pattern?(arm.body, &predicate) }
        when AST::StaticAssert
          expression_uses_pattern?(statement.condition, &predicate) || expression_uses_pattern?(statement.message, &predicate)
        when AST::ForStmt
          statement.iterables.any? { |iterable| expression_uses_pattern?(iterable, &predicate) } || block_uses_expression_pattern?(statement.body, &predicate)
        when AST::UnsafeStmt, AST::WhileStmt
          expression = statement.is_a?(AST::WhileStmt) ? statement.condition : nil
          (expression && expression_uses_pattern?(expression, &predicate)) || block_uses_expression_pattern?(statement.body, &predicate)
        when AST::ReturnStmt
          statement.value && expression_uses_pattern?(statement.value, &predicate)
        when AST::DeferStmt, AST::ExpressionStmt
          expression_uses_pattern?(statement.expression, &predicate)
        else
          false
        end
      end

      def fatal_expression?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "fatal"
      end

      def offsetof_expression?(expression)
        expression.is_a?(AST::OffsetofExpr)
      end

      def expression_uses_pattern?(expression, &predicate)
        return false unless expression
        return true if predicate.call(expression)

        case expression
        when AST::AwaitExpr
          expression_uses_pattern?(expression.expression, &predicate)
        when AST::Call
          expression_uses_pattern?(expression.callee, &predicate) || expression.arguments.any? { |argument| expression_uses_pattern?(argument.value, &predicate) }
        when AST::BinaryOp
          expression_uses_pattern?(expression.left, &predicate) || expression_uses_pattern?(expression.right, &predicate)
        when AST::RangeExpr
          expression_uses_pattern?(expression.start_expr, &predicate) || expression_uses_pattern?(expression.end_expr, &predicate)
        when AST::IfExpr
          expression_uses_pattern?(expression.condition, &predicate) || expression_uses_pattern?(expression.then_expression, &predicate) || expression_uses_pattern?(expression.else_expression, &predicate)
        when AST::MatchExpr
          expression_uses_pattern?(expression.expression, &predicate) || expression.arms.any? { |arm| expression_uses_pattern?(arm.pattern, &predicate) || expression_uses_pattern?(arm.value, &predicate) }
        when AST::UnsafeExpr
          expression_uses_pattern?(expression.expression, &predicate)
        when AST::PrefixCast
          expression_uses_pattern?(expression.expression, &predicate)
        when AST::UnaryOp
          expression_uses_pattern?(expression.operand, &predicate)
        when AST::MemberAccess
          expression_uses_pattern?(expression.receiver, &predicate)
        when AST::IndexAccess
          expression_uses_pattern?(expression.receiver, &predicate) || expression_uses_pattern?(expression.index, &predicate)
        when AST::Specialization
          expression_uses_pattern?(expression.callee, &predicate) || expression.arguments.any? { |argument| expression_uses_pattern?(argument.value, &predicate) }
        else
          false
        end
      end

      def prepare_analysis(analysis, source_path: nil)
        @ctx.install(analysis)
        @ctx.current_analysis_path = source_path
        @ctx.module_prefix = module_c_prefix(@ctx.module_name)
      end

      def collect_tuple_structs(analysis)
        return unless analysis

        analysis.functions.each_value do |func|
          r_collect_tuple_from_type(func.type.return_type)
          func.type.params.each { |p| r_collect_tuple_from_type(p.type) }
        end
        analysis.types.each_value do |type|
          next unless type.respond_to?(:fields)
          type.fields.each_value { |ft| r_collect_tuple_from_type(ft) }
        end
      end

      private def r_collect_tuple_from_type(type)
        return unless type
        return if @collected_tuple_types&.key?(type.object_id)

        if type.is_a?(Types::Tuple)
          @collected_tuple_types ||= {}
          @collected_tuple_types[type.object_id] = true

          linkage_name = "mt_tuple_" + type.element_types.map { |et| sanitize_type_name_for_tuple(et) }.join("_")
          return if @artifacts.synthetic_structs.any? { |s| s.linkage_name == linkage_name }

          @artifacts.synthetic_structs << IR::StructDecl.new(
            name: type.to_s,
            linkage_name: linkage_name,
            fields: type.element_types.each_with_index.map { |et, i| IR::Field.new(name: "_#{i}", type: et) },
            packed: false,
            alignment: nil,
          )
        end

        type.element_types.each { |et| r_collect_tuple_from_type(et) } if type.is_a?(Types::Tuple)
      end

      private def sanitize_type_name_for_tuple(type)
        type.to_s.gsub(/[^a-zA-Z0-9]/, "_").gsub(/_+/, "_").gsub(/^_|_$/, "")
      end

      def build_method_definitions
        @program.analyses_by_path.values.each_with_object({}) do |analysis, definitions|
          analysis.ast.declarations.grep(AST::ExtendingBlock).each do |extending_block|
            receiver_type = resolve_extending_receiver_type(analysis, extending_block.type_name)
            extending_block.methods.each do |method|
              method_key = method.kind == :static ? "static:#{method.name}" : method.name
              definitions[[receiver_type, method_key]] = [analysis, method]
            end
          end
        end
      end
  end
end
