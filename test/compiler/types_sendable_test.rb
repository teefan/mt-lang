# frozen_string_literal: true

require_relative "../test_helper"

class TypesSendableTest < Minitest::Test
  def test_primitive_integers_are_sendable
    %w[byte short int long ubyte ushort uint ulong ptr_int ptr_uint].each do |name|
      assert MilkTea::Types::Registry.primitive(name).sendable?, "#{name} should be sendable"
    end
  end

  def test_primitive_floats_are_sendable
    %w[float double].each do |name|
      assert MilkTea::Types::Registry.primitive(name).sendable?, "#{name} should be sendable"
    end
  end

  def test_primitive_bool_is_sendable
    assert MilkTea::Types::Registry.primitive("bool").sendable?
  end

  def test_primitive_void_is_sendable
    assert MilkTea::Types::Registry.primitive("void").sendable?
  end

  def test_primitive_char_is_sendable
    assert MilkTea::Types::Registry.primitive("char").sendable?
  end

  def test_primitive_cstr_is_sendable
    assert MilkTea::Types::Registry.primitive("cstr").sendable?
  end

  def test_primitive_str_is_not_sendable
    refute MilkTea::Types::Registry.primitive("str").sendable?
  end

  def test_string_view_is_not_sendable
    refute MilkTea::Types::Registry.string_view.sendable?
  end

  def test_null_is_sendable
    assert MilkTea::Types::Null.new.sendable?
    assert MilkTea::Types::Null.new(MilkTea::Types::Registry.primitive("int")).sendable?
  end

  def test_error_type_is_not_sendable
    refute MilkTea::Types::Error.new.sendable?
  end

  def test_ptr_is_not_sendable
    ptr = MilkTea::Types::Registry.generic_instance("ptr", [MilkTea::Types::Registry.primitive("int")])
    refute ptr.sendable?
  end

  def test_const_ptr_is_not_sendable
    cptr = MilkTea::Types::Registry.generic_instance("const_ptr", [MilkTea::Types::Registry.primitive("int")])
    refute cptr.sendable?
  end

  def test_ref_is_not_sendable
    ref = MilkTea::Types::Registry.generic_instance("ref", [MilkTea::Types::Registry.primitive("int")])
    refute ref.sendable?
  end

  def test_span_is_not_sendable
    refute MilkTea::Types::Registry.span(MilkTea::Types::Registry.primitive("float")).sendable?
  end

  def test_array_of_sendable_is_sendable
    arr = MilkTea::Types::Registry.generic_instance("array", [
      MilkTea::Types::Registry.primitive("int"),
      MilkTea::Types::LiteralTypeArg.new(16),
    ])
    assert arr.sendable?
  end

  def test_array_of_non_sendable_is_not_sendable
    arr = MilkTea::Types::Registry.generic_instance("array", [
      MilkTea::Types::Registry.generic_instance("ptr", [MilkTea::Types::Registry.primitive("int")]),
      MilkTea::Types::LiteralTypeArg.new(4),
    ])
    refute arr.sendable?
  end

  def test_str_buffer_is_sendable
    sb = MilkTea::Types::Registry.generic_instance("str_buffer", [MilkTea::Types::LiteralTypeArg.new(64)])
    assert sb.sendable?
  end

  def test_nullable_sendable_base_is_sendable
    nullable_int_ptr = MilkTea::Types::Registry.nullable(
      MilkTea::Types::Registry.primitive("int"),
    )
    assert nullable_int_ptr.sendable?
  end

  def test_nullable_non_sendable_base_is_not_sendable
    nullable_ptr = MilkTea::Types::Registry.nullable(
      MilkTea::Types::Registry.generic_instance("ptr", [MilkTea::Types::Registry.primitive("int")]),
    )
    refute nullable_ptr.sendable?
  end

  def test_struct_with_sendable_fields_is_sendable
    s = MilkTea::Types::Struct.new("Vec2")
    s.define_fields(
      "x" => MilkTea::Types::Registry.primitive("float"),
      "y" => MilkTea::Types::Registry.primitive("float"),
    )
    assert s.sendable?
  end

  def test_struct_with_non_sendable_field_is_not_sendable
    s = MilkTea::Types::Struct.new("Holder")
    s.define_fields(
      "data" => MilkTea::Types::Registry.generic_instance("ptr", [MilkTea::Types::Registry.primitive("int")]),
    )
    refute s.sendable?
  end

  def test_struct_with_events_is_not_sendable
    s = MilkTea::Types::Struct.new("Window")
    s.define_fields("width" => MilkTea::Types::Registry.primitive("int"))
    s.define_events(
      "closed" => MilkTea::Types::Event.new("closed", capacity: 4),
    )
    refute s.sendable?
  end

  def test_struct_with_str_field_is_not_sendable
    s = MilkTea::Types::Struct.new("Label")
    s.define_fields("text" => MilkTea::Types::Registry.string_view)
    refute s.sendable?
  end

  def test_union_inherits_struct_sendable
    u = MilkTea::Types::Union.new("Number")
    u.define_fields(
      "i" => MilkTea::Types::Registry.primitive("int"),
      "f" => MilkTea::Types::Registry.primitive("float"),
    )
    assert u.sendable?
  end

  def test_union_with_ptr_is_not_sendable
    u = MilkTea::Types::Union.new("Value")
    u.define_fields(
      "i" => MilkTea::Types::Registry.primitive("int"),
      "raw" => MilkTea::Types::Registry.generic_instance("ptr", [MilkTea::Types::Registry.primitive("void")]),
    )
    refute u.sendable?
  end

  def test_variant_with_sendable_payloads_is_sendable
    v = MilkTea::Types::Variant.new("Token")
    v.define_arms(
      "number" => { "value" => MilkTea::Types::Registry.primitive("int") },
      "eof" => {},
    )
    assert v.sendable?
  end

  def test_variant_with_non_sendable_payload_is_not_sendable
    v = MilkTea::Types::Variant.new("Token")
    v.define_arms(
      "ident" => { "text" => MilkTea::Types::Registry.string_view },
      "eof" => {},
    )
    refute v.sendable?
  end

  def test_enum_is_sendable
    e = MilkTea::Types::Enum.new("State")
    e.define_members(MilkTea::Types::Registry.primitive("ubyte"), %w[idle running])
    assert e.sendable?
  end

  def test_flags_is_sendable
    f = MilkTea::Types::Flags.new("Mask")
    f.define_members(MilkTea::Types::Registry.primitive("uint"), %w[a b])
    assert f.sendable?
  end

  def test_function_is_sendable
    fn = MilkTea::Types::Registry.function(
      "add",
      params: [
        MilkTea::Types::Registry.parameter("a", MilkTea::Types::Registry.primitive("int")),
        MilkTea::Types::Registry.parameter("b", MilkTea::Types::Registry.primitive("int")),
      ],
      return_type: MilkTea::Types::Registry.primitive("int"),
    )
    assert fn.sendable?
  end

  def test_proc_is_not_sendable
    p = MilkTea::Types::Registry.proc(
      params: [MilkTea::Types::Registry.parameter("x", MilkTea::Types::Registry.primitive("int"))],
      return_type: MilkTea::Types::Registry.primitive("int"),
    )
    refute p.sendable?
  end

  def test_task_with_sendable_result_is_sendable
    task = MilkTea::Types::Registry.task(MilkTea::Types::Registry.primitive("int"))
    assert task.sendable?
  end

  def test_task_with_non_sendable_result_is_not_sendable
    task = MilkTea::Types::Registry.task(MilkTea::Types::Registry.string_view)
    refute task.sendable?
  end

  def test_opaque_is_not_sendable
    refute MilkTea::Types::Opaque.new("SDL_Window").sendable?
  end

  def test_subscription_is_sendable
    assert MilkTea::Types::Subscription.new.sendable?
  end

  def test_event_is_not_sendable
    refute MilkTea::Types::Event.new("closed", capacity: 4).sendable?
  end

  def test_vector_is_sendable
    assert MilkTea::Types::Vector.new("vec3", element_type: MilkTea::Types::Registry.primitive("float"), width: 3).sendable?
  end

  def test_ivector_is_sendable
    assert MilkTea::Types::Vector.new("ivec2", element_type: MilkTea::Types::Registry.primitive("int"), width: 2).sendable?
  end

  def test_matrix_is_sendable
    assert MilkTea::Types::Matrix.new("mat4", dim: 4).sendable?
  end

  def test_quaternion_is_sendable
    assert MilkTea::Types::Quaternion.new("quat").sendable?
  end

  def test_tuple_with_sendable_elements_is_sendable
    t = MilkTea::Types::Registry.tuple([
      MilkTea::Types::Registry.primitive("int"),
      MilkTea::Types::Registry.primitive("float"),
    ])
    assert t.sendable?
  end

  def test_tuple_with_non_sendable_element_is_not_sendable
    t = MilkTea::Types::Registry.tuple([
      MilkTea::Types::Registry.primitive("int"),
      MilkTea::Types::Registry.string_view,
    ])
    refute t.sendable?
  end

  def test_soa_with_sendable_element_is_sendable
    element = MilkTea::Types::Struct.new("Particle")
    element.define_fields(
      "x" => MilkTea::Types::Registry.primitive("float"),
      "y" => MilkTea::Types::Registry.primitive("float"),
    )
    soa = MilkTea::Types::Registry.soa(element, count: 100)
    assert soa.sendable?
  end

  def test_soa_with_non_sendable_element_is_not_sendable
    element = MilkTea::Types::Struct.new("RefHolder")
    element.define_fields(
      "data" => MilkTea::Types::Registry.generic_instance("ref", [MilkTea::Types::Registry.primitive("int")]),
    )
    soa = MilkTea::Types::Registry.soa(element, count: 10)
    refute soa.sendable?
  end

  def test_dyn_is_not_sendable
    interface_binding = ::Struct.new(:name).new("Damageable")
    refute MilkTea::Types::Dyn.new(interface_binding).sendable?
  end

  def test_type_var_is_sendable
    assert MilkTea::Types::TypeVar.new("T").sendable?
  end

  def test_type_type_is_sendable
    assert MilkTea::Types::TypeType.new.sendable?
  end

  def test_reflection_handle_types_are_sendable
    assert MilkTea::Types::BUILTIN_FIELD_HANDLE_TYPE.sendable?
    assert MilkTea::Types::BUILTIN_CALLABLE_HANDLE_TYPE.sendable?
    assert MilkTea::Types::BUILTIN_ATTRIBUTE_HANDLE_TYPE.sendable?
    assert MilkTea::Types::BUILTIN_MEMBER_HANDLE_TYPE.sendable?
    assert MilkTea::Types::BUILTIN_STRUCT_HANDLE_TYPE.sendable?
  end

  def test_generic_struct_instance_sendable
    defn = MilkTea::Types::GenericStructDefinition.new("Pair", ["T"])
    defn.define_fields(
      "first" => MilkTea::Types::TypeVar.new("T"),
      "second" => MilkTea::Types::TypeVar.new("T"),
    )
    instance = defn.instantiate([MilkTea::Types::Registry.primitive("int")])
    assert instance.sendable?
  end

  def test_generic_struct_instance_non_sendable
    defn = MilkTea::Types::GenericStructDefinition.new("Wrapper", ["T"])
    defn.define_fields("value" => MilkTea::Types::TypeVar.new("T"))
    instance = defn.instantiate([MilkTea::Types::Registry.generic_instance("ptr", [MilkTea::Types::Registry.primitive("int")])])
    refute instance.sendable?
  end

  def test_generic_variant_instance_sendable
    instance = MilkTea::Types::BUILTIN_OPTION_TYPE.instantiate([MilkTea::Types::Registry.primitive("int")])
    assert instance.sendable?
  end

  def test_generic_variant_instance_non_sendable
    instance = MilkTea::Types::BUILTIN_OPTION_TYPE.instantiate([MilkTea::Types::Registry.string_view])
    refute instance.sendable?
  end

  def test_result_with_sendable_types_is_sendable
    instance = MilkTea::Types::BUILTIN_RESULT_TYPE.instantiate([
      MilkTea::Types::Registry.primitive("int"),
      MilkTea::Types::Registry.primitive("int"),
    ])
    assert instance.sendable?
  end

  def test_result_with_non_sendable_error_is_not_sendable
    instance = MilkTea::Types::BUILTIN_RESULT_TYPE.instantiate([
      MilkTea::Types::Registry.primitive("int"),
      MilkTea::Types::Registry.string_view,
    ])
    refute instance.sendable?
  end

  def test_nested_struct_sendability
    inner = MilkTea::Types::Struct.new("Inner")
    inner.define_fields("value" => MilkTea::Types::Registry.primitive("int"))
    outer = MilkTea::Types::Struct.new("Outer")
    outer.define_fields("child" => inner)
    assert outer.sendable?
  end

  def test_nested_struct_non_sendable_propagates
    inner = MilkTea::Types::Struct.new("Inner")
    inner.define_fields("data" => MilkTea::Types::Registry.generic_instance("ptr", [MilkTea::Types::Registry.primitive("void")]))
    outer = MilkTea::Types::Struct.new("Outer")
    outer.define_fields("child" => inner)
    refute outer.sendable?
  end

  def test_array_of_sendable_structs_is_sendable
    s = MilkTea::Types::Struct.new("Point")
    s.define_fields(
      "x" => MilkTea::Types::Registry.primitive("float"),
      "y" => MilkTea::Types::Registry.primitive("float"),
    )
    arr = MilkTea::Types::Registry.generic_instance("array", [s, MilkTea::Types::LiteralTypeArg.new(10)])
    assert arr.sendable?
  end

  def test_lifetime_ref_is_sendable
    assert MilkTea::Types::LifetimeRef.new("@a").sendable?
  end
end
