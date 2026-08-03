# frozen_string_literal: true

module MilkTea
  module SexprDumper
    module_function

    def dump_ir(program)
      buf = +""
      emit_value(program, buf)
      buf
    end

    def dump_ast(ast)
      buf = +""
      emit_value(ast, buf)
      buf
    end

    def dump_tokens(tokens)
      buf = +""
      buf << "("
      tokens.each_with_index { |t, i| buf << " " if i > 0; emit_token(t, buf) }
      buf << ")"
      buf
    end

    # ── value dispatcher ──────────────────────────────────────────────

    def emit_value(value, buf)
      case value
      when ::Data then emit_data(value, buf)
      when Array  then emit_array(value, buf)
      when *TYPES_CLASSES then emit_types_object(value, buf)
      when nil    then buf << "null"
      when true   then buf << "true"
      when false  then buf << "false"
      when Integer then buf << value.to_s
      when Float   then buf << format_float(value)
      when String  then emit_string(value, buf)
      when Symbol  then emit_string(value.to_s.tr("_", "-"), buf)
      when Hash, Set then nil
      else buf << escape_string(value.to_s)
      end
    end

    # ── Data serialisation ────────────────────────────────────────────

    def emit_data(node, buf)
      type_name = node.class.name.split("::").last(2).join("::")
      members = node.class.members
      buf << "(" << type_name
      members.each do |field|
        val = node.public_send(field)
        next if val.is_a?(Hash) || val.is_a?(Set)
        buf << " " << field.to_s << " "
        emit_value(val, buf)
      end
      buf << ")"
    end

    # ── Array serialisation ───────────────────────────────────────────

    def emit_array(values, buf)
      buf << "("
      values.each_with_index do |v, i|
        buf << " " if i > 0
        emit_value(v, buf)
      end
      buf << ")"
    end

    # ── Token serialisation ───────────────────────────────────────────

    def emit_token(token, buf)
      buf << "(token type "
      emit_string(token.type.to_s.tr("_", "-"), buf)
      buf << " lexeme "
      emit_string(token.lexeme, buf)
      buf << " literal "
      emit_value(token.literal, buf)
      buf << " line " << token.line.to_s
      buf << " column " << token.column.to_s
      buf << " start_offset " << token.start_offset.to_s
      buf << " end_offset " << token.end_offset.to_s
      buf << ")"
    end

    # ── Types serialisation ───────────────────────────────────────────

    TYPES_SHORT_NAMES = {
      "MilkTea::Types::Primitive"              => "Primitive",
      "MilkTea::Types::Null"                   => "Null",
      "MilkTea::Types::Nullable"               => "Nullable",
      "MilkTea::Types::GenericInstance"        => "Generic",
      "MilkTea::Types::Span"                   => "Span",
      "MilkTea::Types::Task"                   => "Task",
      "MilkTea::Types::Function"               => "Function",
      "MilkTea::Types::Proc"                   => "Proc",
      "MilkTea::Types::Tuple"                  => "Tuple",
      "MilkTea::Types::Vector"                 => "Vector",
      "MilkTea::Types::Matrix"                 => "Matrix",
      "MilkTea::Types::Quaternion"             => "Quaternion",
      "MilkTea::Types::SoA"                    => "SoA",
      "MilkTea::Types::Simd"                   => "Simd",
      "MilkTea::Types::Struct"                 => "Struct",
      "MilkTea::Types::StructInstance"         => "StructInstance",
      "MilkTea::Types::Union"                  => "Union",
      "MilkTea::Types::Variant"                => "Variant",
      "MilkTea::Types::VariantInstance"        => "VariantInstance",
      "MilkTea::Types::VariantArmPayload"      => "VariantArmPayload",
      "MilkTea::Types::Enum"                   => "Enum",
      "MilkTea::Types::Flags"                  => "Flags",
      "MilkTea::Types::Opaque"                 => "Opaque",
      "MilkTea::Types::StringView"             => "StringView",
      "MilkTea::Types::Dyn"                    => "Dyn",
      "MilkTea::Types::Parameter"              => "Parameter",
      "MilkTea::Types::LiteralTypeArg"         => "LiteralTypeArg",
      "MilkTea::Types::TypeVar"                => "TypeVar",
      "MilkTea::Types::LifetimeRef"            => "LifetimeRef",
      "MilkTea::Types::Event"                  => "Event",
      "MilkTea::Types::Subscription"           => "Subscription",
      "MilkTea::Types::Handle"                 => "Handle",
      "MilkTea::Types::TypeType"               => "TypeType",
      "MilkTea::Types::Error"                  => "Error",
      "MilkTea::Types::DynVtable"              => "DynVtable",
    }.freeze

    TYPES_CLASSES = TYPES_SHORT_NAMES.keys.map do |name|
      name.split("::").reduce(Object) { |mod, part| mod.const_get(part) }
    end.freeze

    def emit_types_object(type, buf)
      short = TYPES_SHORT_NAMES[type.class.name] || type.class.name.split("::").last
      buf << "(Types::" << short
      emit_types_fields(type, buf)
      buf << ")"
    end

    def emit_types_fields(type, buf)
      case type
      when Types::Primitive
        buf << " name "
        emit_string(type.name, buf)
      when Types::Null
        buf << " target_type "
        emit_value(type.target_type, buf)
      when Types::Nullable
        buf << " base "
        emit_value(type.base, buf)
      when Types::GenericInstance
        buf << " name "
        emit_string(type.name, buf)
        buf << " arguments "
        emit_array(type.arguments, buf)
      when Types::Span
        buf << " element_type "
        emit_value(type.element_type, buf)
      when Types::Task
        buf << " result_type "
        emit_value(type.result_type, buf)
      when Types::Function
        buf << " name "
        emit_string(type.name, buf)
        buf << " params "
        emit_array(type.params, buf)
        buf << " return_type "
        emit_value(type.return_type, buf)
        buf << " receiver_type "
        emit_value(type.receiver_type, buf)
        buf << " receiver_editable "
        emit_value(type.receiver_editable, buf)
        buf << " variadic "
        emit_value(type.variadic, buf)
        buf << " external "
        emit_value(type.external, buf)
      when Types::Proc
        buf << " params "
        emit_array(type.params, buf)
        buf << " return_type "
        emit_value(type.return_type, buf)
      when Types::Tuple
        buf << " element_types "
        emit_array(type.element_types, buf)
        buf << " field_names "
        emit_value(type.field_names, buf)
      when Types::Vector
        buf << " name "
        emit_string(type.name, buf)
      when Types::Matrix
        buf << " name "
        emit_string(type.name, buf)
      when Types::Quaternion
        buf << " name "
        emit_string(type.name, buf)
      when Types::SoA
        buf << " element_type "
        emit_value(type.element_type, buf)
        buf << " count "
        emit_value(type.count, buf)
      when Types::Simd
        buf << " element_type "
        emit_value(type.element_type, buf)
        buf << " lane_count "
        emit_value(type.lane_count, buf)
      when Types::Struct
        buf << " name "
        emit_string(type.name, buf)
        buf << " module_name "
        emit_value(type.module_name, buf)
      when Types::StructInstance
        buf << " name "
        emit_string(type.name, buf)
        buf << " module_name "
        emit_value(type.module_name, buf)
        buf << " arguments "
        emit_array(type.arguments, buf)
      when Types::Union
        buf << " name "
        emit_string(type.name, buf)
        buf << " module_name "
        emit_value(type.module_name, buf)
      when Types::Variant
        buf << " name "
        emit_string(type.name, buf)
        buf << " module_name "
        emit_value(type.module_name, buf)
      when Types::VariantInstance
        buf << " name "
        emit_string(type.name, buf)
        buf << " module_name "
        emit_value(type.module_name, buf)
        buf << " arguments "
        emit_array(type.arguments, buf)
      when Types::VariantArmPayload
        buf << " variant_name "
        emit_string(type.variant_type.name, buf)
        buf << " arm_name "
        emit_string(type.arm_name, buf)
      when Types::Enum
        buf << " name "
        emit_string(type.name, buf)
        buf << " module_name "
        emit_value(type.module_name, buf)
      when Types::Flags
        buf << " name "
        emit_string(type.name, buf)
        buf << " module_name "
        emit_value(type.module_name, buf)
      when Types::Opaque
        buf << " name "
        emit_string(type.name, buf)
        buf << " module_name "
        emit_value(type.module_name, buf)
      when Types::StringView
        # no fields
      when Types::Dyn
        buf << " interface_name "
        emit_string(type.interface_binding.name, buf)
        buf << " type_arguments "
        emit_array(type.type_arguments, buf)
      when Types::Parameter
        buf << " name "
        emit_string(type.name, buf)
        buf << " type "
        emit_value(type.type, buf)
        buf << " mutable "
        emit_value(type.mutable, buf)
        buf << " passing_mode "
        emit_value(type.passing_mode, buf)
        buf << " boundary_type "
        emit_value(type.boundary_type, buf)
      when Types::LiteralTypeArg
        buf << " value "
        emit_value(type.value, buf)
      when Types::TypeVar
        buf << " name "
        emit_string(type.name, buf)
      when Types::LifetimeRef
        buf << " name "
        emit_string(type.name, buf)
      when Types::Event
        buf << " name "
        emit_string(type.name, buf)
        buf << " capacity "
        emit_value(type.capacity, buf)
        buf << " payload_type "
        emit_value(type.payload_type, buf)
      when Types::Subscription
        # no fields (singleton)
      when Types::Handle
        # no fields (singleton)
      else
        _emit_generic_type(type, buf)
      end
    end

    def _emit_generic_type(type, buf)
      type.instance_variables.sort.each do |ivar|
        next if skip_types_ivar?(ivar)
        name = ivar.to_s.sub(/\A@/, "")
        val = type.instance_variable_get(ivar)
        next if val.is_a?(Hash) || val.is_a?(Set) || val.is_a?(Proc)
        buf << " " << name << " "
        emit_value(val, buf)
      end
    end

    def skip_types_ivar?(ivar)
      %i[@hash @integer @float @numeric @pointer_sized_integer
         @signed_integer @unsigned_integer @fixed_width_integer
         @boolean @void @integer_width @float_width @backing_type
         @arms @arm_names @arm_field_hashes @instances].include?(ivar)
    end

    # ── atom helpers ──────────────────────────────────────────────────

    def emit_string(value, buf)
      escaped = value.to_s
        .gsub("\\", "\\\\")
        .gsub('"', '\"')
        .gsub("\n", '\\n')
        .gsub("\t", '\\t')
        .gsub("\r", '\\r')
      buf << '"' << escaped << '"'
    end

    def escape_string(value)
      value.to_s
        .gsub("\\", "\\\\")
        .gsub('"', '\"')
        .gsub("\n", '\\n')
        .gsub("\t", '\\t')
        .gsub("\r", '\\r')
    end

    def format_float(value)
      s = sprintf("%.17g", value)
      s.include?(".") || s.include?("e") ? s : s + ".0"
    end
  end
end
