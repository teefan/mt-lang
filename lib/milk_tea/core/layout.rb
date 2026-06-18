# frozen_string_literal: true

require "fiddle"

module MilkTea
  module Layout
    module_function

    POINTER_SIZE = Fiddle::SIZEOF_VOIDP

    def size_of(type)
      size_and_alignment(type, {})&.first
    end

    def alignment_of(type)
      size_and_alignment(type, {})&.last
    end

    def offset_of(type, field_name)
      case type
      when Types::Struct, Types::StructInstance, Types::Span, Types::StringView, Types::Task
        fields = ordered_fields(type)
        return unless fields.key?(field_name)

        struct_layout(fields, packed: packed_layout?(type), alignment: explicit_alignment(type), stack: {})[:offsets][field_name]
      when Types::Union
        type.field(field_name) ? 0 : nil
      when Types::GenericInstance
        return unless str_buffer_type?(type)

        fields = str_buffer_fields(type)
        return unless fields.key?(field_name)

        struct_layout(fields, packed: false, alignment: nil, stack: {})[:offsets][field_name]
      else
        nil
      end
    end

    def size_and_alignment(type, stack)
      case type
      when Types::Primitive
        primitive_layout(type)
      when Types::EnumBase
        size_and_alignment(type.backing_type, stack)
      when Types::Nullable, Types::Function
        [POINTER_SIZE, POINTER_SIZE]
      when Types::StringView, Types::Span, Types::Task, Types::Struct, Types::StructInstance
        with_stack(type, stack) do
          layout = struct_layout(ordered_fields(type), packed: packed_layout?(type), alignment: explicit_alignment(type), stack:)
          [layout[:size], layout[:alignment]]
        end
      when Types::Union
        with_stack(type, stack) do
          layout = union_layout(ordered_fields(type), packed: packed_layout?(type), alignment: explicit_alignment(type), stack:)
          [layout[:size], layout[:alignment]]
        end
      when Types::Variant, Types::VariantInstance
        with_stack(type, stack) do
          layout = variant_layout(type, stack:)
          [layout[:size], layout[:alignment]]
        end
      when Types::GenericInstance
        generic_layout(type, stack)
      else
        nil
      end
    end

    def primitive_layout(type)
      case type.name
      when "bool", "byte", "ubyte", "char"
        [1, 1]
      when "short", "ushort"
        [2, 2]
      when "int", "uint", "float"
        [4, 4]
      when "long", "ulong", "double"
        [8, 8]
      when "ptr_int", "ptr_uint", "cstr"
        [POINTER_SIZE, POINTER_SIZE]
      else
        nil
      end
    end

    def generic_layout(type, stack)
      case type.name
      when "ptr", "const_ptr", "ref"
        [POINTER_SIZE, POINTER_SIZE]
      when "array"
        return unless array_type?(type)

        element_layout = size_and_alignment(type.arguments.first, stack)
        return unless element_layout

        [element_layout.first * type.arguments[1].value, element_layout.last]
      when "str_buffer"
        return unless str_buffer_type?(type)

        with_stack(type, stack) do
          layout = struct_layout(str_buffer_fields(type), packed: false, alignment: nil, stack:)
          [layout[:size], layout[:alignment]]
        end
      end
    end

    def variant_layout(type, stack:)
      payload_layouts = type.arm_names.filter_map do |arm_name|
        fields = type.arm(arm_name)
        next if fields.nil? || fields.empty?

        struct_layout(fields, packed: false, alignment: nil, stack:)
      end

      data_layout = union_layout_from_layouts(payload_layouts, packed: false, alignment: nil)
      field_infos = [["kind", 4, 4]]
      field_infos << ["data", data_layout[:size], data_layout[:alignment]] if data_layout[:size].positive?
      struct_layout_from_infos(field_infos, packed: false, alignment: nil)
    end

    def struct_layout(fields, packed:, alignment:, stack:)
      field_infos = fields.map do |field_name, field_type|
        field_layout = size_and_alignment(field_type, stack)
        return nil unless field_layout

        [field_name, field_layout.first, field_layout.last]
      end

      struct_layout_from_infos(field_infos, packed:, alignment:)
    end

    def union_layout(fields, packed:, alignment:, stack:)
      field_infos = fields.map do |_field_name, field_type|
        field_layout = size_and_alignment(field_type, stack)
        return nil unless field_layout

        field_layout
      end

      union_layout_from_layouts(field_infos.map { |size, field_alignment| { size:, alignment: field_alignment } }, packed:, alignment:)
    end

    def struct_layout_from_infos(field_infos, packed:, alignment:)
      offsets = {}
      offset = 0
      natural_alignment = 1

      field_infos.each do |field_name, field_size, field_alignment|
        effective_alignment = packed ? 1 : field_alignment
        natural_alignment = [natural_alignment, effective_alignment].max
        offset = align_up(offset, effective_alignment) unless packed
        offsets[field_name] = offset
        offset += field_size
      end

      overall_alignment = [natural_alignment, alignment || 1].max
      {
        size: align_up(offset, overall_alignment),
        alignment: overall_alignment,
        offsets:,
      }
    end

    def union_layout_from_layouts(layouts, packed:, alignment:)
      natural_alignment = packed ? 1 : (layouts.map { |layout| layout[:alignment] }.max || 1)
      overall_alignment = [natural_alignment, alignment || 1].max
      size = layouts.map { |layout| layout[:size] }.max || 0

      {
        size: align_up(size, overall_alignment),
        alignment: overall_alignment,
      }
    end

    def ordered_fields(type)
      type.fields
    end

    def packed_layout?(type)
      type.respond_to?(:packed) && type.packed
    end

    def explicit_alignment(type)
      type.respond_to?(:alignment) ? type.alignment : nil
    end

    def array_type?(type)
      type.arguments.length == 2 && type.arguments[1].is_a?(Types::LiteralTypeArg) && type.arguments[1].value.is_a?(Integer)
    end

    def str_buffer_type?(type)
      type.arguments.length == 1 && type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments.first.value.is_a?(Integer)
    end

    def str_buffer_fields(type)
      storage_capacity = type.arguments.first.value + 1
      {
        "data" => Types::GenericInstance.new("array", [Types::Primitive.new("char"), Types::LiteralTypeArg.new(storage_capacity)]),
        "len" => Types::Primitive.new("ptr_uint"),
        "dirty" => Types::Primitive.new("bool"),
      }
    end

    def align_up(value, alignment)
      return value if alignment <= 1

      remainder = value % alignment
      remainder.zero? ? value : value + alignment - remainder
    end

    def with_stack(type, stack)
      return if stack[type]

      stack[type] = true
      yield
    ensure
      stack.delete(type)
    end
  end
end
