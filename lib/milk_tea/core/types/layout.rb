# frozen_string_literal: true

require "fiddle"
require_relative "../types"

module MilkTea
  module Types
    module Layout

    POINTER_SIZE = Fiddle::SIZEOF_VOIDP

    def self.size_of(type)
      size_and_alignment(type, nil)&.first
    end

    def self.alignment_of(type)
      size_and_alignment(type, nil)&.last
    end

    def self.offset_of(type, field_name)
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

    # Computes [size, alignment] for a type.
    #
    # `stack` carries the aggregates on the current root-to-leaf path,
    # pass-down only (never popped). A field whose type reaches any aggregate
    # on that path participates in a storage cycle, and the C backend embeds
    # exactly those fields as pointers (see
    # CBackend#build_cyclic_aggregate_pairs and the cyclic field emission in
    # type_declaration.rb), so layout sizes back-edge fields as raw pointers.
    def self.size_and_alignment(type, stack)
      case type
      when Types::Primitive
        primitive_layout(type)
      when Types::EnumBase
        size_and_alignment(type.backing_type, stack)
      when Types::Nullable, Types::Function
        if type.is_a?(Types::Function) || layout_pointer_like_nullable_base?(type.base)
          [POINTER_SIZE, POINTER_SIZE]
        else
          with_stack(type, stack) do |next_stack|
            layout = struct_layout(nullable_opt_layout_fields(type.base), packed: false, alignment: nil, stack: next_stack)
            [layout[:size], layout[:alignment]]
          end
        end
      when Types::StringView, Types::Span, Types::Task, Types::Struct, Types::StructInstance
        with_stack(type, stack) do |next_stack|
          layout = struct_layout(ordered_fields(type), packed: packed_layout?(type), alignment: explicit_alignment(type), stack: next_stack)
          [layout[:size], layout[:alignment]]
        end
      when Types::Union
        with_stack(type, stack) do |next_stack|
          layout = union_layout(ordered_fields(type), packed: packed_layout?(type), alignment: explicit_alignment(type), stack: next_stack)
          [layout[:size], layout[:alignment]]
        end
      when Types::Variant, Types::VariantInstance
        with_stack(type, stack) do |next_stack|
          layout = variant_layout(type, stack: next_stack)
          [layout[:size], layout[:alignment]]
        end
      when Types::GenericInstance
        generic_layout(type, stack)
      when Types::Simd
        element_layout = size_and_alignment(type.element_type, stack)
        return unless element_layout

        total = element_layout.first * type.lane_count
        alignment = total > 16 ? 32 : 16
        [total, alignment]
      when Types::Vector
        element_layout = size_and_alignment(type.element_type, stack)
        return unless element_layout

        [element_layout.first * type.width, element_layout.last]
      when Types::Matrix
        element_layout = size_and_alignment(Types::BUILTIN_VECTOR_ELEMENT, stack)
        return unless element_layout

        [element_layout.first * type.dim * type.dim, element_layout.last]
      when Types::Quaternion
        element_layout = size_and_alignment(Types::BUILTIN_VECTOR_ELEMENT, stack)
        return unless element_layout

        [element_layout.first * 4, element_layout.last]
      else
        nil
      end
    end

    def self.primitive_layout(type)
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

    def self.generic_layout(type, stack)
      case type.name
      when "ptr", "const_ptr", "own", "ref"
        [POINTER_SIZE, POINTER_SIZE]
      when "array"
        return unless array_type?(type)

        element_layout = size_and_alignment(type.arguments.first, stack)
        return unless element_layout

        [element_layout.first * type.arguments[1].value, element_layout.last]
      when "str_buffer"
        return unless str_buffer_type?(type)

        with_stack(type, stack) do |next_stack|
          layout = struct_layout(str_buffer_fields(type), packed: false, alignment: nil, stack: next_stack)
          [layout[:size], layout[:alignment]]
        end
      end
    end

    def self.variant_layout(type, stack:)
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

    def self.struct_layout(fields, packed:, alignment:, stack:)
      field_infos = fields.map do |field_name, field_type|
        field_layout = field_size_and_alignment(field_type, stack)
        return nil unless field_layout

        [field_name, field_layout.first, field_layout.last]
      end

      struct_layout_from_infos(field_infos, packed:, alignment:)
    end

    def self.union_layout(fields, packed:, alignment:, stack:)
      field_infos = fields.map do |_field_name, field_type|
        field_layout = field_size_and_alignment(field_type, stack)
        return nil unless field_layout

        field_layout
      end

      union_layout_from_layouts(field_infos.map { |size, field_alignment| { size:, alignment: field_alignment } }, packed:, alignment:)
    end

    # A field whose type reaches any aggregate on the current path is a
    # storage-cycle back edge. The C backend emits such fields as pointers
    # (element pointer for arrays), so they occupy pointer-size storage here.
    def self.field_size_and_alignment(field_type, stack)
      return [POINTER_SIZE, POINTER_SIZE] if cyclic_back_edge?(field_type, stack)

      size_and_alignment(field_type, stack)
    end

    def self.cyclic_back_edge?(field_type, stack)
      return false if stack.nil? || stack.empty?

      aggregate_reaches_in_progress?(field_type, stack, {})
    end

    def self.aggregate_reaches_in_progress?(type, stack, visited)
      return false if visited.key?(type.object_id)

      visited[type.object_id] = true
      return true if stack.key?(type)

      reachability_children(type).any? { |child| aggregate_reaches_in_progress?(child, stack, visited) }
    end

    def self.struct_layout_from_infos(field_infos, packed:, alignment:)
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

    def self.union_layout_from_layouts(layouts, packed:, alignment:)
      natural_alignment = packed ? 1 : (layouts.map { |layout| layout[:alignment] }.max || 1)
      overall_alignment = [natural_alignment, alignment || 1].max
      size = layouts.map { |layout| layout[:size] }.max || 0

      {
        size: align_up(size, overall_alignment),
        alignment: overall_alignment,
      }
    end

    def self.ordered_fields(type)
      type.fields
    end

    def self.packed_layout?(type)
      type.respond_to?(:packed) && type.packed
    end

    def self.explicit_alignment(type)
      type.respond_to?(:alignment) ? type.alignment : nil
    end

    def self.array_type?(type)
      type.arguments.length == 2 && type.arguments[1].is_a?(Types::LiteralTypeArg) && type.arguments[1].value.is_a?(Integer)
    end

    def self.str_buffer_type?(type)
      type.arguments.length == 1 && type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments.first.value.is_a?(Integer)
    end

    def self.str_buffer_fields(type)
      storage_capacity = type.arguments.first.value + 1
      {
        "data" => Types::Registry.generic_instance("array", [Types::Registry.primitive("char"), Types::LiteralTypeArg.new(storage_capacity)]),
        "len" => Types::Registry.primitive("ptr_uint"),
        "dirty" => Types::Registry.primitive("bool"),
      }
    end

    def self.layout_pointer_like_nullable_base?(base)
      return true if base.is_a?(Types::Function) || base.is_a?(Types::Proc) || base.is_a?(Types::Opaque)
      return true if base.is_a?(Types::Primitive) && base.name == "cstr"

      base.is_a?(Types::GenericInstance) && %w[ptr const_ptr own ref].include?(base.name)
    end

    def self.nullable_opt_layout_fields(base)
      {
        "has_value" => Types::Registry.primitive("bool"),
        "value" => base,
      }
    end

    def self.align_up(value, alignment)
      return value if alignment <= 1

      remainder = value % alignment
      remainder.zero? ? value : value + alignment - remainder
    end

    # `stack` is the set of aggregates on the current path, pass-down only.
    # A nil or empty stack means the caller is not inside an aggregate yet.
    # Yields the extended stack; returns nil when `type` is already in progress
    # (callers treat that as unreachable while mirroring backend semantics).
    def self.with_stack(type, stack)
      next_stack = (stack || {}).dup
      return nil if next_stack.key?(type)

      next_stack[type] = true
      yield(next_stack)
    end

    # Structural expansion used for back-edge detection. Mirrors the
    # CBackend's `aggregate_type_dependencies` so pointer-broken cyclic
    # fields agree with the emitted C struct layout.
    def self.reachability_children(type)
      case type
      when Types::Nullable
        [type.base]
      when Types::GenericInstance
        if pointer_type?(type)
          []
        elsif array_type?(type)
          [array_element_type(type)]
        else
          []
        end
      when Types::Span
        [type.element_type]
      when Types::Struct, Types::StructInstance, Types::Union
        type.fields.values
      when Types::Variant, Types::VariantInstance
        type.arm_names.flat_map { |name| type.arm(name).values }
      when Types::VariantArmPayload
        type.fields.values
      else
        []
      end
    end

    def self.pointer_type?(type)
      type.is_a?(Types::GenericInstance) && %w[ptr const_ptr own ref].include?(type.name)
    end

    def self.array_element_type(type)
      type.arguments.first
    end
    end
  end
end
