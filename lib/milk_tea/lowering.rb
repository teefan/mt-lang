# frozen_string_literal: true

module MilkTea
  class LoweringError < StandardError; end

  class Lowering
    def self.lower(program)
      Lowerer.new(program).lower
    end

    class Lowerer
      def initialize(program)
        @program = program
        @analysis = nil
        @module_name = nil
        @module_prefix = nil
        @imports = {}
        @types = {}
        @values = {}
        @functions = {}
        @struct_types = {}
        @union_types = {}
        @method_definitions = build_method_definitions
      end

      def lower
        if @program.root_analysis.module_kind == :extern_module
          raise LoweringError, "cannot emit C for extern module #{@program.root_analysis.module_name}"
        end

        includes = collect_includes

        constants = []
        structs = []
        unions = []
        enums = []
        static_asserts = []
        functions = []

        lowered_analyses.each do |analysis|
          next if analysis.module_kind == :extern_module

          prepare_analysis(analysis)
          collect_structs

          constants.concat(lower_constants)
          structs.concat(lower_structs)
          unions.concat(lower_unions)
          enums.concat(lower_enums)
          static_asserts.concat(lower_static_asserts)
          functions.concat(lower_functions)
        end

        IR::Program.new(
          module_name: @program.root_analysis.module_name,
          includes:,
          constants:,
          structs:,
          unions:,
          enums:,
          static_asserts:,
          functions:,
        )
      end

      private

      def collect_structs
        @analysis.ast.declarations.each do |decl|
          case decl
          when AST::StructDecl
            @struct_types[decl.name] = @types.fetch(decl.name)
          when AST::UnionDecl
            @union_types[decl.name] = @types.fetch(decl.name)
          end
        end
      end

      def collect_includes
        headers = ["<stdbool.h>", "<stdint.h>", "<string.h>"]
        headers << "<stddef.h>" if program_uses_offsetof?
        if program_uses_panic?
          headers << "<stdio.h>"
          headers << "<stdlib.h>"
        end

        @program.analyses_by_module_name.each_value do |analysis|
          next unless analysis.module_kind == :extern_module

          analysis.directives.grep(AST::IncludeDirective).each do |directive|
            headers << %("#{directive.value}")
          end
        end

        headers.uniq.map { |header| IR::Include.new(header:) }
      end

      def program_uses_panic?
        @program.analyses_by_path.values.any? { |analysis| analysis_uses_panic?(analysis) }
      end

      def program_uses_offsetof?
        @program.analyses_by_path.values.any? { |analysis| analysis_uses_offsetof?(analysis) }
      end

      def analysis_uses_panic?(analysis)
        analysis.ast.declarations.any? do |decl|
          case decl
          when AST::FunctionDef
            block_uses_panic?(decl.body)
          when AST::MethodsBlock
            decl.methods.any? { |method| block_uses_panic?(method.body) }
          else
            false
          end
        end
      end

      def analysis_uses_offsetof?(analysis)
        analysis.ast.declarations.any? do |decl|
          case decl
          when AST::ConstDecl
            expression_uses_offsetof?(decl.value)
          when AST::StaticAssert
            expression_uses_offsetof?(decl.condition) || expression_uses_offsetof?(decl.message)
          when AST::FunctionDef
            block_uses_offsetof?(decl.body)
          when AST::MethodsBlock
            decl.methods.any? { |method| block_uses_offsetof?(method.body) }
          else
            false
          end
        end
      end

      def block_uses_panic?(statements)
        statements.any? { |statement| statement_uses_panic?(statement) }
      end

      def block_uses_offsetof?(statements)
        statements.any? { |statement| statement_uses_offsetof?(statement) }
      end

      def statement_uses_panic?(statement)
        case statement
        when AST::LocalDecl
          expression_uses_panic?(statement.value)
        when AST::Assignment
          expression_uses_panic?(statement.target) || expression_uses_panic?(statement.value)
        when AST::IfStmt
          statement.branches.any? { |branch| expression_uses_panic?(branch.condition) || block_uses_panic?(branch.body) } ||
            (statement.else_body && block_uses_panic?(statement.else_body))
        when AST::MatchStmt
          expression_uses_panic?(statement.expression) || statement.arms.any? { |arm| expression_uses_panic?(arm.pattern) || block_uses_panic?(arm.body) }
        when AST::StaticAssert
          expression_uses_panic?(statement.condition) || expression_uses_panic?(statement.message)
        when AST::ForStmt
          expression_uses_panic?(statement.iterable) || block_uses_panic?(statement.body)
        when AST::UnsafeStmt, AST::WhileStmt
          expression = statement.is_a?(AST::WhileStmt) ? statement.condition : nil
          (expression && expression_uses_panic?(expression)) || block_uses_panic?(statement.body)
        when AST::ReturnStmt
          statement.value && expression_uses_panic?(statement.value)
        when AST::DeferStmt, AST::ExpressionStmt
          expression_uses_panic?(statement.expression)
        else
          false
        end
      end

      def statement_uses_offsetof?(statement)
        case statement
        when AST::LocalDecl
          expression_uses_offsetof?(statement.value)
        when AST::Assignment
          expression_uses_offsetof?(statement.target) || expression_uses_offsetof?(statement.value)
        when AST::IfStmt
          statement.branches.any? { |branch| expression_uses_offsetof?(branch.condition) || block_uses_offsetof?(branch.body) } ||
            (statement.else_body && block_uses_offsetof?(statement.else_body))
        when AST::MatchStmt
          expression_uses_offsetof?(statement.expression) || statement.arms.any? { |arm| expression_uses_offsetof?(arm.pattern) || block_uses_offsetof?(arm.body) }
        when AST::StaticAssert
          expression_uses_offsetof?(statement.condition) || expression_uses_offsetof?(statement.message)
        when AST::ForStmt
          expression_uses_offsetof?(statement.iterable) || block_uses_offsetof?(statement.body)
        when AST::UnsafeStmt, AST::WhileStmt
          expression = statement.is_a?(AST::WhileStmt) ? statement.condition : nil
          (expression && expression_uses_offsetof?(expression)) || block_uses_offsetof?(statement.body)
        when AST::ReturnStmt
          statement.value && expression_uses_offsetof?(statement.value)
        when AST::DeferStmt, AST::ExpressionStmt
          expression_uses_offsetof?(statement.expression)
        else
          false
        end
      end

      def expression_uses_panic?(expression)
        case expression
        when AST::Call
          identifier = expression.callee
          return true if identifier.is_a?(AST::Identifier) && identifier.name == "panic"

          expression_uses_panic?(expression.callee) || expression.arguments.any? { |argument| expression_uses_panic?(argument.value) }
        when AST::BinaryOp
          expression_uses_panic?(expression.left) || expression_uses_panic?(expression.right)
        when AST::IfExpr
          expression_uses_panic?(expression.condition) || expression_uses_panic?(expression.then_expression) || expression_uses_panic?(expression.else_expression)
        when AST::UnaryOp
          expression_uses_panic?(expression.operand)
        when AST::MemberAccess
          expression_uses_panic?(expression.receiver)
        when AST::IndexAccess
          expression_uses_panic?(expression.receiver) || expression_uses_panic?(expression.index)
        when AST::Specialization
          expression_uses_panic?(expression.callee) || expression.arguments.any? { |argument| expression_uses_panic?(argument.value) }
        else
          false
        end
      end

      def expression_uses_offsetof?(expression)
        case expression
        when AST::OffsetofExpr
          true
        when AST::Call
          expression_uses_offsetof?(expression.callee) || expression.arguments.any? { |argument| expression_uses_offsetof?(argument.value) }
        when AST::BinaryOp
          expression_uses_offsetof?(expression.left) || expression_uses_offsetof?(expression.right)
        when AST::IfExpr
          expression_uses_offsetof?(expression.condition) || expression_uses_offsetof?(expression.then_expression) || expression_uses_offsetof?(expression.else_expression)
        when AST::UnaryOp
          expression_uses_offsetof?(expression.operand)
        when AST::MemberAccess
          expression_uses_offsetof?(expression.receiver)
        when AST::IndexAccess
          expression_uses_offsetof?(expression.receiver) || expression_uses_offsetof?(expression.index)
        when AST::Specialization
          expression_uses_offsetof?(expression.callee) || expression.arguments.any? { |argument| expression_uses_offsetof?(argument.value) }
        else
          false
        end
      end

      def lowered_analyses
        @program.analyses_by_path.values
      end

      def prepare_analysis(analysis)
        @analysis = analysis
        @module_name = analysis.module_name
        @module_prefix = @module_name.tr(".", "_")
        @imports = analysis.imports
        @types = analysis.types
        @values = analysis.values
        @functions = analysis.functions
        @struct_types = {}
        @union_types = {}
      end

      def build_method_definitions
        @program.analyses_by_path.values.each_with_object({}) do |analysis, definitions|
          analysis.ast.declarations.grep(AST::MethodsBlock).each do |methods_block|
            receiver_type = resolve_methods_receiver_type(analysis, methods_block.type_name)
            methods_block.methods.each do |method|
              definitions[[receiver_type, method.name]] = [analysis, method]
            end
          end
        end
      end

      def lower_constants
        @analysis.ast.declarations.grep(AST::ConstDecl).map do |decl|
          type = @values.fetch(decl.name).type
          value = lower_expression(decl.value, env: empty_env, expected_type: type)
          IR::Constant.new(name: decl.name, c_name: constant_c_name(decl.name), type:, value:)
        end
      end

      def lower_static_asserts
        @analysis.ast.declarations.grep(AST::StaticAssert).map do |statement|
          IR::StaticAssert.new(
            condition: lower_expression(statement.condition, env: empty_env, expected_type: @types.fetch("bool")),
            message: lower_expression(statement.message, env: empty_env, expected_type: @types.fetch("str")),
          )
        end
      end

      def lower_structs
        @analysis.ast.declarations.grep(AST::StructDecl).filter_map do |decl|
          next unless decl.type_params.empty?

          struct_type = @struct_types.fetch(decl.name)
          fields = decl.fields.map do |field|
            IR::Field.new(name: field.name, type: struct_type.field(field.name))
          end
          IR::StructDecl.new(name: decl.name, c_name: c_type_name(struct_type), fields:, packed: decl.packed, alignment: decl.alignment)
        end
      end

      def lower_unions
        @analysis.ast.declarations.grep(AST::UnionDecl).map do |decl|
          union_type = @union_types.fetch(decl.name)
          fields = decl.fields.map do |field|
            IR::Field.new(name: field.name, type: union_type.field(field.name))
          end
          IR::UnionDecl.new(name: decl.name, c_name: c_type_name(union_type), fields:)
        end
      end

      def lower_enums
        @analysis.ast.declarations.filter_map do |decl|
          case decl
          when AST::EnumDecl, AST::FlagsDecl
            enum_type = @types.fetch(decl.name)
            backing_type = enum_type.backing_type
            members = decl.members.map do |member|
              value = lower_expression(member.value, env: empty_env, expected_type: backing_type)
              IR::EnumMember.new(name: member.name, c_name: enum_member_c_name(enum_type, member.name), value:)
            end

            IR::EnumDecl.new(
              name: decl.name,
              c_name: c_type_name(enum_type),
              backing_type:,
              members:,
              flags: decl.is_a?(AST::FlagsDecl),
            )
          end
        end
      end

      def lower_functions
        lowered = []

        @analysis.ast.declarations.each do |decl|
          case decl
          when AST::FunctionDef
            binding = @functions.fetch(decl.name)
            if binding.type_params.any?
              binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                lowered << lower_function_decl(instance)
              end
            else
              lowered << lower_function_decl(binding)
            end
          when AST::MethodsBlock
            receiver_type = resolve_methods_receiver_type(@analysis, decl.type_name)
            decl.methods.each do |method|
              lowered << lower_function_decl(@analysis.methods.fetch(receiver_type).fetch(method.name), receiver_type:)
            end
          end
        end

        lowered
      end

      def resolve_methods_receiver_type(analysis, type_name)
        parts = type_name.parts
        if parts.length == 1
          return analysis.types.fetch(parts.first)
        end

        if parts.length == 2
          imported_module = analysis.imports.fetch(parts.first)
          return imported_module.types.fetch(parts.last)
        end

        raise LoweringError, "unsupported methods target #{type_name}"
      end

      def lower_function_decl(binding, receiver_type: nil)
        decl = binding.ast
        params = []
        env = empty_env
        parameter_setup = []
        previous_type_substitutions = @current_type_substitutions
        @current_type_substitutions = binding.type_substitutions

        body_params = binding.body_params.dup
        if binding.type.receiver_type
          receiver_binding = body_params.shift
          c_name = c_local_name(receiver_binding.name)
          env[:scopes].last[receiver_binding.name] = local_binding(
            type: receiver_binding.type,
            c_name:,
            mutable: receiver_binding.mutable,
            pointer: binding.type.receiver_mutable,
          )
          params << IR::Param.new(
            name: receiver_binding.name,
            c_name:,
            type: receiver_binding.type,
            pointer: binding.type.receiver_mutable,
          )
        end

        body_params.each_with_index do |param_binding, index|
          param = decl.params[index]
          type = param_binding.type

          c_name = c_local_name(param_binding.name)
          if array_type?(type)
            input_c_name = "#{c_name}_input"
            params << IR::Param.new(name: param_binding.name, c_name: input_c_name, type:, pointer: false)
            env[:scopes].last[param_binding.name] = local_binding(type:, c_name:, mutable: param.mutable, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param_binding.name,
              c_name:,
              type:,
              value: IR::Name.new(name: input_c_name, type:, pointer: false),
            )
          else
            env[:scopes].last[param_binding.name] = local_binding(type:, c_name:, mutable: param.mutable, pointer: false)
            params << IR::Param.new(name: param_binding.name, c_name:, type:, pointer: false)
          end
        end

        return_type = binding.type.return_type
        body = lower_block(decl.body, env:, active_defers: [], return_type:, loop_flow: nil)
        body = parameter_setup + body

        IR::Function.new(
          name: decl.name,
          c_name: function_binding_c_name(binding, module_name: @module_name, receiver_type:),
          params:,
          return_type:,
          body:,
          entry_point: receiver_type.nil? && decl.name == "main" && binding.type_arguments.empty?,
        )
      ensure
        @current_type_substitutions = previous_type_substitutions
      end

      def lower_block(statements, env:, active_defers:, return_type:, loop_flow:)
        local_env = duplicate_env(env)
        lowered = []
        local_defers = []

        statements.each do |statement|
          case statement
          when AST::DeferStmt
            local_defers << lower_expression(statement.expression, env: local_env)
          when AST::UnsafeStmt
            body = lower_block(
              statement.body,
              env: local_env,
              active_defers: active_defers + local_defers,
              return_type:,
              loop_flow: nested_loop_flow(loop_flow, local_defers),
            )
            lowered << IR::BlockStmt.new(body:)
          when AST::LocalDecl
            type = statement.type ? resolve_type_ref(statement.type) : infer_expression_type(statement.value, env: local_env)
            c_name = c_local_name(statement.name)
            value = lower_contextual_expression(
              statement.value,
              env: local_env,
              expected_type: type,
              contextual_int_to_float: statement.type && contextual_int_to_float_target?(type),
            )
            current_actual_scope(local_env[:scopes])[statement.name] = local_binding(type:, c_name:, mutable: statement.kind == :var, pointer: false)
            lowered << IR::LocalDecl.new(name: statement.name, c_name:, type:, value:)
          when AST::Assignment
            target = lower_assignment_target(statement.target, env: local_env)
            value = if statement.operator == "="
                      lower_contextual_expression(
                        statement.value,
                        env: local_env,
                        expected_type: target.type,
                        external_numeric: external_numeric_assignment_target?(statement.target, env: local_env),
                        contextual_int_to_float: contextual_int_to_float_target?(target.type),
                      )
                    else
                      lower_expression(statement.value, env: local_env, expected_type: target.type)
                    end
            lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
          when AST::IfStmt
            false_refinements = {}
            branch_entries = []

            statement.branches.each do |branch|
              branch_env = env_with_refinements(local_env, false_refinements)
              true_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: true, env: branch_env))

              branch_entries << [
                lower_expression(branch.condition, env: branch_env, expected_type: @types.fetch("bool")),
                lower_block(
                  branch.body,
                  env: env_with_refinements(local_env, true_refinements),
                  active_defers: active_defers + local_defers,
                  return_type:,
                  loop_flow: nested_loop_flow(loop_flow, local_defers),
                ),
              ]

              false_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: false, env: branch_env))
            end

            nested_else_body = statement.else_body ? lower_block(
              statement.else_body,
              env: env_with_refinements(local_env, false_refinements),
              active_defers: active_defers + local_defers,
              return_type:,
              loop_flow: nested_loop_flow(loop_flow, local_defers),
            ) : []

            nested_if = nested_else_body
            branch_entries.reverse_each do |condition, then_body|
              nested_if = [IR::IfStmt.new(condition:, then_body:, else_body: nested_if)]
            end
            lowered.concat(nested_if)

            if statement.else_body.nil? && statement.branches.all? { |branch| block_always_terminates?(branch.body) }
              local_env[:scopes] = scopes_with_refinements(local_env[:scopes], false_refinements)
            end
          when AST::MatchStmt
            scrutinee_type = infer_expression_type(statement.expression, env: local_env)
            expression = lower_expression(statement.expression, env: local_env, expected_type: scrutinee_type)
            cases = statement.arms.map do |arm|
              value = lower_expression(arm.pattern, env: local_env, expected_type: scrutinee_type)
              body = lower_block(
                arm.body,
                env: local_env,
                active_defers: active_defers + local_defers,
                return_type:,
                loop_flow: nested_loop_flow(loop_flow, local_defers),
              )
              IR::SwitchCase.new(value:, body:)
            end
            lowered << IR::SwitchStmt.new(expression:, cases:)
          when AST::StaticAssert
            lowered << IR::StaticAssert.new(
              condition: lower_expression(statement.condition, env: local_env, expected_type: @types.fetch("bool")),
              message: lower_expression(statement.message, env: local_env, expected_type: @types.fetch("str")),
            )
          when AST::ForStmt
            lowered << lower_for_stmt(statement, env: local_env, active_defers: active_defers + local_defers, return_type:)
          when AST::WhileStmt
            lowered << lower_while_stmt(statement, env: local_env, active_defers: active_defers + local_defers, return_type:)
          when AST::BreakStmt
            raise LoweringError, "break must be inside a loop" unless loop_flow

            lowered.concat(lower_loop_exit(loop_flow[:break_label], local_defers, loop_flow[:break_defers]))
          when AST::ContinueStmt
            raise LoweringError, "continue must be inside a loop" unless loop_flow

            lowered.concat(lower_loop_exit(loop_flow[:continue_label], local_defers, loop_flow[:continue_defers]))
          when AST::ReturnStmt
            cleanup = cleanup_statements(local_defers, active_defers)
            lowered.concat(cleanup)
            value = statement.value ? lower_contextual_expression(
              statement.value,
              env: local_env,
              expected_type: return_type,
              contextual_int_to_float: contextual_int_to_float_target?(return_type),
            ) : nil
            lowered << IR::ReturnStmt.new(value:)
          when AST::ExpressionStmt
            lowered << IR::ExpressionStmt.new(expression: lower_expression(statement.expression, env: local_env))
          else
            raise LoweringError, "unsupported statement #{statement.class.name}"
          end
        end

        unless terminating_ir_statement?(lowered.last)
          lowered.concat(cleanup_statements(local_defers, []))
        end
        lowered
      end

      def lower_for_stmt(statement, env:, active_defers:, return_type:)
        return lower_range_for_stmt(statement, env:, active_defers:, return_type:) if range_call?(statement.iterable)

        lower_collection_for_stmt(statement, env:, active_defers:, return_type:)
      end

      def lower_while_stmt(statement, env:, active_defers:, return_type:)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")

        body = lower_block(
          statement.body,
          env: env_with_refinements(duplicate_env(env), flow_refinements(statement.condition, truthy: true, env: env)),
          active_defers:,
          return_type:,
          loop_flow: loop_flow(break_label:, continue_label:),
        )
        body << IR::LabelStmt.new(name: continue_label)

        IR::BlockStmt.new(body: [
          IR::WhileStmt.new(
            condition: lower_expression(statement.condition, env:, expected_type: @types.fetch("bool")),
            body:,
          ),
          IR::LabelStmt.new(name: break_label),
        ])
      end

      def lower_range_for_stmt(statement, env:, active_defers:, return_type:)
        loop_type = infer_range_loop_type(statement.iterable, env:)
        start_expr = statement.iterable.arguments[0].value
        stop_expr = statement.iterable.arguments[1].value
        index_c_name = fresh_c_temp_name(env, "for_index")
        stop_c_name = fresh_c_temp_name(env, "for_stop")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_c_name, type: loop_type, pointer: false)
        stop_ref = IR::Name.new(name: stop_c_name, type: loop_type, pointer: false)

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(type: loop_type, c_name: c_local_name(statement.name), mutable: false, pointer: false)

        body = [
          IR::LocalDecl.new(name: statement.name, c_name: c_local_name(statement.name), type: loop_type, value: index_ref),
        ]
        body.concat(
          lower_block(
            statement.body,
            env: while_env,
            active_defers:,
            return_type:,
            loop_flow: loop_flow(break_label:, continue_label:),
          ),
        )
        body << IR::LabelStmt.new(name: continue_label)
        body << IR::Assignment.new(
          target: index_ref,
          operator: "+=",
          value: IR::IntegerLiteral.new(value: 1, type: loop_type),
        )

        IR::BlockStmt.new(body: [
          IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: loop_type, value: lower_expression(start_expr, env:, expected_type: loop_type)),
          IR::LocalDecl.new(name: stop_c_name, c_name: stop_c_name, type: loop_type, value: lower_expression(stop_expr, env:, expected_type: loop_type)),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_ref, type: @types.fetch("bool")),
            body:,
          ),
          IR::LabelStmt.new(name: break_label),
        ])
      end

      def lower_collection_for_stmt(statement, env:, active_defers:, return_type:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects range(start, stop), array[T, N], or span[T], got #{iterable_type}" unless element_type

        iterable_c_name = fresh_c_temp_name(env, "for_items")
        index_c_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        iterable_ref = IR::Name.new(name: iterable_c_name, type: iterable_type, pointer: false)
        index_ref = IR::Name.new(name: index_c_name, type: @types.fetch("usize"), pointer: false)

        item_value = if array_type?(iterable_type)
                       IR::Index.new(receiver: iterable_ref, index: index_ref, type: element_type)
                     else
                       data_ref = IR::Member.new(receiver: iterable_ref, member: "data", type: pointer_to(element_type))
                       IR::Index.new(receiver: data_ref, index: index_ref, type: element_type)
                     end

        stop_value = if array_type?(iterable_type)
                       IR::IntegerLiteral.new(value: array_length(iterable_type), type: @types.fetch("usize"))
                     else
                       IR::Member.new(receiver: iterable_ref, member: "len", type: @types.fetch("usize"))
                     end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(type: element_type, c_name: c_local_name(statement.name), mutable: false, pointer: false)

        body = [
          IR::LocalDecl.new(name: statement.name, c_name: c_local_name(statement.name), type: element_type, value: item_value),
        ]
        body.concat(
          lower_block(
            statement.body,
            env: while_env,
            active_defers:,
            return_type:,
            loop_flow: loop_flow(break_label:, continue_label:),
          ),
        )
        body << IR::LabelStmt.new(name: continue_label)
        body << IR::Assignment.new(
          target: index_ref,
          operator: "+=",
          value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("usize")),
        )

        IR::BlockStmt.new(body: [
          IR::LocalDecl.new(name: iterable_c_name, c_name: iterable_c_name, type: iterable_type, value: lower_expression(statement.iterable, env:, expected_type: iterable_type)),
          IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("usize"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("usize"))),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
            body:,
          ),
          IR::LabelStmt.new(name: break_label),
        ])
      end

      def lower_assignment_target(expression, env:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          IR::Name.new(name: binding[:c_name], type: binding[:storage_type], pointer: binding[:pointer])
        when AST::MemberAccess
          receiver = lower_expression(expression.receiver, env:)
          type = infer_expression_type(expression, env:)
          IR::Member.new(receiver:, member: expression.member, type:)
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          receiver = lower_expression(expression.receiver, env:)
          index = lower_expression(expression.index, env:, expected_type: @types.fetch("usize"))
          type = infer_expression_type(expression, env:)
          if array_type?(receiver_type)
            IR::CheckedIndex.new(receiver:, index:, receiver_type:, type:)
          elsif receiver_type.is_a?(Types::Span)
            IR::CheckedSpanIndex.new(receiver:, index:, receiver_type:, type:)
          else
            IR::Index.new(receiver:, index:, type:)
          end
        when AST::Call
          if value_call?(expression)
            type = infer_expression_type(expression, env:)
            operand = lower_expression(expression.arguments.first.value, env:)
            return IR::Unary.new(operator: "*", operand:, type:)
          end

          raise LoweringError, "unsupported assignment target #{expression.class.name}"
        else
          raise LoweringError, "unsupported assignment target #{expression.class.name}"
        end
      end

      def lower_expression(expression, env:, expected_type: nil)
        type = infer_expression_type(expression, env:, expected_type:)

        case expression
        when AST::IntegerLiteral
          IR::IntegerLiteral.new(value: expression.value, type:)
        when AST::FloatLiteral
          IR::FloatLiteral.new(value: expression.value, type:)
        when AST::SizeofExpr
          IR::SizeofExpr.new(target_type: resolve_type_ref(expression.type), type:)
        when AST::AlignofExpr
          IR::AlignofExpr.new(target_type: resolve_type_ref(expression.type), type:)
        when AST::OffsetofExpr
          IR::OffsetofExpr.new(target_type: resolve_type_ref(expression.type), field: expression.field, type:)
        when AST::StringLiteral
          IR::StringLiteral.new(value: expression.value, type:, cstring: expression.cstring)
        when AST::BooleanLiteral
          IR::BooleanLiteral.new(value: expression.value, type:)
        when AST::NullLiteral
          IR::NullLiteral.new(type:)
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          if binding
            IR::Name.new(name: binding[:c_name], type: binding[:type], pointer: binding[:pointer])
          elsif @functions.key?(expression.name)
            function_binding = @functions.fetch(expression.name)
            raise LoweringError, "generic function #{expression.name} cannot be used as a value" if function_binding.type_params.any?

            IR::Name.new(name: function_binding_c_name(function_binding, module_name: @module_name), type: type, pointer: false)
          else
            raise LoweringError, "unsupported identifier #{expression.name}"
          end
        when AST::MemberAccess
          lower_member_access(expression, env:, type:)
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          receiver = lower_expression(expression.receiver, env:)
          index = lower_expression(expression.index, env:, expected_type: @types.fetch("usize"))
          if array_type?(receiver_type) && addressable_storage_expression?(expression.receiver)
            IR::CheckedIndex.new(receiver:, index:, receiver_type:, type:)
          elsif receiver_type.is_a?(Types::Span)
            IR::CheckedSpanIndex.new(receiver:, index:, receiver_type:, type:)
          else
            IR::Index.new(receiver:, index:, type:)
          end
        when AST::UnaryOp
          IR::Unary.new(operator: expression.operator, operand: lower_expression(expression.operand, env:, expected_type: type), type:)
        when AST::BinaryOp
          right_env = binary_right_env(expression, env)
          left_type, right_type = infer_binary_operand_types(expression, env:, expected_type: type)
          operand_type = promoted_binary_operand_type(expression.operator, left_type, right_type)
          left = lower_expression(expression.left, env:, expected_type: operand_type || type)
          right = lower_expression(expression.right, env: right_env, expected_type: operand_type || left.type)
          left = cast_expression(left, operand_type) if operand_type
          right = cast_expression(right, operand_type) if operand_type
          IR::Binary.new(operator: expression.operator, left:, right:, type:)
        when AST::IfExpr
          then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
          else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
          IR::Conditional.new(
            condition: lower_expression(expression.condition, env:, expected_type: @types.fetch("bool")),
            then_expression: lower_contextual_expression(expression.then_expression, env: then_env, expected_type: type),
            else_expression: lower_contextual_expression(expression.else_expression, env: else_env, expected_type: type),
            type:,
          )
        when AST::Call
          lower_call(expression, env:, type:)
        when AST::Specialization
          lower_specialization(expression, env:, type:)
        else
          raise LoweringError, "unsupported expression #{expression.class.name}"
        end
      end

      def lower_member_access(expression, env:, type:)
        if (type_expr = resolve_type_expression(expression.receiver))
          member_name = if local_named_type?(type_expr) && (type_expr.is_a?(Types::Enum) || type_expr.is_a?(Types::Flags))
                          enum_member_c_name(type_expr, expression.member)
                        else
                          expression.member
                        end
          return IR::Name.new(name: member_name, type:, pointer: false)
        end

        if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
          imported_module = @imports.fetch(expression.receiver.name)
          return IR::Name.new(name: imported_value_c_name(imported_module, expression.member), type:, pointer: false)
        end

        receiver = lower_expression(expression.receiver, env:)
        IR::Member.new(receiver:, member: expression.member, type:)
      end

      def lower_call(expression, env:, type:)
        kind, callee_name, receiver, callee_type = resolve_callee(expression.callee, env, arguments: expression.arguments)

        case kind
        when :function
          arguments = lower_call_arguments(expression.arguments, callee_type, env:)
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :method
          receiver_arg = lower_method_receiver_argument(receiver, callee_type, env:)
          arguments = [receiver_arg, *lower_call_arguments(expression.arguments, callee_type, env:)]
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :associated_method
          arguments = lower_call_arguments(expression.arguments, callee_type, env:)
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :struct_literal
          fields = expression.arguments.map do |argument|
            field_type = type.field(argument.name)
            IR::AggregateField.new(
              name: argument.name,
              value: lower_contextual_expression(
                argument.value,
                env:,
                expected_type: field_type,
                external_numeric: type.respond_to?(:external) && type.external,
              ),
            )
          end
          IR::AggregateLiteral.new(type:, fields:)
        when :array
          element_type = array_element_type(type)
          elements = expression.arguments.map do |argument|
            lower_contextual_expression(argument.value, env:, expected_type: element_type)
          end
          IR::ArrayLiteral.new(type:, elements:)
        when :cast
          argument = expression.arguments.fetch(0)
          lowered_arg = lower_expression(argument.value, env:)
          IR::Cast.new(target_type: type, expression: lowered_arg, type:)
        when :reinterpret
          argument = expression.arguments.fetch(0)
          source_type = infer_expression_type(argument.value, env:)
          IR::ReinterpretExpr.new(
            target_type: type,
            source_type:,
            expression: lower_expression(argument.value, env:, expected_type: source_type),
            type:,
          )
        when :zero
          IR::ZeroInit.new(type:)
        when :result_ok
          argument = expression.arguments.fetch(0)
          fields = [
            IR::AggregateField.new(name: "is_ok", value: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool"))),
            IR::AggregateField.new(name: "value", value: lower_contextual_expression(argument.value, env:, expected_type: type.ok_type)),
          ]
          IR::AggregateLiteral.new(type:, fields:)
        when :result_err
          argument = expression.arguments.fetch(0)
          fields = [
            IR::AggregateField.new(name: "is_ok", value: IR::BooleanLiteral.new(value: false, type: @types.fetch("bool"))),
            IR::AggregateField.new(name: "error", value: lower_contextual_expression(argument.value, env:, expected_type: type.error_type)),
          ]
          IR::AggregateLiteral.new(type:, fields:)
        when :panic
          argument = expression.arguments.fetch(0)
          message_type = infer_expression_type(argument.value, env:)
          callee = message_type == @types.fetch("cstr") ? "mt_panic" : "mt_panic_str"
          IR::Call.new(callee:, arguments: [lower_expression(argument.value, env:, expected_type: message_type)], type:)
        when :addr
          argument = expression.arguments.fetch(0)
          IR::AddressOf.new(expression: lower_expression(argument.value, env:), type:)
        when :value
          argument = expression.arguments.fetch(0)
          IR::Unary.new(operator: "*", operand: lower_expression(argument.value, env:), type:)
        when :raw
          argument = expression.arguments.fetch(0)
          IR::Cast.new(target_type: type, expression: lower_expression(argument.value, env:), type:)
        else
          raise LoweringError, "unsupported call kind #{kind}"
        end
      end

      def lower_method_receiver_argument(receiver, callee_type, env:)
        lowered_receiver = lower_expression(receiver, env:)

        if callee_type.receiver_mutable
          if lowered_receiver.is_a?(IR::Name) && lowered_receiver.pointer
            return lowered_receiver
          end

          if lowered_receiver.is_a?(IR::Unary) && lowered_receiver.operator == "*"
            return lowered_receiver.operand
          end

          return IR::AddressOf.new(expression: lowered_receiver, type: lowered_receiver.type)
        end

        lowered_receiver
      end

      def lower_call_arguments(arguments, callee_type, env:)
        arguments.map.with_index do |argument, index|
          expected_type = index < callee_type.params.length ? callee_type.params[index].type : nil
          lower_contextual_expression(argument.value, env:, expected_type:, external_numeric: callee_type.external && !expected_type.nil?)
        end
      end

      def lower_contextual_expression(expression, env:, expected_type:, external_numeric: false, contextual_int_to_float: false)
        lowered = lower_expression(expression, env:, expected_type: expected_type)
        return lowered unless expected_type
        return lowered if lowered.type == expected_type
        return cast_expression(lowered, expected_type) if contextual_numeric_compatibility?(expression, lowered.type, expected_type, external_numeric:, contextual_int_to_float:)

        lowered
      end

      def contextual_numeric_compatibility?(expression, actual_type, expected_type, external_numeric: false, contextual_int_to_float: false)
        return true if integer_literal_numeric_compatibility?(expression, expected_type)
        return true if external_numeric && external_numeric_compatibility?(actual_type, expected_type)
        return true if contextual_int_to_float && contextual_int_to_float_compatibility?(actual_type, expected_type)

        false
      end

      def integer_literal_numeric_compatibility?(expression, expected_type)
        integer_literal_expression?(expression) && expected_type.is_a?(Types::Primitive) && expected_type.numeric?
      end

      def integer_literal_expression?(expression)
        expression.is_a?(AST::IntegerLiteral) ||
          (expression.is_a?(AST::UnaryOp) && ["+", "-"].include?(expression.operator) && integer_literal_expression?(expression.operand))
      end

      def external_numeric_compatibility?(actual_type, expected_type)
        actual_type.is_a?(Types::Primitive) && actual_type.numeric? &&
          expected_type.is_a?(Types::Primitive) && expected_type.numeric?
      end

      def contextual_int_to_float_compatibility?(actual_type, expected_type)
        actual_type.is_a?(Types::Primitive) && actual_type.integer? &&
          expected_type.is_a?(Types::Primitive) && expected_type.float?
      end

      def contextual_int_to_float_target?(type)
        type.is_a?(Types::Primitive) && type.float?
      end

      def external_numeric_assignment_target?(expression, env:)
        case expression
        when AST::MemberAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          receiver_type.respond_to?(:external) && receiver_type.external
        else
          false
        end
      end

      def lower_specialization(expression, env:, type:)
        raise LoweringError, "specialization #{expression.callee.name} must be called" if expression.callee.is_a?(AST::Identifier)

        raise LoweringError, "unsupported specialization #{expression.class.name}"
      end

      def resolve_callee(callee, env, arguments: nil)
        case callee
        when AST::Identifier
          if @functions.key?(callee.name)
            binding = specialize_function_binding(@functions.fetch(callee.name), arguments, env)
            [ :function, function_binding_c_name(binding, module_name: @module_name), nil, binding.type ]
          elsif callee.name == "ok"
            [:result_ok, nil, nil, nil]
          elsif callee.name == "err"
            [:result_err, nil, nil, nil]
          elsif callee.name == "panic"
            [:panic, nil, nil, nil]
          elsif callee.name == "addr"
            [:addr, nil, nil, nil]
          elsif callee.name == "value"
            [:value, nil, nil, nil]
          elsif callee.name == "raw"
            [:raw, nil, nil, nil]
          elsif (type = @types[callee.name]).is_a?(Types::Struct) || type.is_a?(Types::StringView)
            [ :struct_literal, nil, nil, type ]
          else
            raise LoweringError, "unknown callee #{callee.name}"
          end
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @imports.key?(callee.receiver.name)
            imported_module = @imports.fetch(callee.receiver.name)
            if imported_module.functions.key?(callee.member)
              binding = specialize_function_binding(imported_module.functions.fetch(callee.member), arguments, env)
              return [:function, function_binding_c_name(binding, module_name: imported_module.name), nil, binding.type] unless binding.external

              return [:function, binding.name, nil, binding.type]
            end
            imported_type = imported_module.types[callee.member]
            if imported_type.is_a?(Types::Struct) || imported_type.is_a?(Types::StringView)
              return [:struct_literal, nil, nil, imported_module.types.fetch(callee.member)]
            end
          end

          if (type_expr = resolve_type_expression(callee.receiver))
            method_entry = @method_definitions[[type_expr, callee.member]]
            if method_entry
              method_analysis, method_ast = method_entry
              method_binding = method_analysis.methods.fetch(type_expr).fetch(method_ast.name)
              if method_binding.type.receiver_type.nil?
                return [:associated_method, function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: type_expr), nil, method_binding.type]
              end
            end

            raise LoweringError, "unknown associated function #{type_expr}.#{callee.member}"
          end

          receiver_type = infer_expression_type(callee.receiver, env:)
          resolved_receiver_type = receiver_type
          method_entry = @method_definitions[[resolved_receiver_type, callee.member]]
          if method_entry
            method_analysis, method_ast = method_entry
            method_binding = method_analysis.methods.fetch(resolved_receiver_type).fetch(method_ast.name)
            return [:method, function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: resolved_receiver_type), callee.receiver, method_binding.type]
          end

          raise LoweringError, "unknown callee #{callee.receiver}.#{callee.member}"
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
            target_type = resolve_type_ref(callee.arguments.fetch(0).value)
            return [:cast, nil, nil, Types::Function.new("cast", params: [Types::Parameter.new("value", @types.fetch("i32"))], return_type: target_type)]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "reinterpret"
            target_type = resolve_type_ref(callee.arguments.fetch(0).value)
            return [:reinterpret, nil, nil, Types::Function.new("reinterpret", params: [Types::Parameter.new("value", target_type)], return_type: target_type)]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "array"
            array_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["array"]), arguments: callee.arguments, nullable: false))
            return [:array, nil, nil, array_type]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "span"
            span_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: callee.arguments, nullable: false))
            return [:struct_literal, nil, nil, span_type]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "zero"
            target_type = resolve_type_ref(callee.arguments.fetch(0).value)
            return [:zero, nil, nil, Types::Function.new("zero", params: [], return_type: target_type)]
          end

          if (function_binding = resolve_specialized_function_binding(callee))
            if function_binding.external
              return [:function, function_binding.name, nil, function_binding.type]
            end

            return [:function, function_binding_c_name(function_binding, module_name: function_binding.owner.module_name), nil, function_binding.type]
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct_literal, nil, nil, specialized_type] if specialized_type.is_a?(Types::Struct) || result_type?(specialized_type)
          end

          raise LoweringError, "unsupported specialization callee"
        else
          raise LoweringError, "unsupported callee #{callee.class.name}"
        end
      end

      def infer_expression_type(expression, env:, expected_type: nil)
        case expression
        when AST::IntegerLiteral
          if expected_type.is_a?(Types::Primitive) && expected_type.integer?
            expected_type
          else
            @types.fetch("i32")
          end
        when AST::FloatLiteral
          if expected_type.is_a?(Types::Primitive) && expected_type.float?
            expected_type
          else
            @types.fetch("f64")
          end
        when AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
          @types.fetch("usize")
        when AST::StringLiteral
          @types.fetch(expression.cstring ? "cstr" : "str")
        when AST::BooleanLiteral
          @types.fetch("bool")
        when AST::NullLiteral
          expected_type || Types::Nullable.new(@types.fetch("void"))
        when AST::Identifier
          binding = lookup_value(expression.name, env)
          return binding[:type] if binding
          return function_type_for_name(expression.name) if @functions.key?(expression.name)

          raise LoweringError, "unknown identifier #{expression.name}"
        when AST::MemberAccess
          if (type_expr = resolve_type_expression(expression.receiver))
            member_type = resolve_type_member(type_expr, expression.member)
            return member_type if member_type

            if (method_entry = @method_definitions[[type_expr, expression.member]])
              method_analysis, method_ast = method_entry
              method_binding = method_analysis.methods.fetch(type_expr).fetch(method_ast.name)
              return method_binding.type if method_binding.type.receiver_type.nil?
            end
          end
          if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
            imported_module = @imports.fetch(expression.receiver.name)
            return imported_module.values.fetch(expression.member).type if imported_module.values.key?(expression.member)
          end
          receiver_type = infer_expression_type(expression.receiver, env:)
          return receiver_type.field(expression.member) if receiver_type.respond_to?(:field)

          raise LoweringError, "unknown member #{expression.member}"
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          index_type = infer_expression_type(expression.index, env:, expected_type: @types.fetch("usize"))
          infer_index_result_type(receiver_type, index_type)
        when AST::UnaryOp
          operand_type = infer_expression_type(expression.operand, env:, expected_type:)
          case expression.operator
          when "not"
            @types.fetch("bool")
          else
            operand_type
          end
        when AST::BinaryOp
          left_type, right_type = infer_binary_operand_types(expression, env:, expected_type: expected_type)

          case expression.operator
          when "and", "or", "<", "<=", ">", ">=", "==", "!="
            @types.fetch("bool")
          when "+", "-", "*", "/"
            pointer_arithmetic_result_type(expression.operator, left_type, right_type) || common_numeric_type(left_type, right_type) || left_type
          when "%"
            common_integer_type(left_type, right_type) || left_type
          else
            left_type
          end
        when AST::IfExpr
          then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
          else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
          then_type = infer_expression_type(expression.then_expression, env: then_env, expected_type: expected_type)
          else_type = infer_expression_type(expression.else_expression, env: else_env, expected_type: expected_type)

          if expected_type &&
             if_expression_branch_compatible?(then_type, expected_type) &&
             if_expression_branch_compatible?(else_type, expected_type)
            return expected_type
          end

          conditional_common_type(then_type, else_type) || raise(LoweringError, "if expression branches require compatible types, got #{then_type} and #{else_type}")
        when AST::Call
          kind, = resolve_callee(expression.callee, env, arguments: expression.arguments)
          case kind
          when :function, :method, :associated_method
            _, _, _, function_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            function_type.return_type
          when :struct_literal, :array
            _, _, _, struct_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            struct_type
          when :addr
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            Types::GenericInstance.new("ref", [argument_type])
          when :value
            infer_value_type(expression.arguments.fetch(0).value, env:)
          when :raw
            Types::GenericInstance.new("ptr", [infer_ref_argument_type(expression.arguments.fetch(0).value, env:)])
          when :cast
            _, _, _, function_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            function_type.return_type
          when :reinterpret
            _, _, _, function_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            function_type.return_type
          when :zero
            _, _, _, function_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            function_type.return_type
          when :result_ok, :result_err
            raise LoweringError, "cannot infer result type for #{kind == :result_ok ? 'ok' : 'err'} without an expected Result[T, E]" unless result_type?(expected_type)

            expected_type
          when :panic
            @types.fetch("void")
          else
            raise LoweringError, "unsupported call kind #{kind}"
          end
        when AST::Specialization
          if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "cast"
            resolve_type_ref(expression.arguments.fetch(0).value)
          else
            raise LoweringError, "unsupported specialization"
          end
        else
          raise LoweringError, "unsupported expression type #{expression.class.name}"
        end
      end

      def infer_binary_operand_types(expression, env:, expected_type: nil)
        propagated_type = propagating_expected_type(expression.operator, expected_type)
        left_type = infer_expression_type(expression.left, env:, expected_type: propagated_type)
        right_env = binary_right_env(expression, env)
        right_expected_type = case expression.operator
                              when "<<", ">>"
                                propagated_type || left_type
                              when "+", "-", "*", "/", "%", "|", "&", "^"
                                left_type
                              else
                                left_type
                              end
        right_type = infer_expression_type(expression.right, env: right_env, expected_type: right_expected_type)
        harmonize_binary_float_literal_types(expression.left, expression.right, left_type, right_type, env: right_env)
      end

      def binary_right_env(expression, env)
        case expression.operator
        when "and"
          env_with_refinements(env, flow_refinements(expression.left, truthy: true, env:))
        when "or"
          env_with_refinements(env, flow_refinements(expression.left, truthy: false, env:))
        else
          env
        end
      end

      def harmonize_binary_float_literal_types(left_expression, right_expression, left_type, right_type, env:)
        if float_literal_expression?(left_expression) && right_type.is_a?(Types::Primitive) && right_type.float?
          left_type = infer_expression_type(left_expression, env:, expected_type: right_type)
        end

        if float_literal_expression?(right_expression) && left_type.is_a?(Types::Primitive) && left_type.float?
          right_type = infer_expression_type(right_expression, env:, expected_type: left_type)
        end

        [left_type, right_type]
      end

      def float_literal_expression?(expression)
        expression.is_a?(AST::FloatLiteral) ||
          (expression.is_a?(AST::UnaryOp) && ["+", "-"].include?(expression.operator) && float_literal_expression?(expression.operand))
      end

      def propagating_expected_type(operator, expected_type)
        case operator
        when "+", "-", "*", "/", "%", "<<", ">>"
          return expected_type if expected_type.is_a?(Types::Primitive) && expected_type.numeric?
        when "|", "&", "^"
          return expected_type if expected_type.is_a?(Types::Primitive) && expected_type.integer?
          return expected_type if expected_type.is_a?(Types::Flags)
        end

        nil
      end

      def promoted_binary_operand_type(operator, left_type, right_type)
        case operator
        when "+", "-", "*", "/", "<", "<=", ">", ">=", "==", "!="
          common_numeric_type(left_type, right_type)
        when "%"
          common_integer_type(left_type, right_type)
        end
      end

      def cast_expression(expression, target_type)
        return expression if expression.type == target_type

        IR::Cast.new(target_type:, expression:, type: target_type)
      end

      def common_numeric_type(left_type, right_type)
        return left_type if left_type == right_type
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.numeric? && right_type.numeric?

        return common_integer_type(left_type, right_type) if left_type.integer? && right_type.integer?
        return wider_float_type(left_type, right_type) if left_type.float? && right_type.float?

        float_type, integer_type = left_type.float? ? [left_type, right_type] : [right_type, left_type]
        return unless integer_type.integer? && integer_type.fixed_width_integer?

        float_type
      end

      def common_integer_type(left_type, right_type)
        return left_type if left_type == right_type
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.integer? && right_type.integer?
        return unless left_type.fixed_width_integer? && right_type.fixed_width_integer?
        return unless left_type.signed_integer? == right_type.signed_integer?

        left_type.integer_width >= right_type.integer_width ? left_type : right_type
      end

      def wider_float_type(left_type, right_type)
        left_type.float_width >= right_type.float_width ? left_type : right_type
      end

      def pointer_arithmetic_result_type(operator, left_type, right_type)
        return left_type if pointer_type?(left_type) && integer_type?(right_type) && (operator == "+" || operator == "-")
        return right_type if operator == "+" && integer_type?(left_type) && pointer_type?(right_type)

        nil
      end

      def resolve_type_expression(expression)
        case expression
        when AST::Identifier
          @types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)
          return nil unless @imports.key?(expression.receiver.name)

          @imports.fetch(expression.receiver.name).types[expression.member]
        end
      end

      def resolve_type_member(type, name)
        case type
        when Types::Enum, Types::Flags
          type.member(name)
        end
      end

      def function_type_for_name(name)
        binding = @functions.fetch(name)
        raise LoweringError, "generic function #{name} cannot be used as a value" if binding.type_params.any?

        binding.type
      end

      def resolve_specialized_function_binding(expression)
        binding = case expression.callee
                  when AST::Identifier
                    @functions[expression.callee.name]
                  when AST::MemberAccess
                    if expression.callee.receiver.is_a?(AST::Identifier) && @imports.key?(expression.callee.receiver.name)
                      @imports.fetch(expression.callee.receiver.name).functions[expression.callee.member]
                    end
                  end
        return nil unless binding

        type_arguments = resolve_specialization_type_arguments(expression)
        instantiate_function_binding(binding, type_arguments)
      end

      def resolve_specialization_type_arguments(expression)
        expression.arguments.map do |argument|
          raise LoweringError, "callable specialization arguments must be types" unless argument.value.is_a?(AST::TypeRef)

          resolve_type_ref(argument.value)
        end
      end

      def specialize_function_binding(binding, arguments, env)
        return binding if binding.type_params.empty?
        raise LoweringError, "generic function #{binding.name} must be called" unless arguments

        type_arguments = infer_function_type_arguments(binding, arguments, env)
        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding(binding, type_arguments)
        if binding.type_params.empty?
          raise LoweringError, "function #{binding.name} is not generic and cannot be specialized"
        end

        unless binding.type_params.length == type_arguments.length
          raise LoweringError, "function #{binding.name} expects #{binding.type_params.length} type arguments, got #{type_arguments.length}"
        end

        if type_arguments.any? { |type_argument| contains_ref_type?(type_argument) }
          raise LoweringError, "generic function #{binding.name} cannot be instantiated with ref types"
        end

        key = type_arguments.freeze
        return binding.instances.fetch(key) if binding.instances.key?(key)

        substitutions = binding.type_params.zip(type_arguments).to_h
        instance = Sema::FunctionBinding.new(
          name: binding.name,
          type: substitute_type(binding.type, substitutions),
          body_params: binding.body_params.map { |param| substitute_value_binding(param, substitutions) },
          ast: binding.ast,
          external: binding.external,
          type_params: [].freeze,
          instances: {},
          type_arguments: key,
          owner: binding.owner,
          type_substitutions: substitutions.freeze,
        )
        binding.instances[key] = instance
      end

      def infer_function_type_arguments(binding, arguments, env)
        expected_params = binding.type.params
        unless call_arity_matches?(binding.type, arguments.length)
          raise LoweringError, arity_error_message(binding.type, binding.name, arguments.length)
        end

        substitutions = {}
        expected_params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          actual_type = infer_expression_type(argument.value, env:)
          collect_type_substitutions(parameter.type, actual_type, substitutions, binding.name)
        end

        binding.type_params.map do |name|
          inferred = substitutions[name]
          raise LoweringError, "cannot infer type argument #{name} for function #{binding.name}" unless inferred

          inferred
        end
      end

      def call_arity_matches?(function_type, actual_count)
        return actual_count >= function_type.params.length if function_type.variadic

        actual_count == function_type.params.length
      end

      def arity_error_message(function_type, name, actual_count)
        if function_type.variadic
          "function #{name} expects at least #{function_type.params.length} arguments, got #{actual_count}"
        else
          "function #{name} expects #{function_type.params.length} arguments, got #{actual_count}"
        end
      end

      def collect_type_substitutions(pattern_type, actual_type, substitutions, function_name)
        case pattern_type
        when Types::TypeVar
          existing = substitutions[pattern_type.name]
          if existing && existing != actual_type
            raise LoweringError, "conflicting type argument #{pattern_type.name} for function #{function_name}: got #{existing} and #{actual_type}"
          end

          substitutions[pattern_type.name] ||= actual_type
        when Types::Nullable
          candidate = actual_type.is_a?(Types::Nullable) ? actual_type.base : actual_type
          collect_type_substitutions(pattern_type.base, candidate, substitutions, function_name)
        when Types::GenericInstance
          return unless actual_type.is_a?(Types::GenericInstance)
          return unless actual_type.name == pattern_type.name && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            next if expected_argument.is_a?(Types::LiteralTypeArg)

            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Span
          return unless actual_type.is_a?(Types::Span)

          collect_type_substitutions(pattern_type.element_type, actual_type.element_type, substitutions, function_name)
        when Types::Result
          return unless actual_type.is_a?(Types::Result)

          collect_type_substitutions(pattern_type.ok_type, actual_type.ok_type, substitutions, function_name)
          collect_type_substitutions(pattern_type.error_type, actual_type.error_type, substitutions, function_name)
        when Types::StructInstance
          return unless actual_type.is_a?(Types::StructInstance)
          return unless actual_type.definition == pattern_type.definition && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Function
          return unless actual_type.is_a?(Types::Function)
          return unless actual_type.params.length == pattern_type.params.length

          pattern_type.params.zip(actual_type.params).each do |expected_param, actual_param|
            collect_type_substitutions(expected_param.type, actual_param.type, substitutions, function_name)
          end
          collect_type_substitutions(pattern_type.return_type, actual_type.return_type, substitutions, function_name)
        end
      end

      def substitute_value_binding(binding, substitutions)
        Sema::ValueBinding.new(
          name: binding.name,
          storage_type: substitute_type(binding.storage_type, substitutions),
          flow_type: binding.flow_type ? substitute_type(binding.flow_type, substitutions) : nil,
          mutable: binding.mutable,
          kind: binding.kind,
        )
      end

      def substitute_type(type, substitutions)
        case type
        when Types::TypeVar
          substitutions.fetch(type.name, type)
        when Types::Nullable
          Types::Nullable.new(substitute_type(type.base, substitutions))
        when Types::GenericInstance
          Types::GenericInstance.new(
            type.name,
            type.arguments.map { |argument| argument.is_a?(Types::LiteralTypeArg) ? argument : substitute_type(argument, substitutions) },
          )
        when Types::Span
          Types::Span.new(substitute_type(type.element_type, substitutions))
        when Types::Result
          Types::Result.new(substitute_type(type.ok_type, substitutions), substitute_type(type.error_type, substitutions))
        when Types::StructInstance
          type.definition.instantiate(type.arguments.map { |argument| substitute_type(argument, substitutions) })
        when Types::Function
          Types::Function.new(
            type.name,
            params: type.params.map { |param| Types::Parameter.new(param.name, substitute_type(param.type, substitutions), mutable: param.mutable) },
            return_type: substitute_type(type.return_type, substitutions),
            receiver_type: type.receiver_type ? substitute_type(type.receiver_type, substitutions) : nil,
            receiver_mutable: type.receiver_mutable,
            variadic: type.variadic,
            external: type.external,
          )
        else
          type
        end
      end

      def pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
      end

      def ref_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ref" && type.arguments.length == 1
      end

      def range_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "range"
      end

      def result_type?(type)
        type.is_a?(Types::Result)
      end

      def array_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
          type.arguments[1].is_a?(Types::LiteralTypeArg)
      end

      def array_element_type(type)
        return unless array_type?(type)

        type.arguments.first
      end

      def array_length(type)
        return unless array_type?(type)

        type.arguments[1].value
      end

      def addressable_storage_expression?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          addressable_storage_expression?(expression.receiver)
        when AST::Call
          value_call?(expression)
        else
          false
        end
      end

      def value_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "value"
      end

      def infer_value_type(handle_expression, env:)
        handle_type = infer_expression_type(handle_expression, env:)
        return referenced_type(handle_type) if ref_type?(handle_type)

        pointee_type(handle_type) || raise(LoweringError, "value expects ref[...] or ptr[...], got #{handle_type}")
      end

      def infer_ref_argument_type(handle_expression, env:)
        handle_type = infer_expression_type(handle_expression, env:)
        return referenced_type(handle_type) if ref_type?(handle_type)

        raise LoweringError, "raw expects ref[...] argument, got #{handle_type}"
      end

      def collection_loop_type(type)
        return array_element_type(type) if array_type?(type)
        return type.element_type if type.is_a?(Types::Span)

        nil
      end

      def infer_range_loop_type(expression, env:)
        start_expr = expression.arguments[0].value
        stop_expr = expression.arguments[1].value
        start_type = infer_expression_type(start_expr, env:)
        stop_type = infer_expression_type(stop_expr, env:)

        if start_type != stop_type
          if start_expr.is_a?(AST::IntegerLiteral)
            start_type = infer_expression_type(start_expr, env:, expected_type: stop_type)
          elsif stop_expr.is_a?(AST::IntegerLiteral)
            stop_type = infer_expression_type(stop_expr, env:, expected_type: start_type)
          end
        end

        raise LoweringError, "range bounds must use matching integer types, got #{start_type} and #{stop_type}" unless start_type == stop_type

        start_type
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def infer_index_result_type(receiver_type, index_type)
        raise LoweringError, "index must be an integer type, got #{index_type}" unless integer_type?(index_type)

        receiver_type = referenced_type(receiver_type) if ref_type?(receiver_type)

        if array_type?(receiver_type)
          return array_element_type(receiver_type)
        end

        if receiver_type.is_a?(Types::Span)
          return receiver_type.element_type
        end

        if pointer_type?(receiver_type)
          return pointee_type(receiver_type)
        end

        raise LoweringError, "cannot index #{receiver_type}"
      end

      def pointee_type(type)
        return unless pointer_type?(type)

        type.arguments.first
      end

      def referenced_type(type)
        return unless ref_type?(type)

        type.arguments.first
      end

      def contains_ref_type?(type)
        case type
        when Types::Nullable
          contains_ref_type?(type.base)
        when Types::GenericInstance
          return true if ref_type?(type)

          type.arguments.any? { |argument| !argument.is_a?(Types::LiteralTypeArg) && contains_ref_type?(argument) }
        when Types::Span
          contains_ref_type?(type.element_type)
        when Types::Result
          contains_ref_type?(type.ok_type) || contains_ref_type?(type.error_type)
        when Types::StructInstance
          type.arguments.any? { |argument| contains_ref_type?(argument) }
        when Types::Function
          type.params.any? { |param| contains_ref_type?(param.type) } ||
            contains_ref_type?(type.return_type) ||
            (type.receiver_type && contains_ref_type?(type.receiver_type))
        else
          false
        end
      end

      def pointer_to(type)
        Types::GenericInstance.new("ptr", [type])
      end

      def analysis_for_module(module_name)
        @program.analyses_by_module_name.fetch(module_name)
      end

      def resolve_type_ref_for_analysis(type_ref, analysis)
        saved_analysis = @analysis
        saved_module_name = @module_name
        saved_module_prefix = @module_prefix
        saved_imports = @imports
        saved_types = @types
        saved_values = @values
        saved_functions = @functions

        @analysis = analysis
        @module_name = analysis.module_name
        @module_prefix = @module_name.tr(".", "_")
        @imports = analysis.imports
        @types = analysis.types
        @values = analysis.values
        @functions = analysis.functions
        resolve_type_ref(type_ref)
      ensure
        @analysis = saved_analysis
        @module_name = saved_module_name
        @module_prefix = saved_module_prefix
        @imports = saved_imports
        @types = saved_types
        @values = saved_values
        @functions = saved_functions
      end

      def current_type_params
        @current_type_substitutions || {}
      end

      def resolve_type_ref(type_ref, type_params: current_type_params)
        if type_ref.is_a?(AST::FunctionType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:), mutable: param.mutable)
          end
          return Types::Function.new(nil, params:, return_type: resolve_type_ref(type_ref.return_type, type_params:))
        end

        parts = type_ref.name.parts
        base = if type_ref.arguments.any?
                 name = parts.join(".")
                 args = type_ref.arguments.map do |argument|
                   if argument.value.is_a?(AST::TypeRef)
                     resolve_type_ref(argument.value, type_params:)
                   else
                     Types::LiteralTypeArg.new(argument.value.value)
                   end
                 end
                 if name != "ref" && args.any? { |argument| contains_ref_type?(argument) }
                   raise LoweringError, "ref types cannot be nested inside #{name}"
                 end
                 if name == "Result"
                   validate_generic_type!(name, args)
                   Types::Result.new(args.fetch(0), args.fetch(1))
                 elsif (generic_type = resolve_named_generic_type(parts))
                   generic_type.instantiate(args)
                 elsif name == "span"
                   Types::Span.new(args.fetch(0))
                 else
                   validate_generic_type!(name, args)
                   Types::GenericInstance.new(name, args)
                 end
               elsif parts.length == 1 && type_params.key?(parts.first)
                 type_params.fetch(parts.first)
               elsif parts.length == 1
                 type = @types.fetch(parts.first)
                 raise LoweringError, "generic type #{parts.first} requires type arguments" if type.is_a?(Types::GenericStructDefinition)

                 type
               elsif parts.length == 2 && @imports.key?(parts.first)
                 type = @imports.fetch(parts.first).types.fetch(parts.last)
                 raise LoweringError, "generic type #{type_ref.name} requires type arguments" if type.is_a?(Types::GenericStructDefinition)

                 type
               else
                 raise LoweringError, "unknown type #{type_ref.name}"
               end

        raise LoweringError, "ref types are non-null and cannot be nullable" if type_ref.nullable && ref_type?(base)

        type_ref.nullable ? Types::Nullable.new(base) : base
      end

      def lookup_value(name, env)
        env[:scopes].reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        if @values.key?(name)
          binding = @values.fetch(name)
          { type: binding.type, storage_type: binding.storage_type, c_name: constant_c_name(name), mutable: false, pointer: false }
        end
      end

      def local_binding(type:, c_name:, mutable:, pointer:, storage_type: nil)
        { type:, storage_type: storage_type || type, c_name:, mutable:, pointer: }
      end

      def current_actual_scope(scopes)
        scopes.reverse_each do |scope|
          return scope unless scope.is_a?(Sema::FlowScope)
        end

        raise LoweringError, "missing lexical scope"
      end

      def env_with_refinements(env, refinements)
        updated = env.dup
        updated[:scopes] = scopes_with_refinements(env[:scopes], refinements)
        updated
      end

      def scopes_with_refinements(scopes, refinements)
        return scopes if refinements.nil? || refinements.empty?

        base_scopes = scopes.last.is_a?(Sema::FlowScope) ? scopes[0...-1] : scopes
        merged_refinements = scopes.last.is_a?(Sema::FlowScope) ? scopes.last.each_with_object({}) { |(name, binding), result| result[name] = binding[:type] } : {}
        merged_refinements = merge_refinements(merged_refinements, refinements)
        flow_scope = Sema::FlowScope.new

        merged_refinements.each do |name, refined_type|
          binding = lookup_value(name, { scopes: base_scopes })
          next unless binding

          flow_scope[name] = binding.merge(type: refined_type)
        end

        return base_scopes if flow_scope.empty?

        base_scopes + [flow_scope]
      end

      def merge_refinements(existing, incoming)
        merged = existing.dup
        incoming.each do |name, refined_type|
          if merged.key?(name) && merged[name] != refined_type
            merged.delete(name)
          else
            merged[name] = refined_type
          end
        end

        merged
      end

      def flow_refinements(expression, truthy:, env:)
        case expression
        when AST::UnaryOp
          return flow_refinements(expression.operand, truthy: !truthy, env:) if expression.operator == "not"
        when AST::BinaryOp
          case expression.operator
          when "and"
            if truthy
              left_truthy = flow_refinements(expression.left, truthy: true, env:)
              right_env = env_with_refinements(env, left_truthy)
              right_truthy = flow_refinements(expression.right, truthy: true, env: right_env)
              return merge_refinements(left_truthy, right_truthy)
            end
          when "or"
            unless truthy
              left_falsy = flow_refinements(expression.left, truthy: false, env:)
              right_env = env_with_refinements(env, left_falsy)
              right_falsy = flow_refinements(expression.right, truthy: false, env: right_env)
              return merge_refinements(left_falsy, right_falsy)
            end
          when "==", "!="
            return null_test_refinements(expression, truthy:, env:)
          end
        end

        {}
      end

      def null_test_refinements(expression, truthy:, env:)
        identifier_expression = nil
        if expression.left.is_a?(AST::Identifier) && expression.right.is_a?(AST::NullLiteral)
          identifier_expression = expression.left
        elsif expression.left.is_a?(AST::NullLiteral) && expression.right.is_a?(AST::Identifier)
          identifier_expression = expression.right
        else
          return {}
        end

        binding = lookup_value(identifier_expression.name, env)
        return {} unless binding && binding[:storage_type].is_a?(Types::Nullable)

        null_result = expression.operator == "==" ? truthy : !truthy
        refined_type = null_result ? null_type : binding[:storage_type].base
        { identifier_expression.name => refined_type }
      end

      def block_always_terminates?(statements)
        statements.any? { |statement| statement_always_terminates?(statement) }
      end

      def statement_always_terminates?(statement)
        case statement
        when AST::ReturnStmt, AST::BreakStmt, AST::ContinueStmt
          true
        when AST::IfStmt
          statement.else_body && statement.branches.all? { |branch| block_always_terminates?(branch.body) } && block_always_terminates?(statement.else_body)
        when AST::MatchStmt
          statement.arms.all? { |arm| block_always_terminates?(arm.body) }
        when AST::UnsafeStmt
          block_always_terminates?(statement.body)
        else
          false
        end
      end

      def conditional_common_type(then_type, else_type)
        return then_type if then_type == else_type

        numeric_type = common_numeric_type(then_type, else_type)
        return numeric_type if numeric_type

        if then_type == null_type && nullable_candidate?(else_type)
          return Types::Nullable.new(else_type)
        end

        if else_type == null_type && nullable_candidate?(then_type)
          return Types::Nullable.new(then_type)
        end

        return then_type if then_type.is_a?(Types::Nullable) && else_type == then_type.base
        return else_type if else_type.is_a?(Types::Nullable) && then_type == else_type.base

        nil
      end

      def if_expression_branch_compatible?(actual_type, expected_type)
        return true if actual_type == expected_type
        return true if actual_type == null_type && expected_type.is_a?(Types::Nullable)
        return true if expected_type.is_a?(Types::Nullable) && actual_type == expected_type.base
        return true if common_numeric_type(actual_type, expected_type) == expected_type

        false
      end

      def nullable_candidate?(type)
        !ref_type?(type) && type != @types.fetch("void")
      end

      def null_type
        @null_type ||= Types::Nullable.new(@types.fetch("void"))
      end

      def loop_flow(break_label:, continue_label:, break_defers: [], continue_defers: [])
        {
          break_label:,
          continue_label:,
          break_defers:,
          continue_defers:,
        }
      end

      def nested_loop_flow(current_loop_flow, local_defers)
        return nil unless current_loop_flow

        loop_flow(
          break_label: current_loop_flow[:break_label],
          continue_label: current_loop_flow[:continue_label],
          break_defers: current_loop_flow[:break_defers] + local_defers,
          continue_defers: current_loop_flow[:continue_defers] + local_defers,
        )
      end

      def cleanup_statements(local_defers, outer_defers)
        local_defers.reverse.concat(outer_defers.reverse).map do |expression|
          IR::ExpressionStmt.new(expression:)
        end
      end

      def lower_loop_exit(label, local_defers, outer_defers)
        cleanup_statements(local_defers, outer_defers) + [IR::GotoStmt.new(label:)]
      end

      def terminating_ir_statement?(statement)
        statement.is_a?(IR::ReturnStmt) || statement.is_a?(IR::GotoStmt)
      end

      def empty_env
        { scopes: [{}], counter: 0 }
      end

      def duplicate_env(env)
        { scopes: env[:scopes].map(&:dup) + [{}], counter: env[:counter] }
      end

      def c_type_name(type)
        return type.name if type.module_name&.start_with?("std.c.")
        return type.name if type.module_name.nil?

        "#{type.module_name.tr('.', '_')}_#{type.name}"
      end

      def resolve_named_generic_type(parts)
        if parts.length == 1
          type = @types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition)
        elsif parts.length == 2 && @imports.key?(parts.first)
          type = @imports.fetch(parts.first).types[parts.last]
          return type if type.is_a?(Types::GenericStructDefinition)
        end

        nil
      end

      def type_ref_from_specialization(expression)
        case expression.callee
        when AST::Identifier
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: [expression.callee.name]), arguments: expression.arguments, nullable: false)
        when AST::MemberAccess
          return nil unless expression.callee.receiver.is_a?(AST::Identifier)

          AST::TypeRef.new(
            name: AST::QualifiedName.new(parts: [expression.callee.receiver.name, expression.callee.member]),
            arguments: expression.arguments,
            nullable: false,
          )
        end
      end

      def validate_generic_type!(name, arguments)
        case name
        when "ptr"
          raise LoweringError, "ptr requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "ptr type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "ref"
          raise LoweringError, "ref requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "ref type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "ref cannot target void" if arguments.first.is_a?(Types::Primitive) && arguments.first.void?
          raise LoweringError, "ref cannot target another ref type" if contains_ref_type?(arguments.first)
        when "span"
          raise LoweringError, "span requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "span element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "array"
          raise LoweringError, "array requires exactly two type arguments" unless arguments.length == 2
          raise LoweringError, "array element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "array length must be an integer literal" unless arguments[1].is_a?(Types::LiteralTypeArg) && arguments[1].value.is_a?(Integer)
          raise LoweringError, "array length must be positive" unless arguments[1].value.positive?
        when "Result"
          raise LoweringError, "Result requires exactly two type arguments" unless arguments.length == 2
          raise LoweringError, "Result ok type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "Result error type must be a type" if arguments[1].is_a?(Types::LiteralTypeArg)
        else
          raise LoweringError, "unknown generic type #{name}"
        end
      end

      def enum_member_c_name(type, member_name)
        "#{c_type_name(type)}_#{member_name}"
      end

      def local_named_type?(type)
        type.respond_to?(:module_name) && (type.module_name == @module_name || type.module_name.nil?)
      end

      def function_binding_c_name(binding, module_name:, receiver_type: nil)
        return "main" if receiver_type.nil? && binding.name == "main" && binding.type_arguments.empty?
        return "#{c_type_name(receiver_type)}_#{binding.name}" if receiver_type

        module_function_c_name(module_name, binding.name, type_arguments: binding.type_arguments)
      end

      def constant_c_name(name)
        module_constant_c_name(@module_name, name)
      end

      def imported_value_c_name(imported_module, name)
        imported_analysis = analysis_for_module(imported_module.name)
        return name if imported_analysis.module_kind == :extern_module

        module_constant_c_name(imported_module.name, name)
      end

      def module_function_c_name(module_name, name, type_arguments: [])
        base = "#{module_name.tr('.', '_')}_#{name}"
        return base if type_arguments.empty?

        "#{base}_#{sanitize_identifier(type_arguments.join('_'))}"
      end

      def module_constant_c_name(module_name, name)
        "#{module_name.tr('.', '_')}_#{name}"
      end

      def c_local_name(name)
        name
      end

      def fresh_c_temp_name(env, prefix)
        env[:counter] += 1
        "__mt_#{prefix}_#{env[:counter]}"
      end

      def sanitize_identifier(text)
        identifier = text.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/_+/, "_").sub(/^_+/, "").sub(/_+$/, "")
        identifier.empty? ? "value" : identifier
      end
    end
  end
end
