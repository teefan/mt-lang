# frozen_string_literal: true

module MilkTea
  module SerializerAddons
    # Primitive / simple
    def serialize_tref_primitive(type, h)       = h.merge!("name" => type.name)
    def deserialize_tref_primitive(h)           = Types::Registry.primitive(h["name"])
    def serialize_tref_null(type, h)            = h.merge!("target_type" => serialize_ast(type.target_type))
    def deserialize_tref_null(h)                = Types::Null.new(deserialize_ast(h["target_type"]))
    def serialize_tref_error(type, h)           = h
    def deserialize_tref_error(h)               = Types::Error.new
    def serialize_tref_type_var(type, h)        = h.merge!("name" => type.name)
    def deserialize_tref_type_var(h)            = Types::TypeVar.new(h["name"])
    def serialize_tref_lifetime_ref(type, h)    = h.merge!("name" => type.name)
    def deserialize_tref_lifetime_ref(h)        = Types::LifetimeRef.new(h["name"])
    def serialize_tref_literal_type_arg(t, h)   = h.merge!("value" => t.value)
    def deserialize_tref_literal_type_arg(h)    = Types::LiteralTypeArg.new(h["value"])
    def serialize_tref_handle(type, h)          = h
    def deserialize_tref_handle(h)              = Types::Handle.new
    def serialize_tref_subscription(type, h)    = h
    def deserialize_tref_subscription(h)        = Types::Subscription.new
    def serialize_tref_type_type(type, h)       = h
    def deserialize_tref_type_type(h)           = Types::TypeType.new
    def serialize_tref_reflection_handle_type(type, h) = h.merge!("name" => type.name)
    def deserialize_tref_reflection_handle_type(h)     = Types::ReflectionHandleType.new(h["name"])
    # Compound
    def serialize_tref_nullable(type, h)        = h.merge!("base" => serialize_ast(type.base))
    def deserialize_tref_nullable(h)            = Types::Registry.nullable(deserialize_ast(h["base"]))
    def serialize_tref_generic_instance(type, h)
      h.merge!("name" => type.name, "arguments" => serialize_ast(type.arguments))
    end
    def deserialize_tref_generic_instance(h)
      Types::Registry.generic_instance(h["name"], deserialize_ast(h["arguments"]))
    end
    def serialize_tref_span(type, h)            = h.merge!("element_type" => serialize_ast(type.element_type))
    def deserialize_tref_span(h)                = Types::Registry.span(deserialize_ast(h["element_type"]))
    def serialize_tref_task(type, h)            = h.merge!("result_type" => serialize_ast(type.result_type))
    def deserialize_tref_task(h)                = Types::Registry.task(deserialize_ast(h["result_type"]))
    def serialize_tref_string_view(type, h)     = h
    def deserialize_tref_string_view(h)         = Types::Registry.string_view
    def serialize_tref_soa(type, h)
      h.merge!("element_type" => serialize_ast(type.element_type), "count" => type.count)
    end
    def deserialize_tref_soa(h) = Types::Registry.soa(deserialize_ast(h["element_type"]), count: h["count"])
    alias serialize_tref_so_a serialize_tref_soa
    alias deserialize_tref_so_a deserialize_tref_soa
    def serialize_tref_tuple(type, h)
      h.merge!("element_types" => serialize_ast(type.element_types), "field_names" => serialize_ast(type.field_names))
    end
    def deserialize_tref_tuple(h)
      Types::Registry.tuple(deserialize_ast(h["element_types"]), field_names: deserialize_ast(h["field_names"]))
    end
    def serialize_tref_vector(type, h)
      h.merge!("name" => type.name, "element_type" => serialize_ast(type.element_type), "width" => type.width)
    end
    def deserialize_tref_vector(h)
      Types::Vector.new(h["name"], element_type: deserialize_ast(h["element_type"]), width: h["width"])
    end
    def serialize_tref_matrix(type, h)          = h.merge!("name" => type.name, "dim" => type.dim)
    def deserialize_tref_matrix(h)              = Types::Matrix.new(h["name"], dim: h["dim"])
    def serialize_tref_quaternion(type, h)      = h.merge!("name" => type.name)
    def deserialize_tref_quaternion(h)          = Types::Quaternion.new(h["name"])
    # Function / Proc / Parameter
    def serialize_tref_function(type, h)
      h.merge!("name" => type.name, "params" => serialize_ast(type.params), "return_type" => serialize_ast(type.return_type),
               "receiver_type" => serialize_ast(type.receiver_type), "receiver_editable" => type.receiver_editable,
               "variadic" => type.variadic, "external" => type.external)
    end
    def deserialize_tref_function(h)
      Types::Registry.function(h["name"], params: deserialize_ast(h["params"]), return_type: deserialize_ast(h["return_type"]),
        receiver_type: deserialize_ast(h["receiver_type"]), receiver_editable: h["receiver_editable"],
        variadic: h["variadic"], external: h["external"])
    end
    def serialize_tref_proc(type, h)
      h.merge!("params" => serialize_ast(type.params), "return_type" => serialize_ast(type.return_type))
    end
    def deserialize_tref_proc(h)
      Types::Registry.proc(params: deserialize_ast(h["params"]), return_type: deserialize_ast(h["return_type"]))
    end
    def serialize_tref_parameter(type, h)
      h.merge!("name" => type.name, "type" => serialize_ast(type.type), "mutable" => type.mutable,
               "passing_mode" => type.passing_mode.to_s, "boundary_type" => serialize_ast(type.boundary_type))
    end
    def deserialize_tref_parameter(h)
      Types::Registry.parameter(h["name"], deserialize_ast(h["type"]), mutable: h["mutable"],
        passing_mode: h["passing_mode"].to_sym, boundary_type: deserialize_ast(h["boundary_type"]))
    end
    # Struct / Union
    def serialize_tref_struct(type, h)          = serialize_tref_struct_like(type, h)
    def deserialize_tref_struct(h)              = deserialize_tref_struct_like(h, Types::Struct)
    def serialize_tref_union(type, h)           = serialize_tref_struct_like(type, h)
    def deserialize_tref_union(h)               = deserialize_tref_struct_like(h, Types::Union)
    def serialize_tref_struct_instance(type, h)
      serialize_tref_struct_like(type, h).merge!(
        "arguments" => serialize_ast(type.arguments), "def_name" => type.definition.name,
        "def_type_params" => serialize_ast(type.definition.type_params), "def_module_name" => type.definition.module_name)
    end
    def deserialize_tref_struct_instance(h)
      defn = Types::GenericStructDefinition.new(h["def_name"], deserialize_ast(h["def_type_params"]), module_name: h["def_module_name"])
      inst = Types::StructInstance.new(defn, deserialize_ast(h["arguments"]))
      cache_full_type(h, inst)
      deserialize_tref_struct_like_into(inst, h)
      inst
    end
    def serialize_tref_variant_arm_payload(type, h)
      serialize_tref_struct_like(type, h).merge!("variant_type" => serialize_ast(type.variant_type), "arm_name" => type.arm_name)
    end
    def deserialize_tref_variant_arm_payload(h)
      inst = Types::VariantArmPayload.new(deserialize_ast(h["variant_type"]), h["arm_name"], {})
      cache_full_type(h, inst)
      deserialize_tref_struct_like_into(inst, h)
      inst
    end
    def serialize_tref_struct_like(type, h)
      h.merge!("name" => type.name, "module_name" => type.module_name, "external" => type.external,
               "packed" => type.packed, "alignment" => type.alignment, "linkage_name" => type.linkage_name,
               "lifetime_params" => serialize_ast(type.lifetime_params))
      unless Thread.current[:mt_ser_id_only_types]
        h.merge!("fields" => serialize_struct_fields(type.fields),
                 "events" => serialize_struct_fields(type.respond_to?(:events) ? (type.events || {}) : {}),
                 "nested_types" => serialize_struct_nested_types(type.respond_to?(:nested_types) ? (type.nested_types || {}) : {}))
      end
      h
    end
    def serialize_struct_fields(fields)
      return {} if fields.nil?
      result = {}
      fields.each { |k, v| result[k.to_s] = serialize_ast(v) }
      result
    end
    def serialize_struct_nested_types(nested)
      return {} if nested.nil?
      result = {}
      nested.each { |k, v| result[k.to_s] = serialize_ast(v) }
      result
    end
    def deserialize_tref_struct_like(h, klass)
      inst = klass.new(h["name"], module_name: h["module_name"], external: h["external"],
        packed: h["packed"], alignment: h["alignment"], linkage_name: h["linkage_name"],
        lifetime_params: deserialize_ast(h["lifetime_params"]))
      cache_full_type(h, inst)
      deserialize_tref_struct_like_into(inst, h)
      inst
    end
    def deserialize_tref_struct_like_into(inst, h)
      fields = normalize_field_keys(deserialize_ast(h["fields"]))
      inst.define_fields(fields) unless fields.empty?
      events = normalize_field_keys(deserialize_ast(h["events"]))
      inst.define_events(events) unless events.empty?
      nested = normalize_field_keys(deserialize_ast(h["nested_types"]))
      inst.define_nested_types(nested) unless nested.empty?
      inst
    end
    # Variant
    def serialize_tref_variant(type, h)
      h.merge!("name" => type.name, "module_name" => type.module_name, "arms" => serialize_variant_arms(type))
    end
    def deserialize_tref_variant(h)
      inst = Types::Variant.new(h["name"], module_name: h["module_name"])
      cache_full_type(h, inst)
      arms = normalize_field_keys(deserialize_ast(h["arms"]))
      inst.define_arms(arms) unless arms.empty?
      inst
    end
    def serialize_tref_variant_instance(type, h)
      serialize_tref_variant(type, h).merge!(
        "arguments" => serialize_ast(type.arguments), "def_name" => type.definition.name,
        "def_type_params" => serialize_ast(type.definition.type_params), "def_module_name" => type.definition.module_name)
    end
    def deserialize_tref_variant_instance(h)
      defn = Types::GenericVariantDefinition.new(h["def_name"], deserialize_ast(h["def_type_params"]), module_name: h["def_module_name"])
      inst = Types::VariantInstance.new(defn, deserialize_ast(h["arguments"]))
      cache_full_type(h, inst)
      arms = normalize_field_keys(deserialize_ast(h["arms"]))
      inst.define_arms(arms) unless arms.empty?
      inst
    end
    def serialize_tref_generic_struct_definition(type, h)
      serialize_tref_struct_like(type, h).merge!("type_params" => serialize_ast(type.type_params), "type_param_constraints" => {})
    end
    def deserialize_tref_generic_struct_definition(h)
      inst = Types::GenericStructDefinition.new(h["name"], deserialize_ast(h["type_params"]),
        module_name: h["module_name"], external: h["external"], packed: h["packed"],
        alignment: h["alignment"], linkage_name: h["linkage_name"], lifetime_params: deserialize_ast(h["lifetime_params"]))
      cache_full_type(h, inst)
      deserialize_tref_struct_like_into(inst, h)
      inst
    end
    def serialize_tref_generic_variant_definition(type, h)
      serialize_tref_variant(type, h).merge!("type_params" => serialize_ast(type.type_params), "type_param_constraints" => {})
    end
    def deserialize_tref_generic_variant_definition(h)
      inst = Types::GenericVariantDefinition.new(h["name"], deserialize_ast(h["type_params"]), module_name: h["module_name"])
      cache_full_type(h, inst)
      arms = normalize_field_keys(deserialize_ast(h["arms"]))
      inst.define_arms(arms) unless arms.empty?
      inst
    end
    def serialize_variant_arms(type)
      return {} unless type.respond_to?(:arm_names)
      result = {}
      type.arm_names.each do |arm_name|
        fields = if type.respond_to?(:has_payload?) && type.has_payload?(arm_name)
                    arm_type = type.arm(arm_name)
                    arm_fields = arm_type.respond_to?(:fields) ? arm_type.fields : arm_type.is_a?(Hash) ? arm_type : {}
                    arm_fields.transform_values { |ft| serialize_ast(ft) }
                  else {} end
        result[arm_name] = fields
      end
      result
    end
    # Enum / Flags
    def serialize_tref_enum(type, h)            = serialize_tref_enum_like(type, h)
    def deserialize_tref_enum(h)                = deserialize_tref_enum_like(h, Types::Enum)
    def serialize_tref_flags(type, h)           = serialize_tref_enum_like(type, h)
    def deserialize_tref_flags(h)               = deserialize_tref_enum_like(h, Types::Flags)
    def serialize_tref_enum_like(type, h)
      members = type.respond_to?(:members) ? type.members : []
      member_values = {}
      members.each { |m| member_values[m] = type.member_value(m) } if type.respond_to?(:member_value)
      h.merge!("name" => type.name, "module_name" => type.module_name, "external" => type.external,
               "backing_type" => serialize_ast(type.backing_type), "members" => serialize_ast(members),
               "member_values" => member_values)
    end
    def deserialize_tref_enum_like(h, klass)
      inst = klass.new(h["name"], module_name: h["module_name"], external: h["external"])
      cache_full_type(h, inst)
      members = deserialize_ast(h["members"]) || []
      inst.define_members(deserialize_ast(h["backing_type"]), members) unless members.empty?
      mv = h["member_values"] || {}
      inst.define_member_values(mv) unless mv.empty?
      inst
    end
    # Opaque / Event / Dyn
    def serialize_tref_opaque(type, h)
      h.merge!("name" => type.name, "module_name" => type.module_name,
               "external" => type.external, "linkage_name" => type.linkage_name)
    end
    def deserialize_tref_opaque(h)
      inst = Types::Opaque.new(h["name"], module_name: h["module_name"], external: h["external"], linkage_name: h["linkage_name"])
      cache_full_type(h, inst)
      inst
    end
    def serialize_tref_event(type, h)
      h.merge!("name" => type.name, "capacity" => type.capacity, "payload_type" => serialize_ast(type.payload_type),
               "module_name" => type.module_name, "visibility" => type.visibility.to_s, "owner_type_name" => type.owner_type_name)
    end
    def deserialize_tref_event(h)
      inst = Types::Event.new(h["name"], capacity: h["capacity"], payload_type: deserialize_ast(h["payload_type"]),
        module_name: h["module_name"], visibility: h["visibility"].to_sym, owner_type_name: h["owner_type_name"])
      cache_full_type(h, inst)
      inst
    end
    def serialize_tref_dyn(type, h)
      h.merge!("interface_name" => type.interface_binding.name,
               "interface_binding" => interface_binding_to_hash(type.interface_binding),
               "type_arguments" => serialize_ast(type.type_arguments))
    end
    def deserialize_tref_dyn(h)
      ib = h["interface_binding"] ? unstub_interface_binding(h["interface_binding"]) : Struct.new(:name).new(h["interface_name"])
      Types::Registry.dyn(ib, deserialize_ast(h["type_arguments"]))
    end
    def serialize_tref_dyn_vtable(type, h)
      h.merge!("linkage_name" => type.linkage_name, "interface_name" => type.interface_name,
               "fields" => serialize_struct_fields(type.fields))
    end
    def deserialize_tref_dyn_vtable(h)
      Types::DynVtable.new(h["interface_name"], deserialize_ast(h["fields"]) || {})
    end
    # Reflection handles (for completeness)
    def serialize_tref_struct_handle(type, h)   = h.merge!("struct_type" => serialize_ast(type.struct_type))
    def deserialize_tref_struct_handle(h)        = Types::StructHandle.new(deserialize_ast(h["struct_type"]), nil)
    def serialize_tref_field_handle(type, h)     = h.merge!("struct_handle" => serialize_ast(type.struct_handle), "field_name" => type.field_name)
    def deserialize_tref_field_handle(h)         = Types::FieldHandle.new(deserialize_ast(h["struct_handle"]), h["field_name"], nil)
    def serialize_tref_callable_handle(type, h)  = h.merge!("display_name" => type.display_name)
    def deserialize_tref_callable_handle(h)      = Types::CallableHandle.new(h["display_name"], nil)
    def serialize_tref_attribute_handle(type, h)
      h.merge!("attribute_name" => type.attribute_name, "attribute_module_name" => type.attribute_module_name,
               "target" => serialize_ast(type.target), "argument_values" => serialize_ast(type.argument_values))
    end
    def deserialize_tref_attribute_handle(h)
      Types::AttributeHandle.new(h["attribute_name"], h["attribute_module_name"], deserialize_ast(h["target"]), [], deserialize_ast(h["argument_values"]))
    end
    def serialize_tref_member_handle(type, h)
      h.merge!("enum_handle" => serialize_ast(type.enum_handle), "member_name" => type.member_name, "member_value" => type.member_value)
    end
    def deserialize_tref_member_handle(h)
      Types::MemberHandle.new(deserialize_ast(h["enum_handle"]), h["member_name"], h["member_value"])
    end
  end
end
