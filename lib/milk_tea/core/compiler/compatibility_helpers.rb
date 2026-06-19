# frozen_string_literal: true

require_relative "../types/predicates"

module MilkTea
  module CompatibilityHelpers
    include TypePredicates

    BUILTIN_CSTR = Types::Primitive.new("cstr")

    EVENT_METHOD_KINDS = {
      "subscribe" => :event_subscribe,
      "subscribe_once" => :event_subscribe_once,
      "unsubscribe" => :event_unsubscribe,
      "emit" => :event_emit,
      "wait" => :event_wait,
    }.freeze

    EVENT_METHOD_NAMES = EVENT_METHOD_KINDS.invert.freeze

    STR_BUFFER_METHOD_KINDS = {
      "clear" => :str_buffer_clear,
      "assign" => :str_buffer_assign,
      "append" => :str_buffer_append,
      "assign_format" => :str_buffer_assign_format,
      "append_format" => :str_buffer_append_format,
      "len" => :str_buffer_len,
      "capacity" => :str_buffer_capacity,
      "as_str" => :str_buffer_as_str,
      "as_cstr" => :str_buffer_as_cstr,
    }.freeze

    STR_BUFFER_METHOD_NAMES = STR_BUFFER_METHOD_KINDS.invert.freeze

    ATOMIC_METHOD_KINDS = {
      "load" => :atomic_load,
      "store" => :atomic_store,
      "add" => :atomic_add,
      "sub" => :atomic_sub,
      "exchange" => :atomic_exchange,
      "compare_exchange" => :atomic_compare_exchange,
    }.freeze

    def type_ref_from_specialization(expression)
      case expression.callee
      when AST::Identifier
        return nil if %w[zero default reinterpret].include?(expression.callee.name)

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

    def event_subscription_result_type
      @ctx.types.fetch("Result").instantiate([@ctx.types.fetch("Subscription"), @ctx.types.fetch("EventError")])
    end

    def event_wait_result_type(event_type)
      @ctx.types.fetch("Result").instantiate([event_type.payload_type || @ctx.types.fetch("void"), @ctx.types.fetch("EventError")])
    end

    def range_expr?(expression)
      expression.is_a?(AST::RangeExpr)
    end

    private

    def string_literal_cstr_compatibility?(expression, expected_type)
      expression.is_a?(AST::StringLiteral) && !expression.cstring && expected_type == BUILTIN_CSTR
    end
  end
end
