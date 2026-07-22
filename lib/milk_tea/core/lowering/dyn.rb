# frozen_string_literal: true

module MilkTea
  module LowererDyn
    private

    def lower_adapt_call(expression, env:, type:, interface:)
      argument = expression.arguments.fetch(0)
      arg_value = lower_expression(argument.value, env:)
      arg_type = infer_expression_type(argument.value, env:)
      concrete_type = ref_type?(arg_type) ? referenced_type(arg_type) : arg_type

      @dyn_vtables ||= {}
      key = [concrete_type, interface.name]
      return @dyn_vtables[key] unless @dyn_vtables[key].nil?

      vtable_struct_full = dyn_vtable_struct_type(interface)
      vtable_c_name = ensure_dyn_vtable(interface, concrete_type)

      void_ptr = Types::Registry.generic_instance("ptr", [@ctx.types.fetch("void")])
      vtable_field = IR::Cast.new(
        target_type: void_ptr,
        expression: IR::AddressOf.new(
          expression: IR::Name.new(name: vtable_c_name, type: vtable_struct_full, pointer: false),
          type: Types::Registry.generic_instance("ptr", [vtable_struct_full]),
        ),
        type: void_ptr,
      )

      result = IR::AggregateLiteral.new(
        type:,
        fields: [
          IR::AggregateField.new(name: "data", value: IR::Cast.new(target_type: void_ptr, expression: arg_value, type: void_ptr)),
          IR::AggregateField.new(name: "vtable", value: vtable_field),
        ],
      )
      @dyn_vtables[key] = result
      result
    end

    def lower_dyn_method_call(expression, receiver, method_binding, env:, type:)
      ir_expr = lower_expression(receiver, env:)
      void_ptr = Types::Registry.generic_instance("ptr", [@ctx.types.fetch("void")])
      dyn_type = infer_expression_type(receiver, env:)
      interface = dyn_type.interface_binding

      data_ptr = IR::Member.new(receiver: ir_expr, member: "data", type: void_ptr)
      vtable_field = IR::Member.new(receiver: ir_expr, member: "vtable", type: void_ptr)

      vtable_full = dyn_vtable_struct_type(interface)
      vtable_ptr_type = Types::Registry.generic_instance("ptr", [vtable_full])
      vtable_cast = IR::Cast.new(target_type: vtable_ptr_type, expression: vtable_field, type: vtable_ptr_type)

      fn_type = vtable_full.field(method_binding.name)
      vtable_method = IR::Member.new(receiver: vtable_cast, member: method_binding.name, type: fn_type)

      arguments = [data_ptr, *lower_call_arguments(expression.arguments, method_binding, env:)]
      IR::Call.new(callee: vtable_method, arguments:, type:)
    end

    def dyn_vtable_struct_type(interface)
      void_ptr = Types::Registry.generic_instance("ptr", [@ctx.types.fetch("void")])
      fields = {}
      interface.methods.each do |method_name, method_binding|
        fn_params = [Types::Registry.parameter("data", void_ptr), *method_binding.params]
        fn_type = Types::Registry.function(nil, params: fn_params, return_type: method_binding.return_type)
        fields[method_name] = fn_type
      end
      Types::DynVtable.new(interface.name, fields)
    end

    def ensure_dyn_vtable(interface, concrete_type)
      concrete_type_name = sanitize_identifier(concrete_type.to_s)
      vtable_c_name = "mt_vtable_#{concrete_type_name}_#{interface.name}"
      return vtable_c_name if @dyn_generated_vtables&.key?(vtable_c_name)
      @dyn_generated_vtables ||= {}

      ensure_dyn_vtable_struct(interface)
      wrappers = gen_dyn_vtable_wrappers(concrete_type, interface)
      gen_dyn_vtable_constant(concrete_type, interface, vtable_c_name, wrappers)
      @dyn_generated_vtables[vtable_c_name] = true
      vtable_c_name
    end

    def ensure_dyn_vtable_struct(interface)
      vtable_c_name = "mt_vtable_#{interface.name}"
      return if @artifacts.synthetic_structs.any? { |s| s.linkage_name == vtable_c_name }

      void_ptr = Types::Registry.generic_instance("ptr", [Types::Registry.primitive("void")])
      fields = interface.methods.map do |method_name, method_binding|
        fn_params = [Types::Registry.parameter("data", void_ptr), *method_binding.params]
        fn_type = Types::Registry.function(nil, params: fn_params, return_type: method_binding.return_type)
        IR::Field.new(name: method_name, type: fn_type)
      end

      @artifacts.synthetic_structs << IR::StructDecl.new(
        name: "vtable_#{interface.name}",
        linkage_name: vtable_c_name,
        fields:,
        packed: false,
        alignment: nil,
      )
    end

    def gen_dyn_vtable_wrappers(concrete_type, interface)
      void_ptr = Types::Registry.generic_instance("ptr", [Types::Registry.primitive("void")])
      wrappers = {}
      concrete_type_name = sanitize_identifier(concrete_type.to_s)
      ptr_to_concrete = Types::Registry.generic_instance("ptr", [concrete_type])

      interface.methods.each do |method_name, method_binding|
        method_info = @method_definitions[[concrete_type, method_name]]
        raise LoweringError, "no method #{method_name} for #{concrete_type}" unless method_info

        method_analysis, method_ast = method_info
        method_key = method_ast.kind == :static ? "static:#{method_ast.name}" : method_ast.name
        real_binding = method_analysis.methods.fetch(concrete_type).fetch(method_key)
        real_c_name = function_binding_c_name(real_binding, module_name: method_analysis.module_name, receiver_type: concrete_type)
        wrapper_c_name = "__dyn_#{concrete_type_name}_#{method_name}"
        is_editable = method_ast.kind == :editable

        params = [
          IR::Param.new(name: "data", linkage_name: "data", type: void_ptr, pointer: false),
          *method_binding.params.map.with_index { |p, i| IR::Param.new(name: p.name, linkage_name: p.name || "arg#{i}", type: p.type, pointer: false) },
        ]

        body = if is_editable
                 [
                   IR::ReturnStmt.new(value: IR::Call.new(
                     callee: real_c_name,
                     arguments: [
                       IR::Cast.new(target_type: ptr_to_concrete, expression: IR::Name.new(name: "data", type: void_ptr, pointer: false), type: ptr_to_concrete),
                       *method_binding.params.map.with_index { |p, i| IR::Name.new(name: p.name || "arg#{i}", type: p.type, pointer: false) },
                     ],
                     type: method_binding.return_type,
                   )),
                 ]
               else
                  if method_ast.kind == :static
                    [
                      IR::ReturnStmt.new(value: IR::Call.new(
                        callee: real_c_name,
                        arguments: method_binding.params.map.with_index { |p, i| IR::Name.new(name: p.name || "arg#{i}", type: p.type, pointer: false) },
                        type: method_binding.return_type,
                      )),
                    ]
                  elsif receiver_type_uses_pointer_lowering?(concrete_type)
                    [
                      IR::ReturnStmt.new(value: IR::Call.new(
                        callee: real_c_name,
                        arguments: [
                          IR::Cast.new(target_type: ptr_to_concrete, expression: IR::Name.new(name: "data", type: void_ptr, pointer: false), type: ptr_to_concrete),
                          *method_binding.params.map.with_index { |p, i| IR::Name.new(name: p.name || "arg#{i}", type: p.type, pointer: false) },
                        ],
                        type: method_binding.return_type,
                      )),
                    ]
                  else
                    # The receiver is always passed here; the C backend's
                    # omitted-receiver call logic drops it when the target
                    # method's unused receiver parameter was omitted (the same
                    # single source of truth every ordinary method call uses,
                    # which requires a String callee).
                    [
                      IR::ReturnStmt.new(value: IR::Call.new(
                        callee: real_c_name,
                        arguments: [
                          IR::Unary.new(operator: "*", operand: IR::Cast.new(target_type: ptr_to_concrete, expression: IR::Name.new(name: "data", type: void_ptr, pointer: false), type: ptr_to_concrete), type: concrete_type),
                          *method_binding.params.map.with_index { |p, i| IR::Name.new(name: p.name || "arg#{i}", type: p.type, pointer: false) },
                        ],
                        type: method_binding.return_type,
                      )),
                    ]
                  end
               end

        @artifacts.synthetic_functions << IR::Function.new(
          name: "__dyn_#{concrete_type_name}_#{method_name}",
          linkage_name: wrapper_c_name,
          params:,
          return_type: method_binding.return_type,
          body:,
          entry_point: false,
        )
        wrappers[method_name] = wrapper_c_name
      end

      wrappers
    end

    def gen_dyn_vtable_constant(concrete_type, interface, vtable_c_name, wrappers)
      vtable_full = dyn_vtable_struct_type(interface)
      fields = interface.methods.map do |method_name, _|
        wrapper_c_name = wrappers[method_name]
        field_type = vtable_full.field(method_name)
        IR::AggregateField.new(name: method_name, value: IR::Name.new(name: wrapper_c_name, type: field_type || @error_type, pointer: false))
      end
      @artifacts.synthetic_constants << IR::Constant.new(
        name: vtable_c_name,
        linkage_name: vtable_c_name,
        type: vtable_full,
        value: IR::AggregateLiteral.new(type: vtable_full, fields:),
      )
    end
  end
end
