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
        @current_analysis_path = nil
        @module_name = nil
        @module_prefix = nil
        @imports = {}
        @types = {}
        @values = {}
        @functions = {}
        @struct_types = {}
        @union_types = {}
        @variant_types = {}
        @synthetic_structs = []
        @synthetic_functions = []
        @synthetic_proc_counter = 0
        @synthetic_format_counter = 0
        @format_builder_cache = {}
        @method_definitions = build_method_definitions
      end

      def lower
        if @program.root_analysis.module_kind == :extern_module
          raise LoweringError, "cannot emit C for extern module #{@program.root_analysis.module_name}"
        end

        includes = collect_includes

        constants = []
        globals = []
        opaques = []
        structs = []
        unions = []
        enums = []
        static_asserts = []
        functions = []

        @program.analyses_by_path.each_pair do |path, analysis|
          next if analysis.module_kind == :extern_module

          prepare_analysis(analysis, source_path: path)
          collect_structs

          constants.concat(lower_constants)
          globals.concat(lower_globals)
          opaques.concat(lower_opaques)
          structs.concat(lower_structs)
          unions.concat(lower_unions)
          enums.concat(lower_enums)
          static_asserts.concat(lower_static_asserts)
          functions.concat(lower_functions)
        end

        opaques.concat(lower_imported_external_opaques)
        structs.concat(@synthetic_structs)
        functions.concat(@synthetic_functions)

        IR::Program.new(
          module_name: @program.root_analysis.module_name,
          includes:,
          constants:,
          globals:,
          opaques:,
          structs:,
          unions:,
          enums:,
          variants: lower_variants,
          static_asserts:,
          functions:,
          source_path: @program.root_path,
        )
      end

      private

      def collect_structs
        @analysis.ast.declarations.each do |decl|
          case decl
          when AST::OpaqueDecl
            @opaque_types[decl.name] = @types.fetch(decl.name)
          when AST::StructDecl
            @struct_types[decl.name] = @types.fetch(decl.name)
          when AST::UnionDecl
            @union_types[decl.name] = @types.fetch(decl.name)
          when AST::VariantDecl
            @variant_types[decl.name] = @types.fetch(decl.name)
          end
        end
      end

      def collect_includes
        headers = ["<stdbool.h>", "<stdint.h>", "<stdlib.h>", "<string.h>"]
        headers << "<stddef.h>" if program_uses_offsetof?
        if program_uses_panic?
          headers << "<stdio.h>"
        end

        @program.analyses_by_module_name.each_value do |analysis|
          next unless analysis.module_kind == :extern_module

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
        %w[stdbool.h stdint.h stdlib.h string.h stddef.h stdio.h].include?(header_name)
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
        when AST::AwaitExpr
          expression_uses_panic?(expression.expression)
        when AST::Call
          identifier = expression.callee
          return true if identifier.is_a?(AST::Identifier) && identifier.name == "panic"

          expression_uses_panic?(expression.callee) || expression.arguments.any? { |argument| expression_uses_panic?(argument.value) }
        when AST::BinaryOp
          expression_uses_panic?(expression.left) || expression_uses_panic?(expression.right)
        when AST::RangeExpr
          expression_uses_panic?(expression.start_expr) || expression_uses_panic?(expression.end_expr)
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
        when AST::AwaitExpr
          expression_uses_offsetof?(expression.expression)
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
        when AST::RangeExpr
          expression_uses_offsetof?(expression.start_expr) || expression_uses_offsetof?(expression.end_expr)
        when AST::Specialization
          expression_uses_offsetof?(expression.callee) || expression.arguments.any? { |argument| expression_uses_offsetof?(argument.value) }
        else
          false
        end
      end

      def prepare_analysis(analysis, source_path: nil)
        @analysis = analysis
        @current_analysis_path = source_path
        @module_name = analysis.module_name
        @module_prefix = @module_name.tr(".", "_")
        @imports = analysis.imports
        @types = analysis.types
        @values = analysis.values
        @functions = analysis.functions
        @opaque_types = {}
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
          IR::Constant.new(name: decl.name, c_name: value_c_name(decl.name), type:, value:)
        end
      end

      def lower_globals
        @analysis.ast.declarations.grep(AST::VarDecl).map do |decl|
          type = @values.fetch(decl.name).type
          value = if decl.value
                    lower_static_storage_initializer(decl.value, env: empty_env, expected_type: type)
                  else
                    IR::ZeroInit.new(type: type)
                  end
          IR::Global.new(name: decl.name, c_name: value_c_name(decl.name), type:, value:)
        end
      end

      def lower_opaques
        @analysis.ast.declarations.grep(AST::OpaqueDecl).map do |decl|
          opaque_type = @opaque_types.fetch(decl.name)
          IR::OpaqueDecl.new(
            name: decl.name,
            c_name: opaque_c_type_name(opaque_type),
            forward_declarable: opaque_forward_declarable?(opaque_type),
          )
        end
      end

      def lower_imported_external_opaques
        @program.analyses_by_module_name.each_value.flat_map do |analysis|
          next [] unless analysis.module_kind == :extern_module

          analysis.ast.declarations.grep(AST::OpaqueDecl).filter_map do |decl|
            opaque_type = analysis.types.fetch(decl.name)
            next unless forward_declarable_external_opaque?(opaque_type)

            IR::OpaqueDecl.new(name: decl.name, c_name: opaque_c_type_name(opaque_type), forward_declarable: true)
          end
        end.uniq { |decl| decl.c_name }
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

      def lower_variants
        @analysis.ast.declarations.filter_map do |decl|
          next unless decl.is_a?(AST::VariantDecl)

          variant_type = @types.fetch(decl.name)
          next if variant_type.is_a?(Types::GenericVariantDefinition)

          outer_c = c_type_name(variant_type)
          arms = decl.arms.map do |arm|
            arm_c = "#{outer_c}_#{arm.name}"
            fields = arm.fields.map do |field|
              field_type = variant_type.arm(arm.name).fetch(field.name)
              IR::Field.new(name: field.name, type: field_type)
            end
            IR::VariantArm.new(name: arm.name, c_name: arm_c, fields:)
          end
          IR::VariantDecl.new(name: decl.name, c_name: outer_c, arms:)
        end
      end

      def lower_functions
        lowered = []
        lowered_function_c_names = {}

        changed = true
        while changed
          changed = false

          @analysis.ast.declarations.each do |decl|
            case decl
            when AST::FunctionDef
              binding = @functions.fetch(decl.name)
              if binding.type_params.any?
                binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                  c_name = function_binding_c_name(instance, module_name: @module_name)
                  next if lowered_function_c_names[c_name]

                  lowered << lower_function_decl(instance)
                  lowered_function_c_names[c_name] = true
                  changed = true
                end
              else
                c_name = function_binding_c_name(binding, module_name: @module_name)
                next if lowered_function_c_names[c_name]

                lowered << lower_function_decl(binding)
                lowered_function_c_names[c_name] = true
                changed = true
              end
            when AST::MethodsBlock
              receiver_type = resolve_methods_receiver_type(@analysis, decl.type_name)
              decl.methods.each do |method|
                binding = @analysis.methods.fetch(receiver_type).fetch(method.name)
                if binding.type_params.any?
                  binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                    c_name = function_binding_c_name(instance, module_name: @module_name, receiver_type:)
                    next if lowered_function_c_names[c_name]

                    lowered << lower_function_decl(instance, receiver_type:)
                    lowered_function_c_names[c_name] = true
                    changed = true
                  end
                else
                  c_name = function_binding_c_name(binding, module_name: @module_name, receiver_type:)
                  next if lowered_function_c_names[c_name]

                  lowered << lower_function_decl(binding, receiver_type:)
                  lowered_function_c_names[c_name] = true
                  changed = true
                end
              end
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

        return lower_async_function_decl(binding, receiver_type:) if binding.async

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
            env[:scopes].last[param_binding.name] = local_binding(type:, c_name:, mutable: false, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param_binding.name,
              c_name:,
              type:,
              value: IR::Name.new(name: input_c_name, type:, pointer: false),
            )
          else
            env[:scopes].last[param_binding.name] = local_binding(type:, c_name:, mutable: false, pointer: false)
            params << IR::Param.new(name: param_binding.name, c_name:, type:, pointer: false)
          end
        end

        return_type = binding.type.return_type
        body = lower_block(decl.body, env:, active_defers: [], return_type:, loop_flow: nil, allow_return: true)
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

      def lower_async_function_decl(binding, receiver_type: nil)
        decl = binding.ast
        normalized_statements = normalize_async_body(binding, decl.body)
        constructor_c_name = function_binding_c_name(binding, module_name: @module_name, receiver_type:)
        frame_c_name = "#{constructor_c_name}__frame"
        resume_c_name = "#{constructor_c_name}__resume"
        ready_c_name = "#{constructor_c_name}__ready"
        set_waiter_c_name = "#{constructor_c_name}__set_waiter"
        release_c_name = "#{constructor_c_name}__release"
        take_result_c_name = "#{constructor_c_name}__take_result"

        async_info = analyze_async_function(binding, normalized_statements)
        frame_type = build_async_frame_type(frame_c_name, async_info)

        @synthetic_structs << IR::StructDecl.new(
          name: frame_c_name,
          c_name: frame_c_name,
          fields: frame_type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
          packed: false,
          alignment: nil,
        )
        @synthetic_functions << build_async_resume_function(binding, normalized_statements, frame_type, resume_c_name, async_info)
        @synthetic_functions << build_async_ready_function(frame_type, ready_c_name, async_info)
        @synthetic_functions << build_async_set_waiter_function(frame_type, set_waiter_c_name, async_info)
        @synthetic_functions << build_async_release_function(frame_type, release_c_name, async_info)
        @synthetic_functions << build_async_take_result_function(frame_type, take_result_c_name, async_info)

        if decl.name == "main" && binding.type_arguments.empty?
          @synthetic_functions << build_async_constructor_function(
            binding,
            decl,
            frame_type,
            constructor_c_name,
            resume_c_name,
            ready_c_name,
            set_waiter_c_name,
            release_c_name,
            take_result_c_name,
            async_info,
          )

          return build_async_main_entrypoint(binding, constructor_c_name, async_info)
        end

        build_async_constructor_function(
          binding,
          decl,
          frame_type,
          constructor_c_name,
          resume_c_name,
          ready_c_name,
          set_waiter_c_name,
          release_c_name,
          take_result_c_name,
          async_info,
        )
      end

      def build_async_main_entrypoint(binding, constructor_c_name, async_info)
        libuv_async = analysis_for_module("std.libuv.async")
        loop_type = analysis_for_module("std.libuv.runtime").types.fetch("Loop")
        task_type = async_info[:task_type]
        body = []

        loop_name = "__mt_loop"
        task_name = "__mt_task"
        status_name = "__mt_status"
        result_name = "__mt_result"

        loop_expr = IR::Name.new(name: loop_name, type: loop_type, pointer: false)
        task_expr = IR::Name.new(name: task_name, type: task_type, pointer: false)

        body << IR::LocalDecl.new(
          name: loop_name,
          c_name: loop_name,
          type: loop_type,
          value: IR::Call.new(
            callee: module_function_c_name(libuv_async.module_name, "must_create_loop"),
            arguments: [],
            type: loop_type,
          ),
        )
        body << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: module_function_c_name(libuv_async.module_name, "activate_current_loop"),
            arguments: [loop_expr],
            type: @types.fetch("void"),
          ),
        )
        body << IR::LocalDecl.new(
          name: task_name,
          c_name: task_name,
          type: task_type,
          value: IR::Call.new(callee: constructor_c_name, arguments: [], type: task_type),
        )
        body << IR::WhileStmt.new(
          condition: IR::Unary.new(
            operator: "not",
            operand: IR::Call.new(
              callee: IR::Member.new(receiver: task_expr, member: "ready", type: task_type.field("ready")),
              arguments: [IR::Member.new(receiver: task_expr, member: "frame", type: task_type.field("frame"))],
              type: @types.fetch("bool"),
            ),
            type: @types.fetch("bool"),
          ),
          body: [
            IR::LocalDecl.new(
              name: status_name,
              c_name: status_name,
              type: @types.fetch("i32"),
              value: IR::Call.new(
                callee: module_function_c_name("std.libuv.runtime", "loop_run_default"),
                arguments: [loop_expr],
                type: @types.fetch("i32"),
              ),
            ),
            IR::IfStmt.new(
              condition: IR::Binary.new(
                operator: "!=",
                left: IR::Name.new(name: status_name, type: @types.fetch("i32"), pointer: false),
                right: IR::IntegerLiteral.new(value: 0, type: @types.fetch("i32")),
                type: @types.fetch("bool"),
              ),
              then_body: [
                IR::ExpressionStmt.new(
                  expression: IR::Call.new(
                    callee: "mt_panic",
                    arguments: [IR::StringLiteral.new(value: "async main loop_run_default failed", type: @types.fetch("cstr"), cstring: true)],
                    type: @types.fetch("void"),
                  ),
                ),
              ],
              else_body: nil,
            ),
          ],
        )

        if async_info[:result_type] == @types.fetch("i32")
          body << IR::LocalDecl.new(
            name: result_name,
            c_name: result_name,
            type: @types.fetch("i32"),
            value: IR::Call.new(
              callee: IR::Member.new(receiver: task_expr, member: "take_result", type: task_type.field("take_result")),
              arguments: [IR::Member.new(receiver: task_expr, member: "frame", type: task_type.field("frame"))],
              type: @types.fetch("i32"),
            ),
          )
        else
          body << IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: IR::Member.new(receiver: task_expr, member: "take_result", type: task_type.field("take_result")),
              arguments: [IR::Member.new(receiver: task_expr, member: "frame", type: task_type.field("frame"))],
              type: @types.fetch("void"),
            ),
          )
        end

        body << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: IR::Member.new(receiver: task_expr, member: "release", type: task_type.field("release")),
            arguments: [IR::Member.new(receiver: task_expr, member: "frame", type: task_type.field("frame"))],
            type: @types.fetch("void"),
          ),
        )
        body << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: module_function_c_name(libuv_async.module_name, "deactivate_current_loop"),
            arguments: [],
            type: @types.fetch("void"),
          ),
        )
        body << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: module_function_c_name(libuv_async.module_name, "must_release_loop"),
            arguments: [IR::AddressOf.new(expression: loop_expr, type: pointer_to(loop_type))],
            type: @types.fetch("void"),
          ),
        )
        body << IR::ReturnStmt.new(
          value: async_info[:result_type] == @types.fetch("i32") ? IR::Name.new(name: result_name, type: @types.fetch("i32"), pointer: false) : IR::IntegerLiteral.new(value: 0, type: @types.fetch("i32")),
        )

        IR::Function.new(
          name: binding.name,
          c_name: "main",
          params: [],
          return_type: @types.fetch("i32"),
          body: body,
          entry_point: true,
        )
      end

      def analyze_async_function(binding, statements)
        env = empty_env
        void_ptr = pointer_to(@types.fetch("void"))
        wake_type = Types::Function.new(
          nil,
          params: [Types::Parameter.new("frame", void_ptr)],
          return_type: @types.fetch("void"),
        )
        param_fields = {}
        local_fields = {}
        await_fields = {}
        await_counter = 0

        binding.body_params.each do |param_binding|
          pointer = binding.type.receiver_type && binding.type.receiver_mutable && param_binding.name == "this"
          field_type = pointer ? pointer_to(param_binding.type) : param_binding.type
          field_name = "param_#{param_binding.name}"
          param_fields[param_binding.name] = {
            field_name:,
            type: field_type,
            param_type: param_binding.type,
            mutable: param_binding.mutable,
            pointer:,
          }
          env[:scopes].last[param_binding.name] = local_binding(
            type: param_binding.type,
            c_name: field_name,
            mutable: param_binding.mutable,
            pointer:,
          )
        end

        statements.each_with_index do |statement, index|
          case statement
          when AST::LocalDecl
            type = statement.type ? resolve_type_ref(statement.type) : infer_expression_type(statement.value, env:)
            local_fields[statement.name] = { field_name: "local_#{statement.name}", type:, mutable: statement.kind == :var }
            if statement.value.is_a?(AST::AwaitExpr)
              await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
            env[:scopes].last[statement.name] = local_binding(type:, c_name: statement.name, mutable: statement.kind == :var, pointer: false)
          when AST::Assignment
            next unless statement.value.is_a?(AST::AwaitExpr)

            await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          when AST::ExpressionStmt
            next unless statement.expression.is_a?(AST::AwaitExpr)

            await_fields[statement.expression.object_id] = build_async_await_field_info(statement.expression, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          when AST::ReturnStmt
            next unless statement.value&.is_a?(AST::AwaitExpr)

            await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
            await_counter += 1
          when AST::IfStmt
            statement.branches.each do |branch|
              await_counter = analyze_async_statements!(branch.body, await_counter, env, param_fields, local_fields, await_fields)
            end
            await_counter = analyze_async_statements!(statement.else_body, await_counter, env, param_fields, local_fields, await_fields) if statement.else_body
          when AST::WhileStmt
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::ForStmt
            # For loops with await need the loop variable in the frame so it survives across suspension
            loop_type = range_iterable?(statement.iterable) ? infer_range_loop_type(statement.iterable, env:) : collection_loop_type(infer_expression_type(statement.iterable, env:))
            local_fields[statement.name] ||= { field_name: "local_#{statement.name}", type: loop_type, mutable: true }
              if range_iterable?(statement.iterable)
                stop_field_name = "local_#{statement.name}_stop"
                local_fields[stop_field_name] ||= { field_name: stop_field_name, type: loop_type, mutable: true }
              end
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::MatchStmt
            statement.arms.each do |arm|
              await_counter = analyze_async_statements!(arm.body, await_counter, env, param_fields, local_fields, await_fields)
            end
          when AST::UnsafeStmt
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::BreakStmt, AST::ContinueStmt, AST::StaticAssert
              nil
          else
            raise LoweringError, "unsupported async statement #{statement.class.name}"
          end
        end

        {
          task_type: binding.type.return_type,
            result_type: binding.body_return_type,
          void_ptr:,
          wake_type:,
          param_fields:,
          local_fields:,
          await_fields:,
        }
      end

      # Recursively scan nested statement bodies for await slots, assigning state IDs.
      # Returns the updated await_counter.
      def analyze_async_statements!(statements, await_counter, env, param_fields, local_fields, await_fields)
        statements.each do |statement|
          case statement
          when AST::LocalDecl
            type = statement.type ? resolve_type_ref(statement.type) : infer_expression_type(statement.value, env:)
            local_fields[statement.name] ||= { field_name: "local_#{statement.name}", type:, mutable: statement.kind == :var }
            if statement.value.is_a?(AST::AwaitExpr)
              await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
            env[:scopes].last[statement.name] = local_binding(type:, c_name: statement.name, mutable: statement.kind == :var, pointer: false)
          when AST::Assignment
            if statement.value.is_a?(AST::AwaitExpr)
              await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
          when AST::ExpressionStmt
            if statement.expression.is_a?(AST::AwaitExpr)
              await_fields[statement.expression.object_id] = build_async_await_field_info(statement.expression, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
          when AST::ReturnStmt
            if statement.value&.is_a?(AST::AwaitExpr)
              await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
          when AST::IfStmt
            statement.branches.each do |branch|
              await_counter = analyze_async_statements!(branch.body, await_counter, env, param_fields, local_fields, await_fields)
            end
            await_counter = analyze_async_statements!(statement.else_body, await_counter, env, param_fields, local_fields, await_fields) if statement.else_body
          when AST::WhileStmt
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::ForStmt
            loop_type = range_iterable?(statement.iterable) ? infer_range_loop_type(statement.iterable, env:) : collection_loop_type(infer_expression_type(statement.iterable, env:))
            local_fields[statement.name] ||= { field_name: "local_#{statement.name}", type: loop_type, mutable: true }
              if range_iterable?(statement.iterable)
                stop_field_name = "local_#{statement.name}_stop"
                local_fields[stop_field_name] ||= { field_name: stop_field_name, type: loop_type, mutable: true }
              end
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::MatchStmt
            statement.arms.each do |arm|
              await_counter = analyze_async_statements!(arm.body, await_counter, env, param_fields, local_fields, await_fields)
            end
          when AST::UnsafeStmt
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          else
            nil
          end
        end
        await_counter
      end

      def build_async_await_field_info(await_expression, await_counter, env:, param_fields:, local_fields:)
        task_expression = await_expression.expression
        reused_field_name = reusable_async_await_task_field_name(task_expression, param_fields:, local_fields:)
        {
          field_name: reused_field_name || "await_#{await_counter}",
          task_type: infer_expression_type(task_expression, env:),
          result_type: infer_expression_type(await_expression, env:),
          state: await_counter + 1,
          reuse_existing_storage: !reused_field_name.nil?,
        }
      end

      def reusable_async_await_task_field_name(task_expression, param_fields:, local_fields:)
        return unless task_expression.is_a?(AST::Identifier)
        return local_fields.fetch(task_expression.name)[:field_name] if local_fields.key?(task_expression.name)
        return param_fields.fetch(task_expression.name)[:field_name] if param_fields.key?(task_expression.name)

        nil
      end

      def build_async_frame_type(frame_c_name, async_info)
        fields = {
          "state" => @types.fetch("i32"),
          "ready" => @types.fetch("bool"),
          "waiter_frame" => async_info[:void_ptr],
          "waiter" => async_info[:wake_type],
        }
        unless async_info[:result_type] == @types.fetch("void")
          fields["result"] = async_info[:result_type]
        end
        async_info[:param_fields].each_value do |field_info|
          fields[field_info[:field_name]] = field_info[:type]
        end
        async_info[:local_fields].each_value do |field_info|
          fields[field_info[:field_name]] = field_info[:type]
        end
        async_info[:await_fields].each_value do |field_info|
          next if fields.key?(field_info[:field_name])

          fields[field_info[:field_name]] = field_info[:task_type]
        end

        Types::Struct.new(frame_c_name).define_fields(fields)
      end

      def build_async_constructor_function(binding, decl, frame_type, constructor_c_name, resume_c_name, ready_c_name, set_waiter_c_name, release_c_name, take_result_c_name, async_info)
        params = []
        body = []
        frame_pointer_type = pointer_to(frame_type)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: frame_pointer_type, pointer: false)
        raw_frame_expr = IR::Cast.new(target_type: async_info[:void_ptr], expression: frame_expr, type: async_info[:void_ptr])

        body << IR::LocalDecl.new(
          name: async_frame_local_name,
          c_name: async_frame_local_name,
          type: frame_pointer_type,
          value: IR::Cast.new(
            target_type: frame_pointer_type,
            expression: IR::Call.new(
              callee: "mt_async_alloc",
              arguments: [IR::SizeofExpr.new(target_type: frame_type, type: @types.fetch("usize"))],
              type: async_info[:void_ptr],
            ),
            type: frame_pointer_type,
          ),
        )

        binding.body_params.each do |param_binding|
          field_info = async_info[:param_fields].fetch(param_binding.name)
          field_type = field_info[:type]
          param_type = field_info[:param_type]
          c_name = c_local_name(param_binding.name)
          input_c_name = array_type?(param_type) && !field_info[:pointer] ? "#{c_name}_input" : c_name
          params << IR::Param.new(name: param_binding.name, c_name: input_c_name, type: param_type, pointer: field_info[:pointer])
          frame_field_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_type)
          body << IR::Assignment.new(
            target: frame_field_expr,
            operator: "=",
            value: IR::Name.new(name: input_c_name, type: param_type, pointer: field_info[:pointer]),
          )
          # Retain proc-containing params: the frame outlives the constructor call stack,
          # so we must increment the env refcount so the caller releasing their copy is safe.
          if !field_info[:pointer] && contains_proc_storage_type?(param_type)
            body.concat(lower_proc_contained_retain_statements(frame_field_expr, param_type))
          end
        end

        body << IR::ExpressionStmt.new(
          expression: IR::Call.new(callee: resume_c_name, arguments: [raw_frame_expr], type: @types.fetch("void")),
        )
        body << IR::ReturnStmt.new(
          value: IR::AggregateLiteral.new(
            type: async_info[:task_type],
            fields: [
              IR::AggregateField.new(name: "frame", value: raw_frame_expr),
              IR::AggregateField.new(name: "ready", value: IR::Name.new(name: ready_c_name, type: async_info[:task_type].field("ready"), pointer: false)),
              IR::AggregateField.new(name: "set_waiter", value: IR::Name.new(name: set_waiter_c_name, type: async_info[:task_type].field("set_waiter"), pointer: false)),
              IR::AggregateField.new(name: "release", value: IR::Name.new(name: release_c_name, type: async_info[:task_type].field("release"), pointer: false)),
              IR::AggregateField.new(name: "take_result", value: IR::Name.new(name: take_result_c_name, type: async_info[:task_type].field("take_result"), pointer: false)),
            ],
          ),
        )

        IR::Function.new(
          name: decl.name,
          c_name: constructor_c_name,
          params:,
          return_type: async_info[:task_type],
          body:,
          entry_point: false,
        )
      end

      def build_async_resume_function(binding, statements, frame_type, resume_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)
        body = [async_frame_cast_declaration(frame_type, async_info)]

        cases = (0..async_info[:await_fields].length).map do |state|
          IR::SwitchCase.new(
            value: IR::IntegerLiteral.new(value: state, type: @types.fetch("i32")),
            body: [IR::GotoStmt.new(label: async_state_label(resume_c_name, state))],
          )
        end
        body << IR::SwitchStmt.new(expression: async_frame_field_expression(frame_expr, "state", @types.fetch("i32")), cases:)
        body << IR::ReturnStmt.new(value: nil)
        body << IR::LabelStmt.new(name: async_state_label(resume_c_name, 0))

        env = async_resume_env_for(async_info)

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            field_info = async_info[:local_fields].fetch(statement.name)
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              body.concat(lower_async_await_statement(statement, field_info:, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              body.concat(lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:))
            end
            async_bind_local!(env, statement.name, field_info)
          when AST::Assignment
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              body.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              body.concat(lower_async_assignment_statement(statement, env:))
            end
          when AST::ExpressionStmt
            await_info = async_info[:await_fields][statement.expression&.object_id]
            if await_info
              body.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              body.concat(lower_async_expression_statement(statement, env:))
            end
          when AST::ReturnStmt
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              body.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              body.concat(lower_async_return_statement(statement, env:, frame_expr:, raw_frame_expr:, async_info:))
            end
          when AST::IfStmt, AST::MatchStmt, AST::WhileStmt, AST::ForStmt,
               AST::BreakStmt, AST::ContinueStmt, AST::UnsafeStmt, AST::StaticAssert
            if statements_contain_await?(Array(statement), async_info)
              body.concat(lower_async_cf_statements([statement], env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              body.concat(lower_async_non_await_statements([statement], env:, frame_expr:, raw_frame_expr:, async_info:))
            end
          else
            raise LoweringError, "unsupported async statement #{statement.class.name}"
          end
        end

        if async_info[:result_type] == @types.fetch("void") && !cfg_block_always_terminates?(statements)
          body.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
        end

        IR::Function.new(
          name: "#{binding.name}__resume",
          c_name: resume_c_name,
          params: [IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)],
          return_type: @types.fetch("void"),
          body:,
          entry_point: false,
        )
      end

      def build_async_ready_function(frame_type, ready_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)

        IR::Function.new(
          name: "#{ready_c_name}_fn",
          c_name: ready_c_name,
          params: [IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)],
          return_type: @types.fetch("bool"),
          body: [
            async_frame_cast_declaration(frame_type, async_info),
            IR::ReturnStmt.new(value: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool"))),
          ],
          entry_point: false,
        )
      end

      def build_async_set_waiter_function(frame_type, set_waiter_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        waiter_frame_expr = IR::Name.new(name: "waiter_frame", type: async_info[:void_ptr], pointer: false)
        waiter_expr = IR::Name.new(name: "waiter", type: async_info[:wake_type], pointer: false)

        IR::Function.new(
          name: "#{set_waiter_c_name}_fn",
          c_name: set_waiter_c_name,
          params: [
            IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false),
            IR::Param.new(name: "waiter_frame", c_name: "waiter_frame", type: async_info[:void_ptr], pointer: false),
            IR::Param.new(name: "waiter", c_name: "waiter", type: async_info[:wake_type], pointer: false),
          ],
          return_type: @types.fetch("void"),
          body: [
            async_frame_cast_declaration(frame_type, async_info),
            IR::IfStmt.new(
              condition: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(expression: IR::Call.new(callee: waiter_expr, arguments: [waiter_frame_expr], type: @types.fetch("void"))),
                IR::ReturnStmt.new(value: nil),
              ],
              else_body: nil,
            ),
            IR::Assignment.new(target: async_frame_field_expression(frame_expr, "waiter_frame", async_info[:void_ptr]), operator: "=", value: waiter_frame_expr),
            IR::Assignment.new(target: async_frame_field_expression(frame_expr, "waiter", async_info[:wake_type]), operator: "=", value: waiter_expr),
            IR::ReturnStmt.new(value: nil),
          ],
          entry_point: false,
        )
      end

      def build_async_release_function(frame_type, release_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)

        body = [
          async_frame_cast_declaration(frame_type, async_info),
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool")), type: @types.fetch("bool")),
            then_body: [IR::ReturnStmt.new(value: nil)],
            else_body: nil,
          ),
        ]

        # Release proc-containing params (always initialized by constructor, but null-guard is safe).
        async_info[:param_fields].each_value do |field_info|
          next if field_info[:pointer]
          next unless contains_proc_storage_type?(field_info[:type])

          field_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_info[:type])
          body.concat(lower_async_frame_proc_release_statements(field_expr, field_info[:type]))
        end

        # Release proc-containing locals (may not be initialized if function returned early via branch,
        # so always null-guard via invoke pointer check on each proc).
        async_info[:local_fields].each_value do |field_info|
          next unless contains_proc_storage_type?(field_info[:type])

          field_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_info[:type])
          body.concat(lower_async_frame_proc_release_statements(field_expr, field_info[:type]))
        end

        body << IR::ExpressionStmt.new(expression: IR::Call.new(callee: "mt_async_free", arguments: [raw_frame_expr], type: @types.fetch("void")))
        body << IR::ReturnStmt.new(value: nil)

        IR::Function.new(
          name: "#{release_c_name}_fn",
          c_name: release_c_name,
          params: [IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)],
          return_type: @types.fetch("void"),
          body:,
          entry_point: false,
        )
      end

      def build_async_take_result_function(frame_type, take_result_c_name, async_info)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        body = [async_frame_cast_declaration(frame_type, async_info)]
        if async_info[:result_type] == @types.fetch("void")
          body << IR::ReturnStmt.new(value: nil)
        else
          body << IR::ReturnStmt.new(value: async_frame_field_expression(frame_expr, "result", async_info[:result_type]))
        end

        IR::Function.new(
          name: "#{take_result_c_name}_fn",
          c_name: take_result_c_name,
          params: [IR::Param.new(name: "frame", c_name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)],
          return_type: async_info[:result_type],
          body:,
          entry_point: false,
        )
      end

      def async_resume_env_for(async_info)
        env = empty_env
        async_info[:param_fields].each do |name, field_info|
          env[:scopes].last[name] = local_binding(
            type: field_info[:pointer] ? pointee_type(field_info[:type]) : field_info[:type],
            c_name: async_frame_field_c_name(field_info[:field_name]),
            mutable: field_info[:mutable],
            pointer: field_info[:pointer],
          )
        end
        env
      end

      def async_bind_local!(env, name, field_info)
        current_actual_scope(env[:scopes])[name] = local_binding(
          type: field_info[:type],
          c_name: async_frame_field_c_name(field_info[:field_name]),
          mutable: field_info[:mutable],
          pointer: false,
        )
      end

      def async_frame_cast_declaration(frame_type, async_info)
        IR::LocalDecl.new(
          name: async_frame_local_name,
          c_name: async_frame_local_name,
          type: pointer_to(frame_type),
          value: IR::Cast.new(
            target_type: pointer_to(frame_type),
            expression: IR::Name.new(name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false),
            type: pointer_to(frame_type),
          ),
        )
      end

      def async_frame_local_name
        "__mt_frame"
      end

      def async_frame_raw_name
        "__mt_frame_raw"
      end

      def async_frame_field_c_name(field_name)
        "#{async_frame_local_name}->#{field_name}"
      end

      def async_state_label(resume_c_name, state)
        "#{resume_c_name}_state_#{state}"
      end

      def async_frame_field_expression(frame_expr, field_name, field_type)
        IR::Member.new(receiver: frame_expr, member: field_name, type: field_type)
      end

      def async_task_frame_expression(task_expr, task_type)
        IR::Member.new(receiver: task_expr, member: "frame", type: task_type.field("frame"))
      end

      def async_task_call(task_expr, task_type, member, arguments, return_type)
        IR::Call.new(
          callee: IR::Member.new(receiver: task_expr, member:, type: task_type.field(member)),
          arguments:,
          type: return_type,
        )
      end

      def lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:)
        lowered = []
        type = field_info[:type]
        target = async_frame_field_expression(frame_expr, field_info[:field_name], type)
        prepared_setup = []
        prepared_value = statement.value

        if statement.value
          prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
            statement.value,
            env:,
            expected_type: type,
            allow_root_statement_foreign: true,
          )
          lowered.concat(prepared_setup)
        end

        if prepared_value && (foreign_call = foreign_call_info(prepared_value, env))
          setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
            foreign_call,
            env:,
            expected_type: type,
            statement_position: false,
          )
          lowered.concat(setup)
          raise LoweringError, "foreign call used to initialize #{statement.name} must return a value" if call_type == @types.fetch("void")
          raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

          lowered << IR::Assignment.new(target:, operator: "=", value:)
          lowered.concat(cleanup_statements)
        else
          value = if prepared_value
                    lower_contextual_expression(
                      prepared_value,
                      env:,
                      expected_type: type,
                      contextual_int_to_float: statement.type && contextual_int_to_float_target?(type),
                    )
                  else
                    IR::ZeroInit.new(type:)
                  end
          lowered << IR::Assignment.new(target:, operator: "=", value:)
        end

        lowered
      end

      def normalize_async_body(binding, statements)
        counter = { value: 0 }
        env = empty_env
        binding.body_params.each do |param_binding|
          env[:scopes].last[param_binding.name] = local_binding(
            type: param_binding.type,
            c_name: param_binding.name,
            mutable: param_binding.mutable,
            pointer: false,
          )
        end
        normalize_async_statements(statements, counter, env, return_type: binding.body_return_type)
      end

      def normalize_async_statements(statements, counter, env, return_type:)
        statements.flat_map { |statement| normalize_async_statement(statement, counter, env, return_type:) }
      end

      def normalize_async_statement(statement, counter, env, return_type:)
        case statement
        when AST::LocalDecl
          if statement.value
            return [statement] if statement.value.is_a?(AST::AwaitExpr)

            declared_type = statement.type ? resolve_type_ref(statement.type) : nil
            original_value_type = statement.type ? nil : infer_expression_type(statement.value, env:)
            setup, value = normalize_async_expression(statement.value, counter, env:, expected_type: declared_type)
            normalized = AST::LocalDecl.new(kind: statement.kind, name: statement.name, type: statement.type, value: value, line: statement.line)
            local_type = statement.type ? resolve_type_ref(statement.type) : original_value_type
            current_actual_scope(env[:scopes])[statement.name] = local_binding(type: local_type, c_name: statement.name, mutable: statement.kind == :var, pointer: false)
            return setup + [normalized]
          end

          local_type = resolve_type_ref(statement.type)
          current_actual_scope(env[:scopes])[statement.name] = local_binding(type: local_type, c_name: statement.name, mutable: statement.kind == :var, pointer: false)
          [statement]
        when AST::Assignment
          target_setup, target = normalize_async_assignment_target(statement.target, counter, env:)
          return target_setup + [AST::Assignment.new(target:, operator: statement.operator, value: statement.value)] if statement.value.is_a?(AST::AwaitExpr)

          target_type = infer_expression_type(statement.target, env:)
          setup, value = normalize_async_expression(statement.value, counter, env:, expected_type: target_type)
          target_setup + setup + [AST::Assignment.new(target:, operator: statement.operator, value: value)]
        when AST::ExpressionStmt
          return [statement] if statement.expression.is_a?(AST::AwaitExpr)

          setup, expression = normalize_async_expression(statement.expression, counter, env:)
          setup + [AST::ExpressionStmt.new(expression: expression, line: statement.line)]
        when AST::ReturnStmt
          return [statement] unless statement.value
          return [statement] if statement.value.is_a?(AST::AwaitExpr)

          setup, value = normalize_async_expression(statement.value, counter, env:, expected_type: return_type)
          setup + [AST::ReturnStmt.new(value: value, line: statement.line)]
        when AST::IfStmt
          normalize_async_if_statement(statement, counter, env, return_type:)
        when AST::MatchStmt
          expr_setup, expression = normalize_async_expression(statement.expression, counter, env:)
          arms = statement.arms.map do |arm|
            arm_env = duplicate_env(env)
            AST::MatchArm.new(pattern: arm.pattern, binding_name: arm.binding_name, body: normalize_async_statements(arm.body, counter, arm_env, return_type:))
          end
          expr_setup + [AST::MatchStmt.new(expression:, arms:)]
        when AST::WhileStmt
          condition_setup, condition = normalize_async_expression(statement.condition, counter, env:, expected_type: @types.fetch("bool"))
          body_env = duplicate_env(env)
          body = normalize_async_statements(statement.body, counter, body_env, return_type:)
          if condition_setup.empty?
            [AST::WhileStmt.new(condition:, body:)]
          else
            cond_name = fresh_async_temp_name(counter)
            condition_eval = condition_setup + [AST::LocalDecl.new(kind: :let, name: cond_name, type: ast_type_ref_for(@types.fetch("bool")), value: condition)]
            [
              AST::WhileStmt.new(
                condition: AST::BooleanLiteral.new(value: true),
                body: condition_eval + [
                  AST::IfStmt.new(
                    branches: [AST::IfBranch.new(condition: AST::UnaryOp.new(operator: "not", operand: AST::Identifier.new(name: cond_name)), body: [AST::BreakStmt.new])],
                    else_body: nil,
                  ),
                  *body,
                ],
              ),
            ]
          end
        when AST::ForStmt
          original_iterable = statement.iterable
          loop_type = if range_iterable?(original_iterable)
                        infer_range_loop_type(original_iterable, env:)
                      else
                        iterable_type = infer_expression_type(original_iterable, env:)
                        collection_loop_type(iterable_type)
                      end
          iterable_setup, iterable = normalize_async_expression(statement.iterable, counter, env:)
          for_env = duplicate_env(env)
          current_actual_scope(for_env[:scopes])[statement.name] = local_binding(type: loop_type, c_name: statement.name, mutable: false, pointer: false)
          body = normalize_async_statements(statement.body, counter, for_env, return_type:)
          iterable_setup + [AST::ForStmt.new(name: statement.name, iterable:, body:)]
        when AST::UnsafeStmt
          unsafe_env = duplicate_env(env)
          [AST::UnsafeStmt.new(body: normalize_async_statements(statement.body, counter, unsafe_env, return_type:))]
        when AST::BreakStmt, AST::ContinueStmt, AST::StaticAssert
          [statement]
        else
          raise LoweringError, "unsupported async statement #{statement.class.name}"
        end
      end

      def normalize_async_if_statement(statement, counter, env, return_type:)
        else_body = if statement.else_body
                      else_env = duplicate_env(env)
                      normalize_async_statements(statement.else_body, counter, else_env, return_type:)
                    end
        normalize_async_if_branches(statement.branches, else_body, counter, env, return_type:)
      end

      def normalize_async_if_branches(branches, else_body, counter, env, return_type:)
        return else_body || [] if branches.empty?

        branch = branches.first
        condition_setup, condition = normalize_async_expression(branch.condition, counter, env:, expected_type: @types.fetch("bool"))
        then_env = duplicate_env(env)
        then_body = normalize_async_statements(branch.body, counter, then_env, return_type:)
        chained_else = normalize_async_if_branches(branches.drop(1), else_body, counter, env, return_type:)
        condition_setup + [AST::IfStmt.new(branches: [AST::IfBranch.new(condition:, body: then_body)], else_body: chained_else)]
      end

      def normalize_async_assignment_target(target, counter, env:)
        case target
        when AST::Identifier
          [[], target]
        when AST::MemberAccess
          receiver_setup, receiver = normalize_async_expression(target.receiver, counter, env:)
          [receiver_setup, AST::MemberAccess.new(receiver:, member: target.member)]
        when AST::IndexAccess
          receiver_setup, receiver = normalize_async_expression(target.receiver, counter, env:)
          index_setup, index = normalize_async_expression(target.index, counter, env:)
          [receiver_setup + index_setup, AST::IndexAccess.new(receiver:, index:)]
        else
          raise LoweringError, "unsupported assignment target #{target.class.name}"
        end
      end

      def normalize_async_expression(expression, counter, env:, expected_type: nil)
        case expression
        when AST::AwaitExpr
          temp_name = fresh_async_temp_name(counter)
          [
            [AST::LocalDecl.new(kind: :let, name: temp_name, type: nil, value: expression)],
            AST::Identifier.new(name: temp_name),
          ]
        when AST::Call
          setup = []
          callee_setup, callee = normalize_async_expression(expression.callee, counter, env:)
          setup.concat(callee_setup)
          arguments = expression.arguments.map do |argument|
            argument_setup, value = normalize_async_expression(argument.value, counter, env:)
            setup.concat(argument_setup)
            AST::Argument.new(name: argument.name, value: value)
          end
          [setup, AST::Call.new(callee: callee, arguments: arguments)]
        when AST::Specialization
          setup = []
          callee_setup, callee = normalize_async_expression(expression.callee, counter, env:)
          setup.concat(callee_setup)
          arguments = expression.arguments.map do |argument|
            argument_setup, value = normalize_async_expression(argument.value, counter, env:)
            setup.concat(argument_setup)
            AST::TypeArgument.new(value: value)
          end
          [setup, AST::Specialization.new(callee: callee, arguments: arguments)]
        when AST::UnaryOp
          setup, operand = normalize_async_expression(expression.operand, counter, env:, expected_type: expected_type)
          [setup, AST::UnaryOp.new(operator: expression.operator, operand: operand)]
        when AST::BinaryOp
          if %w[and or].include?(expression.operator)
            left_setup, left = normalize_async_expression(expression.left, counter, env:, expected_type: @types.fetch("bool"))
            right_setup, right = normalize_async_expression(expression.right, counter, env:, expected_type: @types.fetch("bool"))
            temp_name = fresh_async_temp_name(counter)

            temp_init = expression.operator == "and" ? AST::BooleanLiteral.new(value: false) : AST::BooleanLiteral.new(value: true)
            short_circuit_value = expression.operator == "and" ? AST::BooleanLiteral.new(value: false) : AST::BooleanLiteral.new(value: true)

            branch_body = right_setup + [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: right)]
            else_body = [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: short_circuit_value)]

            if expression.operator == "or"
              branch_body, else_body = else_body, branch_body
            end

            setup = [AST::LocalDecl.new(kind: :var, name: temp_name, type: nil, value: temp_init)]
            setup.concat(left_setup)
            setup << AST::IfStmt.new(branches: [AST::IfBranch.new(condition: left, body: branch_body)], else_body: else_body)
            return [setup, AST::Identifier.new(name: temp_name)]
          end

          left_setup, left = normalize_async_expression(expression.left, counter, env:)
          right_setup, right = normalize_async_expression(expression.right, counter, env:)
          [left_setup + right_setup, AST::BinaryOp.new(operator: expression.operator, left: left, right: right)]
        when AST::IfExpr
          condition_setup, condition = normalize_async_expression(expression.condition, counter, env:, expected_type: @types.fetch("bool"))
          result_type = infer_expression_type(expression, env:, expected_type:)
          then_setup, then_expression = normalize_async_expression(expression.then_expression, counter, env:, expected_type: result_type)
          else_setup, else_expression = normalize_async_expression(expression.else_expression, counter, env:, expected_type: result_type)

          return [[], AST::IfExpr.new(condition:, then_expression:, else_expression:)] if condition_setup.empty? && then_setup.empty? && else_setup.empty?

          temp_name = fresh_async_temp_name(counter)
          setup = condition_setup + [
            AST::LocalDecl.new(kind: :var, name: temp_name, type: ast_type_ref_for(result_type), value: nil),
            AST::IfStmt.new(
              branches: [AST::IfBranch.new(condition:, body: then_setup + [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: then_expression)])],
              else_body: else_setup + [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: else_expression)],
            ),
          ]
          [setup, AST::Identifier.new(name: temp_name)]
        when AST::MemberAccess
          setup, receiver = normalize_async_expression(expression.receiver, counter, env:)
          [setup, AST::MemberAccess.new(receiver: receiver, member: expression.member)]
        when AST::IndexAccess
          receiver_setup, receiver = normalize_async_expression(expression.receiver, counter, env:)
          index_setup, index = normalize_async_expression(expression.index, counter, env:)
          [receiver_setup + index_setup, AST::IndexAccess.new(receiver: receiver, index: index)]
        when AST::RangeExpr
          start_setup, start_expr = normalize_async_expression(expression.start_expr, counter, env:)
          end_setup, end_expr = normalize_async_expression(expression.end_expr, counter, env:)
          [start_setup + end_setup, AST::RangeExpr.new(start_expr:, end_expr:, line: expression.line, column: expression.column)]
        when AST::FormatString
          setup = []
          parts = expression.parts.map do |part|
            if part.is_a?(AST::FormatExprPart)
              expression_setup, inner_expression = normalize_async_expression(part.expression, counter, env:)
              setup.concat(expression_setup)
              AST::FormatExprPart.new(expression: inner_expression)
            else
              part
            end
          end
          [setup, AST::FormatString.new(parts: parts)]
        else
          [[], expression]
        end
      end

      def ast_type_ref_for(type)
        case type
        when Types::Primitive
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: [type.name]), arguments: [], nullable: false)
        when Types::Nullable
          inner = ast_type_ref_for(type.base)
          raise LoweringError, "nullable annotation is only valid for named/generic types" unless inner.is_a?(AST::TypeRef)

          AST::TypeRef.new(name: inner.name, arguments: inner.arguments, nullable: true)
        when Types::GenericInstance
          AST::TypeRef.new(
            name: AST::QualifiedName.new(parts: type.name.split(".")),
            arguments: type.arguments.map do |argument|
              if argument.is_a?(Types::LiteralTypeArg)
                AST::TypeArgument.new(value: AST::IntegerLiteral.new(lexeme: argument.value.to_s, value: argument.value))
              else
                AST::TypeArgument.new(value: ast_type_ref_for(argument))
              end
            end,
            nullable: false,
          )
        when Types::Span
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: [AST::TypeArgument.new(value: ast_type_ref_for(type.element_type))], nullable: false)
        when Types::Result
          AST::TypeRef.new(
            name: AST::QualifiedName.new(parts: ["Result"]),
            arguments: [AST::TypeArgument.new(value: ast_type_ref_for(type.ok_type)), AST::TypeArgument.new(value: ast_type_ref_for(type.error_type))],
            nullable: false,
          )
        when Types::Task
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["Task"]), arguments: [AST::TypeArgument.new(value: ast_type_ref_for(type.result_type))], nullable: false)
        when Types::TypeVar
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: [type.name]), arguments: [], nullable: false)
        when Types::StructInstance
          base_parts = type.module_name ? type.module_name.split(".") + [type.name] : [type.name]
          AST::TypeRef.new(
            name: AST::QualifiedName.new(parts: base_parts),
            arguments: type.arguments.map do |argument|
              if argument.is_a?(Types::LiteralTypeArg)
                AST::TypeArgument.new(value: AST::IntegerLiteral.new(lexeme: argument.value.to_s, value: argument.value))
              else
                AST::TypeArgument.new(value: ast_type_ref_for(argument))
              end
            end,
            nullable: false,
          )
        when Types::Struct, Types::Union, Types::Opaque, Types::Enum, Types::Flags
          parts = type.module_name ? type.module_name.split(".") + [type.name] : [type.name]
          AST::TypeRef.new(name: AST::QualifiedName.new(parts: parts), arguments: [], nullable: false)
        when Types::Function
          AST::FunctionType.new(
            params: type.params.each_with_index.map { |param, i| AST::Param.new(name: param.name || "p#{i}", type: ast_type_ref_for(param.type)) },
            return_type: ast_type_ref_for(type.return_type),
          )
        when Types::Proc
          AST::ProcType.new(
            params: type.params.each_with_index.map { |param, i| AST::Param.new(name: param.name || "p#{i}", type: ast_type_ref_for(param.type)) },
            return_type: ast_type_ref_for(type.return_type),
          )
        else
          raise LoweringError, "unsupported type for AST normalization #{type.class.name}"
        end
      end

      def async_expression_contains_await?(expression)
        case expression
        when AST::AwaitExpr
          true
        when AST::Call, AST::Specialization
          async_expression_contains_await?(expression.callee) || expression.arguments.any? { |argument| async_expression_contains_await?(argument.value) }
        when AST::UnaryOp
          async_expression_contains_await?(expression.operand)
        when AST::BinaryOp
          async_expression_contains_await?(expression.left) || async_expression_contains_await?(expression.right)
        when AST::IfExpr
          async_expression_contains_await?(expression.condition) || async_expression_contains_await?(expression.then_expression) || async_expression_contains_await?(expression.else_expression)
        when AST::MemberAccess
          async_expression_contains_await?(expression.receiver)
        when AST::IndexAccess
          async_expression_contains_await?(expression.receiver) || async_expression_contains_await?(expression.index)
        when AST::FormatString
          expression.parts.any? { |part| part.is_a?(AST::FormatExprPart) && async_expression_contains_await?(part.expression) }
        else
          false
        end
      end

      def fresh_async_temp_name(counter)
        counter[:value] += 1
        "__mt_async_tmp_#{counter[:value]}"
      end

      # Lowers a list of statements that contain no `await` anywhere, but live
      # inside an async resume function. Return statements are lowered as async
      # completions. All other control flow is lowered recursively.
      def statements_contain_await?(statements, async_info)
        statements.any? do |s|
          case s
          when AST::LocalDecl
            async_info[:await_fields].key?(s.value&.object_id)
          when AST::Assignment
            async_info[:await_fields].key?(s.value&.object_id)
          when AST::ExpressionStmt
            async_info[:await_fields].key?(s.expression&.object_id)
          when AST::ReturnStmt
            async_info[:await_fields].key?(s.value&.object_id)
          when AST::IfStmt
            s.branches.any? { |b| statements_contain_await?(b.body, async_info) } ||
              (s.else_body && statements_contain_await?(s.else_body, async_info))
          when AST::WhileStmt
            statements_contain_await?(s.body, async_info)
          when AST::ForStmt
            statements_contain_await?(s.body, async_info)
          when AST::MatchStmt
            s.arms.any? { |arm| statements_contain_await?(arm.body, async_info) }
          when AST::UnsafeStmt
            statements_contain_await?(s.body, async_info)
          else
            false
          end
        end
      end

      # Lower a list of statements that MAY contain await expressions inside nested control flow.
      # CPS-via-goto: labels placed inside if/while/match bodies, reachable from top-level switch dispatch.
      def lower_async_cf_statements(statements, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow: nil)
        lowered = []
        statements.each do |statement|
          case statement
          when AST::LocalDecl
            field_info = async_info[:local_fields].fetch(statement.name)
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, field_info:, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              lowered.concat(lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:))
            end
            async_bind_local!(env, statement.name, field_info)
          when AST::Assignment
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              lowered.concat(lower_async_assignment_statement(statement, env:))
            end
          when AST::ExpressionStmt
            await_info = async_info[:await_fields][statement.expression&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              lowered.concat(lower_async_expression_statement(statement, env:))
            end
          when AST::ReturnStmt
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
            else
              lowered.concat(lower_async_return_statement(statement, env:, frame_expr:, raw_frame_expr:, async_info:))
            end
          when AST::IfStmt
            lowered.concat(lower_async_cf_if_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:))
          when AST::WhileStmt
            lowered.concat(lower_async_cf_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:))
          when AST::ForStmt
            lowered.concat(lower_async_cf_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:))
          when AST::MatchStmt
            lowered.concat(lower_async_cf_match_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:))
          when AST::UnsafeStmt
            lowered.concat(lower_async_cf_statements(statement.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:))
          when AST::BreakStmt
            lowered << IR::BreakStmt.new
          when AST::ContinueStmt
            lowered << IR::ContinueStmt.new
          when AST::StaticAssert
            lowered.concat(lower_static_assert(statement))
          else
            raise LoweringError, "unsupported async cf statement #{statement.class.name}"
          end
        end
        lowered
      end

      def lower_async_cf_if_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:)
        branch_entries = statement.branches.map do |branch|
          condition_setup, prepared_cond = prepare_expression_for_inline_lowering(branch.condition, env:)
          condition = lower_contextual_expression(prepared_cond, env:, expected_type: @types.fetch("bool"))
          body = if statements_contain_await?(branch.body, async_info)
            lower_async_cf_statements(branch.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:)
          else
            lower_async_non_await_statements(branch.body, env:, frame_expr:, raw_frame_expr:, async_info:, loop_flow:)
          end
          { condition_setup:, condition:, body: }
        end

        else_body = if statement.else_body
          if statements_contain_await?(statement.else_body, async_info)
            lower_async_cf_statements(statement.else_body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:)
          else
            lower_async_non_await_statements(statement.else_body, env:, frame_expr:, raw_frame_expr:, async_info:, loop_flow:)
          end
        end

        nested_else = else_body
        branch_entries.reverse_each do |entry|
          nested_else = [
            *entry[:condition_setup],
            IR::IfStmt.new(condition: entry[:condition], then_body: entry[:body], else_body: nested_else),
          ]
        end
        nested_else || []
      end

      def lower_async_cf_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:)
        condition_setup, prepared_cond = prepare_expression_for_inline_lowering(statement.condition, env:)
        condition = lower_contextual_expression(prepared_cond, env:, expected_type: @types.fetch("bool"))
        body = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:)
        else
          lower_async_non_await_statements(statement.body, env:, frame_expr:, raw_frame_expr:, async_info:, loop_flow:)
        end
        condition_setup + [IR::WhileStmt.new(condition:, body:)]
      end

      def lower_async_cf_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:)
        if range_iterable?(statement.iterable)
          lower_async_cf_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:)
        else
          lower_async_cf_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:)
        end
      end

      def lower_range_call(iterable, env:)
        loop_type = infer_range_loop_type(iterable, env:)
        start_expr_ast = range_start_of(iterable)
        stop_expr_ast = range_end_of(iterable)
        start_ir = lower_expression(start_expr_ast, env:, expected_type: loop_type)
        stop_ir = lower_expression(stop_expr_ast, env:, expected_type: loop_type)
        [start_ir, stop_ir, false]
      end

      def lower_async_cf_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:)
        loop_var_name = statement.name
        loop_var_type = infer_range_loop_type(statement.iterable, env:)
        loop_var_field = async_info[:local_fields].fetch(loop_var_name)
        loop_var_expr = async_frame_field_expression(frame_expr, loop_var_field[:field_name], loop_var_type)

        start_expr, stop_expr, inclusive = lower_range_call(statement.iterable, env:)

        # Store stop value in frame too so it survives suspension
        stop_field_name = "#{loop_var_field[:field_name]}_stop"
        async_info[:local_fields][stop_field_name] ||= { field_name: stop_field_name, type: loop_var_type, mutable: true }
        stop_field_expr = async_frame_field_expression(frame_expr, stop_field_name, loop_var_type)

        inner_env = duplicate_env(env)
        inner_env[:scopes].last[loop_var_name] = local_binding(
          type: loop_var_type,
          c_name: async_frame_field_c_name(loop_var_field[:field_name]),
          mutable: true, pointer: false
        )

        body = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:)
        end

        cmp_op = inclusive ? "<=" : "<"
        [
          IR::Assignment.new(target: loop_var_expr, operator: "=", value: start_expr),
          IR::Assignment.new(target: stop_field_expr, operator: "=", value: stop_expr),
          IR::WhileStmt.new(
            condition: IR::BinaryOp.new(operator: cmp_op, left: loop_var_expr, right: stop_field_expr, type: @types.fetch("bool")),
            body: body + [IR::Assignment.new(target: loop_var_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: loop_var_type))],
          ),
        ]
      end

      def lower_async_cf_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects range(start, stop), array[T, N], or span[T], got #{iterable_type}" unless element_type

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        iterable_c_name = fresh_c_temp_name(env, "for_items")
        index_c_name = fresh_c_temp_name(env, "for_index")
        iterable_ref = IR::Name.new(name: iterable_c_name, type: iterable_type, pointer: false)
        index_ref = IR::Name.new(name: index_c_name, type: @types.fetch("usize"), pointer: false)

        # Loop variable stored in frame so it survives suspension
        loop_var_field = async_info[:local_fields].fetch(statement.name)
        loop_var_expr = async_frame_field_expression(frame_expr, loop_var_field[:field_name], element_type)

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

        inner_env = duplicate_env(env)
        inner_env[:scopes].last[statement.name] = local_binding(
          type: element_type, c_name: async_frame_field_c_name(loop_var_field[:field_name]), mutable: true, pointer: false
        )

        assign_item = IR::Assignment.new(target: loop_var_expr, operator: "=", value: item_value)
        body_stmts = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:)
        end

        stmts = [
          *iterable_setup,
          IR::LocalDecl.new(name: iterable_c_name, c_name: iterable_c_name, type: iterable_type, value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
          IR::ForStmt.new(
            init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("usize"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("usize"))),
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
            post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("usize"))),
            body: [assign_item] + body_stmts,
          ),
        ]
        stmts
      end

      def lower_async_cf_match_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:)
        expr_setup, prepared_expr = prepare_expression_for_inline_lowering(statement.expression, env:)
        match_expr = lower_contextual_expression(prepared_expr, env:, expected_type: nil)
        match_type = infer_expression_type(statement.expression, env:)

        cases = statement.arms.map do |arm|
          arm_body = if statements_contain_await?(arm.body, async_info)
            lower_async_cf_statements(arm.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, loop_flow:)
          else
            lower_async_non_await_statements(arm.body, env:, frame_expr:, raw_frame_expr:, async_info:, loop_flow:)
          end
          if wildcard_arm_pattern?(arm.pattern)
            IR::SwitchDefaultCase.new(body: arm_body + [IR::BreakStmt.new])
          else
            IR::SwitchCase.new(value: lower_expression(arm.pattern, env:, expected_type: match_type), body: arm_body + [IR::BreakStmt.new])
          end
        end

        expr_setup + [IR::SwitchStmt.new(expression: match_expr, cases:)]
      end

      def lower_async_non_await_statements(statements, env:, frame_expr:, raw_frame_expr:, async_info:, loop_flow: nil)
        local_env = duplicate_env(env)
        lowered = []

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            type = statement.type ? resolve_type_ref(statement.type) : infer_expression_type(statement.value, env: local_env)
            c_name = c_local_name(statement.name)
            if statement.value
              prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
                statement.value, env: local_env, expected_type: type, allow_root_statement_foreign: true
              )
              lowered.concat(prepared_setup)
              value = lower_contextual_expression(
                prepared_value, env: local_env, expected_type: type,
                contextual_int_to_float: statement.type && contextual_int_to_float_target?(type)
              )
            else
              value = IR::ZeroInit.new(type:)
            end
            lowered << IR::LocalDecl.new(name: statement.name, c_name:, type:, value:)
            current_actual_scope(local_env[:scopes])[statement.name] = local_binding(type:, c_name:, mutable: statement.kind == :var, pointer: false)
          when AST::Assignment
            lowered.concat(lower_async_assignment_statement(statement, env: local_env))
          when AST::ExpressionStmt
            lowered.concat(lower_async_expression_statement(statement, env: local_env))
          when AST::ReturnStmt
            lowered.concat(lower_async_return_statement(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:))
          when AST::IfStmt
            branch_entries = statement.branches.map do |branch|
              condition_setup, prepared_cond = prepare_expression_for_inline_lowering(
                branch.condition, env: local_env, expected_type: @types.fetch("bool")
              )
              then_body = lower_async_non_await_statements(
                branch.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, loop_flow:
              )
              [condition_setup, lower_expression(prepared_cond, env: local_env, expected_type: @types.fetch("bool")), then_body]
            end
            else_body = statement.else_body ? lower_async_non_await_statements(
              statement.else_body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, loop_flow:
            ) : nil
            nested = else_body || []
            branch_entries.reverse_each do |cond_setup, cond, then_body|
              nested = [*cond_setup, IR::IfStmt.new(condition: cond, then_body:, else_body: nested.empty? ? nil : nested)]
            end
            lowered.concat(nested)
          when AST::MatchStmt
            scrutinee_type = infer_expression_type(statement.expression, env: local_env)
            expr_setup, prepared_expr = prepare_expression_for_inline_lowering(
              statement.expression, env: local_env, expected_type: scrutinee_type
            )
            lowered.concat(expr_setup)
            expr = lower_expression(prepared_expr, env: local_env, expected_type: scrutinee_type)
            cases = statement.arms.map do |arm|
              arm_body = lower_async_non_await_statements(
                arm.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, loop_flow:
              )
              if wildcard_arm_pattern?(arm.pattern)
                IR::SwitchDefaultCase.new(body: arm_body)
              else
                value = lower_expression(arm.pattern, env: local_env, expected_type: scrutinee_type)
                IR::SwitchCase.new(value:, body: arm_body)
              end
            end
            lowered << IR::SwitchStmt.new(expression: expr, cases:)
          when AST::WhileStmt
            lowered << lower_async_while_stmt(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:)
          when AST::ForStmt
            lowered << lower_async_for_stmt(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:)
          when AST::BreakStmt
            if loop_flow
              lowered.concat(lower_loop_exit(loop_flow[:break_target], [], []))
            else
              lowered << IR::BreakStmt.new
            end
          when AST::ContinueStmt
            if loop_flow
              lowered.concat(lower_loop_exit(loop_flow[:continue_target], [], []))
            else
              lowered << IR::ContinueStmt.new
            end
          when AST::UnsafeStmt
            lowered.concat(lower_async_non_await_statements(
              statement.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, loop_flow:
            ))
          when AST::StaticAssert
            lowered << IR::StaticAssert.new(
              condition: lower_expression(statement.condition, env: local_env, expected_type: @types.fetch("bool")),
              message: lower_expression(statement.message, env: local_env, expected_type: @types.fetch("str")),
            )
          else
            raise LoweringError, "unsupported async non-await statement #{statement.class.name}"
          end
        end

        lowered
      end

      def lower_async_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        condition_setup, prepared_cond = prepare_expression_for_inline_lowering(
          statement.condition, env:, expected_type: @types.fetch("bool")
        )
        body = lower_async_non_await_statements(
          statement.body,
          env: duplicate_env(env),
          frame_expr:,
          raw_frame_expr:,
          async_info:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)
        cond = lower_expression(prepared_cond, env:, expected_type: @types.fetch("bool"))

        if condition_setup.empty?
          stmts = [IR::WhileStmt.new(condition: cond, body:)]
          stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
          return IR::BlockStmt.new(body: stmts)
        end

        loop_body = [
          *condition_setup,
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: cond, type: @types.fetch("bool")),
            then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: nil,
          ),
          *body,
        ]
        stmts = [IR::WhileStmt.new(condition: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")), body: loop_body)]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(loop_body, break_label)
        IR::BlockStmt.new(body: stmts)
      end

      def lower_async_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:)
        return lower_async_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:) if range_iterable?(statement.iterable)

        lower_async_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:)
      end

      def lower_async_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:)
        loop_type = infer_range_loop_type(statement.iterable, env:)
        start_expr = range_start_of(statement.iterable)
        stop_expr = range_end_of(statement.iterable)
        start_setup, prepared_start = prepare_expression_for_inline_lowering(start_expr, env:, expected_type: loop_type)
        stop_setup, prepared_stop = prepare_expression_for_inline_lowering(stop_expr, env:, expected_type: loop_type)
        index_c_name = c_local_name(statement.name)
        stop_c_name = fresh_c_temp_name(env, "for_stop")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_c_name, type: loop_type, pointer: false)
        inline_stop = stop_setup.empty? && compile_time_numeric_const_expression?(prepared_stop)
        stop_value = if inline_stop
                       lower_expression(prepared_stop, env:, expected_type: loop_type)
                     else
                       IR::Name.new(name: stop_c_name, type: loop_type, pointer: false)
                     end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(
          type: loop_type, c_name: index_c_name, mutable: false, pointer: false
        )
        body = lower_async_non_await_statements(
          statement.body,
          env: while_env,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: statement.name, c_name: index_c_name, type: loop_type, value: lower_expression(prepared_start, env:, expected_type: loop_type)),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: loop_type)),
          body:,
        )

        stmts = [
          *start_setup,
          *stop_setup,
          *(inline_stop ? [] : [IR::LocalDecl.new(name: stop_c_name, c_name: stop_c_name, type: loop_type, value: lower_expression(prepared_stop, env:, expected_type: loop_type))]),
          for_statement,
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
        IR::BlockStmt.new(body: stmts)
      end

      def lower_async_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects range(start, stop), array[T, N], or span[T], got #{iterable_type}" unless element_type

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
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
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(
          type: element_type, c_name: c_local_name(statement.name), mutable: false, pointer: false
        )
        body = [IR::LocalDecl.new(name: statement.name, c_name: c_local_name(statement.name), type: element_type, value: item_value)]
        body.concat(lower_async_non_await_statements(
          statement.body,
          env: while_env,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        ))
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("usize"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("usize"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("usize"))),
          body:,
        )

        stmts = [
          *iterable_setup,
          IR::LocalDecl.new(name: iterable_c_name, c_name: iterable_c_name, type: iterable_type, value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
          for_statement,
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
        IR::BlockStmt.new(body: stmts)
      end

      def lower_async_assignment_statement(statement, env:)
        lowered = []
        target = lower_assignment_target(statement.target, env:)
        prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
          statement.value,
          env:,
          expected_type: target.type,
          allow_root_statement_foreign: true,
        )
        lowered.concat(prepared_setup)

        if (foreign_call = foreign_call_info(prepared_value, env))
          setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
            foreign_call,
            env:,
            expected_type: target.type,
            statement_position: false,
          )
          lowered.concat(setup)
          raise LoweringError, "foreign call used in assignment must return a value" if call_type == @types.fetch("void")
          raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

          lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
          lowered.concat(cleanup_statements)
          update_cstr_metadata_for_assignment!(statement, prepared_value, env)
          return lowered
        end

        value = if statement.operator == "="
                  lower_contextual_expression(
                    prepared_value,
                    env:,
                    expected_type: target.type,
                    external_numeric: external_numeric_assignment_target?(statement.target, env:),
                    contextual_int_to_float: contextual_int_to_float_target?(target.type),
                  )
                else
                  lower_expression(statement.value, env:, expected_type: target.type)
                end
        update_cstr_metadata_for_assignment!(statement, prepared_value, env)
        if statement.operator == "=" && contains_proc_storage_type?(target.type)
          rhs_name = fresh_c_temp_name(env, "proc_assign")
          lowered << IR::LocalDecl.new(name: rhs_name, c_name: rhs_name, type: target.type, value:)
          rhs = IR::Name.new(name: rhs_name, type: target.type, pointer: false)
          lowered.concat(lower_proc_selective_retain_statements(rhs, statement.value, target.type))
          lowered.concat(lower_proc_contained_guarded_release_statements(target, target.type))
          lowered << IR::Assignment.new(target:, operator: "=", value: rhs)
        else
          lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
        end
        lowered
      end

      def lower_async_expression_statement(statement, env:)
        lowered = []
        prepared_setup, prepared_expression = prepare_expression_for_inline_lowering(
          statement.expression,
          env:,
          expected_type: infer_expression_type(statement.expression, env:),
          allow_root_statement_foreign: true,
        )
        lowered.concat(prepared_setup)

        if (foreign_call = foreign_call_info(prepared_expression, env))
          setup, = lower_foreign_call_statement(
            foreign_call,
            env:,
            expected_type: foreign_call[:binding].type.return_type,
            statement_position: true,
            discard_result: true,
          )
          lowered.concat(setup)
        else
          lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env:), line: statement.line, source_path: @current_analysis_path)
        end

        lowered
      end

      def lower_async_return_statement(statement, env:, frame_expr:, raw_frame_expr:, async_info:)
        lowered = []
        value = nil
        prepared_setup = []
        prepared_value = statement.value

        if statement.value
          prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
            statement.value,
            env:,
            expected_type: async_info[:result_type],
            allow_root_statement_foreign: true,
          )
          lowered.concat(prepared_setup)
        end

        if prepared_value && (foreign_call = foreign_call_info(prepared_value, env))
          setup, value = lower_foreign_call_statement(foreign_call, env:, expected_type: async_info[:result_type], statement_position: false)
          lowered.concat(setup)
        elsif prepared_value
          value = lower_contextual_expression(
            prepared_value,
            env:,
            expected_type: async_info[:result_type],
            contextual_int_to_float: contextual_int_to_float_target?(async_info[:result_type]),
          )
        end

        lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value:))
        lowered
      end

      def lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, field_info: nil)
        lowered = []
        await_expression = case statement
                           when AST::LocalDecl then statement.value
                           when AST::Assignment then statement.value
                           when AST::ExpressionStmt then statement.expression
                           when AST::ReturnStmt then statement.value
                           end
        prepared_setup, prepared_task = prepare_expression_for_inline_lowering(
          await_expression.expression,
          env:,
          expected_type: await_info[:task_type],
        )
        lowered.concat(prepared_setup)
        raise LoweringError, "await does not support foreign task expressions" if foreign_call_info(prepared_task, env)

        task_expr = async_frame_field_expression(frame_expr, await_info[:field_name], await_info[:task_type])
        task_frame_expr = async_task_frame_expression(task_expr, await_info[:task_type])
        ready_call = async_task_call(task_expr, await_info[:task_type], "ready", [task_frame_expr], @types.fetch("bool"))
        set_waiter_call = async_task_call(
          task_expr,
          await_info[:task_type],
          "set_waiter",
          [
            task_frame_expr,
            raw_frame_expr,
            IR::Name.new(name: resume_c_name, type: async_info[:wake_type], pointer: false),
          ],
          @types.fetch("void"),
        )
        take_result_call = async_task_call(task_expr, await_info[:task_type], "take_result", [task_frame_expr], await_info[:result_type])
        release_call = async_task_call(task_expr, await_info[:task_type], "release", [task_frame_expr], @types.fetch("void"))

        unless await_info[:reuse_existing_storage]
          lowered << IR::Assignment.new(
            target: task_expr,
            operator: "=",
            value: lower_contextual_expression(prepared_task, env:, expected_type: await_info[:task_type]),
          )
        end
        lowered << IR::IfStmt.new(
          condition: IR::Unary.new(operator: "not", operand: ready_call, type: @types.fetch("bool")),
          then_body: [
            IR::Assignment.new(
              target: async_frame_field_expression(frame_expr, "state", @types.fetch("i32")),
              operator: "=",
              value: IR::IntegerLiteral.new(value: await_info[:state], type: @types.fetch("i32")),
            ),
            IR::ExpressionStmt.new(expression: set_waiter_call),
            IR::ReturnStmt.new(value: nil),
          ],
          else_body: nil,
        )
        lowered << IR::LabelStmt.new(name: async_state_label(resume_c_name, await_info[:state]))

        case statement
        when AST::LocalDecl
          target = async_frame_field_expression(frame_expr, field_info[:field_name], field_info[:type])
          lowered << IR::Assignment.new(target:, operator: "=", value: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
        when AST::Assignment
          lowered << IR::Assignment.new(target: lower_assignment_target(statement.target, env:), operator: "=", value: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
        when AST::ExpressionStmt
          lowered << IR::ExpressionStmt.new(expression: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
        when AST::ReturnStmt
          if await_info[:result_type] == @types.fetch("void")
            lowered << IR::ExpressionStmt.new(expression: take_result_call)
            lowered << IR::ExpressionStmt.new(expression: release_call)
            lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
          else
            lowered << IR::Assignment.new(
              target: async_frame_field_expression(frame_expr, "result", async_info[:result_type]),
              operator: "=",
              value: take_result_call,
            )
            lowered << IR::ExpressionStmt.new(expression: release_call)
            lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
          end
        end

        lowered
      end

      def async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value:, result_already_stored: false)
        lowered = []

        if async_info[:result_type] != @types.fetch("void") && !result_already_stored
          lowered << IR::Assignment.new(
            target: async_frame_field_expression(frame_expr, "result", async_info[:result_type]),
            operator: "=",
            value: value,
          )
        end

        lowered << IR::Assignment.new(
          target: async_frame_field_expression(frame_expr, "ready", @types.fetch("bool")),
          operator: "=",
          value: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")),
        )

        waiter_frame_field = async_frame_field_expression(frame_expr, "waiter_frame", async_info[:void_ptr])
        lowered << IR::IfStmt.new(
          condition: IR::Binary.new(
            operator: "!=",
            left: waiter_frame_field,
            right: IR::NullLiteral.new(type: async_info[:void_ptr]),
            type: @types.fetch("bool"),
          ),
          then_body: [
            IR::LocalDecl.new(
              name: "waiter_frame",
              c_name: "__mt_waiter_frame",
              type: async_info[:void_ptr],
              value: waiter_frame_field,
            ),
            IR::Assignment.new(
              target: waiter_frame_field,
              operator: "=",
              value: IR::NullLiteral.new(type: async_info[:void_ptr]),
            ),
            IR::ExpressionStmt.new(
              expression: IR::Call.new(
                callee: async_frame_field_expression(frame_expr, "waiter", async_info[:wake_type]),
                arguments: [IR::Name.new(name: "__mt_waiter_frame", type: async_info[:void_ptr], pointer: false)],
                type: @types.fetch("void"),
              ),
            ),
            IR::ReturnStmt.new(value: nil),
          ],
          else_body: nil,
        )
        lowered << IR::ReturnStmt.new(value: nil)
        lowered
      end

      def lower_block(statements, env:, active_defers:, return_type:, loop_flow:, allow_return: true)
        local_env = duplicate_env(env)
        lowered = []
        local_defers = []

        statements.each do |statement|
          case statement
          when AST::DeferStmt
            local_defers << if statement.body
                              lower_defer_cleanup_body(statement.body, env: local_env, return_type:)
                            else
                              lower_defer_cleanup_expression(statement.expression, env: local_env)
                            end
          when AST::UnsafeStmt
            body = lower_block(
              statement.body,
              env: local_env,
              active_defers: active_defers + local_defers,
              return_type:,
              loop_flow: nested_loop_flow(loop_flow, local_defers),
              allow_return:,
            )
            lowered << IR::BlockStmt.new(body:)
          when AST::LocalDecl
            type = statement.type ? resolve_type_ref(statement.type) : infer_expression_type(statement.value, env: local_env)
            c_name = c_local_name(statement.name)
            prepared_setup = []
            prepared_value = statement.value
            prepared_cleanups = []
            emitted_decl = false
            if statement.value
              prepared_setup, prepared_value, prepared_cleanups = prepare_expression_with_cleanups(
                statement.value,
                env: local_env,
                expected_type: type,
                allow_root_statement_foreign: true,
              )
              lowered.concat(prepared_setup)
            end
            if prepared_value && (foreign_call = foreign_call_info(prepared_value, local_env))
              setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
                foreign_call,
                env: local_env,
                expected_type: type,
                statement_position: false,
              )
              lowered.concat(setup)
              raise LoweringError, "foreign call used to initialize #{statement.name} must return a value" if call_type == @types.fetch("void")
              raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

              lowered << IR::LocalDecl.new(name: statement.name, c_name:, type:, value:, line: statement.line, source_path: @current_analysis_path)
              lowered.concat(cleanup_statements)
              local_defers.concat(prepared_cleanups)
              emitted_decl = true
            elsif prepared_value.is_a?(AST::ProcExpr)
              setup, value = lower_proc_expression_for_local(prepared_value, env: local_env, local_name: statement.name, proc_type: type)
              lowered.concat(setup)
            elsif prepared_value
              value = lower_contextual_expression(
                prepared_value,
                env: local_env,
                expected_type: type,
                contextual_int_to_float: statement.type && contextual_int_to_float_target?(type),
              )
            else
              value = IR::ZeroInit.new(type:)
            end
            current_actual_scope(local_env[:scopes])[statement.name] = local_binding(
              type:,
              c_name:,
              mutable: statement.kind == :var,
              pointer: false,
              cstr_backed: cstr_backed_storage_value?(type, prepared_value, local_env),
              cstr_list_backed: cstr_list_backed_storage_value?(type, prepared_value, local_env),
            )
            lowered << IR::LocalDecl.new(name: statement.name, c_name:, type:, value:, line: statement.line, source_path: @current_analysis_path) unless emitted_decl
            local_defers.concat(prepared_cleanups)
            if contains_proc_storage_type?(type)
              local_value = IR::Name.new(name: c_name, type:, pointer: false)
              # Use guarded release so zero-initialized var locals are safe (invoke == NULL guard).
              local_defers << lower_proc_contained_guarded_release_statements(local_value, type)
              if statement.value && !expression_contains_proc_expr?(statement.value)
                lowered.concat(lower_proc_contained_retain_statements(local_value, type))
              end
            end
          when AST::Assignment
            if statement.operator == "=" &&
               statement.target.is_a?(AST::IndexAccess) &&
               statement.target.index.is_a?(AST::RangeExpr) &&
               statement.value.is_a?(AST::TupleLiteral)
              lowered.concat(lower_range_index_assignment(statement, env: local_env))
              next
            end
            target = lower_assignment_target(statement.target, env: local_env)
            prepared_cleanups = []
            prepared_setup, prepared_value, prepared_cleanups = prepare_expression_with_cleanups(
              statement.value,
              env: local_env,
              expected_type: target.type,
              allow_root_statement_foreign: true,
            )
            lowered.concat(prepared_setup)
            if (foreign_call = foreign_call_info(prepared_value, local_env))
              setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
                foreign_call,
                env: local_env,
                expected_type: target.type,
                statement_position: false,
              )
              lowered.concat(setup)
              raise LoweringError, "foreign call used in assignment must return a value" if call_type == @types.fetch("void")
              raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

              lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
              lowered.concat(cleanup_statements)
              update_cstr_metadata_for_assignment!(statement, prepared_value, local_env)
              local_defers.concat(prepared_cleanups)
              next
            else
              value = if statement.operator == "="
                        lower_contextual_expression(
                          prepared_value,
                          env: local_env,
                          expected_type: target.type,
                          external_numeric: external_numeric_assignment_target?(statement.target, env: local_env),
                          contextual_int_to_float: contextual_int_to_float_target?(target.type),
                        )
                      else
                        lower_expression(statement.value, env: local_env, expected_type: target.type)
                      end
            end
            update_cstr_metadata_for_assignment!(statement, prepared_value, local_env)
            local_defers.concat(prepared_cleanups)
            if statement.operator == "=" && contains_proc_storage_type?(target.type)
              # Materialize the RHS to a C temp to avoid evaluating aggregate literals multiple times
              # and to ensure retain/release operate on a stable struct value throughout the sequence.
              rhs_name = fresh_c_temp_name(local_env, "proc_assign")
              lowered << IR::LocalDecl.new(name: rhs_name, c_name: rhs_name, type: target.type, value:)
              rhs = IR::Name.new(name: rhs_name, type: target.type, pointer: false)
              # Retain proc fields in the incoming value that are NOT from fresh proc expressions
              # (fresh proc exprs carry refcount=1 and transfer ownership; existing procs need +1).
              lowered.concat(lower_proc_selective_retain_statements(rhs, statement.value, target.type))
              # Release old proc fields in the target (guarded: target may be zero-initialized).
              lowered.concat(lower_proc_contained_guarded_release_statements(target, target.type))
              lowered << IR::Assignment.new(target:, operator: "=", value: rhs)
            else
              lowered << IR::Assignment.new(target:, operator: statement.operator, value:)
            end
          when AST::IfStmt
            false_refinements = {}
            branch_entries = []

            statement.branches.each do |branch|
              branch_env = env_with_refinements(local_env, false_refinements)
              condition_setup, prepared_condition, condition_cleanups = prepare_expression_with_cleanups(
                branch.condition,
                env: branch_env,
                expected_type: @types.fetch("bool"),
              )
              true_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: true, env: branch_env))

              branch_entries << [
                condition_setup,
                condition_cleanups,
                lower_expression(prepared_condition, env: branch_env, expected_type: @types.fetch("bool")),
                lower_block(
                  branch.body,
                  env: env_with_refinements(local_env, true_refinements),
                  active_defers: active_defers + local_defers,
                  return_type:,
                  loop_flow: nested_loop_flow(loop_flow, local_defers),
                  allow_return:,
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
              allow_return:,
            ) : []

            nested_if = nested_else_body
            branch_entries.reverse_each do |condition_setup, condition_cleanups, condition, then_body|
              condition_cleanup_statements = condition_cleanups.flat_map(&:itself)
              nested_if = [
                *condition_setup,
                IR::IfStmt.new(
                  condition:,
                  then_body: condition_cleanup_statements + then_body,
                  else_body: condition_cleanup_statements + nested_if,
                ),
              ]
            end
            lowered.concat(nested_if)

            merge_cstr_metadata_after_if_statement!(statement, local_env)

            if statement.else_body.nil? && statement.branches.all? { |branch| cfg_block_always_terminates?(branch.body) }
              local_env[:scopes] = scopes_with_refinements(local_env[:scopes], false_refinements)
            end
          when AST::MatchStmt
            scrutinee_type = infer_expression_type(statement.expression, env: local_env)
            expression_setup, prepared_expression, expression_cleanups = prepare_expression_with_cleanups(
              statement.expression,
              env: local_env,
              expected_type: scrutinee_type,
            )
            lowered.concat(expression_setup)
            expression = lower_expression(prepared_expression, env: local_env, expected_type: scrutinee_type)

            if scrutinee_type.is_a?(Types::Variant)
              outer_c = c_type_name(scrutinee_type)
              kind_type = @types.fetch("i32")
              kind_expr = IR::Member.new(receiver: expression, member: "kind", type: kind_type)
              cases = statement.arms.map do |arm|
                arm_local_env = duplicate_env(local_env)
                binding_decl = if arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
                                 arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                                 if arm_name && scrutinee_type.has_payload?(arm_name)
                                   fields = scrutinee_type.arm(arm_name)
                                   payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
                                   data_expr = IR::Member.new(receiver: expression, member: "data", type: nil)
                                   arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
                                   binding_c = c_local_name(arm.binding_name)
                                   arm_local_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: binding_c, mutable: false, pointer: false)
                                   IR::LocalDecl.new(name: arm.binding_name, c_name: binding_c, type: payload_type, value: arm_expr)
                                 end
                               end
                body = lower_block(
                  arm.body,
                  env: arm_local_env,
                  active_defers: active_defers + local_defers,
                  return_type:,
                  loop_flow: nested_loop_flow(loop_flow, local_defers),
                  allow_return:,
                )
                body = [binding_decl, *body].compact if binding_decl
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body:)
                else
                  arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                  IR::SwitchCase.new(value: IR::Name.new(name: "#{outer_c}_kind_#{arm_name}", type: kind_type, pointer: false), body:)
                end
              end
              lowered << IR::SwitchStmt.new(expression: kind_expr, cases:)
            else
              cases = statement.arms.map do |arm|
                body = lower_block(
                  arm.body,
                  env: local_env,
                  active_defers: active_defers + local_defers,
                  return_type:,
                  loop_flow: nested_loop_flow(loop_flow, local_defers),
                  allow_return:,
                )
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body:)
                else
                  value = lower_expression(arm.pattern, env: local_env, expected_type: scrutinee_type)
                  IR::SwitchCase.new(value:, body:)
                end
              end
              lowered << IR::SwitchStmt.new(expression:, cases:)
            end
            lowered.concat(expression_cleanups.flat_map(&:itself))
          when AST::StaticAssert
            lowered << IR::StaticAssert.new(
              condition: lower_expression(statement.condition, env: local_env, expected_type: @types.fetch("bool")),
              message: lower_expression(statement.message, env: local_env, expected_type: @types.fetch("str")),
            )
          when AST::ForStmt
            lowered << lower_for_stmt(statement, env: local_env, active_defers: active_defers + local_defers, return_type:, allow_return:)
          when AST::WhileStmt
            lowered << lower_while_stmt(statement, env: local_env, active_defers: active_defers + local_defers, return_type:, allow_return:)
          when AST::BreakStmt
            raise LoweringError, "break must be inside a loop" unless loop_flow

            lowered.concat(lower_loop_exit(loop_flow[:break_target], local_defers, loop_flow[:break_defers]))
          when AST::ContinueStmt
            raise LoweringError, "continue must be inside a loop" unless loop_flow

            lowered.concat(lower_loop_exit(loop_flow[:continue_target], local_defers, loop_flow[:continue_defers]))
          when AST::ReturnStmt
            raise LoweringError, "return is not allowed inside defer blocks" unless allow_return

            value = nil
            prepared_setup = []
            prepared_value = statement.value
            prepared_cleanups = []
            if statement.value
              prepared_setup, prepared_value, prepared_cleanups = prepare_expression_with_cleanups(
                statement.value,
                env: local_env,
                expected_type: return_type,
                allow_root_statement_foreign: true,
              )
              lowered.concat(prepared_setup)
            end
            if prepared_value && (foreign_call = foreign_call_info(prepared_value, local_env))
              setup, value = lower_foreign_call_statement(foreign_call, env: local_env, expected_type: return_type, statement_position: false)
              lowered.concat(setup)
            end
            value ||= prepared_value ? lower_contextual_expression(
              prepared_value,
              env: local_env,
              expected_type: return_type,
              contextual_int_to_float: contextual_int_to_float_target?(return_type),
            ) : nil
            if prepared_cleanups.any? && cstr_trackable_type?(return_type)
              raise LoweringError, "formatted string temporaries cannot be returned as borrowed text; use fmt.string(...) when ownership must escape"
            end

            cleanup = prepared_cleanups.flat_map(&:itself) + cleanup_statements(local_defers, active_defers)
            needs_proc_retain = value && contains_proc_storage_type?(return_type) && !local_defers.empty? && !expression_contains_proc_expr?(prepared_value)
            if value && (!cleanup.empty? && !cleanup_safe_return_expression?(prepared_value) || needs_proc_retain)
              return_value_name = fresh_c_temp_name(local_env, "return_value")
              lowered << IR::LocalDecl.new(name: return_value_name, c_name: return_value_name, type: return_type, value:)
              value = IR::Name.new(name: return_value_name, type: return_type, pointer: false)
            end
            lowered.concat(lower_proc_contained_retain_statements(value, return_type)) if needs_proc_retain
            lowered.concat(cleanup)
            lowered << IR::ReturnStmt.new(value:, line: statement.line, source_path: @current_analysis_path)
          when AST::ExpressionStmt
            prepared_setup, prepared_expression, prepared_cleanups = prepare_expression_with_cleanups(
              statement.expression,
              env: local_env,
              expected_type: infer_expression_type(statement.expression, env: local_env),
              allow_root_statement_foreign: true,
            )
            lowered.concat(prepared_setup)
            if (foreign_call = foreign_call_info(prepared_expression, local_env))
              setup, value = lower_foreign_call_statement(
                foreign_call,
                env: local_env,
                expected_type: foreign_call[:binding].type.return_type,
                statement_position: true,
                discard_result: true,
              )
              lowered.concat(setup)
              lowered.concat(prepared_cleanups.flat_map(&:itself))
              local_env[:scopes] = scopes_with_refinements(local_env[:scopes], consuming_foreign_call_refinements(foreign_call, local_env))
            else
              lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env: local_env), line: statement.line, source_path: @current_analysis_path)
              lowered.concat(prepared_cleanups.flat_map(&:itself))
            end
          else
            raise LoweringError, "unsupported statement #{statement.class.name}"
          end
        end

        unless terminating_ir_statement?(lowered.last)
          lowered.concat(cleanup_statements(local_defers, []))
        end
        lowered
      end

      def lower_proc_expression_for_local(expression, env:, local_name:, proc_type:)
        captures = proc_capture_entries(expression, env)
        captures.each do |capture|
          if ref_type?(capture[:type]) || contains_ref_type?(capture[:type])
            raise LoweringError, "proc capture #{capture[:name]} cannot use ref types"
          end
          raise LoweringError, "proc capture #{capture[:name]} cannot capture proc values" if proc_type?(capture[:type])
          raise LoweringError, "proc capture #{capture[:name]} cannot capture array values yet" if array_type?(capture[:type])
        end

        proc_id = fresh_proc_symbol
        invoke_c_name = "#{@module_prefix}__proc_#{proc_id}__invoke"
        release_c_name = "#{@module_prefix}__proc_#{proc_id}__release"
        retain_c_name = "#{@module_prefix}__proc_#{proc_id}__retain"
        env_struct_type = nil
        setup = []

        env_value = if captures.empty?
                      IR::NullLiteral.new(type: proc_env_pointer_type)
                    else
                      env_struct_type = Types::Struct.new("#{@module_prefix}__proc_#{proc_id}__env").define_fields(
                        { "__mt_ref_count" => @types.fetch("usize") }.merge(captures.each_with_object({}) { |capture, fields| fields[capture[:field_name]] = capture[:type] }),
                      )
                      @synthetic_structs << IR::StructDecl.new(
                        name: env_struct_type.name,
                        c_name: env_struct_type.name,
                        fields: [IR::Field.new(name: "__mt_ref_count", type: @types.fetch("usize")), *captures.map { |capture| IR::Field.new(name: capture[:field_name], type: capture[:type]) }],
                        packed: false,
                        alignment: nil,
                      )

                      env_pointer_type = pointer_to(env_struct_type)
                      env_name = fresh_c_temp_name(env, "#{local_name}_env")
                      raw_allocation = IR::Call.new(
                        callee: "malloc",
                        arguments: [IR::SizeofExpr.new(target_type: env_struct_type, type: @types.fetch("usize"))],
                        type: proc_env_pointer_type,
                      )
                      setup << IR::LocalDecl.new(
                        name: env_name,
                        c_name: env_name,
                        type: env_pointer_type,
                        value: IR::Cast.new(target_type: env_pointer_type, expression: raw_allocation, type: env_pointer_type),
                      )
                      env_pointer = IR::Name.new(name: env_name, type: env_pointer_type, pointer: false)
                      setup << IR::Assignment.new(
                        target: IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @types.fetch("usize")),
                        operator: "=",
                        value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("usize")),
                      )
                      captures.each do |capture|
                        setup << IR::Assignment.new(
                          target: IR::Member.new(receiver: env_pointer, member: capture[:field_name], type: capture[:type]),
                          operator: "=",
                          value: lower_expression(AST::Identifier.new(name: capture[:name]), env:, expected_type: capture[:type]),
                        )
                      end
                      IR::Cast.new(target_type: proc_env_pointer_type, expression: env_pointer, type: proc_env_pointer_type)
                    end

        @synthetic_functions << build_proc_invoke_function(expression, proc_type, captures, env_struct_type, invoke_c_name)
        @synthetic_functions << build_proc_release_function(release_c_name, env_struct_type)
        @synthetic_functions << build_proc_retain_function(retain_c_name, env_struct_type)

        [
          setup,
          IR::AggregateLiteral.new(
            type: proc_type,
            fields: [
              IR::AggregateField.new(name: "env", value: env_value),
              IR::AggregateField.new(name: "invoke", value: IR::Name.new(name: invoke_c_name, type: proc_invoke_function_type(proc_type), pointer: false)),
              IR::AggregateField.new(name: "release", value: IR::Name.new(name: release_c_name, type: proc_release_function_type, pointer: false)),
              IR::AggregateField.new(name: "retain", value: IR::Name.new(name: retain_c_name, type: proc_retain_function_type, pointer: false)),
            ],
          ),
        ]
      end

      def build_proc_invoke_function(expression, proc_type, captures, env_struct_type, invoke_c_name)
        env = empty_env
        params = [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)]
        parameter_setup = []

        if env_struct_type
          env_pointer_type = pointer_to(env_struct_type)
          env_pointer_name = "__mt_proc_env_ptr"
          env[:scopes].last[env_pointer_name] = local_binding(type: env_pointer_type, c_name: env_pointer_name, mutable: false, pointer: false)
          parameter_setup << IR::LocalDecl.new(
            name: env_pointer_name,
            c_name: env_pointer_name,
            type: env_pointer_type,
            value: IR::Cast.new(
              target_type: env_pointer_type,
              expression: IR::Name.new(name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false),
              type: env_pointer_type,
            ),
          )

          env_pointer = IR::Name.new(name: env_pointer_name, type: env_pointer_type, pointer: false)
          captures.each do |capture|
            capture_c_name = "__mt_capture_#{capture[:name]}"
            env[:scopes].last[capture[:name]] = local_binding(type: capture[:type], c_name: capture_c_name, mutable: false, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: capture[:name],
              c_name: capture_c_name,
              type: capture[:type],
              value: IR::Member.new(receiver: env_pointer, member: capture[:field_name], type: capture[:type]),
            )
          end
        end

        expression.params.each_with_index do |param, index|
          type = proc_type.params.fetch(index).type
          c_name = c_local_name(param.name)
          if array_type?(type)
            input_c_name = "#{c_name}_input"
            params << IR::Param.new(name: param.name, c_name: input_c_name, type:, pointer: false)
            env[:scopes].last[param.name] = local_binding(type:, c_name:, mutable: false, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param.name,
              c_name:,
              type:,
              value: IR::Name.new(name: input_c_name, type:, pointer: false),
            )
          else
            env[:scopes].last[param.name] = local_binding(type:, c_name:, mutable: false, pointer: false)
            params << IR::Param.new(name: param.name, c_name:, type:, pointer: false)
          end
        end

        body = parameter_setup + lower_block(expression.body, env:, active_defers: [], return_type: proc_type.return_type, loop_flow: nil, allow_return: true)
        IR::Function.new(name: invoke_c_name, c_name: invoke_c_name, params:, return_type: proc_type.return_type, body:, entry_point: false)
      end

      def build_proc_release_function(release_c_name, env_struct_type)
        return build_proc_noop_release_function(release_c_name) unless env_struct_type

        env_pointer_type = pointer_to(env_struct_type)
        env_pointer = IR::Name.new(name: "__mt_proc_env_ptr", type: env_pointer_type, pointer: false)
        ref_count = IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @types.fetch("usize"))
        IR::Function.new(
          name: release_c_name,
          c_name: release_c_name,
          params: [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)],
          return_type: @types.fetch("void"),
          body: [
            IR::LocalDecl.new(
              name: "__mt_proc_env_ptr",
              c_name: "__mt_proc_env_ptr",
              type: env_pointer_type,
              value: IR::Cast.new(target_type: env_pointer_type, expression: IR::Name.new(name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false), type: env_pointer_type),
            ),
            IR::Assignment.new(target: ref_count, operator: "-=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("usize"))),
            IR::IfStmt.new(
              condition: IR::Binary.new(operator: "==", left: ref_count, right: IR::IntegerLiteral.new(value: 0, type: @types.fetch("usize")), type: @types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(
                  expression: IR::Call.new(
                    callee: "free",
                    arguments: [IR::Name.new(name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)],
                    type: @types.fetch("void"),
                  ),
                ),
              ],
              else_body: nil,
            ),
            IR::ReturnStmt.new(value: nil),
          ],
          entry_point: false,
        )
      end

      def build_proc_retain_function(retain_c_name, env_struct_type)
        return build_proc_noop_retain_function(retain_c_name) unless env_struct_type

        env_pointer_type = pointer_to(env_struct_type)
        env_pointer = IR::Name.new(name: "__mt_proc_env_ptr", type: env_pointer_type, pointer: false)
        ref_count = IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @types.fetch("usize"))
        IR::Function.new(
          name: retain_c_name,
          c_name: retain_c_name,
          params: [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)],
          return_type: @types.fetch("void"),
          body: [
            IR::LocalDecl.new(
              name: "__mt_proc_env_ptr",
              c_name: "__mt_proc_env_ptr",
              type: env_pointer_type,
              value: IR::Cast.new(target_type: env_pointer_type, expression: IR::Name.new(name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false), type: env_pointer_type),
            ),
            IR::Assignment.new(target: ref_count, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("usize"))),
            IR::ReturnStmt.new(value: nil),
          ],
          entry_point: false,
        )
      end

      def proc_capture_entries(expression, env)
        local_scopes = [expression.params.each_with_object({}) { |param, names| names[param.name] = true }]
        captures = {}
        collect_proc_captures_from_statements(expression.body, env, local_scopes, captures)
        captures.values
      end

      def collect_proc_captures_from_statements(statements, env, local_scopes, captures)
        statements.each do |statement|
          collect_proc_captures_from_statement(statement, env, local_scopes, captures)
        end
      end

      def collect_proc_captures_from_statement(statement, env, local_scopes, captures)
        case statement
        when AST::LocalDecl
          collect_proc_captures_from_expression(statement.value, env, local_scopes, captures) if statement.value
          local_scopes.last[statement.name] = true
        when AST::Assignment
          collect_proc_captures_from_expression(statement.target, env, local_scopes, captures)
          collect_proc_captures_from_expression(statement.value, env, local_scopes, captures)
        when AST::IfStmt
          statement.branches.each do |branch|
            collect_proc_captures_from_expression(branch.condition, env, local_scopes, captures)
            collect_proc_captures_from_statements(branch.body, env, local_scopes + [{}], captures)
          end
          collect_proc_captures_from_statements(statement.else_body, env, local_scopes + [{}], captures) if statement.else_body
        when AST::MatchStmt
          collect_proc_captures_from_expression(statement.expression, env, local_scopes, captures)
          statement.arms.each do |arm|
            collect_proc_captures_from_expression(arm.pattern, env, local_scopes, captures)
            collect_proc_captures_from_statements(arm.body, env, local_scopes + [{}], captures)
          end
        when AST::UnsafeStmt
          collect_proc_captures_from_statements(statement.body, env, local_scopes + [{}], captures)
        when AST::StaticAssert
          collect_proc_captures_from_expression(statement.condition, env, local_scopes, captures)
          collect_proc_captures_from_expression(statement.message, env, local_scopes, captures)
        when AST::ForStmt
          collect_proc_captures_from_expression(statement.iterable, env, local_scopes, captures)
          collect_proc_captures_from_statements(statement.body, env, local_scopes + [{ statement.name => true }], captures)
        when AST::WhileStmt
          collect_proc_captures_from_expression(statement.condition, env, local_scopes, captures)
          collect_proc_captures_from_statements(statement.body, env, local_scopes + [{}], captures)
        when AST::ReturnStmt
          collect_proc_captures_from_expression(statement.value, env, local_scopes, captures) if statement.value
        when AST::DeferStmt
          if statement.body
            collect_proc_captures_from_statements(statement.body, env, local_scopes + [{}], captures)
          else
            collect_proc_captures_from_expression(statement.expression, env, local_scopes, captures)
          end
        when AST::ExpressionStmt
          collect_proc_captures_from_expression(statement.expression, env, local_scopes, captures)
        when AST::BreakStmt, AST::ContinueStmt
          nil
        else
          raise LoweringError, "unsupported proc capture statement #{statement.class.name}"
        end
      end

      def collect_proc_captures_from_expression(expression, env, local_scopes, captures)
        return unless expression

        case expression
        when AST::Identifier
          return if local_scopes.any? { |scope| scope.key?(expression.name) }

          if (binding = proc_capture_binding(expression.name, env))
            captures[expression.name] ||= { name: expression.name, field_name: expression.name, type: binding[:type] }
          end
        when AST::MemberAccess
          collect_proc_captures_from_expression(expression.receiver, env, local_scopes, captures)
        when AST::IndexAccess
          collect_proc_captures_from_expression(expression.receiver, env, local_scopes, captures)
          collect_proc_captures_from_expression(expression.index, env, local_scopes, captures)
        when AST::Specialization
          collect_proc_captures_from_expression(expression.callee, env, local_scopes, captures)
          expression.arguments.each { |argument| collect_proc_captures_from_expression(argument.value, env, local_scopes, captures) }
        when AST::Call
          collect_proc_captures_from_expression(expression.callee, env, local_scopes, captures)
          expression.arguments.each { |argument| collect_proc_captures_from_expression(argument.value, env, local_scopes, captures) }
        when AST::UnaryOp
          collect_proc_captures_from_expression(expression.operand, env, local_scopes, captures)
        when AST::BinaryOp
          collect_proc_captures_from_expression(expression.left, env, local_scopes, captures)
          collect_proc_captures_from_expression(expression.right, env, local_scopes, captures)
        when AST::IfExpr
          collect_proc_captures_from_expression(expression.condition, env, local_scopes, captures)
          collect_proc_captures_from_expression(expression.then_expression, env, local_scopes, captures)
          collect_proc_captures_from_expression(expression.else_expression, env, local_scopes, captures)
        when AST::AwaitExpr
          collect_proc_captures_from_expression(expression.expression, env, local_scopes, captures)
        when AST::FormatString
          expression.parts.each do |part|
            collect_proc_captures_from_expression(part.expression, env, local_scopes, captures) if part.is_a?(AST::FormatExprPart)
          end
        when AST::ProcExpr, AST::TypeRef, AST::FunctionType, AST::ProcType,
             AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr,
             AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral,
             AST::BooleanLiteral, AST::NullLiteral
          nil
        else
          raise LoweringError, "unsupported proc capture expression #{expression.class.name}"
        end
      end

      def proc_capture_binding(name, env)
        env[:scopes].reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        nil
      end

      def lower_proc_release_expression(proc_expression, _proc_type)
        IR::Call.new(
          callee: IR::Member.new(receiver: proc_expression, member: "release", type: proc_release_function_type),
          arguments: [IR::Member.new(receiver: proc_expression, member: "env", type: proc_env_pointer_type)],
          type: @types.fetch("void"),
        )
      end

      def lower_proc_retain_expression(proc_expression, _proc_type)
        IR::Call.new(
          callee: IR::Member.new(receiver: proc_expression, member: "retain", type: proc_retain_function_type),
          arguments: [IR::Member.new(receiver: proc_expression, member: "env", type: proc_env_pointer_type)],
          type: @types.fetch("void"),
        )
      end

      def lower_proc_contained_release_statements(value_expression, type)
        lower_proc_contained_lifecycle_statements(value_expression, type, :release)
      end

      # Null-guarded release: safe when value may be zero-initialized (var locals, async frame fields).
      # Wraps each proc release in `if (proc.invoke) { proc.release(proc.env); }`.
      def lower_proc_contained_guarded_release_statements(value_expression, type)
        lower_proc_contained_lifecycle_statements(value_expression, type, :release, guarded: true)
      end

      # Alias used for async frame fields (always guarded).
      def lower_async_frame_proc_release_statements(value_expression, type)
        lower_proc_contained_lifecycle_statements(value_expression, type, :release, guarded: true)
      end

      def lower_proc_contained_retain_statements(value_expression, type)
        lower_proc_contained_lifecycle_statements(value_expression, type, :retain)
      end

      def lower_proc_contained_lifecycle_statements(value_expression, type, mode, guarded: false)
        return [] unless contains_proc_storage_type?(type)

        if proc_type?(type)
          if mode == :release && guarded
            invoke_member = IR::Member.new(receiver: value_expression, member: "invoke", type: proc_invoke_function_type(type))
            release_stmt = IR::ExpressionStmt.new(expression: lower_proc_release_expression(value_expression, type))
            return [IR::IfStmt.new(condition: invoke_member, then_body: [release_stmt], else_body: nil)]
          end
          expression = mode == :retain ? lower_proc_retain_expression(value_expression, type) : lower_proc_release_expression(value_expression, type)
          return [IR::ExpressionStmt.new(expression:)]
        end

        case type
        when Types::Struct, Types::StructInstance
          statements = []
          type.fields.each do |field_name, field_type|
            next unless contains_proc_storage_type?(field_type)

            member = IR::Member.new(receiver: value_expression, member: field_name, type: field_type)
            statements.concat(lower_proc_contained_lifecycle_statements(member, field_type, mode, guarded:))
          end
          statements
        when Types::Nullable
          []
        else
          raise LoweringError, "unsupported proc lifecycle container #{type.class.name}"
        end
      end

      # Retain only proc fields that did NOT originate from a fresh proc expression in `original_ast`.
      # Fresh proc expressions already carry refcount=1; retaining them would over-count.
      # For existing proc values (variables, member accesses, return values), we retain to share ownership.
      # When `original_ast` is a struct aggregate literal (AST::Call), fields are matched by name.
      def lower_proc_selective_retain_statements(ir_value, original_ast, type)
        return [] unless contains_proc_storage_type?(type)

        if proc_type?(type)
          # If the direct expression is a fresh proc, ownership transfers — no retain needed.
          return [] if expression_contains_proc_expr?(original_ast)

          return [IR::ExpressionStmt.new(expression: lower_proc_retain_expression(ir_value, type))]
        end

        case type
        when Types::Struct, Types::StructInstance
          statements = []
          type.fields.each do |field_name, field_type|
            next unless contains_proc_storage_type?(field_type)

            # Try to extract the AST sub-expression for this specific field when the source
            # is a struct aggregate literal (struct-name(field = value, ...)).
            ast_field_source = if original_ast.is_a?(AST::Call)
                                 original_ast.arguments.find { |arg| arg.name == field_name }&.value
                               end
            # Fall back to the whole RHS expression (conservative — treats as existing proc → retains).
            ast_field_source ||= original_ast

            member = IR::Member.new(receiver: ir_value, member: field_name, type: field_type)
            statements.concat(lower_proc_selective_retain_statements(member, ast_field_source, field_type))
          end
          statements
        when Types::Nullable
          []
        else
          []
        end
      end

      def expression_contains_proc_expr?(expression)
        return false unless expression

        case expression
        when AST::ProcExpr
          true
        when AST::MemberAccess
          expression_contains_proc_expr?(expression.receiver)
        when AST::IndexAccess
          expression_contains_proc_expr?(expression.receiver) || expression_contains_proc_expr?(expression.index)
        when AST::UnaryOp
          expression_contains_proc_expr?(expression.operand)
        when AST::BinaryOp
          expression_contains_proc_expr?(expression.left) || expression_contains_proc_expr?(expression.right)
        when AST::IfExpr
          expression_contains_proc_expr?(expression.condition) ||
            expression_contains_proc_expr?(expression.then_expression) ||
            expression_contains_proc_expr?(expression.else_expression)
        when AST::AwaitExpr
          expression_contains_proc_expr?(expression.expression)
        when AST::Call
          expression_contains_proc_expr?(expression.callee) || expression.arguments.any? { |argument| expression_contains_proc_expr?(argument.value) }
        when AST::Specialization
          expression_contains_proc_expr?(expression.callee)
        else
          false
        end
      end

      def lower_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        return lower_range_for_stmt(statement, env:, active_defers:, return_type:, allow_return:) if range_iterable?(statement.iterable)

        lower_collection_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
      end

      def lower_while_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        condition_setup, prepared_condition, condition_cleanups = prepare_expression_with_cleanups(
          statement.condition,
          env:,
          expected_type: @types.fetch("bool"),
        )

        body = lower_block(
          statement.body,
          env: env_with_refinements(duplicate_env(env), flow_refinements(statement.condition, truthy: true, env: env)),
          active_defers:,
          return_type:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
          allow_return:,
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        condition = lower_expression(prepared_condition, env:, expected_type: @types.fetch("bool"))

        if condition_setup.empty? && condition_cleanups.empty?
          statements = [
            IR::WhileStmt.new(
              condition:,
              body:,
            ),
          ]
          statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
          return IR::BlockStmt.new(body: statements)
        end

        loop_body = [
          *condition_setup,
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: condition, type: @types.fetch("bool")),
            then_body: condition_cleanups.flat_map(&:itself) + [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: condition_cleanups.flat_map(&:itself),
          ),
          *body,
        ]

        statements = [
          IR::WhileStmt.new(
            condition: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")),
            body: loop_body,
          ),
        ]
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(loop_body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_range_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        loop_type = infer_range_loop_type(statement.iterable, env:)
        start_expr = range_start_of(statement.iterable)
        stop_expr = range_end_of(statement.iterable)
        start_setup, prepared_start = prepare_expression_for_inline_lowering(start_expr, env:, expected_type: loop_type)
        stop_setup, prepared_stop = prepare_expression_for_inline_lowering(stop_expr, env:, expected_type: loop_type)
        index_c_name = c_local_name(statement.name)
        stop_c_name = fresh_c_temp_name(env, "for_stop")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_c_name, type: loop_type, pointer: false)
        inline_stop = stop_setup.empty? && compile_time_numeric_const_expression?(prepared_stop)
        stop_value = if inline_stop
                       lower_expression(prepared_stop, env:, expected_type: loop_type)
                     else
                       IR::Name.new(name: stop_c_name, type: loop_type, pointer: false)
                     end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(type: loop_type, c_name: c_local_name(statement.name), mutable: false, pointer: false)

        body = []
        body.concat(
          lower_block(
            statement.body,
            env: while_env,
            active_defers:,
            return_type:,
            loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
            allow_return:,
          ),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: statement.name, c_name: index_c_name, type: loop_type, value: lower_expression(prepared_start, env:, expected_type: loop_type)),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: loop_type),
          ),
          body:,
        )

        statements = [
          *start_setup,
          *stop_setup,
          for_statement,
        ]
        unless inline_stop
          statements.insert(
            statements.length - 1,
            IR::LocalDecl.new(name: stop_c_name, c_name: stop_c_name, type: loop_type, value: lower_expression(prepared_stop, env:, expected_type: loop_type)),
          )
        end
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_collection_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects range(start, stop), array[T, N], or span[T], got #{iterable_type}" unless element_type
        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)

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
            loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
            allow_return:,
          ),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("usize"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("usize"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("usize")),
          ),
          body:,
        )

        statements = [
          *iterable_setup,
          IR::LocalDecl.new(name: iterable_c_name, c_name: iterable_c_name, type: iterable_type, value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
          for_statement,
        ]
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_range_index_assignment(statement, env:)
        range = statement.target.index
        start_val = range.start_expr.value
        end_val = range.end_expr.value
        receiver_type = infer_expression_type(statement.target.receiver, env:)
        element_type = infer_index_result_type(receiver_type, @types.fetch("usize"))

        receiver_setup, prepared_receiver = prepare_expression_for_inline_lowering(statement.target.receiver, env:, expected_type: receiver_type)
        statements = receiver_setup.dup

        statement.value.elements.each_with_index do |elem, i|
          index_ir = IR::IntegerLiteral.new(value: start_val + i, type: @types.fetch("usize"))
          target_ir = IR::Index.new(
            receiver: lower_expression(prepared_receiver, env:, expected_type: receiver_type),
            index: index_ir,
            type: element_type,
          )
          value_ir = lower_contextual_expression(
            elem,
            env:,
            expected_type: element_type,
            contextual_int_to_float: contextual_int_to_float_target?(element_type),
          )
          statements << IR::Assignment.new(target: target_ir, operator: "=", value: value_ir)
        end

        statements
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
          index = lower_expression(expression.index, env:)
          type = infer_expression_type(expression, env:)
          if array_type?(receiver_type)
            IR::CheckedIndex.new(receiver:, index:, receiver_type:, type:)
          elsif receiver_type.is_a?(Types::Span)
            IR::CheckedSpanIndex.new(receiver:, index:, receiver_type:, type:)
          else
            IR::Index.new(receiver:, index:, type:)
          end
        when AST::Call
          if read_call?(expression)
            type = infer_expression_type(expression, env:)
            operand = lower_expression(expression.arguments.first.value, env:)
            return IR::Unary.new(operator: "*", operand:, type:)
          end

          raise LoweringError, "unsupported assignment target #{expression.class.name}"
        else
          raise LoweringError, "unsupported assignment target #{expression.class.name}"
        end
      end

      def prepare_expression_with_cleanups(expression, env:, expected_type: nil, allow_root_statement_foreign: false)
        env[:prepared_expression_cleanups] ||= []
        start_index = env[:prepared_expression_cleanups].length
        setup, prepared_expression = prepare_expression_for_inline_lowering(
          expression,
          env:,
          expected_type:,
          allow_root_statement_foreign:,
        )
        cleanup_count = env[:prepared_expression_cleanups].length - start_index
        cleanups = cleanup_count.positive? ? env[:prepared_expression_cleanups].slice!(start_index, cleanup_count) : []
        [setup, prepared_expression, cleanups || []]
      end

      def prepare_expression_for_inline_lowering(expression, env:, expected_type: nil, allow_root_statement_foreign: false)
        return [[], expression] unless expression

        if expression.is_a?(AST::Call) && (foreign_call = foreign_call_info(expression, env)) && !allow_root_statement_foreign &&
            foreign_call_requires_statement_lowering?(expression, foreign_call[:binding], env:)
          type = infer_expression_type(expression, env:, expected_type:)
          setup, value = lower_foreign_call_statement(foreign_call, env:, expected_type: type, statement_position: false)
          return materialize_prepared_expression(setup, value, env:, type:, prefix: "foreign_expr")
        end

        case expression
        when AST::FormatString
          prepare_format_string_expression_for_inline_lowering(expression, env:)
        when AST::MemberAccess
          receiver_setup, receiver = prepare_expression_for_inline_lowering(expression.receiver, env:)
          [receiver_setup, AST::MemberAccess.new(receiver:, member: expression.member)]
        when AST::IndexAccess
          receiver_setup, receiver = prepare_expression_for_inline_lowering(expression.receiver, env:)
          index_setup, index = prepare_expression_for_inline_lowering(expression.index, env:)
          [receiver_setup + index_setup, AST::IndexAccess.new(receiver:, index:)]
        when AST::UnaryOp
          operand_setup, operand = prepare_expression_for_inline_lowering(expression.operand, env:, expected_type:)
          [operand_setup, AST::UnaryOp.new(operator: expression.operator, operand:)]
        when AST::BinaryOp
          prepare_binary_expression_for_inline_lowering(expression, env:, expected_type:)
        when AST::IfExpr
          prepare_if_expression_for_inline_lowering(expression, env:, expected_type:)
        when AST::Call
          prepare_call_expression_for_inline_lowering(expression, env:, expected_type:, allow_root_statement_foreign:)
        when AST::ProcExpr
          proc_type = infer_expression_type(expression, env:, expected_type:)
          setup, value = lower_proc_expression_for_local(expression, env:, local_name: fresh_c_temp_name(env, "proc_expr"), proc_type: proc_type)
          materialize_prepared_expression(setup, value, env:, type: proc_type, prefix: "proc_expr")
        else
          [[], expression]
        end
      end

      def prepare_call_expression_for_inline_lowering(expression, env:, expected_type: nil, allow_root_statement_foreign: false)
        kind, _callee_name, _receiver, callee_type, binding = resolve_callee(expression.callee, env, arguments: expression.arguments)

        case format_string_call_kind(binding, expression.arguments)
        when :fmt_string
          return lower_format_string_call_to_temp(expression.arguments.first.value, env:)
        when :io_print
          return lower_io_format_string_call_to_temp(expression.arguments.first.value, env:, helper_name: "print_formatted")
        when :io_println
          return lower_io_format_string_call_to_temp(expression.arguments.first.value, env:, helper_name: "println_formatted")
        when :io_write_error
          return lower_io_format_string_call_to_temp(expression.arguments.first.value, env:, helper_name: "write_error_formatted")
        when :io_write_error_line
          return lower_io_format_string_call_to_temp(expression.arguments.first.value, env:, helper_name: "write_error_line_formatted")
        end

        if binding && kind != :variant_arm_ctor && foreign_function_binding?(binding) && !allow_root_statement_foreign && foreign_call_requires_statement_lowering?(expression, binding, env:)
          type = infer_expression_type(expression, env:, expected_type:)
          setup, value = lower_foreign_call_statement({ call: expression, binding: binding }, env:, expected_type: type, statement_position: false)
          return materialize_prepared_expression(setup, value, env:, type:, prefix: "foreign_expr")
        end

        callee_setup, callee = prepare_expression_for_inline_lowering(expression.callee, env:)
        argument_setup = []
        arguments = expression.arguments.map.with_index do |argument, index|
          expected_arg_type = kind == :function || kind == :method || kind == :associated_method || kind == :callable_value ?
            (index < callee_type.params.length ? callee_type.params[index].type : nil) : nil
          setup, prepared_value = prepare_expression_for_inline_lowering(argument.value, env:, expected_type: expected_arg_type)
          argument_setup.concat(setup)
          AST::Argument.new(name: argument.name, value: prepared_value)
        end

        [callee_setup + argument_setup, AST::Call.new(callee:, arguments:)]
      end

      def lower_format_string_call_to_temp(format_string, env:)
        setup, temp_name, = build_format_string_temp_setup(format_string, env:)
        [setup, AST::Identifier.new(name: temp_name)]
      end

      def prepare_format_string_expression_for_inline_lowering(format_string, env:)
        setup, temp_name, = build_format_string_temp_setup(format_string, env:)
        receiver = AST::Identifier.new(name: temp_name)

        (env[:prepared_expression_cleanups] ||= []) << lower_defer_cleanup_expression(
          AST::Call.new(callee: AST::MemberAccess.new(receiver:, member: "release"), arguments: []),
          env:,
        )

        [
          setup,
          AST::Call.new(callee: AST::MemberAccess.new(receiver:, member: "as_str"), arguments: []),
        ]
      end

      def build_format_string_temp_setup(format_string, env:)
        return build_static_format_string_temp_setup(format_string, env:) unless format_string_has_dynamic_parts?(format_string)

        build_extracted_format_string_temp_setup(format_string, env:)
      end

      def build_static_format_string_temp_setup(format_string, env:)
        string_type = std_string_type
        ref_string_type = Types::GenericInstance.new("ref", [string_type])
        temp_name = fresh_c_temp_name(env, "fmt_string")
        temp_value = IR::Name.new(name: temp_name, type: string_type, pointer: false)
        temp_ref = IR::AddressOf.new(expression: temp_value, type: ref_string_type)
        register_prepared_temp!(env, temp_name, string_type)

        text = format_string.parts.filter_map do |part|
          next unless part.is_a?(AST::FormatTextPart)

          part.value
        end.join

        setup = [
          IR::LocalDecl.new(
            name: temp_name,
            c_name: temp_name,
            type: string_type,
            value: IR::Call.new(
              callee: std_string_from_str_c_name,
              arguments: [IR::StringLiteral.new(value: text, type: @types.fetch("str"), cstring: false)],
              type: string_type,
            ),
          ),
        ]

        [setup, temp_name, temp_ref]
      end

      def build_extracted_format_string_temp_setup(format_string, env:)
        string_type = std_string_type
        ref_string_type = Types::GenericInstance.new("ref", [string_type])
        temp_name = fresh_c_temp_name(env, "fmt_string")
        temp_value = IR::Name.new(name: temp_name, type: string_type, pointer: false)
        temp_ref = IR::AddressOf.new(expression: temp_value, type: ref_string_type)
        register_prepared_temp!(env, temp_name, string_type)

        setup, builder_c_name, builder_arguments = build_format_string_builder_call(format_string, env:)
        setup << IR::LocalDecl.new(
          name: temp_name,
          c_name: temp_name,
          type: string_type,
          value: IR::Call.new(callee: builder_c_name, arguments: builder_arguments, type: string_type),
        )

        [setup, temp_name, temp_ref]
      end

      def build_format_string_builder_call(format_string, env:)
        helper_parts = []
        helper_params = []
        helper_arguments = []
        setup = []

        format_string.parts.each do |part|
          if part.is_a?(AST::FormatTextPart)
            next if part.value.empty?

            helper_parts << { kind: :text, value: part.value }
            next
          end

          expression_setup, prepared_expression = prepare_expression_for_inline_lowering(part.expression, env:)
          setup.concat(expression_setup)
          value_type = infer_expression_type(prepared_expression, env:)
          parameter_name = "part_#{helper_params.length + 1}"
          parameter_c_name = "__mt_fmt_#{parameter_name}"

          if part.format_spec && part.format_spec[:kind] == :precision
            precision = part.format_spec[:value]
            append_argument_type = @types.fetch("f64")
            helper_params << IR::Param.new(name: parameter_name, c_name: parameter_c_name, type: append_argument_type, pointer: false)
            helper_arguments << cast_expression(
              lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
              append_argument_type,
            )
            helper_parts << {
              kind: :precision_expression,
              append_function_name: "append_f64_precision",
              parameter_c_name: parameter_c_name,
              parameter_type: append_argument_type,
              precision: precision,
            }
          else
            append_function_name, append_argument_type = format_string_append_plan(value_type)
            helper_params << IR::Param.new(name: parameter_name, c_name: parameter_c_name, type: append_argument_type, pointer: false)
            helper_arguments << cast_expression(
              lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
              append_argument_type,
            )
            helper_parts << {
              kind: :expression,
              append_function_name: append_function_name,
              parameter_c_name: parameter_c_name,
              parameter_type: append_argument_type,
            }
          end
        end

        signature = format_string_builder_signature(helper_parts)
        helper_c_name = @format_builder_cache[signature]
        unless helper_c_name
          helper_c_name = "#{@module_prefix}__fmt_#{fresh_format_symbol}"
          @synthetic_functions << build_format_string_builder_function(helper_c_name, helper_params, helper_parts)
          @format_builder_cache[signature] = helper_c_name
        end

        [setup, helper_c_name, helper_arguments]
      end

      def format_string_builder_signature(helper_parts)
        [
          @module_prefix,
          helper_parts.map do |part|
            case part[:kind]
            when :text
              [:text, part[:value]]
            when :precision_expression
              [:precision_expression, part[:precision], part[:parameter_type].to_s]
            else
              [:expression, part[:append_function_name], part[:parameter_type].to_s]
            end
          end,
        ]
      end

      def build_format_string_builder_function(helper_c_name, helper_params, helper_parts)
        string_type = std_string_type
        ref_string_type = Types::GenericInstance.new("ref", [string_type])
        result_name = "__mt_result"
        result_value = IR::Name.new(name: result_name, type: string_type, pointer: false)
        result_ref = IR::AddressOf.new(expression: result_value, type: ref_string_type)
        literal_capacity = helper_parts.sum { |part| part[:kind] == :text ? part[:value].bytesize : 0 }
        initializer = if literal_capacity.zero?
                        IR::Call.new(callee: std_string_create_c_name, arguments: [], type: string_type)
                      else
                        IR::Call.new(
                          callee: std_string_with_capacity_c_name,
                          arguments: [IR::IntegerLiteral.new(value: literal_capacity, type: @types.fetch("usize"))],
                          type: string_type,
                        )
                      end

        body = [
          IR::LocalDecl.new(name: result_name, c_name: result_name, type: string_type, value: initializer),
        ]

        helper_parts.each do |part|
          if part[:kind] == :text
            body << IR::ExpressionStmt.new(
              expression: IR::Call.new(
                callee: std_fmt_function_c_name("append"),
                arguments: [result_ref, IR::StringLiteral.new(value: part[:value], type: @types.fetch("str"), cstring: false)],
                type: @types.fetch("void"),
              ),
            )
            next
          end

          if part[:kind] == :precision_expression
            body << IR::ExpressionStmt.new(
              expression: IR::Call.new(
                callee: std_fmt_function_c_name(part[:append_function_name]),
                arguments: [
                  result_ref,
                  IR::Name.new(name: part[:parameter_c_name], type: part[:parameter_type], pointer: false),
                  IR::IntegerLiteral.new(value: part[:precision], type: @types.fetch("i32")),
                ],
                type: @types.fetch("void"),
              ),
            )
            next
          end

          body << IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: std_fmt_function_c_name(part[:append_function_name]),
              arguments: [
                result_ref,
                IR::Name.new(name: part[:parameter_c_name], type: part[:parameter_type], pointer: false),
              ],
              type: @types.fetch("void"),
            ),
          )
        end

        body << IR::ReturnStmt.new(value: result_value)

        IR::Function.new(
          name: helper_c_name,
          c_name: helper_c_name,
          params: helper_params,
          return_type: string_type,
          body: body,
          entry_point: false,
        )
      end

      def format_string_has_dynamic_parts?(format_string)
        format_string.parts.any? { |part| part.is_a?(AST::FormatExprPart) }
      end

      def lower_io_format_string_call_to_temp(format_string, env:, helper_name:)
        setup, _temp_name, temp_ref = build_format_string_temp_setup(format_string, env:)
        result_name = fresh_c_temp_name(env, helper_name)
        register_prepared_temp!(env, result_name, @types.fetch("bool"))
        setup << IR::LocalDecl.new(
          name: result_name,
          c_name: result_name,
          type: @types.fetch("bool"),
          value: IR::Call.new(
            callee: std_io_function_c_name(helper_name),
            arguments: [temp_ref],
            type: @types.fetch("bool"),
          ),
        )

        [setup, AST::Identifier.new(name: result_name)]
      end

      def format_string_call?(binding, arguments)
        !format_string_call_kind(binding, arguments).nil?
      end

      def format_string_call_kind(binding, arguments)
        return nil unless binding
        return nil unless arguments.length == 1
        return nil unless arguments.first.value.is_a?(AST::FormatString)

        return :fmt_string if binding.owner.module_name == "std.fmt" && binding.name == "string"
        return :io_print if binding.owner.module_name == "std.io" && binding.name == "print"
        return :io_println if binding.owner.module_name == "std.io" && binding.name == "println"
        return :io_write_error if binding.owner.module_name == "std.io" && binding.name == "write_error"
        return :io_write_error_line if binding.owner.module_name == "std.io" && binding.name == "write_error_line"

        nil
      end

      def format_string_append_plan(type)
        return ["append", @types.fetch("str")] if type == @types.fetch("str")
        return ["append_cstr", @types.fetch("cstr")] if type == @types.fetch("cstr")
        return ["append_bool", @types.fetch("bool")] if type == @types.fetch("bool")
        return ["append_f32", @types.fetch("f32")] if type == @types.fetch("f32")
        return ["append_f64", @types.fetch("f64")] if type == @types.fetch("f64")

        if type.is_a?(Types::Primitive) && type.integer?
          return ["append_i32", @types.fetch("i32")] if %w[i8 i16 i32].include?(type.name)
          return ["append_u32", @types.fetch("u32")] if %w[u8 u16 u32].include?(type.name)
          return ["append_usize", @types.fetch("usize")] if type.name == "usize"
          return ["append_i64", @types.fetch("i64")] if %w[i64 isize].include?(type.name)
          return ["append_u64", @types.fetch("u64")] if type.name == "u64"
        end

        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_append_plan(type.backing_type)
        end

        raise LoweringError, "formatted string interpolation supports str, cstr, bool, numeric primitives, and integer-backed enums/flags, got #{type}"
      end

      def std_fmt_function_c_name(name)
        binding = analysis_for_module("std.fmt").functions.fetch(name)
        function_binding_c_name(binding, module_name: binding.owner.module_name)
      end

      def std_io_function_c_name(name)
        binding = analysis_for_module("std.io").functions.fetch(name)
        function_binding_c_name(binding, module_name: binding.owner.module_name)
      end

      def canonical_std_io_direct_call_c_name(binding)
        return nil unless binding
        return nil unless binding.owner.module_name == "std.io"

        case binding.name
        when "print"
          std_io_function_c_name("write")
        when "println"
          std_io_function_c_name("write_line")
        else
          nil
        end
      end

      def std_string_type
        analysis_for_module("std.string").types.fetch("String")
      end

      def std_string_create_c_name
        analysis = analysis_for_module("std.string")
        string_type = analysis.types.fetch("String")
        binding = analysis.methods.fetch(string_type).fetch("create")
        function_binding_c_name(binding, module_name: binding.owner.module_name, receiver_type: string_type)
      end

      def std_string_with_capacity_c_name
        analysis = analysis_for_module("std.string")
        string_type = analysis.types.fetch("String")
        binding = analysis.methods.fetch(string_type).fetch("with_capacity")
        function_binding_c_name(binding, module_name: binding.owner.module_name, receiver_type: string_type)
      end

      def std_string_from_str_c_name
        analysis = analysis_for_module("std.string")
        string_type = analysis.types.fetch("String")
        binding = analysis.methods.fetch(string_type).fetch("from_str")
        function_binding_c_name(binding, module_name: binding.owner.module_name, receiver_type: string_type)
      end

      def prepare_binary_expression_for_inline_lowering(expression, env:, expected_type: nil)
        propagated_type = propagating_expected_type(expression.operator, expected_type)
        left_type, right_type = infer_binary_operand_types(expression, env:, expected_type:)
        operand_type = promoted_binary_operand_type(expression.operator, left_type, right_type)
        left_setup, left = prepare_expression_for_inline_lowering(expression.left, env:, expected_type: operand_type || propagated_type || left_type)
        right_env = binary_right_env(expression, env)
        right_setup, right = prepare_expression_for_inline_lowering(expression.right, env: right_env, expected_type: operand_type || left_type)

        unless %w[and or].include?(expression.operator)
          return [
            left_setup + right_setup,
            AST::BinaryOp.new(operator: expression.operator, left:, right:),
          ]
        end

        return [[], expression] if left_setup.empty? && right_setup.empty?

        result_type = infer_expression_type(expression, env:, expected_type:)
        result_name = fresh_c_temp_name(env, expression.operator)
        register_prepared_temp!(env, result_name, result_type)
        result_ref = IR::Name.new(name: result_name, type: result_type, pointer: false)
        left_value = lower_contextual_expression(left, env:, expected_type: result_type)
        right_value = lower_contextual_expression(right, env: right_env, expected_type: result_type)
        branch_condition = expression.operator == "and" ? result_ref : IR::Unary.new(operator: "not", operand: result_ref, type: @types.fetch("bool"))

        [
          left_setup + [
            IR::LocalDecl.new(name: result_name, c_name: result_name, type: result_type, value: left_value),
            IR::IfStmt.new(
              condition: branch_condition,
              then_body: right_setup + [IR::Assignment.new(target: result_ref, operator: "=", value: right_value)],
              else_body: nil,
            ),
          ],
          AST::Identifier.new(name: result_name),
        ]
      end

      def prepare_if_expression_for_inline_lowering(expression, env:, expected_type: nil)
        condition_setup, condition = prepare_expression_for_inline_lowering(expression.condition, env:, expected_type: @types.fetch("bool"))
        then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
        else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
        result_type = infer_expression_type(expression, env:, expected_type:)
        then_setup, then_expression = prepare_expression_for_inline_lowering(expression.then_expression, env: then_env, expected_type: result_type)
        else_setup, else_expression = prepare_expression_for_inline_lowering(expression.else_expression, env: else_env, expected_type: result_type)

        return [[], expression] if condition_setup.empty? && then_setup.empty? && else_setup.empty?

        result_name = fresh_c_temp_name(env, "if_expr")
        register_prepared_temp!(env, result_name, result_type)
        result_ref = IR::Name.new(name: result_name, type: result_type, pointer: false)

        [
          condition_setup + [
            IR::LocalDecl.new(name: result_name, c_name: result_name, type: result_type, value: IR::ZeroInit.new(type: result_type)),
            IR::IfStmt.new(
              condition: lower_expression(condition, env:, expected_type: @types.fetch("bool")),
              then_body: then_setup + [
                IR::Assignment.new(
                  target: result_ref,
                  operator: "=",
                  value: lower_contextual_expression(then_expression, env: then_env, expected_type: result_type),
                ),
              ],
              else_body: else_setup + [
                IR::Assignment.new(
                  target: result_ref,
                  operator: "=",
                  value: lower_contextual_expression(else_expression, env: else_env, expected_type: result_type),
                ),
              ],
            ),
          ],
          AST::Identifier.new(name: result_name),
        ]
      end

      def materialize_prepared_expression(setup, value, env:, type:, prefix:)
        raise LoweringError, "cannot use void expression inline" unless value

        if value.is_a?(IR::Name)
          register_prepared_temp!(env, value.name, value.type, pointer: value.pointer)
          return [setup, AST::Identifier.new(name: value.name)]
        end

        temp_name = fresh_c_temp_name(env, prefix)
        register_prepared_temp!(env, temp_name, type)
        [
          setup + [IR::LocalDecl.new(name: temp_name, c_name: temp_name, type:, value:)],
          AST::Identifier.new(name: temp_name),
        ]
      end

      def register_prepared_temp!(env, name, type, pointer: false, storage_type: nil)
        current_actual_scope(env[:scopes])[name] = local_binding(type:, storage_type:, c_name: name, mutable: false, pointer:)
      end

      def foreign_call_requires_statement_lowering?(expression, binding, env:)
        return true if foreign_call_consumes_binding?(binding)

        mapping_expression = foreign_mapping_expression(binding.ast)
        reference_counts = foreign_mapping_reference_counts(mapping_expression)

        binding.ast.params.each_with_index do |param_ast, index|
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil
          total_references = reference_counts.fetch(param_ast.name, 0)
          total_references += reference_counts.fetch(public_alias, 0) if public_alias
          next unless total_references > 1
          next if duplicable_foreign_argument_expression?(expression.arguments.fetch(index).value)

          return true
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          next unless automatic_foreign_cstr_temp_needed?(parameter, expression.arguments.fetch(index).value, env:) ||
                      automatic_foreign_cstr_list_temp_needed?(parameter, expression.arguments.fetch(index).value, env:)

          return true
        end

        false
      end

      def lower_expression(expression, env:, expected_type: nil)
        type = infer_expression_type(expression, env:, expected_type:)

        case expression
        when AST::AwaitExpr
          raise LoweringError, "await expressions must be lowered in async statement context"
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
        when AST::FormatString
          raise LoweringError, "unprepared format string reached raw lowering; format strings should be materialized before direct lowering"
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
            raise LoweringError, "foreign function #{expression.name} cannot be used as a value" if foreign_function_binding?(function_binding)

            IR::Name.new(name: function_binding_c_name(function_binding, module_name: @module_name), type: type, pointer: false)
          else
            raise LoweringError, "unsupported identifier #{expression.name}"
          end
        when AST::MemberAccess
          lower_member_access(expression, env:, type:)
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          receiver = lower_expression(expression.receiver, env:)
          index = lower_expression(expression.index, env:)
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
        when AST::ProcExpr
          raise LoweringError, "proc expressions must be lowered in local initializer context"
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
          if type_expr.is_a?(Types::Variant)
            return IR::VariantLiteral.new(type: type_expr, arm_name: expression.member, fields: [])
          end

          member_name = if (type_expr.is_a?(Types::Enum) || type_expr.is_a?(Types::Flags)) && !type_expr.external
                          enum_member_c_name(type_expr, expression.member)
                        else
                          expression.member
                        end
          return IR::Name.new(name: member_name, type:, pointer: false)
        end

        if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
          imported_module = @imports.fetch(expression.receiver.name)
          if imported_module.functions.key?(expression.member)
            function_binding = imported_module.functions.fetch(expression.member)
            raise LoweringError, "generic function #{expression.receiver.name}.#{expression.member} cannot be used as a value" if function_binding.type_params.any?
            raise LoweringError, "foreign function #{expression.receiver.name}.#{expression.member} cannot be used as a value" if foreign_function_binding?(function_binding)

            return IR::Name.new(name: function_binding_c_name(function_binding, module_name: imported_module.name), type:, pointer: false)
          end

          return IR::Name.new(name: imported_value_c_name(imported_module, expression.member), type:, pointer: false)
        end

        receiver_type = infer_expression_type(expression.receiver, env:)
        receiver = lower_expression(expression.receiver, env:)
        IR::Member.new(receiver:, member: member_c_name(receiver_type, expression.member), type:)
      end

      def member_c_name(receiver_type, member)
        owner_type = receiver_type
        loop do
          case owner_type
          when Types::Nullable
            owner_type = owner_type.base
          when Types::GenericInstance
            if %w[ptr const_ptr ref].include?(owner_type.name) && owner_type.arguments.length == 1
              owner_type = owner_type.arguments.first
            else
              break
            end
          else
            break
          end
        end

        owner_type.field_c_name(member)
      end

      def lower_call(expression, env:, type:)
        kind, callee_name, receiver, callee_type, callee_binding = resolve_callee(expression.callee, env, arguments: expression.arguments)

        case kind
        when :function
          if callee_binding && foreign_function_binding?(callee_binding)
            raise LoweringError, "consuming foreign calls must be top-level expression statements" if foreign_call_consumes_binding?(callee_binding)

            return lower_foreign_call_inline(expression, callee_binding, env:, type:)
          end

          canonical_callee_name = canonical_std_io_direct_call_c_name(callee_binding) || callee_name
          arguments = lower_call_arguments(expression.arguments, callee_type, env:)
          IR::Call.new(callee: canonical_callee_name, arguments:, type:)
        when :callable_value
          callee_expression = lower_expression(expression.callee, env:, expected_type: callee_type)
          if proc_type?(callee_type)
            arguments = [
              IR::Member.new(receiver: callee_expression, member: "env", type: proc_env_pointer_type),
              *lower_call_arguments(expression.arguments, callee_type, env:),
            ]
            IR::Call.new(
              callee: IR::Member.new(receiver: callee_expression, member: "invoke", type: proc_invoke_function_type(callee_type)),
              arguments:,
              type:,
            )
          else
            arguments = lower_call_arguments(expression.arguments, callee_type, env:)
            IR::Call.new(callee: callee_expression, arguments:, type:)
          end
        when :method
          receiver_arg = lower_method_receiver_argument(receiver, callee_type, env:)
          arguments = [receiver_arg, *lower_call_arguments(expression.arguments, callee_type, env:)]
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :str_builder_clear
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_builder_clear",
            arguments: [
              lower_str_builder_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_builder_capacity(receiver_type), type: @types.fetch("usize")),
              lower_str_builder_len_pointer(receiver, env:),
              lower_str_builder_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_builder_assign
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_builder_assign",
            arguments: [
              lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: @types.fetch("str")),
              lower_str_builder_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_builder_capacity(receiver_type), type: @types.fetch("usize")),
              lower_str_builder_len_pointer(receiver, env:),
              lower_str_builder_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_builder_append
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_builder_append",
            arguments: [
              lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: @types.fetch("str")),
              lower_str_builder_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_builder_capacity(receiver_type), type: @types.fetch("usize")),
              lower_str_builder_len_pointer(receiver, env:),
              lower_str_builder_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_builder_len
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_builder_len",
            arguments: [
              lower_str_builder_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_builder_capacity(receiver_type), type: @types.fetch("usize")),
              lower_str_builder_len_pointer(receiver, env:),
              lower_str_builder_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_builder_capacity
          receiver_type = infer_expression_type(receiver, env:)
          IR::IntegerLiteral.new(value: str_builder_capacity(receiver_type), type: type)
        when :str_builder_as_str
          receiver_type = infer_expression_type(receiver, env:)
          data_pointer = lower_str_builder_data_pointer(receiver, env:)
          IR::AggregateLiteral.new(
            type:,
            fields: [
              IR::AggregateField.new(name: "data", value: data_pointer),
              IR::AggregateField.new(
                name: "len",
                value: IR::Call.new(
                  callee: "mt_str_builder_len",
                  arguments: [
                    data_pointer,
                    IR::IntegerLiteral.new(value: str_builder_capacity(receiver_type), type: @types.fetch("usize")),
                    lower_str_builder_len_pointer(receiver, env:),
                    lower_str_builder_dirty_pointer(receiver, env:),
                  ],
                  type: @types.fetch("usize"),
                ),
              ),
            ],
          )
        when :str_builder_as_cstr
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_builder_as_cstr",
            arguments: [
              lower_str_builder_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_builder_capacity(receiver_type), type: @types.fetch("usize")),
              lower_str_builder_len_pointer(receiver, env:),
              lower_str_builder_dirty_pointer(receiver, env:),
            ],
            type:,
          )
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
        when :variant_arm_ctor
          _, _, _, variant_type, (_, arm_name) = resolve_callee(expression.callee, env, arguments: expression.arguments)
          arm_fields = variant_type.arm(arm_name)
          payload_fields = expression.arguments.map do |argument|
            field_type = arm_fields.fetch(argument.name)
            IR::AggregateField.new(name: argument.name, value: lower_contextual_expression(argument.value, env:, expected_type: field_type))
          end
          IR::VariantLiteral.new(type: variant_type, arm_name:, fields: payload_fields)
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
        when :ref_of
          argument = expression.arguments.fetch(0)
          lower_addr_expression(argument.value, env:, target_type: type)
        when :const_ptr_of
          argument = expression.arguments.fetch(0)
          lower_addr_expression(argument.value, env:, target_type: type)
        when :read
          argument = expression.arguments.fetch(0)
          IR::Unary.new(operator: "*", operand: lower_expression(argument.value, env:), type:)
        when :ptr_of
          argument = expression.arguments.fetch(0)
          IR::Cast.new(target_type: type, expression: lower_expression(argument.value, env:), type:)
        else
          raise LoweringError, "unsupported call kind #{kind}"
        end
      end

      def lower_method_receiver_argument(receiver, callee_type, env:)
        lowered_receiver = lower_expression(receiver, env:)

        if callee_type.receiver_mutable
          return lowered_receiver if ref_type?(lowered_receiver.type)
          return lowered_receiver if pointer_type?(lowered_receiver.type)

          if lowered_receiver.is_a?(IR::Name) && lowered_receiver.pointer
            return lowered_receiver
          end

          if lowered_receiver.is_a?(IR::Unary) && lowered_receiver.operator == "*"
            return lowered_receiver.operand
          end

          return IR::AddressOf.new(expression: lowered_receiver, type: lowered_receiver.type)
        end

        if ref_type?(lowered_receiver.type)
          return IR::Unary.new(operator: "*", operand: lowered_receiver, type: referenced_type(lowered_receiver.type))
        end

        if pointer_type?(lowered_receiver.type)
          return IR::Unary.new(operator: "*", operand: lowered_receiver, type: pointee_type(lowered_receiver.type))
        end

        lowered_receiver
      end

      def lower_addr_expression(expression, env:, target_type:)
        lowered_expression = lower_expression(expression, env:)
        return cast_expression(lowered_expression, target_type) if lowered_expression.is_a?(IR::Name) && lowered_expression.pointer

        if lowered_expression.is_a?(IR::Unary) && lowered_expression.operator == "*"
          return cast_expression(lowered_expression.operand, target_type)
        end

        IR::AddressOf.new(expression: lowered_expression, type: target_type)
      end

      def lower_call_arguments(arguments, callee_type, env:)
        arguments.map.with_index do |argument, index|
          expected_type = index < callee_type.params.length ? callee_type.params[index].type : nil
          lower_contextual_expression(
            argument.value,
            env:,
            expected_type:,
            external_numeric: callee_type.respond_to?(:external) && callee_type.external && !expected_type.nil?,
          )
        end
      end

      def foreign_call_info(expression, env)
        call = expression if expression.is_a?(AST::Call)
        return unless call

        kind, _, _, _, binding = resolve_callee(call.callee, env, arguments: call.arguments)
        return unless kind == :function && binding && foreign_function_binding?(binding)

        {
          call:,
          binding:,
        }
      end

      def foreign_call_consumes_binding?(binding)
        binding.type.params.any? { |parameter| parameter.passing_mode == :consuming }
      end

      def lower_foreign_call_components(foreign_call, env:, expected_type:, statement_position:)
        call = foreign_call.fetch(:call)
        binding = foreign_call.fetch(:binding)
        raise LoweringError, "consuming foreign calls must be top-level expression statements" if foreign_call_consumes_binding?(binding) && !statement_position

        owner_analysis = analysis_for_module(binding.owner.module_name)
        mapping_expression = foreign_mapping_expression(binding.ast)
        reference_counts = foreign_mapping_reference_counts(mapping_expression)
        mapping_env = duplicate_env(env)
        lowered = []
        release_assignments = consuming_foreign_release_assignments(foreign_call, env:)
        cleanup_statements = []

        replacements = bind_foreign_mapping_arguments(binding, call.arguments, mapping_env, lowered, env:, reference_counts:, cleanup: cleanup_statements)

        call_type = binding.type.return_type
        lowered_call = lower_inline_foreign_mapping_expression(
          mapping_expression,
          mapping_env:,
          replacements:,
          owner_analysis:,
          expected_type: expected_type || call_type,
        )

        [lowered, lowered_call, call_type, release_assignments, cleanup_statements]
      end

      def lower_foreign_call_statement(foreign_call, env:, expected_type:, statement_position:, discard_result: false)
        lowered, lowered_call, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
          foreign_call,
          env:,
          expected_type:,
          statement_position:,
        )

        if call_type == @types.fetch("void")
          lowered << IR::ExpressionStmt.new(expression: lowered_call)
          lowered.concat(release_assignments)
          lowered.concat(cleanup_statements)
          return [lowered, nil]
        end

        raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

        if discard_result
          lowered << IR::ExpressionStmt.new(expression: lowered_call)
          lowered.concat(cleanup_statements)
          return [lowered, nil]
        end

        unless cleanup_statements.empty?
          result_name = fresh_c_temp_name(env, "foreign_result")
          lowered << IR::LocalDecl.new(name: result_name, c_name: result_name, type: call_type, value: lowered_call)
          lowered.concat(cleanup_statements)
          return [lowered, IR::Name.new(name: result_name, type: call_type, pointer: false)]
        end

        [lowered, lowered_call]
      end

      def consuming_foreign_release_assignments(foreign_call, env:)
        consuming_foreign_release_bindings(foreign_call, env:).map do |binding|
          IR::Assignment.new(
            target: IR::Name.new(name: binding[:c_name], type: binding[:storage_type], pointer: binding[:pointer]),
            operator: "=",
            value: IR::NullLiteral.new(type: binding[:storage_type]),
          )
        end
      end

      def consuming_foreign_call_refinements(foreign_call, env)
        consuming_foreign_release_bindings(foreign_call, env:).each_with_object({}) do |binding, refinements|
          refinements[binding[:name]] = null_type
        end
      end

      def consuming_foreign_release_bindings(foreign_call, env:)
        binding = foreign_call.fetch(:binding)
        call = foreign_call.fetch(:call)

        binding.type.params.each_with_index.filter_map do |parameter, index|
          next unless parameter.passing_mode == :consuming

          argument = call.arguments.fetch(index)
          unless argument.value.is_a?(AST::Identifier)
            raise LoweringError, "consuming foreign calls require bare nullable local or parameter bindings"
          end

          lowered_binding = lookup_value(argument.value.name, env)
          unless lowered_binding && lowered_binding[:storage_type].is_a?(Types::Nullable) && lowered_binding[:storage_type].base == parameter.type
            raise LoweringError, "consuming foreign calls require bare nullable local or parameter bindings"
          end

          lowered_binding.merge(name: argument.value.name)
        end
      end

      def bind_foreign_mapping_arguments(binding, arguments, mapping_env, lowered, env:, reference_counts:, cleanup:)
        replacements = {}
        entries = binding.ast.params.each_with_index.map do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil
          {
            argument: arguments.fetch(index),
            param_ast:,
            parameter:,
            temp_type: parameter.boundary_type || parameter.type,
            public_alias:,
            public_reference_count: public_alias ? reference_counts.fetch(public_alias, 0) : 0,
            reference_count: reference_counts.fetch(param_ast.name, 0),
            lowered_value: nil,
          }
        end

        entries.each do |entry|
          next unless entry[:public_reference_count].positive?

          public_value = lower_contextual_expression(entry[:argument].value, env:, expected_type: entry[:parameter].type)
          if public_value.is_a?(IR::Name)
            current_actual_scope(mapping_env[:scopes])[entry[:public_alias]] = local_binding(
              type: entry[:parameter].type,
              c_name: public_value.name,
              mutable: false,
              pointer: public_value.pointer,
            )
            replacements[entry[:public_alias]] = public_value
            next
          end

          public_temp_name = fresh_c_temp_name(env, "foreign_arg_public")
          lowered << IR::LocalDecl.new(
            name: public_temp_name,
            c_name: public_temp_name,
            type: entry[:parameter].type,
            value: public_value,
          )
          current_actual_scope(mapping_env[:scopes])[entry[:public_alias]] = local_binding(
            type: entry[:parameter].type,
            c_name: public_temp_name,
            mutable: false,
            pointer: false,
          )
          replacements[entry[:public_alias]] = IR::Name.new(name: public_temp_name, type: entry[:parameter].type, pointer: false)
        end

        entries.each do |entry|
          next unless entry[:reference_count].positive?

          source_argument = if entry[:public_reference_count].positive?
                              AST::Argument.new(name: nil, value: AST::Identifier.new(name: entry[:public_alias]))
                            else
                              entry[:argument]
                            end
          source_env = entry[:public_reference_count].positive? ? mapping_env : env
          source_argument = prepare_foreign_in_argument(entry[:parameter], source_argument, source_env:, lowered:, env:)
          entry[:lowered_value] = if automatic_foreign_cstr_list_temp_needed?(entry[:parameter], source_argument.value, env: source_env)
                                    lower_foreign_cstr_list_argument_value(entry[:parameter], source_argument.value, env: source_env, lowered:, cleanup:)
                                  else
                                    lower_foreign_argument_value(entry[:parameter], source_argument, env: source_env)
                                  end
        end

        inline_direct_call_names = inlineable_single_direct_call_names(entries)

        entries.each do |entry|
          next unless entry[:reference_count].positive?

          param_ast = entry[:param_ast]
          temp_type = entry[:temp_type]
          lowered_value = entry[:lowered_value]

          if !inline_direct_call_names.include?(param_ast.name) && foreign_argument_needs_temporary_binding?(lowered_value, reference_count: entry[:reference_count])
            temp_name = fresh_c_temp_name(env, "foreign_arg")
            lowered << IR::LocalDecl.new(
              name: temp_name,
              c_name: temp_name,
              type: temp_type,
              value: lowered_value,
            )
            current_actual_scope(mapping_env[:scopes])[param_ast.name] = local_binding(type: temp_type, c_name: temp_name, mutable: false, pointer: false)
            replacements[param_ast.name] = IR::Name.new(name: temp_name, type: temp_type, pointer: false)
            if temporary_foreign_cstr_expression?(lowered_value)
              cleanup << IR::ExpressionStmt.new(
                expression: IR::Call.new(
                  callee: "mt_free_foreign_cstr_temp",
                  arguments: [IR::Name.new(name: temp_name, type: temp_type, pointer: false)],
                  type: @types.fetch("void"),
                ),
              )
            end
          else
            current_actual_scope(mapping_env[:scopes])[param_ast.name] = local_binding(type: temp_type, c_name: param_ast.name, mutable: false, pointer: false)
            replacements[param_ast.name] = lowered_value
          end
        end

        replacements
      end

      def inlineable_single_direct_call_names(entries)
        blocked_entries = entries.select do |entry|
          next false unless entry[:reference_count].positive?

          entry[:reference_count] > 1 || !inlineable_foreign_argument_expression?(entry[:lowered_value])
        end
        return [] unless blocked_entries.length == 1

        blocked_entry = blocked_entries.first
        return [] unless blocked_entry[:reference_count] == 1 && blocked_entry[:lowered_value].is_a?(IR::Call)
        return [] if temporary_foreign_cstr_expression?(blocked_entry[:lowered_value])

        [blocked_entry[:param_ast].name]
      end

      def lower_foreign_argument_value(parameter, argument, env:)
        case parameter.passing_mode
        when :plain, :consuming
          if parameter.boundary_type.nil? || parameter.boundary_type == parameter.type
            lower_contextual_expression(argument.value, env:, expected_type: parameter.type)
          elsif parameter.boundary_type == @types.fetch("cstr") && parameter.type == @types.fetch("str")
            if argument.value.is_a?(AST::StringLiteral) && !argument.value.cstring
              return IR::StringLiteral.new(value: argument.value.value, type: parameter.boundary_type, cstring: true)
            end

            actual_type = infer_expression_type(argument.value, env:)
            if actual_type == @types.fetch("cstr")
              return lower_expression(argument.value, env:, expected_type: parameter.boundary_type)
            end

            if cstr_backed_expression?(argument.value, env)
              lowered_value = lower_contextual_expression(argument.value, env:, expected_type: parameter.type)
              data_expression = IR::Member.new(receiver: lowered_value, member: "data", type: pointer_to(@types.fetch("char")))
              converted = foreign_identity_projection_expression(data_expression, parameter.boundary_type)
              return converted if converted
            end

            IR::Call.new(
              callee: "mt_foreign_str_to_cstr_temp",
              arguments: [lower_contextual_expression(argument.value, env:, expected_type: parameter.type)],
              type: parameter.boundary_type,
            )
          elsif foreign_span_boundary_compatible?(parameter.type, parameter.boundary_type)
            lower_foreign_span_argument_value(parameter, argument, env:)
          elsif foreign_char_pointer_buffer_boundary_compatible?(parameter.type, parameter.boundary_type)
            lower_foreign_char_pointer_buffer_argument_value(parameter, argument, env:)
          else
            lowered_value = lower_contextual_expression(argument.value, env:, expected_type: parameter.type)
            converted = foreign_identity_projection_expression(lowered_value, parameter.boundary_type)
            return converted if converted

            raise LoweringError, "unsupported foreign boundary mapping #{parameter.type} as #{parameter.boundary_type}"
          end
        when :in
          lower_foreign_in_argument_value(parameter, argument, env:)
        when :out, :inout
          lower_foreign_pointer_argument_value(parameter, argument, env:)
        else
          raise LoweringError, "unsupported foreign passing mode #{parameter.passing_mode}"
        end
      end

      def lower_foreign_span_argument_value(parameter, argument, env:)
        public_type = parameter.type
        boundary_type = parameter.boundary_type
        lowered_value = lower_contextual_expression(argument.value, env:, expected_type: public_type)
        return lowered_value if public_type == boundary_type

        public_element_type = public_type.element_type
        boundary_element_type = boundary_type.element_type

        data_expression = IR::Member.new(receiver: lowered_value, member: "data", type: pointer_to(public_element_type))
        converted_data = foreign_identity_projection_expression(data_expression, pointer_to(boundary_element_type))
        raise LoweringError, "unsupported foreign boundary mapping #{public_type} as #{boundary_type}" unless converted_data

        len_expression = IR::Member.new(receiver: lowered_value, member: "len", type: @types.fetch("usize"))
        IR::AggregateLiteral.new(
          type: boundary_type,
          fields: [
            IR::AggregateField.new(name: "data", value: converted_data),
            IR::AggregateField.new(name: "len", value: len_expression),
          ],
        )
      end

      def lower_foreign_pointer_argument_value(parameter, argument, env:)
        operand = argument.value.operand
        address = IR::AddressOf.new(
          expression: lower_expression(operand, env:),
          type: pointer_to(parameter.type),
        )

        converted = foreign_identity_projection_expression(address, parameter.boundary_type)
        return converted if converted

        raise LoweringError, "unsupported foreign pointer boundary mapping #{parameter.type} as #{parameter.boundary_type}"
      end

      def prepare_foreign_in_argument(parameter, argument, source_env:, lowered:, env:)
        return argument unless parameter.passing_mode == :in

        operand = argument.value.operand
        return argument if addressable_storage_expression?(operand)

        temp_name = fresh_c_temp_name(env, "foreign_in")
        lowered << IR::LocalDecl.new(
          name: temp_name,
          c_name: temp_name,
          type: parameter.type,
          value: lower_contextual_expression(operand, env: source_env, expected_type: parameter.type),
        )
        current_actual_scope(source_env[:scopes])[temp_name] = local_binding(type: parameter.type, c_name: temp_name, mutable: false, pointer: false)

        AST::Argument.new(
          name: argument.name,
          value: AST::UnaryOp.new(operator: "in", operand: AST::Identifier.new(name: temp_name)),
        )
      end

      def lower_foreign_in_argument_value(parameter, argument, env:)
        address = lower_addr_expression(
          argument.value.operand,
          env:,
          target_type: const_pointer_to(parameter.type),
        )

        converted = foreign_identity_projection_expression(address, parameter.boundary_type)
        return converted if converted

        raise LoweringError, "unsupported foreign in boundary mapping #{parameter.type} as #{parameter.boundary_type}"
      end

      def lower_foreign_char_pointer_buffer_argument_value(parameter, argument, env:)
        public_type = parameter.type

        if char_array_text_type?(public_type)
          return lower_char_array_data_pointer(argument.value, env:)
        end

        if str_builder_type?(public_type)
          return IR::Call.new(
            callee: "mt_str_builder_prepare_write",
            arguments: [
              lower_str_builder_data_pointer(argument.value, env:),
              IR::IntegerLiteral.new(value: str_builder_capacity(public_type), type: @types.fetch("usize")),
              lower_str_builder_dirty_pointer(argument.value, env:),
            ],
            type: parameter.boundary_type,
          )
        end

        lowered_value = lower_contextual_expression(argument.value, env:, expected_type: public_type)
        return IR::Member.new(receiver: lowered_value, member: "data", type: parameter.boundary_type) if public_type.is_a?(Types::Span) && public_type.element_type == @types.fetch("char")

        converted = foreign_identity_projection_expression(lowered_value, parameter.boundary_type)
        return converted if converted

        raise LoweringError, "unsupported foreign boundary mapping #{public_type} as #{parameter.boundary_type}"
      end

      def lower_foreign_call_inline(expression, binding, env:, type:)
        owner_analysis = analysis_for_module(binding.owner.module_name)
        mapping_expression = foreign_mapping_expression(binding.ast)
        reference_counts = foreign_mapping_reference_counts(mapping_expression)
        mapping_env = duplicate_env(env)

        binding.ast.params.each_with_index do |param_ast, index|
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil
          total_references = reference_counts.fetch(param_ast.name, 0)
          total_references += reference_counts.fetch(public_alias, 0) if public_alias
          next unless total_references > 1
          next if duplicable_foreign_argument_expression?(expression.arguments.fetch(index).value)

          raise LoweringError, "foreign call #{binding.name} cannot be used inline because #{param_ast.name} is referenced multiple times in its mapping; use it as a statement, local initializer, assignment, or return expression"
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          next unless automatic_foreign_cstr_temp_needed?(parameter, expression.arguments.fetch(index).value, env:) ||
                      automatic_foreign_cstr_list_temp_needed?(parameter, expression.arguments.fetch(index).value, env:)

          raise LoweringError, "foreign call #{binding.name} cannot be used inline because #{param_ast.name} needs temporary foreign text storage; use it as a statement, local initializer, assignment, or return expression"
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          argument = expression.arguments.fetch(index)
          next unless parameter.passing_mode == :in
          next if addressable_storage_expression?(argument.value.operand)

          raise LoweringError, "foreign call #{binding.name} cannot be used inline because #{param_ast.name} needs temporary in storage; use it as a statement, local initializer, assignment, or return expression"
        end

        replacements = {}
        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          temp_type = parameter.boundary_type || parameter.type
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil

          if reference_counts.fetch(param_ast.name, 0).positive?
            current_actual_scope(mapping_env[:scopes])[param_ast.name] = local_binding(type: temp_type, c_name: param_ast.name, mutable: false, pointer: false)
            replacements[param_ast.name] = lower_foreign_argument_value(parameter, expression.arguments.fetch(index), env:)
          end

          next unless public_alias && reference_counts.fetch(public_alias, 0).positive?

          current_actual_scope(mapping_env[:scopes])[public_alias] = local_binding(type: parameter.type, c_name: public_alias, mutable: false, pointer: false)
          replacements[public_alias] = lower_contextual_expression(expression.arguments.fetch(index).value, env:, expected_type: parameter.type)
        end

        lowered_expression = lower_inline_foreign_mapping_expression(
          mapping_expression,
          mapping_env:,
          replacements:,
          owner_analysis:,
          expected_type: type,
        )

        converted = foreign_identity_projection_expression(lowered_expression, type)
        return converted if converted

        lowered_expression
      end

      def lower_inline_foreign_mapping_expression(expression, mapping_env:, replacements:, owner_analysis:, expected_type: nil)
        unless foreign_mapping_uses_inline_replacement?(expression, replacements)
          return with_analysis_context(owner_analysis) do
            lower_expression(expression, env: mapping_env, expected_type:)
          end
        end

        type = with_analysis_context(owner_analysis) do
          infer_expression_type(expression, env: mapping_env, expected_type:)
        end

        case expression
        when AST::Identifier
          replacements.fetch(expression.name)
        when AST::MemberAccess
          receiver = lower_inline_foreign_mapping_expression(
            expression.receiver,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          IR::Member.new(receiver:, member: expression.member, type:)
        when AST::IndexAccess
          receiver_type = with_analysis_context(owner_analysis) do
            infer_expression_type(expression.receiver, env: mapping_env)
          end
          receiver = lower_inline_foreign_mapping_expression(
            expression.receiver,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          index = lower_inline_foreign_mapping_expression(
            expression.index,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          if array_type?(receiver_type) && addressable_storage_expression?(expression.receiver)
            IR::CheckedIndex.new(receiver:, index:, receiver_type:, type:)
          elsif receiver_type.is_a?(Types::Span)
            IR::CheckedSpanIndex.new(receiver:, index:, receiver_type:, type:)
          else
            IR::Index.new(receiver:, index:, type:)
          end
        when AST::Call
          lower_inline_foreign_mapping_call(expression, mapping_env:, replacements:, owner_analysis:, type:)
        when AST::UnaryOp
          IR::Unary.new(
            operator: expression.operator,
            operand: lower_inline_foreign_mapping_expression(
              expression.operand,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: type,
            ),
            type:,
          )
        when AST::BinaryOp
          left_type, right_type = with_analysis_context(owner_analysis) do
            infer_binary_operand_types(expression, env: mapping_env, expected_type: type)
          end
          operand_type = promoted_binary_operand_type(expression.operator, left_type, right_type)
          left = lower_inline_foreign_mapping_expression(
            expression.left,
            mapping_env:,
            replacements:,
            owner_analysis:,
            expected_type: operand_type || type,
          )
          right = lower_inline_foreign_mapping_expression(
            expression.right,
            mapping_env:,
            replacements:,
            owner_analysis:,
            expected_type: operand_type || left.type,
          )
          left = cast_expression(left, operand_type) if operand_type
          right = cast_expression(right, operand_type) if operand_type
          IR::Binary.new(operator: expression.operator, left:, right:, type:)
        when AST::IfExpr
          IR::Conditional.new(
            condition: lower_inline_foreign_mapping_expression(
              expression.condition,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: @types.fetch("bool"),
            ),
            then_expression: lower_inline_foreign_mapping_expression(
              expression.then_expression,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: type,
            ),
            else_expression: lower_inline_foreign_mapping_expression(
              expression.else_expression,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: type,
            ),
            type:,
          )
        else
          with_analysis_context(owner_analysis) do
            lower_expression(expression, env: mapping_env, expected_type:)
          end
        end
      end

      def lower_inline_foreign_mapping_call(expression, mapping_env:, replacements:, owner_analysis:, type:)
        kind, callee_name, receiver, callee_type, callee_binding = with_analysis_context(owner_analysis) do
          resolve_callee(expression.callee, mapping_env, arguments: expression.arguments)
        end

        case kind
        when :function
          raise LoweringError, "consuming foreign calls must be top-level expression statements" if callee_binding && foreign_function_binding?(callee_binding) && foreign_call_consumes_binding?(callee_binding)

          arguments = expression.arguments.map.with_index do |argument, index|
            expected_arg_type = index < callee_type.params.length ? callee_type.params[index].type : nil
            lower_inline_foreign_mapping_expression(
              argument.value,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: expected_arg_type,
            )
          end
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :cast
          argument = expression.arguments.fetch(0)
          lowered_arg = lower_inline_foreign_mapping_expression(
            argument.value,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          IR::Cast.new(target_type: type, expression: lowered_arg, type:)
        when :reinterpret
          argument = expression.arguments.fetch(0)
          source_type = with_analysis_context(owner_analysis) do
            infer_expression_type(argument.value, env: mapping_env)
          end
          IR::ReinterpretExpr.new(
            target_type: type,
            source_type:,
            expression: lower_inline_foreign_mapping_expression(
              argument.value,
              mapping_env:,
              replacements:,
              owner_analysis:,
              expected_type: source_type,
            ),
            type:,
          )
        when :zero
          IR::ZeroInit.new(type:)
        when :ref_of
          argument = expression.arguments.fetch(0)
          lowered_argument = lower_inline_foreign_mapping_expression(
            argument.value,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          if lowered_argument.is_a?(IR::Name) && lowered_argument.pointer
            cast_expression(lowered_argument, type)
          elsif lowered_argument.is_a?(IR::Unary) && lowered_argument.operator == "*"
            cast_expression(lowered_argument.operand, type)
          else
            IR::AddressOf.new(expression: lowered_argument, type:)
          end
        when :const_ptr_of
          argument = expression.arguments.fetch(0)
          lowered_argument = lower_inline_foreign_mapping_expression(
            argument.value,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          if lowered_argument.is_a?(IR::Name) && lowered_argument.pointer
            cast_expression(lowered_argument, type)
          elsif lowered_argument.is_a?(IR::Unary) && lowered_argument.operator == "*"
            cast_expression(lowered_argument.operand, type)
          else
            IR::AddressOf.new(expression: lowered_argument, type:)
          end
        when :read
          argument = expression.arguments.fetch(0)
          IR::Unary.new(
            operator: "*",
            operand: lower_inline_foreign_mapping_expression(
              argument.value,
              mapping_env:,
              replacements:,
              owner_analysis:,
            ),
            type:,
          )
        when :str_builder_capacity
          receiver_type = with_analysis_context(owner_analysis) do
            infer_expression_type(receiver, env: mapping_env)
          end
          IR::IntegerLiteral.new(value: str_builder_capacity(receiver_type), type:)
        when :ptr_of
          argument = expression.arguments.fetch(0)
          IR::Cast.new(
            target_type: type,
            expression: lower_inline_foreign_mapping_expression(
              argument.value,
              mapping_env:,
              replacements:,
              owner_analysis:,
            ),
            type:,
          )
        else
          raise LoweringError, "unsupported inline foreign mapping call kind #{kind}"
        end
      end

      def foreign_mapping_uses_inline_replacement?(expression, replacements)
        case expression
        when AST::Identifier
          replacements.key?(expression.name)
        when AST::MemberAccess
          foreign_mapping_uses_inline_replacement?(expression.receiver, replacements)
        when AST::IndexAccess
          foreign_mapping_uses_inline_replacement?(expression.receiver, replacements) ||
            foreign_mapping_uses_inline_replacement?(expression.index, replacements)
        when AST::Specialization, AST::Call
          foreign_mapping_uses_inline_replacement?(expression.callee, replacements) ||
            expression.arguments.any? { |argument| foreign_mapping_uses_inline_replacement?(argument.value, replacements) }
        when AST::UnaryOp
          foreign_mapping_uses_inline_replacement?(expression.operand, replacements)
        when AST::BinaryOp
          foreign_mapping_uses_inline_replacement?(expression.left, replacements) ||
            foreign_mapping_uses_inline_replacement?(expression.right, replacements)
        when AST::IfExpr
          foreign_mapping_uses_inline_replacement?(expression.condition, replacements) ||
            foreign_mapping_uses_inline_replacement?(expression.then_expression, replacements) ||
            foreign_mapping_uses_inline_replacement?(expression.else_expression, replacements)
        else
          false
        end
      end

      def raw_pointer_argument_expression(operand)
        AST::Call.new(
          callee: AST::Identifier.new(name: "ptr_of"),
          arguments: [
            AST::Argument.new(
              name: nil,
              value: AST::Call.new(
                callee: AST::Identifier.new(name: "ref_of"),
                arguments: [AST::Argument.new(name: nil, value: operand)],
              ),
            ),
          ],
        )
      end

      def foreign_function_binding?(binding)
        binding.ast.is_a?(AST::ForeignFunctionDecl)
      end

      def foreign_mapping_expression(decl)
        return decl.mapping if decl.mapping.is_a?(AST::Call)

        AST::Call.new(
          callee: decl.mapping,
          arguments: decl.params.map { |param| AST::Argument.new(name: nil, value: AST::Identifier.new(name: param.name)) },
        )
      end

      def foreign_mapping_public_alias_name(name)
        "#{name}_public"
      end

      def substitute_foreign_mapping_expression(expression, replacements)
        case expression
        when AST::Identifier
          replacements.fetch(expression.name, expression)
        when AST::MemberAccess
          AST::MemberAccess.new(receiver: substitute_foreign_mapping_expression(expression.receiver, replacements), member: expression.member)
        when AST::IndexAccess
          AST::IndexAccess.new(
            receiver: substitute_foreign_mapping_expression(expression.receiver, replacements),
            index: substitute_foreign_mapping_expression(expression.index, replacements),
          )
        when AST::Specialization
          AST::Specialization.new(
            callee: substitute_foreign_mapping_expression(expression.callee, replacements),
            arguments: expression.arguments.map do |argument|
              AST::Argument.new(name: argument.name, value: substitute_foreign_mapping_expression(argument.value, replacements))
            end,
          )
        when AST::Call
          AST::Call.new(
            callee: substitute_foreign_mapping_expression(expression.callee, replacements),
            arguments: expression.arguments.map do |argument|
              AST::Argument.new(name: argument.name, value: substitute_foreign_mapping_expression(argument.value, replacements))
            end,
          )
        when AST::UnaryOp
          AST::UnaryOp.new(operator: expression.operator, operand: substitute_foreign_mapping_expression(expression.operand, replacements))
        when AST::BinaryOp
          AST::BinaryOp.new(
            operator: expression.operator,
            left: substitute_foreign_mapping_expression(expression.left, replacements),
            right: substitute_foreign_mapping_expression(expression.right, replacements),
          )
        when AST::IfExpr
          AST::IfExpr.new(
            condition: substitute_foreign_mapping_expression(expression.condition, replacements),
            then_expression: substitute_foreign_mapping_expression(expression.then_expression, replacements),
            else_expression: substitute_foreign_mapping_expression(expression.else_expression, replacements),
          )
        else
          expression
        end
      end

      def foreign_mapping_reference_counts(expression, counts = Hash.new(0))
        case expression
        when AST::Identifier
          counts[expression.name] += 1
        when AST::MemberAccess
          foreign_mapping_reference_counts(expression.receiver, counts)
        when AST::IndexAccess
          foreign_mapping_reference_counts(expression.receiver, counts)
          foreign_mapping_reference_counts(expression.index, counts)
        when AST::Specialization, AST::Call
          foreign_mapping_reference_counts(expression.callee, counts)
          expression.arguments.each { |argument| foreign_mapping_reference_counts(argument.value, counts) }
        when AST::UnaryOp
          foreign_mapping_reference_counts(expression.operand, counts)
        when AST::BinaryOp
          foreign_mapping_reference_counts(expression.left, counts)
          foreign_mapping_reference_counts(expression.right, counts)
        when AST::IfExpr
          foreign_mapping_reference_counts(expression.condition, counts)
          foreign_mapping_reference_counts(expression.then_expression, counts)
          foreign_mapping_reference_counts(expression.else_expression, counts)
        end

        counts
      end

      def duplicable_foreign_argument_expression?(expression)
        case expression
        when AST::Identifier, AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral,
             IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral
          true
        when AST::MemberAccess
          duplicable_foreign_argument_expression?(expression.receiver)
        when IR::Member
          duplicable_foreign_argument_expression?(expression.receiver)
        when AST::UnaryOp
          duplicable_foreign_argument_expression?(expression.operand)
        when IR::Unary
          duplicable_foreign_argument_expression?(expression.operand)
        when AST::BinaryOp
          duplicable_foreign_argument_expression?(expression.left) && duplicable_foreign_argument_expression?(expression.right)
        when IR::Binary
          duplicable_foreign_argument_expression?(expression.left) && duplicable_foreign_argument_expression?(expression.right)
        else
          false
        end
      end

      def foreign_argument_needs_temporary_binding?(expression, reference_count:)
        return true if reference_count > 1 && !duplicable_foreign_argument_expression?(expression)

        !inlineable_foreign_argument_expression?(expression)
      end

      def automatic_foreign_cstr_list_temp_needed?(parameter, _expression, env: nil)
        return false unless parameter.type.is_a?(Types::Span) && parameter.type.element_type == @types.fetch("str")
        return false unless parameter.boundary_type.is_a?(Types::Span)

        boundary_element_type = parameter.boundary_type.element_type
        boundary_element_type == @types.fetch("cstr") || char_pointer_type?(boundary_element_type)
      end

      def automatic_foreign_cstr_temp_needed?(parameter, expression, env:)
        return false unless parameter.boundary_type == @types.fetch("cstr") && parameter.type == @types.fetch("str")
        return false if expression.is_a?(AST::StringLiteral) && !expression.cstring
        return false if cstr_backed_expression?(expression, env)

        infer_expression_type(expression, env:) != @types.fetch("cstr")
      end

      def temporary_foreign_cstr_expression?(expression)
        expression.is_a?(IR::Call) && expression.callee == "mt_foreign_str_to_cstr_temp"
      end

      def lower_foreign_cstr_list_argument_value(parameter, argument_value, env:, lowered:, cleanup:)
        if (direct_value = lower_direct_foreign_cstr_list_argument_value(parameter, argument_value, env:, lowered:))
          return direct_value
        end

        public_type = parameter.type
        boundary_type = parameter.boundary_type
        items_type = pointer_to(pointer_to(@types.fetch("char")))
        data_type = pointer_to(@types.fetch("char"))
        len_type = @types.fetch("usize")
        lowered_value = lower_contextual_expression(argument_value, env:, expected_type: public_type)
        items_name = fresh_c_temp_name(env, "foreign_cstr_items")
        data_name = fresh_c_temp_name(env, "foreign_cstr_data")
        len_name = fresh_c_temp_name(env, "foreign_cstr_len")

        lowered << IR::LocalDecl.new(
          name: items_name,
          c_name: items_name,
          type: items_type,
          value: IR::NullLiteral.new(type: items_type),
        )
        lowered << IR::LocalDecl.new(
          name: data_name,
          c_name: data_name,
          type: data_type,
          value: IR::NullLiteral.new(type: data_type),
        )
        lowered << IR::LocalDecl.new(
          name: len_name,
          c_name: len_name,
          type: len_type,
          value: IR::IntegerLiteral.new(value: 0, type: len_type),
        )
        lowered << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: "mt_foreign_strs_to_cstrs_temp",
            arguments: [
              lowered_value,
              IR::AddressOf.new(expression: IR::Name.new(name: items_name, type: items_type, pointer: false), type: pointer_to(items_type)),
              IR::AddressOf.new(expression: IR::Name.new(name: data_name, type: data_type, pointer: false), type: pointer_to(data_type)),
              IR::AddressOf.new(expression: IR::Name.new(name: len_name, type: len_type, pointer: false), type: pointer_to(len_type)),
            ],
            type: @types.fetch("void"),
          ),
        )
        cleanup << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: "mt_free_foreign_cstrs_temp",
            arguments: [
              IR::Name.new(name: items_name, type: items_type, pointer: false),
              IR::Name.new(name: data_name, type: data_type, pointer: false),
            ],
            type: @types.fetch("void"),
          ),
        )

        converted_data = foreign_identity_projection_expression(
          IR::Name.new(name: items_name, type: items_type, pointer: false),
          pointer_to(boundary_type.element_type),
        )
        raise LoweringError, "unsupported foreign boundary mapping #{public_type} as #{boundary_type}" unless converted_data

        IR::AggregateLiteral.new(
          type: boundary_type,
          fields: [
            IR::AggregateField.new(name: "data", value: converted_data),
            IR::AggregateField.new(name: "len", value: IR::Name.new(name: len_name, type: len_type, pointer: false)),
          ],
        )
      end

      def lower_direct_foreign_cstr_list_argument_value(parameter, argument_value, env:, lowered:)
        actual_type = infer_expression_type(argument_value, env:)
        return unless array_type?(actual_type)
        return unless cstr_list_backed_expression?(argument_value, env)

        boundary_type = parameter.boundary_type
        boundary_element_type = boundary_type.element_type
        len = array_length(actual_type)
        len_type = @types.fetch("usize")

        if len.zero?
          return IR::AggregateLiteral.new(
            type: boundary_type,
            fields: [
              IR::AggregateField.new(name: "data", value: IR::NullLiteral.new(type: pointer_to(boundary_element_type))),
              IR::AggregateField.new(name: "len", value: IR::IntegerLiteral.new(value: 0, type: len_type)),
            ],
          )
        end

        source = lower_expression(argument_value, env:, expected_type: actual_type)
        item_type = array_element_type(actual_type)
        items_array_type = Types::GenericInstance.new("array", [boundary_element_type, Types::LiteralTypeArg.new(len)])
        items_name = fresh_c_temp_name(env, "foreign_cstr_items")
        items = (0...len).map do |index|
          item = IR::Index.new(
            receiver: source,
            index: IR::IntegerLiteral.new(value: index, type: len_type),
            type: item_type,
          )
          item = IR::Member.new(receiver: item, member: "data", type: pointer_to(@types.fetch("char"))) if item_type == @types.fetch("str")

          converted = foreign_identity_projection_expression(item, boundary_element_type)
          raise LoweringError, "unsupported foreign boundary mapping #{parameter.type} as #{boundary_type}" unless converted

          converted
        end

        lowered << IR::LocalDecl.new(
          name: items_name,
          c_name: items_name,
          type: items_array_type,
          value: IR::ArrayLiteral.new(type: items_array_type, elements: items),
        )

        items_ref = IR::Name.new(name: items_name, type: items_array_type, pointer: false)
        IR::AggregateLiteral.new(
          type: boundary_type,
          fields: [
            IR::AggregateField.new(
              name: "data",
              value: IR::AddressOf.new(
                expression: IR::Index.new(
                  receiver: items_ref,
                  index: IR::IntegerLiteral.new(value: 0, type: len_type),
                  type: boundary_element_type,
                ),
                type: pointer_to(boundary_element_type),
              ),
            ),
            IR::AggregateField.new(name: "len", value: IR::IntegerLiteral.new(value: len, type: len_type)),
          ],
        )
      end

      def inlineable_foreign_argument_expression?(expression)
        case expression
        when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::ZeroInit, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
          true
        when IR::Call
          return false if temporary_foreign_cstr_expression?(expression)

          callee_inlineable = expression.callee.is_a?(String) || inlineable_foreign_argument_expression?(expression.callee)
          callee_inlineable && expression.arguments.all? { |argument| inlineable_foreign_argument_expression?(argument) }
        when IR::Member
          inlineable_foreign_argument_expression?(expression.receiver)
        when IR::Index
          inlineable_foreign_argument_expression?(expression.receiver) && inlineable_foreign_argument_expression?(expression.index)
        when IR::CheckedIndex, IR::CheckedSpanIndex
          inlineable_foreign_argument_expression?(expression.receiver) && inlineable_foreign_argument_expression?(expression.index)
        when IR::Unary
          inlineable_foreign_argument_expression?(expression.operand)
        when IR::Binary
          inlineable_foreign_argument_expression?(expression.left) && inlineable_foreign_argument_expression?(expression.right)
        when IR::Conditional
          inlineable_foreign_argument_expression?(expression.condition) &&
            inlineable_foreign_argument_expression?(expression.then_expression) &&
            inlineable_foreign_argument_expression?(expression.else_expression)
        when IR::ReinterpretExpr, IR::Cast
          inlineable_foreign_argument_expression?(expression.expression)
        when IR::AddressOf
          inlineable_foreign_argument_expression?(expression.expression)
        when IR::AggregateLiteral
          expression.fields.all? { |field| inlineable_foreign_argument_expression?(field.value) }
        else
          false
        end
      end

      def lower_contextual_expression(expression, env:, expected_type:, external_numeric: false, contextual_int_to_float: false)
        if string_literal_cstr_compatibility?(expression, expected_type)
          return IR::StringLiteral.new(value: expression.value, type: expected_type, cstring: true)
        end

        lowered = lower_expression(expression, env:, expected_type: expected_type)
        return lowered unless expected_type
        return lowered if lowered.type == expected_type
        return lower_direct_function_to_proc_expression(expression, lowered, env:, expected_type:) if direct_function_to_proc_contextual_compatibility?(expression, lowered.type, env:, expected_type:)
        return lower_str_builder_to_span_expression(lowered, expected_type) if str_builder_to_span_compatible?(lowered.type, expected_type)
        return lower_array_to_span_expression(lowered, expected_type) if array_to_span_compatible?(lowered.type, expected_type)
        return cast_expression(lowered, expected_type) if contextual_numeric_compatibility?(expression, lowered.type, expected_type, external_numeric:, contextual_int_to_float:)

        lowered
      end

      def direct_function_to_proc_contextual_compatibility?(expression, actual_type, env:, expected_type:)
        return false unless actual_type.is_a?(Types::Function) && proc_type?(expected_type)
        return false unless direct_function_identity_expression?(expression, env)

        function_type_matches_proc_type?(actual_type, expected_type)
      end

      def function_type_matches_proc_type?(function_type, proc_type)
        return false if function_type.receiver_type || function_type.variadic
        return false unless function_type.params.length == proc_type.params.length
        return false unless function_type.return_type == proc_type.return_type

        function_type.params.zip(proc_type.params).all? do |function_param, proc_param|
          function_param.type == proc_param.type && function_param.mutable == proc_param.mutable
        end
      end

      def direct_function_identity_expression?(expression, env)
        case expression
        when AST::Identifier
          return false if lookup_value(expression.name, env)
          return false unless @functions.key?(expression.name)

          binding = @functions.fetch(expression.name)
          !binding.type_params.any? && !foreign_function_binding?(binding)
        when AST::MemberAccess
          return false unless expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)

          imported_module = @imports.fetch(expression.receiver.name)
          return false unless imported_module.functions.key?(expression.member)

          binding = imported_module.functions.fetch(expression.member)
          !binding.type_params.any? && !foreign_function_binding?(binding)
        when AST::Specialization
          binding = resolve_specialized_function_binding(expression)
          binding && !foreign_function_binding?(binding)
        else
          false
        end
      end

      def lower_direct_function_to_proc_expression(source_expression, source_function, env:, expected_type:)
        raise LoweringError, "function-to-proc coercion requires a direct function name" unless source_function.is_a?(IR::Name)

        proc_id = fresh_proc_symbol
        invoke_c_name = "#{@module_prefix}__proc_#{proc_id}__invoke"
        release_c_name = "#{@module_prefix}__proc_#{proc_id}__release"
        retain_c_name = "#{@module_prefix}__proc_#{proc_id}__retain"

        @synthetic_functions << build_direct_function_proc_invoke_function(source_expression, source_function.name, source_function.type, expected_type, invoke_c_name)
        @synthetic_functions << build_proc_noop_release_function(release_c_name)
        @synthetic_functions << build_proc_noop_retain_function(retain_c_name)

        IR::AggregateLiteral.new(
          type: expected_type,
          fields: [
            IR::AggregateField.new(name: "env", value: IR::NullLiteral.new(type: proc_env_pointer_type)),
            IR::AggregateField.new(name: "invoke", value: IR::Name.new(name: invoke_c_name, type: proc_invoke_function_type(expected_type), pointer: false)),
            IR::AggregateField.new(name: "release", value: IR::Name.new(name: release_c_name, type: proc_release_function_type, pointer: false)),
            IR::AggregateField.new(name: "retain", value: IR::Name.new(name: retain_c_name, type: proc_retain_function_type, pointer: false)),
          ],
        )
      end

      def build_direct_function_proc_invoke_function(source_expression, function_c_name, function_type, proc_type, invoke_c_name)
        env = empty_env
        params = [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)]
        parameter_setup = []
        call_arguments = []

        proc_type.params.each_with_index do |param, index|
          c_name = c_local_name(param.name || "arg#{index}")
          if array_type?(param.type)
            input_c_name = "#{c_name}_input"
            params << IR::Param.new(name: param.name || "arg#{index}", c_name: input_c_name, type: param.type, pointer: false)
            env[:scopes].last[param.name || "arg#{index}"] = local_binding(type: param.type, c_name:, mutable: param.mutable, pointer: false)
            parameter_setup << IR::LocalDecl.new(
              name: param.name || "arg#{index}",
              c_name:,
              type: param.type,
              value: IR::Name.new(name: input_c_name, type: param.type, pointer: false),
            )
            call_arguments << IR::Name.new(name: c_name, type: param.type, pointer: false)
          else
            env[:scopes].last[param.name || "arg#{index}"] = local_binding(type: param.type, c_name:, mutable: param.mutable, pointer: false)
            params << IR::Param.new(name: param.name || "arg#{index}", c_name:, type: param.type, pointer: false)
            call_arguments << IR::Name.new(name: c_name, type: param.type, pointer: false)
          end
        end

        call = IR::Call.new(callee: function_c_name, arguments: call_arguments, type: proc_type.return_type)
        body = if proc_type.return_type == @types.fetch("void")
                 parameter_setup + [IR::ExpressionStmt.new(expression: call), IR::ReturnStmt.new(value: nil)]
               else
                 parameter_setup + [IR::ReturnStmt.new(value: call)]
               end

        IR::Function.new(name: invoke_c_name, c_name: invoke_c_name, params:, return_type: proc_type.return_type, body:, entry_point: false)
      end

      def build_proc_noop_release_function(release_c_name)
        IR::Function.new(
          name: release_c_name,
          c_name: release_c_name,
          params: [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)],
          return_type: @types.fetch("void"),
          body: [IR::ReturnStmt.new(value: nil)],
          entry_point: false,
        )
      end

      def build_proc_noop_retain_function(retain_c_name)
        IR::Function.new(
          name: retain_c_name,
          c_name: retain_c_name,
          params: [IR::Param.new(name: "env", c_name: "__mt_proc_env", type: proc_env_pointer_type, pointer: false)],
          return_type: @types.fetch("void"),
          body: [IR::ReturnStmt.new(value: nil)],
          entry_point: false,
        )
      end

      def lower_array_to_span_expression(expression, target_type)
        IR::AggregateLiteral.new(
          type: target_type,
          fields: [
            IR::AggregateField.new(
              name: "data",
              value: IR::AddressOf.new(
                expression: IR::Index.new(
                  receiver: expression,
                  index: IR::IntegerLiteral.new(value: 0, type: @types.fetch("usize")),
                  type: target_type.element_type,
                ),
                type: pointer_to(target_type.element_type),
              ),
            ),
            IR::AggregateField.new(
              name: "len",
              value: IR::IntegerLiteral.new(value: array_length(expression.type), type: @types.fetch("usize")),
            ),
          ],
        )
      end

      def lower_str_builder_to_span_expression(expression, target_type)
        IR::AggregateLiteral.new(
          type: target_type,
          fields: [
            IR::AggregateField.new(
              name: "data",
              value: IR::Call.new(
                callee: "mt_str_builder_prepare_write",
                arguments: [
                  lower_str_builder_data_pointer_from_lowered(expression),
                  IR::IntegerLiteral.new(value: str_builder_capacity(expression.type), type: @types.fetch("usize")),
                  lower_str_builder_dirty_pointer_from_lowered(expression),
                ],
                type: pointer_to(target_type.element_type),
              ),
            ),
            IR::AggregateField.new(
              name: "len",
              value: IR::IntegerLiteral.new(value: str_builder_storage_capacity(expression.type), type: @types.fetch("usize")),
            ),
          ],
        )
      end

      def contextual_numeric_compatibility?(expression, actual_type, expected_type, external_numeric: false, contextual_int_to_float: false)
        return true if integer_literal_numeric_compatibility?(expression, expected_type)
        return true if integer_to_char_compatibility?(actual_type, expected_type)
        return true if external_numeric && external_numeric_compatibility?(actual_type, expected_type)
        return true if contextual_int_to_float && contextual_int_to_float_compatibility?(actual_type, expected_type)

        false
      end

      def string_literal_cstr_compatibility?(expression, expected_type)
        expression.is_a?(AST::StringLiteral) && !expression.cstring && expected_type == @types.fetch("cstr")
      end

      def cstr_backed_expression?(expression, env)
        return true if infer_expression_type(expression, env:) == @types.fetch("cstr")

        case expression
        when AST::StringLiteral
          true
        when AST::Identifier
          binding_cstr_backed?(lookup_value(expression.name, env))
        when AST::IfExpr
          then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
          else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
          cstr_backed_expression?(expression.then_expression, then_env) &&
            cstr_backed_expression?(expression.else_expression, else_env)
        else
          false
        end
      rescue LoweringError
        false
      end

      def cstr_list_backed_expression?(expression, env)
        actual_type = infer_expression_type(expression, env:)
        return false unless array_type?(actual_type)

        element_type = array_element_type(actual_type)
        return false unless element_type == @types.fetch("str") || element_type == @types.fetch("cstr")

        case expression
        when AST::Identifier
          binding_cstr_list_backed?(lookup_value(expression.name, env))
        when AST::Call
          expression.arguments.all? { |argument| cstr_backed_expression?(argument.value, env) }
        when AST::IfExpr
          then_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: true, env:))
          else_env = env_with_refinements(env, flow_refinements(expression.condition, truthy: false, env:))
          cstr_list_backed_expression?(expression.then_expression, then_env) &&
            cstr_list_backed_expression?(expression.else_expression, else_env)
        else
          false
        end
      rescue LoweringError
        false
      end

      def cstr_backed_storage_value?(type, expression, env)
        return false unless expression
        return true if type == @types.fetch("cstr")
        return false unless type == @types.fetch("str")

        cstr_backed_expression?(expression, env)
      end

      def cstr_list_backed_storage_value?(type, expression, env)
        return false unless expression
        return false unless cstr_list_trackable_type?(type)

        cstr_list_backed_expression?(expression, env)
      end

      def update_cstr_metadata_for_assignment!(statement, prepared_value, env)
        if statement.target.is_a?(AST::Identifier)
          binding = lookup_value(statement.target.name, env)
          return unless binding

          replace_binding_cstr_metadata!(
            statement.target.name,
            env,
            cstr_backed: statement.operator == "=" ? cstr_backed_storage_value?(binding[:type], prepared_value, env) : false,
            cstr_list_backed: statement.operator == "=" ? cstr_list_backed_storage_value?(binding[:type], prepared_value, env) : false,
          )
          return
        end

        return unless statement.target.is_a?(AST::IndexAccess) && statement.target.receiver.is_a?(AST::Identifier)

        binding = lookup_value(statement.target.receiver.name, env)
        return unless binding && cstr_list_trackable_type?(binding[:type])

        replace_binding_cstr_metadata!(statement.target.receiver.name, env, cstr_backed: binding_cstr_backed?(binding), cstr_list_backed: false)
      end

      def merge_cstr_metadata_after_if_statement!(statement, env)
        exit_envs = cstr_metadata_exit_envs_for_if_statement(statement, env)
        return if exit_envs.empty?

        trackable_binding_names(env).each do |name|
          binding = lookup_value(name, env)
          next unless binding

          replace_binding_cstr_metadata!(
            name,
            env,
            cstr_backed: cstr_trackable_type?(binding[:type]) && exit_envs.all? { |exit_env| binding_cstr_backed?(lookup_value(name, exit_env)) },
            cstr_list_backed: cstr_list_trackable_type?(binding[:type]) && exit_envs.all? { |exit_env| binding_cstr_list_backed?(lookup_value(name, exit_env)) },
          )
        end
      end

      def cstr_metadata_exit_envs_for_if_statement(statement, env)
        false_refinements = {}
        exit_envs = []

        statement.branches.each do |branch|
          branch_env = env_with_refinements(env, false_refinements)
          true_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: true, env: branch_env))
          simulated = simulate_cstr_metadata_block(branch.body, env: env_with_refinements(env, true_refinements))
          exit_envs << simulated if simulated
          false_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: false, env: branch_env))
        end

        if statement.else_body
          simulated = simulate_cstr_metadata_block(statement.else_body, env: env_with_refinements(env, false_refinements))
          exit_envs << simulated if simulated
        else
          exit_envs << env
        end

        exit_envs
      end

      def simulate_cstr_metadata_block(statements, env:)
        simulated_env = duplicate_env(env)

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            type = statement.type ? resolve_type_ref(statement.type) : infer_expression_type(statement.value, env: simulated_env)
            current_actual_scope(simulated_env[:scopes])[statement.name] = local_binding(
              type:,
              c_name: c_local_name(statement.name),
              mutable: statement.kind == :var,
              pointer: false,
              cstr_backed: cstr_backed_storage_value?(type, statement.value, simulated_env),
              cstr_list_backed: cstr_list_backed_storage_value?(type, statement.value, simulated_env),
            )
          when AST::Assignment
            update_cstr_metadata_for_assignment!(statement, statement.value, simulated_env)
          when AST::IfStmt
            merge_cstr_metadata_after_if_statement!(statement, simulated_env)
          when AST::UnsafeStmt
            nested_env = simulate_cstr_metadata_block(statement.body, env: simulated_env)
            return nil unless nested_env

            copy_cstr_metadata!(simulated_env, nested_env)
          when AST::ReturnStmt, AST::BreakStmt, AST::ContinueStmt
            return nil
          end
        end

        simulated_env
      end

      def copy_cstr_metadata!(target_env, source_env)
        trackable_binding_names(target_env).each do |name|
          binding = lookup_value(name, target_env)
          source_binding = lookup_value(name, source_env)
          next unless binding && source_binding

          replace_binding_cstr_metadata!(
            name,
            target_env,
            cstr_backed: binding_cstr_backed?(source_binding),
            cstr_list_backed: binding_cstr_list_backed?(source_binding),
          )
        end
      end

      def replace_binding_cstr_metadata!(name, env, cstr_backed:, cstr_list_backed:)
        env[:scopes].reverse_each do |scope|
          next if scope.is_a?(Sema::FlowScope)
          next unless scope.key?(name)

          scope[name] = scope.fetch(name).merge(cstr_backed:, cstr_list_backed:)
          return
        end
      end

      def trackable_binding_names(env)
        env[:scopes].each_with_object([]) do |scope, names|
          next if scope.is_a?(Sema::FlowScope)

          scope.each do |name, binding|
            next unless cstr_trackable_type?(binding[:type]) || cstr_list_trackable_type?(binding[:type])

            names << name unless names.include?(name)
          end
        end
      end

      def binding_cstr_backed?(binding)
        binding && binding[:cstr_backed]
      end

      def binding_cstr_list_backed?(binding)
        binding && binding[:cstr_list_backed]
      end

      def integer_literal_numeric_compatibility?(expression, expected_type)
        integer_literal_expression?(expression) && expected_type.is_a?(Types::Primitive) && expected_type.numeric?
      end

      def integer_to_char_compatibility?(actual_type, expected_type)
        char_type?(expected_type) && integer_like_char_source_type?(actual_type)
      end

      def integer_like_char_source_type?(type)
        return true if type.is_a?(Types::Primitive) && type.integer?
        return true if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?

        false
      end

      def char_type?(type)
        type.is_a?(Types::Primitive) && type.name == "char"
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
          receiver_type = infer_field_receiver_type(expression.receiver, env:)
          receiver_type.respond_to?(:external) && receiver_type.external
        else
          false
        end
      end

      def lower_specialization(expression, env:, type:)
        if (function_binding = resolve_specialized_function_binding(expression))
          raise LoweringError, "foreign function #{function_binding.name} cannot be used as a value" if foreign_function_binding?(function_binding)

          if function_binding.external
            return IR::Name.new(name: function_binding.name, type:, pointer: false)
          end

          return IR::Name.new(
            name: function_binding_c_name(function_binding, module_name: function_binding.owner.module_name),
            type:,
            pointer: false,
          )
        end

        raise LoweringError, "specialization #{expression.callee.name} must be called" if expression.callee.is_a?(AST::Identifier)

        raise LoweringError, "unsupported specialization #{expression.class.name}"
      end

      def resolve_callee(callee, env, arguments: nil)
        case callee
        when AST::Identifier
          if (binding = lookup_value(callee.name, env))
            return [:callable_value, nil, nil, binding[:type], nil] if callable_type?(binding[:type])

            raise LoweringError, "#{callee.name} is not callable"
          end

          if @functions.key?(callee.name)
            binding = specialize_function_binding(@functions.fetch(callee.name), arguments, env)
            [ :function, function_binding_c_name(binding, module_name: @module_name), nil, binding.type, binding ]
          elsif callee.name == "ok"
            [:result_ok, nil, nil, nil]
          elsif callee.name == "err"
            [:result_err, nil, nil, nil]
          elsif callee.name == "panic"
            [:panic, nil, nil, nil]
          elsif callee.name == "ref_of"
            [:ref_of, nil, nil, nil]
          elsif callee.name == "const_ptr_of"
            [:const_ptr_of, nil, nil, nil]
          elsif callee.name == "read"
            [:read, nil, nil, nil]
          elsif callee.name == "ptr_of"
            [:ptr_of, nil, nil, nil]
          elsif (type = @types[callee.name]).is_a?(Types::Struct) || type.is_a?(Types::StringView) || task_type?(type)
            [ :struct_literal, nil, nil, type ]
          else
            raise LoweringError, "unknown callee #{callee.name}"
          end
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @imports.key?(callee.receiver.name)
            imported_module = @imports.fetch(callee.receiver.name)
            if imported_module.functions.key?(callee.member)
              binding = specialize_function_binding(imported_module.functions.fetch(callee.member), arguments, env)
              return [:function, function_binding_c_name(binding, module_name: imported_module.name), nil, binding.type, binding] unless binding.external

              return [:function, binding.name, nil, binding.type, binding]
            end
            imported_type = imported_module.types[callee.member]
            if imported_type.is_a?(Types::Struct) || imported_type.is_a?(Types::StringView) || task_type?(imported_type)
              return [:struct_literal, nil, nil, imported_module.types.fetch(callee.member)]
            end

            if imported_type.is_a?(Types::Variant) && imported_type.arm_names.include?(callee.member)
              arm_name = callee.member
              return [:variant_arm_ctor, nil, nil, imported_type, [imported_type, arm_name]]
            end
          end

          if (type_expr = resolve_type_expression(callee.receiver))
            if type_expr.is_a?(Types::Variant) && type_expr.arm_names.include?(callee.member)
              arm_name = callee.member
              return [:variant_arm_ctor, nil, nil, type_expr, [type_expr, arm_name]]
            end

            method_entry = @method_definitions[[type_expr, callee.member]]
            if method_entry
              method_analysis, method_ast = method_entry
              method_binding = method_analysis.methods.fetch(type_expr).fetch(method_ast.name)
              if method_binding.type.receiver_type.nil?
                method_binding = specialize_function_binding(method_binding, arguments, env) if method_binding.type_params.any?
                return [:associated_method, function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: type_expr), nil, method_binding.type]
              end
            end

            raise LoweringError, "unknown associated function #{type_expr}.#{callee.member}"
          end

          resolved_receiver_type = infer_method_receiver_type(callee.receiver, env:)
          method_entry = @method_definitions[[resolved_receiver_type, callee.member]]
          if method_entry
            method_analysis, method_ast = method_entry
            method_binding = method_analysis.methods.fetch(resolved_receiver_type).fetch(method_ast.name)
            method_binding = specialize_function_binding(method_binding, arguments, env)
            return [
              :method,
              function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: resolved_receiver_type),
              callee.receiver,
              method_binding.type,
            ]
          end

          if (str_builder_method = str_builder_method_kind(resolved_receiver_type, callee.member))
            return [str_builder_method, nil, callee.receiver, str_builder_method_type(str_builder_method, resolved_receiver_type)]
          end

          field_receiver_type = infer_field_receiver_type(callee.receiver, env:)
          member_type = field_receiver_type.respond_to?(:field) ? field_receiver_type.field(callee.member) : nil
          return [:callable_value, nil, nil, member_type, nil] if callable_type?(member_type)

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
              return [:function, function_binding.name, nil, function_binding.type, function_binding]
            end

            return [:function, function_binding_c_name(function_binding, module_name: function_binding.owner.module_name), nil, function_binding.type, function_binding]
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct_literal, nil, nil, specialized_type] if specialized_type.is_a?(Types::Struct) || result_type?(specialized_type) || task_type?(specialized_type)
          end

          raise LoweringError, "unsupported specialization callee"
        else
          callee_type = infer_expression_type(callee, env:)
          return [:callable_value, nil, nil, callee_type, nil] if callable_type?(callee_type)

          raise LoweringError, "unsupported callee #{callee.class.name}"
        end
      end

      def infer_expression_type(expression, env:, expected_type: nil)
        case expression
        when AST::AwaitExpr
          task_type = infer_expression_type(expression.expression, env:)
          raise LoweringError, "await requires a Task value, got #{task_type}" unless task_type.is_a?(Types::Task)

          task_type.result_type
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
        when AST::FormatString
          @types.fetch("str")
        when AST::BooleanLiteral
          @types.fetch("bool")
        when AST::NullLiteral
          infer_null_literal_type(expression, expected_type)
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
            return imported_module.functions.fetch(expression.member).type if imported_module.functions.key?(expression.member)
          end
          receiver_type = infer_field_receiver_type(expression.receiver, env:)
          return receiver_type.field(expression.member) if receiver_type.respond_to?(:field)

          raise LoweringError, "unknown member #{expression.member}"
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          index_type = infer_expression_type(expression.index, env:)
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
        when AST::ProcExpr
          resolve_type_ref(AST::ProcType.new(params: expression.params, return_type: expression.return_type))
        when AST::Call
          kind, = resolve_callee(expression.callee, env, arguments: expression.arguments)
          case kind
          when :function, :method, :associated_method, :callable_value,
            :str_builder_clear, :str_builder_assign, :str_builder_append, :str_builder_len, :str_builder_capacity, :str_builder_as_str, :str_builder_as_cstr
            _, _, _, function_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            function_type.return_type
          when :struct_literal, :array
            _, _, _, struct_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            struct_type
          when :ref_of
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            Types::GenericInstance.new("ref", [argument_type])
          when :const_ptr_of
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            Types::GenericInstance.new("const_ptr", [argument_type])
          when :read
            infer_value_type(expression.arguments.fetch(0).value, env:)
          when :ptr_of
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
          when :variant_arm_ctor
            _, _, _, variant_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
            variant_type
          when :panic
            @types.fetch("void")
          else
            raise LoweringError, "unsupported call kind #{kind}"
          end
        when AST::Specialization
          if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "cast"
            resolve_type_ref(expression.arguments.fetch(0).value)
          elsif (function_binding = resolve_specialized_function_binding(expression))
            function_binding.type
          else
            raise LoweringError, "unsupported specialization"
          end
        when AST::RangeExpr
          raise LoweringError, "range expression is not valid in this context; use it as a for-loop iterable"
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

      def reinterpret_expression(expression, target_type)
        return expression if expression.type == target_type

        IR::ReinterpretExpr.new(target_type:, source_type: expression.type, expression:, type: target_type)
      end

      def foreign_identity_projection_expression(expression, target_type)
        return expression if expression.type == target_type
        return cast_expression(expression, target_type) if foreign_identity_projection_cast_compatible?(expression.type, target_type)
        return reinterpret_expression(expression, target_type) if foreign_identity_projection_reinterpret_compatible?(expression.type, target_type)

        nil
      end

      def foreign_identity_projection_compatible?(actual_type, expected_type)
        foreign_identity_projection_cast_compatible?(actual_type, expected_type) ||
          foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type)
      end

      def foreign_span_boundary_compatible?(public_type, boundary_type)
        return false unless public_type.is_a?(Types::Span) && boundary_type.is_a?(Types::Span)

        foreign_boundary_element_compatible?(public_type.element_type, boundary_type.element_type)
      end

      def foreign_char_pointer_buffer_boundary_compatible?(public_type, boundary_type)
        return false unless char_pointer_type?(boundary_type)

        return true if public_type.is_a?(Types::Span) && public_type.element_type == @types.fetch("char")
        return true if char_array_text_type?(public_type)
        return true if str_builder_type?(public_type)

        false
      end

      def foreign_boundary_element_compatible?(public_type, boundary_type)
        return true if public_type == boundary_type
        return true if public_type == @types.fetch("str") && boundary_type == @types.fetch("cstr")
        return true if public_type == @types.fetch("str") && char_pointer_type?(boundary_type)

        foreign_identity_projection_compatible?(public_type, boundary_type)
      end

      def foreign_identity_projection_cast_compatible?(actual_type, expected_type)
        return true if actual_type == expected_type
        return true if same_external_opaque_c_name?(actual_type, expected_type)

        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          return foreign_identity_projection_cast_compatible?(actual_type.base, expected_type.base)
        end

        return foreign_identity_projection_cast_compatible?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
        return false if actual_type.is_a?(Types::Nullable)

        if pointer_type?(actual_type) && pointer_type?(expected_type)
          return true if void_pointer_type?(actual_type) || void_pointer_type?(expected_type)

          return true if foreign_identity_projection_cast_compatible?(actual_type.arguments.first, expected_type.arguments.first)

          return foreign_external_layout_compatible?(actual_type.arguments.first, expected_type.arguments.first)
        end

        return true if void_pointer_type?(actual_type) && opaque_type?(expected_type)
        return true if opaque_type?(actual_type) && void_pointer_type?(expected_type)
        return true if char_pointer_type?(actual_type) && expected_type == @types.fetch("cstr")
        return true if actual_type == @types.fetch("cstr") && char_pointer_type?(expected_type)

        false
      end

      def same_external_opaque_c_name?(actual_type, expected_type)
        return false unless actual_type.is_a?(Types::Opaque) && expected_type.is_a?(Types::Opaque)
        return false unless actual_type.external && expected_type.external

        foreign_opaque_c_name(actual_type) == foreign_opaque_c_name(expected_type)
      end

      def foreign_opaque_c_name(type)
        type.c_name || type.name
      end

      def foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type)
        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          return foreign_identity_projection_reinterpret_compatible?(actual_type.base, expected_type.base)
        end

        return foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
        return false if actual_type.is_a?(Types::Nullable)

        foreign_external_layout_compatible?(actual_type, expected_type)
      end

      def foreign_external_layout_compatible?(actual_type, expected_type, seen = {})
        return false unless actual_type.is_a?(Types::Struct) && expected_type.is_a?(Types::Struct)
        return false if actual_type.is_a?(Types::Union) != expected_type.is_a?(Types::Union)
        return false unless actual_type.external && expected_type.external
        return false unless actual_type.name == expected_type.name
        return false unless actual_type.packed == expected_type.packed
        return false unless actual_type.alignment == expected_type.alignment

        key = [actual_type.object_id, expected_type.object_id]
        return true if seen[key]

        seen[key] = true
        actual_fields = actual_type.fields
        expected_fields = expected_type.fields
        return false unless actual_fields.keys == expected_fields.keys

        actual_fields.all? do |field_name, field_type|
          foreign_external_layout_field_compatible?(field_type, expected_fields.fetch(field_name), seen)
        end
      end

      def foreign_external_layout_field_compatible?(actual_type, expected_type, seen)
        return true if actual_type == expected_type

        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          return foreign_external_layout_field_compatible?(actual_type.base, expected_type.base, seen)
        end

        if pointer_type?(actual_type) && pointer_type?(expected_type)
          return foreign_external_layout_field_compatible?(actual_type.arguments.first, expected_type.arguments.first, seen)
        end

        if array_type?(actual_type) && array_type?(expected_type)
          return false unless array_length(actual_type) == array_length(expected_type)

          return foreign_external_layout_field_compatible?(array_element_type(actual_type), array_element_type(expected_type), seen)
        end

        foreign_external_layout_compatible?(actual_type, expected_type, seen)
      end

      def void_pointer_type?(type)
        pointer_type?(type) && type.arguments.first == @types.fetch("void")
      end

      def char_pointer_type?(type)
        pointer_type?(type) && type.arguments.first == @types.fetch("char")
      end

      def opaque_type?(type)
        type.is_a?(Types::Opaque)
      end

      def infer_null_literal_type(expression, expected_type)
        return Types::Null.new(resolve_type_ref(expression.type)) if expression.type

        expected_type || null_type
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
        when AST::Specialization
          type_ref = type_ref_from_specialization(expression)
          return nil unless type_ref

          resolve_type_ref(type_ref)
        end
      end

      def resolve_type_member(type, name)
        case type
        when Types::Enum, Types::Flags
          type.member(name)
        when Types::Variant
          type if type.arm_names.include?(name)
        end
      end

      def function_type_for_name(name)
        binding = @functions.fetch(name)
        raise LoweringError, "generic function #{name} cannot be used as a value" if binding.type_params.any?
        raise LoweringError, "foreign function #{name} cannot be used as a value" if foreign_function_binding?(binding)

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
          resolve_type_argument(argument.value)
        end
      end

      def resolve_type_argument(argument, type_params: current_type_params)
        case argument
        when AST::TypeRef
          resolve_type_argument_ref(argument, type_params:)
        when AST::FunctionType
          resolve_type_ref(argument, type_params:)
        when AST::IntegerLiteral, AST::FloatLiteral
          Types::LiteralTypeArg.new(argument.value)
        else
          raise LoweringError, "unsupported type argument #{argument.class.name}"
        end
      end

      def resolve_type_argument_ref(type_ref, type_params:)
        return resolve_type_ref(type_ref, type_params:) unless literal_type_argument_name_candidate?(type_ref)

        resolve_type_ref(type_ref, type_params:)
      rescue LoweringError => error
        literal_type_argument = resolve_named_literal_type_argument(type_ref)
        return literal_type_argument if literal_type_argument

        raise error
      end

      def literal_type_argument_name_candidate?(type_ref)
        type_ref.arguments.empty? && !type_ref.nullable
      end

      def resolve_named_literal_type_argument(type_ref)
        value = case type_ref.name.parts.length
                when 1
                  resolve_current_module_const_value(type_ref.name.parts.first)
                when 2
                  resolve_imported_module_const_value(type_ref.name.parts.first, type_ref.name.parts.last)
                end

        return unless value.is_a?(Integer) || value.is_a?(Float)

        Types::LiteralTypeArg.new(value)
      end

      def resolve_current_module_const_value(name)
        binding = @values[name]
        return unless binding&.kind == :const

        binding.const_value
      end

      def resolve_imported_module_const_value(import_name, value_name)
        imported_module = @imports[import_name]
        return unless imported_module
        if imported_module.private_value?(value_name)
          raise LoweringError, "#{import_name}.#{value_name} is private to module #{imported_module.name}"
        end

        binding = imported_module.values[value_name]
        return unless binding&.kind == :const

        binding.const_value
      end

      def compile_time_numeric_const_expression?(expression)
        value = compile_time_const_value(expression)
        value.is_a?(Integer) || value.is_a?(Float)
      end

      def compile_time_const_value(expression)
        case expression
        when AST::IntegerLiteral, AST::FloatLiteral, AST::BooleanLiteral
          expression.value
        when AST::Identifier
          resolve_current_module_const_value(expression.name)
        when AST::MemberAccess
          return unless expression.receiver.is_a?(AST::Identifier)

          resolve_imported_module_const_value(expression.receiver.name, expression.member)
        when AST::UnaryOp
          operand = compile_time_const_value(expression.operand)
          return if operand.nil?

          case expression.operator
          when "+"
            operand
          when "-"
            -operand
          when "not"
            !operand
          end
        when AST::BinaryOp
          left = compile_time_const_value(expression.left)
          right = compile_time_const_value(expression.right)
          return if left.nil? || right.nil?

          case expression.operator
          when "+"
            left + right
          when "-"
            left - right
          when "*"
            left * right
          when "/"
            left / right
          when "%"
            left % right
          when "<<"
            left << right
          when ">>"
            left >> right
          when "&"
            left & right
          when "|"
            left | right
          when "^"
            left ^ right
          else
            nil
          end
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
          body_return_type: substitute_type(binding.body_return_type, substitutions),
          ast: binding.ast,
          external: binding.external,
          async: binding.async,
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
        return actual_count >= function_type.params.length if function_type.is_a?(Types::Function) && function_type.variadic

        actual_count == function_type.params.length
      end

      def arity_error_message(function_type, name, actual_count)
        if function_type.is_a?(Types::Function) && function_type.variadic
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
        when Types::Task
          return unless actual_type.is_a?(Types::Task)

          collect_type_substitutions(pattern_type.result_type, actual_type.result_type, substitutions, function_name)
        when Types::Proc
          actual_params = case actual_type
                          when Types::Proc
                            return unless actual_type.params.length == pattern_type.params.length

                            actual_type.params
                          when Types::Function
                            return if actual_type.receiver_type || actual_type.variadic
                            return unless actual_type.params.length == pattern_type.params.length
                            return unless actual_type.params.zip(pattern_type.params).all? { |actual_param, expected_param| actual_param.mutable == expected_param.mutable }

                            actual_type.params
                          else
                            return
                          end

          pattern_type.params.zip(actual_params).each do |expected_param, actual_param|
            collect_type_substitutions(expected_param.type, actual_param.type, substitutions, function_name)
          end
          collect_type_substitutions(pattern_type.return_type, actual_type.return_type, substitutions, function_name)
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
          id: binding.id,
          name: binding.name,
          storage_type: substitute_type(binding.storage_type, substitutions),
          flow_type: binding.flow_type ? substitute_type(binding.flow_type, substitutions) : nil,
          mutable: binding.mutable,
          kind: binding.kind,
          const_value: binding.const_value,
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
        when Types::Task
          Types::Task.new(substitute_type(type.result_type, substitutions))
        when Types::Proc
          Types::Proc.new(
            params: type.params.map do |param|
              Types::Parameter.new(
                param.name,
                substitute_type(param.type, substitutions),
                mutable: param.mutable,
                passing_mode: param.passing_mode,
                boundary_type: param.boundary_type ? substitute_type(param.boundary_type, substitutions) : nil,
              )
            end,
            return_type: substitute_type(type.return_type, substitutions),
          )
        when Types::StructInstance
          type.definition.instantiate(type.arguments.map { |argument| substitute_type(argument, substitutions) })
        when Types::Function
          Types::Function.new(
            type.name,
            params: type.params.map do |param|
              Types::Parameter.new(
                param.name,
                substitute_type(param.type, substitutions),
                mutable: param.mutable,
                passing_mode: param.passing_mode,
                boundary_type: param.boundary_type ? substitute_type(param.boundary_type, substitutions) : nil,
              )
            end,
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
        type.is_a?(Types::GenericInstance) && ["ptr", "const_ptr"].include?(type.name) && type.arguments.length == 1
      end

      def ref_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ref" && type.arguments.length == 1
      end

      def range_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "range"
      end

      def range_expr?(expression)
        expression.is_a?(AST::RangeExpr)
      end

      def range_iterable?(expression)
        range_call?(expression) || range_expr?(expression)
      end

      def range_start_of(iterable)
        iterable.is_a?(AST::RangeExpr) ? iterable.start_expr : iterable.arguments[0].value
      end

      def range_end_of(iterable)
        iterable.is_a?(AST::RangeExpr) ? iterable.end_expr : iterable.arguments[1].value
      end

      def wildcard_arm_pattern?(expression)
        expression.is_a?(AST::Identifier) && expression.name == "_"
      end

      def variant_match_arm_name_from_pattern(pattern)
        # pattern is TypeName.arm_name or module.TypeName.arm_name
        pattern.is_a?(AST::MemberAccess) ? pattern.member : nil
      end

      def result_type?(type)
        type.is_a?(Types::Result)
      end

      def task_type?(type)
        type.is_a?(Types::Task)
      end

      def array_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
          type.arguments[1].is_a?(Types::LiteralTypeArg)
      end

      def array_element_type(type)
        return unless array_type?(type)

        type.arguments.first
      end

      def array_to_span_compatible?(actual_type, expected_type)
        array_type?(actual_type) && expected_type.is_a?(Types::Span) && array_element_type(actual_type) == expected_type.element_type
      end

      def cstr_trackable_type?(type)
        type == @types.fetch("str") || type == @types.fetch("cstr")
      end

      def cstr_list_trackable_type?(type)
        return false unless array_type?(type)

        element_type = array_element_type(type)
        element_type == @types.fetch("str") || element_type == @types.fetch("cstr")
      end

      def str_builder_to_span_compatible?(actual_type, expected_type)
        str_builder_type?(actual_type) && expected_type.is_a?(Types::Span) && expected_type.element_type == @types.fetch("char")
      end

      def array_length(type)
        return unless array_type?(type)

        type.arguments[1].value
      end

      def char_array_text_type?(type)
        array_type?(type) && array_element_type(type) == @types.fetch("char")
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

      def str_builder_method_kind(receiver_type, name)
        return unless str_builder_type?(receiver_type)

        case name
        when "clear"
          :str_builder_clear
        when "assign"
          :str_builder_assign
        when "append"
          :str_builder_append
        when "len"
          :str_builder_len
        when "capacity"
          :str_builder_capacity
        when "as_str"
          :str_builder_as_str
        when "as_cstr"
          :str_builder_as_cstr
        end
      end

      def str_builder_method_type(kind, receiver_type)
        return_type, params = case kind
                              when :str_builder_clear
                                [@types.fetch("void"), []]
                              when :str_builder_assign, :str_builder_append
                                [@types.fetch("void"), [Types::Parameter.new("value", @types.fetch("str"))]]
                              when :str_builder_len, :str_builder_capacity
                                [@types.fetch("usize"), []]
                              when :str_builder_as_str
                                [@types.fetch("str"), []]
                              when :str_builder_as_cstr
                                [@types.fetch("cstr"), []]
                              else
                                raise LoweringError, "unsupported str_builder method #{kind}"
                              end

        Types::Function.new(
          kind.to_s,
          params:,
          return_type:,
          receiver_type:,
          receiver_mutable: %i[str_builder_clear str_builder_assign str_builder_append].include?(kind),
          external: false,
        )
      end

      def lower_char_array_data_pointer(expression, env:)
        lowered_receiver = lower_expression(expression, env:)
        IR::AddressOf.new(
          expression: IR::Index.new(
            receiver: lowered_receiver,
            index: IR::IntegerLiteral.new(value: 0, type: @types.fetch("usize")),
            type: @types.fetch("char"),
          ),
          type: pointer_to(@types.fetch("char")),
        )
      end

      def lower_str_builder_data_pointer(expression, env:)
        lower_str_builder_data_pointer_from_lowered(lower_expression(expression, env:))
      end

      def lower_str_builder_data_pointer_from_lowered(lowered_receiver)
        IR::AddressOf.new(
          expression: IR::Index.new(
            receiver: IR::Member.new(
              receiver: lowered_receiver,
              member: "data",
              type: Types::GenericInstance.new(
                "array",
                [@types.fetch("char"), Types::LiteralTypeArg.new(str_builder_storage_capacity(lowered_receiver.type))],
              ),
            ),
            index: IR::IntegerLiteral.new(value: 0, type: @types.fetch("usize")),
            type: @types.fetch("char"),
          ),
          type: pointer_to(@types.fetch("char")),
        )
      end

      def lower_str_builder_len_pointer(expression, env:)
        lower_str_builder_len_pointer_from_lowered(lower_expression(expression, env:))
      end

      def lower_str_builder_len_pointer_from_lowered(lowered_receiver)
        IR::AddressOf.new(
          expression: IR::Member.new(receiver: lowered_receiver, member: "len", type: @types.fetch("usize")),
          type: pointer_to(@types.fetch("usize")),
        )
      end

      def lower_str_builder_dirty_pointer(expression, env:)
        lower_str_builder_dirty_pointer_from_lowered(lower_expression(expression, env:))
      end

      def lower_str_builder_dirty_pointer_from_lowered(lowered_receiver)
        IR::AddressOf.new(
          expression: IR::Member.new(receiver: lowered_receiver, member: "dirty", type: @types.fetch("bool")),
          type: pointer_to(@types.fetch("bool")),
        )
      end

      def addressable_storage_expression?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          addressable_storage_expression?(expression.receiver)
        when AST::Call
          read_call?(expression)
        else
          false
        end
      end

      def read_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "read"
      end

      def infer_value_type(handle_expression, env:)
        handle_type = infer_expression_type(handle_expression, env:)
        return referenced_type(handle_type) if ref_type?(handle_type)
        return pointee_type(handle_type) if pointer_type?(handle_type)

        raise LoweringError, "read expects ref[...] or ptr[...], got #{handle_type}"
      end

      def infer_method_receiver_type(receiver_expression, env:)
        receiver_type = infer_expression_type(receiver_expression, env:)
        return referenced_type(receiver_type) if ref_type?(receiver_type)
        return pointee_type(receiver_type) if pointer_type?(receiver_type)

        receiver_type
      end

      def infer_field_receiver_type(receiver_expression, env:)
        receiver_type = infer_expression_type(receiver_expression, env:)
        return referenced_type(receiver_type) if ref_type?(receiver_type)
        return pointee_type(receiver_type) if pointer_type?(receiver_type)

        receiver_type
      end

      def infer_ref_argument_type(handle_expression, env:)
        handle_type = infer_expression_type(handle_expression, env:)
        return referenced_type(handle_type) if ref_type?(handle_type)

        raise LoweringError, "ptr_of expects ref[...] argument, got #{handle_type}"
      end

      def collection_loop_type(type)
        return array_element_type(type) if array_type?(type)
        return type.element_type if type.is_a?(Types::Span)

        nil
      end

      def infer_range_loop_type(expression, env:)
        start_expr = range_start_of(expression)
        stop_expr = range_end_of(expression)
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
        when Types::Task
          contains_ref_type?(type.result_type)
        when Types::StructInstance
          type.arguments.any? { |argument| contains_ref_type?(argument) }
        when Types::Proc
          type.params.any? { |param| contains_ref_type?(param.type) } || contains_ref_type?(type.return_type)
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

      def const_pointer_to(type)
        Types::GenericInstance.new("const_ptr", [type])
      end

      def analysis_for_module(module_name)
        @program.analyses_by_module_name.fetch(module_name)
      end

      def with_analysis_context(analysis)
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
        yield
      ensure
        @analysis = saved_analysis
        @module_name = saved_module_name
        @module_prefix = saved_module_prefix
        @imports = saved_imports
        @types = saved_types
        @values = saved_values
        @functions = saved_functions
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
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:))
          end
          return Types::Function.new(nil, params:, return_type: resolve_type_ref(type_ref.return_type, type_params:))
        end

        if type_ref.is_a?(AST::ProcType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:))
          end
          return Types::Proc.new(params:, return_type: resolve_type_ref(type_ref.return_type, type_params:))
        end

        parts = type_ref.name.parts
        base = if type_ref.arguments.any?
                 name = parts.join(".")
                 args = type_ref.arguments.map { |argument| resolve_type_argument(argument.value, type_params:) }
                 if name != "ref" && args.any? { |argument| contains_ref_type?(argument) }
                   raise LoweringError, "ref types cannot be nested inside #{name}"
                 end
                 if name == "Result"
                   validate_generic_type!(name, args)
                   Types::Result.new(args.fetch(0), args.fetch(1))
                 elsif name == "Task"
                   validate_generic_type!(name, args)
                   Types::Task.new(args.fetch(0))
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
                 type = @types[parts.first]
                 raise LoweringError, "unknown type #{parts.first}" unless type
                 raise LoweringError, "generic type #{parts.first} requires type arguments" if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

                 type
               elsif parts.length == 2 && @imports.key?(parts.first)
                 imported_module = @imports.fetch(parts.first)
                 if imported_module.private_type?(parts.last)
                   raise LoweringError, "#{parts.first}.#{parts.last} is private to module #{imported_module.name}"
                 end

                 type = imported_module.types[parts.last]
                 raise LoweringError, "unknown type #{type_ref.name}" unless type
                 raise LoweringError, "generic type #{type_ref.name} requires type arguments" if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

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
          {
            type: binding.type,
            storage_type: binding.storage_type,
            c_name: value_c_name(name),
            mutable: binding.mutable,
            pointer: false,
            cstr_backed: cstr_trackable_type?(binding.type) && binding.const_value.is_a?(String),
            cstr_list_backed: false,
            const_value: binding.const_value,
          }
        end
      end

      def lower_static_storage_initializer(expression, env:, expected_type: nil)
        lower_expression(rewrite_static_storage_initializer(expression), env:, expected_type: expected_type)
      end

      def rewrite_static_storage_initializer(expression)
        case expression
        when AST::Identifier
          binding = @values[expression.name]
          if binding&.kind == :const
            declaration = const_declaration_for(analysis_for_module(@module_name), expression.name)
            return rewrite_static_storage_initializer(declaration.value)
          end

          expression
        when AST::MemberAccess
          if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
            imported_module = @imports.fetch(expression.receiver.name)
            if (binding = imported_module.values[expression.member])&.kind == :const
              imported_analysis = analysis_for_module(imported_module.name)
              declaration = const_declaration_for(imported_analysis, expression.member)
              return with_analysis_context(imported_analysis) do
                rewrite_static_storage_initializer(declaration.value)
              end
            end
          end

          AST::MemberAccess.new(
            receiver: rewrite_static_storage_initializer(expression.receiver),
            member: expression.member,
          )
        when AST::UnaryOp
          AST::UnaryOp.new(operator: expression.operator, operand: rewrite_static_storage_initializer(expression.operand))
        when AST::BinaryOp
          AST::BinaryOp.new(
            operator: expression.operator,
            left: rewrite_static_storage_initializer(expression.left),
            right: rewrite_static_storage_initializer(expression.right),
          )
        when AST::IfExpr
          AST::IfExpr.new(
            condition: rewrite_static_storage_initializer(expression.condition),
            then_expression: rewrite_static_storage_initializer(expression.then_expression),
            else_expression: rewrite_static_storage_initializer(expression.else_expression),
          )
        when AST::Call
          AST::Call.new(
            callee: rewrite_static_storage_initializer(expression.callee),
            arguments: expression.arguments.map do |argument|
              AST::Argument.new(name: argument.name, value: rewrite_static_storage_initializer(argument.value))
            end,
          )
        when AST::Specialization
          AST::Specialization.new(
            callee: rewrite_static_storage_initializer(expression.callee),
            arguments: expression.arguments.map { |argument| AST::TypeArgument.new(value: argument.value) },
          )
        else
          expression
        end
      end

      def const_declaration_for(analysis, name)
        declaration = analysis.ast.declarations.find { |decl| decl.is_a?(AST::ConstDecl) && decl.name == name }
        raise LoweringError, "unknown constant #{analysis.module_name}.#{name}" unless declaration

        declaration
      end

      def local_binding(type:, c_name:, mutable:, pointer:, storage_type: nil, cstr_backed: false, cstr_list_backed: false)
        { type:, storage_type: storage_type || type, c_name:, mutable:, pointer:, cstr_backed:, cstr_list_backed: }
      end

      def callable_type?(type)
        type.is_a?(Types::Function) || proc_type?(type)
      end

      def proc_type?(type)
        type.is_a?(Types::Proc)
      end

      def contains_proc_storage_type?(type)
        case type
        when Types::Proc
          true
        when Types::Struct, Types::StructInstance
          type.fields.each_value.any? { |field_type| contains_proc_storage_type?(field_type) }
        when Types::Nullable
          contains_proc_storage_type?(type.base)
        else
          false
        end
      end

      def proc_env_pointer_type
        @proc_env_pointer_type ||= pointer_to(@types.fetch("void"))
      end

      def proc_invoke_function_type(proc_type)
        Types::Function.new(
          nil,
          params: [Types::Parameter.new("env", proc_env_pointer_type), *proc_type.params],
          return_type: proc_type.return_type,
        )
      end

      def proc_release_function_type
        @proc_release_function_type ||= Types::Function.new(
          nil,
          params: [Types::Parameter.new("env", proc_env_pointer_type)],
          return_type: @types.fetch("void"),
        )
      end

      def proc_retain_function_type
        @proc_retain_function_type ||= Types::Function.new(
          nil,
          params: [Types::Parameter.new("env", proc_env_pointer_type)],
          return_type: @types.fetch("void"),
        )
      end

      def fresh_proc_symbol
        @synthetic_proc_counter += 1
      end

      def fresh_format_symbol
        @synthetic_format_counter += 1
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

      def cfg_block_always_terminates?(statements)
        CFG::Termination.block_always_terminates?(statements, ignore_name: ->(_name) { false })
      end

      def conditional_common_type(then_type, else_type)
        return then_type if then_type == else_type

        numeric_type = common_numeric_type(then_type, else_type)
        return numeric_type if numeric_type

        if (nullable_type = conditional_null_common_type(then_type, else_type))
          return nullable_type
        end

        if (nullable_type = conditional_null_common_type(else_type, then_type))
          return nullable_type
        end

        return then_type if then_type.is_a?(Types::Nullable) && else_type == then_type.base
        return else_type if else_type.is_a?(Types::Nullable) && then_type == else_type.base

        nil
      end

      def if_expression_branch_compatible?(actual_type, expected_type)
        return true if actual_type == expected_type
        return true if null_assignable_to?(actual_type, expected_type)
        return true if expected_type.is_a?(Types::Nullable) && actual_type == expected_type.base
        return true if common_numeric_type(actual_type, expected_type) == expected_type

        false
      end

      def nullable_candidate?(type)
        !ref_type?(type) && type != @types.fetch("void")
      end

      def null_assignable_to?(actual_type, expected_type)
        return false unless actual_type.is_a?(Types::Null)
        return false unless expected_type.is_a?(Types::Nullable)
        return true unless actual_type.target_type

        actual_type.target_type == expected_type.base
      end

      def conditional_null_common_type(null_type, other_type)
        return unless null_type.is_a?(Types::Null)

        if other_type.is_a?(Types::Nullable)
          return other_type if null_type.target_type.nil? || null_type.target_type == other_type.base

          return nil
        end

        return unless nullable_candidate?(other_type)
        return if null_type.target_type && null_type.target_type != other_type

        Types::Nullable.new(other_type)
      end

      def null_type
        @null_type ||= Types::Null.new
      end

      def loop_flow(break_target:, continue_target:, break_defers: [], continue_defers: [])
        {
          break_target:,
          continue_target:,
          break_defers:,
          continue_defers:,
        }
      end

      def nested_loop_flow(current_loop_flow, local_defers)
        return nil unless current_loop_flow

        loop_flow(
          break_target: current_loop_flow[:break_target],
          continue_target: current_loop_flow[:continue_target],
          break_defers: current_loop_flow[:break_defers] + local_defers,
          continue_defers: current_loop_flow[:continue_defers] + local_defers,
        )
      end

      def cleanup_statements(local_defers, outer_defers)
        local_defers.reverse.flat_map(&:itself) + outer_defers.reverse.flat_map(&:itself)
      end

      def loop_exit_break(label = nil)
        { kind: :break, label: }
      end

      def loop_exit_continue(label = nil)
        { kind: :continue, label: }
      end

      def loop_exit_label(label)
        { kind: :label, label: }
      end

      def loop_exit_statement(target, local_defers:, outer_defers:)
        case target[:kind]
        when :break
          IR::BreakStmt.new
        when :continue
          IR::ContinueStmt.new
        when :label
          IR::GotoStmt.new(label: target[:label])
        else
          raise LoweringError, "unsupported loop exit target #{target.inspect}"
        end
      end

      def lower_loop_exit(target, local_defers, outer_defers)
        cleanup = cleanup_statements(local_defers, outer_defers)
        if cleanup.empty?
          [loop_exit_statement(target, local_defers:, outer_defers:)]
        else
          label = target[:label]
          raise LoweringError, "structured loop exits with cleanup are unsupported" unless label

          cleanup + [IR::GotoStmt.new(label:)]
        end
      end

      def contains_label_target?(statements, label)
        statements.any? do |statement|
          case statement
          when IR::GotoStmt
            statement.label == label
          when IR::BlockStmt, IR::WhileStmt, IR::ForStmt
            contains_label_target?(statement.body, label)
          when IR::IfStmt
            contains_label_target?(statement.then_body, label) || (statement.else_body && contains_label_target?(statement.else_body, label))
          when IR::SwitchStmt
            statement.cases.any? { |switch_case| contains_label_target?(switch_case.body, label) }
          else
            false
          end
        end
      end

      def lower_defer_cleanup_expression(expression, env:)
        [IR::ExpressionStmt.new(expression: lower_expression(expression, env:))]
      end

      def lower_defer_cleanup_body(statements, env:, return_type:)
        lower_block(statements, env:, active_defers: [], return_type:, loop_flow: nil, allow_return: false)
      end

      def terminating_ir_statement?(statement)
        statement.is_a?(IR::ReturnStmt) || statement.is_a?(IR::GotoStmt)
      end

      def empty_env
        { scopes: [{}], counter: { value: 0 } }
      end

      def duplicate_env(env)
        { scopes: env[:scopes].map(&:dup) + [{}], counter: env[:counter] }
      end

      def c_type_name(type)
        return type.name if type.module_name&.start_with?("std.c.")
        return type.name if type.module_name.nil?

        base = "#{type.module_name.tr('.', '_')}_#{type.name}"
        return base unless type.is_a?(Types::StructInstance) || type.is_a?(Types::VariantInstance)

        "#{base}_#{sanitize_identifier(type.arguments.join('_'))}"
      end

      def opaque_c_type_name(type)
        type.c_name || c_type_name(type)
      end

      def opaque_forward_declarable?(type)
        return false unless opaque_c_type_name(type).match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        !type.external || type.c_name.nil?
      end

      def forward_declarable_external_opaque?(type)
        type.external && opaque_forward_declarable?(type)
      end

      def resolve_named_generic_type(parts)
        if parts.length == 1
          type = @types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        elsif parts.length == 2 && @imports.key?(parts.first)
          type = @imports.fetch(parts.first).types[parts.last]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
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
        when "const_ptr"
          raise LoweringError, "const_ptr requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "const_ptr type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "const_ptr cannot target ref types" if contains_ref_type?(arguments.first)
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
          raise LoweringError, "array length must be an integer literal, named const, or type parameter" unless generic_integer_type_argument?(arguments[1])
          raise LoweringError, "array length must be positive" if integer_type_argument?(arguments[1]) && !arguments[1].value.positive?
        when "str_builder"
          raise LoweringError, "str_builder requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "str_builder capacity must be an integer literal, named const, or type parameter" unless generic_integer_type_argument?(arguments.first)
          raise LoweringError, "str_builder capacity must be positive" if integer_type_argument?(arguments.first) && !arguments.first.value.positive?
        when "Result"
          raise LoweringError, "Result requires exactly two type arguments" unless arguments.length == 2
          raise LoweringError, "Result ok type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise LoweringError, "Result error type must be a type" if arguments[1].is_a?(Types::LiteralTypeArg)
        when "Task"
          raise LoweringError, "Task requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "Task result type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        else
          raise LoweringError, "unknown generic type #{name}"
        end
      end

      def integer_type_argument?(argument)
        argument.is_a?(Types::LiteralTypeArg) && argument.value.is_a?(Integer)
      end

      def generic_integer_type_argument?(argument)
        integer_type_argument?(argument) || argument.is_a?(Types::TypeVar)
      end

      def enum_member_c_name(type, member_name)
        "#{c_type_name(type)}_#{member_name}"
      end

      def local_named_type?(type)
        type.respond_to?(:module_name) && (type.module_name == @module_name || type.module_name.nil?)
      end

      def function_binding_c_name(binding, module_name:, receiver_type: nil)
        if receiver_type.nil? && binding.name == "main" && binding.type_arguments.empty?
          return binding.async ? module_function_c_name(module_name, "__async_main") : "main"
        end
        if receiver_type
          base = "#{c_type_name(receiver_type)}_#{binding.name}"
          return binding.type_arguments.empty? ? base : "#{base}_#{sanitize_identifier(binding.type_arguments.join('_'))}"
        end

        module_function_c_name(module_name, binding.name, type_arguments: binding.type_arguments)
      end

      def value_c_name(name)
        module_value_c_name(@module_name, name)
      end

      def imported_value_c_name(imported_module, name)
        imported_analysis = analysis_for_module(imported_module.name)
        return name if imported_analysis.module_kind == :extern_module

        module_value_c_name(imported_module.name, name)
      end

      def module_function_c_name(module_name, name, type_arguments: [])
        base = "#{module_name.tr('.', '_')}_#{name}"
        return base if type_arguments.empty?

        "#{base}_#{sanitize_identifier(type_arguments.join('_'))}"
      end

      def module_value_c_name(module_name, name)
        "#{module_name.tr('.', '_')}_#{name}"
      end

      def c_local_name(name)
        identifier = sanitize_identifier(name)
        return "#{identifier}_" if c_reserved_identifier?(identifier)

        identifier
      end

      def c_reserved_identifier?(identifier)
        %w[
          auto break case char const continue default do double else enum extern
          float for goto if inline int long register restrict return short signed
          sizeof static struct switch typedef union unsigned void volatile while
          _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn
          _Static_assert _Thread_local
        ].include?(identifier)
      end

      def fresh_c_temp_name(env, prefix)
        env[:counter][:value] += 1
        "__mt_#{prefix}_#{env[:counter][:value]}"
      end

      def cleanup_safe_return_expression?(expression)
        case expression
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral
          true
        else
          false
        end
      end

      def sanitize_identifier(text)
        identifier = text.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/_+/, "_").sub(/^_+/, "").sub(/_+$/, "")
        identifier.empty? ? "value" : identifier
      end
    end
  end
end
