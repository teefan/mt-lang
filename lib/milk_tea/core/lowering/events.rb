# frozen_string_literal: true

module MilkTea
  module LowererEvents
    private

      def event_method_kind(receiver_type, member_name)
        return unless receiver_type.is_a?(Types::Event)

        TypeCompatibilityPredicates::EVENT_METHOD_KINDS[member_name]
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
              Types::Parameter.new("state", pointer_to(@ctx.types.fetch("void"))),
              Types::Parameter.new("listener", event_stateful_listener_function_type(event_type)),
            ],
            return_type: event_subscription_result_type,
          )
        when :event_unsubscribe
          Types::Function.new(
            kind.to_s,
            params: [Types::Parameter.new("subscription", @ctx.types.fetch("Subscription"))],
            return_type: @ctx.types.fetch("bool"),
          )
        when :event_emit
          params = []
          params << Types::Parameter.new("payload", event_type.payload_type) if event_type.payload_type
          Types::Function.new(kind.to_s, params:, return_type: @ctx.types.fetch("void"))
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
        Types::Function.new("#{event_type.name}__listener", params:, return_type: @ctx.types.fetch("void"))
      end

      def event_stateful_listener_function_type(event_type)
        params = [Types::Parameter.new("state", pointer_to(@ctx.types.fetch("void")))]
        params << Types::Parameter.new("payload", event_type.payload_type) if event_type.payload_type
        Types::Function.new("#{event_type.name}__stateful_listener", params:, return_type: @ctx.types.fetch("void"))
      end

      def array_of(type, length)
        Types::GenericInstance.new("array", [type, Types::LiteralTypeArg.new(length)])
      end

      def ensure_subscription_runtime
        return if @artifacts.subscription_runtime_emitted

        subscription_type = @ctx.types.fetch("Subscription")
        @artifacts.synthetic_structs << IR::StructDecl.new(
          name: subscription_type.name,
          c_name: subscription_type.c_name,
          fields: [
            IR::Field.new(name: "slot", type: @ctx.types.fetch("ptr_uint")),
            IR::Field.new(name: "generation", type: @ctx.types.fetch("ptr_uint")),
          ],
          packed: false,
          alignment: nil,
        )
        @artifacts.subscription_runtime_emitted = true
      end

      def ensure_event_error_enum
        return if @artifacts.event_error_enum_emitted

        event_error_type = @ctx.types.fetch("EventError")
        @artifacts.synthetic_enums << IR::EnumDecl.new(
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
        @artifacts.event_error_enum_emitted = true
      end

      def ensure_event_runtime(event_type)
        return @artifacts.event_runtime_infos.fetch(event_type) if @artifacts.event_runtime_infos.key?(event_type)

        ensure_subscription_runtime
        ensure_event_error_enum

        void_ptr = pointer_to(@ctx.types.fetch("void"))
        listener_type = event_listener_function_type(event_type)
        subscription_result_type = event_subscription_result_type
        wait_result_type = event_wait_result_type(event_type)
        task_type = Types::Task.new(wait_result_type)
        wake_type = task_type.field("ready").params.fetch(0).type == void_ptr ? task_type.field("set_waiter").params.fetch(2).type : Types::Function.new(nil, params: [Types::Parameter.new("frame", void_ptr)], return_type: @ctx.types.fetch("void"))
        slot_type = Types::Struct.new("#{event_type.c_name}__slot").define_fields(
          "active" => @ctx.types.fetch("bool"),
          "once" => @ctx.types.fetch("bool"),
          "generation" => @ctx.types.fetch("ptr_uint"),
          "state" => void_ptr,
          "listener" => void_ptr,
          "wait_frame" => void_ptr,
        )
        snapshot_type = Types::Struct.new("#{event_type.c_name}__snapshot").define_fields(
          "slot" => @ctx.types.fetch("ptr_uint"),
          "generation" => @ctx.types.fetch("ptr_uint"),
          "once" => @ctx.types.fetch("bool"),
          "wait_slot" => @ctx.types.fetch("bool"),
          "stateful" => @ctx.types.fetch("bool"),
          "state" => void_ptr,
          "listener" => void_ptr,
        )
        wait_frame_type = Types::Struct.new("#{event_type.c_name}__wait_frame").define_fields(
          "ready" => @ctx.types.fetch("bool"),
          "waiter_frame" => void_ptr,
          "waiter" => wake_type,
          "event" => void_ptr,
          "subscription" => @ctx.types.fetch("Subscription"),
          "result" => wait_result_type,
        )
        slots_type = array_of(slot_type, event_type.capacity)
        snapshots_type = array_of(snapshot_type, event_type.capacity)

        @artifacts.synthetic_structs << IR::StructDecl.new(
          name: slot_type.name,
          c_name: slot_type.name,
          fields: [
            IR::Field.new(name: "active", type: @ctx.types.fetch("bool")),
            IR::Field.new(name: "once", type: @ctx.types.fetch("bool")),
            IR::Field.new(name: "generation", type: @ctx.types.fetch("ptr_uint")),
            IR::Field.new(name: "state", type: void_ptr),
            IR::Field.new(name: "listener", type: void_ptr),
            IR::Field.new(name: "wait_frame", type: void_ptr),
          ],
          packed: false,
          alignment: nil,
        )
        @artifacts.synthetic_structs << IR::StructDecl.new(
          name: snapshot_type.name,
          c_name: snapshot_type.name,
          fields: [
            IR::Field.new(name: "slot", type: @ctx.types.fetch("ptr_uint")),
            IR::Field.new(name: "generation", type: @ctx.types.fetch("ptr_uint")),
            IR::Field.new(name: "once", type: @ctx.types.fetch("bool")),
            IR::Field.new(name: "wait_slot", type: @ctx.types.fetch("bool")),
            IR::Field.new(name: "stateful", type: @ctx.types.fetch("bool")),
            IR::Field.new(name: "state", type: void_ptr),
            IR::Field.new(name: "listener", type: void_ptr),
          ],
          packed: false,
          alignment: nil,
        )
        @artifacts.synthetic_structs << IR::StructDecl.new(
          name: wait_frame_type.name,
          c_name: wait_frame_type.name,
          fields: [
            IR::Field.new(name: "ready", type: @ctx.types.fetch("bool")),
            IR::Field.new(name: "waiter_frame", type: void_ptr),
            IR::Field.new(name: "waiter", type: wake_type),
            IR::Field.new(name: "event", type: void_ptr),
            IR::Field.new(name: "subscription", type: @ctx.types.fetch("Subscription")),
            IR::Field.new(name: "result", type: wait_result_type),
          ],
          packed: false,
          alignment: nil,
        )
        @artifacts.synthetic_structs << IR::StructDecl.new(
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
          stateful_listener_type: event_stateful_listener_function_type(event_type),
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

        @artifacts.synthetic_functions << build_event_subscribe_function(runtime, once: false)
        @artifacts.synthetic_functions << build_event_subscribe_function(runtime, once: true)
        @artifacts.synthetic_functions << build_event_subscribe_stateful_function(runtime, once: false)
        @artifacts.synthetic_functions << build_event_subscribe_stateful_function(runtime, once: true)
        @artifacts.synthetic_functions << build_event_unsubscribe_function(runtime)
        @artifacts.synthetic_functions << build_event_emit_function(runtime)
        @artifacts.synthetic_functions << build_event_wait_ready_function(runtime)
        @artifacts.synthetic_functions << build_event_wait_set_waiter_function(runtime)
        @artifacts.synthetic_functions << build_event_wait_release_function(runtime)
        @artifacts.synthetic_functions << build_event_wait_take_result_function(runtime)
        @artifacts.synthetic_functions << build_event_wait_function(runtime)

        @artifacts.event_runtime_infos[event_type] = runtime
      end

      def build_event_subscribe_function(runtime, once:)
        event_expr = IR::Name.new(name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)
        listener_expr = IR::Name.new(name: "listener", type: runtime.fetch(:listener_type), pointer: false)
        slot_index_expr = IR::Name.new(name: "__mt_slot_index", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        generation_expr = IR::Name.new(name: "__mt_generation", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)

        body = [
          IR::ForStmt.new(
            init: IR::LocalDecl.new(
              name: "__mt_slot_index",
              c_name: "__mt_slot_index",
              type: @ctx.types.fetch("ptr_uint"),
              value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint")),
            ),
            condition: IR::Binary.new(
              operator: "<",
              left: slot_index_expr,
              right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @ctx.types.fetch("ptr_uint")),
              type: @ctx.types.fetch("bool"),
            ),
            post: IR::Assignment.new(target: slot_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
            body: [
              event_slot_local_decl(event_expr, slot_index_expr, runtime),
              active_event_slot_continue_guard(slot_pointer_expr),
              IR::LocalDecl.new(
                name: "__mt_generation",
                c_name: "__mt_generation",
                type: @ctx.types.fetch("ptr_uint"),
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
        listener_expr = IR::Name.new(name: "listener", type: runtime.fetch(:void_ptr), pointer: false)
        slot_index_expr = IR::Name.new(name: "__mt_slot_index", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        generation_expr = IR::Name.new(name: "__mt_generation", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)

        body = [
          IR::ForStmt.new(
            init: IR::LocalDecl.new(
              name: "__mt_slot_index",
              c_name: "__mt_slot_index",
              type: @ctx.types.fetch("ptr_uint"),
              value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint")),
            ),
            condition: IR::Binary.new(
              operator: "<",
              left: slot_index_expr,
              right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @ctx.types.fetch("ptr_uint")),
              type: @ctx.types.fetch("bool"),
            ),
            post: IR::Assignment.new(target: slot_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
            body: [
              event_slot_local_decl(event_expr, slot_index_expr, runtime),
              active_event_slot_continue_guard(slot_pointer_expr),
              IR::LocalDecl.new(
                name: "__mt_generation",
                c_name: "__mt_generation",
                type: @ctx.types.fetch("ptr_uint"),
                value: event_next_generation_expression(slot_pointer_expr),
              ),
              *event_slot_activate_stateful_statements(
                slot_pointer_expr,
                runtime,
                generation_expr: generation_expr,
                once: once,
                state_expr: state_expr,
                wait_frame_expr: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                listener_expr: listener_expr,
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
        subscription_expr = IR::Name.new(name: "subscription", type: @ctx.types.fetch("Subscription"), pointer: false)
        slot_index_expr = subscription_field_expression(subscription_expr, "slot", @ctx.types.fetch("ptr_uint"))
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)

        false_value = IR::BooleanLiteral.new(value: false, type: @ctx.types.fetch("bool"))
        true_value = IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool"))
        body = [
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: ">=",
              left: slot_index_expr,
              right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @ctx.types.fetch("ptr_uint")),
              type: @ctx.types.fetch("bool"),
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
            condition: IR::Unary.new(operator: "not", operand: event_slot_active_expression(slot_pointer_expr), type: @ctx.types.fetch("bool")),
            then_body: [IR::ReturnStmt.new(value: false_value)],
            else_body: nil,
          ),
          IR::IfStmt.new(
            condition: IR::Binary.new(
              operator: "!=",
              left: event_slot_field_expression(slot_pointer_expr, "generation", @ctx.types.fetch("ptr_uint")),
              right: subscription_field_expression(subscription_expr, "generation", @ctx.types.fetch("ptr_uint")),
              type: @ctx.types.fetch("bool"),
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
            IR::Param.new(name: "subscription", c_name: "subscription", type: @ctx.types.fetch("Subscription"), pointer: false),
          ],
          return_type: @ctx.types.fetch("bool"),
          body:,
          entry_point: false,
        )
      end

      def build_event_emit_function(runtime)
        event_expr = IR::Name.new(name: "event", type: runtime.fetch(:event_pointer_type), pointer: false)
        payload_expr = runtime.fetch(:event_type).payload_type ? IR::Name.new(name: "payload", type: runtime.fetch(:event_type).payload_type, pointer: false) : nil
        snapshots_expr = IR::Name.new(name: "__mt_snapshots", type: runtime.fetch(:snapshots_type), pointer: false)
        snapshot_count_expr = IR::Name.new(name: "__mt_snapshot_count", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        slot_index_expr = IR::Name.new(name: "__mt_slot_index", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        dispatch_index_expr = IR::Name.new(name: "__mt_dispatch_index", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)
        frame_pointer_expr = IR::Name.new(name: "__mt_wait_frame", type: runtime.fetch(:wait_frame_pointer_type), pointer: false)

        collect_body = [
          event_slot_local_decl(event_expr, slot_index_expr, runtime),
          inactive_event_slot_continue_guard(slot_pointer_expr),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "slot", @ctx.types.fetch("ptr_uint")), operator: "=", value: slot_index_expr),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "generation", @ctx.types.fetch("ptr_uint")), operator: "=", value: event_slot_field_expression(slot_pointer_expr, "generation", @ctx.types.fetch("ptr_uint"))),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "once", @ctx.types.fetch("bool")), operator: "=", value: event_slot_field_expression(slot_pointer_expr, "once", @ctx.types.fetch("bool"))),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "wait_slot", @ctx.types.fetch("bool")),
            operator: "=",
            value: IR::Binary.new(
              operator: "!=",
              left: event_slot_wait_frame_expression(slot_pointer_expr, runtime),
              right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
              type: @ctx.types.fetch("bool"),
            ),
          ),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "stateful", @ctx.types.fetch("bool")), operator: "=", value: IR::Binary.new(operator: "!=", left: event_slot_field_expression(slot_pointer_expr, "state", runtime.fetch(:void_ptr)), right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)), type: @ctx.types.fetch("bool"))),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "state", runtime.fetch(:void_ptr)), operator: "=", value: event_slot_field_expression(slot_pointer_expr, "state", runtime.fetch(:void_ptr))),
          IR::Assignment.new(target: snapshot_field_expression(snapshots_expr, snapshot_count_expr, runtime, "listener", runtime.fetch(:void_ptr)), operator: "=", value: event_slot_field_expression(slot_pointer_expr, "listener", runtime.fetch(:void_ptr))),
          IR::Assignment.new(target: snapshot_count_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
        ]

        snapshot_subscription_expr = event_subscription_literal(
          snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "slot", @ctx.types.fetch("ptr_uint")),
          snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "generation", @ctx.types.fetch("ptr_uint")),
        )
        current_slot_active = event_slot_active_expression(slot_pointer_expr)
        current_slot_generation = event_slot_field_expression(slot_pointer_expr, "generation", @ctx.types.fetch("ptr_uint"))
        current_wait_frame = event_slot_wait_frame_expression(slot_pointer_expr, runtime)
        wait_slot_condition = IR::Binary.new(
          operator: "and",
          left: current_slot_active,
          right: IR::Binary.new(
            operator: "and",
            left: IR::Binary.new(
              operator: "==",
              left: current_slot_generation,
              right: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "generation", @ctx.types.fetch("ptr_uint")),
              type: @ctx.types.fetch("bool"),
            ),
            right: IR::Binary.new(
              operator: "!=",
              left: current_wait_frame,
              right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
              type: @ctx.types.fetch("bool"),
            ),
            type: @ctx.types.fetch("bool"),
          ),
          type: @ctx.types.fetch("bool"),
        )

        wait_result_value = event_wait_success_literal(runtime.fetch(:wait_result_type), payload_expr)
        waiter_frame_expr = wait_frame_field_expression(frame_pointer_expr, "waiter_frame", runtime.fetch(:void_ptr))

        dispatch_body = [
          IR::IfStmt.new(
            condition: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "wait_slot", @ctx.types.fetch("bool")),
            then_body: [
              IR::LocalDecl.new(
                name: "__mt_slot",
                c_name: "__mt_slot",
                type: runtime.fetch(:slot_pointer_type),
                value: event_slot_pointer_expression(
                  event_expr,
                  snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "slot", @ctx.types.fetch("ptr_uint")),
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
                  IR::Assignment.new(target: wait_frame_field_expression(frame_pointer_expr, "ready", @ctx.types.fetch("bool")), operator: "=", value: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool"))),
                  IR::IfStmt.new(
                    condition: IR::Binary.new(
                      operator: "!=",
                      left: waiter_frame_expr,
                      right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                      type: @ctx.types.fetch("bool"),
                    ),
                    then_body: [
                      IR::LocalDecl.new(name: "__mt_waiter_frame", c_name: "__mt_waiter_frame", type: runtime.fetch(:void_ptr), value: waiter_frame_expr),
                      IR::Assignment.new(target: waiter_frame_expr, operator: "=", value: IR::NullLiteral.new(type: runtime.fetch(:void_ptr))),
                      IR::ExpressionStmt.new(
                        expression: IR::Call.new(
                          callee: wait_frame_field_expression(frame_pointer_expr, "waiter", runtime.fetch(:wake_type)),
                          arguments: [IR::Name.new(name: "__mt_waiter_frame", type: runtime.fetch(:void_ptr), pointer: false)],
                          type: @ctx.types.fetch("void"),
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
                condition: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "once", @ctx.types.fetch("bool")),
                then_body: [IR::ExpressionStmt.new(expression: event_unsubscribe_call(runtime, event_expr, snapshot_subscription_expr))],
                else_body: nil,
              ),
              IR::IfStmt.new(
                condition: snapshot_field_expression(snapshots_expr, dispatch_index_expr, runtime, "stateful", @ctx.types.fetch("bool")),
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
          IR::LocalDecl.new(name: "__mt_snapshot_count", c_name: "__mt_snapshot_count", type: @ctx.types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
          IR::ForStmt.new(
            init: IR::LocalDecl.new(name: "__mt_slot_index", c_name: "__mt_slot_index", type: @ctx.types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
            condition: IR::Binary.new(operator: "<", left: slot_index_expr, right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @ctx.types.fetch("ptr_uint")), type: @ctx.types.fetch("bool")),
            post: IR::Assignment.new(target: slot_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
            body: collect_body,
          ),
          IR::ForStmt.new(
            init: IR::LocalDecl.new(name: "__mt_dispatch_index", c_name: "__mt_dispatch_index", type: @ctx.types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
            condition: IR::Binary.new(operator: "<", left: dispatch_index_expr, right: snapshot_count_expr, type: @ctx.types.fetch("bool")),
            post: IR::Assignment.new(target: dispatch_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
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
          return_type: @ctx.types.fetch("void"),
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
          return_type: @ctx.types.fetch("bool"),
          body: [
            IR::IfStmt.new(
              condition: IR::Binary.new(
                operator: "==",
                left: raw_frame_expr,
                right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                type: @ctx.types.fetch("bool"),
              ),
              then_body: [IR::ReturnStmt.new(value: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool")))],
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
            IR::ReturnStmt.new(value: wait_frame_field_expression(frame_expr, "ready", @ctx.types.fetch("bool"))),
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
          return_type: @ctx.types.fetch("void"),
          body: [
            IR::IfStmt.new(
              condition: IR::Binary.new(
                operator: "==",
                left: raw_frame_expr,
                right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                type: @ctx.types.fetch("bool"),
              ),
              then_body: [
                IR::ExpressionStmt.new(expression: IR::Call.new(callee: waiter_expr, arguments: [waiter_frame_expr], type: @ctx.types.fetch("void"))),
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
              condition: wait_frame_field_expression(frame_expr, "ready", @ctx.types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(expression: IR::Call.new(callee: waiter_expr, arguments: [waiter_frame_expr], type: @ctx.types.fetch("void"))),
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
          return_type: @ctx.types.fetch("void"),
          body: [
            IR::IfStmt.new(
              condition: IR::Binary.new(
                operator: "==",
                left: raw_frame_expr,
                right: IR::NullLiteral.new(type: runtime.fetch(:void_ptr)),
                type: @ctx.types.fetch("bool"),
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
              condition: IR::Unary.new(operator: "not", operand: wait_frame_field_expression(frame_expr, "ready", @ctx.types.fetch("bool")), type: @ctx.types.fetch("bool")),
              then_body: [
                IR::ExpressionStmt.new(
                  expression: event_unsubscribe_call(
                    runtime,
                    IR::Cast.new(target_type: runtime.fetch(:event_pointer_type), expression: wait_frame_field_expression(frame_expr, "event", runtime.fetch(:void_ptr)), type: runtime.fetch(:event_pointer_type)),
                    wait_frame_field_expression(frame_expr, "subscription", @ctx.types.fetch("Subscription")),
                  ),
                ),
              ],
              else_body: nil,
            ),
            IR::ExpressionStmt.new(expression: IR::Call.new(callee: "mt_async_free", arguments: [raw_frame_expr], type: @ctx.types.fetch("void"))),
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
                type: @ctx.types.fetch("bool"),
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
        slot_index_expr = IR::Name.new(name: "__mt_slot_index", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        generation_expr = IR::Name.new(name: "__mt_generation", type: @ctx.types.fetch("ptr_uint"), pointer: false)
        slot_pointer_expr = IR::Name.new(name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), pointer: false)

        body = [
          IR::ForStmt.new(
            init: IR::LocalDecl.new(name: "__mt_slot_index", c_name: "__mt_slot_index", type: @ctx.types.fetch("ptr_uint"), value: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint"))),
            condition: IR::Binary.new(operator: "<", left: slot_index_expr, right: IR::IntegerLiteral.new(value: runtime.fetch(:event_type).capacity, type: @ctx.types.fetch("ptr_uint")), type: @ctx.types.fetch("bool")),
            post: IR::Assignment.new(target: slot_index_expr, operator: "+=", value: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint"))),
            body: [
              IR::LocalDecl.new(name: "__mt_slot", c_name: "__mt_slot", type: runtime.fetch(:slot_pointer_type), value: event_slot_pointer_expression(event_expr, slot_index_expr, runtime)),
              active_event_slot_continue_guard(slot_pointer_expr),
              IR::LocalDecl.new(
                name: "__mt_generation",
                c_name: "__mt_generation",
                type: @ctx.types.fetch("ptr_uint"),
                value: event_next_generation_expression(slot_pointer_expr),
              ),
              IR::LocalDecl.new(
                name: "__mt_wait_frame",
                c_name: "__mt_wait_frame",
                type: runtime.fetch(:wait_frame_pointer_type),
                value: IR::Cast.new(
                  target_type: runtime.fetch(:wait_frame_pointer_type),
                  expression: IR::Call.new(callee: "mt_async_alloc", arguments: [IR::SizeofExpr.new(target_type: runtime.fetch(:wait_frame_type), type: @ctx.types.fetch("ptr_uint"))], type: runtime.fetch(:void_ptr)),
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
              IR::Assignment.new(target: wait_frame_field_expression(frame_expr, "subscription", @ctx.types.fetch("Subscription")), operator: "=", value: event_subscription_literal(slot_index_expr, generation_expr)),
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
        event_slot_field_expression(slot_pointer_expr, "active", @ctx.types.fetch("bool"))
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
          condition: IR::Unary.new(operator: "not", operand: event_slot_active_expression(slot_pointer_expr), type: @ctx.types.fetch("bool")),
          then_body: [IR::ContinueStmt.new],
          else_body: nil,
        )
      end

      def event_next_generation_expression(slot_pointer_expr)
        IR::Binary.new(
          operator: "+",
          left: event_slot_field_expression(slot_pointer_expr, "generation", @ctx.types.fetch("ptr_uint")),
          right: IR::IntegerLiteral.new(value: 1, type: @ctx.types.fetch("ptr_uint")),
          type: @ctx.types.fetch("ptr_uint"),
        )
      end

      def event_slot_activate_statements(slot_pointer_expr, runtime, generation_expr:, once:, wait_frame_expr:, listener_expr: nil)
        statements = [
          IR::Assignment.new(target: event_slot_active_expression(slot_pointer_expr), operator: "=", value: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "once", @ctx.types.fetch("bool")), operator: "=", value: IR::BooleanLiteral.new(value: once, type: @ctx.types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "generation", @ctx.types.fetch("ptr_uint")), operator: "=", value: generation_expr),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "state", runtime.fetch(:void_ptr)), operator: "=", value: IR::NullLiteral.new(type: runtime.fetch(:void_ptr))),
        ]
        statements << IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "listener", runtime.fetch(:listener_type)), operator: "=", value: listener_expr) if listener_expr
        statements << IR::Assignment.new(target: event_slot_wait_frame_expression(slot_pointer_expr, runtime), operator: "=", value: wait_frame_expr)
        statements
      end

      def event_slot_activate_stateful_statements(slot_pointer_expr, runtime, generation_expr:, once:, state_expr:, wait_frame_expr:, listener_expr: nil)
        statements = [
          IR::Assignment.new(target: event_slot_active_expression(slot_pointer_expr), operator: "=", value: IR::BooleanLiteral.new(value: true, type: @ctx.types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "once", @ctx.types.fetch("bool")), operator: "=", value: IR::BooleanLiteral.new(value: once, type: @ctx.types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "generation", @ctx.types.fetch("ptr_uint")), operator: "=", value: generation_expr),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "state", runtime.fetch(:void_ptr)), operator: "=", value: state_expr),
        ]
        statements << IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "listener", runtime.fetch(:listener_type)), operator: "=", value: listener_expr) if listener_expr
        statements << IR::Assignment.new(target: event_slot_wait_frame_expression(slot_pointer_expr, runtime), operator: "=", value: wait_frame_expr)
        statements
      end

      def event_slot_clear_statements(slot_pointer_expr, runtime)
        [
          IR::Assignment.new(target: event_slot_active_expression(slot_pointer_expr), operator: "=", value: IR::BooleanLiteral.new(value: false, type: @ctx.types.fetch("bool"))),
          IR::Assignment.new(target: event_slot_field_expression(slot_pointer_expr, "once", @ctx.types.fetch("bool")), operator: "=", value: IR::BooleanLiteral.new(value: false, type: @ctx.types.fetch("bool"))),
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
          type: @ctx.types.fetch("Subscription"),
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
              value: IR::Name.new(name: enum_member_c_name(@ctx.types.fetch("EventError"), "full"), type: @ctx.types.fetch("EventError"), pointer: false),
            ),
          ],
        )
      end

      def void_value_expression
        IR::Cast.new(
          target_type: @ctx.types.fetch("void"),
          expression: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("int")),
          type: @ctx.types.fetch("void"),
        )
      end

      def event_unsubscribe_call(runtime, event_expr, subscription_expr)
        IR::Call.new(
          callee: runtime.fetch(:unsubscribe_c_name),
          arguments: [event_expr, subscription_expr],
          type: @ctx.types.fetch("void"),
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
          type: @ctx.types.fetch("void"),
        )
      end

      def event_stateful_listener_call_expression(runtime, snapshots_expr, dispatch_index_expr, payload_expr)
        listener_type = runtime.fetch(:stateful_listener_type)
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
          type: @ctx.types.fetch("void"),
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
  end
end
