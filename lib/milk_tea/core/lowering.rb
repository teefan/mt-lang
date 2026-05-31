# frozen_string_literal: true

module MilkTea
  class LoweringError < StandardError; end

  class Lowering
    def self.lower(program)
      Lowerer.new(program).lower
    end

    class Lowerer
      include TypeCompatibilityPredicates

      ExplicitDefaultBinding = Data.define(:binding, :callee_name)
      ExplicitHashBinding = Data.define(:binding, :callee_name)
      ExplicitEqualBinding = Data.define(:binding, :callee_name)
      ExplicitOrderBinding = Data.define(:binding, :callee_name)
      ExplicitFormatBinding = Data.define(:length_binding, :length_callee_name, :append_binding, :append_callee_name)
      DefaultResolution = Data.define(:target_type, :binding, :callee_name)
      HashResolution = Data.define(:target_type, :binding, :callee_name)
      EqualResolution = Data.define(:target_type, :binding, :callee_name)
      OrderResolution = Data.define(:target_type, :binding, :callee_name)

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
        @synthetic_structs = []
        @synthetic_enums = []
        @synthetic_functions = []
        @synthetic_proc_counter = 0
        @event_runtime_infos = {}
        @multiplayer_typed_rpc_dispatch_helpers = {}
        @subscription_runtime_emitted = false
        @event_error_enum_emitted = false
        @lowered_function_c_names = {}
        @method_definitions = build_method_definitions
      end

      def lower
        if @program.root_analysis.module_kind == :raw_module
          raise LoweringError, "cannot emit C for external file #{@program.root_analysis.module_name}"
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
          next if analysis.module_kind == :raw_module

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

        pending_functions = true
        while pending_functions
          pending_functions = false

          @program.analyses_by_path.each_pair do |path, analysis|
            next if analysis.module_kind == :raw_module

            prepare_analysis(analysis, source_path: path)
            newly_lowered = lower_functions
            next if newly_lowered.empty?

            functions.concat(newly_lowered)
            pending_functions = true
          end
        end

        opaques.concat(lower_imported_external_opaques)
        structs.concat(@synthetic_structs)
        enums.concat(@synthetic_enums)
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
          end
        end
      end

      def collect_includes
        headers = ["<stdbool.h>", "<stdint.h>", "<stdlib.h>", "<string.h>"]
        headers << "<stddef.h>" if program_uses_offsetof?
        if program_uses_fatal?
          headers << "<stdio.h>"
        end

        @program.analyses_by_module_name.each_value do |analysis|
          next unless analysis.module_kind == :raw_module

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
        @program.analyses_by_module_name.each_value.any? do |analysis|
          next false if analysis.module_kind == :raw_module

          analysis_uses_fatal?(analysis)
        end
      end

      def program_uses_offsetof?
        @program.analyses_by_module_name.each_value.any? do |analysis|
          next false if analysis.module_kind == :raw_module

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

      def expression_uses_fatal?(expression)
        expression_uses_pattern?(expression) { |candidate| fatal_expression?(candidate) }
      end

      def expression_uses_offsetof?(expression)
        expression_uses_pattern?(expression) { |candidate| offsetof_expression?(candidate) }
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
        @analysis = analysis
        @current_analysis_path = source_path
        @module_name = analysis.module_name
        @module_prefix = module_c_prefix(@module_name)
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
          analysis.ast.declarations.grep(AST::ExtendingBlock).each do |extending_block|
            receiver_type = resolve_extending_receiver_type(analysis, extending_block.type_name)
            extending_block.methods.each do |method|
              definitions[[receiver_type, method.name]] = [analysis, method]
            end
          end
        end
      end

      def lower_constants
        @analysis.ast.declarations.grep(AST::ConstDecl).map do |decl|
          type = @values.fetch(decl.name).type
          value = lower_static_storage_initializer(decl.value, env: empty_env, expected_type: type)
          IR::Constant.new(name: decl.name, c_name: value_c_name(decl.name), type:, value:)
        end
      end

      def lower_globals
        @analysis.ast.declarations.filter_map do |decl|
          next unless decl.is_a?(AST::VarDecl) || decl.is_a?(AST::EventDecl)

          type = @values.fetch(decl.name).type
          ensure_event_runtime(type) if type.is_a?(Types::Event)
          value = if decl.is_a?(AST::VarDecl) && decl.value
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
          next [] unless analysis.module_kind == :raw_module

          analysis.ast.declarations.grep(AST::OpaqueDecl).filter_map do |decl|
            opaque_type = analysis.types.fetch(decl.name)
            next unless forward_declarable_external_opaque?(opaque_type)

            IR::OpaqueDecl.new(name: decl.name, c_name: opaque_c_type_name(opaque_type), forward_declarable: true)
          end
        end.uniq { |decl| decl.c_name }
      end

      def lower_static_asserts
        @analysis.ast.declarations.grep(AST::StaticAssert).map do |statement|
          lower_static_assert(statement, env: empty_env)
        end
      end

      def lower_static_assert(statement, env:)
        condition_value = compile_time_const_value(statement.condition, env:)
        raise LoweringError, "static_assert condition must lower to a compile-time bool constant" unless condition_value == true || condition_value == false

        IR::StaticAssert.new(
          condition: IR::BooleanLiteral.new(value: condition_value, type: @types.fetch("bool")),
          message: lower_expression(statement.message, env:, expected_type: @types.fetch("str")),
        )
      end

      def lower_structs
        @analysis.ast.declarations.grep(AST::StructDecl).filter_map do |decl|
          next unless decl.type_params.empty?

          struct_type = @struct_types.fetch(decl.name)
          fields = decl.fields.map do |field|
            IR::Field.new(name: field.name, type: struct_type.field(field.name))
          end
          decl.events.each do |event_decl|
            event_type = struct_type.event(event_decl.name)
            ensure_event_runtime(event_type)
            fields << IR::Field.new(name: event_type.hidden_field_name, type: event_type)
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

      def event_method_kind(receiver_type, member_name)
        return unless receiver_type.is_a?(Types::Event)

        case member_name
        when "subscribe"
          :event_subscribe
        when "subscribe_once"
          :event_subscribe_once
        when "unsubscribe"
          :event_unsubscribe
        when "emit"
          :event_emit
        when "wait"
          :event_wait
        end
      end

      def event_method_type(kind, event_type)
        case kind
        when :event_subscribe, :event_subscribe_once
          Types::Function.new(
            kind.to_s,
            params: [Types::Parameter.new("listener", event_listener_function_type(event_type))],
            return_type: event_subscription_result_type,
          )
        when :event_subscribe_stateful, :event_subscribe_once_stateful
          Types::Function.new(
            kind.to_s,
            params: [
              Types::Parameter.new("state", pointer_to(@types.fetch("void"))),
              Types::Parameter.new("listener", event_stateful_listener_function_type(event_type)),
            ],
            return_type: event_subscription_result_type,
          )
        when :event_unsubscribe
          Types::Function.new(
            kind.to_s,
            params: [Types::Parameter.new("subscription", @types.fetch("Subscription"))],
            return_type: @types.fetch("bool"),
          )
        when :event_emit
          params = []
          params << Types::Parameter.new("payload", event_type.payload_type) if event_type.payload_type
          Types::Function.new(kind.to_s, params:, return_type: @types.fetch("void"))
        when :event_wait
          Types::Function.new(kind.to_s, params: [], return_type: Types::Task.new(event_wait_result_type(event_type)))
        else
          raise LoweringError, "unsupported event method #{kind}"
        end
      end

      def event_member_from_owner_type(receiver_type, member_name)
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

        return unless owner_type.respond_to?(:event)

        owner_type.event(member_name)
      end

      def lower_event_storage_pointer(expression, env:)
        event_type = infer_expression_type(expression, env:)
        IR::AddressOf.new(
          expression: lower_expression(expression, env:, expected_type: event_type),
          type: pointer_to(event_type),
        )
      end

      def event_listener_function_type(event_type)
        params = []
        params << Types::Parameter.new("payload", event_type.payload_type) if event_type.payload_type
        Types::Function.new("#{event_type.name}__listener", params:, return_type: @types.fetch("void"))
      end

      def event_stateful_listener_function_type(event_type)
        params = [Types::Parameter.new("state", pointer_to(@types.fetch("void")))]
        params << Types::Parameter.new("payload", event_type.payload_type) if event_type.payload_type
        Types::Function.new("#{event_type.name}__stateful_listener", params:, return_type: @types.fetch("void"))
      end

      def event_subscription_result_type
        @types.fetch("Result").instantiate([@types.fetch("Subscription"), @types.fetch("EventError")])
      end

      def event_wait_result_type(event_type)
        @types.fetch("Result").instantiate([event_type.payload_type || @types.fetch("void"), @types.fetch("EventError")])
      end

      def array_of(type, length)
        Types::GenericInstance.new("array", [type, Types::LiteralTypeArg.new(length)])
      end

      def ensure_subscription_runtime
        return if @subscription_runtime_emitted

        subscription_type = @types.fetch("Subscription")
        @synthetic_structs << IR::StructDecl.new(
          name: subscription_type.name,
          c_name: subscription_type.c_name,
          fields: [
            IR::Field.new(name: "slot", type: @types.fetch("ptr_uint")),
            IR::Field.new(name: "generation", type: @types.fetch("ptr_uint")),
          ],
          packed: false,
          alignment: nil,
        )
        @subscription_runtime_emitted = true
      end

      def ensure_event_error_enum
        return if @event_error_enum_emitted

        event_error_type = @types.fetch("EventError")
        @synthetic_enums << IR::EnumDecl.new(
          name: event_error_type.name,
          c_name: c_type_name(event_error_type),
          backing_type: event_error_type.backing_type,
          members: [
            IR::EnumMember.new(
              name: "full",
              c_name: enum_member_c_name(event_error_type, "full"),
              value: IR::IntegerLiteral.new(value: 0, type: event_error_type.backing_type),
            ),
          ],
          flags: false,
        )
        @event_error_enum_emitted = true
      end

      def ensure_event_runtime(event_type)
        return @event_runtime_infos.fetch(event_type) if @event_runtime_infos.key?(event_type)

        ensure_subscription_runtime
        ensure_event_error_enum

        void_ptr = pointer_to(@types.fetch("void"))
        listener_type = event_listener_function_type(event_type)
        subscription_result_type = event_subscription_result_type
        wait_result_type = event_wait_result_type(event_type)
        task_type = Types::Task.new(wait_result_type)
        wake_type = task_type.field("ready").params.fetch(0).type == void_ptr ? task_type.field("set_waiter").params.fetch(2).type : Types::Function.new(nil, params: [Types::Parameter.new("frame", void_ptr)], return_type: @types.fetch("void"))
        slot_type = Types::Struct.new("#{event_type.c_name}__slot").define_fields(
          "active" => @types.fetch("bool"),
          "once" => @types.fetch("bool"),
          "generation" => @types.fetch("ptr_uint"),
          "state" => void_ptr,
          "listener" => void_ptr,
          "wait_frame" => void_ptr,
        )
        snapshot_type = Types::Struct.new("#{event_type.c_name}__snapshot").define_fields(
          "slot" => @types.fetch("ptr_uint"),
          "generation" => @types.fetch("ptr_uint"),
          "once" => @types.fetch("bool"),
          "wait_slot" => @types.fetch("bool"),
          "stateful" => @types.fetch("bool"),
          "state" => void_ptr,
          "listener" => void_ptr,
        )
        wait_frame_type = Types::Struct.new("#{event_type.c_name}__wait_frame").define_fields(
          "ready" => @types.fetch("bool"),
          "waiter_frame" => void_ptr,
          "waiter" => wake_type,
          "event" => void_ptr,
          "subscription" => @types.fetch("Subscription"),
          "result" => wait_result_type,
        )
        slots_type = array_of(slot_type, event_type.capacity)
        snapshots_type = array_of(snapshot_type, event_type.capacity)

        @synthetic_structs << IR::StructDecl.new(
          name: slot_type.name,
          c_name: slot_type.name,
          fields: [
            IR::Field.new(name: "active", type: @types.fetch("bool")),
            IR::Field.new(name: "once", type: @types.fetch("bool")),
            IR::Field.new(name: "generation", type: @types.fetch("ptr_uint")),
            IR::Field.new(name: "state", type: void_ptr),
            IR::Field.new(name: "listener", type: void_ptr),
            IR::Field.new(name: "wait_frame", type: void_ptr),
          ],
          packed: false,
          alignment: nil,
        )
        @synthetic_structs << IR::StructDecl.new(
          name: snapshot_type.name,
          c_name: snapshot_type.name,
          fields: [
            IR::Field.new(name: "slot", type: @types.fetch("ptr_uint")),
            IR::Field.new(name: "generation", type: @types.fetch("ptr_uint")),
            IR::Field.new(name: "once", type: @types.fetch("bool")),
            IR::Field.new(name: "wait_slot", type: @types.fetch("bool")),
            IR::Field.new(name: "stateful", type: @types.fetch("bool")),
            IR::Field.new(name: "state", type: void_ptr),
            IR::Field.new(name: "listener", type: void_ptr),
          ],
          packed: false,
          alignment: nil,
        )
        @synthetic_structs << IR::StructDecl.new(
          name: wait_frame_type.name,
          c_name: wait_frame_type.name,
          fields: [
            IR::Field.new(name: "ready", type: @types.fetch("bool")),
            IR::Field.new(name: "waiter_frame", type: void_ptr),
            IR::Field.new(name: "waiter", type: wake_type),
            IR::Field.new(name: "event", type: void_ptr),
            IR::Field.new(name: "subscription", type: @types.fetch("Subscription")),
            IR::Field.new(name: "result", type: wait_result_type),
          ],
          packed: false,
          alignment: nil,
        )
        @synthetic_structs << IR::StructDecl.new(
          name: event_type.name,
          c_name: event_type.c_name,
          fields: [IR::Field.new(name: "slots", type: slots_type)],
          packed: false,
          alignment: nil,
        )

        runtime = {
          event_type:,
          event_pointer_type: pointer_to(event_type),
          listener_type:,
          slot_type:,
          slot_pointer_type: pointer_to(slot_type),
          slots_type:,
          snapshot_type:,
          snapshots_type:,
          wait_frame_type:,
          wait_frame_pointer_type: pointer_to(wait_frame_type),
          void_ptr:,
          wake_type:,
          subscription_result_type:,
          wait_result_type:,
          task_type:,
          subscribe_c_name: "#{event_type.c_name}__subscribe",
          subscribe_once_c_name: "#{event_type.c_name}__subscribe_once",
          subscribe_stateful_c_name: "#{event_type.c_name}__subscribe_stateful",
          subscribe_once_stateful_c_name: "#{event_type.c_name}__subscribe_once_stateful",
          unsubscribe_c_name: "#{event_type.c_name}__unsubscribe",
          emit_c_name: "#{event_type.c_name}__emit",
          wait_c_name: "#{event_type.c_name}__wait",
          wait_ready_c_name: "#{event_type.c_name}__wait__ready",
          wait_set_waiter_c_name: "#{event_type.c_name}__wait__set_waiter",
          wait_release_c_name: "#{event_type.c_name}__wait__release",
          wait_take_result_c_name: "#{event_type.c_name}__wait__take_result",
        }

        @synthetic_functions << build_event_subscribe_function(runtime, once: false)
        @synthetic_functions << build_event_subscribe_function(runtime, once: true)
        @synthetic_functions << build_event_subscribe_stateful_function(runtime, once: false)
        @synthetic_functions << build_event_subscribe_stateful_function(runtime, once: true)
        @synthetic_functions << build_event_unsubscribe_function(runtime)
        @synthetic_functions << build_event_emit_function(runtime)
        @synthetic_functions << build_event_wait_ready_function(runtime)
        @synthetic_functions << build_event_wait_set_waiter_function(runtime)
        @synthetic_functions << build_event_wait_release_function(runtime)
        @synthetic_functions << build_event_wait_take_result_function(runtime)
        @synthetic_functions << build_event_wait_function(runtime)

        @event_runtime_infos[event_type] = runtime
      end

      def build_event_subscribe_function(runtime, once:)
        event_expr = IR::Name.new(name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)
        listener_expr = IR::Name.new(name: "listener", type: runtime.fetch(:listener_type), pointer: false)
        slot_index_expr = IR::Name.new(name: "__mt_slot_index", type: @types.fetch("ptr_uint"), pointer: false)
        generation_expr = IR::Name.new(name: "__mt_generation", type: @types.fetch("ptr_uint"), pointer: false)
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)

        body = [
          IR::ForStmt.new(
            init: IR::LocalDecl.new(
              name: "__mt_slot_index",
              c_name: "__mt_slot_index",
              type: @types.fetch("ptr_uint"),
              value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")),
            ),
            condition: IR::Binary.new(
              operator: "<",
              left: slot_index_expr,
              right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @types.fetch("ptr_uint")),
              type: @types.fetch("bool"),
            ),
            post: IR::Assignment.new(target: slot_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            body: [
              event_slot_local_decl(event_expr, slot_index_expr, runtime),
              active_event_slot_continue_guard(slot_pointer_expr),
              IR::LocalDecl.new(
                name: "__mt_generation",
                c_name: "__mt_generation",
                type: @types.fetch("ptr_uint"),
                value: event_next_generation_expression(slot_pointer_expr),
              ),
              *event_slot_activate_statements(
                slot_pointer_expr,
                runtime,
                generation_expr: generation_expr,
                once: once,
                wait_frame_expr: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                listener_expr: IR::Cast.new(target_type: runtime.fetch(:void_ptr), expression: listener_expr, type: runtime.fetch(:void_ptr)),
              ),
              IR::ReturnStmt.new(value: event_subscription_success_literal(runtime.fetch(:subscription_result_type), slot_index_expr, generation_expr)),
            ],
          ),
          IR::ReturnStmt.new(value: event_failure_literal(runtime.fetch(:subscription_result_type))),
        ]

        IR::Function.new(
          name: once ? "#{runtime.fetch(:subscribe_once_c_name)}_fn" : "#{runtime.fetch(:subscribe_c_name)}_fn",
          c_name: once ? runtime.fetch(:subscribe_once_c_name) : runtime.fetch(:subscribe_c_name),
          params: [
            IR::Param.new(name: "event", c_name: "event", type: runtime.fetch(:event_pointer_type), pointer: false),
            IR::Param.new(name: "listener", c_name: "listener", type: runtime.fetch(:listener_type), pointer: false),
          ],
          return_type: runtime.fetch(:subscription_result_type),
          body:,
          entry_point: false,
        )
      end

      def build_event_subscribe_stateful_function(runtime, once:)
        event_expr = IR::Name.new(name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)
        state_expr = IR::Name.new(name: "state", type: runtime.fetch(:void_ptr), pointer: false)
        listener_expr = IR::Name.new(name: "listener", type: runtime.fetch(:listener_type), pointer: false)
        slot_index_expr = IR::Name.new(name: "__mt_slot_index", type: @types.fetch("ptr_uint"), pointer: false)
        generation_expr = IR::Name.new(name: "__mt_generation", type: @types.fetch("ptr_uint"), pointer: false)
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)

        body = [
          IR::ForStmt.new(
            init: IR::LocalDecl.new(
              name: "__mt_slot_index",
              c_name: "__mt_slot_index",
              type: @types.fetch("ptr_uint"),
              value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")),
            ),
            condition: IR::Binary.new(
              operator: "<",
              left: slot_index_expr,
              right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @types.fetch("ptr_uint")),
              type: @types.fetch("bool"),
            ),
            post: IR::Assignment.new(target: slot_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            body: [
              event_slot_local_decl(event_expr, slot_index_expr, runtime),
              active_event_slot_continue_guard(slot_pointer_expr),
              IR::LocalDecl.new(
                name: "__mt_generation",
                c_name: "__mt_generation",
                type: @types.fetch("ptr_uint"),
                value: event_next_generation_expression(slot_pointer_expr),
              ),
              *event_slot_activate_stateful_statements(
                slot_pointer_expr,
                runtime,
                generation_expr: generation_expr,
                once: once,
                state_expr: state_expr,
                wait_frame_expr: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                listener_expr: IR::Cast.new(target_type: runtime.fetch(:void_ptr), expression: listener_expr, type: runtime.fetch(:void_ptr)),
              ),
              IR::ReturnStmt.new(value: event_subscription_success_literal(runtime.fetch(:subscription_result_type), slot_index_expr, generation_expr)),
            ],
          ),
          IR::ReturnStmt.new(value: event_failure_literal(runtime.fetch(:subscription_result_type))),
        ]

        c_name = once ? runtime.fetch(:subscribe_once_stateful_c_name) : runtime.fetch(:subscribe_stateful_c_name)
        IR::Function.new(
          name: "#{c_name}_fn",
          c_name:,
          params: [
            IR::Param.new(name: "event", c_name: "event", type: runtime.fetch(:event_pointer_type), pointer: false),
            IR::Param.new(name: "state", c_name: "state", type: runtime.fetch(:void_ptr), pointer: false),
            IR::Param.new(name: "listener", c_name: "listener", type: runtime.fetch(:void_ptr), pointer: false),
          ],
          return_type: runtime.fetch(:subscription_result_type),
          body:,
          entry_point: false,
        )
      end

      def build_event_unsubscribe_function(runtime)
        event_expr = IR::Name.new(name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)
        subscription_expr = IR::Name.new(name: "subscription", type: @types.fetch("Subscription"), pointer: false)
        slot_index_expr = subscription_field_expression(subscription_expr, "slot", @types.fetch("ptr_uint"))
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)

        false_value = IR::BooleanLiteral.new(value: false, type: @types.fetch("bool"))
        true_value = IR::BooleanLiteral.new(value: true, type: @types.fetch("bool"))
        body = [
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: ">=",
              left: slot_index_expr,
              right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @types.fetch("ptr_uint")),
              type: @types.fetch("bool"),
            ),
            then_body: [IR::ReturnStmt.new(value: false_value)],
            else_body: nil,
          ),
          IR::LocalDecl.new(
            name: "__mt_slot",
            c_name: "__mt_slot",
            type: runtime.fetch(:slot_pointer_type),
            value: event_slot_pointer_expression(event_expr, slot_index_expr, runtime),
          ),
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: event_slot_active_expression(slot_pointer_expr), type: @types.fetch("bool")),
            then_body: [IR::ReturnStmt.new(value: false_value)],
            else_body: nil,
          ),
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: "!=",
              left: event_slot_field_expression(slot_pointer_expr, "generation", @types.fetch("ptr_uint")),
              right: subscription_field_expression(subscription_expr, "generation", @types.fetch("ptr_uint")),
              type: @types.fetch("bool"),
            ),
            then_body: [IR::ReturnStmt.new(value: false_value)],
            else_body: nil,
          ),
          *event_slot_clear_statements(slot_pointer_expr, runtime),
          IR::ReturnStmt.new(value: true_value),
        ]

        IR::Function.new(
          name: "#{runtime.fetch(:unsubscribe_c_name)}_fn",
          c_name: runtime.fetch(:unsubscribe_c_name),
          params: [
            IR::Param.new(name: "event", c_name: "event", type: runtime.fetch(:event_pointer_type), pointer: false),
            IR::Param.new(name: "subscription", c_name: "subscription", type: @types.fetch("Subscription"), pointer: false),
          ],
          return_type: @types.fetch("void"),
          body:,
          entry_point: false,
        )
      end

      def build_event_emit_function(runtime)
        event_expr = IR::Name.new(name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)
        payload_expr = runtime.fetch(:event_type).payload_type ? IR::Name.new(name: "payload", type: runtime.fetch(:event_type).payload_type, pointer: false) : nil
        snapshots_expr = IR::Name.new(name: "__mt_snapshots", type: runtime.fetch(:snapshots_type), pointer: false)
        snapshot_count_expr = IR::Name.new(name: "__mt_snapshot_count", type: @types.fetch("ptr_uint"), pointer: false)
        slot_index_expr = IR::Name.new(name: "__mt_slot_index", type: @types.fetch("ptr_uint"), pointer: false)
        dispatch_index_expr = IR::Name.new(name: "__mt_dispatch_index", type: @types.fetch("ptr_uint"), pointer: false)
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)
        frame_pointer_expr = IR::Name.new(name: "__mt_wait_frame", type: runtime.fetch(:wait_frame_pointer_type), pointer: false)

        collect_body = [
          event_slot_local_decl(event_expr, slot_index_expr, runtime),
          inactive_event_slot_continue_guard(slot_pointer_expr),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "slot", @types.fetch("ptr_uint")), operator: "=", value: slot_index_expr),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "generation", @types.fetch("ptr_uint")), operator: "=", value: event_slot_field_expression(slot_pointer_expr, "generation", @types.fetch("ptr_uint"))),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "once", @types.fetch("bool")), operator: "=", value: event_slot_field_expression(slot_pointer_expr, "once", @types.fetch("bool"))),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "wait_slot", @types.fetch("bool")),
            operator: "=",
            value: IR::Binary.new(
              operator: "!=",
              left: event_slot_wait_frame_expression(slot_pointer_expr, runtime),
              right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
              type: @types.fetch("bool"),
            ),
          ),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "stateful", @types.fetch("bool")), operator: "=", value: IR::Binary.new(operator: "!=", left: event_slot_field_expression(slot_pointer_expr, "state", runtime.fetch(:void_ptr)), right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)), type: @types.fetch("bool"))),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "state", runtime.fetch(:void_ptr)), operator: "=", value: event_slot_field_expression(slot_pointer_expr, "state", runtime.fetch(:void_ptr))),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "listener", runtime.fetch(:void_ptr)), operator: "=", value: event_slot_field_expression(slot_pointer_expr, "listener", runtime.fetch(:void_ptr))),
          IR::Assignment.new(target: snapshot_count_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
        ]

        snapshot_subscription_expr = event_subscription_literal(
          snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "slot", @types.fetch("ptr_uint")),
          snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "generation", @types.fetch("ptr_uint")),
        )
        current_slot_active = event_slot_active_expression(slot_pointer_expr)
        current_slot_generation = event_slot_field_expression(slot_pointer_expr, "generation", @types.fetch("ptr_uint"))
        current_wait_frame = event_slot_wait_frame_expression(slot_pointer_expr, runtime)
        wait_slot_condition = IR::Binary.new(
          operator: "and",
          left: current_slot_active,
          right: IR::Binary.new(
            operator: "and",
            left: IR::Binary.new(
              operator: "==",
              left: current_slot_generation,
              right: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "generation", @types.fetch("ptr_uint")),
              type: @types.fetch("bool"),
            ),
            right: IR::Binary.new(
              operator: "!=",
              left: current_wait_frame,
              right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
              type: @types.fetch("bool"),
            ),
            type: @types.fetch("bool"),
          ),
          type: @types.fetch("bool"),
        )

        wait_result_value = event_wait_success_literal(runtime.fetch(:wait_result_type), payload_expr)
        waiter_frame_expr = wait_frame_field_expression(frame_pointer_expr, "waiter_frame", runtime.fetch(:void_ptr))

        dispatch_body = [
          IR::IfStmt.new(
            condition: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "wait_slot", @types.fetch("bool")),
            then_body: [
              IR::LocalDecl.new(
                name: "__mt_slot",
                c_name: "__mt_slot",
                type: runtime.fetch(:slot_pointer_type),
                value: event_slot_pointer_expression(
                  event_expr,
                  snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "slot", @types.fetch("ptr_uint")),
                  runtime,
                ),
              ),
              IR::IfStmt.new(
                condition: wait_slot_condition,
                then_body: [
                  IR::LocalDecl.new(
                    name: "__mt_wait_frame",
                    c_name: "__mt_wait_frame",
                    type: runtime.fetch(:wait_frame_pointer_type),
                    value: IR::Cast.new(target_type: runtime.fetch(:wait_frame_pointer_type), expression: current_wait_frame, type: runtime.fetch(:wait_frame_pointer_type)),
                  ),
                  IR::ExpressionStmt.new(expression: event_unsubscribe_call(runtime, event_expr, snapshot_subscription_expr)),
                  IR::Assignment.new(target: wait_frame_field_expression(frame_pointer_expr, "result", runtime.fetch(:wait_result_type)), operator: "=", value: wait_result_value),
                  IR::Assignment.new(target: wait_frame_field_expression(frame_pointer_expr, "ready", @types.fetch("bool")), operator: "=", value: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool"))),
                  IR::IfStmt.new(
                    condition: IR::Binary.new(
                      operator: "!=",
                      left: waiter_frame_expr,
                      right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                      type: @types.fetch("bool"),
                    ),
                    then_body: [
                      IR::LocalDecl.new(name: "__mt_waiter_frame", c_name: "__mt_waiter_frame", type: runtime.fetch(:void_ptr), value: waiter_frame_expr),
                      IR::Assignment.new(target: waiter_frame_expr, operator: "=", value: IR::NullLiteral.new(type: runtime.fetch(:void_ptr))),
                      IR::ExpressionStmt.new(
                        expression: IR::Call.new(
                          callee: wait_frame_field_expression(frame_pointer_expr, "waiter", runtime.fetch(:wake_type)),
                          arguments: [IR::Name.new(name: "__mt_waiter_frame", type: runtime.fetch(:void_ptr), pointer: false)],
                          type: @types.fetch("void"),
                        ),
                      ),
                    ],
                    else_body: nil,
                  ),
                ],
                else_body: nil,
              ),
            ],
            else_body: [
              IR::IfStmt.new(
                condition: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "once", @types.fetch("bool")),
                then_body: [IR::ExpressionStmt.new(expression: event_unsubscribe_call(runtime, event_expr, snapshot_subscription_expr))],
                else_body: nil,
              ),
              IR::IfStmt.new(
                condition: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "stateful", @types.fetch("bool")),
                then_body: [
                  IR::ExpressionStmt.new(expression: event_stateful_listener_call_expression(runtime, snapshots_expr, dispatch_index_expr, payload_expr)),
                ],
                else_body: [
                  IR::ExpressionStmt.new(expression: event_listener_call_expression(runtime, snapshots_expr, dispatch_index_expr, payload_expr)),
                ],
              ),
            ],
          ),
        ]

        body = [
          IR::LocalDecl.new(name: "__mt_snapshots", c_name: "__mt_snapshots", type: runtime.fetch(:snapshots_type), value: IR::ZeroInit.new(type: runtime.fetch(:snapshots_type))),
          IR::LocalDecl.new(name: "__mt_snapshot_count", c_name: "__mt_snapshot_count", type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          IR::ForStmt.new(
            init: IR::LocalDecl.new(name: "__mt_slot_index", c_name: "__mt_slot_index", type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
            condition: IR::Binary.new(operator: "<", left: slot_index_expr, right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @types.fetch("ptr_uint")), type: @types.fetch("bool")),
            post: IR::Assignment.new(target: slot_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            body: collect_body,
          ),
          IR::ForStmt.new(
            init: IR::LocalDecl.new(name: "__mt_dispatch_index", c_name: "__mt_dispatch_index", type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
            condition: IR::Binary.new(operator: "<", left: dispatch_index_expr, right: snapshot_count_expr, type: @types.fetch("bool")),
            post: IR::Assignment.new(target: dispatch_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            body: dispatch_body,
          ),
          IR::ReturnStmt.new(value: nil),
        ]

        params = [IR::Param.new(name: "event", c_name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)]
        params << IR::Param.new(name: "payload", c_name: "payload", type: runtime.fetch(:event_type).payload_type, pointer: false) if runtime.fetch(:event_type).payload_type

        IR::Function.new(
          name: "#{runtime.fetch(:emit_c_name)}_fn",
          c_name: runtime.fetch(:emit_c_name),
          params:,
          return_type: @types.fetch("void"),
          body:,
          entry_point: false,
        )
      end

      def build_event_wait_ready_function(runtime)
        frame_expr = IR::Name.new(name: "__mt_wait_frame", type: runtime.fetch(:wait_frame_pointer_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: "frame", type: runtime.fetch(:void_ptr), pointer: false)

        IR::Function.new(
          name: "#{runtime.fetch(:wait_ready_c_name)}_fn",
          c_name: runtime.fetch(:wait_ready_c_name),
          params: [IR::Param.new(name: "frame", c_name: "frame", type: runtime.fetch(:void_ptr), pointer: false)],
          return_type: @types.fetch("bool"),
          body: [
            IR::IfStmt.new(
              condition: IR::Binary.new(
                operator: "==",
                left: raw_frame_expr,
                right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                type: @types.fetch("bool"),
              ),
              then_body: [IR::ReturnStmt.new(value: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")))],
              else_body: nil,
            ),
            IR::LocalDecl.new(
              name: "__mt_wait_frame",
              c_name: "__mt_wait_frame",
              type: runtime.fetch(:wait_frame_pointer_type),
              value: IR::Cast.new(
                target_type: runtime.fetch(:wait_frame_pointer_type),
                expression: IR::Name.new(name: "frame", type: runtime.fetch(:void_ptr), pointer: false),
                type: runtime.fetch(:wait_frame_pointer_type),
              ),
            ),
            IR::ReturnStmt.new(value: wait_frame_field_expression(frame_expr, "ready", @types.fetch("bool"))),
          ],
          entry_point: false,
        )
      end

      def build_event_wait_set_waiter_function(runtime)
        frame_expr = IR::Name.new(name: "__mt_wait_frame", type: runtime.fetch(:wait_frame_pointer_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: "frame", type: runtime.fetch(:void_ptr), pointer: false)
        waiter_frame_expr = IR::Name.new(name: "waiter_frame", type: runtime.fetch(:void_ptr), pointer: false)
        waiter_expr = IR::Name.new(name: "waiter", type: runtime.fetch(:wake_type), pointer: false)

        IR::Function.new(
          name: "#{runtime.fetch(:wait_set_waiter_c_name)}_fn",
          c_name: runtime.fetch(:wait_set_waiter_c_name),
          params: [
            IR::Param.new(name: "frame", c_name: "frame", type: runtime.fetch(:void_ptr), pointer: false),
            IR::Param.new(name: "waiter_frame", c_name: "waiter_frame", type: runtime.fetch(:void_ptr), pointer: false),
            IR::Param.new(name: "waiter", c_name: "waiter", type: runtime.fetch(:wake_type), pointer: false),
          ],
          return_type: @types.fetch("void"),
          body: [
            IR::IfStmt.new(
              condition: IR::Binary.new(
                operator: "==",
                left: raw_frame_expr,
                right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                type: @types.fetch("bool"),
              ),
              then_body: [
                IR::ExpressionStmt.new(expression: IR::Call.new(callee: waiter_expr, arguments: [waiter_frame_expr], type: @types.fetch("void"))),
                IR::ReturnStmt.new(value: nil),
              ],
              else_body: nil,
            ),
            IR::LocalDecl.new(
              name: "__mt_wait_frame",
              c_name: "__mt_wait_frame",
              type: runtime.fetch(:wait_frame_pointer_type),
              value: IR::Cast.new(target_type: runtime.fetch(:wait_frame_pointer_type), expression: IR::Name.new(name: "frame", type: runtime.fetch(:void_ptr), pointer: false), type: runtime.fetch(:wait_frame_pointer_type)),
            ),
            IR::IfStmt.new(
              condition: wait_frame_field_expression(frame_expr, "ready", @types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(expression: IR::Call.new(callee: waiter_expr, arguments: [waiter_frame_expr], type: @types.fetch("void"))),
                IR::ReturnStmt.new(value: nil),
              ],
              else_body: nil,
            ),
            IR::Assignment.new(target: wait_frame_field_expression(frame_expr, "waiter_frame", runtime.fetch(:void_ptr)), operator: "=", value: waiter_frame_expr),
            IR::Assignment.new(target: wait_frame_field_expression(frame_expr, "waiter", runtime.fetch(:wake_type)), operator: "=", value: waiter_expr),
            IR::ReturnStmt.new(value: nil),
          ],
          entry_point: false,
        )
      end

      def build_event_wait_release_function(runtime)
        frame_expr = IR::Name.new(name: "__mt_wait_frame", type: runtime.fetch(:wait_frame_pointer_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: "frame", type: runtime.fetch(:void_ptr), pointer: false)

        IR::Function.new(
          name: "#{runtime.fetch(:wait_release_c_name)}_fn",
          c_name: runtime.fetch(:wait_release_c_name),
          params: [IR::Param.new(name: "frame", c_name: "frame", type: runtime.fetch(:void_ptr), pointer: false)],
          return_type: @types.fetch("void"),
          body: [
            IR::IfStmt.new(
              condition: IR::Binary.new(
                operator: "==",
                left: raw_frame_expr,
                right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                type: @types.fetch("bool"),
              ),
              then_body: [IR::ReturnStmt.new(value: nil)],
              else_body: nil,
            ),
            IR::LocalDecl.new(
              name: "__mt_wait_frame",
              c_name: "__mt_wait_frame",
              type: runtime.fetch(:wait_frame_pointer_type),
              value: IR::Cast.new(target_type: runtime.fetch(:wait_frame_pointer_type), expression: raw_frame_expr, type: runtime.fetch(:wait_frame_pointer_type)),
            ),
            IR::IfStmt.new(
              condition: IR::Unary.new(operator: "not", operand: wait_frame_field_expression(frame_expr, "ready", @types.fetch("bool")), type: @types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(
                  expression: event_unsubscribe_call(
                    runtime,
                    IR::Cast.new(target_type: runtime.fetch(:event_pointer_type), expression: wait_frame_field_expression(frame_expr, "event", runtime.fetch(:void_ptr)), type: runtime.fetch(:event_pointer_type)),
                    wait_frame_field_expression(frame_expr, "subscription", @types.fetch("Subscription")),
                  ),
                ),
              ],
              else_body: nil,
            ),
            IR::ExpressionStmt.new(expression: IR::Call.new(callee: "mt_async_free", arguments: [raw_frame_expr], type: @types.fetch("void"))),
            IR::ReturnStmt.new(value: nil),
          ],
          entry_point: false,
        )
      end

      def build_event_wait_take_result_function(runtime)
        frame_expr = IR::Name.new(name: "__mt_wait_frame", type: runtime.fetch(:wait_frame_pointer_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: "frame", type: runtime.fetch(:void_ptr), pointer: false)

        IR::Function.new(
          name: "#{runtime.fetch(:wait_take_result_c_name)}_fn",
          c_name: runtime.fetch(:wait_take_result_c_name),
          params: [IR::Param.new(name: "frame", c_name: "frame", type: runtime.fetch(:void_ptr), pointer: false)],
          return_type: runtime.fetch(:wait_result_type),
          body: [
            IR::IfStmt.new(
              condition: IR::Binary.new(
                operator: "==",
                left: raw_frame_expr,
                right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                type: @types.fetch("bool"),
              ),
              then_body: [IR::ReturnStmt.new(value: event_failure_literal(runtime.fetch(:wait_result_type)))],
              else_body: nil,
            ),
            IR::LocalDecl.new(
              name: "__mt_wait_frame",
              c_name: "__mt_wait_frame",
              type: runtime.fetch(:wait_frame_pointer_type),
              value: IR::Cast.new(target_type: runtime.fetch(:wait_frame_pointer_type), expression: IR::Name.new(name: "frame", type: runtime.fetch(:void_ptr), pointer: false), type: runtime.fetch(:wait_frame_pointer_type)),
            ),
            IR::ReturnStmt.new(value: wait_frame_field_expression(frame_expr, "result", runtime.fetch(:wait_result_type))),
          ],
          entry_point: false,
        )
      end

      def build_event_wait_function(runtime)
        event_expr = IR::Name.new(name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)
        frame_expr = IR::Name.new(name: "__mt_wait_frame", type: runtime.fetch(:wait_frame_pointer_type), pointer: false)
        raw_frame_expr = IR::Cast.new(target_type: runtime.fetch(:void_ptr), expression: frame_expr, type: runtime.fetch(:void_ptr))
        slot_index_expr = IR::Name.new(name: "__mt_slot_index", type: @types.fetch("ptr_uint"), pointer: false)
        generation_expr = IR::Name.new(name: "__mt_generation", type: @types.fetch("ptr_uint"), pointer: false)
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)

        body = [
          IR::ForStmt.new(
            init: IR::LocalDecl.new(name: "__mt_slot_index", c_name: "__mt_slot_index", type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
            condition: IR::Binary.new(operator: "<", left: slot_index_expr, right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @types.fetch("ptr_uint")), type: @types.fetch("bool")),
            post: IR::Assignment.new(target: slot_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            body: [
              IR::LocalDecl.new(name: "__mt_slot", c_name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), value: event_slot_pointer_expression(event_expr, slot_index_expr, runtime)),
              active_event_slot_continue_guard(slot_pointer_expr),
              IR::LocalDecl.new(
                name: "__mt_generation",
                c_name: "__mt_generation",
                type: @types.fetch("ptr_uint"),
                value: event_next_generation_expression(slot_pointer_expr),
              ),
              IR::LocalDecl.new(
                name: "__mt_wait_frame",
                c_name: "__mt_wait_frame",
                type: runtime.fetch(:wait_frame_pointer_type),
                value: IR::Cast.new(
                  target_type: runtime.fetch(:wait_frame_pointer_type),
                  expression: IR::Call.new(callee: "mt_async_alloc", arguments: [IR::SizeofExpr.new(target_type: runtime.fetch(:wait_frame_type), type: @types.fetch("ptr_uint"))], type: runtime.fetch(:void_ptr)),
                  type: runtime.fetch(:wait_frame_pointer_type),
                ),
              ),
              IR::Assignment.new(
                target: IR::Unary.new(operator: "*", operand: frame_expr, type: runtime.fetch(:wait_frame_type)),
                operator: "=",
                value: IR::ZeroInit.new(type: runtime.fetch(:wait_frame_type)),
              ),
              IR::Assignment.new(target: wait_frame_field_expression(frame_expr, "event", runtime.fetch(:void_ptr)), operator: "=", value: IR::Cast.new(target_type: runtime.fetch(:void_ptr), expression: event_expr, type: runtime.fetch(:void_ptr))),
              *event_slot_activate_statements(
                slot_pointer_expr,
                runtime,
                generation_expr: generation_expr,
                once: true,
                wait_frame_expr: raw_frame_expr,
              ),
              IR::Assignment.new(target: wait_frame_field_expression(frame_expr, "subscription", @types.fetch("Subscription")), operator: "=", value: event_subscription_literal(slot_index_expr, generation_expr)),
              IR::ReturnStmt.new(value: event_task_literal(runtime, frame_expr)),
            ],
          ),
          IR::ReturnStmt.new(value: event_immediate_failure_task_literal(runtime)),
        ]

        IR::Function.new(
          name: "#{runtime.fetch(:wait_c_name)}_fn",
          c_name: runtime.fetch(:wait_c_name),
          params: [IR::Param.new(name: "event", c_name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)],
          return_type: runtime.fetch(:task_type),
          body:,
          entry_point: false,
        )
      end

      def event_slot_pointer_expression(event_expr, slot_index_expr, runtime)
        IR::AddressOf.new(
          expression: IR::Index.new(
            receiver: IR::Member.new(receiver: event_expr, member: "slots", type: runtime.fetch(:slots_type)),
            index: slot_index_expr,
            type: runtime.fetch(:slot_type),
          ),
          type: runtime.fetch(:slot_pointer_type),
        )
      end

      def event_slot_local_decl(event_expr, slot_index_expr, runtime, local_name: "__mt_slot")
        IR::LocalDecl.new(
          name: local_name,
          c_name: local_name,
          type: runtime.fetch(:slot_pointer_type),
          value: event_slot_pointer_expression(event_expr, slot_index_expr, runtime),
        )
      end

      def event_slot_active_expression(slot_pointer_expr)
        event_slot_field_expression(slot_pointer_expr, "active", @types.fetch("bool"))
      end

      def event_slot_wait_frame_expression(slot_pointer_expr, runtime)
        event_slot_field_expression(slot_pointer_expr, "wait_frame", runtime.fetch(:void_ptr))
      end

      def active_event_slot_continue_guard(slot_pointer_expr)
        IR::IfStmt.new(
          condition: event_slot_active_expression(slot_pointer_expr),
          then_body: [IR::ContinueStmt.new],
          else_body: nil,
        )
      end

      def inactive_event_slot_continue_guard(slot_pointer_expr)
        IR::IfStmt.new(
          condition: IR::Unary.new(operator: "not", operand: event_slot_active_expression(slot_pointer_expr), type: @types.fetch("bool")),
          then_body: [IR::ContinueStmt.new],
          else_body: nil,
        )
      end

      def event_next_generation_expression(slot_pointer_expr)
        IR::Binary.new(
          operator: "+",
          left: event_slot_field_expression(slot_pointer_expr, "generation", @types.fetch("ptr_uint")),
          right: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint")),
          type: @types.fetch("ptr_uint"),
        )
      end

      def event_slot_activate_statements(slot_pointer_expr, runtime, generation_expr:, once:, wait_frame_expr:, listener_expr: nil)
        statements = [
          IR::Assignment.new(target: event_slot_active_expression(slot_pointer_expr), operator: "=", value: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "once", @types.fetch("bool")), operator: "=", value: IR::BooleanLiteral.new(value: once, type: @types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "generation", @types.fetch("ptr_uint")), operator: "=", value: generation_expr),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "state", runtime.fetch(:void_ptr)), operator: "=", value: IR::NullLiteral.new(type: runtime.fetch(:void_ptr))),
        ]
        statements << IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "listener", runtime.fetch(:listener_type)), operator: "=", value: listener_expr) if listener_expr
        statements << IR::Assignment.new(target: event_slot_wait_frame_expression(slot_pointer_expr, runtime), operator: "=", value: wait_frame_expr)
        statements
      end

      def event_slot_activate_stateful_statements(slot_pointer_expr, runtime, generation_expr:, once:, state_expr:, wait_frame_expr:, listener_expr: nil)
        statements = [
          IR::Assignment.new(target: event_slot_active_expression(slot_pointer_expr), operator: "=", value: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "once", @types.fetch("bool")), operator: "=", value: IR::BooleanLiteral.new(value: once, type: @types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "generation", @types.fetch("ptr_uint")), operator: "=", value: generation_expr),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "state", runtime.fetch(:void_ptr)), operator: "=", value: state_expr),
        ]
        statements << IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "listener", runtime.fetch(:listener_type)), operator: "=", value: listener_expr) if listener_expr
        statements << IR::Assignment.new(target: event_slot_wait_frame_expression(slot_pointer_expr, runtime), operator: "=", value: wait_frame_expr)
        statements
      end

      def event_slot_clear_statements(slot_pointer_expr, runtime)
        [
          IR::Assignment.new(target: event_slot_active_expression(slot_pointer_expr), operator: "=", value: IR::BooleanLiteral.new(value: false, type: @types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "once", @types.fetch("bool")), operator: "=", value: IR::BooleanLiteral.new(value: false, type: @types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_wait_frame_expression(slot_pointer_expr, runtime), operator: "=", value: IR::NullLiteral.new(type: runtime.fetch(:void_ptr))),
        ]
      end

      def event_slot_field_expression(slot_pointer_expr, field_name, field_type)
        IR::Member.new(receiver: slot_pointer_expr, member: field_name, type: field_type)
      end

      def snapshot_field_expression(snapshots_expr, index_expr, runtime, field_name, field_type)
        IR::Member.new(
          receiver: IR::Index.new(receiver: snapshots_expr, index: index_expr, type: runtime.fetch(:snapshot_type)),
          member: field_name,
          type: field_type,
        )
      end

      def subscription_field_expression(subscription_expr, field_name, field_type)
        IR::Member.new(receiver: subscription_expr, member: field_name, type: field_type)
      end

      def wait_frame_field_expression(frame_expr, field_name, field_type)
        IR::Member.new(receiver: frame_expr, member: field_name, type: field_type)
      end

      def event_subscription_literal(slot_expr, generation_expr)
        IR::AggregateLiteral.new(
          type: @types.fetch("Subscription"),
          fields: [
            IR::AggregateField.new(name: "slot", value: slot_expr),
            IR::AggregateField.new(name: "generation", value: generation_expr),
          ],
        )
      end

      def event_subscription_success_literal(result_type, slot_expr, generation_expr)
        IR::VariantLiteral.new(
          type: result_type,
          arm_name: "success",
          fields: [IR::AggregateField.new(name: "value", value: event_subscription_literal(slot_expr, generation_expr))],
        )
      end

      def event_wait_success_literal(result_type, payload_expr)
        IR::VariantLiteral.new(
          type: result_type,
          arm_name: "success",
          fields: [IR::AggregateField.new(name: "value", value: payload_expr || void_value_expression)],
        )
      end

      def event_failure_literal(result_type)
        IR::VariantLiteral.new(
          type: result_type,
          arm_name: "failure",
          fields: [
            IR::AggregateField.new(
              name: "error",
              value: IR::Name.new(name: enum_member_c_name(@types.fetch("EventError"), "full"), type: @types.fetch("EventError"), pointer: false),
            ),
          ],
        )
      end

      def void_value_expression
        IR::Cast.new(
          target_type: @types.fetch("void"),
          expression: IR::IntegerLiteral.new(value: 0, type: @types.fetch("int")),
          type: @types.fetch("void"),
        )
      end

      def event_unsubscribe_call(runtime, event_expr, subscription_expr)
        IR::Call.new(
          callee: runtime.fetch(:unsubscribe_c_name),
          arguments: [event_expr, subscription_expr],
          type: @types.fetch("void"),
        )
      end

      def event_listener_call_expression(runtime, snapshots_expr, dispatch_index_expr, payload_expr)
        listener_type = runtime.fetch(:listener_type)
        listener_expr = IR::Cast.new(
          target_type: listener_type,
          expression: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "listener", runtime.fetch(:void_ptr)),
          type: listener_type,
        )
        arguments = []
        arguments << payload_expr if runtime.fetch(:event_type).payload_type
        IR::Call.new(
          callee: listener_expr,
          arguments:,
          type: @types.fetch("void"),
        )
      end

      def event_stateful_listener_call_expression(runtime, snapshots_expr, dispatch_index_expr, payload_expr)
        listener_type = runtime.fetch(:listener_type)
        listener_expr = IR::Cast.new(
          target_type: listener_type,
          expression: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "listener", runtime.fetch(:void_ptr)),
          type: listener_type,
        )
        state_expr = snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "state", runtime.fetch(:void_ptr))
        arguments = [state_expr]
        arguments << payload_expr if runtime.fetch(:event_type).payload_type
        IR::Call.new(
          callee: listener_expr,
          arguments:,
          type: @types.fetch("void"),
        )
      end

      def event_task_literal(runtime, frame_expr)
        raw_frame_expr = IR::Cast.new(target_type: runtime.fetch(:void_ptr), expression: frame_expr, type: runtime.fetch(:void_ptr))
        event_task_literal_from_raw_frame(runtime, raw_frame_expr)
      end

      def event_immediate_failure_task_literal(runtime)
        event_task_literal_from_raw_frame(runtime, IR::NullLiteral.new(type: runtime.fetch(:void_ptr)))
      end

      def event_task_literal_from_raw_frame(runtime, raw_frame_expr)
        IR::AggregateLiteral.new(
          type: runtime.fetch(:task_type),
          fields: [
            IR::AggregateField.new(name: "frame", value: raw_frame_expr),
            IR::AggregateField.new(name: "ready", value: IR::Name.new(name: runtime.fetch(:wait_ready_c_name), type: runtime.fetch(:task_type).field("ready"), pointer: false)),
            IR::AggregateField.new(name: "set_waiter", value: IR::Name.new(name: runtime.fetch(:wait_set_waiter_c_name), type: runtime.fetch(:task_type).field("set_waiter"), pointer: false)),
            IR::AggregateField.new(name: "release", value: IR::Name.new(name: runtime.fetch(:wait_release_c_name), type: runtime.fetch(:task_type).field("release"), pointer: false)),
            IR::AggregateField.new(name: "take_result", value: IR::Name.new(name: runtime.fetch(:wait_take_result_c_name), type: runtime.fetch(:task_type).field("take_result"), pointer: false)),
          ],
        )
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
                  next if @lowered_function_c_names[c_name]

                  lowered << lower_function_decl(instance)
                  @lowered_function_c_names[c_name] = true
                  changed = true
                end
              else
                c_name = function_binding_c_name(binding, module_name: @module_name)
                next if @lowered_function_c_names[c_name]

                lowered << lower_function_decl(binding)
                @lowered_function_c_names[c_name] = true
                if (entrypoint = build_root_main_entrypoint(binding))
                  next if @lowered_function_c_names[entrypoint.c_name]

                  lowered << entrypoint
                  @lowered_function_c_names[entrypoint.c_name] = true
                end
                changed = true
              end
            when AST::ExtendingBlock
              receiver_type = resolve_extending_receiver_type(@analysis, decl.type_name)
              decl.methods.each do |method|
                binding = @analysis.methods.fetch(receiver_type).fetch(method.name)
                if binding.type_params.any?
                  binding.instances.values.sort_by { |instance| instance.type_arguments.map(&:to_s).join(",") }.each do |instance|
                    c_name = function_binding_c_name(instance, module_name: @module_name, receiver_type:)
                    next if @lowered_function_c_names[c_name]

                    lowered << lower_function_decl(instance, receiver_type:)
                    @lowered_function_c_names[c_name] = true
                    changed = true
                  end
                else
                  c_name = function_binding_c_name(binding, module_name: @module_name, receiver_type:)
                  next if @lowered_function_c_names[c_name]

                  lowered << lower_function_decl(binding, receiver_type:)
                  @lowered_function_c_names[c_name] = true
                  changed = true
                end
              end
            end
          end
        end

        lowered
      end

      def resolve_extending_receiver_type(analysis, type_name)
        if type_name.is_a?(AST::TypeRef)
          generic_type = resolve_named_generic_type_for_analysis(analysis, type_name.name.parts)
          if generic_type.is_a?(Types::GenericStructDefinition)
            validate_methods_receiver_type_arguments!(type_name, generic_type)
            return generic_type
          end

          begin
            return resolve_type_ref_for_analysis(type_name, analysis)
          rescue LoweringError => error
            receiver_type_param_names = methods_receiver_type_argument_names!(type_name)
            raise error if receiver_type_param_names.empty?

            receiver_type_params = receiver_type_param_names.to_h { |name| [name, Types::TypeVar.new(name)] }
            receiver_type = resolve_type_ref_for_analysis(type_name, analysis, type_params: receiver_type_params)
            return method_dispatch_receiver_type(receiver_type)
          end
        end

        parts = type_name.name.parts
        if parts.length == 1
          return analysis.types.fetch(parts.first)
        end

        if parts.length == 2
          imported_module = analysis.imports.fetch(parts.first)
          return imported_module.types.fetch(parts.last)
        end

        raise LoweringError, "unsupported extending target #{type_name}"
      end

      def lower_function_decl(binding, receiver_type: nil)
        decl = binding.ast
        params = []
        env = empty_env
        parameter_setup = []
        previous_type_substitutions = @current_type_substitutions
        @current_type_substitutions = binding.type_substitutions

        return lower_async_function_decl(binding, receiver_type:) if binding.async

        receiver_by_pointer = pointer_lowered_sync_method_receiver?(binding)

        body_params = binding.body_params.dup
        if binding.type.receiver_type
          receiver_binding = body_params.shift
          c_name = c_local_name(receiver_binding.name)
          env[:scopes].last[receiver_binding.name] = local_binding(
            type: receiver_binding.type,
            c_name:,
            mutable: receiver_binding.mutable,
            pointer: receiver_by_pointer,
          )
          params << IR::Param.new(
            name: receiver_binding.name,
            c_name:,
            type: receiver_binding.type,
            pointer: receiver_by_pointer,
          )
        end

        body_params.each_with_index do |param_binding, index|
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
          entry_point: false,
          method_receiver_param: !binding.type.receiver_type.nil?,
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

        if root_main_entrypoint_signature(binding)
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

      def build_async_main_entrypoint(binding, _constructor_c_name, async_info)
        task_type = async_info[:task_type]
        signature = root_main_entrypoint_signature(binding)
        raise LoweringError, "async main entrypoint requires a supported signature" unless signature

        params, setup_statements, call_arguments, cleanup_statements = build_root_main_entrypoint_bridge(signature)
        body = []
        env = empty_env

        root_proc_name = "__mt_async_main_root"
        result_name = "__mt_result"

        body.concat(setup_statements)
        argument_names = binding.type.params.each_index.map { |index| "__mt_async_main_arg_#{index + 1}" }
        binding.type.params.each_with_index do |param, index|
          name = argument_names.fetch(index)
          env[:scopes].last[name] = local_binding(type: param.type, c_name: name, mutable: false, pointer: false)
          body << IR::LocalDecl.new(
            name: name,
            c_name: name,
            type: param.type,
            value: call_arguments.fetch(index),
          )
        end

        proc_expression = AST::ProcExpr.new(
          params: [],
          return_type: ast_type_ref_for(task_type),
          body: [
            AST::ReturnStmt.new(
              value: AST::Call.new(
                callee: AST::Identifier.new(name: binding.name),
                arguments: argument_names.map { |name| AST::Argument.new(name: nil, value: AST::Identifier.new(name: name)) },
              ),
            ),
          ],
        )
        root_proc_type = Types::Proc.new(params: [], return_type: task_type)
        proc_setup, proc_value = lower_proc_expression_for_local(proc_expression, env:, local_name: root_proc_name, proc_type: root_proc_type)
        body.concat(proc_setup)
        body << IR::LocalDecl.new(
          name: root_proc_name,
          c_name: root_proc_name,
          type: root_proc_type,
          value: proc_value,
        )

        root_proc_expr = IR::Name.new(name: root_proc_name, type: root_proc_type, pointer: false)

        if async_info[:result_type] == @types.fetch("int")
          wait_callee = async_main_runtime_callee_name("wait", type_arguments: [async_info[:result_type]])
          body << IR::LocalDecl.new(
            name: result_name,
            c_name: result_name,
            type: @types.fetch("int"),
            value: IR::Call.new(
              callee: wait_callee,
              arguments: [root_proc_expr],
              type: @types.fetch("int"),
            ),
          )
        else
          run_callee = async_main_runtime_callee_name("run")
          body << IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: run_callee,
              arguments: [root_proc_expr],
              type: @types.fetch("void"),
            ),
          )
        end

        body << IR::ExpressionStmt.new(
          expression: lower_proc_release_expression(root_proc_expr, root_proc_type),
        )
        body.concat(cleanup_statements)
        body << IR::ReturnStmt.new(
          value: async_info[:result_type] == @types.fetch("int") ? IR::Name.new(name: result_name, type: @types.fetch("int"), pointer: false) : IR::IntegerLiteral.new(value: 0, type: @types.fetch("int")),
        )

        IR::Function.new(
          name: binding.name,
          c_name: "main",
          params:,
          return_type: @types.fetch("int"),
          body: body,
          entry_point: true,
        )
      end

      def async_main_runtime_callee_name(function_name, type_arguments: [])
        binding = analysis_for_module("std.async").functions.fetch(function_name)
        binding = binding.owner.send(:instantiate_function_binding, binding, type_arguments) if type_arguments.any?
        function_binding_c_name(binding, module_name: binding.owner.module_name)
      end

      def build_root_main_entrypoint(binding)
        return nil if binding.async

        signature = root_main_entrypoint_signature(binding)
        return nil unless signature

        params, setup_statements, call_arguments, cleanup_statements = build_root_main_entrypoint_bridge(signature)
        return_type = binding.body_return_type
        body = []
        call = IR::Call.new(
          callee: function_binding_c_name(binding, module_name: @module_name),
          arguments: call_arguments,
          type: return_type,
        )

        body.concat(setup_statements)
        if return_type == @types.fetch("void")
          body << IR::ExpressionStmt.new(expression: call)
          body.concat(cleanup_statements)
          body << IR::ReturnStmt.new(value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("int")))
        elsif cleanup_statements.empty?
          body << IR::ReturnStmt.new(value: call)
        else
          result_name = "__mt_result"
          body << IR::LocalDecl.new(
            name: result_name,
            c_name: result_name,
            type: @types.fetch("int"),
            value: call,
          )
          body.concat(cleanup_statements)
          body << IR::ReturnStmt.new(value: IR::Name.new(name: result_name, type: @types.fetch("int"), pointer: false))
        end

        IR::Function.new(
          name: binding.name,
          c_name: "main",
          params:,
          return_type: @types.fetch("int"),
          body:,
          entry_point: true,
        )
      end

      def build_root_main_entrypoint_bridge(signature)
        argc_type = @types.fetch("int")
        raw_argv_type = pointer_to(pointer_to(@types.fetch("char")))
        argc_name = "argc"
        argv_name = "argv"

        case signature[:kind]
        when :none
          [[], [], [], []]
        when :raw_char_ptr_ptr
          argc_expr = IR::Name.new(name: argc_name, type: argc_type, pointer: false)
          argv_expr = IR::Name.new(name: argv_name, type: raw_argv_type, pointer: false)
          [
            [
              IR::Param.new(name: argc_name, c_name: argc_name, type: argc_type, pointer: false),
              IR::Param.new(name: argv_name, c_name: argv_name, type: raw_argv_type, pointer: false),
            ],
            [],
            [argc_expr, argv_expr],
            [],
          ]
        when :raw_cstr_ptr
          argc_expr = IR::Name.new(name: argc_name, type: argc_type, pointer: false)
          argv_expr = IR::Cast.new(
            target_type: signature[:argv_type],
            expression: IR::Name.new(name: argv_name, type: raw_argv_type, pointer: false),
            type: signature[:argv_type],
          )
          [
            [
              IR::Param.new(name: argc_name, c_name: argc_name, type: argc_type, pointer: false),
              IR::Param.new(name: argv_name, c_name: argv_name, type: raw_argv_type, pointer: false),
            ],
            [],
            [argc_expr, argv_expr],
            [],
          ]
        when :span_str
          items_type = pointer_to(@types.fetch("str"))
          items_name = "__mt_args_items"
          args_name = "__mt_args"
          items_expr = IR::Name.new(name: items_name, type: items_type, pointer: false)
          args_expr = IR::Name.new(name: args_name, type: signature[:args_type], pointer: false)
          argc_expr = IR::Name.new(name: argc_name, type: argc_type, pointer: false)
          argv_expr = IR::Name.new(name: argv_name, type: raw_argv_type, pointer: false)

          setup = [
            IR::LocalDecl.new(
              name: items_name,
              c_name: items_name,
              type: items_type,
              value: IR::NullLiteral.new(type: items_type),
            ),
            IR::LocalDecl.new(
              name: args_name,
              c_name: args_name,
              type: signature[:args_type],
              value: IR::Call.new(
                callee: "mt_entry_argv_to_span_str",
                arguments: [
                  argc_expr,
                  argv_expr,
                  IR::AddressOf.new(expression: items_expr, type: pointer_to(items_type)),
                ],
                type: signature[:args_type],
              ),
            ),
          ]
          cleanup = [
            IR::ExpressionStmt.new(
              expression: IR::Call.new(callee: "mt_free_entry_argv_strs", arguments: [items_expr], type: @types.fetch("void")),
            ),
          ]

          [
            [
              IR::Param.new(name: argc_name, c_name: argc_name, type: argc_type, pointer: false),
              IR::Param.new(name: argv_name, c_name: argv_name, type: raw_argv_type, pointer: false),
            ],
            setup,
            [args_expr],
            cleanup,
          ]
        else
          raise LoweringError, "unsupported root main entrypoint bridge #{signature[:kind]}"
        end
      end

      def root_main_entrypoint_signature(binding)
        return nil unless @analysis == @program.root_analysis
        return nil unless binding.type.receiver_type.nil?
        return nil unless binding.name == "main"
        return nil unless binding.type_arguments.empty?

        return_type = binding.body_return_type
        return nil unless return_type == @types.fetch("int") || return_type == @types.fetch("void")

        params = binding.type.params
        return { kind: :none } if params.empty?

        if params.length == 1 && params.first.type.is_a?(Types::Span) && params.first.type.element_type == @types.fetch("str")
          return { kind: :span_str, args_type: params.first.type }
        end

        return nil unless params.length == 2
        return nil unless params[0].type == @types.fetch("int")

        argv_type = params[1].type
        return { kind: :raw_cstr_ptr, argv_type: } if argv_type == pointer_to(@types.fetch("cstr"))
        return { kind: :raw_char_ptr_ptr, argv_type: } if argv_type == pointer_to(pointer_to(@types.fetch("char")))

        nil
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
        env[:return_context] = {
          return_type: binding.body_return_type,
          active_defers: [],
          local_defers: [],
          allow_return: true,
        }

        statements.each_with_index do |statement, index|
          case statement
          when AST::LocalDecl
            type, storage_type = async_local_decl_types(statement, env:)
            local_field_key = async_local_decl_field_key(statement)
            local_fields[local_field_key] = { field_name: async_local_decl_field_name(statement), type:, storage_type:, mutable: statement.kind == :var }
            if statement.value.is_a?(AST::AwaitExpr)
              await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
            if bind_let_else_local?(statement)
              env[:scopes].last[statement.name] = local_binding(
                type:,
                storage_type:,
                c_name: statement.name,
                mutable: statement.kind == :var,
                pointer: false,
                const_value: statement.else_body ? nil : statement.kind == :let && statement.value ? compile_time_const_value(statement.value, env:) : nil,
              )
            end
            await_counter = analyze_async_statements!(statement.else_body, await_counter, env, param_fields, local_fields, await_fields) if statement.else_body
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
            if range_iterable?(statement.iterable)
              loop_type = infer_range_loop_type(statement.iterable, env:)
              local_fields[statement.name] ||= { field_name: "local_#{statement.name}", type: loop_type, storage_type: loop_type, mutable: true }
              stop_field_name = "local_#{statement.name}_stop"
              local_fields[stop_field_name] ||= { field_name: stop_field_name, type: loop_type, storage_type: loop_type, mutable: true }
            else
              statement.bindings.each_with_index do |binding, index|
                iterable_type = infer_expression_type(statement.iterables[index], env:)
                element_type = collection_loop_type(iterable_type)
                binding_type = collection_loop_binding_type(iterable_type, element_type) || element_type
                local_fields[binding.name] ||= { field_name: "local_#{binding.name}", type: binding_type, storage_type: binding_type, mutable: true }
                iterable_field_name = async_collection_iterable_field_name(statement, index)
                iterable_field_key = async_collection_iterable_field_key(statement, index)
                local_fields[iterable_field_key] ||= { field_name: iterable_field_name, type: iterable_type, storage_type: iterable_type, mutable: true }
              end
              index_field_name = async_collection_index_field_name(statement)
              index_field_key = async_collection_index_field_key(statement)
              local_fields[index_field_key] ||= { field_name: index_field_name, type: @types.fetch("ptr_uint"), storage_type: @types.fetch("ptr_uint"), mutable: true }
            end
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::MatchStmt
            scrutinee_type = infer_expression_type(statement.expression, env:)
            statement.arms.each do |arm|
              arm_env = duplicate_env(env)
              bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
              await_counter = analyze_async_statements!(arm.body, await_counter, arm_env, param_fields, local_fields, await_fields)
            end
          when AST::UnsafeStmt
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::DeferStmt
            if statement.body
              cleanup_env = duplicate_env(env)
              cleanup_env[:return_context] = cleanup_env[:return_context]&.merge(allow_return: false)
              await_counter = analyze_async_statements!(statement.body, await_counter, cleanup_env, param_fields, local_fields, await_fields)
            end
            if statement.expression.is_a?(AST::AwaitExpr)
              await_fields[statement.expression.object_id] = build_async_await_field_info(statement.expression, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
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
            type, storage_type = async_local_decl_types(statement, env:)
            local_field_key = async_local_decl_field_key(statement)
            local_fields[local_field_key] ||= { field_name: async_local_decl_field_name(statement), type:, storage_type:, mutable: statement.kind == :var }
            if statement.value.is_a?(AST::AwaitExpr)
              await_fields[statement.value.object_id] = build_async_await_field_info(statement.value, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
            if bind_let_else_local?(statement)
              env[:scopes].last[statement.name] = local_binding(
                type:,
                storage_type:,
                c_name: statement.name,
                mutable: statement.kind == :var,
                pointer: false,
                const_value: statement.else_body ? nil : statement.kind == :let && statement.value ? compile_time_const_value(statement.value, env:) : nil,
              )
            end
            await_counter = analyze_async_statements!(statement.else_body, await_counter, env, param_fields, local_fields, await_fields) if statement.else_body
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
            if range_iterable?(statement.iterable)
              loop_type = infer_range_loop_type(statement.iterable, env:)
              local_fields[statement.name] ||= { field_name: "local_#{statement.name}", type: loop_type, storage_type: loop_type, mutable: true }
              stop_field_name = "local_#{statement.name}_stop"
              local_fields[stop_field_name] ||= { field_name: stop_field_name, type: loop_type, storage_type: loop_type, mutable: true }
            else
              statement.bindings.each_with_index do |binding, index|
                iterable_type = infer_expression_type(statement.iterables[index], env:)
                element_type = collection_loop_type(iterable_type)
                binding_type = collection_loop_binding_type(iterable_type, element_type) || element_type
                local_fields[binding.name] ||= { field_name: "local_#{binding.name}", type: binding_type, storage_type: binding_type, mutable: true }
                iterable_field_name = async_collection_iterable_field_name(statement, index)
                iterable_field_key = async_collection_iterable_field_key(statement, index)
                local_fields[iterable_field_key] ||= { field_name: iterable_field_name, type: iterable_type, storage_type: iterable_type, mutable: true }
              end
              index_field_name = async_collection_index_field_name(statement)
              index_field_key = async_collection_index_field_key(statement)
              local_fields[index_field_key] ||= { field_name: index_field_name, type: @types.fetch("ptr_uint"), storage_type: @types.fetch("ptr_uint"), mutable: true }
            end
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::MatchStmt
            scrutinee_type = infer_expression_type(statement.expression, env:)
            statement.arms.each do |arm|
              arm_env = duplicate_env(env)
              bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
              await_counter = analyze_async_statements!(arm.body, await_counter, arm_env, param_fields, local_fields, await_fields)
            end
          when AST::UnsafeStmt
            await_counter = analyze_async_statements!(statement.body, await_counter, env, param_fields, local_fields, await_fields)
          when AST::DeferStmt
            if statement.body
              cleanup_env = duplicate_env(env)
              cleanup_env[:return_context] = cleanup_env[:return_context]&.merge(allow_return: false)
              await_counter = analyze_async_statements!(statement.body, await_counter, cleanup_env, param_fields, local_fields, await_fields)
            end
            if statement.expression.is_a?(AST::AwaitExpr)
              await_fields[statement.expression.object_id] = build_async_await_field_info(statement.expression, await_counter, env:, param_fields:, local_fields:)
              await_counter += 1
            end
          else
            nil
          end
        end
        await_counter
      end

      def async_local_decl_types(statement, env:)
        storage_type = if statement.else_body
                         infer_expression_type(statement.value, env:)
                       elsif statement.type
                         resolve_type_ref(statement.type)
                       else
                         infer_expression_type(statement.value, env:)
                       end
        type = if statement.else_body
                 statement.type ? resolve_type_ref(statement.type) : let_else_success_type(storage_type)
               else
                 storage_type
               end

        [type, storage_type]
      end

      def async_collection_iterable_field_key(statement, index = 0)
        "__async_for_iterable_#{statement.object_id}_#{index}"
      end

      def async_collection_iterable_field_name(statement, index = 0)
        "for_iterable_#{statement.object_id}_#{index}"
      end

      def async_collection_index_field_key(statement)
        "__async_for_index_#{statement.object_id}"
      end

      def async_collection_index_field_name(statement)
        "for_index_#{statement.object_id}"
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
          "ready" => @types.fetch("bool"),
          "waiter_frame" => async_info[:void_ptr],
          "waiter" => async_info[:wake_type],
        }
        fields["state"] = @types.fetch("int") unless async_info[:await_fields].empty?
        unless async_info[:result_type] == @types.fetch("void")
          fields["result"] = async_info[:result_type]
        end
        async_info[:param_fields].each_value do |field_info|
          fields[field_info[:field_name]] = field_info[:type]
        end
        async_info[:local_fields].each_value do |field_info|
          fields[field_info[:field_name]] = field_info[:storage_type]
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
              arguments: [IR::SizeofExpr.new(target_type: frame_type, type: @types.fetch("ptr_uint"))],
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
          method_receiver_param: !binding.type.receiver_type.nil?,
        )
      end

      def build_async_resume_function(binding, statements, frame_type, resume_c_name, async_info)
        async_info = async_info.merge(resume_c_name:)
        frame_expr = IR::Name.new(name: async_frame_local_name, type: pointer_to(frame_type), pointer: false)
        raw_frame_expr = IR::Name.new(name: async_frame_raw_name, type: async_info[:void_ptr], pointer: false)
        body = [async_frame_cast_declaration(frame_type, async_info)]

        env = async_resume_env_for(async_info)
        if async_info[:await_fields].empty?
          body.concat(lower_async_non_await_statements(statements, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: []))
        else
          cases = (0..async_info[:await_fields].length).map do |state|
            IR::SwitchCase.new(
              value: IR::IntegerLiteral.new(value: state, type: @types.fetch("int")),
              body: [IR::GotoStmt.new(label: async_state_label(resume_c_name, state))],
            )
          end
          body << IR::SwitchStmt.new(expression: async_frame_field_expression(frame_expr, "state", @types.fetch("int")), cases:)
          body << IR::ReturnStmt.new(value: nil)
          body << IR::LabelStmt.new(name: async_state_label(resume_c_name, 0))
          body.concat(lower_async_cf_statements(statements, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: []))
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
          next unless contains_proc_storage_type?(field_info[:storage_type])

          field_expr = async_frame_field_expression(frame_expr, field_info[:field_name], field_info[:storage_type])
          body.concat(lower_async_frame_proc_release_statements(field_expr, field_info[:storage_type]))
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
          storage_type: field_info[:storage_type],
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

      def lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: [], loop_flow: nil)
        lowered = []
        type = field_info[:type]
        storage_type = field_info[:storage_type]
        target = async_frame_field_expression(frame_expr, field_info[:field_name], storage_type)
        prepared_setup = []
        prepared_value = statement.value

        if statement.value
          prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
            statement.value,
            env:,
            expected_type: storage_type,
            allow_root_statement_foreign: true,
          )
          lowered.concat(prepared_setup)
        end

        if prepared_value && (foreign_call = foreign_call_info(prepared_value, env))
          setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
            foreign_call,
            env:,
            expected_type: storage_type,
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
                      expected_type: storage_type,
                      contextual_int_to_float: statement.type && contextual_int_to_float_target?(type),
                    )
                  else
                    IR::ZeroInit.new(type: storage_type)
                  end
          lowered << IR::Assignment.new(target:, operator: "=", value:)
        end

        if statement.else_body
          else_env = duplicate_env(env)
          if statement.else_binding
            current_actual_scope(else_env[:scopes])[statement.else_binding.name] = local_binding(
              type: let_else_error_type(storage_type),
              storage_type:,
              c_name: async_frame_field_c_name(field_info[:field_name]),
              mutable: false,
              pointer: false,
              projection: :result_failure_error,
            )
          end
          else_body = if statements_contain_await?(statement.else_body, async_info)
            lower_async_cf_statements(
              statement.else_body,
              env: else_env,
              frame_expr:,
              raw_frame_expr:,
              resume_c_name:,
              async_info:,
              active_defers:,
              loop_flow:,
            )
          else
            lower_async_non_await_statements(
              statement.else_body,
              env: else_env,
              frame_expr:,
              raw_frame_expr:,
              async_info:,
              active_defers:,
              loop_flow:,
            )
          end
          lowered << IR::IfStmt.new(
            condition: let_else_failure_condition(target, storage_type),
            then_body: else_body,
            else_body: nil,
          )
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
        env[:return_context] = {
          return_type: binding.body_return_type,
          active_defers: [],
          local_defers: [],
          allow_return: true,
        }
        normalize_async_statements(statements, counter, env, return_type: binding.body_return_type)
      end

      def normalize_async_statements(statements, counter, env, return_type:)
        statements.flat_map { |statement| normalize_async_statement(statement, counter, env, return_type:) }
      end

      def normalize_async_statement(statement, counter, env, return_type:)
        case statement
        when AST::LocalDecl
          if statement.value
            local_type, storage_type = async_local_decl_types(statement, env:)
            expected_type = statement.else_body ? storage_type : (statement.type ? resolve_type_ref(statement.type) : nil)
            setup, value = if statement.value.is_a?(AST::AwaitExpr)
              [[], statement.value]
            else
              normalize_async_expression(statement.value, counter, env:, expected_type: expected_type)
            end
            else_body = if statement.else_body
              else_env = duplicate_env(env)
              normalize_async_statements(statement.else_body, counter, else_env, return_type:)
            end
            normalized = AST::LocalDecl.new(kind: statement.kind, name: statement.name, type: statement.type, value: value, else_binding: statement.else_binding, else_body:, line: statement.line)
            if bind_let_else_local?(statement)
              current_actual_scope(env[:scopes])[statement.name] = local_binding(
                type: local_type,
                storage_type:,
                c_name: statement.name,
                mutable: statement.kind == :var,
                pointer: false,
                projection: statement.else_body ? let_else_binding_projection(storage_type) : nil,
                const_value: statement.else_body ? nil : statement.kind == :let ? compile_time_const_value(statement.value, env:) : nil,
              )
            end
            return setup + [normalized]
          end

          local_type = resolve_type_ref(statement.type)
          current_actual_scope(env[:scopes])[statement.name] = local_binding(
            type: local_type,
            storage_type: local_type,
            c_name: statement.name,
            mutable: statement.kind == :var,
            pointer: false,
            const_value: nil,
          )
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
          scrutinee_type = infer_expression_type(statement.expression, env:)
          arms = statement.arms.map do |arm|
            arm_env = duplicate_env(env)
            bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
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
          for_env = duplicate_env(env)
          if statement.parallel?
            iterable_setups = []
            normalized_iterables = statement.iterables.map do |iterable|
              setup, normalized_iterable = normalize_async_expression(iterable, counter, env:)
              iterable_setups.concat(setup)
              normalized_iterable
            end
            statement.bindings.each_with_index do |binding, index|
              iterable_type = infer_expression_type(statement.iterables[index], env:)
              element_type = collection_loop_type(iterable_type)
              binding_type = collection_loop_binding_type(iterable_type, element_type) || element_type
              current_actual_scope(for_env[:scopes])[binding.name] = local_binding(type: binding_type, c_name: binding.name, mutable: false, pointer: false)
            end
            body = normalize_async_statements(statement.body, counter, for_env, return_type:)
            return iterable_setups + [AST::ForStmt.new(bindings: statement.bindings, iterables: normalized_iterables, body:)]
          end

          iterable_setup, iterable = normalize_async_expression(statement.iterable, counter, env:)
          current_actual_scope(for_env[:scopes])[statement.name] = local_binding(type: loop_type, c_name: statement.name, mutable: false, pointer: false)
          body = normalize_async_statements(statement.body, counter, for_env, return_type:)
          iterable_setup + [AST::ForStmt.new(bindings: statement.bindings, iterables: [iterable], body:)]
        when AST::UnsafeStmt
          unsafe_env = duplicate_env(env)
          [AST::UnsafeStmt.new(body: normalize_async_statements(statement.body, counter, unsafe_env, return_type:))]
        when AST::DeferStmt
          cleanup_env = duplicate_env(env)
          cleanup_env[:return_context] = cleanup_env[:return_context]&.merge(allow_return: false)
          cleanup_body = if statement.body
                           normalize_async_statements(statement.body, counter, cleanup_env, return_type:)
                         else
                           expression_setup, expression = normalize_async_expression(statement.expression, counter, env: cleanup_env)
                           expression_setup + [AST::ExpressionStmt.new(expression:, line: statement.line)]
                         end
          [AST::DeferStmt.new(expression: nil, body: cleanup_body, line: statement.line, column: statement.column, length: statement.length)]
        when AST::BreakStmt, AST::ContinueStmt, AST::StaticAssert, AST::PassStmt
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
        when AST::MatchExpr
          expression_setup, normalized_expression = normalize_async_expression(expression.expression, counter, env:)
          result_type = infer_expression_type(expression, env:, expected_type:)
          scrutinee_type = infer_expression_type(expression.expression, env:)
          normalized_arms = expression.arms.map do |arm|
            arm_env = duplicate_env(env)
            bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
            pattern_setup, normalized_pattern = normalize_async_expression(arm.pattern, counter, env:)
            value_setup, normalized_value = normalize_async_expression(arm.value, counter, env: arm_env, expected_type: result_type)
            [pattern_setup, value_setup, AST::MatchExprArm.new(
              pattern: normalized_pattern,
              binding_name: arm.binding_name,
              binding_line: arm.binding_line,
              binding_column: arm.binding_column,
              value: normalized_value,
            )]
          end

          if expression_setup.empty? && normalized_arms.all? { |pattern_setup, value_setup, _arm| pattern_setup.empty? && value_setup.empty? }
            return [[], AST::MatchExpr.new(expression: normalized_expression, arms: normalized_arms.map(&:last), line: expression.line, column: expression.column, length: expression.length)]
          end

          temp_name = fresh_async_temp_name(counter)
          setup = expression_setup + [
            AST::LocalDecl.new(kind: :var, name: temp_name, type: ast_type_ref_for(result_type), value: nil),
            AST::MatchStmt.new(
              expression: normalized_expression,
              arms: normalized_arms.map do |pattern_setup, value_setup, arm|
                AST::MatchArm.new(
                  pattern: arm.pattern,
                  binding_name: arm.binding_name,
                  binding_line: arm.binding_line,
                  binding_column: arm.binding_column,
                  body: pattern_setup + value_setup + [AST::Assignment.new(target: AST::Identifier.new(name: temp_name), operator: "=", value: arm.value)],
                )
              end,
              line: expression.line,
              column: expression.column,
              length: expression.length,
            ),
          ]
          [setup, AST::Identifier.new(name: temp_name)]
        when AST::UnsafeExpr
          normalize_async_expression(expression.expression, counter, env:, expected_type:)
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
              AST::FormatExprPart.new(expression: inner_expression, format_spec: part.format_spec)
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
        when AST::MatchExpr
          async_expression_contains_await?(expression.expression) || expression.arms.any? { |arm| async_expression_contains_await?(arm.pattern) || async_expression_contains_await?(arm.value) }
        when AST::UnsafeExpr
          async_expression_contains_await?(expression.expression)
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
            async_info[:await_fields].key?(s.value&.object_id) || async_expression_contains_await?(s.value) || (s.else_body && statements_contain_await?(s.else_body, async_info))
          when AST::Assignment
            async_info[:await_fields].key?(s.value&.object_id) || async_expression_contains_await?(s.target) || async_expression_contains_await?(s.value)
          when AST::ExpressionStmt
            async_info[:await_fields].key?(s.expression&.object_id) || async_expression_contains_await?(s.expression)
          when AST::ReturnStmt
            async_info[:await_fields].key?(s.value&.object_id) || async_expression_contains_await?(s.value)
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
          when AST::DeferStmt
            (s.body && statements_contain_await?(s.body, async_info)) || (s.expression && async_expression_contains_await?(s.expression))
          else
            false
          end
        end
      end

      # Lower a list of statements that MAY contain await expressions inside nested control flow.
      # CPS-via-goto: labels placed inside if/while/match bodies, reachable from top-level switch dispatch.
      def lower_async_cf_statements(statements, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: [], loop_flow: nil)
        lowered = []
        local_defers = []
        env[:return_context] = async_return_context(
          return_type: async_info[:result_type],
          active_defers:,
          local_defers:,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
        )

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            field_info = async_info[:local_fields].fetch(async_local_decl_field_key(statement))
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, field_info:, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
            else
              lowered.concat(lower_async_local_decl_statement(statement, field_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
            end
            async_bind_local!(env, statement.name, field_info) if bind_let_else_local?(statement)
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
            cleanup = lower_async_cleanup_entries(local_defers, active_defers, frame_expr:, raw_frame_expr:, async_info:)
            await_info = async_info[:await_fields][statement.value&.object_id]
            if await_info
              lowered.concat(lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, cleanup:))
            else
              lowered.concat(lower_async_return_statement(statement, env:, frame_expr:, raw_frame_expr:, async_info:, cleanup:))
            end
          when AST::IfStmt
            lowered.concat(lower_async_cf_if_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::WhileStmt
            lowered.concat(lower_async_cf_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::ForStmt
            lowered.concat(lower_async_cf_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers))
          when AST::MatchStmt
            lowered.concat(lower_async_cf_match_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::UnsafeStmt
            lowered.concat(lower_async_cf_statements(statement.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)))
          when AST::DeferStmt
            local_defers << lower_async_defer_cleanup(statement, env:, async_info:)
          when AST::PassStmt
            nil
          when AST::BreakStmt
            if loop_flow
              lowered.concat(lower_async_loop_exit(loop_flow[:break_target], local_defers, loop_flow[:break_defers], frame_expr:, raw_frame_expr:, async_info:))
            else
              lowered << IR::BreakStmt.new
            end
          when AST::ContinueStmt
            if loop_flow
              lowered.concat(lower_async_loop_exit(loop_flow[:continue_target], local_defers, loop_flow[:continue_defers], frame_expr:, raw_frame_expr:, async_info:))
            else
              lowered << IR::ContinueStmt.new
            end
          when AST::StaticAssert
            lowered.concat(lower_static_assert(statement))
          else
            raise LoweringError, "unsupported async cf statement #{statement.class.name}"
          end
        end

        unless cfg_block_always_terminates?(statements)
          lowered.concat(lower_async_cleanup_entries(local_defers, [], frame_expr:, raw_frame_expr:, async_info:))
        end
        lowered
      end

      def lower_async_cf_if_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
        branch_entries = statement.branches.map do |branch|
          condition_setup, prepared_cond = prepare_expression_for_inline_lowering(branch.condition, env:)
          condition = lower_contextual_expression(prepared_cond, env:, expected_type: @types.fetch("bool"))
          body = if statements_contain_await?(branch.body, async_info)
            lower_async_cf_statements(branch.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
          else
            lower_async_non_await_statements(branch.body, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow:)
          end
          { condition_setup:, condition:, body: }
        end

        else_body = if statement.else_body
          if statements_contain_await?(statement.else_body, async_info)
            lower_async_cf_statements(statement.else_body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
          else
            lower_async_non_await_statements(statement.else_body, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow:)
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

      def lower_async_cf_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        condition_setup, prepared_cond = prepare_expression_for_inline_lowering(statement.condition, env:)
        condition = lower_contextual_expression(prepared_cond, env:, expected_type: @types.fetch("bool"))
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))
        body = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: duplicate_env(env), frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: duplicate_env(env), frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        if condition_setup.empty?
          stmts = [IR::WhileStmt.new(condition:, body:)]
          stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
          return stmts
        end

        loop_body = [
          *condition_setup,
          IR::IfStmt.new(
            condition: IR::Unary.new(operator: "not", operand: condition, type: @types.fetch("bool")),
            then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
            else_body: nil,
          ),
          *body,
        ]
        stmts = [IR::WhileStmt.new(condition: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")), body: loop_body)]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(loop_body, break_label)
        stmts
      end

      def lower_async_cf_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        return lower_async_cf_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:) if statement.parallel?

        if range_iterable?(statement.iterable)
          lower_async_cf_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        else
          lower_async_cf_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
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

      def lower_async_cf_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        loop_var_name = statement.name
        loop_var_type = infer_range_loop_type(statement.iterable, env:)
        loop_var_field = async_info[:local_fields].fetch(loop_var_name)
        loop_var_expr = async_frame_field_expression(frame_expr, loop_var_field[:field_name], loop_var_type)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")

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
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))

        body = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        cmp_op = inclusive ? "<=" : "<"
        stmts = [
          IR::Assignment.new(target: loop_var_expr, operator: "=", value: start_expr),
          IR::Assignment.new(target: stop_field_expr, operator: "=", value: stop_expr),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: cmp_op, left: loop_var_expr, right: stop_field_expr, type: @types.fetch("bool")),
            body: body + [IR::Assignment.new(target: loop_var_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: loop_var_type))],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)
        stmts
      end

      def lower_async_cf_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects start..stop, array[T, N], or span[T], got #{iterable_type}" unless element_type

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        iterable_field = async_info[:local_fields].fetch(async_collection_iterable_field_key(statement))
        index_field = async_info[:local_fields].fetch(async_collection_index_field_key(statement))
        iterable_ref = async_frame_field_expression(frame_expr, iterable_field[:field_name], iterable_type)
        index_ref = async_frame_field_expression(frame_expr, index_field[:field_name], @types.fetch("ptr_uint"))

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
                       IR::IntegerLiteral.new(value: array_length(iterable_type), type: @types.fetch("ptr_uint"))
                     else
                       IR::Member.new(receiver: iterable_ref, member: "len", type: @types.fetch("ptr_uint"))
                     end

        inner_env = duplicate_env(env)
        inner_env[:scopes].last[statement.name] = local_binding(
          type: element_type, c_name: async_frame_field_c_name(loop_var_field[:field_name]), mutable: true, pointer: false
        )
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))

        assign_item = IR::Assignment.new(target: loop_var_expr, operator: "=", value: item_value)
        body_stmts = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body_stmts << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body_stmts, continue_label)

        stmts = [
          *iterable_setup,
          IR::Assignment.new(target: iterable_ref, operator: "=", value: lower_expression(prepared_iterable, env:, expected_type: iterable_type)),
          IR::Assignment.new(target: index_ref, operator: "=", value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
            body: [assign_item] + body_stmts + [
              IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            ],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body_stmts, break_label)
        stmts
      end

      def lower_async_cf_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:)
        infos = statement.bindings.each_with_index.map do |binding, index|
          iterable = statement.iterables[index]
          iterable_type = infer_expression_type(iterable, env:)
          element_type = collection_loop_type(iterable_type)
          raise LoweringError, "parallel for loops expect arrays or spans for each iterable, got #{iterable_type}" unless element_type

          {
            binding:,
            iterable:,
            iterable_type:,
            element_type:,
            binding_type: collection_loop_binding_type(iterable_type, element_type) || element_type,
            iterable_field: async_info[:local_fields].fetch(async_collection_iterable_field_key(statement, index)),
          }
        end

        iterable_entries = infos.map do |info|
          setup, prepared_iterable = prepare_expression_for_inline_lowering(info[:iterable], env:, expected_type: info[:iterable_type])
          info.merge(setup:, prepared_iterable:)
        end

        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_field = async_info[:local_fields].fetch(async_collection_index_field_key(statement))
        index_ref = async_frame_field_expression(frame_expr, index_field[:field_name], @types.fetch("ptr_uint"))
        iterable_refs = iterable_entries.map do |entry|
          async_frame_field_expression(frame_expr, entry[:iterable_field][:field_name], entry[:iterable_type])
        end
        stop_value = collection_loop_stop_value(iterable_refs.first, iterable_entries.first[:iterable_type])

        inner_env = duplicate_env(env)
        assign_items = iterable_entries.map.with_index do |entry, index|
          item_value = collection_loop_item_value(iterable_refs[index], entry[:iterable_type], index_ref, entry[:element_type])
          loop_item_value = if ref_type?(entry[:binding_type])
                              IR::AddressOf.new(expression: item_value, type: entry[:binding_type])
                            else
                              item_value
                            end
          binding_field = async_info[:local_fields].fetch(entry[:binding].name)
          binding_target = async_frame_field_expression(frame_expr, binding_field[:field_name], entry[:binding_type])
          inner_env[:scopes].last[entry[:binding].name] = local_binding(
            type: entry[:binding_type],
            c_name: async_frame_field_c_name(binding_field[:field_name]),
            mutable: true,
            pointer: false,
          )
          IR::Assignment.new(target: binding_target, operator: "=", value: loop_item_value)
        end
        inner_loop_flow = loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label))
        body_stmts = if statements_contain_await?(statement.body, async_info)
          lower_async_cf_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        else
          lower_async_non_await_statements(statement.body, env: inner_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: inner_loop_flow)
        end
        body_stmts << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body_stmts, continue_label)

        length_checks = iterable_entries.drop(1).each_with_index.map do |entry, offset|
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: "!=",
              left: collection_loop_stop_value(iterable_refs[offset + 1], entry[:iterable_type]),
              right: stop_value,
              type: @types.fetch("bool"),
            ),
            then_body: [lower_fatal_statement("parallel for iterables must have matching lengths", env:)],
            else_body: nil,
          )
        end

        stmts = [
          *iterable_entries.flat_map { |entry| entry[:setup] },
          *iterable_entries.each_with_index.map do |entry, index|
            IR::Assignment.new(
              target: iterable_refs[index],
              operator: "=",
              value: lower_expression(entry[:prepared_iterable], env:, expected_type: entry[:iterable_type]),
            )
          end,
          *length_checks,
          IR::Assignment.new(target: index_ref, operator: "=", value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          IR::WhileStmt.new(
            condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
            body: assign_items + body_stmts + [
              IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            ],
          ),
        ]
        stmts << IR::LabelStmt.new(name: break_label) if contains_label_target?(body_stmts, break_label)
        stmts
      end

      def lower_async_cf_match_stmt(statement, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow:)
        expr_setup, prepared_expr = prepare_expression_for_inline_lowering(statement.expression, env:)
        match_expr = lower_contextual_expression(prepared_expr, env:, expected_type: nil)
        match_type = infer_expression_type(statement.expression, env:)
        arm_loop_flow = switch_loop_flow(loop_flow, [])

        if match_type.is_a?(Types::Variant)
          if statement.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
             !duplicable_foreign_argument_expression?(match_expr)
            scrutinee_c_name = fresh_c_temp_name(env, "match_value")
            expr_setup << IR::LocalDecl.new(name: scrutinee_c_name, c_name: scrutinee_c_name, type: match_type, value: match_expr)
            match_expr = IR::Name.new(name: scrutinee_c_name, type: match_type, pointer: false)
          end

          kind_type = @types.fetch("int")
          kind_expr = IR::Member.new(receiver: match_expr, member: "kind", type: kind_type)
          cases = statement.arms.map do |arm|
            arm_env, binding_decl = async_variant_match_arm_binding(arm, match_expr, match_type, env:)
            arm_body = if statements_contain_await?(arm.body, async_info)
                         lower_async_cf_statements(arm.body, env: arm_env, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: arm_loop_flow)
                       else
                         lower_async_non_await_statements(arm.body, env: arm_env, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: arm_loop_flow)
                       end
            body = [binding_decl, *arm_body].compact + [IR::BreakStmt.new]
            if wildcard_arm_pattern?(arm.pattern)
              IR::SwitchDefaultCase.new(body: body)
            else
              arm_name = variant_match_arm_name_from_pattern(arm.pattern)
              IR::SwitchCase.new(value: IR::Name.new(name: enum_member_c_name(match_type, "kind_#{arm_name}"), type: kind_type, pointer: false), body: body)
            end
          end

          return expr_setup + [IR::SwitchStmt.new(expression: kind_expr, cases:, exhaustive: true)]
        end

        cases = statement.arms.map do |arm|
          arm_body = if statements_contain_await?(arm.body, async_info)
            lower_async_cf_statements(arm.body, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, active_defers:, loop_flow: arm_loop_flow)
          else
            lower_async_non_await_statements(arm.body, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:, loop_flow: arm_loop_flow)
          end
          if wildcard_arm_pattern?(arm.pattern)
            IR::SwitchDefaultCase.new(body: arm_body + [IR::BreakStmt.new])
          else
            IR::SwitchCase.new(value: lower_expression(arm.pattern, env:, expected_type: match_type), body: arm_body + [IR::BreakStmt.new])
          end
        end

        expr_setup + [IR::SwitchStmt.new(expression: match_expr, cases:, exhaustive: true)]
      end

      def lower_async_non_await_statements(statements, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [], loop_flow: nil)
        local_env = duplicate_env(env)
        lowered = []
        local_defers = []
        local_env[:return_context] = async_return_context(
          return_type: async_info[:result_type],
          active_defers:,
          local_defers:,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
        )

        statements.each do |statement|
          case statement
          when AST::LocalDecl
            else_env = duplicate_env(local_env) if statement.else_body
            type, storage_type = async_local_decl_types(statement, env: local_env)
            c_name = c_local_name(statement.name)
            if statement.value
              prepared_setup, prepared_value = prepare_expression_for_inline_lowering(
                statement.value, env: local_env, expected_type: storage_type, allow_root_statement_foreign: true
              )
              lowered.concat(prepared_setup)
              value = lower_contextual_expression(
                prepared_value, env: local_env, expected_type: storage_type,
                contextual_int_to_float: statement.type && contextual_int_to_float_target?(type)
              )
            else
              value = IR::ZeroInit.new(type: storage_type)
            end
            lowered << IR::LocalDecl.new(name: statement.name, c_name:, type: storage_type, value:)
            current_actual_scope(local_env[:scopes])[statement.name] = local_binding(type:, storage_type:, c_name:, mutable: statement.kind == :var, pointer: false)
            if statement.else_body
              else_body = lower_async_non_await_statements(
                statement.else_body,
                env: else_env,
                frame_expr:,
                raw_frame_expr:,
                async_info:,
                active_defers: active_defers + local_defers,
                loop_flow: nested_loop_flow(loop_flow, local_defers),
              )
              lowered << IR::IfStmt.new(
                condition: IR::Binary.new(
                  operator: "==",
                  left: IR::Name.new(name: c_name, type: storage_type, pointer: false),
                  right: IR::NullLiteral.new(type: storage_type),
                  type: @types.fetch("bool"),
                ),
                then_body: else_body,
                else_body: nil,
              )
            end
          when AST::Assignment
            lowered.concat(lower_async_assignment_statement(statement, env: local_env))
          when AST::ExpressionStmt
            lowered.concat(lower_async_expression_statement(statement, env: local_env))
          when AST::ReturnStmt
            lowered.concat(lower_async_return_statement(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:, cleanup: lower_async_cleanup_entries(local_defers, active_defers, frame_expr:, raw_frame_expr:, async_info:)))
          when AST::IfStmt
            branch_entries = statement.branches.map do |branch|
              condition_setup, prepared_cond = prepare_expression_for_inline_lowering(
                branch.condition, env: local_env, expected_type: @types.fetch("bool")
              )
              then_body = lower_async_non_await_statements(
                branch.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)
              )
              [condition_setup, lower_expression(prepared_cond, env: local_env, expected_type: @types.fetch("bool")), then_body]
            end
            else_body = statement.else_body ? lower_async_non_await_statements(
              statement.else_body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)
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
            arm_loop_flow = switch_loop_flow(loop_flow, local_defers)
            if scrutinee_type.is_a?(Types::Variant)
              if statement.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
                 !duplicable_foreign_argument_expression?(expr)
                scrutinee_c_name = fresh_c_temp_name(local_env, "match_value")
                lowered << IR::LocalDecl.new(name: scrutinee_c_name, c_name: scrutinee_c_name, type: scrutinee_type, value: expr)
                expr = IR::Name.new(name: scrutinee_c_name, type: scrutinee_type, pointer: false)
              end

              kind_type = @types.fetch("int")
              kind_expr = IR::Member.new(receiver: expr, member: "kind", type: kind_type)
              cases = statement.arms.map do |arm|
                arm_env, binding_decl = async_variant_match_arm_binding(arm, expr, scrutinee_type, env: local_env)
                arm_body = lower_async_non_await_statements(
                  arm.body, env: arm_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: arm_loop_flow
                )
                body = [binding_decl, *arm_body].compact
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body: body)
                else
                  arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                  IR::SwitchCase.new(value: IR::Name.new(name: enum_member_c_name(scrutinee_type, "kind_#{arm_name}"), type: kind_type, pointer: false), body: body)
                end
              end
              lowered << IR::SwitchStmt.new(expression: kind_expr, cases:, exhaustive: true)
            else
              cases = statement.arms.map do |arm|
                arm_body = lower_async_non_await_statements(
                  arm.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: arm_loop_flow
                )
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body: arm_body)
                else
                  value = lower_expression(arm.pattern, env: local_env, expected_type: scrutinee_type)
                  IR::SwitchCase.new(value:, body: arm_body)
                end
              end
              lowered << IR::SwitchStmt.new(expression: expr, cases:, exhaustive: true)
            end
          when AST::WhileStmt
            lowered << lower_async_while_stmt(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers)
          when AST::ForStmt
            lowered << lower_async_for_stmt(statement, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers)
          when AST::DeferStmt
            local_defers << lower_async_defer_cleanup(statement, env: local_env, async_info:)
          when AST::PassStmt
            nil
          when AST::BreakStmt
            if loop_flow
              lowered.concat(lower_async_loop_exit(loop_flow[:break_target], local_defers, loop_flow[:break_defers], frame_expr:, raw_frame_expr:, async_info:))
            else
              lowered << IR::BreakStmt.new
            end
          when AST::ContinueStmt
            if loop_flow
              lowered.concat(lower_async_loop_exit(loop_flow[:continue_target], local_defers, loop_flow[:continue_defers], frame_expr:, raw_frame_expr:, async_info:))
            else
              lowered << IR::ContinueStmt.new
            end
          when AST::UnsafeStmt
            lowered.concat(lower_async_non_await_statements(
              statement.body, env: local_env, frame_expr:, raw_frame_expr:, async_info:, active_defers: active_defers + local_defers, loop_flow: nested_loop_flow(loop_flow, local_defers)
            ))
          when AST::StaticAssert
            lowered << lower_static_assert(statement, env: local_env)
          else
            raise LoweringError, "unsupported async non-await statement #{statement.class.name}"
          end
        end

        unless cfg_block_always_terminates?(statements)
          lowered.concat(lower_async_cleanup_entries(local_defers, [], frame_expr:, raw_frame_expr:, async_info:))
        end
        lowered
      end

      def lower_async_while_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
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
          active_defers:,
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

      def lower_async_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
        return lower_async_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:) if statement.parallel?

        return lower_async_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:) if range_iterable?(statement.iterable)

        lower_async_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers:)
      end

      def lower_async_range_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
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
          active_defers:,
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

      def lower_async_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
        iterable_type = infer_expression_type(statement.iterable, env:)
        element_type = collection_loop_type(iterable_type)
        raise LoweringError, "for loop expects start..stop, array[T, N], or span[T], got #{iterable_type}" unless element_type

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        iterable_c_name = fresh_c_temp_name(env, "for_items")
        index_c_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        iterable_ref = IR::Name.new(name: iterable_c_name, type: iterable_type, pointer: false)
        index_ref = IR::Name.new(name: index_c_name, type: @types.fetch("ptr_uint"), pointer: false)

        item_value = if array_type?(iterable_type)
                       IR::Index.new(receiver: iterable_ref, index: index_ref, type: element_type)
                     else
                       data_ref = IR::Member.new(receiver: iterable_ref, member: "data", type: pointer_to(element_type))
                       IR::Index.new(receiver: data_ref, index: index_ref, type: element_type)
                     end
        stop_value = if array_type?(iterable_type)
                       IR::IntegerLiteral.new(value: array_length(iterable_type), type: @types.fetch("ptr_uint"))
                     else
                       IR::Member.new(receiver: iterable_ref, member: "len", type: @types.fetch("ptr_uint"))
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
          active_defers:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        ))
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
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

      def lower_async_parallel_collection_for_stmt(statement, env:, frame_expr:, raw_frame_expr:, async_info:, active_defers: [])
        infos = statement.bindings.each_with_index.map do |binding, index|
          iterable = statement.iterables[index]
          iterable_type = infer_expression_type(iterable, env:)
          element_type = collection_loop_type(iterable_type)
          raise LoweringError, "parallel for loops expect arrays or spans for each iterable, got #{iterable_type}" unless element_type

          {
            binding:,
            iterable:,
            iterable_type:,
            element_type:,
            binding_type: collection_loop_binding_type(iterable_type, element_type) || element_type,
          }
        end

        iterable_entries = infos.map do |info|
          setup, prepared_iterable = prepare_expression_for_inline_lowering(info[:iterable], env:, expected_type: info[:iterable_type])
          c_name = fresh_c_temp_name(env, "for_items")
          info.merge(
            setup:,
            prepared_iterable:,
            iterable_c_name: c_name,
            iterable_ref: IR::Name.new(name: c_name, type: info[:iterable_type], pointer: false),
          )
        end

        index_c_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_c_name, type: @types.fetch("ptr_uint"), pointer: false)
        stop_value = collection_loop_stop_value(iterable_entries.first[:iterable_ref], iterable_entries.first[:iterable_type])

        while_env = duplicate_env(env)
        body = iterable_entries.map do |entry|
          item_value = collection_loop_item_value(entry[:iterable_ref], entry[:iterable_type], index_ref, entry[:element_type])
          loop_item_value = if ref_type?(entry[:binding_type])
                              IR::AddressOf.new(expression: item_value, type: entry[:binding_type])
                            else
                              item_value
                            end
          binding = entry[:binding]
          current_actual_scope(while_env[:scopes])[binding.name] = local_binding(type: entry[:binding_type], c_name: c_local_name(binding.name), mutable: false, pointer: false)
          IR::LocalDecl.new(name: binding.name, c_name: c_local_name(binding.name), type: entry[:binding_type], value: loop_item_value)
        end
        body.concat(lower_async_non_await_statements(
          statement.body,
          env: while_env,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
          active_defers:,
          loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
        ))
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        length_checks = iterable_entries.drop(1).map do |entry|
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: "!=",
              left: collection_loop_stop_value(entry[:iterable_ref], entry[:iterable_type]),
              right: stop_value,
              type: @types.fetch("bool"),
            ),
            then_body: [lower_fatal_statement("parallel for iterables must have matching lengths", env:)],
            else_body: nil,
          )
        end

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(target: index_ref, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
          body:,
        )

        stmts = [
          *iterable_entries.flat_map { |entry| entry[:setup] },
          *iterable_entries.map do |entry|
            IR::LocalDecl.new(name: entry[:iterable_c_name], c_name: entry[:iterable_c_name], type: entry[:iterable_type], value: lower_expression(entry[:prepared_iterable], env:, expected_type: entry[:iterable_type]))
          end,
          *length_checks,
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
                elsif ["+=", "-=", "*=", "/="].include?(statement.operator)
                  lower_contextual_expression(
                    prepared_value,
                    env:,
                    expected_type: target.type,
                    contextual_int_to_float: contextual_int_to_float_target?(target.type),
                  )
                else
                  lower_expression(prepared_value, env:, expected_type: target.type)
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
        expression_expected_type = if statement.expression.is_a?(AST::UnaryOp) && statement.expression.operator == "?"
                                     nil
                                   else
                                     infer_expression_type(statement.expression, env:)
                                   end
        prepared_setup, prepared_expression = prepare_expression_for_inline_lowering(
          statement.expression,
          env:,
          expected_type: expression_expected_type,
          allow_root_statement_foreign: true,
          allow_void_propagation: true,
        )
        lowered.concat(prepared_setup)

        if prepared_expression && (foreign_call = foreign_call_info(prepared_expression, env))
          setup, = lower_foreign_call_statement(
            foreign_call,
            env:,
            expected_type: foreign_call[:binding].type.return_type,
            statement_position: true,
            discard_result: true,
          )
          lowered.concat(setup)
        elsif prepared_expression
          lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env:), line: statement.line, source_path: @current_analysis_path)
        end

        lowered
      end

      def lower_async_return_statement(statement, env:, frame_expr:, raw_frame_expr:, async_info:, cleanup: [])
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

        if async_info[:result_type] != @types.fetch("void") && value && cleanup.any? && !cleanup_safe_return_expression?(prepared_value)
          lowered << IR::Assignment.new(
            target: async_frame_field_expression(frame_expr, "result", async_info[:result_type]),
            operator: "=",
            value: value,
          )
          lowered.concat(cleanup)
          lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
        else
          lowered.concat(cleanup)
          lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value:))
        end
        lowered
      end

      def lower_async_await_statement(statement, await_info:, env:, frame_expr:, raw_frame_expr:, resume_c_name:, async_info:, field_info: nil, cleanup: [], active_defers: [], loop_flow: nil)
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
              target: async_frame_field_expression(frame_expr, "state", @types.fetch("int")),
              operator: "=",
              value: IR::IntegerLiteral.new(value: await_info[:state], type: @types.fetch("int")),
            ),
            IR::ExpressionStmt.new(expression: set_waiter_call),
            IR::ReturnStmt.new(value: nil),
          ],
          else_body: nil,
        )
        lowered << IR::LabelStmt.new(name: async_state_label(resume_c_name, await_info[:state]))

        case statement
        when AST::LocalDecl
          storage_type = field_info[:storage_type]
          target = async_frame_field_expression(frame_expr, field_info[:field_name], storage_type)
          lowered << IR::Assignment.new(target:, operator: "=", value: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
          if statement.else_body
            else_env = duplicate_env(env)
            if statement.else_binding
              current_actual_scope(else_env[:scopes])[statement.else_binding.name] = local_binding(
                type: let_else_error_type(storage_type),
                storage_type:,
                c_name: async_frame_field_c_name(field_info[:field_name]),
                mutable: false,
                pointer: false,
                projection: :result_failure_error,
              )
            end
            else_body = if statements_contain_await?(statement.else_body, async_info)
              lower_async_cf_statements(
                statement.else_body,
                env: else_env,
                frame_expr:,
                raw_frame_expr:,
                resume_c_name:,
                async_info:,
                active_defers:,
                loop_flow:,
              )
            else
              lower_async_non_await_statements(
                statement.else_body,
                env: else_env,
                frame_expr:,
                raw_frame_expr:,
                async_info:,
                active_defers:,
                loop_flow:,
              )
            end
            lowered << IR::IfStmt.new(
              condition: let_else_failure_condition(target, storage_type),
              then_body: else_body,
              else_body: nil,
            )
          end
        when AST::Assignment
          lowered << IR::Assignment.new(target: lower_assignment_target(statement.target, env:), operator: statement.operator, value: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
        when AST::ExpressionStmt
          lowered << IR::ExpressionStmt.new(expression: take_result_call)
          lowered << IR::ExpressionStmt.new(expression: release_call)
        when AST::ReturnStmt
          if await_info[:result_type] == @types.fetch("void")
            lowered << IR::ExpressionStmt.new(expression: take_result_call)
            lowered << IR::ExpressionStmt.new(expression: release_call)
            lowered.concat(cleanup)
            lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
          else
            lowered << IR::Assignment.new(
              target: async_frame_field_expression(frame_expr, "result", async_info[:result_type]),
              operator: "=",
              value: take_result_call,
            )
            lowered << IR::ExpressionStmt.new(expression: release_call)
            lowered.concat(cleanup)
            lowered.concat(async_complete_statements(frame_expr:, raw_frame_expr:, async_info:, value: nil, result_already_stored: true))
          end
        end

        lowered
      end

      def lower_async_defer_cleanup(statement, env:, async_info:)
        body = if statement.body
                 statement.body
               elsif statement.expression
                 [AST::ExpressionStmt.new(expression: statement.expression, line: statement.line)]
               else
                 []
               end

        { body:, env: snapshot_env(env) }
      end

      def lower_async_cleanup_entries(local_defers, outer_defers, frame_expr:, raw_frame_expr:, async_info:)
        cleanup_entries = local_defers.reverse + outer_defers.reverse
        cleanup_entries.flat_map do |cleanup_entry|
          next [] if cleanup_entry[:body].empty?

          cleanup_env = duplicate_env(cleanup_entry[:env])
          if statements_contain_await?(cleanup_entry[:body], async_info)
            lower_async_cf_statements(
              cleanup_entry[:body],
              env: cleanup_env,
              frame_expr:,
              raw_frame_expr:,
              resume_c_name: async_info.fetch(:resume_c_name),
              async_info:,
              active_defers: [],
              loop_flow: nil,
            )
          else
            lower_async_non_await_statements(
              cleanup_entry[:body],
              env: cleanup_env,
              frame_expr:,
              raw_frame_expr:,
              async_info:,
              active_defers: [],
              loop_flow: nil,
            )
          end
        end
      end

      def async_return_context(return_type:, active_defers:, local_defers:, frame_expr:, raw_frame_expr:, async_info:, allow_return: true)
        {
          return_type:,
          active_defers:,
          local_defers:,
          allow_return:,
          frame_expr:,
          raw_frame_expr:,
          async_info:,
        }
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
        local_env[:return_context] = {
          return_type:,
          active_defers:,
          local_defers:,
          allow_return:,
        }

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
            storage_type = if statement.else_body
                             infer_expression_type(statement.value, env: local_env)
                           elsif statement.type
                             resolve_type_ref(statement.type)
                           else
                             infer_expression_type(statement.value, env: local_env)
                           end
            type = if statement.else_body
                     statement.type ? resolve_type_ref(statement.type) : let_else_success_type(storage_type)
                   else
                     storage_type
                   end
            c_name = let_else_storage_c_name(statement, local_env)
            decl_name = bind_let_else_local?(statement) ? statement.name : c_name
            prepared_setup = []
            prepared_value = statement.value
            prepared_cleanups = []
            emitted_decl = false
            if statement.value
              prepared_setup, prepared_value, prepared_cleanups = prepare_expression_with_cleanups(
                statement.value,
                env: local_env,
                expected_type: storage_type,
                allow_root_statement_foreign: true,
                materialize_array_calls: !array_type?(storage_type),
              )
              lowered.concat(prepared_setup)
            end
            if prepared_value && (foreign_call = foreign_call_info(prepared_value, local_env))
              setup, value, call_type, release_assignments, cleanup_statements = lower_foreign_call_components(
                foreign_call,
                env: local_env,
                expected_type: storage_type,
                statement_position: false,
              )
              lowered.concat(setup)
              raise LoweringError, "foreign call used to initialize #{statement.name} must return a value" if call_type == @types.fetch("void")
              raise LoweringError, "consuming foreign calls must return void" unless release_assignments.empty?

              lowered << IR::LocalDecl.new(name: decl_name, c_name:, type: storage_type, value:, line: statement.line, source_path: @current_analysis_path)
              lowered.concat(cleanup_statements)
              emitted_decl = true
            elsif prepared_value.is_a?(AST::ProcExpr)
              setup, value = lower_proc_expression_for_local(prepared_value, env: local_env, local_name: statement.name, proc_type: storage_type)
              lowered.concat(setup)
            elsif prepared_value
              value = lower_contextual_expression(
                prepared_value,
                env: local_env,
                expected_type: storage_type,
                contextual_int_to_float: statement.type && contextual_int_to_float_target?(type),
              )
            else
              value = IR::ZeroInit.new(type: storage_type)
            end
            if bind_let_else_local?(statement)
              current_actual_scope(local_env[:scopes])[statement.name] = local_binding(
                type:,
                storage_type:,
                c_name:,
                mutable: statement.kind == :var,
                pointer: false,
                projection: statement.else_body ? let_else_binding_projection(storage_type) : nil,
                cstr_backed: cstr_backed_storage_value?(storage_type, prepared_value, local_env),
                cstr_list_backed: cstr_list_backed_storage_value?(storage_type, prepared_value, local_env),
                const_value: statement.else_body ? nil : statement.kind == :let && prepared_value ? compile_time_const_value(prepared_value, env: local_env) : nil,
              )
            end
            lowered << IR::LocalDecl.new(name: decl_name, c_name:, type: storage_type, value:, line: statement.line, source_path: @current_analysis_path) unless emitted_decl
            if statement.else_body
              else_env = if statement.else_binding
                           duplicate_env(local_env).tap do |env_with_error|
                             current_actual_scope(env_with_error[:scopes])[statement.else_binding.name] = local_binding(
                               type: let_else_error_type(storage_type),
                               storage_type:,
                               c_name:,
                               mutable: false,
                               pointer: false,
                               projection: :result_failure_error,
                             )
                           end
                         else
                           local_env
                         end
              else_body = lower_block(
                statement.else_body,
                env: else_env,
                active_defers: active_defers + local_defers + prepared_cleanups,
                return_type:,
                loop_flow: nested_loop_flow(loop_flow, local_defers),
                allow_return:,
              )
              local_ref = IR::Name.new(name: c_name, type: storage_type, pointer: false)
              lowered << IR::IfStmt.new(
                condition: let_else_failure_condition(local_ref, storage_type),
                then_body: else_body,
                else_body: nil,
              )
            end
            local_defers.concat(prepared_cleanups)
            if contains_proc_storage_type?(storage_type)
              local_value = IR::Name.new(name: c_name, type: storage_type, pointer: false)
              # Use guarded release so zero-initialized var locals are safe (invoke == NULL guard).
              local_defers << lower_proc_contained_guarded_release_statements(local_value, storage_type)
              if statement.value && !expression_contains_proc_expr?(statement.value)
                lowered.concat(lower_proc_contained_retain_statements(local_value, storage_type))
              end
            end
          when AST::Assignment
            if statement.operator == "=" &&
               statement.target.is_a?(AST::IndexAccess) &&
               statement.target.index.is_a?(AST::RangeExpr) &&
               statement.value.is_a?(AST::ExpressionList)
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
              materialize_array_calls: !array_type?(target.type),
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
                      elsif ["+=", "-=", "*=", "/="].include?(statement.operator)
                        lower_contextual_expression(
                          prepared_value,
                          env: local_env,
                          expected_type: target.type,
                          contextual_int_to_float: contextual_int_to_float_target?(target.type),
                        )
                      else
                        lower_expression(prepared_value, env: local_env, expected_type: target.type)
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

            if scrutinee_type.is_a?(Types::Variant) &&
               statement.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
               !duplicable_foreign_argument_expression?(expression)
              scrutinee_c_name = fresh_c_temp_name(local_env, "match_value")
              lowered << IR::LocalDecl.new(name: scrutinee_c_name, c_name: scrutinee_c_name, type: scrutinee_type, value: expression)
              expression = IR::Name.new(name: scrutinee_c_name, type: scrutinee_type, pointer: false)
            end

            if scrutinee_type.is_a?(Types::Variant)
              kind_type = @types.fetch("int")
              kind_expr = IR::Member.new(receiver: expression, member: "kind", type: kind_type)
              arm_loop_flow = switch_loop_flow(loop_flow, local_defers)
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
                  loop_flow: arm_loop_flow,
                  allow_return:,
                )
                body = [binding_decl, *body].compact if binding_decl
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body:)
                else
                  arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                  IR::SwitchCase.new(value: IR::Name.new(name: enum_member_c_name(scrutinee_type, "kind_#{arm_name}"), type: kind_type, pointer: false), body:)
                end
              end
              lowered << IR::SwitchStmt.new(expression: kind_expr, cases:, exhaustive: true)
            else
              arm_loop_flow = switch_loop_flow(loop_flow, local_defers)
              cases = statement.arms.map do |arm|
                body = lower_block(
                  arm.body,
                  env: local_env,
                  active_defers: active_defers + local_defers,
                  return_type:,
                  loop_flow: arm_loop_flow,
                  allow_return:,
                )
                if wildcard_arm_pattern?(arm.pattern)
                  IR::SwitchDefaultCase.new(body:)
                else
                  value = lower_expression(arm.pattern, env: local_env, expected_type: scrutinee_type)
                  IR::SwitchCase.new(value:, body:)
                end
              end
              lowered << IR::SwitchStmt.new(expression:, cases:, exhaustive: true)
            end
            lowered.concat(expression_cleanups.flat_map(&:itself))
          when AST::StaticAssert
            lowered << lower_static_assert(statement, env: local_env)
          when AST::ForStmt
            lowered << lower_for_stmt(statement, env: local_env, active_defers: active_defers + local_defers, return_type:, allow_return:)
          when AST::WhileStmt
            lowered << lower_while_stmt(statement, env: local_env, active_defers: active_defers + local_defers, return_type:, allow_return:)
          when AST::PassStmt
            nil
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
                materialize_array_calls: !array_type?(return_type),
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
              raise LoweringError, "formatted string temporaries cannot be returned as borrowed text; use fmt.format(...) when ownership must escape"
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
            if (format_sink_statements = lower_explicit_format_sink_expression_statement(statement.expression, env: local_env, line: statement.line))
              lowered.concat(format_sink_statements)
              next
            end

            expression_expected_type = if statement.expression.is_a?(AST::UnaryOp) && statement.expression.operator == "?"
                                         nil
                                       else
                                         infer_expression_type(statement.expression, env: local_env)
                                       end
            prepared_setup, prepared_expression, prepared_cleanups = prepare_expression_with_cleanups(
              statement.expression,
              env: local_env,
              expected_type: expression_expected_type,
              allow_root_statement_foreign: true,
              allow_void_propagation: true,
            )
            lowered.concat(prepared_setup)
            if prepared_expression && (foreign_call = foreign_call_info(prepared_expression, local_env))
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
            elsif prepared_expression
              lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env: local_env), line: statement.line, source_path: @current_analysis_path)
              lowered.concat(prepared_cleanups.flat_map(&:itself))
            else
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
                        { "__mt_ref_count" => @types.fetch("ptr_uint") }.merge(captures.each_with_object({}) { |capture, fields| fields[capture[:field_name]] = capture[:type] }),
                      )
                      @synthetic_structs << IR::StructDecl.new(
                        name: env_struct_type.name,
                        c_name: env_struct_type.name,
                        fields: [IR::Field.new(name: "__mt_ref_count", type: @types.fetch("ptr_uint")), *captures.map { |capture| IR::Field.new(name: capture[:field_name], type: capture[:type]) }],
                        packed: false,
                        alignment: nil,
                      )

                      env_pointer_type = pointer_to(env_struct_type)
                      env_name = fresh_c_temp_name(env, "#{local_name}_env")
                      raw_allocation = IR::Call.new(
                        callee: "mt_async_alloc",
                        arguments: [IR::SizeofExpr.new(target_type: env_struct_type, type: @types.fetch("ptr_uint"))],
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
                        target: IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @types.fetch("ptr_uint")),
                        operator: "=",
                        value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint")),
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
        ref_count = IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @types.fetch("ptr_uint"))
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
            IR::Assignment.new(target: ref_count, operator: "-=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
            IR::IfStmt.new(
              condition: IR::Binary.new(operator: "==", left: ref_count, right: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")), type: @types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(
                  expression: IR::Call.new(
                    callee: "mt_async_free",
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
        ref_count = IR::Member.new(receiver: env_pointer, member: "__mt_ref_count", type: @types.fetch("ptr_uint"))
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
            IR::Assignment.new(target: ref_count, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint"))),
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
          statement.iterables.each { |iterable| collect_proc_captures_from_expression(iterable, env, local_scopes, captures) }
          collect_proc_captures_from_statements(statement.body, env, local_scopes + [statement.names.each_with_object({}) { |name, scope| scope[name] = true }], captures)
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
        when AST::MatchExpr
          collect_proc_captures_from_expression(expression.expression, env, local_scopes, captures)
          expression.arms.each do |arm|
            collect_proc_captures_from_expression(arm.pattern, env, local_scopes, captures)
            arm_scopes = arm.binding_name ? local_scopes + [{ arm.binding_name => true }] : local_scopes
            collect_proc_captures_from_expression(arm.value, env, arm_scopes, captures)
          end
        when AST::UnsafeExpr
          collect_proc_captures_from_expression(expression.expression, env, local_scopes, captures)
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
        when AST::UnsafeExpr
          expression_contains_proc_expr?(expression.expression)
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
        return lower_parallel_collection_for_stmt(statement, env:, active_defers:, return_type:, allow_return:) if statement.parallel?
        return lower_range_for_stmt(statement, env:, active_defers:, return_type:, allow_return:) if range_iterable?(statement.iterable)

        iterable_type = infer_expression_type(statement.iterable, env:)
        return lower_iterator_for_stmt(statement, env:, active_defers:, return_type:, allow_return:) if collection_loop_type(iterable_type).nil?

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
        raise LoweringError, "for loop expects start..stop, array[T, N], span[T], or an iterable with iter()/next(), got #{iterable_type}" unless element_type
        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        binding_type = collection_loop_binding_type(iterable_type, element_type) || element_type

        iterable_c_name = fresh_c_temp_name(env, "for_items")
        index_c_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        iterable_ref = IR::Name.new(name: iterable_c_name, type: iterable_type, pointer: false)
        index_ref = IR::Name.new(name: index_c_name, type: @types.fetch("ptr_uint"), pointer: false)

        item_value = if array_type?(iterable_type)
                       IR::Index.new(receiver: iterable_ref, index: index_ref, type: element_type)
                     else
                       data_ref = IR::Member.new(receiver: iterable_ref, member: "data", type: pointer_to(element_type))
                       IR::Index.new(receiver: data_ref, index: index_ref, type: element_type)
                     end

        stop_value = if array_type?(iterable_type)
                       IR::IntegerLiteral.new(value: array_length(iterable_type), type: @types.fetch("ptr_uint"))
                     else
                       IR::Member.new(receiver: iterable_ref, member: "len", type: @types.fetch("ptr_uint"))
                     end

        loop_item_value = if ref_type?(binding_type)
                            IR::AddressOf.new(expression: item_value, type: binding_type)
                          else
                            item_value
                          end

        while_env = duplicate_env(env)
        current_actual_scope(while_env[:scopes])[statement.name] = local_binding(type: binding_type, c_name: c_local_name(statement.name), mutable: false, pointer: false)

        body = [
          IR::LocalDecl.new(name: statement.name, c_name: c_local_name(statement.name), type: binding_type, value: loop_item_value),
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
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint")),
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

      def lower_parallel_collection_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        infos = statement.bindings.each_with_index.map do |binding, index|
          iterable = statement.iterables[index]
          iterable_type = infer_expression_type(iterable, env:)
          element_type = collection_loop_type(iterable_type)
          raise LoweringError, "parallel for loops expect arrays or spans for each iterable, got #{iterable_type}" unless element_type

          {
            binding:,
            iterable:,
            iterable_type:,
            element_type:,
            binding_type: collection_loop_binding_type(iterable_type, element_type) || element_type,
          }
        end

        iterable_entries = infos.map do |info|
          setup, prepared_iterable = prepare_expression_for_inline_lowering(info[:iterable], env:, expected_type: info[:iterable_type])
          c_name = fresh_c_temp_name(env, "for_items")
          info.merge(
            setup:,
            prepared_iterable:,
            iterable_c_name: c_name,
            iterable_ref: IR::Name.new(name: c_name, type: info[:iterable_type], pointer: false),
          )
        end

        index_c_name = fresh_c_temp_name(env, "for_index")
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")
        index_ref = IR::Name.new(name: index_c_name, type: @types.fetch("ptr_uint"), pointer: false)
        stop_value = collection_loop_stop_value(iterable_entries.first[:iterable_ref], iterable_entries.first[:iterable_type])

        while_env = duplicate_env(env)
        body = iterable_entries.map do |entry|
          item_value = collection_loop_item_value(entry[:iterable_ref], entry[:iterable_type], index_ref, entry[:element_type])
          loop_item_value = if ref_type?(entry[:binding_type])
                              IR::AddressOf.new(expression: item_value, type: entry[:binding_type])
                            else
                              item_value
                            end
          binding = entry[:binding]
          current_actual_scope(while_env[:scopes])[binding.name] = local_binding(type: entry[:binding_type], c_name: c_local_name(binding.name), mutable: false, pointer: false)
          IR::LocalDecl.new(name: binding.name, c_name: c_local_name(binding.name), type: entry[:binding_type], value: loop_item_value)
        end
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

        length_checks = iterable_entries.drop(1).map do |entry|
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: "!=",
              left: collection_loop_stop_value(entry[:iterable_ref], entry[:iterable_type]),
              right: stop_value,
              type: @types.fetch("bool"),
            ),
            then_body: [lower_fatal_statement("parallel for iterables must have matching lengths", env:)],
            else_body: nil,
          )
        end

        for_statement = IR::ForStmt.new(
          init: IR::LocalDecl.new(name: index_c_name, c_name: index_c_name, type: @types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))),
          condition: IR::Binary.new(operator: "<", left: index_ref, right: stop_value, type: @types.fetch("bool")),
          post: IR::Assignment.new(
            target: index_ref,
            operator: "+=",
            value: IR::IntegerLiteral.new(value: 1, type: @types.fetch("ptr_uint")),
          ),
          body:,
        )

        statements = [
          *iterable_entries.flat_map { |entry| entry[:setup] },
          *iterable_entries.map do |entry|
            IR::LocalDecl.new(
              name: entry[:iterable_c_name],
              c_name: entry[:iterable_c_name],
              type: entry[:iterable_type],
              value: lower_expression(entry[:prepared_iterable], env:, expected_type: entry[:iterable_type]),
            )
          end,
          *length_checks,
          for_statement,
        ]
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_iterator_for_stmt(statement, env:, active_defers:, return_type:, allow_return:)
        iterable_type = infer_expression_type(statement.iterable, env:)
        iterator_info = iterator_loop_info(iterable_type, env:)
        raise LoweringError, "for loop expects start..stop, array[T, N], span[T], or an iterable with iter()/next(), got #{iterable_type}" unless iterator_info

        iterable_setup, prepared_iterable = prepare_expression_for_inline_lowering(statement.iterable, env:, expected_type: iterable_type)
        iterator_c_name = fresh_c_temp_name(env, "for_iterator")
        iterator_name = iterator_c_name
        continue_label = fresh_c_temp_name(env, "loop_continue")
        break_label = fresh_c_temp_name(env, "loop_break")

        iter_call = AST::Call.new(
          callee: AST::MemberAccess.new(receiver: prepared_iterable, member: "iter"),
          arguments: [],
        )

        iterator_env = duplicate_env(env)
        current_actual_scope(iterator_env[:scopes])[iterator_name] = local_binding(
          type: iterator_info[:iterator_type],
          c_name: iterator_c_name,
          mutable: true,
          pointer: false,
        )

        loop_env = duplicate_env(iterator_env)
        current_actual_scope(loop_env[:scopes])[statement.name] = local_binding(
          type: iterator_info[:item_type],
          storage_type: iterator_info[:item_storage_type],
          c_name: c_local_name(statement.name),
          mutable: false,
          pointer: false,
        )

        next_call = AST::Call.new(
          callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "next"),
          arguments: [],
        )

        body = if iterator_info[:kind] == :nullable_item
                 item_ref = IR::Name.new(name: c_local_name(statement.name), type: iterator_info[:item_storage_type], pointer: false)
                 [
                   IR::LocalDecl.new(
                     name: statement.name,
                     c_name: c_local_name(statement.name),
                     type: iterator_info[:item_storage_type],
                     value: lower_expression(next_call, env: iterator_env, expected_type: iterator_info[:item_storage_type]),
                   ),
                   IR::IfStmt.new(
                     condition: IR::Binary.new(
                       operator: "==",
                       left: item_ref,
                       right: IR::NullLiteral.new(type: iterator_info[:item_storage_type]),
                       type: @types.fetch("bool"),
                     ),
                     then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
                     else_body: nil,
                   ),
                 ]
               else
                 ready_c_name = fresh_c_temp_name(env, "for_ready")
                 ready_ref = IR::Name.new(name: ready_c_name, type: @types.fetch("bool"), pointer: false)
                 current_call = AST::Call.new(
                   callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "current"),
                   arguments: [],
                 )
                 [
                   IR::LocalDecl.new(
                     name: ready_c_name,
                     c_name: ready_c_name,
                     type: @types.fetch("bool"),
                     value: lower_expression(next_call, env: iterator_env, expected_type: @types.fetch("bool")),
                   ),
                   IR::IfStmt.new(
                     condition: IR::Unary.new(operator: "not", operand: ready_ref, type: @types.fetch("bool")),
                     then_body: [loop_exit_statement(loop_exit_break(break_label), local_defers: [], outer_defers: [])],
                     else_body: nil,
                   ),
                   IR::LocalDecl.new(
                     name: statement.name,
                     c_name: c_local_name(statement.name),
                     type: iterator_info[:item_storage_type],
                     value: lower_expression(current_call, env: iterator_env, expected_type: iterator_info[:item_storage_type]),
                   ),
                 ]
               end
        body.concat(
          lower_block(
            statement.body,
            env: loop_env,
            active_defers:,
            return_type:,
            loop_flow: loop_flow(break_target: loop_exit_break(break_label), continue_target: loop_exit_continue(continue_label)),
            allow_return:,
          ),
        )
        body << IR::LabelStmt.new(name: continue_label) if contains_label_target?(body, continue_label)

        statements = [
          *iterable_setup,
          IR::LocalDecl.new(
            name: iterator_name,
            c_name: iterator_c_name,
            type: iterator_info[:iterator_type],
            value: lower_expression(iter_call, env:, expected_type: iterator_info[:iterator_type]),
          ),
          IR::WhileStmt.new(
            condition: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")),
            body:,
          ),
        ]
        statements << IR::LabelStmt.new(name: break_label) if contains_label_target?(body, break_label)

        IR::BlockStmt.new(body: statements)
      end

      def lower_range_index_assignment(statement, env:)
        range = statement.target.index
        start_val = range.start_expr.value
        receiver_type = infer_expression_type(statement.target.receiver, env:)
        element_type = infer_index_result_type(receiver_type, @types.fetch("ptr_uint"))

        receiver_setup, prepared_receiver = prepare_expression_for_inline_lowering(statement.target.receiver, env:, expected_type: receiver_type)
        statements = receiver_setup.dup

        statement.value.elements.each_with_index do |elem, i|
          index_ir = IR::IntegerLiteral.new(value: start_val + i, type: @types.fetch("ptr_uint"))
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
          lower_assignment_binding_target(binding)
        when AST::MemberAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          receiver = lower_expression(expression.receiver, env:)
          type = infer_expression_type(expression, env:)
          IR::Member.new(receiver:, member: member_c_name(receiver_type, expression.member), type:)
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

      def lower_assignment_binding_target(binding)
        storage_type = binding[:storage_type]
        visible_type = binding[:type]
        storage_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])

        case binding[:projection]
        when :result_success_value
          variant_binding_projection_expression(storage_ref, storage_type, "success", "value", visible_type)
        when :option_some_value
          variant_binding_projection_expression(storage_ref, storage_type, "some", "value", visible_type)
        else
          if visible_type == storage_type || (storage_type.is_a?(Types::Nullable) && storage_type.base == visible_type)
            IR::Name.new(name: binding[:c_name], type: visible_type, pointer: binding[:pointer])
          else
            storage_ref
          end
        end
      end

      def prepare_expression_with_cleanups(expression, env:, expected_type: nil, allow_root_statement_foreign: false, materialize_array_calls: true, allow_void_propagation: false)
        env[:prepared_expression_cleanups] ||= []
        start_index = env[:prepared_expression_cleanups].length
        setup, prepared_expression = prepare_expression_for_inline_lowering(
          expression,
          env:,
          expected_type:,
          allow_root_statement_foreign:,
          materialize_array_calls:,
          allow_void_propagation:,
        )
        cleanup_count = env[:prepared_expression_cleanups].length - start_index
        cleanups = cleanup_count.positive? ? env[:prepared_expression_cleanups].slice!(start_index, cleanup_count) : []
        [setup, prepared_expression, cleanups || []]
      end

      def prepare_expression_for_inline_lowering(expression, env:, expected_type: nil, allow_root_statement_foreign: false, materialize_array_calls: true, allow_void_propagation: false)
        return [[], expression] unless expression

        if expression.is_a?(AST::Call) &&
            (foreign_call = foreign_call_info(expression, env)) && !allow_root_statement_foreign &&
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
          return prepare_result_propagation_for_inline_lowering(expression, env:, allow_void_success: allow_void_propagation) if expression.operator == "?"

          operand_setup, operand = prepare_expression_for_inline_lowering(expression.operand, env:, expected_type:)
          [operand_setup, AST::UnaryOp.new(operator: expression.operator, operand:)]
        when AST::BinaryOp
          prepare_binary_expression_for_inline_lowering(expression, env:, expected_type:)
        when AST::IfExpr
          prepare_if_expression_for_inline_lowering(expression, env:, expected_type:)
        when AST::MatchExpr
          prepare_match_expression_for_inline_lowering(expression, env:, expected_type:)
        when AST::UnsafeExpr
          prepare_expression_for_inline_lowering(expression.expression, env:, expected_type:)
        when AST::Call
          prepare_call_expression_for_inline_lowering(
            expression,
            env:,
            expected_type:,
            allow_root_statement_foreign:,
            materialize_array_calls:,
          )
        when AST::ProcExpr
          proc_type = infer_expression_type(expression, env:, expected_type:)
          setup, value = lower_proc_expression_for_local(expression, env:, local_name: fresh_c_temp_name(env, "proc_expr"), proc_type: proc_type)
          materialize_prepared_expression(setup, value, env:, type: proc_type, prefix: "proc_expr")
        else
          [[], expression]
        end
      end

      def prepare_call_expression_for_inline_lowering(expression, env:, expected_type: nil, allow_root_statement_foreign: false, materialize_array_calls: true)
        kind, _callee_name, _receiver, callee_type, binding = resolve_callee(expression.callee, env, arguments: expression.arguments)

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
          argument_value = argument.value
          argument_value = wrap_task_expression_in_root_proc(argument_value, env:) if task_expression_root_proc_bridge?(argument_value, expected_arg_type, env:)
          argument_value = wrap_expression_in_ref_of(argument_value) if implicit_ref_argument_bridge?(argument_value, expected_arg_type, env:)
          setup, prepared_value = prepare_expression_for_inline_lowering(argument_value, env:, expected_type: expected_arg_type)
          argument_setup.concat(setup)
          AST::Argument.new(name: argument.name, value: prepared_value)
        end

        prepared_call = AST::Call.new(callee:, arguments:)
        return [callee_setup + argument_setup, prepared_call] unless materialize_array_calls && callee_type.respond_to?(:return_type) && array_type?(callee_type.return_type)

        call_type = infer_expression_type(prepared_call, env:, expected_type:)
        materialize_prepared_expression(
          callee_setup + argument_setup,
          lower_expression(prepared_call, env:, expected_type: call_type),
          env:,
          type: call_type,
          prefix: "array_call",
        )
      end

      def prepare_format_string_expression_for_inline_lowering(format_string, env:)
        unless format_string_has_dynamic_parts?(format_string)
          return [[], AST::StringLiteral.new(value: format_string_static_text(format_string), cstring: false)]
        end

        setup, temp_name = build_dynamic_format_string_temp_setup(format_string, env:)
        temp_value = IR::Name.new(name: temp_name, type: @types.fetch("str"), pointer: false)
        (env[:prepared_expression_cleanups] ||= []) << [
          IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: "mt_format_str_release",
              arguments: [temp_value],
              type: @types.fetch("void"),
            ),
          ),
        ]

        [setup, AST::Identifier.new(name: temp_name)]
      end

      def build_dynamic_format_string_temp_setup(format_string, env:)
        string_type = @types.fetch("str")
        temp_name = fresh_c_temp_name(env, "fmt_string")
        total_len_name = fresh_c_temp_name(env, "fmt_total_len")
        offset_name = fresh_c_temp_name(env, "fmt_offset")
        register_prepared_temp!(env, temp_name, string_type, cstr_backed: true)
        total_len_value = IR::Name.new(name: total_len_name, type: @types.fetch("ptr_uint"), pointer: false)
        result_value = IR::Name.new(name: temp_name, type: string_type, pointer: false)
        offset_value = IR::Name.new(name: offset_name, type: @types.fetch("ptr_uint"), pointer: false)

        setup, format_parts = build_dynamic_format_string_parts(format_string, env:)
        literal_capacity = format_parts.sum { |part| part[:kind] == :text ? part[:value].bytesize : 0 }

        setup << IR::LocalDecl.new(
          name: total_len_name,
          c_name: total_len_name,
          type: @types.fetch("ptr_uint"),
          value: IR::IntegerLiteral.new(value: literal_capacity, type: @types.fetch("ptr_uint")),
        )

        format_parts.each do |part|
          next if part[:kind] == :text

          setup << IR::Assignment.new(
            target: total_len_value,
            operator: "=",
            value: IR::Binary.new(
              operator: "+",
              left: total_len_value,
              right: format_string_part_length_expression(part, env:),
              type: @types.fetch("ptr_uint"),
            ),
          )
        end

        setup << IR::LocalDecl.new(
          name: temp_name,
          c_name: temp_name,
          type: string_type,
          value: IR::Call.new(callee: "mt_format_str_make", arguments: [total_len_value], type: string_type),
        )
        setup << IR::LocalDecl.new(
          name: offset_name,
          c_name: offset_name,
          type: @types.fetch("ptr_uint"),
          value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")),
        )

        format_parts.each do |part|
          setup.concat(format_string_part_append_statements(part, result_value, offset_value, env:))
        end

        [setup, temp_name]
      end

      def format_string_static_text(format_string)
        format_string.parts.filter_map do |part|
          next unless part.is_a?(AST::FormatTextPart)

          part.value
        end.join
      end

      def build_dynamic_format_string_parts(format_string, env:)
        format_parts = []
        setup = []

        format_string.parts.each do |part|
          if part.is_a?(AST::FormatTextPart)
            next if part.value.empty?

            format_parts << { kind: :text, value: part.value }
            next
          end

          expression_setup, prepared_expression = prepare_expression_for_inline_lowering(part.expression, env:)
          setup.concat(expression_setup)
          value_type = infer_expression_type(prepared_expression, env:)

          if part.format_spec
            case part.format_spec[:kind]
            when :precision
              precision = part.format_spec[:value]
              append_argument_type = @types.fetch("double")
              parameter_c_name = fresh_c_temp_name(env, "fmt_part")
              setup << IR::LocalDecl.new(
                name: parameter_c_name,
                c_name: parameter_c_name,
                type: append_argument_type,
                value: cast_expression(
                  lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                  append_argument_type,
                ),
              )
              format_parts << {
                kind: :precision_expression,
                append_function_name: "append_double_precision",
                parameter_c_name: parameter_c_name,
                parameter_type: append_argument_type,
                precision: precision,
              }
            when :hex
              append_function_name, append_argument_type = format_string_hex_append_plan(value_type, uppercase: part.format_spec[:uppercase])
              parameter_c_name = fresh_c_temp_name(env, "fmt_part")
              setup << IR::LocalDecl.new(
                name: parameter_c_name,
                c_name: parameter_c_name,
                type: append_argument_type,
                value: cast_expression(
                  lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                  append_argument_type,
                ),
              )
              format_parts << {
                kind: :expression,
                append_function_name: append_function_name,
                parameter_c_name: parameter_c_name,
                parameter_type: append_argument_type,
              }
            when :oct
              append_function_name, append_argument_type = format_string_oct_append_plan(value_type, uppercase: part.format_spec[:uppercase])
              parameter_c_name = fresh_c_temp_name(env, "fmt_part")
              setup << IR::LocalDecl.new(
                name: parameter_c_name,
                c_name: parameter_c_name,
                type: append_argument_type,
                value: cast_expression(
                  lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                  append_argument_type,
                ),
              )
              format_parts << {
                kind: :expression,
                append_function_name: append_function_name,
                parameter_c_name: parameter_c_name,
                parameter_type: append_argument_type,
              }
            when :bin
              append_function_name, append_argument_type = format_string_bin_append_plan(value_type, uppercase: part.format_spec[:uppercase])
              parameter_c_name = fresh_c_temp_name(env, "fmt_part")
              setup << IR::LocalDecl.new(
                name: parameter_c_name,
                c_name: parameter_c_name,
                type: append_argument_type,
                value: cast_expression(
                  lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                  append_argument_type,
                ),
              )
              format_parts << {
                kind: :expression,
                append_function_name: append_function_name,
                parameter_c_name: parameter_c_name,
                parameter_type: append_argument_type,
              }
            else
              raise LoweringError, "unsupported format spec #{part.format_spec.inspect}"
            end
          else
            append_plan = format_string_append_plan(value_type, context: "formatted string interpolation of #{value_type}")
            parameter_c_name = fresh_c_temp_name(env, "fmt_part")
            setup << IR::LocalDecl.new(
              name: parameter_c_name,
              c_name: parameter_c_name,
              type: append_plan[:append_argument_type],
              value: cast_expression(
                lower_contextual_expression(prepared_expression, env:, expected_type: value_type),
                append_plan[:append_argument_type],
              ),
            )

            if append_plan[:kind] == :custom
              register_prepared_temp!(env, parameter_c_name, append_plan[:append_argument_type])
              part_info = {
                kind: :custom_expression,
                parameter_c_name: parameter_c_name,
                parameter_type: append_plan[:append_argument_type],
                format_binding: append_plan[:binding],
                append_output_type: append_plan[:append_output_type],
              }
              expected_length_c_name = fresh_c_temp_name(env, "fmt_part_len")
              setup << IR::LocalDecl.new(
                name: expected_length_c_name,
                c_name: expected_length_c_name,
                type: @types.fetch("ptr_uint"),
                value: IR::Call.new(
                  callee: append_plan[:binding].length_callee_name,
                  arguments: [format_string_custom_receiver_argument(part_info, hook: :length, env:)],
                  type: @types.fetch("ptr_uint"),
                ),
              )
              format_parts << part_info.merge(expected_length_c_name:)
            else
              format_parts << {
                kind: :expression,
                append_function_name: append_plan[:append_function_name],
                parameter_c_name: parameter_c_name,
                parameter_type: append_plan[:append_argument_type],
              }
            end
          end
        end

        [setup, format_parts]
      end

      def format_string_has_dynamic_parts?(format_string)
        format_string.parts.any? { |part| part.is_a?(AST::FormatExprPart) }
      end

      def string_builder_type?(type)
        type.respond_to?(:name) && type.respond_to?(:module_name) && type.name == "String" && type.module_name == "std.string"
      end

      def string_builder_ref_type?(type)
        ref_type?(type) && string_builder_type?(referenced_type(type))
      end

      def explicit_format_sink_call_info(expression, env)
        return unless expression.is_a?(AST::Call)

        kind, _callee_name, receiver, callee_type, callee_binding = resolve_callee(expression.callee, env, arguments: expression.arguments)

        case kind
        when :function
          return unless callee_binding&.owner&.module_name == "std.fmt"
          return unless expression.arguments.length == 2

          operation = case callee_binding.name
                      when "append_format"
                        :append
                      when "assign_format"
                        :assign
                      end
          return unless operation

          format_string = expression.arguments.fetch(1).value
          return unless format_string.is_a?(AST::FormatString)

          {
            operation:,
            sink_expression: expression.arguments.fetch(0).value,
            sink_expected_type: callee_type.params.fetch(0).type,
            format_string:,
            sink_kind: :string,
            method_call: false,
            callee_type:,
            callee_binding:,
          }
        when :method
          return unless callee_binding&.owner&.module_name == "std.string"
          return unless string_builder_type?(callee_type.receiver_type)
          return unless expression.arguments.length == 1

          operation = case callee_binding.name
                      when "append_format"
                        :append
                      when "assign_format"
                        :assign
                      end
          return unless operation

          format_string = expression.arguments.fetch(0).value
          return unless format_string.is_a?(AST::FormatString)

          {
            operation:,
            sink_expression: receiver,
            sink_expected_type: callee_type.receiver_type,
            format_string:,
            sink_kind: :string,
            method_call: true,
            callee_type:,
            callee_binding:,
          }
        when :str_buffer_append_format, :str_buffer_assign_format
          return unless expression.arguments.length == 1

          format_string = expression.arguments.fetch(0).value
          return unless format_string.is_a?(AST::FormatString)

          {
            operation: kind == :str_buffer_assign_format ? :assign : :append,
            sink_expression: receiver,
            sink_expected_type: callee_type.receiver_type,
            format_string:,
            sink_kind: :str_buffer,
            method_call: false,
            callee_type:,
            callee_binding: nil,
          }
        end
      end

      def explicit_format_sink_target(info, prepared_sink_expression, env:)
        case info[:sink_kind]
        when :string
          sink_value = if info[:method_call]
                         lower_method_receiver_argument(prepared_sink_expression, info[:callee_type], info[:callee_binding], env:)
                       else
                         lower_contextual_expression(prepared_sink_expression, env:, expected_type: info[:sink_expected_type])
                       end

          { kind: :string, value: sink_value }
        when :str_buffer
          lowered_receiver = lower_expression(prepared_sink_expression, env:)
          {
            kind: :str_buffer,
            receiver: lowered_receiver,
            data_pointer: lower_str_buffer_data_pointer_from_lowered(lowered_receiver),
            len_pointer: lower_str_buffer_len_pointer_from_lowered(lowered_receiver),
            dirty_pointer: lower_str_buffer_dirty_pointer_from_lowered(lowered_receiver),
            capacity: IR::IntegerLiteral.new(value: str_buffer_capacity(lowered_receiver.type), type: @types.fetch("ptr_uint")),
          }
        else
          raise LoweringError, "unsupported explicit format sink #{info[:sink_kind]}"
        end
      end

      def explicit_format_sink_target_buffer_view(sink_target)
        case sink_target[:kind]
        when :string
          sink_target[:value]
        when :str_buffer
          IR::AggregateLiteral.new(
            type: @types.fetch("str"),
            fields: [
              IR::AggregateField.new(name: "data", value: sink_target[:data_pointer]),
              IR::AggregateField.new(name: "len", value: sink_target[:capacity]),
            ],
          )
        else
          raise LoweringError, "unsupported explicit format sink #{sink_target[:kind]}"
        end
      end

      def lower_explicit_format_sink_expression_statement(expression, env:, line:)
        info = explicit_format_sink_call_info(expression, env)
        return unless info

        sink_setup, prepared_sink_expression, sink_cleanups = prepare_expression_with_cleanups(
          info[:sink_expression],
          env:,
          expected_type: info[:sink_expected_type],
          allow_root_statement_foreign: true,
        )
        sink_target = explicit_format_sink_target(info, prepared_sink_expression, env:)

        unless format_string_has_dynamic_parts?(info[:format_string])
          return sink_setup + [
            IR::ExpressionStmt.new(
              expression: explicit_format_sink_runtime_call(
                operation: info[:operation],
                sink_target:,
                text_value: IR::StringLiteral.new(
                  value: format_string_static_text(info[:format_string]),
                  type: @types.fetch("str"),
                  cstring: false,
                ),
              ),
              line:,
              source_path: @current_analysis_path,
            ),
            *sink_cleanups.flat_map(&:itself),
          ]
        end

        format_cleanup_start = (env[:prepared_expression_cleanups] ||= []).length
        format_setup, format_parts = build_dynamic_format_string_parts(info[:format_string], env:)
        format_cleanup_count = env[:prepared_expression_cleanups].length - format_cleanup_start
        format_cleanups = format_cleanup_count.positive? ? env[:prepared_expression_cleanups].slice!(format_cleanup_start, format_cleanup_count) : []
        copied_part_setup, copied_parts, copied_part_cleanups = copy_explicit_format_sink_str_parts(
          format_parts,
          env:,
          sink_kind: info[:sink_kind],
        )

        sink_statements = sink_setup + format_setup + copied_part_setup
        case sink_target[:kind]
        when :string
          if info[:operation] == :assign
            sink_statements << IR::ExpressionStmt.new(
              expression: IR::Call.new(callee: "std_string_String_clear", arguments: [sink_target[:value]], type: @types.fetch("void")),
              line:,
              source_path: @current_analysis_path,
            )
          end

          copied_parts.each do |part|
            sink_statements << IR::ExpressionStmt.new(
              expression: explicit_format_sink_append_call(part, sink_value: sink_target[:value], env:),
              line:,
              source_path: @current_analysis_path,
            )
          end
        when :str_buffer
          if info[:operation] == :assign
            sink_statements << IR::ExpressionStmt.new(
              expression: IR::Call.new(
                callee: "mt_str_buffer_clear",
                arguments: [
                  sink_target[:data_pointer],
                  sink_target[:capacity],
                  sink_target[:len_pointer],
                  sink_target[:dirty_pointer],
                ],
                type: @types.fetch("void"),
              ),
              line:,
              source_path: @current_analysis_path,
            )
          end

          offset_name = fresh_c_temp_name(env, "fmt_sink_offset")
          offset_value = IR::Name.new(name: offset_name, type: @types.fetch("ptr_uint"), pointer: false)
          offset_init = if info[:operation] == :assign
                          IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint"))
                        else
                          IR::Call.new(
                            callee: "mt_str_buffer_len",
                            arguments: [
                              sink_target[:data_pointer],
                              sink_target[:capacity],
                              sink_target[:len_pointer],
                              sink_target[:dirty_pointer],
                            ],
                            type: @types.fetch("ptr_uint"),
                          )
                        end
          sink_statements << IR::LocalDecl.new(name: offset_name, c_name: offset_name, type: @types.fetch("ptr_uint"), value: offset_init)

          target_value = explicit_format_sink_target_buffer_view(sink_target)
          copied_parts.each do |part|
            sink_statements.concat(format_string_part_append_statements(part, target_value, offset_value, env:))
          end
          sink_statements << IR::Assignment.new(
            target: IR::Unary.new(operator: "*", operand: sink_target[:len_pointer], type: @types.fetch("ptr_uint")),
            operator: "=",
            value: offset_value,
          )
        else
          raise LoweringError, "unsupported explicit format sink #{sink_target[:kind]}"
        end

        sink_statements.concat(copied_part_cleanups)
        sink_statements.concat(sink_cleanups.flat_map(&:itself))
        sink_statements.concat(format_cleanups.flat_map(&:itself))
        sink_statements
      end

      def explicit_format_sink_runtime_call(operation:, sink_target:, text_value:)
        case sink_target[:kind]
        when :string
          callee = operation == :assign ? "std_string_String_assign" : "std_string_String_append"
          IR::Call.new(callee:, arguments: [sink_target[:value], text_value], type: @types.fetch("void"))
        when :str_buffer
          callee = operation == :assign ? "mt_str_buffer_assign" : "mt_str_buffer_append"
          IR::Call.new(
            callee:,
            arguments: [
              text_value,
              sink_target[:data_pointer],
              sink_target[:capacity],
              sink_target[:len_pointer],
              sink_target[:dirty_pointer],
            ],
            type: @types.fetch("void"),
          )
        else
          raise LoweringError, "unsupported explicit format sink #{sink_target[:kind]}"
        end
      end

      def copy_explicit_format_sink_str_parts(format_parts, env:, sink_kind:)
        setup = []
        cleanup = []

        copied_parts = format_parts.map do |part|
          next part unless part[:kind] == :expression

          should_copy = part[:append_function_name] == "append" ||
            (sink_kind == :str_buffer && part[:append_function_name] == "append_cstr")
          next part unless should_copy

          parameter = format_string_part_parameter_expression(part)
          copy_name = fresh_c_temp_name(env, "fmt_sink_str")
          copy_value = IR::Name.new(name: copy_name, type: @types.fetch("str"), pointer: false)
          register_prepared_temp!(env, copy_name, @types.fetch("str"), cstr_backed: true)

          length_value = if part[:append_function_name] == "append"
                           IR::Member.new(receiver: parameter, member: "len", type: @types.fetch("ptr_uint"))
                         else
                           IR::Call.new(callee: "mt_format_cstr_len", arguments: [parameter], type: @types.fetch("ptr_uint"))
                         end
          append_callee = part[:append_function_name] == "append" ? "mt_format_append_str" : "mt_format_append_cstr"

          setup << IR::LocalDecl.new(
            name: copy_name,
            c_name: copy_name,
            type: @types.fetch("str"),
            value: IR::Call.new(
              callee: "mt_format_str_make",
              arguments: [length_value],
              type: @types.fetch("str"),
            ),
          )
          setup << IR::ExpressionStmt.new(
            expression: IR::Call.new(
              callee: append_callee,
              arguments: [copy_value, IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")), parameter],
              type: @types.fetch("ptr_uint"),
            ),
          )
          cleanup << IR::ExpressionStmt.new(
            expression: IR::Call.new(callee: "mt_format_str_release", arguments: [copy_value], type: @types.fetch("void")),
          )

          part.merge(parameter_c_name: copy_name, parameter_type: @types.fetch("str"), append_function_name: "append")
        end

        [setup, copied_parts, cleanup]
      end

      def explicit_format_sink_append_call(part, sink_value:, env:)
        if part[:kind] == :text
          return IR::Call.new(
            callee: "std_string_String_append",
            arguments: [sink_value, IR::StringLiteral.new(value: part[:value], type: @types.fetch("str"), cstring: false)],
            type: @types.fetch("void"),
          )
        end

        parameter = format_string_part_parameter_expression(part)

        if part[:kind] == :precision_expression
          return IR::Call.new(
            callee: "std_fmt_append_double_precision",
            arguments: [sink_value, parameter, IR::IntegerLiteral.new(value: part[:precision], type: @types.fetch("int"))],
            type: @types.fetch("void"),
          )
        end

        if part[:kind] == :custom_expression
          return IR::Call.new(
            callee: part[:format_binding].append_callee_name,
            arguments: [
              format_string_custom_receiver_argument(part, hook: :append, env:),
              sink_value,
            ],
            type: @types.fetch("void"),
          )
        end

        callee = case part[:append_function_name]
                 when "append"
                   "std_string_String_append"
                 when "append_cstr"
                   "std_fmt_append_cstr"
                 else
                   "std_fmt_#{part[:append_function_name]}"
                 end

        IR::Call.new(callee:, arguments: [sink_value, parameter], type: @types.fetch("void"))
      end

      def format_string_part_length_expression(part, env:)
        parameter = format_string_part_parameter_expression(part)

        if part[:kind] == :precision_expression
          return IR::Call.new(
            callee: "mt_format_double_precision_len",
            arguments: [parameter, IR::IntegerLiteral.new(value: part[:precision], type: @types.fetch("int"))],
            type: @types.fetch("ptr_uint"),
          )
        end

        if part[:kind] == :custom_expression
          return IR::Name.new(name: part[:expected_length_c_name], type: @types.fetch("ptr_uint"), pointer: false)
        end

        case part[:append_function_name]
        when "append"
          IR::Member.new(receiver: parameter, member: "len", type: @types.fetch("ptr_uint"))
        when "append_cstr"
          IR::Call.new(callee: "mt_format_cstr_len", arguments: [parameter], type: @types.fetch("ptr_uint"))
        else
          IR::Call.new(callee: mt_format_length_c_name(part[:append_function_name]), arguments: [parameter], type: @types.fetch("ptr_uint"))
        end
      end

      def format_string_part_append_statements(part, result_value, offset_value, env:)
        if part[:kind] == :custom_expression
          output_type = part[:append_output_type]
          output_ref_type = Types::GenericInstance.new("ref", [output_type])
          output_value_name = fresh_c_temp_name(env, "fmt_part_output")
          output_value = IR::Name.new(name: output_value_name, type: output_type, pointer: false)
          output_len = IR::Member.new(receiver: output_value, member: "len", type: @types.fetch("ptr_uint"))
          expected_length = IR::Name.new(name: part[:expected_length_c_name], type: @types.fetch("ptr_uint"), pointer: false)
          data_pointer = format_string_result_data_pointer(result_value)
          slice_data_pointer = cast_expression(
            IR::Binary.new(operator: "+", left: data_pointer, right: offset_value, type: pointer_to(@types.fetch("char"))),
            output_type.field("data"),
          )

          return [
            IR::LocalDecl.new(
              name: output_value_name,
              c_name: output_value_name,
              type: output_type,
              value: IR::AggregateLiteral.new(
                type: output_type,
                fields: [
                  IR::AggregateField.new(name: "data", value: slice_data_pointer),
                  IR::AggregateField.new(
                    name: "len",
                    value: IR::IntegerLiteral.new(value: 0, type: output_type.field("len")),
                  ),
                  IR::AggregateField.new(name: "capacity", value: expected_length),
                  IR::AggregateField.new(
                    name: "owns_storage",
                    value: IR::BooleanLiteral.new(value: false, type: output_type.field("owns_storage")),
                  ),
                ],
              ),
            ),
            IR::ExpressionStmt.new(
              expression: IR::Call.new(
                callee: part[:format_binding].append_callee_name,
                arguments: [
                  format_string_custom_receiver_argument(part, hook: :append, env:),
                  IR::AddressOf.new(expression: output_value, type: output_ref_type),
                ],
                type: @types.fetch("void"),
              ),
            ),
            IR::IfStmt.new(
              condition: IR::Binary.new(operator: "!=", left: output_len, right: expected_length, type: @types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(
                  expression: IR::Call.new(
                    callee: "mt_fatal",
                    arguments: [
                      IR::StringLiteral.new(
                        value: "custom format hook length mismatch",
                        type: @types.fetch("cstr"),
                        cstring: true,
                      ),
                    ],
                    type: @types.fetch("void"),
                  ),
                ),
              ],
              else_body: nil,
            ),
            IR::Assignment.new(
              target: offset_value,
              operator: "=",
              value: IR::Binary.new(
                operator: "+",
                left: offset_value,
                right: output_len,
                type: @types.fetch("ptr_uint"),
              ),
            ),
            IR::Assignment.new(
              target: IR::Index.new(receiver: data_pointer, index: offset_value, type: @types.fetch("char")),
              operator: "=",
              value: IR::IntegerLiteral.new(value: 0, type: @types.fetch("char")),
            ),
          ]
        end

        [
          IR::Assignment.new(
            target: offset_value,
            operator: "=",
            value: format_string_part_append_expression(part, result_value, offset_value),
          ),
        ]
      end

      def format_string_part_append_expression(part, result_value, offset_value)
        if part[:kind] == :text
          return IR::Call.new(
            callee: "mt_format_append_str",
            arguments: [result_value, offset_value, IR::StringLiteral.new(value: part[:value], type: @types.fetch("str"), cstring: false)],
            type: @types.fetch("ptr_uint"),
          )
        end

        parameter = format_string_part_parameter_expression(part)

        if part[:kind] == :precision_expression
          return IR::Call.new(
            callee: "mt_format_append_double_precision",
            arguments: [result_value, offset_value, parameter, IR::IntegerLiteral.new(value: part[:precision], type: @types.fetch("int"))],
            type: @types.fetch("ptr_uint"),
          )
        end

        if part[:kind] == :custom_expression
          raise LoweringError, "custom format parts require statement lowering"
        end

        IR::Call.new(
          callee: mt_format_append_c_name(part[:append_function_name]),
          arguments: [result_value, offset_value, parameter],
          type: @types.fetch("ptr_uint"),
        )
      end

      def format_string_custom_receiver_argument(part, hook:, env:)
        binding = case hook
                  when :length
                    part[:format_binding].length_binding
                  when :append
                    part[:format_binding].append_binding
                  else
                    raise LoweringError, "unsupported custom format hook #{hook}"
                  end

        if env
          return lower_method_receiver_argument(AST::Identifier.new(name: part[:parameter_c_name]), binding.type, binding, env:)
        end

        IR::Name.new(name: part[:parameter_c_name], type: part[:parameter_type], pointer: false)
      end

      def format_string_result_data_pointer(result_value)
        IR::Member.new(receiver: result_value, member: "data", type: pointer_to(@types.fetch("char")))
      end

      def format_string_part_parameter_expression(part)
        IR::Name.new(name: part[:parameter_c_name], type: part[:parameter_type], pointer: false)
      end

      def format_string_append_plan(type, context:)
        return { kind: :builtin, append_function_name: "append", append_argument_type: @types.fetch("str") } if type == @types.fetch("str")
        return { kind: :builtin, append_function_name: "append_cstr", append_argument_type: @types.fetch("cstr") } if type == @types.fetch("cstr")
        return { kind: :builtin, append_function_name: "append_bool", append_argument_type: @types.fetch("bool") } if type == @types.fetch("bool")
        return { kind: :builtin, append_function_name: "append_float", append_argument_type: @types.fetch("float") } if type == @types.fetch("float")
        return { kind: :builtin, append_function_name: "append_double", append_argument_type: @types.fetch("double") } if type == @types.fetch("double")

        if type.is_a?(Types::Primitive) && type.integer?
          return { kind: :builtin, append_function_name: "append_int", append_argument_type: @types.fetch("int") } if %w[byte short int].include?(type.name)
          return { kind: :builtin, append_function_name: "append_uint", append_argument_type: @types.fetch("uint") } if %w[ubyte ushort uint].include?(type.name)
          return { kind: :builtin, append_function_name: "append_ptr_uint", append_argument_type: @types.fetch("ptr_uint") } if type.name == "ptr_uint"
          return { kind: :builtin, append_function_name: "append_long", append_argument_type: @types.fetch("long") } if %w[long ptr_int].include?(type.name)
          return { kind: :builtin, append_function_name: "append_ulong", append_argument_type: @types.fetch("ulong") } if type.name == "ulong"
        end

        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_append_plan(type.backing_type, context:)
        end

        if (custom_binding = resolve_explicit_format_binding(type, context:))
          return {
            kind: :custom,
            append_argument_type: type,
            binding: custom_binding,
            append_output_type: referenced_type(custom_binding.append_binding.type.params.first.type),
          }
        end

        raise LoweringError, "formatted string interpolation supports str, cstr, bool, numeric primitives, integer-backed enums/flags, and types implementing format_len()/append_format(output: ref[std.string.String]), got #{type}"
      end

      def format_string_hex_append_plan(type, uppercase:)
        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_hex_append_plan(type.backing_type, uppercase:)
        end

        unless type.is_a?(Types::Primitive) && type.integer?
          raise LoweringError, "format spec ':x' and ':X' require integer interpolation, got #{type}"
        end

        if %w[byte short int long ptr_int].include?(type.name)
          return [uppercase ? "append_long_hex_upper" : "append_long_hex", @types.fetch("long")]
        end

        if %w[ubyte ushort uint ulong ptr_uint].include?(type.name)
          return [uppercase ? "append_ulong_hex_upper" : "append_ulong_hex", @types.fetch("ulong")]
        end

        raise LoweringError, "format spec ':x' and ':X' require integer interpolation, got #{type}"
      end

      def format_string_oct_append_plan(type, uppercase:)
        _ = uppercase
        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_oct_append_plan(type.backing_type, uppercase:)
        end

        unless type.is_a?(Types::Primitive) && type.integer?
          raise LoweringError, "format spec ':o' and ':O' require integer interpolation, got #{type}"
        end

        if %w[byte short int long ptr_int].include?(type.name)
          return ["append_long_oct", @types.fetch("long")]
        end

        if %w[ubyte ushort uint ulong ptr_uint].include?(type.name)
          return ["append_ulong_oct", @types.fetch("ulong")]
        end

        raise LoweringError, "format spec ':o' and ':O' require integer interpolation, got #{type}"
      end

      def format_string_bin_append_plan(type, uppercase:)
        _ = uppercase
        if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
          return format_string_bin_append_plan(type.backing_type, uppercase:)
        end

        unless type.is_a?(Types::Primitive) && type.integer?
          raise LoweringError, "format spec ':b' and ':B' require integer interpolation, got #{type}"
        end

        if %w[byte short int long ptr_int].include?(type.name)
          return ["append_long_bin", @types.fetch("long")]
        end

        if %w[ubyte ushort uint ulong ptr_uint].include?(type.name)
          return ["append_ulong_bin", @types.fetch("ulong")]
        end

        raise LoweringError, "format spec ':b' and ':B' require integer interpolation, got #{type}"
      end

      def mt_format_length_c_name(name)
        {
          "append_bool" => "mt_format_bool_len",
          "append_float" => "mt_format_float_len",
          "append_double" => "mt_format_double_len",
          "append_ulong_hex" => "mt_format_ulong_hex_len",
          "append_ulong_hex_upper" => "mt_format_ulong_hex_len",
          "append_long_hex" => "mt_format_long_hex_len",
          "append_long_hex_upper" => "mt_format_long_hex_len",
          "append_ulong_oct" => "mt_format_ulong_oct_len",
          "append_long_oct" => "mt_format_long_oct_len",
          "append_ulong_bin" => "mt_format_ulong_bin_len",
          "append_long_bin" => "mt_format_long_bin_len",
          "append_int" => "mt_format_int_len",
          "append_uint" => "mt_format_uint_len",
          "append_ptr_uint" => "mt_format_ptr_uint_len",
          "append_long" => "mt_format_long_len",
          "append_ulong" => "mt_format_ulong_len",
        }.fetch(name)
      end

      def mt_format_append_c_name(name)
        {
          "append" => "mt_format_append_str",
          "append_cstr" => "mt_format_append_cstr",
          "append_bool" => "mt_format_append_bool",
          "append_float" => "mt_format_append_float",
          "append_double" => "mt_format_append_double",
          "append_ulong_hex" => "mt_format_append_ulong_hex",
          "append_ulong_hex_upper" => "mt_format_append_ulong_hex_upper",
          "append_long_hex" => "mt_format_append_long_hex",
          "append_long_hex_upper" => "mt_format_append_long_hex_upper",
          "append_ulong_oct" => "mt_format_append_ulong_oct",
          "append_long_oct" => "mt_format_append_long_oct",
          "append_ulong_bin" => "mt_format_append_ulong_bin",
          "append_long_bin" => "mt_format_append_long_bin",
          "append_int" => "mt_format_append_int",
          "append_uint" => "mt_format_append_uint",
          "append_ptr_uint" => "mt_format_append_ptr_uint",
          "append_long" => "mt_format_append_long",
          "append_ulong" => "mt_format_append_ulong",
        }.fetch(name)
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

      def prepare_match_expression_for_inline_lowering(expression, env:, expected_type: nil)
        scrutinee_type = infer_expression_type(expression.expression, env:)
        expression_setup, prepared_expression = prepare_expression_for_inline_lowering(expression.expression, env:, expected_type: scrutinee_type)
        result_type = infer_expression_type(expression, env:, expected_type:)
        result_name = fresh_c_temp_name(env, "match_expr")
        register_prepared_temp!(env, result_name, result_type)
        result_ref = IR::Name.new(name: result_name, type: result_type, pointer: false)
        setup = expression_setup + [IR::LocalDecl.new(name: result_name, c_name: result_name, type: result_type, value: IR::ZeroInit.new(type: result_type))]
        lowered_expression = lower_expression(prepared_expression, env:, expected_type: scrutinee_type)

        if scrutinee_type.is_a?(Types::Variant) &&
           expression.arms.any? { |arm| arm.binding_name && !wildcard_arm_pattern?(arm.pattern) } &&
           !duplicable_foreign_argument_expression?(lowered_expression)
          scrutinee_name = fresh_c_temp_name(env, "match_value")
          setup << IR::LocalDecl.new(name: scrutinee_name, c_name: scrutinee_name, type: scrutinee_type, value: lowered_expression)
          lowered_expression = IR::Name.new(name: scrutinee_name, type: scrutinee_type, pointer: false)
        end

        switch_expression = lowered_expression
        cases = if scrutinee_type.is_a?(Types::Variant)
                  kind_type = @types.fetch("int")
                  switch_expression = IR::Member.new(receiver: lowered_expression, member: "kind", type: kind_type)
                  expression.arms.map do |arm|
                    arm_env = duplicate_env(env)
                    binding_decl = if arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
                                     arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                                     if arm_name && scrutinee_type.has_payload?(arm_name)
                                       fields = scrutinee_type.arm(arm_name)
                                       payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
                                       data_expr = IR::Member.new(receiver: lowered_expression, member: "data", type: nil)
                                       arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
                                       binding_c = c_local_name(arm.binding_name)
                                       arm_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: binding_c, mutable: false, pointer: false)
                                       IR::LocalDecl.new(name: arm.binding_name, c_name: binding_c, type: payload_type, value: arm_expr)
                                     end
                                   end
                    value_setup, prepared_value = prepare_expression_for_inline_lowering(arm.value, env: arm_env, expected_type: result_type)
                    body = [binding_decl, *value_setup].compact
                    body << IR::Assignment.new(target: result_ref, operator: "=", value: lower_contextual_expression(prepared_value, env: arm_env, expected_type: result_type))
                    if wildcard_arm_pattern?(arm.pattern)
                      IR::SwitchDefaultCase.new(body: body)
                    else
                      arm_name = variant_match_arm_name_from_pattern(arm.pattern)
                      IR::SwitchCase.new(value: IR::Name.new(name: enum_member_c_name(scrutinee_type, "kind_#{arm_name}"), type: kind_type, pointer: false), body: body)
                    end
                  end
                else
                  expression.arms.map do |arm|
                    arm_env = duplicate_env(env)
                    value_setup, prepared_value = prepare_expression_for_inline_lowering(arm.value, env: arm_env, expected_type: result_type)
                    body = value_setup + [IR::Assignment.new(target: result_ref, operator: "=", value: lower_contextual_expression(prepared_value, env: arm_env, expected_type: result_type))]
                    if wildcard_arm_pattern?(arm.pattern)
                      IR::SwitchDefaultCase.new(body: body)
                    else
                      IR::SwitchCase.new(value: lower_expression(arm.pattern, env: arm_env, expected_type: scrutinee_type), body: body)
                    end
                  end
                end

        [setup + [IR::SwitchStmt.new(expression: switch_expression, cases: cases, exhaustive: true)], AST::Identifier.new(name: result_name)]
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

      def register_prepared_temp!(env, name, type, pointer: false, storage_type: nil, projection: nil, cstr_backed: false, cstr_list_backed: false)
        current_actual_scope(env[:scopes])[name] = local_binding(type:, storage_type:, c_name: name, mutable: false, pointer:, projection:, cstr_backed:, cstr_list_backed:)
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

        expression.arguments.drop(binding.type.params.length).each do |argument|
          return true if automatic_variadic_foreign_cstr_temp_needed?(argument.value, env:)
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
            lower_bound_identifier(binding)
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
          raise LoweringError, "propagation expressions must be prepared before direct lowering" if expression.operator == "?"

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
        when AST::MatchExpr
          raise LoweringError, "match expressions must be prepared before direct lowering"
        when AST::UnsafeExpr
          lower_expression(expression.expression, env:, expected_type: type)
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

        if (event_type = event_member_from_owner_type(owner_type, member))
          return event_type.hidden_field_name
        end

        owner_type.field_c_name(member)
      end

      def lower_call(expression, env:, type:)
        if (literal = lower_compile_time_literal(compile_time_const_value(expression, env:), type))
          return literal
        end

        kind, callee_name, receiver, callee_type, callee_binding = resolve_callee(expression.callee, env, arguments: expression.arguments)

        case kind
        when :function
          if callee_binding && foreign_function_binding?(callee_binding)
            raise LoweringError, "consuming foreign calls must be top-level expression statements" if foreign_call_consumes_binding?(callee_binding)

            return lower_foreign_call_inline(expression, callee_binding, env:, type:)
          end

          arguments = lower_call_arguments(expression.arguments, callee_type, env:)
          IR::Call.new(callee: callee_name, arguments:, type:)
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
        when :compile_time_builtin
          lower_compile_time_builtin_call(expression, builtin_name: callee_name, env:, type:)
        when :method
          receiver_arg = lower_method_receiver_argument(receiver, callee_type, callee_binding, env:)
          arguments = [receiver_arg, *lower_call_arguments(expression.arguments, callee_type, env:)]
          IR::Call.new(callee: callee_name, arguments:, type:)
        when :str_buffer_clear
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_clear",
            arguments: [
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_buffer_assign, :str_buffer_assign_format
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_assign",
            arguments: [
              lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: @types.fetch("str")),
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_buffer_append, :str_buffer_append_format
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_append",
            arguments: [
              lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: @types.fetch("str")),
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_buffer_len
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_len",
            arguments: [
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :str_buffer_capacity
          receiver_type = infer_expression_type(receiver, env:)
          IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: type)
        when :str_buffer_as_str
          receiver_type = infer_expression_type(receiver, env:)
          data_pointer = lower_str_buffer_data_pointer(receiver, env:)
          IR::AggregateLiteral.new(
            type:,
            fields: [
              IR::AggregateField.new(name: "data", value: data_pointer),
              IR::AggregateField.new(
                name: "len",
                value: IR::Call.new(
                  callee: "mt_str_buffer_len",
                  arguments: [
                    data_pointer,
                    IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @types.fetch("ptr_uint")),
                    lower_str_buffer_len_pointer(receiver, env:),
                    lower_str_buffer_dirty_pointer(receiver, env:),
                  ],
                  type: @types.fetch("ptr_uint"),
                ),
              ),
            ],
          )
        when :str_buffer_as_cstr
          receiver_type = infer_expression_type(receiver, env:)
          IR::Call.new(
            callee: "mt_str_buffer_as_cstr",
            arguments: [
              lower_str_buffer_data_pointer(receiver, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type: @types.fetch("ptr_uint")),
              lower_str_buffer_len_pointer(receiver, env:),
              lower_str_buffer_dirty_pointer(receiver, env:),
            ],
            type:,
          )
        when :event_subscribe, :event_subscribe_once, :event_unsubscribe, :event_emit, :event_wait
          event_type = infer_expression_type(receiver, env:)
          runtime = ensure_event_runtime(event_type)
          event_pointer = lower_event_storage_pointer(receiver, env:)

          case kind
          when :event_subscribe
            if expression.arguments.length == 2
              IR::Call.new(
                callee: runtime.fetch(:subscribe_stateful_c_name),
                arguments: [
                  event_pointer,
                  lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: runtime.fetch(:void_ptr)),
                  lower_contextual_expression(expression.arguments.fetch(1).value, env:, expected_type: runtime.fetch(:listener_type)),
                ],
                type:,
              )
            else
              IR::Call.new(
                callee: runtime.fetch(:subscribe_c_name),
                arguments: [
                  event_pointer,
                  lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: runtime.fetch(:listener_type)),
                ],
                type:,
              )
            end
          when :event_subscribe_once
            if expression.arguments.length == 2
              IR::Call.new(
                callee: runtime.fetch(:subscribe_once_stateful_c_name),
                arguments: [
                  event_pointer,
                  lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: runtime.fetch(:void_ptr)),
                  lower_contextual_expression(expression.arguments.fetch(1).value, env:, expected_type: runtime.fetch(:listener_type)),
                ],
                type:,
              )
            else
              IR::Call.new(
                callee: runtime.fetch(:subscribe_once_c_name),
                arguments: [
                  event_pointer,
                  lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: runtime.fetch(:listener_type)),
                ],
                type:,
              )
            end
          when :event_unsubscribe
            IR::Call.new(
              callee: runtime.fetch(:unsubscribe_c_name),
              arguments: [
                event_pointer,
                lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: @types.fetch("Subscription")),
              ],
              type:,
            )
          when :event_emit
            arguments = [event_pointer]
            if event_type.payload_type
              arguments << lower_contextual_expression(expression.arguments.fetch(0).value, env:, expected_type: event_type.payload_type)
            end
            IR::Call.new(callee: runtime.fetch(:emit_c_name), arguments:, type:)
          when :event_wait
            IR::Call.new(callee: runtime.fetch(:wait_c_name), arguments: [event_pointer], type:)
          end
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
                contextual_int_to_float: contextual_int_to_float_target?(field_type),
              ),
            )
          end
          IR::AggregateLiteral.new(type:, fields:)
        when :variant_arm_ctor
          _, _, _, variant_type, (_, arm_name) = resolve_callee(expression.callee, env, arguments: expression.arguments)
          arm_fields = variant_type.arm(arm_name)
          payload_fields = expression.arguments.map do |argument|
            field_type = arm_fields.fetch(argument.name)
            IR::AggregateField.new(
              name: argument.name,
              value: lower_contextual_expression(
                argument.value,
                env:,
                expected_type: field_type,
                contextual_int_to_float: contextual_int_to_float_target?(field_type),
              ),
            )
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
        when :hash
          resolution = resolve_hash_specialization(expression.callee, env:)
          argument = expression.arguments.fetch(0)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [lower_hash_operation_argument(argument.value, env:, target_type: resolution.target_type)],
            type:,
          )
        when :equal
          resolution = resolve_equal_specialization(expression.callee, env:)
          left = expression.arguments.fetch(0)
          right = expression.arguments.fetch(1)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_hash_operation_argument(left.value, env:, target_type: resolution.target_type),
              lower_hash_operation_argument(right.value, env:, target_type: resolution.target_type),
            ],
            type:,
          )
        when :order
          resolution = resolve_order_specialization(expression.callee, env:)
          left = expression.arguments.fetch(0)
          right = expression.arguments.fetch(1)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_hash_operation_argument(left.value, env:, target_type: resolution.target_type),
              lower_hash_operation_argument(right.value, env:, target_type: resolution.target_type),
            ],
            type:,
          )
        when :zero
          IR::ZeroInit.new(type:)
        when :fatal
          argument = expression.arguments.fetch(0)
          message_type = infer_expression_type(argument.value, env:)
          callee = message_type == @types.fetch("cstr") ? "mt_fatal" : "mt_fatal_str"
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
          argument_type = infer_expression_type(argument.value, env:)
          if ref_type?(argument_type)
            IR::Cast.new(target_type: type, expression: lower_expression(argument.value, env:), type:)
          else
            lower_addr_expression(argument.value, env:, target_type: type)
          end
        else
          raise LoweringError, "unsupported call kind #{kind}"
        end
      end

      def lower_method_receiver_argument(receiver, callee_type, callee_binding, env:)
        lowered_receiver = lower_expression(receiver, env:)
        declared_receiver_type = callee_type.receiver_type

        if pointer_lowered_method_receiver?(callee_type, callee_binding)
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

        return lowered_receiver if declared_receiver_type && pointer_type?(declared_receiver_type)

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

      def lower_hash_operation_argument(expression, env:, target_type:)
        actual_type = infer_expression_type(expression, env:)
        lowered_expression = lower_expression(expression, env:)
        pointer_type = const_pointer_to(target_type)

        if pointer_type?(actual_type) || ref_type?(actual_type)
          return cast_expression(lowered_expression, pointer_type)
        end

        return cast_expression(lowered_expression.operand, pointer_type) if lowered_expression.is_a?(IR::Unary) && lowered_expression.operator == "*"

        IR::AddressOf.new(expression: lowered_expression, type: pointer_type)
      end

      def lower_call_arguments(arguments, callee_type, env:)
        arguments.map.with_index do |argument, index|
          parameter = index < callee_type.params.length ? callee_type.params[index] : nil
          expected_type = parameter&.type
          external_call = callee_type.respond_to?(:external) && callee_type.external && !expected_type.nil?
          if external_call && parameter && %i[out inout].include?(parameter.passing_mode)
            next lower_foreign_pointer_argument_value(parameter, argument, env:)
          end

          lower_contextual_expression(
            argument.value,
            env:,
            expected_type:,
            external_numeric: external_call,
            contextual_int_to_float: expected_type && contextual_int_to_float_target?(expected_type) && !external_call,
          )
        end
      end

      def implicit_ref_argument_bridge?(expression, expected_type, env:)
        return false unless ref_type?(expected_type)

        actual_type = infer_expression_type(expression, env:)
        actual_type == referenced_type(expected_type) && addressable_storage_expression?(expression)
      end

      def task_expression_root_proc_bridge?(expression, expected_type, env:)
        return false unless task_root_proc_type?(expected_type)

        actual_type = infer_expression_type(expression, env:)
        actual_type.is_a?(Types::Task) && actual_type == expected_type.return_type
      end

      def wrap_task_expression_in_root_proc(expression, env:)
        task_type = infer_expression_type(expression, env:)
        AST::ProcExpr.new(
          params: [],
          return_type: ast_type_ref_for(task_type),
          body: [AST::ReturnStmt.new(value: expression)],
        )
      end

      def wrap_expression_in_ref_of(expression)
        AST::Call.new(
          callee: AST::Identifier.new(name: "ref_of"),
          arguments: [AST::Argument.new(name: nil, value: expression)],
        )
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

        previous_type_substitutions = @current_type_substitutions
        @current_type_substitutions = binding.type_substitutions

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
        lowered_call = append_variadic_foreign_call_arguments(
          lowered_call,
          call.arguments,
          binding.type,
          env:,
          lowered:,
          cleanup: cleanup_statements,
        )

        [lowered, lowered_call, call_type, release_assignments, cleanup_statements]
      ensure
        @current_type_substitutions = previous_type_substitutions
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

      def foreign_argument_expression(argument)
        if argument.value.is_a?(AST::UnaryOp) && ["out", "in", "inout"].include?(argument.value.operator)
          argument.value.operand
        else
          argument.value
        end
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

        len_expression = IR::Member.new(receiver: lowered_value, member: "len", type: @types.fetch("ptr_uint"))
        IR::AggregateLiteral.new(
          type: boundary_type,
          fields: [
            IR::AggregateField.new(name: "data", value: converted_data),
            IR::AggregateField.new(name: "len", value: len_expression),
          ],
        )
      end

      def lower_foreign_pointer_argument_value(parameter, argument, env:)
        slot_type = foreign_slot_boundary_value_type(parameter.type)
        operand = foreign_argument_expression(argument)
        address = lower_addr_expression(operand, env:, target_type: pointer_to(slot_type))

        converted = foreign_identity_projection_expression(address, parameter.boundary_type)
        return converted if converted

        raise LoweringError, "unsupported foreign pointer boundary mapping #{parameter.type} as #{parameter.boundary_type}"
      end

      def foreign_slot_boundary_value_type(type)
        if type.is_a?(Types::Nullable) && pointer_type?(type.base)
          return type.base
        end

        type
      end

      def prepare_foreign_in_argument(parameter, argument, source_env:, lowered:, env:)
        return argument unless parameter.passing_mode == :in

        operand = foreign_argument_expression(argument)
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
          value: AST::Identifier.new(name: temp_name),
        )
      end

      def lower_foreign_in_argument_value(parameter, argument, env:)
        address = lower_addr_expression(
          foreign_argument_expression(argument),
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

        if str_buffer_type?(public_type)
          return IR::Call.new(
            callee: "mt_str_buffer_prepare_write",
            arguments: [
              lower_str_buffer_data_pointer(argument.value, env:),
              IR::IntegerLiteral.new(value: str_buffer_capacity(public_type), type: @types.fetch("ptr_uint")),
              lower_str_buffer_dirty_pointer(argument.value, env:),
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
        previous_type_substitutions = @current_type_substitutions
        @current_type_substitutions = binding.type_substitutions

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

        expression.arguments.drop(binding.type.params.length).each do |argument|
          next unless automatic_variadic_foreign_cstr_temp_needed?(argument.value, env:)

          raise LoweringError, "foreign call #{binding.name} cannot be used inline because a variadic argument needs temporary foreign text storage; use it as a statement, local initializer, assignment, or return expression"
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          argument = expression.arguments.fetch(index)
          next unless parameter.passing_mode == :in
          next if addressable_storage_expression?(foreign_argument_expression(argument))

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
        lowered_expression = append_variadic_foreign_call_arguments(
          lowered_expression,
          expression.arguments,
          binding.type,
          env:,
        )

        converted = foreign_identity_projection_expression(lowered_expression, type)
        return converted if converted

        lowered_expression
      ensure
        @current_type_substitutions = previous_type_substitutions
      end

      def append_variadic_foreign_call_arguments(lowered_expression, arguments, function_type, env:, lowered: nil, cleanup: nil)
        return lowered_expression unless function_type.variadic

        extra_arguments = arguments.drop(function_type.params.length)
        return lowered_expression if extra_arguments.empty?
        return lowered_expression unless lowered_expression.is_a?(IR::Call)

        IR::Call.new(
          callee: lowered_expression.callee,
          arguments: lowered_expression.arguments + extra_arguments.map { |argument| lower_variadic_foreign_argument(argument, env:, lowered:, cleanup:) },
          type: lowered_expression.type,
        )
      end

      def lower_variadic_foreign_argument(argument, env:, lowered:, cleanup:)
        actual_type = infer_expression_type(argument.value, env:)
        return lower_contextual_expression(argument.value, env:, expected_type: nil) unless actual_type == @types.fetch("str")

        lowered_argument = lower_foreign_argument_value(
          Types::Parameter.new("__mt_variadic", actual_type, passing_mode: :plain, boundary_type: @types.fetch("cstr")),
          argument,
          env:,
        )
        return lowered_argument unless temporary_foreign_cstr_expression?(lowered_argument)

        raise LoweringError, "foreign variadic call cannot be used inline because an extra argument needs temporary foreign text storage; use it as a statement, local initializer, assignment, or return expression" unless lowered && cleanup

        temp_name = fresh_c_temp_name(env, "foreign_arg")
        lowered << IR::LocalDecl.new(
          name: temp_name,
          c_name: temp_name,
          type: @types.fetch("cstr"),
          value: lowered_argument,
        )
        cleanup << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: "mt_free_foreign_cstr_temp",
            arguments: [IR::Name.new(name: temp_name, type: @types.fetch("cstr"), pointer: false)],
            type: @types.fetch("void"),
          ),
        )
        IR::Name.new(name: temp_name, type: @types.fetch("cstr"), pointer: false)
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
          receiver_type = with_analysis_context(owner_analysis) do
            infer_expression_type(expression.receiver, env: mapping_env)
          end
          receiver = lower_inline_foreign_mapping_expression(
            expression.receiver,
            mapping_env:,
            replacements:,
            owner_analysis:,
          )
          IR::Member.new(receiver:, member: member_c_name(receiver_type, expression.member), type:)
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
        when :hash
          resolution = with_analysis_context(owner_analysis) do
            resolve_hash_specialization(expression.callee, env: mapping_env)
          end
          argument = expression.arguments.fetch(0)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_inline_hash_operation_argument(
                argument.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
            ],
            type:,
          )
        when :equal
          resolution = with_analysis_context(owner_analysis) do
            resolve_equal_specialization(expression.callee, env: mapping_env)
          end
          left = expression.arguments.fetch(0)
          right = expression.arguments.fetch(1)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_inline_hash_operation_argument(
                left.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
              lower_inline_hash_operation_argument(
                right.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
            ],
            type:,
          )
        when :order
          resolution = with_analysis_context(owner_analysis) do
            resolve_order_specialization(expression.callee, env: mapping_env)
          end
          left = expression.arguments.fetch(0)
          right = expression.arguments.fetch(1)
          IR::Call.new(
            callee: resolution.callee_name,
            arguments: [
              lower_inline_hash_operation_argument(
                left.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
              lower_inline_hash_operation_argument(
                right.value,
                mapping_env:,
                replacements:,
                owner_analysis:,
                target_type: resolution.target_type,
              ),
            ],
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
        when :str_buffer_capacity
          receiver_type = with_analysis_context(owner_analysis) do
            infer_expression_type(receiver, env: mapping_env)
          end
          IR::IntegerLiteral.new(value: str_buffer_capacity(receiver_type), type:)
        when :ptr_of
          argument = expression.arguments.fetch(0)
          argument_type = with_analysis_context(owner_analysis) do
            infer_expression_type(argument.value, env: mapping_env)
          end
          if ref_type?(argument_type)
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
            lower_addr_expression(
              argument.value,
              env: mapping_env,
              target_type: type,
            )
          end
        else
          raise LoweringError, "unsupported inline foreign mapping call kind #{kind}"
        end
      end

      def lower_inline_hash_operation_argument(expression, mapping_env:, replacements:, owner_analysis:, target_type:)
        actual_type = with_analysis_context(owner_analysis) do
          infer_expression_type(expression, env: mapping_env)
        end
        lowered_expression = lower_inline_foreign_mapping_expression(
          expression,
          mapping_env:,
          replacements:,
          owner_analysis:,
        )
        pointer_type = const_pointer_to(target_type)

        if pointer_type?(actual_type) || ref_type?(actual_type)
          return cast_expression(lowered_expression, pointer_type)
        end

        return cast_expression(lowered_expression.operand, pointer_type) if lowered_expression.is_a?(IR::Unary) && lowered_expression.operator == "*"

        IR::AddressOf.new(expression: lowered_expression, type: pointer_type)
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
        when AST::UnsafeExpr
          foreign_mapping_uses_inline_replacement?(expression.expression, replacements)
        else
          false
        end
      end

      def raw_pointer_argument_expression(operand)
        AST::Call.new(
          callee: AST::Identifier.new(name: "ptr_of"),
          arguments: [AST::Argument.new(name: nil, value: operand)],
        )
      end

      def foreign_function_binding?(binding)
        binding.ast.is_a?(AST::ForeignFunctionDecl)
      end

      def foreign_mapping_expression(decl)
        return decl.mapping unless foreign_mapping_auto_call_shorthand?(decl.mapping)

        AST::Call.new(
          callee: decl.mapping,
          arguments: decl.params.map { |param| AST::Argument.new(name: nil, value: AST::Identifier.new(name: param.name)) },
        )
      end

      def foreign_mapping_auto_call_shorthand?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess
          foreign_mapping_auto_call_shorthand?(expression.receiver)
        when AST::Specialization
          foreign_mapping_auto_call_shorthand?(expression.callee)
        else
          false
        end
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
        when AST::UnsafeExpr
          AST::UnsafeExpr.new(expression: substitute_foreign_mapping_expression(expression.expression, replacements))
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
        when AST::UnsafeExpr
          foreign_mapping_reference_counts(expression.expression, counts)
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

      def automatic_variadic_foreign_cstr_temp_needed?(expression, env:)
        return false if expression.is_a?(AST::StringLiteral) && !expression.cstring
        return false if cstr_backed_expression?(expression, env)

        infer_expression_type(expression, env:) == @types.fetch("str")
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
        len_type = @types.fetch("ptr_uint")
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
        len_type = @types.fetch("ptr_uint")

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
        if (materialized = materialize_pointer_backed_value(lowered, expected_type))
          return materialized
        end
        return lowered if lowered.type == expected_type
        return lower_direct_function_to_proc_expression(expression, lowered, env:, expected_type:) if direct_function_to_proc_contextual_compatibility?(expression, lowered.type, env:, expected_type:)
        return lower_str_buffer_to_span_expression(lowered, expected_type) if str_buffer_to_span_compatible?(lowered.type, expected_type)
        return lower_array_to_span_expression(lowered, expected_type) if array_to_span_compatible?(lowered.type, expected_type)
        return cast_expression(lowered, expected_type) if contextual_numeric_compatibility?(expression, lowered.type, expected_type, env:, external_numeric:, contextual_int_to_float:)

        lowered
      end

      def materialize_pointer_backed_value(lowered, expected_type)
        return nil unless lowered.is_a?(IR::Name) && lowered.pointer
        return nil unless lowered.type == expected_type
        return nil if ref_type?(expected_type)
        return nil if pointer_type?(expected_type)

        IR::Unary.new(operator: "*", operand: lowered, type: lowered.type)
      end

      def direct_function_to_proc_contextual_compatibility?(expression, actual_type, env:, expected_type:)
        return false unless actual_type.is_a?(Types::Function) && proc_type?(expected_type)
        return false unless direct_function_identity_expression?(expression, env)

        function_type_matches_proc_type?(actual_type, expected_type)
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
          callable_resolution = resolve_specialized_callable_binding(expression, env:)
          return false unless callable_resolution

          callable_kind, binding, = callable_resolution
          callable_kind == :function && !foreign_function_binding?(binding)
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
                  index: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")),
                  type: target_type.element_type,
                ),
                type: pointer_to(target_type.element_type),
              ),
            ),
            IR::AggregateField.new(
              name: "len",
              value: IR::IntegerLiteral.new(value: array_length(expression.type), type: @types.fetch("ptr_uint")),
            ),
          ],
        )
      end

      def lower_str_buffer_to_span_expression(expression, target_type)
        IR::AggregateLiteral.new(
          type: target_type,
          fields: [
            IR::AggregateField.new(
              name: "data",
              value: IR::Call.new(
                callee: "mt_str_buffer_prepare_write",
                arguments: [
                  lower_str_buffer_data_pointer_from_lowered(expression),
                  IR::IntegerLiteral.new(value: str_buffer_capacity(expression.type), type: @types.fetch("ptr_uint")),
                  lower_str_buffer_dirty_pointer_from_lowered(expression),
                ],
                type: pointer_to(target_type.element_type),
              ),
            ),
            IR::AggregateField.new(
              name: "len",
              value: IR::IntegerLiteral.new(value: str_buffer_storage_capacity(expression.type), type: @types.fetch("ptr_uint")),
            ),
          ],
        )
      end

      def contextual_numeric_compatibility?(expression, actual_type, expected_type, env:, external_numeric: false, contextual_int_to_float: false)
        return true if exact_compile_time_numeric_compatibility?(actual_type, expression, expected_type, env:)
        return true if integer_to_char_compatibility?(actual_type, expected_type)
        return true if external_numeric && external_numeric_compatibility?(actual_type, expected_type)
        return true if contextual_int_to_float && contextual_int_to_float_compatibility?(actual_type, expected_type)

        false
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
        when AST::UnsafeExpr
          cstr_backed_expression?(expression.expression, env)
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
        when AST::UnsafeExpr
          cstr_list_backed_expression?(expression.expression, env)
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
            storage_type = if statement.else_body
                             infer_expression_type(statement.value, env: simulated_env)
                           elsif statement.type
                             resolve_type_ref(statement.type)
                           else
                             infer_expression_type(statement.value, env: simulated_env)
                           end
            type = if statement.else_body
                     statement.type ? resolve_type_ref(statement.type) : let_else_success_type(storage_type)
                   else
                     storage_type
                   end
            unless let_else_discard_binding_syntax?(statement)
              current_actual_scope(simulated_env[:scopes])[statement.name] = local_binding(
                type:,
                storage_type:,
                c_name: c_local_name(statement.name),
                mutable: statement.kind == :var,
                pointer: false,
                projection: statement.else_body ? let_else_binding_projection(storage_type) : nil,
                cstr_backed: cstr_backed_storage_value?(storage_type, statement.value, simulated_env),
                cstr_list_backed: cstr_list_backed_storage_value?(storage_type, statement.value, simulated_env),
                const_value: statement.else_body ? nil : statement.kind == :let && statement.value ? compile_time_const_value(statement.value, env: simulated_env) : nil,
              )
            end
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

      def exact_compile_time_numeric_compatibility?(actual_type, expression, expected_type, env: nil)
        return false unless expected_type.is_a?(Types::Primitive) && expected_type.numeric?
        return false if actual_type.is_a?(Types::EnumBase)

        value = compile_time_const_value(expression, env:)
        return false unless value.is_a?(Numeric)

        numeric_constant_fits_type?(value, expected_type)
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
        if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "zero"
          return IR::ZeroInit.new(type:)
        end

        if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "default"
          resolution = resolve_default_specialization(expression, env:)
          return IR::Call.new(callee: resolution.callee_name, arguments: [], type:) if resolution.binding

          return IR::ZeroInit.new(type:)
        end

        if (literal = lower_compile_time_literal(compile_time_const_value(expression, env:), type))
          return literal
        end

        if (callable_resolution = resolve_specialized_callable_binding(expression, env:))
          callable_kind, function_binding, = callable_resolution
          raise LoweringError, "specialized method must be called" if callable_kind == :method

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
            callee_name = if binding.external
                            binding.name
                          else
                            function_binding_c_name(binding, module_name: @module_name)
                          end
            [ :function, callee_name, nil, binding.type, binding ]
          elsif callee.name == "fatal"
            [:fatal, nil, nil, nil]
          elsif callee.name == "ref_of"
            [:ref_of, nil, nil, nil]
          elsif callee.name == "const_ptr_of"
            [:const_ptr_of, nil, nil, nil]
          elsif callee.name == "read"
            [:read, nil, nil, nil]
          elsif callee.name == "ptr_of"
            [:ptr_of, nil, nil, nil]
          elsif callee.name == "field_of"
            [:compile_time_builtin, "field_of", nil, compile_time_builtin_function_type("field_of", arguments, env)]
          elsif callee.name == "callable_of"
            [:compile_time_builtin, "callable_of", nil, compile_time_builtin_function_type("callable_of", arguments, env)]
          elsif callee.name == "has_attribute"
            [:compile_time_builtin, "has_attribute", nil, compile_time_builtin_function_type("has_attribute", arguments, env)]
          elsif callee.name == "attribute_of"
            [:compile_time_builtin, "attribute_of", nil, compile_time_builtin_function_type("attribute_of", arguments, env)]
          elsif (type = @types[callee.name]).is_a?(Types::Struct) || type.is_a?(Types::StringView) || task_type?(type)
            [ :struct_literal, nil, nil, type ]
          else
            raise LoweringError, "unknown callee #{callee.name}"
          end
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @imports.key?(callee.receiver.name)
            imported_module = @imports.fetch(callee.receiver.name)
            if multiplayer_root_import_call?(callee, "rpc_descriptor")
              return [:compile_time_builtin, "rpc_descriptor", nil, multiplayer_rpc_descriptor_function_type]
            end

            if multiplayer_root_import_call?(callee, "rpc_payload_size")
              return [:compile_time_builtin, "rpc_payload_size", nil, multiplayer_rpc_payload_size_function_type]
            end

            if imported_module.name == "std.multiplayer.rpc" && callee.member == "dispatch_typed_payload"
              return [:compile_time_builtin, "rpc_dispatch_typed_payload", nil, multiplayer_rpc_typed_dispatch_function_type]
            end

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

            dispatch_receiver_type = method_dispatch_receiver_type(type_expr)
            method_entry_receiver_type = type_expr
            method_entry = @method_definitions[[type_expr, callee.member]]
            unless method_entry || dispatch_receiver_type == type_expr
              method_entry_receiver_type = dispatch_receiver_type
              method_entry = @method_definitions[[dispatch_receiver_type, callee.member]]
            end
            if method_entry
              method_analysis, method_ast = method_entry
              method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_ast.name)
              if method_binding.type.receiver_type.nil?
                method_binding = specialize_function_binding(method_binding, arguments, env, receiver_type: type_expr) if method_binding.type_params.any?
                return [:associated_method, function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: method_entry_receiver_type), nil, method_binding.type, method_binding]
              end
            end

            raise LoweringError, "unknown associated function #{type_expr}.#{callee.member}"
          end

          resolved_receiver_type = infer_method_receiver_type(callee.receiver, env:, member_name: callee.member)
          dispatch_receiver_type = method_dispatch_receiver_type(resolved_receiver_type)
          method_entry_receiver_type = resolved_receiver_type
          method_entry = @method_definitions[[resolved_receiver_type, callee.member]]
          unless method_entry || dispatch_receiver_type == resolved_receiver_type
            method_entry_receiver_type = dispatch_receiver_type
            method_entry = @method_definitions[[dispatch_receiver_type, callee.member]]
          end
          if method_entry
            method_analysis, method_ast = method_entry
            method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_ast.name)
            method_binding = specialize_function_binding(method_binding, arguments, env, receiver_type: resolved_receiver_type)
            return [
              :method,
              function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: method_entry_receiver_type),
              callee.receiver,
              method_binding.type,
              method_binding,
            ]
          end

          if (str_buffer_method = str_buffer_method_kind(resolved_receiver_type, callee.member))
            return [str_buffer_method, nil, callee.receiver, str_buffer_method_type(str_buffer_method, resolved_receiver_type)]
          end

          if (event_method = event_method_kind(resolved_receiver_type, callee.member))
            event_type = infer_expression_type(callee.receiver, env:)
            return [event_method, nil, callee.receiver, event_method_type(event_method, event_type)]
          end

          field_receiver_type = infer_field_receiver_type(callee.receiver, env:)
          member_type = field_receiver_type.respond_to?(:field) ? field_receiver_type.field(callee.member) : nil
          return [:callable_value, nil, nil, member_type, nil] if callable_type?(member_type)

          raise LoweringError, "unknown callee #{callee.receiver}.#{callee.member}"
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
            target_type = resolve_type_ref(callee.arguments.fetch(0).value)
            return [:cast, nil, nil, Types::Function.new("cast", params: [Types::Parameter.new("value", @types.fetch("int"))], return_type: target_type)]
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

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "hash"
            resolution = resolve_hash_specialization(callee, env:)
            return [:hash, resolution.callee_name, nil, Types::Function.new("hash", params: [Types::Parameter.new("value", resolution.target_type)], return_type: @types.fetch("uint")), resolution.binding]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "equal"
            resolution = resolve_equal_specialization(callee, env:)
            params = [
              Types::Parameter.new("left", resolution.target_type),
              Types::Parameter.new("right", resolution.target_type),
            ]
            return [:equal, resolution.callee_name, nil, Types::Function.new("equal", params:, return_type: @types.fetch("bool")), resolution.binding]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "order"
            resolution = resolve_order_specialization(callee, env:)
            params = [
              Types::Parameter.new("left", resolution.target_type),
              Types::Parameter.new("right", resolution.target_type),
            ]
            return [:order, resolution.callee_name, nil, Types::Function.new("order", params:, return_type: @types.fetch("int")), resolution.binding]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "attribute_arg"
            return [:compile_time_builtin, "attribute_arg", nil, compile_time_builtin_specialization_function_type(callee)]
          end

          if multiplayer_root_specialization_call?(callee, "state_descriptor")
            return [:compile_time_builtin, "state_descriptor", nil, multiplayer_state_descriptor_function_type]
          end

          if multiplayer_root_specialization_call?(callee, "state_wire_size")
            return [:compile_time_builtin, "state_wire_size", nil, multiplayer_state_wire_size_function_type]
          end

          if (callable_resolution = resolve_specialized_callable_binding(callee, env:))
            callable_kind, function_binding, receiver = callable_resolution
            if callable_kind == :method
              return [
                :method,
                function_binding_c_name(function_binding, module_name: function_binding.owner.module_name, receiver_type: function_binding.type.receiver_type),
                receiver,
                function_binding.type,
                function_binding,
              ]
            end

            if function_binding.external
              return [:function, function_binding.name, nil, function_binding.type, function_binding]
            end

            return [:function, function_binding_c_name(function_binding, module_name: function_binding.owner.module_name), nil, function_binding.type, function_binding]
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct_literal, nil, nil, specialized_type] if specialized_type.is_a?(Types::Struct) || task_type?(specialized_type)
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
            @types.fetch("int")
          end
        when AST::FloatLiteral
          if expected_type.is_a?(Types::Primitive) && expected_type.float?
            expected_type
          else
            @types.fetch("double")
          end
        when AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
          @types.fetch("ptr_uint")
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

            dispatch_receiver_type = method_dispatch_receiver_type(type_expr)
            method_entry_receiver_type = type_expr
            method_entry = @method_definitions[[type_expr, expression.member]]
            unless method_entry || dispatch_receiver_type == type_expr
              method_entry_receiver_type = dispatch_receiver_type
              method_entry = @method_definitions[[dispatch_receiver_type, expression.member]]
            end
            if method_entry
              method_analysis, method_ast = method_entry
              method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_ast.name)
              return method_binding.type if method_binding.type.receiver_type.nil?
            end
          end
          if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
            imported_module = @imports.fetch(expression.receiver.name)
            return imported_module.values.fetch(expression.member).type if imported_module.values.key?(expression.member)
            return imported_module.functions.fetch(expression.member).type if imported_module.functions.key?(expression.member)
          end
          receiver_type = infer_field_receiver_type(expression.receiver, env:)
          if (event_type = event_member_from_owner_type(receiver_type, expression.member))
            return event_type
          end
          return receiver_type.field(expression.member) if receiver_type.respond_to?(:field)

          raise LoweringError, "unknown member #{expression.member}"
        when AST::IndexAccess
          receiver_type = infer_expression_type(expression.receiver, env:)
          index_type = infer_expression_type(expression.index, env:)
          infer_index_result_type(receiver_type, index_type)
        when AST::UnaryOp
          return infer_result_propagation_type(expression, env:) if expression.operator == "?"

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
        when AST::MatchExpr
          scrutinee_type = infer_expression_type(expression.expression, env:)
          arm_types = expression.arms.map do |arm|
            arm_env = duplicate_env(env)
            if scrutinee_type.is_a?(Types::Variant) && arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
              arm_name = variant_match_arm_name_from_pattern(arm.pattern)
              if arm_name && scrutinee_type.has_payload?(arm_name)
                fields = scrutinee_type.arm(arm_name)
                payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
                arm_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: c_local_name(arm.binding_name), mutable: false, pointer: false)
              end
            end
            infer_expression_type(arm.value, env: arm_env, expected_type: expected_type)
          end

          if expected_type && arm_types.all? { |arm_type| if_expression_branch_compatible?(arm_type, expected_type) }
            return expected_type
          end

          common_type = arm_types.first
          arm_types.drop(1).each do |arm_type|
            common_type = conditional_common_type(common_type, arm_type) || raise(LoweringError, "match expression arms require compatible types, got #{common_type} and #{arm_type}")
          end
          common_type
        when AST::UnsafeExpr
          infer_expression_type(expression.expression, env:, expected_type:)
        when AST::ProcExpr
          resolve_type_ref(AST::ProcType.new(params: expression.params, return_type: expression.return_type))
        when AST::Call
          kind, _callee_name, _receiver, callee_type = resolve_callee(expression.callee, env, arguments: expression.arguments)
          case kind
          when :function, :method, :associated_method, :callable_value,
            :str_buffer_clear, :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format,
            :str_buffer_len, :str_buffer_capacity, :str_buffer_as_str, :str_buffer_as_cstr,
            :event_subscribe, :event_subscribe_once, :event_unsubscribe, :event_emit, :event_wait,
            :compile_time_builtin,
            :cast, :reinterpret, :zero, :hash, :equal, :order
            callee_type.return_type
          when :struct_literal, :array, :variant_arm_ctor
            callee_type
          when :ref_of
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            Types::GenericInstance.new("ref", [argument_type])
          when :const_ptr_of
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            Types::GenericInstance.new("const_ptr", [argument_type])
          when :read
            infer_value_type(expression.arguments.fetch(0).value, env:)
          when :ptr_of
            argument_type = infer_expression_type(expression.arguments.fetch(0).value, env:)
            if ref_type?(argument_type)
              Types::GenericInstance.new("ptr", [referenced_type(argument_type)])
            else
              Types::GenericInstance.new("ptr", [infer_expression_type(expression.arguments.fetch(0).value, env:, expected_type: expected_type && pointer_type?(expected_type) ? pointee_type(expected_type) : nil)])
            end
          when :fatal
            @types.fetch("void")
          else
            raise LoweringError, "unsupported call kind #{kind}"
          end
        when AST::Specialization
          if expression.callee.is_a?(AST::Identifier) && expression.callee.name == "cast"
            resolve_type_ref(expression.arguments.fetch(0).value)
          elsif expression.callee.is_a?(AST::Identifier) && expression.callee.name == "zero"
            _, _, _, function_type = resolve_callee(expression, env, arguments: [])
            function_type.return_type
          elsif expression.callee.is_a?(AST::Identifier) && expression.callee.name == "default"
            resolve_default_specialization(expression, env:).target_type
          elsif (callable_resolution = resolve_specialized_callable_binding(expression, env:))
            callable_kind, function_binding, = callable_resolution
            raise LoweringError, "specialized method must be called" if callable_kind == :method

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
                              when "+", "-", "*", "/", "%"
                                propagated_type || left_type
                              when "|", "&", "^"
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

      def pointer_lowered_sync_method_receiver?(binding)
        return false if binding.async

        pointer_lowered_method_receiver?(binding.type, binding)
      end

      def pointer_lowered_method_receiver?(callee_type, callee_binding)
        return true if callee_type.receiver_mutable

        receiver_type_uses_pointer_lowering?(callee_type.receiver_type) && !callee_binding&.async
      end

      def receiver_type_uses_pointer_lowering?(type)
        case type
        when Types::Nullable
          receiver_type_uses_pointer_lowering?(type.base)
        when Types::Struct, Types::StructInstance
          type_contains_array_storage?(type)
        else
          false
        end
      end

      def type_contains_array_storage?(type)
        return true if array_type?(type)

        case type
        when Types::Struct, Types::StructInstance
          type.fields.each_value.any? { |field_type| type_contains_array_storage?(field_type) }
        when Types::Nullable
          type_contains_array_storage?(type.base)
        else
          false
        end
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
          return current_type_params[expression.name] if current_type_params.key?(expression.name)

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

      def resolve_specialized_callable_binding(expression, env:)
        callable_kind = :function
        receiver = nil
        receiver_type = nil
        binding = case expression.callee
                  when AST::Identifier
                    @functions[expression.callee.name]
                  when AST::MemberAccess
                    if expression.callee.receiver.is_a?(AST::Identifier) && @imports.key?(expression.callee.receiver.name)
                      @imports.fetch(expression.callee.receiver.name).functions[expression.callee.member]
                    elsif (type_expr = resolve_type_expression(expression.callee.receiver))
                      dispatch_receiver_type = method_dispatch_receiver_type(type_expr)
                      method_entry_receiver_type = type_expr
                      method_entry = @method_definitions[[type_expr, expression.callee.member]]
                      unless method_entry || dispatch_receiver_type == type_expr
                        method_entry_receiver_type = dispatch_receiver_type
                        method_entry = @method_definitions[[dispatch_receiver_type, expression.callee.member]]
                      end
                      if method_entry
                        method_analysis, method_ast = method_entry
                        method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_ast.name)
                        if method_binding.type.receiver_type.nil?
                          receiver_type = type_expr
                          method_binding
                        end
                      end
                    else
                      resolved_receiver_type = infer_method_receiver_type(expression.callee.receiver, env:, member_name: expression.callee.member)
                      dispatch_receiver_type = method_dispatch_receiver_type(resolved_receiver_type)
                      method_entry_receiver_type = resolved_receiver_type
                      method_entry = @method_definitions[[resolved_receiver_type, expression.callee.member]]
                      unless method_entry || dispatch_receiver_type == resolved_receiver_type
                        method_entry_receiver_type = dispatch_receiver_type
                        method_entry = @method_definitions[[dispatch_receiver_type, expression.callee.member]]
                      end
                      if method_entry
                        method_analysis, method_ast = method_entry
                        callable_kind = :method
                        receiver = expression.callee.receiver
                        receiver_type = resolved_receiver_type
                        method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_ast.name)
                      end
                    end
                  end
        return nil unless binding

        type_arguments = resolve_specialization_type_arguments(expression)
        [callable_kind, instantiate_function_binding_with_receiver(binding, type_arguments, receiver_type:), receiver]
      end

      def resolve_default_specialization(expression, env:)
        target_type = resolve_type_ref(expression.arguments.fetch(0).value)

        explicit_default = resolve_explicit_default_binding(target_type, context: "default[#{target_type}]")
        raise LoweringError, "default[#{target_type}] requires associated function #{target_type}.default()" unless explicit_default

        DefaultResolution.new(target_type:, binding: explicit_default.binding, callee_name: explicit_default.callee_name)
      end

      def resolve_hash_specialization(expression, env:)
        target_type = resolve_type_ref(expression.arguments.fetch(0).value)
        explicit_hash = resolve_explicit_hash_binding(target_type, context: "hash[#{target_type}]")
        raise LoweringError, "hash[#{target_type}] requires associated function #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint" unless explicit_hash

        HashResolution.new(target_type:, binding: explicit_hash.binding, callee_name: explicit_hash.callee_name)
      end

      def resolve_equal_specialization(expression, env:)
        target_type = resolve_type_ref(expression.arguments.fetch(0).value)
        explicit_equal = resolve_explicit_equal_binding(target_type, context: "equal[#{target_type}]")
        raise LoweringError, "equal[#{target_type}] requires associated function #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool" unless explicit_equal

        EqualResolution.new(target_type:, binding: explicit_equal.binding, callee_name: explicit_equal.callee_name)
      end

      def resolve_order_specialization(expression, env:)
        target_type = resolve_type_ref(expression.arguments.fetch(0).value)
        explicit_order = resolve_explicit_order_binding(target_type, context: "order[#{target_type}]")
        raise LoweringError, "order[#{target_type}] requires associated function #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int" unless explicit_order

        OrderResolution.new(target_type:, binding: explicit_order.binding, callee_name: explicit_order.callee_name)
      end

      def resolve_explicit_default_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.default()"
        resolve_explicit_associated_binding(target_type, "default", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          raise LoweringError, "#{context} requires #{target_type}.default() to take 0 arguments" unless method_binding.type.params.empty?
          unless method_binding.type.return_type == target_type
            raise LoweringError, "#{context} requires #{target_type}.default() to return #{target_type}, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_hash_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint"
        resolve_explicit_associated_binding(target_type, "hash", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          unless method_binding.type.params.map(&:type) == [const_pointer_to(target_type)]
            raise LoweringError, "#{context} requires #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint"
          end
          unless method_binding.type.return_type == @types.fetch("uint")
            raise LoweringError, "#{context} requires #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_equal_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool"
        resolve_explicit_associated_binding(target_type, "equal", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          expected_param_types = [const_pointer_to(target_type), const_pointer_to(target_type)]
          unless method_binding.type.params.map(&:type) == expected_param_types
            raise LoweringError, "#{context} requires #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool"
          end
          unless method_binding.type.return_type == @types.fetch("bool")
            raise LoweringError, "#{context} requires #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_order_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int"
        resolve_explicit_associated_binding(target_type, "order", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          expected_param_types = [const_pointer_to(target_type), const_pointer_to(target_type)]
          unless method_binding.type.params.map(&:type) == expected_param_types
            raise LoweringError, "#{context} requires #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int"
          end
          unless method_binding.type.return_type == @types.fetch("int")
            raise LoweringError, "#{context} requires #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_format_binding(target_type, context:)
        length_binding = resolve_explicit_format_len_binding(target_type, context:)
        append_binding = resolve_explicit_format_append_binding(target_type, context:)

        return ExplicitFormatBinding.new(
          length_binding: length_binding.fetch(:binding),
          length_callee_name: length_binding.fetch(:callee_name),
          append_binding: append_binding.fetch(:binding),
          append_callee_name: append_binding.fetch(:callee_name),
        ) if length_binding && append_binding

        if length_binding || append_binding
          raise LoweringError, "#{context} requires methods #{target_type}.format_len() -> ptr_uint and #{target_type}.append_format(output: ref[std.string.String]) -> void"
        end

        nil
      end

      def resolve_explicit_format_len_binding(target_type, context:)
        requirement_message = "#{context} requires method #{target_type}.format_len() -> ptr_uint"
        resolve_explicit_instance_binding(target_type, "format_len", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          raise LoweringError, "#{context} requires #{target_type}.format_len() to take 0 arguments" unless method_binding.type.params.empty?
          raise LoweringError, "#{context} requires #{target_type}.format_len() to be non-mutable" if method_binding.type.receiver_mutable
          unless method_binding.type.return_type == @types.fetch("ptr_uint")
            raise LoweringError, "#{context} requires #{target_type}.format_len() -> ptr_uint, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_format_append_binding(target_type, context:)
        requirement_message = "#{context} requires method #{target_type}.append_format(output: ref[std.string.String]) -> void"
        resolve_explicit_instance_binding(target_type, "append_format", requirement_message:) do |method_binding, _method_analysis, _method_entry_receiver_type|
          raise LoweringError, "#{context} requires #{target_type}.append_format() to be non-mutable" if method_binding.type.receiver_mutable
          unless method_binding.type.params.length == 1 && string_builder_ref_type?(method_binding.type.params.first.type)
            raise LoweringError, "#{context} requires #{target_type}.append_format(output: ref[std.string.String]) -> void"
          end
          unless method_binding.type.return_type == @types.fetch("void")
            raise LoweringError, "#{context} requires #{target_type}.append_format(output: ref[std.string.String]) -> void, got #{method_binding.type.return_type}"
          end
        end
      end

      def resolve_explicit_associated_binding(target_type, method_name, requirement_message:)
        dispatch_receiver_type = method_dispatch_receiver_type(target_type)
        method_entry_receiver_type = target_type
        method_entry = @method_definitions[[target_type, method_name]]
        unless method_entry || dispatch_receiver_type == target_type
          method_entry_receiver_type = dispatch_receiver_type
          method_entry = @method_definitions[[dispatch_receiver_type, method_name]]
        end
        return nil unless method_entry

        method_analysis, method_ast = method_entry
        method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_ast.name)
        raise LoweringError, requirement_message unless method_binding.type.receiver_type.nil?

        method_binding = instantiate_function_binding_with_receiver(method_binding, [], receiver_type: target_type) if method_binding.type_params.any?
        yield method_binding, method_analysis, method_entry_receiver_type

        callee_name = if method_binding.external
                        method_binding.name
                      else
                        function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: method_entry_receiver_type)
                      end

        case method_name
        when "default"
          ExplicitDefaultBinding.new(binding: method_binding, callee_name:)
        when "hash"
          ExplicitHashBinding.new(binding: method_binding, callee_name:)
        when "equal"
          ExplicitEqualBinding.new(binding: method_binding, callee_name:)
        when "order"
          ExplicitOrderBinding.new(binding: method_binding, callee_name:)
        else
          raise LoweringError, "unsupported associated hook #{method_name}"
        end
      end

      def resolve_explicit_instance_binding(target_type, method_name, requirement_message:)
        dispatch_receiver_type = method_dispatch_receiver_type(target_type)
        method_entry_receiver_type = target_type
        method_entry = @method_definitions[[target_type, method_name]]
        unless method_entry || dispatch_receiver_type == target_type
          method_entry_receiver_type = dispatch_receiver_type
          method_entry = @method_definitions[[dispatch_receiver_type, method_name]]
        end
        return nil unless method_entry

        method_analysis, method_ast = method_entry
        method_binding = method_analysis.methods.fetch(method_entry_receiver_type).fetch(method_ast.name)
        raise LoweringError, requirement_message if method_binding.type.receiver_type.nil?

        method_binding = instantiate_function_binding_with_receiver(method_binding, [], receiver_type: target_type) if method_binding.type_params.any?
        yield method_binding, method_analysis, method_entry_receiver_type

        callee_name = if method_binding.external
                        method_binding.name
                      else
                        function_binding_c_name(method_binding, module_name: method_analysis.module_name, receiver_type: method_entry_receiver_type)
                      end

        {
          binding: method_binding,
          callee_name: callee_name,
        }
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

      def resolve_type_member_const_value(expression)
        type = resolve_type_expression(expression.receiver)
        return unless type.is_a?(Types::EnumBase)

        type.member_value(expression.member)
      end

      def compile_time_numeric_const_expression?(expression, env: nil)
        value = compile_time_const_value(expression, env:)
        value.is_a?(Integer) || value.is_a?(Float)
      end

      def compile_time_const_value(expression, env: nil)
        CompileTime.evaluate(
          expression,
          resolve_identifier: lambda do |identifier_expression|
            if env
              binding = lookup_value(identifier_expression.name, env)
              return binding[:const_value] unless binding&.fetch(:const_value, nil).nil?
            end

            resolve_current_module_const_value(identifier_expression.name)
          end,
          resolve_member_access: lambda do |member_access_expression|
            value = if member_access_expression.receiver.is_a?(AST::Identifier)
                      resolve_imported_module_const_value(member_access_expression.receiver.name, member_access_expression.member)
                    end
            next value unless value.nil?

            resolve_type_member_const_value(member_access_expression)
          end,
          resolve_type_ref: lambda do |type_ref|
            resolve_type_ref(type_ref)
          end,
          resolve_call: lambda do |call_expression|
            evaluate_compile_time_call(call_expression, env:)
          end,
        )
      end

      def evaluate_compile_time_call(expression, env:)
        case expression.callee
        when AST::Identifier
          case expression.callee.name
          when "field_of"
            evaluate_field_of_call(expression.arguments, env:)
          when "callable_of"
            evaluate_callable_of_call(expression.arguments)
          when "has_attribute"
            evaluate_has_attribute_call(expression.arguments, env:)
          when "attribute_of"
            evaluate_attribute_of_call(expression.arguments, env:)
          else
            nil
          end
        when AST::Specialization
          if expression.callee.callee.is_a?(AST::Identifier) && expression.callee.callee.name == "attribute_arg"
            evaluate_attribute_arg_call(expression.arguments, env:)
          end
        else
          nil
        end
      end

      def evaluate_field_of_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 2)

        struct_handle = resolve_struct_handle_argument(arguments.first.value, env:)
        return nil unless struct_handle

        field_name = reflection_identifier_name(arguments[1].value)
        return nil unless field_name

        field_declaration = struct_handle.declaration.fields.find { |field| field.name == field_name }
        return nil unless field_declaration

        Types::FieldHandle.new(struct_handle, field_name, field_declaration)
      end

      def evaluate_callable_of_call(arguments)
        return nil unless reflection_positional_arguments?(arguments, 1)

        resolve_callable_handle_argument(arguments.first.value)
      end

      def evaluate_has_attribute_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 2)

        target = evaluate_reflection_target_argument(arguments.first.value, env:)
        binding = resolve_attribute_name_argument(arguments[1].value)
        return nil unless attribute_binding_supports_target?(binding, target)

        !find_attribute_application(target, binding).nil?
      end

      def evaluate_attribute_of_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 2)

        target = evaluate_reflection_target_argument(arguments.first.value, env:)
        binding = resolve_attribute_name_argument(arguments[1].value)
        return nil unless attribute_binding_supports_target?(binding, target)

        application = find_attribute_application(target, binding)
        return nil unless application

        Types::AttributeHandle.new(
          binding.name,
          binding.module_name,
          target,
          binding.params,
          application.argument_values,
        )
      end

      def evaluate_attribute_arg_call(arguments, env:)
        return nil unless reflection_positional_arguments?(arguments, 2)

        attribute_handle = compile_time_const_value(arguments.first.value, env:)
        return nil unless attribute_handle.is_a?(Types::AttributeHandle)

        param_name = reflection_identifier_name(arguments[1].value)
        return nil unless param_name && attribute_handle.argument_values

        attribute_handle.argument_values[param_name]
      end

      def lower_compile_time_builtin_call(expression, builtin_name:, env:, type:)
        case builtin_name
        when "state_descriptor"
          lower_multiplayer_state_descriptor_call(expression, type:)
        when "state_wire_size"
          lower_multiplayer_state_wire_size_call(expression, type:)
        when "rpc_descriptor"
          lower_multiplayer_rpc_descriptor_call(expression, type:)
        when "rpc_payload_size"
          lower_multiplayer_rpc_payload_size_call(expression, type:)
        when "rpc_dispatch_typed_payload"
          lower_multiplayer_rpc_typed_payload_call(expression, env:, type:)
        else
          raise LoweringError, "compile-time builtin #{builtin_name} cannot be lowered as a runtime value"
        end
      end

      def lower_multiplayer_state_descriptor_call(expression, type:)
        callee = expression.callee
        raise LoweringError, "state_descriptor requires a specialized call" unless callee.is_a?(AST::Specialization)

        struct_type = resolve_type_ref(callee.arguments.fetch(0).value)
        struct_handle = struct_handle_for_type(struct_type) || raise(LoweringError, "state_descriptor requires a struct type")
        analysis = analysis_for_module(struct_handle.struct_type.module_name)

        with_analysis_context(analysis) do
          replicated_binding = multiplayer_attribute_binding("replicated")
          sync_defaults_binding = multiplayer_attribute_binding("sync_defaults")
          sync_binding = multiplayer_attribute_binding("sync")
          replicated_application = find_attribute_application(struct_handle, replicated_binding) || raise(LoweringError, "state_descriptor requires a @[std.multiplayer.replicated(...)] struct")
          replicated_arguments = replicated_application.argument_values
          sync_defaults_application = find_attribute_application(struct_handle, sync_defaults_binding)

          sync_fields = struct_handle.declaration.fields.filter_map do |field_declaration|
            field_handle = Types::FieldHandle.new(struct_handle, field_declaration.name, field_declaration)
            sync_application = find_attribute_application(field_handle, sync_binding)
            next unless sync_application

            sync_arguments = if sync_application.argument_values.empty?
                               sync_defaults_application&.argument_values || raise(LoweringError, "state_descriptor sync marker field #{field_declaration.name} requires @[std.multiplayer.sync_defaults(...)] on the struct")
                             else
                               sync_application.argument_values
                             end

            {
              name: field_declaration.name,
              type: struct_handle.struct_type.field(field_declaration.name),
              arguments: sync_arguments,
            }
          end

          normalized_sync = nil
          sync_fields.each do |field_info|
            current_sync = {
              mode: field_info.fetch(:arguments).fetch("mode"),
              channel: field_info.fetch(:arguments).fetch("channel"),
              rate_hz: field_info.fetch(:arguments).fetch("rate_hz"),
              target: field_info.fetch(:arguments).fetch("target"),
            }
            normalized_sync ||= current_sync
            next if normalized_sync == current_sync

            raise LoweringError,
                  "state_descriptor requires sync fields to share mode/channel/rate_hz/target in v1"
          end

          normalized_sync ||= {
            mode: 1,
            channel: 0,
            rate_hz: 0,
            target: 0,
          }

          wire_size = sync_fields.sum do |field_info|
            multiplayer_typed_rpc_encoded_size(field_info.fetch(:type))
          end

          encode_full_binding = multiplayer_descriptor_hash("state_encode_full", struct_handle.struct_type.to_s)
          decode_full_binding = multiplayer_descriptor_hash("state_decode_full", struct_handle.struct_type.to_s)
          encode_delta_binding = multiplayer_descriptor_hash("state_encode_delta", struct_handle.struct_type.to_s)
          apply_delta_binding = multiplayer_descriptor_hash("state_apply_delta", struct_handle.struct_type.to_s)

          schema_hash = multiplayer_descriptor_hash(
            "state",
            struct_handle.struct_type.to_s,
            "authority=#{replicated_arguments.fetch("authority")}",
            *sync_fields.flat_map do |field_info|
              [
                "field=#{field_info.fetch(:name)}",
                "type=#{multiplayer_schema_type_name(field_info.fetch(:type))}",
                "mode=#{field_info.fetch(:arguments).fetch("mode")}",
                "channel=#{field_info.fetch(:arguments).fetch("channel")}",
                "rate_hz=#{field_info.fetch(:arguments).fetch("rate_hz")}",
                "target=#{field_info.fetch(:arguments).fetch("target")}",
              ]
            end,
          )

          return IR::AggregateLiteral.new(
            type:,
            fields: [
              IR::AggregateField.new(name: "name", value: lower_multiplayer_descriptor_value(struct_handle.struct_type.to_s, type.field("name"))),
              IR::AggregateField.new(name: "authority", value: lower_multiplayer_descriptor_value(replicated_arguments.fetch("authority"), type.field("authority"))),
              IR::AggregateField.new(name: "schema_hash", value: lower_multiplayer_descriptor_value(schema_hash, type.field("schema_hash"))),
              IR::AggregateField.new(name: "wire_size", value: lower_multiplayer_descriptor_value(wire_size, type.field("wire_size"))),
              IR::AggregateField.new(name: "encode_full_binding", value: lower_multiplayer_descriptor_value(encode_full_binding, type.field("encode_full_binding"))),
              IR::AggregateField.new(name: "decode_full_binding", value: lower_multiplayer_descriptor_value(decode_full_binding, type.field("decode_full_binding"))),
              IR::AggregateField.new(name: "encode_delta_binding", value: lower_multiplayer_descriptor_value(encode_delta_binding, type.field("encode_delta_binding"))),
              IR::AggregateField.new(name: "apply_delta_binding", value: lower_multiplayer_descriptor_value(apply_delta_binding, type.field("apply_delta_binding"))),
              IR::AggregateField.new(name: "sync_field_count", value: lower_multiplayer_descriptor_value(sync_fields.length, type.field("sync_field_count"))),
              IR::AggregateField.new(name: "sync_mode", value: lower_multiplayer_descriptor_value(normalized_sync.fetch(:mode), type.field("sync_mode"))),
              IR::AggregateField.new(name: "sync_channel", value: lower_multiplayer_descriptor_value(normalized_sync.fetch(:channel), type.field("sync_channel"))),
              IR::AggregateField.new(name: "sync_rate_hz", value: lower_multiplayer_descriptor_value(normalized_sync.fetch(:rate_hz), type.field("sync_rate_hz"))),
              IR::AggregateField.new(name: "sync_target", value: lower_multiplayer_descriptor_value(normalized_sync.fetch(:target), type.field("sync_target"))),
            ],
          )
        end
      end

      def lower_multiplayer_state_wire_size_call(expression, type:)
        callee = expression.callee
        raise LoweringError, "state_wire_size requires a specialized call" unless callee.is_a?(AST::Specialization)

        struct_type = resolve_type_ref(callee.arguments.fetch(0).value)
        struct_handle = struct_handle_for_type(struct_type) || raise(LoweringError, "state_wire_size requires a struct type")
        analysis = analysis_for_module(struct_handle.struct_type.module_name)

        with_analysis_context(analysis) do
          replicated_binding = multiplayer_attribute_binding("replicated")
          sync_defaults_binding = multiplayer_attribute_binding("sync_defaults")
          sync_binding = multiplayer_attribute_binding("sync")
          find_attribute_application(struct_handle, replicated_binding) || raise(LoweringError, "state_wire_size requires a @[std.multiplayer.replicated(...)] struct")
          sync_defaults_application = find_attribute_application(struct_handle, sync_defaults_binding)

          payload_size = 0
          struct_handle.declaration.fields.each do |field_declaration|
            field_handle = Types::FieldHandle.new(struct_handle, field_declaration.name, field_declaration)
            sync_application = find_attribute_application(field_handle, sync_binding)
            next unless sync_application

            if sync_application.argument_values.empty? && !sync_defaults_application
              raise LoweringError, "state_wire_size sync marker field #{field_declaration.name} requires @[std.multiplayer.sync_defaults(...)] on the struct"
            end

            payload_size += multiplayer_typed_rpc_encoded_size(struct_handle.struct_type.field(field_declaration.name))
          end

          return IR::IntegerLiteral.new(value: payload_size, type:)
        end
      end

      def lower_multiplayer_rpc_descriptor_call(expression, type:)
        target_expression = expression.arguments.fetch(0).value
        raise LoweringError, "rpc_descriptor expects callable_of(name)" unless target_expression.is_a?(AST::Call)

        callable_expression = target_expression.arguments.fetch(0).value
        rpc_target = resolve_multiplayer_rpc_target(callable_expression) || raise(LoweringError, "rpc_descriptor expects a top-level callable")
        analysis = analysis_for_module(rpc_target.fetch(:module_name))

        with_analysis_context(analysis) do
          rpc_binding = multiplayer_attribute_binding("rpc")
          callable_handle = Types::CallableHandle.new(rpc_target.fetch(:qualified_name), rpc_target.fetch(:binding).ast)
          rpc_application = find_attribute_application(callable_handle, rpc_binding) || raise(LoweringError, "rpc_descriptor expects a @[std.multiplayer.rpc(...)] callable")
          rpc_arguments = rpc_application.argument_values
          payload_params = rpc_target.fetch(:binding).type.params.drop(1)
          payload_size = payload_params.sum do |param|
            multiplayer_typed_rpc_encoded_size(param.type)
          end
          decode_payload_binding = multiplayer_descriptor_hash("rpc_decode_payload", rpc_target.fetch(:qualified_name))
          dispatch_typed_binding = multiplayer_descriptor_hash("rpc_dispatch_typed", rpc_target.fetch(:qualified_name))

          schema_hash = multiplayer_descriptor_hash(
            "rpc",
            rpc_target.fetch(:qualified_name),
            "direction=#{rpc_arguments.fetch("direction")}",
            "mode=#{rpc_arguments.fetch("mode")}",
            "channel=#{rpc_arguments.fetch("channel")}",
            "require_owner=#{rpc_arguments.fetch("require_owner")}",
            *payload_params.flat_map do |param|
              ["param=#{param.name}", "type=#{multiplayer_schema_type_name(param.type)}"]
            end,
          )

          return IR::AggregateLiteral.new(
            type:,
            fields: [
              IR::AggregateField.new(name: "name", value: lower_multiplayer_descriptor_value(rpc_target.fetch(:qualified_name), type.field("name"))),
              IR::AggregateField.new(name: "direction", value: lower_multiplayer_descriptor_value(rpc_arguments.fetch("direction"), type.field("direction"))),
              IR::AggregateField.new(name: "mode", value: lower_multiplayer_descriptor_value(rpc_arguments.fetch("mode"), type.field("mode"))),
              IR::AggregateField.new(name: "channel", value: lower_multiplayer_descriptor_value(rpc_arguments.fetch("channel"), type.field("channel"))),
              IR::AggregateField.new(name: "require_owner", value: lower_multiplayer_descriptor_value(rpc_arguments.fetch("require_owner"), type.field("require_owner"))),
              IR::AggregateField.new(name: "schema_hash", value: lower_multiplayer_descriptor_value(schema_hash, type.field("schema_hash"))),
              IR::AggregateField.new(name: "payload_size", value: lower_multiplayer_descriptor_value(payload_size, type.field("payload_size"))),
              IR::AggregateField.new(name: "decode_payload_binding", value: lower_multiplayer_descriptor_value(decode_payload_binding, type.field("decode_payload_binding"))),
              IR::AggregateField.new(name: "dispatch_typed_binding", value: lower_multiplayer_descriptor_value(dispatch_typed_binding, type.field("dispatch_typed_binding"))),
            ],
          )
        end
      end

      def lower_multiplayer_rpc_payload_size_call(expression, type:)
        target_expression = expression.arguments.fetch(0).value
        raise LoweringError, "rpc_payload_size expects callable_of(name)" unless target_expression.is_a?(AST::Call)

        callable_expression = target_expression.arguments.fetch(0).value
        rpc_target = resolve_multiplayer_rpc_target(callable_expression) || raise(LoweringError, "rpc_payload_size expects a top-level callable")
        analysis = analysis_for_module(rpc_target.fetch(:module_name))

        with_analysis_context(analysis) do
          rpc_binding = multiplayer_attribute_binding("rpc")
          callable_handle = Types::CallableHandle.new(rpc_target.fetch(:qualified_name), rpc_target.fetch(:binding).ast)
          find_attribute_application(callable_handle, rpc_binding) || raise(LoweringError, "rpc_payload_size expects a @[std.multiplayer.rpc(...)] callable")

          payload_size = rpc_target.fetch(:binding).type.params.drop(1).sum do |param|
            multiplayer_typed_rpc_encoded_size(param.type)
          end

          return IR::IntegerLiteral.new(value: payload_size, type:)
        end
      end

      def lower_multiplayer_rpc_typed_payload_call(expression, env:, type:)
        unless expression.arguments.length == 3 && expression.arguments.none?(&:name)
          raise LoweringError, "dispatch_typed_payload expects positional arguments: callable_of(name), context, payload"
        end

        target_expression = expression.arguments.fetch(0).value
        raise LoweringError, "dispatch_typed_payload expects callable_of(name) as first argument" unless target_expression.is_a?(AST::Call)

        callable_expression = target_expression.arguments.fetch(0).value
        rpc_target = resolve_multiplayer_rpc_target(callable_expression) || raise(LoweringError, "dispatch_typed_payload expects a top-level callable")

        helper_c_name = ensure_multiplayer_rpc_typed_dispatch_helper(rpc_target)
        helper_type = multiplayer_rpc_typed_dispatch_function_type
        context_expression = lower_contextual_expression(expression.arguments.fetch(1).value, env:, expected_type: helper_type.params.fetch(1).type)
        payload_expression = lower_contextual_expression(expression.arguments.fetch(2).value, env:, expected_type: helper_type.params.fetch(2).type)

        IR::Call.new(
          callee: helper_c_name,
          arguments: [context_expression, payload_expression],
          type:,
        )
      end

      def ensure_multiplayer_rpc_typed_dispatch_helper(rpc_target)
        cache_key = rpc_target.fetch(:qualified_name)
        return @multiplayer_typed_rpc_dispatch_helpers.fetch(cache_key) if @multiplayer_typed_rpc_dispatch_helpers.key?(cache_key)

        rpc_analysis = analysis_for_module(rpc_target.fetch(:module_name))

        helper_c_name = with_analysis_context(rpc_analysis) do
          function_binding = rpc_target.fetch(:binding)
          rpc_binding = multiplayer_attribute_binding("rpc")
          callable_handle = Types::CallableHandle.new(rpc_target.fetch(:qualified_name), function_binding.ast)
          rpc_application = find_attribute_application(callable_handle, rpc_binding) || raise(LoweringError, "dispatch_typed_payload expects a @[std.multiplayer.rpc(...)] callable")
          rpc_arguments = rpc_application.argument_values
          payload_params = function_binding.type.params.drop(1)
          unsupported = payload_params.find do |param|
            multiplayer_typed_rpc_payload_type_error(param.type)
          end
          if unsupported
            reason = multiplayer_typed_rpc_payload_type_error(unsupported.type)
            raise LoweringError,
                  "dispatch_typed_payload does not support payload parameter #{unsupported.name} of type #{unsupported.type}: #{reason}"
          end

          payload_size = payload_params.sum { |param| multiplayer_typed_rpc_encoded_size(param.type) }

          helper_type = multiplayer_rpc_typed_dispatch_function_type
          result_type = helper_type.return_type
          context_type = helper_type.params.fetch(1).type
          payload_type = helper_type.params.fetch(2).type
          payload_len_expr = IR::Member.new(
            receiver: IR::Name.new(name: "payload", type: payload_type, pointer: false),
            member: "len",
            type: @types.fetch("ptr_uint"),
          )

          dispatch_error_type = analysis_for_module("std.multiplayer.rpc").types.fetch("DispatchError")
          error_code_type = analysis_for_module("std.multiplayer.protocol").types.fetch("ErrorCode")
          rpc_runtime_analysis = analysis_for_module("std.multiplayer.rpc")
          owner_check_binding = rpc_runtime_analysis.functions.fetch("context_satisfies_owner_requirement")
          owner_check_c_name = function_binding_c_name(owner_check_binding, module_name: "std.multiplayer.rpc")

          failure_literal = IR::VariantLiteral.new(
            type: result_type,
            arm_name: "failure",
            fields: [
              IR::AggregateField.new(
                name: "error",
                value: IR::AggregateLiteral.new(
                  type: dispatch_error_type,
                  fields: [
                    IR::AggregateField.new(
                      name: "code",
                      value: IR::Name.new(
                        name: enum_member_c_name(error_code_type, "invalid_argument"),
                        type: error_code_type,
                        pointer: false,
                      ),
                    ),
                    IR::AggregateField.new(
                      name: "message",
                      value: IR::StringLiteral.new(
                        value: "typed rpc payload size mismatch",
                        type: @types.fetch("str"),
                        cstring: false,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          )

          success_literal = IR::VariantLiteral.new(
            type: result_type,
            arm_name: "success",
            fields: [
              IR::AggregateField.new(
                name: "value",
                value: IR::BooleanLiteral.new(value: true, type: @types.fetch("bool")),
              ),
            ],
          )

          payload_data_expr = IR::Member.new(
            receiver: IR::Name.new(name: "payload", type: payload_type, pointer: false),
            member: "data",
            type: pointer_to(@types.fetch("ubyte")),
          )
          owner_requirement_expr = IR::Call.new(
            callee: owner_check_c_name,
            arguments: [
              IR::BooleanLiteral.new(value: rpc_arguments.fetch("require_owner"), type: @types.fetch("bool")),
              IR::Name.new(name: "context", type: context_type, pointer: false),
            ],
            type: @types.fetch("bool"),
          )
          owner_requirement_failure = IR::VariantLiteral.new(
            type: result_type,
            arm_name: "failure",
            fields: [
              IR::AggregateField.new(
                name: "error",
                value: IR::AggregateLiteral.new(
                  type: dispatch_error_type,
                  fields: [
                    IR::AggregateField.new(
                      name: "code",
                      value: IR::Name.new(
                        name: enum_member_c_name(error_code_type, "invalid_argument"),
                        type: error_code_type,
                        pointer: false,
                      ),
                    ),
                    IR::AggregateField.new(
                      name: "message",
                      value: IR::StringLiteral.new(
                        value: "rpc dispatch requires a sender when descriptor requires owner",
                        type: @types.fetch("str"),
                        cstring: false,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          )
          decoded_arguments = payload_params.each_with_index.map do |param, index|
            value, _size = decode_multiplayer_typed_rpc_payload_value(param.type, payload_data_expr, multiplayer_typed_rpc_param_offset(payload_params, index))
            value
          end

          helper_c_name = "#{module_c_prefix(rpc_target.fetch(:module_name))}_#{function_binding.name}_typed_dispatch_#{@multiplayer_typed_rpc_dispatch_helpers.length}"
          @synthetic_functions << IR::Function.new(
            name: helper_c_name,
            c_name: helper_c_name,
            params: [
              IR::Param.new(name: "context", c_name: "context", type: context_type, pointer: false),
              IR::Param.new(name: "payload", c_name: "payload", type: payload_type, pointer: false),
            ],
            return_type: result_type,
            body: [
              IR::IfStmt.new(
                condition: IR::Unary.new(
                  operator: "!",
                  operand: owner_requirement_expr,
                  type: @types.fetch("bool"),
                ),
                then_body: [IR::ReturnStmt.new(value: owner_requirement_failure)],
                else_body: nil,
              ),
              IR::IfStmt.new(
                condition: IR::Binary.new(
                  operator: "!=",
                  left: payload_len_expr,
                  right: IR::IntegerLiteral.new(value: payload_size, type: @types.fetch("ptr_uint")),
                  type: @types.fetch("bool"),
                ),
                then_body: [IR::ReturnStmt.new(value: failure_literal)],
                else_body: nil,
              ),
              IR::ExpressionStmt.new(
                expression: IR::Call.new(
                  callee: function_binding_c_name(function_binding, module_name: rpc_target.fetch(:module_name)),
                  arguments: [
                    IR::Name.new(name: "context", type: context_type, pointer: false),
                    *decoded_arguments,
                  ],
                  type: @types.fetch("void"),
                ),
              ),
              IR::ReturnStmt.new(value: success_literal),
            ],
            entry_point: false,
          )

          helper_c_name
        end

        @multiplayer_typed_rpc_dispatch_helpers[cache_key] = helper_c_name
        helper_c_name
      end

      def multiplayer_typed_rpc_param_offset(payload_params, index)
        return 0 if index.zero?

        payload_params.take(index).sum { |param| multiplayer_typed_rpc_encoded_size(param.type) }
      end

      def multiplayer_typed_rpc_payload_type_error(type, visited = {})
        return nil if multiplayer_typed_rpc_scalar_payload_type?(type)

        if type.is_a?(Types::Struct) || type.is_a?(Types::StructInstance)
          return "external structs are not supported" if type.external
          return "event-carrying structs are not supported" if type.has_events?
          return "recursive struct payloads are not supported" if visited[type]

          added = false
          begin
            visited[type] = true
            added = true
            field_names = type.fields.keys
            return "struct payloads are limited to 8 fields" if field_names.length > 8

            field_names.each do |field_name|
              field_type = type.field(field_name)
              nested_reason = multiplayer_typed_rpc_payload_type_error(field_type, visited)
              next unless nested_reason

              return "field #{field_name} (#{field_type}) is not supported: #{nested_reason}"
            end

            return nil
          ensure
            visited.delete(type) if added
          end
        end

        "only primitives, integer-backed enums/flags, and small wire-safe structs are supported"
      end

      def multiplayer_typed_rpc_scalar_payload_type?(type)
        return multiplayer_typed_rpc_primitive_payload_type?(type) if type.is_a?(Types::Primitive)

        type.is_a?(Types::EnumBase) && multiplayer_typed_rpc_primitive_payload_type?(type.backing_type)
      end

      def multiplayer_typed_rpc_primitive_payload_type?(type)
        return false unless type.is_a?(Types::Primitive)

        %w[bool byte ubyte char short ushort int uint long ulong float double].include?(type.name)
      end

      def multiplayer_typed_rpc_encoded_size(type)
        if type.is_a?(Types::EnumBase)
          return multiplayer_typed_rpc_encoded_size(type.backing_type)
        end

        if type.is_a?(Types::Primitive)
          return 1 if %w[bool byte ubyte char].include?(type.name)
          return 2 if %w[short ushort].include?(type.name)
          return 4 if %w[int uint float].include?(type.name)
          return 8 if %w[long ulong double].include?(type.name)

          raise LoweringError, "unsupported primitive payload type #{type}"
        end

        if type.is_a?(Types::Struct) || type.is_a?(Types::StructInstance)
          return type.fields.keys.sum { |field_name| multiplayer_typed_rpc_encoded_size(type.field(field_name)) }
        end

        raise LoweringError, "unsupported typed rpc payload type #{type}"
      end

      def decode_multiplayer_typed_rpc_payload_value(type, payload_data_expr, offset)
        if type.is_a?(Types::EnumBase)
          backing_expr, size = decode_multiplayer_typed_rpc_payload_value(type.backing_type, payload_data_expr, offset)
          return [IR::Cast.new(target_type: type, expression: backing_expr, type: type), size]
        end

        if type.is_a?(Types::Primitive)
          case type.name
          when "bool"
            byte_expr = typed_rpc_payload_byte_expression(payload_data_expr, offset)
            return [
              IR::Binary.new(
                operator: "!=",
                left: byte_expr,
                right: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ubyte")),
                type: @types.fetch("bool"),
              ),
              1,
            ]
          when "ubyte"
            return [typed_rpc_payload_byte_expression(payload_data_expr, offset), 1]
          when "byte", "char"
            byte_expr = typed_rpc_payload_byte_expression(payload_data_expr, offset)
            return [IR::Cast.new(target_type: type, expression: byte_expr, type: type), 1]
          when "ushort"
            return [typed_rpc_decode_unsigned_be(payload_data_expr, offset, @types.fetch("ushort"), 2), 2]
          when "short"
            decoded = typed_rpc_decode_unsigned_be(payload_data_expr, offset, @types.fetch("ushort"), 2)
            return [IR::Cast.new(target_type: type, expression: decoded, type: type), 2]
          when "uint"
            return [typed_rpc_decode_unsigned_be(payload_data_expr, offset, @types.fetch("uint"), 4), 4]
          when "int"
            decoded = typed_rpc_decode_unsigned_be(payload_data_expr, offset, @types.fetch("uint"), 4)
            return [IR::Cast.new(target_type: type, expression: decoded, type: type), 4]
          when "ulong"
            return [typed_rpc_decode_unsigned_be(payload_data_expr, offset, @types.fetch("ulong"), 8), 8]
          when "long"
            decoded = typed_rpc_decode_unsigned_be(payload_data_expr, offset, @types.fetch("ulong"), 8)
            return [IR::Cast.new(target_type: type, expression: decoded, type: type), 8]
          when "float"
            bits = typed_rpc_decode_unsigned_be(payload_data_expr, offset, @types.fetch("uint"), 4)
            return [IR::ReinterpretExpr.new(target_type: type, source_type: @types.fetch("uint"), expression: bits, type: type), 4]
          when "double"
            bits = typed_rpc_decode_unsigned_be(payload_data_expr, offset, @types.fetch("ulong"), 8)
            return [IR::ReinterpretExpr.new(target_type: type, source_type: @types.fetch("ulong"), expression: bits, type: type), 8]
          else
            raise LoweringError, "unsupported primitive payload type #{type}"
          end
        end

        if type.is_a?(Types::Struct) || type.is_a?(Types::StructInstance)
          cursor = offset
          fields = type.fields.keys.map do |field_name|
            field_type = type.field(field_name)
            field_expr, field_size = decode_multiplayer_typed_rpc_payload_value(field_type, payload_data_expr, cursor)
            cursor += field_size
            IR::AggregateField.new(name: field_name, value: field_expr)
          end

          return [IR::AggregateLiteral.new(type: type, fields: fields), cursor - offset]
        end

        raise LoweringError, "unsupported typed rpc payload type #{type}"
      end

      def typed_rpc_payload_byte_expression(payload_data_expr, index)
        IR::Index.new(
          receiver: payload_data_expr,
          index: IR::IntegerLiteral.new(value: index, type: @types.fetch("ptr_uint")),
          type: @types.fetch("ubyte"),
        )
      end

      def typed_rpc_decode_unsigned_be(payload_data_expr, offset, target_type, byte_count)
        parts = (0...byte_count).map do |index|
          byte = IR::Cast.new(
            target_type: target_type,
            expression: typed_rpc_payload_byte_expression(payload_data_expr, offset + index),
            type: target_type,
          )
          shift = (byte_count - index - 1) * 8
          next byte if shift.zero?

          IR::Binary.new(
            operator: "<<",
            left: byte,
            right: IR::IntegerLiteral.new(value: shift, type: @types.fetch("int")),
            type: target_type,
          )
        end

        parts.reduce do |accumulator, part|
          IR::Binary.new(operator: "|", left: accumulator, right: part, type: target_type)
        end
      end

      def lower_multiplayer_descriptor_value(value, type)
        literal = lower_compile_time_literal(value, type)
        return literal if literal

        if type.is_a?(Types::EnumBase) && value.is_a?(Integer)
          return IR::Cast.new(
            target_type: type,
            expression: IR::IntegerLiteral.new(value:, type: type.backing_type),
            type:,
          )
        end

        raise LoweringError, "unsupported multiplayer descriptor literal #{value.inspect} for #{type}"
      end

      def resolve_multiplayer_rpc_target(expression)
        case expression
        when AST::Identifier
          binding = @functions[expression.name]
          return nil unless binding&.ast

          {
            binding:,
            module_name: @module_name,
            qualified_name: "#{@module_name}.#{binding.name}",
          }
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)
          return nil unless @imports.key?(expression.receiver.name)

          imported_module = @imports.fetch(expression.receiver.name)
          return nil if imported_module.private_function?(expression.member)

          binding = imported_module.functions[expression.member]
          return nil unless binding&.ast

          {
            binding:,
            module_name: imported_module.name,
            qualified_name: "#{imported_module.name}.#{binding.name}",
          }
        else
          nil
        end
      end

      def multiplayer_attribute_binding(name)
        analysis_for_module("std.multiplayer").attributes.fetch(name)
      end

      def multiplayer_state_descriptor_function_type
        descriptor_type = analysis_for_module("std.multiplayer.registry").types.fetch("StateDescriptor")
        Types::Function.new("state_descriptor", params: [], return_type: descriptor_type)
      end

      def multiplayer_state_wire_size_function_type
        Types::Function.new("state_wire_size", params: [], return_type: @types.fetch("ptr_uint"))
      end

      def multiplayer_rpc_descriptor_function_type
        descriptor_type = analysis_for_module("std.multiplayer.registry").types.fetch("RpcDescriptor")
        Types::Function.new("rpc_descriptor", params: [], return_type: descriptor_type)
      end

      def multiplayer_rpc_payload_size_function_type
        Types::Function.new("rpc_payload_size", params: [], return_type: @types.fetch("ptr_uint"))
      end

      def multiplayer_rpc_typed_dispatch_function_type
        analysis_for_module("std.multiplayer.rpc").functions.fetch("dispatch_typed_payload").type
      end

      def multiplayer_root_import_call?(callee, function_name)
        return false unless callee.receiver.is_a?(AST::Identifier)
        return false unless @imports.key?(callee.receiver.name)

        @imports.fetch(callee.receiver.name).name == "std.multiplayer" && callee.member == function_name
      end

      def multiplayer_root_specialization_call?(callee, function_name)
        callee.callee.is_a?(AST::MemberAccess) && multiplayer_root_import_call?(callee.callee, function_name)
      end

      def multiplayer_schema_type_name(type)
        type.to_s
      end

      def multiplayer_descriptor_hash(*components)
        hash = 14_695_981_039_346_656_037
        prime = 1_099_511_628_211
        mask = 0xffff_ffff_ffff_ffff

        components.each do |component|
          component.to_s.each_byte do |byte|
            hash ^= byte
            hash = (hash * prime) & mask
          end

          hash ^= 0xff
          hash = (hash * prime) & mask
        end

        hash.zero? ? 1 : hash
      end

      def evaluate_reflection_target_argument(expression, env:)
        struct_handle = resolve_struct_handle_argument(expression, env:)
        return struct_handle if struct_handle

        value = compile_time_const_value(expression, env:)
        return value if value.is_a?(Types::FieldHandle) || value.is_a?(Types::CallableHandle)

        nil
      end

      def reflection_positional_arguments?(arguments, expected_length)
        arguments.length == expected_length && arguments.none?(&:name)
      end

      def resolve_struct_handle_argument(expression, env:)
        type = reflection_type_from_expression(expression, env:)
        return nil unless type

        struct_handle_for_type(type)
      end

      def reflection_type_from_expression(expression, env:)
        case expression
        when AST::Identifier
          return nil if env && lookup_value(expression.name, env)

          @types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)

          imported_module = @imports[expression.receiver.name]
          return nil unless imported_module
          return nil if imported_module.private_type?(expression.member)

          imported_module.types[expression.member]
        else
          nil
        end
      end

      def struct_handle_for_type(type)
        base_type = type.is_a?(Types::StructInstance) ? type.definition : type
        return nil unless base_type.is_a?(Types::Struct) || base_type.is_a?(Types::GenericStructDefinition)
        return nil unless base_type.respond_to?(:module_name)

        analysis = analysis_for_module(base_type.module_name)
        declaration = analysis.ast.declarations.find do |decl|
          decl.is_a?(AST::StructDecl) && decl.name == base_type.name
        end
        return nil unless declaration

        Types::StructHandle.new(base_type, declaration)
      end

      def resolve_callable_handle_argument(expression)
        case expression
        when AST::Identifier
          binding = @functions[expression.name]
          return nil unless binding&.ast

          Types::CallableHandle.new(expression.name, binding.ast)
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)

          imported_module = @imports[expression.receiver.name]
          return nil unless imported_module
          return nil if imported_module.private_function?(expression.member)

          binding = imported_module.functions[expression.member]
          return nil unless binding&.ast

          Types::CallableHandle.new("#{expression.receiver.name}.#{expression.member}", binding.ast)
        else
          nil
        end
      end

      def resolve_attribute_name_argument(expression)
        case expression
        when AST::Identifier
          @analysis.attributes[expression.name] || builtin_attribute_binding(expression.name)
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)

          imported_module = @imports[expression.receiver.name]
          return nil unless imported_module
          return nil if imported_module.private_attribute?(expression.member)

          imported_module.attributes[expression.member]
        else
          nil
        end
      end

      def reflection_identifier_name(expression)
        expression.is_a?(AST::Identifier) ? expression.name : nil
      end

      def attribute_binding_supports_target?(binding, target)
        binding && target && binding.targets.include?(attribute_target_kind(target))
      end

      def attribute_target_kind(target)
        case target
        when Types::StructHandle then :struct
        when Types::FieldHandle then :field
        when Types::CallableHandle then :callable
        end
      end

      def resolved_attribute_applications_for_target(target)
        target_id = case target
        when Types::StructHandle then target.declaration.object_id
        when Types::FieldHandle then target.field_declaration.object_id
        when Types::CallableHandle then target.declaration.object_id
        end
        return [] unless target_id

        applications = @analysis.attribute_applications[target_id]
        return applications if applications

        @imports.each_value do |imported_module|
          applications = imported_module.attribute_applications[target_id]
          return applications if applications
        end

        []
      end

      def find_attribute_application(target, binding)
        resolved_attribute_applications_for_target(target).find do |application|
          same_attribute_binding?(application.binding, binding)
        end
      end

      def resolve_attribute_binding_for_name(name)
        case name.parts.length
        when 1
          @analysis.attributes[name.parts.first] || builtin_attribute_binding(name.parts.first)
        when 2
          imported_module = @imports[name.parts.first]
          return nil unless imported_module
          return nil if imported_module.private_attribute?(name.parts.last)

          imported_module.attributes[name.parts.last]
        else
          nil
        end
      end

      def same_attribute_binding?(left, right)
        left.name == right.name && left.module_name == right.module_name
      end

      def builtin_attribute_binding(name)
        Sema.builtin_attribute_binding(name, @types)
      end

      def attribute_argument_values(binding, application, env:)
        positional_index = 0

        application.arguments.each_with_object({}) do |argument, values|
          param_name = if argument.name
            argument.name
          else
            parameter = binding.params[positional_index]
            positional_index += 1
            parameter&.name
          end
          next unless param_name

          values[param_name] = compile_time_const_value(argument.value, env:)
        end
      end

      def specialize_function_binding(binding, arguments, env, receiver_type: nil)
        return binding if binding.type_params.empty?
        raise LoweringError, "generic function #{binding.name} must be called" unless arguments

        type_arguments = infer_function_type_arguments(binding, arguments, env, receiver_type:)
        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding_with_receiver(binding, explicit_type_arguments, receiver_type: nil)
        if binding.type_params.empty?
          raise LoweringError, "function #{binding.name} is not generic and cannot be specialized"
        end

        receiver_substitutions = infer_receiver_type_substitutions(binding, receiver_type)
        remaining_type_params = binding.type_params.reject { |name| receiver_substitutions.key?(name) }
        unless remaining_type_params.length == explicit_type_arguments.length
          raise LoweringError, "function #{binding.name} expects #{remaining_type_params.length} type arguments, got #{explicit_type_arguments.length}"
        end

        substitutions = receiver_substitutions.dup
        remaining_type_params.zip(explicit_type_arguments).each do |name, type_argument|
          raise LoweringError, "generic function #{binding.name} cannot be instantiated with ref types" if contains_ref_type?(type_argument)

          substitutions[name] = type_argument
        end

        type_arguments = binding.type_params.map do |name|
          inferred = substitutions[name]
          raise LoweringError, "cannot infer type argument #{name} for function #{binding.name}" unless inferred

          inferred
        end

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
        validate_function_type_param_constraints!(binding, substitutions)
        instance = Sema::FunctionBinding.new(
          name: binding.name,
          type: substitute_type(binding.type, substitutions),
          body_params: binding.body_params.map { |param| substitute_value_binding(param, substitutions) },
          body_return_type: substitute_type(binding.body_return_type, substitutions),
          ast: binding.ast,
          external: binding.external,
          async: binding.async,
          type_params: [].freeze,
          type_param_constraints: {}.freeze,
          instances: {},
          type_arguments: key,
          owner: binding.owner,
          specialization_owner: nil,
          type_substitutions: substitutions.freeze,
          declared_receiver_type: binding.declared_receiver_type ? substitute_type(binding.declared_receiver_type, substitutions) : nil,
        )
        binding.instances[key] = instance
      end

      def validate_function_type_param_constraints!(binding, substitutions)
        binding.type_param_constraints.each do |name, constraints|
          actual_type = substitutions[name]
          raise LoweringError, "cannot infer type argument #{name} for function #{binding.name}" unless actual_type

          constraints.interfaces.each do |interface|
            next if type_implements_interface?(actual_type, interface)

            raise LoweringError, "type #{actual_type} does not implement interface #{interface.name} for function #{binding.name}"
          end
        end
      end

      def interface_implementation_key(type)
        return type.definition if type.is_a?(Types::StructInstance)

        type
      end

      def type_implements_interface?(type, interface)
        key = interface_implementation_key(type)
        return true if @analysis.implemented_interfaces.fetch(key, []).include?(interface)

        @imports.each_value do |module_binding|
          return true if module_binding.implemented_interfaces.fetch(key, []).include?(interface)
        end

        false
      end

      def infer_function_type_arguments(binding, arguments, env, receiver_type: nil)
        expected_params = binding.type.params
        unless call_arity_matches?(binding.type, arguments.length)
          raise LoweringError, arity_error_message(binding.type, binding.name, arguments.length)
        end

        substitutions = infer_receiver_type_substitutions(binding, receiver_type)
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

      def method_dispatch_receiver_type(receiver_type)
        return receiver_type.definition if receiver_type.is_a?(Types::StructInstance)
        if receiver_type.is_a?(Types::Nullable)
          dispatch_base_type = method_dispatch_receiver_type(receiver_type.base)
          return receiver_type if dispatch_base_type == receiver_type.base

          return Types::Nullable.new(dispatch_base_type)
        end
        return receiver_type unless receiver_type.is_a?(Types::GenericInstance)

        dispatch_receiver_type = Types::GenericInstance.new(
          receiver_type.name,
          receiver_type.arguments.each_with_index.map do |argument, index|
            argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
          end,
        )
        dispatch_receiver_type == receiver_type ? receiver_type : dispatch_receiver_type
      end

      def resolve_named_generic_type_for_analysis(analysis, parts)
        if parts.length == 1
          type = analysis.types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        elsif parts.length == 2 && analysis.imports.key?(parts.first)
          type = analysis.imports.fetch(parts.first).types[parts.last]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        end

        nil
      end

      def validate_methods_receiver_type_arguments!(type_ref, generic_type)
        names = type_ref.arguments.map do |argument|
          value = argument.value
          next unless value.is_a?(AST::TypeRef)
          next unless value.arguments.empty? && !value.nullable && value.name.parts.length == 1

          value.name.parts.first
        end

        expected_names = generic_type.type_params
        unless names == expected_names
          raise LoweringError, "extending target #{type_ref} must use the receiver type parameters directly"
        end

        expected_names
      end

      def methods_receiver_type_argument_names!(type_ref)
        names = type_ref.arguments.map do |argument|
          value = argument.value
          next unless value.is_a?(AST::TypeRef)
          next unless value.arguments.empty? && !value.nullable && value.name.parts.length == 1

          value.name.parts.first
        end

        raise LoweringError, "extending target #{type_ref} must use the receiver type parameters directly" if names.any?(&:nil?)

        names
      end

      def infer_receiver_type_substitutions(binding, receiver_type)
        declared_receiver_type = binding.declared_receiver_type
        return {} unless declared_receiver_type
        case declared_receiver_type
        when Types::Nullable
          unless receiver_type.is_a?(Types::Nullable)
            raise LoweringError, "cannot use method #{binding.name} with receiver #{receiver_type}"
          end

          infer_receiver_type_substitutions(
            binding.with(declared_receiver_type: declared_receiver_type.base),
            receiver_type.base,
          )
        when Types::StructInstance
          return {} unless declared_receiver_type.definition.is_a?(Types::GenericStructDefinition)

          unless receiver_type.is_a?(Types::StructInstance) && receiver_type.definition == declared_receiver_type.definition
            raise LoweringError, "cannot use method #{binding.name} with receiver #{receiver_type}"
          end

          declared_receiver_type.definition.type_params.zip(receiver_type.arguments).to_h
        when Types::GenericInstance
          unless receiver_type.is_a?(Types::GenericInstance) && receiver_type.name == declared_receiver_type.name && receiver_type.arguments.length == declared_receiver_type.arguments.length
            raise LoweringError, "cannot use method #{binding.name} with receiver #{receiver_type}"
          end

          declared_receiver_type.arguments.zip(receiver_type.arguments).each_with_object({}) do |(declared_argument, actual_argument), substitutions|
            if declared_argument.is_a?(Types::TypeVar)
              substitutions[declared_argument.name] = actual_argument
            elsif declared_argument != actual_argument
              raise LoweringError, "cannot use method #{binding.name} with receiver #{receiver_type}"
            end
          end
        else
          {}
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
          if ref_type?(pattern_type) && !ref_type?(actual_type)
            collect_type_substitutions(referenced_type(pattern_type), actual_type, substitutions, function_name)
            return
          end

          return unless actual_type.is_a?(Types::GenericInstance)
          return unless actual_type.name == pattern_type.name && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            next if expected_argument.is_a?(Types::LiteralTypeArg)

            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Span
          return unless actual_type.is_a?(Types::Span)

          collect_type_substitutions(pattern_type.element_type, actual_type.element_type, substitutions, function_name)
        when Types::Task
          return unless actual_type.is_a?(Types::Task)

          collect_type_substitutions(pattern_type.result_type, actual_type.result_type, substitutions, function_name)
        when Types::Proc
          if task_root_proc_type?(pattern_type) && actual_type.is_a?(Types::Task)
            collect_type_substitutions(pattern_type.return_type, actual_type, substitutions, function_name)
            return
          end

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
        when Types::VariantInstance
          return unless actual_type.is_a?(Types::VariantInstance)
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
        mutable_pointer_type?(type) || const_pointer_type?(type)
      end

      def mutable_pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
      end

      def const_pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "const_ptr" && type.arguments.length == 1
      end

      def ref_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ref" && type.arguments.length == 1
      end

      def range_expr?(expression)
        expression.is_a?(AST::RangeExpr)
      end

      def range_iterable?(expression)
        range_expr?(expression)
      end

      def range_start_of(iterable)
        iterable.start_expr
      end

      def range_end_of(iterable)
        iterable.end_expr
      end

      def wildcard_arm_pattern?(expression)
        expression.is_a?(AST::Identifier) && expression.name == "_"
      end

      def variant_match_arm_name_from_pattern(pattern)
        # pattern is TypeName.arm_name or module.TypeName.arm_name
        pattern.is_a?(AST::MemberAccess) ? pattern.member : nil
      end

      def async_variant_match_arm_binding(arm, scrutinee_expr, scrutinee_type, env:)
        arm_env = duplicate_env(env)
        binding_decl = nil

        if arm.binding_name && !wildcard_arm_pattern?(arm.pattern)
          arm_name = variant_match_arm_name_from_pattern(arm.pattern)
          if arm_name && scrutinee_type.has_payload?(arm_name)
            fields = scrutinee_type.arm(arm_name)
            payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
            data_expr = IR::Member.new(receiver: scrutinee_expr, member: "data", type: nil)
            arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
            binding_c = c_local_name(arm.binding_name)
            arm_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: binding_c, mutable: false, pointer: false)
            binding_decl = IR::LocalDecl.new(name: arm.binding_name, c_name: binding_c, type: payload_type, value: arm_expr)
          end
        end

        [arm_env, binding_decl]
      end

      def bind_async_variant_match_arm_env!(arm_env, scrutinee_type, arm)
        return unless scrutinee_type.is_a?(Types::Variant)
        return unless arm.binding_name && !wildcard_arm_pattern?(arm.pattern)

        arm_name = variant_match_arm_name_from_pattern(arm.pattern)
        return unless arm_name && scrutinee_type.has_payload?(arm_name)

        fields = scrutinee_type.arm(arm_name)
        payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
        arm_env[:scopes].last[arm.binding_name] = local_binding(type: payload_type, c_name: c_local_name(arm.binding_name), mutable: false, pointer: false)
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

      def str_buffer_to_span_compatible?(actual_type, expected_type)
        str_buffer_type?(actual_type) && expected_type.is_a?(Types::Span) && expected_type.element_type == @types.fetch("char")
      end

      def array_length(type)
        return unless array_type?(type)

        type.arguments[1].value
      end

      def char_array_text_type?(type)
        array_type?(type) && array_element_type(type) == @types.fetch("char")
      end

      def str_buffer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1 &&
          type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments.first.value.is_a?(Integer)
      end

      def str_buffer_capacity(type)
        type.arguments.first.value
      end

      def str_buffer_storage_capacity(type)
        str_buffer_capacity(type) + 1
      end

      def str_buffer_method_kind(receiver_type, name)
        return unless str_buffer_type?(receiver_type)

        case name
        when "clear"
          :str_buffer_clear
        when "assign"
          :str_buffer_assign
        when "append"
          :str_buffer_append
        when "assign_format"
          :str_buffer_assign_format
        when "append_format"
          :str_buffer_append_format
        when "len"
          :str_buffer_len
        when "capacity"
          :str_buffer_capacity
        when "as_str"
          :str_buffer_as_str
        when "as_cstr"
          :str_buffer_as_cstr
        end
      end

      def str_buffer_method_type(kind, receiver_type)
        return_type, params = case kind
                              when :str_buffer_clear
                                [@types.fetch("void"), []]
                              when :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format
                                [@types.fetch("void"), [Types::Parameter.new("value", @types.fetch("str"))]]
                              when :str_buffer_len, :str_buffer_capacity
                                [@types.fetch("ptr_uint"), []]
                              when :str_buffer_as_str
                                [@types.fetch("str"), []]
                              when :str_buffer_as_cstr
                                [@types.fetch("cstr"), []]
                              else
                                raise LoweringError, "unsupported str_buffer method #{kind}"
                              end

        Types::Function.new(
          kind.to_s,
          params:,
          return_type:,
          receiver_type:,
          receiver_mutable: %i[str_buffer_clear str_buffer_assign str_buffer_append str_buffer_assign_format str_buffer_append_format].include?(kind),
          external: false,
        )
      end

      def lower_char_array_data_pointer(expression, env:)
        lowered_receiver = lower_expression(expression, env:)
        IR::AddressOf.new(
          expression: IR::Index.new(
            receiver: lowered_receiver,
            index: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")),
            type: @types.fetch("char"),
          ),
          type: pointer_to(@types.fetch("char")),
        )
      end

      def lower_str_buffer_data_pointer(expression, env:)
        lower_str_buffer_data_pointer_from_lowered(lower_expression(expression, env:))
      end

      def lower_str_buffer_data_pointer_from_lowered(lowered_receiver)
        IR::AddressOf.new(
          expression: IR::Index.new(
            receiver: IR::Member.new(
              receiver: lowered_receiver,
              member: "data",
              type: Types::GenericInstance.new(
                "array",
                [@types.fetch("char"), Types::LiteralTypeArg.new(str_buffer_storage_capacity(lowered_receiver.type))],
              ),
            ),
            index: IR::IntegerLiteral.new(value: 0, type: @types.fetch("ptr_uint")),
            type: @types.fetch("char"),
          ),
          type: pointer_to(@types.fetch("char")),
        )
      end

      def lower_str_buffer_len_pointer(expression, env:)
        lower_str_buffer_len_pointer_from_lowered(lower_expression(expression, env:))
      end

      def lower_str_buffer_len_pointer_from_lowered(lowered_receiver)
        IR::AddressOf.new(
          expression: IR::Member.new(receiver: lowered_receiver, member: "len", type: @types.fetch("ptr_uint")),
          type: pointer_to(@types.fetch("ptr_uint")),
        )
      end

      def lower_str_buffer_dirty_pointer(expression, env:)
        lower_str_buffer_dirty_pointer_from_lowered(lower_expression(expression, env:))
      end

      def lower_str_buffer_dirty_pointer_from_lowered(lowered_receiver)
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

      def infer_method_receiver_type(receiver_expression, env:, member_name: nil)
        receiver_type = infer_expression_type(receiver_expression, env:)
        receiver_type = referenced_type(receiver_type) if ref_type?(receiver_type)

        if pointer_type?(receiver_type)
          dispatch_receiver_type = method_dispatch_receiver_type(receiver_type)
          return receiver_type if member_name && (@method_definitions.key?([receiver_type, member_name]) || @method_definitions.key?([dispatch_receiver_type, member_name]))

          return pointee_type(receiver_type)
        end

        receiver_type
      end

      def infer_field_receiver_type(receiver_expression, env:)
        receiver_type = infer_expression_type(receiver_expression, env:)
        return referenced_type(receiver_type) if ref_type?(receiver_type)
        return pointee_type(receiver_type) if pointer_type?(receiver_type)

        receiver_type
      end

      def collection_loop_type(type)
        return array_element_type(type) if array_type?(type)
        return type.element_type if type.is_a?(Types::Span)

        nil
      end

      def collection_loop_binding_type(iterable_type, element_type)
        return nil unless array_type?(iterable_type) || iterable_type.is_a?(Types::Span)
        return nil unless collection_loop_ref_element_type?(element_type)

        Types::GenericInstance.new("ref", [element_type])
      end

      def collection_loop_ref_element_type?(type)
        type.is_a?(Types::Struct)
      end

      def iterator_loop_info(type, env:)
        iter_name = "__mt_for_iterable__"
        iterator_name = "__mt_for_iterator__"
        probe_env = duplicate_env(env)
        current_actual_scope(probe_env[:scopes])[iter_name] = local_binding(type:, c_name: iter_name, mutable: false, pointer: false)

        iter_call = AST::Call.new(
          callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iter_name), member: "iter"),
          arguments: [],
        )
        iterator_type = infer_expression_type(iter_call, env: probe_env)

        current_actual_scope(probe_env[:scopes])[iterator_name] = local_binding(type: iterator_type, c_name: iterator_name, mutable: true, pointer: false)
        next_call = AST::Call.new(
          callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "next"),
          arguments: [],
        )
        item_storage_type = infer_expression_type(next_call, env: probe_env)
        if item_storage_type.is_a?(Types::Nullable) && nullable_iterator_item_type?(item_storage_type.base)
          return {
            kind: :nullable_item,
            iterator_type:,
            item_storage_type:,
            item_type: item_storage_type.base,
          }
        end

        if item_storage_type == @types.fetch("bool")
          current_call = AST::Call.new(
            callee: AST::MemberAccess.new(receiver: AST::Identifier.new(name: iterator_name), member: "current"),
            arguments: [],
          )
          current_type = infer_expression_type(current_call, env: probe_env)
          return {
            kind: :current_item,
            iterator_type:,
            item_storage_type: current_type,
            item_type: current_type,
          }
        end

        nil
      rescue SemaError
        nil
      end

      def nullable_iterator_item_type?(type)
        type == @types.fetch("cstr") || pointer_type?(type)
      end

      def collection_loop_item_value(iterable_ref, iterable_type, index_ref, element_type)
        if array_type?(iterable_type)
          IR::Index.new(receiver: iterable_ref, index: index_ref, type: element_type)
        else
          data_ref = IR::Member.new(receiver: iterable_ref, member: "data", type: pointer_to(element_type))
          IR::Index.new(receiver: data_ref, index: index_ref, type: element_type)
        end
      end

      def collection_loop_stop_value(iterable_ref, iterable_type)
        if array_type?(iterable_type)
          IR::IntegerLiteral.new(value: array_length(iterable_type), type: @types.fetch("ptr_uint"))
        else
          IR::Member.new(receiver: iterable_ref, member: "len", type: @types.fetch("ptr_uint"))
        end
      end

      def lower_fatal_statement(message, env:)
        IR::ExpressionStmt.new(
          expression: lower_expression(
            AST::Call.new(
              callee: AST::Identifier.new(name: "fatal"),
              arguments: [AST::Argument.new(name: nil, value: AST::StringLiteral.new(lexeme: message.inspect, value: message, cstring: false))],
            ),
            env:,
            expected_type: @types.fetch("void"),
          ),
        )
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
        @module_prefix = module_c_prefix(@module_name)
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

      def resolve_type_ref_for_analysis(type_ref, analysis, type_params: current_type_params)
        saved_analysis = @analysis
        saved_module_name = @module_name
        saved_module_prefix = @module_prefix
        saved_imports = @imports
        saved_types = @types
        saved_values = @values
        saved_functions = @functions

        @analysis = analysis
        @module_name = analysis.module_name
        @module_prefix = module_c_prefix(@module_name)
        @imports = analysis.imports
        @types = analysis.types
        @values = analysis.values
        @functions = analysis.functions
        resolve_type_ref(type_ref, type_params:)
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
                 if name == "Task"
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
        if expected_type && (literal = lower_compile_time_literal(compile_time_const_value(expression, env:), expected_type))
          return literal
        end

        lower_expression(rewrite_static_storage_initializer(expression), env:, expected_type: expected_type)
      end

      def lower_compile_time_literal(value, type)
        case value
        when true, false
          return IR::BooleanLiteral.new(value:, type:) if type.is_a?(Types::Primitive) && type.boolean?
        when Integer
          return IR::IntegerLiteral.new(value:, type:) if type.is_a?(Types::Primitive) && type.integer?
          return IR::FloatLiteral.new(value: value.to_f, type:) if type.is_a?(Types::Primitive) && type.float?
        when Float
          return IR::FloatLiteral.new(value:, type:) if type.is_a?(Types::Primitive) && type.float?
        when String
          if type == @types.fetch("str") || type == @types.fetch("cstr")
            return IR::StringLiteral.new(value:, type:, cstring: type == @types.fetch("cstr"))
          end
        end

        nil
      end

      def compile_time_builtin_function_type(name, arguments, env)
        return_type = case name
        when "field_of"
          @types.fetch("field_handle")
        when "callable_of"
          @types.fetch("callable_handle")
        when "has_attribute"
          @types.fetch("bool")
        when "attribute_of"
          @types.fetch("attribute_handle")
        else
          nil
        end
        raise LoweringError, "unsupported compile-time builtin #{name}" unless return_type

        Types::Function.new(name, params: [], return_type: return_type)
      end

      def compile_time_builtin_specialization_function_type(callee)
        Types::Function.new("attribute_arg", params: [], return_type: resolve_type_ref(callee.arguments.fetch(0).value))
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
        when AST::UnsafeExpr
          AST::UnsafeExpr.new(expression: rewrite_static_storage_initializer(expression.expression))
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

      def local_binding(type:, c_name:, mutable:, pointer:, storage_type: nil, projection: nil, cstr_backed: false, cstr_list_backed: false, const_value: nil)
        { type:, storage_type: storage_type || type, c_name:, mutable:, pointer:, projection:, cstr_backed:, cstr_list_backed:, const_value: }
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

      def switch_loop_target(target)
        return target unless target && target[:label]

        loop_exit_label(target[:label])
      end

      def switch_loop_flow(current_loop_flow, local_defers)
        nested = nested_loop_flow(current_loop_flow, local_defers)
        return nil unless nested

        loop_flow(
          break_target: switch_loop_target(nested[:break_target]),
          continue_target: switch_loop_target(nested[:continue_target]),
          break_defers: nested[:break_defers],
          continue_defers: nested[:continue_defers],
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
          return IR::GotoStmt.new(label: target[:label]) if target[:label]

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

      def lower_async_loop_exit(target, local_defers, outer_defers, frame_expr:, raw_frame_expr:, async_info:)
        cleanup = lower_async_cleanup_entries(local_defers, outer_defers, frame_expr:, raw_frame_expr:, async_info:)
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
        prepared_setup, prepared_expression, prepared_cleanups = prepare_expression_with_cleanups(
          expression,
          env:,
          expected_type: infer_expression_type(expression, env:),
          allow_root_statement_foreign: true,
        )

        lowered = []
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
          lowered << IR::ExpressionStmt.new(expression: lower_expression(prepared_expression, env:))
        end
        lowered.concat(prepared_cleanups.flat_map(&:itself))
        lowered
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

      def snapshot_env(env)
        { scopes: env[:scopes].map(&:dup), counter: env[:counter] }
      end

      def duplicate_env(env)
        duplicated = env.dup
        duplicated[:scopes] = env[:scopes].map(&:dup) + [{}]
        duplicated[:counter] = env[:counter]
        duplicated.delete(:prepared_expression_cleanups)
        duplicated
      end

      def let_else_discard_binding_syntax?(statement)
        statement.is_a?(AST::LocalDecl) && statement.else_body && statement.name == "_"
      end

      def bind_let_else_local?(statement)
        !let_else_discard_binding_syntax?(statement)
      end

      def async_local_decl_field_key(statement)
        return statement.name unless let_else_discard_binding_syntax?(statement)

        "__let_else_discard_#{statement.object_id}"
      end

      def async_local_decl_field_name(statement)
        return "local_#{statement.name}" unless let_else_discard_binding_syntax?(statement)

        "local_let_else_discard_#{statement.object_id}"
      end

      def let_else_storage_c_name(statement, env)
        return c_local_name(statement.name) unless let_else_discard_binding_syntax?(statement)

        fresh_c_temp_name(env, "let_else_discard")
      end

      def let_else_success_type(type)
        return type.base if type.is_a?(Types::Nullable)
        return type.arm("some").fetch("value") if option_let_else_type?(type)
        return unless result_let_else_type?(type)

        type.arm("success").fetch("value")
      end

      def let_else_error_type(type)
        return unless result_let_else_type?(type)

        type.arm("failure").fetch("error")
      end

      def let_else_binding_projection(type)
        return :result_success_value if result_let_else_type?(type)
        return :option_some_value if option_let_else_type?(type)

        nil
      end

      def option_let_else_type?(type)
        return false unless type.is_a?(Types::Variant)
        return false unless type.module_name.nil? && type.name == "Option"

        some_fields = type.arm("some")
        none_fields = type.arm("none")
        some_fields && some_fields.length == 1 && some_fields.key?("value") &&
          none_fields && none_fields.empty?
      end

      def result_let_else_type?(type)
        return false unless type.is_a?(Types::Variant)
        return false unless type.module_name.nil? && type.name == "Result"

        success_fields = type.arm("success")
        failure_fields = type.arm("failure")
        success_fields && success_fields.length == 1 && success_fields.key?("value") &&
          failure_fields && failure_fields.length == 1 && failure_fields.key?("error")
      end

      def let_else_failure_condition(storage_expr, storage_type)
        if storage_type.is_a?(Types::Nullable)
          return IR::Binary.new(
            operator: "==",
            left: storage_expr,
            right: IR::NullLiteral.new(type: storage_type),
            type: @types.fetch("bool"),
          )
        end

        if result_let_else_type?(storage_type)
          kind_type = @types.fetch("int")
          return IR::Binary.new(
            operator: "==",
            left: IR::Member.new(receiver: storage_expr, member: "kind", type: kind_type),
            right: IR::Name.new(name: "#{c_type_name(storage_type)}_kind_failure", type: kind_type, pointer: false),
            type: @types.fetch("bool"),
          )
        end

        if option_let_else_type?(storage_type)
          kind_type = @types.fetch("int")
          return IR::Binary.new(
            operator: "==",
            left: IR::Member.new(receiver: storage_expr, member: "kind", type: kind_type),
            right: IR::Name.new(name: "#{c_type_name(storage_type)}_kind_none", type: kind_type, pointer: false),
            type: @types.fetch("bool"),
          )
        end

        raise LoweringError, "unsupported let-else storage type #{storage_type}"
      end

      def lower_bound_identifier(binding)
        storage_type = binding[:storage_type]
        visible_type = binding[:type]
        projection = binding[:projection]

        if projection == :result_success_value
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "success", "value", visible_type)
        end

        if projection == :result_failure_error
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "failure", "error", visible_type)
        end

        if projection == :option_some_value
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "some", "value", visible_type)
        end

        return IR::Name.new(name: binding[:c_name], type: visible_type, pointer: binding[:pointer]) if visible_type == storage_type
        return IR::Name.new(name: binding[:c_name], type: visible_type, pointer: binding[:pointer]) if storage_type.is_a?(Types::Nullable) && storage_type.base == visible_type

        if result_let_else_type?(storage_type) && let_else_success_type(storage_type) == visible_type
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "success", "value", visible_type)
        end

        if option_let_else_type?(storage_type) && let_else_success_type(storage_type) == visible_type
          local_ref = IR::Name.new(name: binding[:c_name], type: storage_type, pointer: binding[:pointer])
          return variant_binding_projection_expression(local_ref, storage_type, "some", "value", visible_type)
        end

        IR::Name.new(name: binding[:c_name], type: visible_type, pointer: binding[:pointer])
      end

      def variant_binding_projection_expression(storage_expr, storage_type, arm_name, field_name, field_type)
        payload_type = Types::VariantArmPayload.new(storage_type, arm_name, storage_type.arm(arm_name))
        data_expr = IR::Member.new(receiver: storage_expr, member: "data", type: nil)
        arm_expr = IR::Member.new(receiver: data_expr, member: arm_name, type: payload_type)
        IR::Member.new(receiver: arm_expr, member: field_name, type: field_type)
      end

      def infer_result_propagation_type(expression, env:)
        _storage_type, success_type, = infer_result_propagation_types(expression, env:)

        success_type
      end

      def infer_result_propagation_types(expression, env:, allow_void_success: false)
        storage_type = infer_expression_type(expression.operand, env:)
        raise LoweringError, "propagation expects Result[T, E], got #{storage_type}" unless result_let_else_type?(storage_type)

        success_type = let_else_success_type(storage_type)
        error_type = let_else_error_type(storage_type)
        raise LoweringError, "propagation requires a non-void Result success type" if success_type == @types.fetch("void") && !allow_void_success

        context = env[:return_context]
        raise LoweringError, "propagation is only allowed inside function and proc bodies" unless context
        raise LoweringError, "propagation is not allowed inside defer blocks" unless context[:allow_return]

        return_type = context[:return_type]
        unless result_let_else_type?(return_type)
          raise LoweringError, "propagation requires enclosing function/proc to return Result[_, #{error_type}], got #{return_type}"
        end

        return_error_type = let_else_error_type(return_type)
        unless return_error_type == error_type
          raise LoweringError, "propagation error type #{error_type} must match enclosing Result error type #{return_error_type}"
        end

        [storage_type, success_type, return_type, error_type]
      end

      def prepare_result_propagation_for_inline_lowering(expression, env:, allow_void_success: false)
        storage_type, success_type, return_type, error_type = infer_result_propagation_types(expression, env:, allow_void_success:)

        env[:prepared_expression_cleanups] ||= []
        cleanup_start = env[:prepared_expression_cleanups].length
        operand_setup, operand = prepare_expression_for_inline_lowering(expression.operand, env:, expected_type: storage_type)
        operand_cleanups = env[:prepared_expression_cleanups].drop(cleanup_start)

        result_name = fresh_c_temp_name(env, "propagate")
        result_ref = IR::Name.new(name: result_name, type: storage_type, pointer: false)
        return_context = env.fetch(:return_context)
        failure_return = if storage_type == return_type
                           result_ref
                         else
                           IR::VariantLiteral.new(
                             type: return_type,
                             arm_name: "failure",
                             fields: [
                               IR::AggregateField.new(
                                 name: "error",
                                 value: variant_binding_projection_expression(result_ref, storage_type, "failure", "error", error_type),
                               ),
                             ],
                           )
                         end
        failure_cleanup = operand_cleanups.flat_map(&:itself)
        failure_terminator = if return_context[:async_info]
                               failure_cleanup +
                                 lower_async_cleanup_entries(
                                   return_context[:local_defers],
                                   return_context[:active_defers],
                                   frame_expr: return_context.fetch(:frame_expr),
                                   raw_frame_expr: return_context.fetch(:raw_frame_expr),
                                   async_info: return_context.fetch(:async_info),
                                 ) +
                                 async_complete_statements(
                                   frame_expr: return_context.fetch(:frame_expr),
                                   raw_frame_expr: return_context.fetch(:raw_frame_expr),
                                   async_info: return_context.fetch(:async_info),
                                   value: failure_return,
                                 )
                             else
                               failure_cleanup +
                                 cleanup_statements(return_context[:local_defers], return_context[:active_defers]) +
                                 [IR::ReturnStmt.new(value: failure_return, source_path: @current_analysis_path)]
                             end

        if success_type == @types.fetch("void")
          return [
            operand_setup + [
              IR::LocalDecl.new(
                name: result_name,
                c_name: result_name,
                type: storage_type,
                value: lower_contextual_expression(operand, env:, expected_type: storage_type),
              ),
              IR::IfStmt.new(
                condition: let_else_failure_condition(result_ref, storage_type),
                then_body: failure_terminator,
                else_body: nil,
              ),
            ],
            nil,
          ]
        end

        register_prepared_temp!(env, result_name, success_type, storage_type:, projection: :result_success_value)

        [
          operand_setup + [
            IR::LocalDecl.new(
              name: result_name,
              c_name: result_name,
              type: storage_type,
              value: lower_contextual_expression(operand, env:, expected_type: storage_type),
            ),
            IR::IfStmt.new(
              condition: let_else_failure_condition(result_ref, storage_type),
              then_body: failure_terminator,
              else_body: nil,
            ),
          ],
          AST::Identifier.new(name: result_name),
        ]
      end

      def c_type_name(type)
        if type.is_a?(Types::Nullable)
          return "nullable_#{c_type_name(type.base)}"
        end

        if type.respond_to?(:c_name) && type.c_name
          return type.c_name
        end

        if type.is_a?(Types::GenericInstance)
          base = if type.respond_to?(:module_name) && type.module_name&.start_with?("std.c.")
                   type.name
                 elsif type.respond_to?(:module_name) && !type.module_name.nil?
                   "#{module_c_prefix(type.module_name)}_#{type.name}"
                 else
                   type.name
                 end

          return "#{base}_#{sanitize_identifier(type.arguments.join('_'))}"
        end

        return type.name if type.module_name&.start_with?("std.c.")

        base = type.module_name ? "#{module_c_prefix(type.module_name)}_#{type.name}" : type.name
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
        when "str_buffer"
          raise LoweringError, "str_buffer requires exactly one type argument" unless arguments.length == 1
          raise LoweringError, "str_buffer capacity must be an integer literal, named const, or type parameter" unless generic_integer_type_argument?(arguments.first)
          raise LoweringError, "str_buffer capacity must be positive" if integer_type_argument?(arguments.first) && !arguments.first.value.positive?
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
          return binding.async ? module_function_c_name(module_name, "__async_main") : module_function_c_name(module_name, "main")
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
        return name if imported_analysis.module_kind == :raw_module

        module_value_c_name(imported_module.name, name)
      end

      def module_function_c_name(module_name, name, type_arguments: [])
        base = "#{module_c_prefix(module_name)}_#{name}"
        return base if type_arguments.empty?

        "#{base}_#{sanitize_identifier(type_arguments.join('_'))}"
      end

      def module_value_c_name(module_name, name)
        "#{module_c_prefix(module_name)}_#{name}"
      end

      def module_c_prefix(module_name)
        sanitize_identifier(module_name.to_s.tr('.', '_'))
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
