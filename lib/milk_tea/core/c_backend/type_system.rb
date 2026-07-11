# frozen_string_literal: true

module MilkTea
  class CBackend
    module TypeSystem
      private

          PRIMITIVE_C_TYPE_MAP = {
            "bool" => "bool",
            "byte" => "int8_t",
            "ubyte" => "uint8_t",
            "char" => "char",
            "short" => "int16_t",
            "ushort" => "uint16_t",
            "int" => "int32_t",
            "uint" => "uint32_t",
            "long" => "int64_t",
            "ulong" => "uint64_t",
            "ptr_int" => "intptr_t",
            "ptr_uint" => "uintptr_t",
            "float" => "float",
            "double" => "double",
            "void" => "void",
            "cstr" => "const char*",
          }.freeze

          SANITIZE_NON_ALNUM_RE = /[^A-Za-z0-9_]+/
          SANITIZE_UNDERSCORES_RE = /_+/
          SANITIZE_LEADING_UNDERSCORES_RE = /^_+/
          SANITIZE_TRAILING_UNDERSCORES_RE = /_+$/

          def c_declaration(type, name)
            base, declarator = c_declaration_parts(type, name)
            declarator.empty? ? base : "#{base} #{declarator}"
          end

          def c_field_declaration(type, name)
            return "uint8_t #{name}" if void_storage_field?(type)

            c_declaration(type, name)
          end

          def c_function_declaration(return_type, name, params)
            c_declaration(array_type?(return_type) ? void_type : return_type, "#{name}(#{params})")
          end

          def c_function_return_type(type)
            c_type(array_type?(type) ? void_type : type)
          end

          def array_out_param_declaration(type, name)
            c_declaration(type, "(*#{name})")
          end

          def c_declaration_parts(type, name)
            name = name.to_s

            if array_type?(type)
              declarator = declarator_needs_grouping?(name) ? "(#{name})" : name
              return c_declaration_parts(array_element_type(type), "#{declarator}[#{array_length(type)}]")
            end

            if type.is_a?(Types::Nullable) && type.base.is_a?(Types::Function)
              return c_declaration_parts(type.base, name)
            end

            if type.is_a?(Types::Function)
              params = []
              params << array_out_param_declaration(type.return_type, ARRAY_OUT_PARAM_NAME) if array_type?(type.return_type)
              params.concat(type.params.each_with_index.map do |param, index|
                c_declaration(param.type, param.name || "arg#{index}")
              end)
              params << "..." if type.variadic
              params = ["void"] if params.empty?
              return [c_function_return_type(type.return_type), "(*#{name})(#{params.join(', ')})"]
            end

            if type.is_a?(Types::Proc)
              return [proc_type_name(type), name]
            end

            if mutable_pointer_type?(type) || own_type?(type)
              return c_declaration_parts(type.arguments.first, "*#{name}")
            end

            if const_pointer_type?(type)
              return [generic_c_type(type), name]
            end

            if ref_type?(type)
              ref_arguments = type.arguments
              ref_target = ref_arguments.length == 1 ? ref_arguments.first : ref_arguments[1]
              return c_declaration_parts(ref_target, "*#{name}")
            end

            [c_type(type), name]
          end

          def declarator_needs_grouping?(name)
            !name.empty? && (name.start_with?("*") || name.include?("["))
          end

          def c_type(type, pointer: false)
            case type
            when Types::Nullable
              return c_type(type.base, pointer:) if type.base.is_a?(Types::Function)

              unless c_backend_pointer_like_type?(type.base)
                base = nullable_opt_type_name(type)
                return pointer ? "#{base}*" : base
              end

              base = c_type(type.base)
              base.end_with?("*") ? base : "#{base}*"
            when Types::StringView
              base = "mt_str"
              pointer ? "#{base}*" : base
            when Types::Primitive
              base = primitive_c_type(type.name)
              pointer ? "#{base}*" : base
            when Types::Span
              base = span_type_name(type)
              pointer ? "#{base}*" : base
            when Types::Task
              base = task_type_name(type)
              pointer ? "#{base}*" : base
            when Types::Proc
              base = proc_type_name(type)
              pointer ? "#{base}*" : base
            when Types::Dyn
              base = dyn_type_name(type)
              pointer ? "#{base}*" : base
            when Types::DynVtable
              base = type.linkage_name
              pointer ? "#{base}*" : base
            when Types::Function
              base = c_declaration(type, "")
              pointer ? "#{base}*" : base
            when Types::GenericInstance
              base = generic_c_type(type)
              pointer ? "#{base}*" : base
            when Types::Struct, Types::StructInstance, Types::Union, Types::Enum, Types::Flags, Types::Variant, Types::VariantInstance, Types::VariantArmPayload, Types::Event, Types::Subscription
              base = named_type_c_name(type)
              pointer ? "#{base}*" : base
            when Types::Opaque
              if type.external
                base = external_opaque_c_type(type)
                pointer ? "#{base}*" : base
              else
                base = type.linkage_name || named_type_c_name(type)
                pointer ? "#{base}**" : "#{base}*"
              end
            when Types::Vector
              base = "mt_#{type.name}"
              pointer ? "#{base}*" : base
            when Types::Matrix
              base = "mt_#{type.name}"
              pointer ? "#{base}*" : base
            when Types::Quaternion
              base = "mt_#{type.name}"
              pointer ? "#{base}*" : base
            when Types::SoA
              base = soa_type_name(type)
              pointer ? "#{base}*" : base
            when Types::Tuple
              base = tuple_type_name(type)
              pointer ? "#{base}*" : base
            when Types::Handle
              "void*"
            else
              raise CBackendError, "unsupported C type #{type.class.name}"
            end
          end

          def constant_storage(type)
            return "static const" if array_type?(type)

            c_type(type).start_with?("const ") ? "static" : "static const"
          end

          def global_storage(_type)
            "static"
          end

          def span_type_name(type)
            "mt_span_#{sanitize_identifier(type.element_type.to_s)}"
          end

          def soa_type_name(type)
            element_name = sanitize_identifier(type.element_type.respond_to?(:name) ? type.element_type.name : type.element_type.to_s)
            "mt_soa_#{element_name}_#{type.count}"
          end

          def tuple_type_name(type)
            sanitized = type.element_types.map { |et| sanitize_identifier(et.to_s) }.join("_")
            base = "mt_tuple_#{sanitized}"
            default_names = type.element_types.each_with_index.map { |_, i| "_#{i}" }
            if type.field_names != default_names
              base << "_" << type.field_names.map { |n| sanitize_identifier(n) }.join("_")
            end
            base
          end

          def task_type_name(type)
            "mt_task_#{sanitize_identifier(type.result_type.to_s)}"
          end

          def proc_type_name(type)
            "mt_proc_#{sanitize_identifier(type.to_s)}"
          end

          def dyn_type_name(type)
            "mt_dyn_#{sanitize_identifier(type.interface_binding.name)}"
          end

          def nullable_opt_type_name(type)
            "mt_opt_#{sanitize_identifier(c_type(type.base))}"
          end

          def named_type_c_name(type)
            return task_type_name(type) if type.is_a?(Types::Task)
            if type.is_a?(Types::VariantArmPayload)
              return "#{named_type_c_name(type.variant_type)}_#{type.arm_name}"
            end

            if type.respond_to?(:linkage_name) && type.linkage_name
              return type.linkage_name
            end

            base_name = type.module_name&.start_with?("std.c.") ? type.name : type.module_name ? "#{module_c_prefix(type.module_name)}_#{type.name}" : type.name
            return base_name unless type.is_a?(Types::StructInstance) || type.is_a?(Types::VariantInstance)

            "#{base_name}_#{sanitize_identifier(type.arguments.join('_'))}"
          end

          def external_opaque_c_type(type)
            type.linkage_name || type.name
          end

          def sanitize_identifier(text)
            identifier = text.gsub(SANITIZE_NON_ALNUM_RE, "_").gsub(SANITIZE_UNDERSCORES_RE, "_").sub(SANITIZE_LEADING_UNDERSCORES_RE, "").sub(SANITIZE_TRAILING_UNDERSCORES_RE, "")
            identifier.empty? ? "value" : identifier
          end

          def module_c_prefix(module_name)
            sanitize_identifier(module_name.to_s.tr('.', '_'))
          end

          def primitive_c_type(name)
            PRIMITIVE_C_TYPE_MAP.fetch(name)
          end

          def generic_c_type(type)
            case type.name
            when "ptr"
              raise CBackendError, "ptr requires exactly one type argument" unless type.arguments.length == 1

              "#{c_type(type.arguments.first)}*"
            when "const_ptr"
              raise CBackendError, "const_ptr requires exactly one type argument" unless type.arguments.length == 1

              "const #{c_type(type.arguments.first)}*"
            when "own"
              raise CBackendError, "own requires exactly one type argument" unless type.arguments.length == 1

              "#{c_type(type.arguments.first)}*"
            when "ref"
              raise CBackendError, "ref requires at least one type argument" unless [1, 2].include?(type.arguments.length)

              "#{c_type(type.arguments.length == 1 ? type.arguments.first : type.arguments[1])}*"
            when "str_buffer"
              raise CBackendError, "str_buffer requires exactly one type argument" unless str_buffer_type?(type)

              str_buffer_type_name(type)
            when "atomic"
              "_Atomic #{c_type(type.arguments.first)}"
            else
              raise CBackendError, "unsupported generic C type #{type.name}"
            end
          end

          def mutable_pointer_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
          end

          def const_pointer_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "const_ptr" && type.arguments.length == 1
          end

          def own_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "own" && type.arguments.length == 1
          end

          def pointer_type?(type)
            mutable_pointer_type?(type)
          end

          def c_backend_pointer_like_type?(type)
            pointer_type?(type) || const_pointer_type?(type) || own_type?(type) || (type.is_a?(Types::Primitive) && type.name == "cstr") || type.is_a?(Types::Function) || type.is_a?(Types::Proc) || type.is_a?(Types::Opaque)
          end

          def raw_pointer_type?(type)
            mutable_pointer_type?(type) || const_pointer_type?(type) || own_type?(type)
          end

          def ref_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "ref" && [1, 2].include?(type.arguments.length)
          end

          def array_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
              type.arguments[1].is_a?(Types::LiteralTypeArg)
          end

          def array_element_type(type)
            type.arguments.first
          end

          def array_length(type)
            type.arguments[1].value
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

          def str_buffer_type_name(type)
            "mt_str_buffer_#{str_buffer_capacity(type)}"
          end

          def pointer_to(type)
            Types::Registry.generic_instance("ptr", [type])
          end
    end
  end
end
