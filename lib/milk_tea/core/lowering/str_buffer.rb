# frozen_string_literal: true

module MilkTea
  module LowererStrBuffer
    private


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
                                [@ctx.types.fetch("void"), []]
                              when :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format
                                [@ctx.types.fetch("void"), [Types::Parameter.new("value", @ctx.types.fetch("str"))]]
                              when :str_buffer_len, :str_buffer_capacity
                                [@ctx.types.fetch("ptr_uint"), []]
                              when :str_buffer_as_str
                                [@ctx.types.fetch("str"), []]
                              when :str_buffer_as_cstr
                                [@ctx.types.fetch("cstr"), []]
                              else
                                raise LoweringError, "unsupported str_buffer method #{kind}"
                              end

        Types::Function.new(
          kind.to_s,
          params:,
          return_type:,
          receiver_type:,
          receiver_editable: %i[str_buffer_clear str_buffer_assign str_buffer_append str_buffer_assign_format str_buffer_append_format].include?(kind),
          external: false,
        )
      end

      def lower_char_array_data_pointer(expression, env:)
        lowered_receiver = lower_expression(expression, env:)
        IR::AddressOf.new(
          expression: IR::Index.new(
            receiver: lowered_receiver,
            index: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint")),
            type: @ctx.types.fetch("char"),
          ),
          type: pointer_to(@ctx.types.fetch("char")),
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
                [@ctx.types.fetch("char"), Types::LiteralTypeArg.new(str_buffer_storage_capacity(lowered_receiver.type))],
              ),
            ),
            index: IR::IntegerLiteral.new(value: 0, type: @ctx.types.fetch("ptr_uint")),
            type: @ctx.types.fetch("char"),
          ),
          type: pointer_to(@ctx.types.fetch("char")),
        )
      end

      def lower_str_buffer_len_pointer(expression, env:)
        lower_str_buffer_len_pointer_from_lowered(lower_expression(expression, env:))
      end

      def lower_str_buffer_len_pointer_from_lowered(lowered_receiver)
        IR::AddressOf.new(
          expression: IR::Member.new(receiver: lowered_receiver, member: "len", type: @ctx.types.fetch("ptr_uint")),
          type: pointer_to(@ctx.types.fetch("ptr_uint")),
        )
      end

      def lower_str_buffer_dirty_pointer(expression, env:)
        lower_str_buffer_dirty_pointer_from_lowered(lower_expression(expression, env:))
      end

      def lower_str_buffer_dirty_pointer_from_lowered(lowered_receiver)
        IR::AddressOf.new(
          expression: IR::Member.new(receiver: lowered_receiver, member: "dirty", type: @ctx.types.fetch("bool")),
          type: pointer_to(@ctx.types.fetch("bool")),
        )
      end
  end
end
