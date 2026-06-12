# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def build_analysis
        Analysis.new(
          ast: @ast,
          module_name: @module_name,
          module_kind: @module_kind,
          directives: @ast.directives,
          imports: @imports,
          types: @types,
          interfaces: @interfaces,
          attributes: snapshot_attributes,
          attribute_applications: snapshot_attribute_applications,
          values: @top_level_values,
          functions: @top_level_functions,
          methods: snapshot_methods,
          implemented_interfaces: snapshot_implemented_interfaces,
          local_completion_frames: @local_completion_frames.dup.freeze,
          binding_resolution: binding_resolution_snapshot,
          callable_value_identifier_sites: @callable_value_identifier_sites.dup.freeze,
          callable_value_member_access_sites: @callable_value_member_access_sites.dup.freeze,
          required_unsafe_lines: @required_unsafe_lines.uniq.freeze,
        )
      end

      def install_builtin_types
        INSTALLABLE_BUILTIN_TYPE_NAMES.each do |name|
          @types[name] = case name
                         when "str"
                           Types::StringView.new
                         when "Option"
                           builtin_option_type
                         when "Result"
                           builtin_result_type
                         when "Subscription"
                           builtin_subscription_type
                         when "EventError"
                           builtin_event_error_type
                         when "struct_handle"
                           builtin_struct_handle_type
                         when "field_handle"
                           builtin_field_handle_type
                         when "callable_handle"
                           builtin_callable_handle_type
                          when "attribute_handle"
                            builtin_attribute_handle_type
                          when "member_handle"
                            builtin_member_handle_type
                          when "type"
                            builtin_type_meta_type
                          when "vec2"
                            Types::Vector.new("vec2", element_type: Types::BUILTIN_VECTOR_ELEMENT, width: 2)
                          when "vec3"
                            Types::Vector.new("vec3", element_type: Types::BUILTIN_VECTOR_ELEMENT, width: 3)
                          when "vec4"
                            Types::Vector.new("vec4", element_type: Types::BUILTIN_VECTOR_ELEMENT, width: 4)
                          when "ivec2"
                            Types::Vector.new("ivec2", element_type: Types::BUILTIN_IVECTOR_ELEMENT, width: 2)
                          when "ivec3"
                            Types::Vector.new("ivec3", element_type: Types::BUILTIN_IVECTOR_ELEMENT, width: 3)
                          when "ivec4"
                            Types::Vector.new("ivec4", element_type: Types::BUILTIN_IVECTOR_ELEMENT, width: 4)
                          when "mat3"
                            Types::Matrix.new("mat3", dim: 3)
                          when "mat4"
                            Types::Matrix.new("mat4", dim: 4)
                          when "quat"
                            Types::Quaternion.new("quat")
                          else
                            Types::Primitive.new(name)
                         end
        end
      end

      def builtin_option_type
        Types::BUILTIN_OPTION_TYPE
      end

      def builtin_result_type
        Types::BUILTIN_RESULT_TYPE
      end

      def builtin_subscription_type
        Types::Subscription.new
      end

      def builtin_event_error_type
        Types::Enum.new("EventError").define_members(@types.fetch("int"), ["full"]).define_member_values("full" => 0)
      end

      def builtin_struct_handle_type
        Types::BUILTIN_STRUCT_HANDLE_TYPE
      end

      def builtin_field_handle_type
        Types::BUILTIN_FIELD_HANDLE_TYPE
      end

      def builtin_callable_handle_type
        Types::BUILTIN_CALLABLE_HANDLE_TYPE
      end

      def builtin_attribute_handle_type
        Types::BUILTIN_ATTRIBUTE_HANDLE_TYPE
      end

      def builtin_member_handle_type
        Types::BUILTIN_MEMBER_HANDLE_TYPE
      end

      def builtin_type_meta_type
        Types::BUILTIN_TYPE_META_TYPE
      end

      def install_builtin_attributes
        BUILTIN_ATTRIBUTE_NAMES.each do |name|
          @attributes[name] = Sema.builtin_attribute_binding(name, @types)
        end
      end

      def snapshot_attributes
        @attributes.each_with_object({}) do |(name, binding), attributes|
          next if binding.builtin

          attributes[name] = binding
        end.freeze
      end

      def snapshot_attribute_applications
        @resolved_attribute_applications.each_with_object({}) do |(target_id, applications), snapshot|
          snapshot[target_id] = applications
        end.freeze
      end

      def snapshot_methods
        @methods.each_with_object({}) do |(receiver_type, bindings), methods|
          methods[receiver_type] = bindings.dup.freeze
        end.freeze
      end

      def snapshot_implemented_interfaces
        @implemented_interfaces.each_with_object({}) do |(receiver_type, interfaces), snapshot|
          snapshot[receiver_type] = interfaces.dup.freeze
        end.freeze
      end

      def install_imports
        @ast.imports.each do |import|
          with_error_node(import) do
            alias_name = import.alias_name || import.path.parts.last
            ensure_non_reserved_import_alias_name!(alias_name, kind_label: "import alias", line: import.line, column: import.column)
            raise_sema_error("duplicate import alias #{alias_name}") if @imports.key?(alias_name)

            module_binding = @imported_modules[import.path.to_s]
            next if @allow_missing_imports && module_binding.nil?
            raise_sema_error("unknown import #{import.path}") unless module_binding

            @imports[alias_name] = module_binding
          end
        end
      end

      def declare_named_types
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            case decl
            when AST::StructDecl
              validate_struct_layout!(decl)
              validate_explicit_aggregate_c_name!(decl)
              ensure_available_type_name!(decl.name)
              @types[decl.name] = if decl.type_params.empty?
                                    Types::Struct.new(
                                      decl.name,
                                      module_name: @module_name,
                                      external: raw_module?,
                                      packed: decl.packed,
                                      alignment: decl.alignment,
                                      c_name: decl.c_name,
                                      lifetime_params: decl.lifetime_params,
                                    )
                                  else
                                    Types::GenericStructDefinition.new(
                                      decl.name,
                                      decl.type_params.map(&:name),
                                      module_name: @module_name,
                                      external: raw_module?,
                                      packed: decl.packed,
                                      alignment: decl.alignment,
                                      c_name: decl.c_name,
                                      lifetime_params: decl.lifetime_params,
                                    )
                                  end
            when AST::UnionDecl
              validate_explicit_aggregate_c_name!(decl)
              ensure_available_type_name!(decl.name)
              @types[decl.name] = Types::Union.new(decl.name, module_name: @module_name, external: raw_module?, c_name: decl.c_name)
            when AST::VariantDecl
              ensure_available_type_name!(decl.name)
              @types[decl.name] = if decl.type_params.empty?
                                    Types::Variant.new(decl.name, module_name: @module_name)
                                  else
                                    Types::GenericVariantDefinition.new(
                                      decl.name,
                                      decl.type_params.map(&:name),
                                      module_name: @module_name,
                                    )
                                  end
            when AST::EnumDecl
              ensure_available_type_name!(decl.name)
              @types[decl.name] = Types::Enum.new(decl.name, module_name: @module_name, external: raw_module?)
            when AST::FlagsDecl
              ensure_available_type_name!(decl.name)
              @types[decl.name] = Types::Flags.new(decl.name, module_name: @module_name, external: raw_module?)
            when AST::OpaqueDecl
              ensure_available_type_name!(decl.name)
              @types[decl.name] = Types::Opaque.new(
                decl.name,
                module_name: @module_name,
                external: raw_module?,
                c_name: decl.c_name,
              )
            when AST::InterfaceDecl
              ensure_available_type_name!(decl.name)
              @interfaces[decl.name] = declare_interface_binding(decl)
            end
          end
        rescue SemaError => e
          collect_structural_error(e)
        end
      end

      def resolve_generic_type_param_constraints
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            next unless decl.is_a?(AST::StructDecl) || decl.is_a?(AST::VariantDecl)
            next if decl.type_params.empty?

            @types.fetch(decl.name).define_type_param_constraints(resolve_type_param_constraints(decl.type_params))
          end
        end
      end

      def resolve_type_aliases
        @ast.declarations.grep(AST::TypeAliasDecl).each do |decl|
          ensure_available_type_name!(decl.name)
          @types[decl.name] = resolve_type_ref(decl.target)
        rescue SemaError => e
          collect_structural_error(e)
        end
      end

      def declare_attributes
        @ast.declarations.grep(AST::AttributeDecl).each do |decl|
          with_error_node(decl) do
            raise_sema_error("duplicate attribute #{decl.name}") if @attributes.key?(decl.name)

            params = []
            seen = {}
            decl.params.each do |param|
              raise_sema_error("duplicate attribute parameter #{decl.name}.#{param.name}") if seen.key?(param.name)

              seen[param.name] = true
              params << Types::Parameter.new(param.name, resolve_type_ref(param.type))
            end

            @attributes[decl.name] = AttributeBinding.new(
              name: decl.name,
              targets: decl.targets.freeze,
              params: params.freeze,
              module_name: @module_name,
              builtin: false,
              ast: decl,
            )
          end
        end
      end

      def declare_interface_binding(decl)
        methods = {}

        decl.methods.each do |method_decl|
          method = resolve_interface_method_binding(method_decl)
          raise_sema_error("duplicate method #{decl.name}.#{method.name}") if methods.key?(method.name)

          methods[method.name] = method
        end

        InterfaceBinding.new(
          name: decl.name,
          methods: methods.freeze,
          ast: decl,
          module_name: @module_name,
        )
      end

      def resolve_interface_method_binding(method_decl)
        raise_sema_error("interface method #{method_decl.name} cannot be async") if method_decl.async

        params = []
        seen = {}
        method_decl.params.each do |param|
          raise_sema_error("duplicate parameter #{param.name} in #{method_decl.name}") if seen.key?(param.name)

          seen[param.name] = true
          type = resolve_type_ref(param.type)
          validate_parameter_ref_type!(type, function_name: method_decl.name, parameter_name: param.name, external: false)
          validate_parameter_proc_type!(type, function_name: method_decl.name, parameter_name: param.name, external: false, foreign: false)
          params << Types::Parameter.new(param.name, type)
        end

        return_type = method_decl.return_type ? resolve_type_ref(method_decl.return_type) : @types.fetch("void")
        validate_return_ref_type!(return_type, function_name: method_decl.name)
        validate_return_proc_type!(return_type, function_name: method_decl.name)

        InterfaceMethodBinding.new(
          name: method_decl.name,
          params: params.freeze,
          return_type: return_type,
          kind: method_decl.kind,
          async: method_decl.async,
          ast: method_decl,
        )
      end

      def validate_struct_layout!(decl)
        return unless decl.alignment

        raise_sema_error("align(...) requires a positive alignment") unless decl.alignment.positive?
        return if power_of_two?(decl.alignment)

        raise_sema_error("align(...) requires a power-of-two alignment, got #{decl.alignment}")
      end

      def validate_explicit_aggregate_c_name!(decl)
        return unless decl.c_name

        raise_sema_error("explicit C names are only allowed on external structs and unions") unless raw_module?
        return if !decl.respond_to?(:type_params) || decl.type_params.empty?

        raise_sema_error("explicit C names are not supported on generic external structs")
      end

      def resolve_event_decl_type(decl, type_params: {}, type_param_constraints: {}, owner_type_name: nil)
        raise_sema_error("event #{decl.name} capacity must be positive") unless decl.capacity.is_a?(Integer) && decl.capacity.positive?

        payload_type = decl.payload_type ? resolve_type_ref(decl.payload_type, type_params:, type_param_constraints:) : nil
        if payload_type
          raise_sema_error("event #{decl.name} payload cannot be ref[T] in v1") if ref_type?(payload_type)
          validate_stored_ref_type!(payload_type, "event #{decl.name} payload")
          raise_sema_error("event #{decl.name} payload uses unsupported proc nesting") unless proc_storage_supported_type?(payload_type)
          raise_sema_error("event #{decl.name} payload cannot use event storage type #{payload_type}") if noncopyable_event_storage_type?(payload_type)
        end

        Types::Event.new(
          decl.name,
          capacity: decl.capacity,
          payload_type: payload_type,
          module_name: @module_name,
          visibility: decl.visibility,
          owner_type_name: owner_type_name,
        )
      end

      def resolve_aggregate_fields
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            next unless decl.is_a?(AST::StructDecl) || decl.is_a?(AST::UnionDecl)

            struct_type = @types.fetch(decl.name)
            struct_type.ast_declaration = decl if struct_type.respond_to?(:ast_declaration=)
            type_params = if struct_type.is_a?(Types::GenericStructDefinition)
                            seen = {}
                            struct_type.type_params.each_with_object({}) do |name, params|
                              raise_sema_error("duplicate type parameter #{decl.name}[#{name}]") if seen.key?(name)

                              seen[name] = true
                              params[name] = Types::TypeVar.new(name)
                            end
                          else
                            {}
                          end
            type_param_constraints = struct_type.is_a?(Types::GenericStructDefinition) ? struct_type.type_param_constraints : {}
            fields = {}
            events = {}

            decl.fields.each do |field|
              raise_sema_error("duplicate field #{decl.name}.#{field.name}") if fields.key?(field.name)
              raise_sema_error("duplicate member #{decl.name}.#{field.name}") if events.key?(field.name)
              unless raw_module?
                ensure_non_reserved_type_binding_name!(
                  field.name,
                  kind_label: "field #{decl.name}",
                  line: field.respond_to?(:line) ? field.line : decl.line,
                  column: field.respond_to?(:column) ? field.column : nil,
                )
              end

              begin
                field_type = resolve_type_ref(field.type, type_params:, type_param_constraints:)
                if decl.respond_to?(:lifetime_params) && (lt = ref_lifetime(field_type))
                  unless decl.lifetime_params.include?(lt)
                    raise_sema_error("field #{decl.name}.#{field.name} uses lifetime #{lt} not declared on struct")
                  end
                end
                allow_lts = decl.respond_to?(:lifetime_params) ? decl.lifetime_params : []
                validate_stored_ref_type!(field_type, "field #{decl.name}.#{field.name}", allow_lifetimes: allow_lts)
                unless proc_storage_supported_type?(field_type)
                  raise_sema_error("field #{decl.name}.#{field.name} uses unsupported proc nesting")
                end
                fields[field.name] = field_type
              rescue SemaError => e
                collect_structural_error(e)
              end
            end

            if decl.is_a?(AST::StructDecl)
              decl.events.each do |event_decl|
                raise_sema_error("duplicate event #{decl.name}.#{event_decl.name}") if events.key?(event_decl.name)
                raise_sema_error("duplicate member #{decl.name}.#{event_decl.name}") if fields.key?(event_decl.name)
                unless raw_module?
                  ensure_non_reserved_type_binding_name!(
                    event_decl.name,
                    kind_label: "event #{decl.name}",
                    line: event_decl.line,
                    column: event_decl.column,
                  )
                end

                begin
                  events[event_decl.name] = resolve_event_decl_type(
                    event_decl,
                    type_params:,
                    type_param_constraints:,
                    owner_type_name: decl.name,
                  )
                rescue SemaError => e
                  collect_structural_error(e)
                end
              end
            end

            struct_type.define_fields(fields)
            struct_type.define_events(events) if struct_type.respond_to?(:define_events)
          end
        rescue SemaError => e
          collect_structural_error(e)
        end
      end

      def resolve_enum_members
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            next unless decl.is_a?(AST::EnumDecl) || decl.is_a?(AST::FlagsDecl)

            enum_type = @types.fetch(decl.name)
            backing_type = resolve_type_ref(decl.backing_type)
            unless backing_type.is_a?(Types::Primitive) && backing_type.integer?
              raise_sema_error("#{decl.name} backing type must be an integer primitive, got #{backing_type}")
            end

            member_names = []
            decl.members.each do |member|
              raise_sema_error("duplicate member #{decl.name}.#{member.name}") if member_names.include?(member.name)
              unless raw_module?
                ensure_non_reserved_type_binding_name!(
                  member.name,
                  kind_label: "member #{decl.name}",
                  line: member.respond_to?(:line) ? member.line : decl.line,
                  column: member.respond_to?(:column) ? member.column : nil,
                )
              end

              member_names << member.name
            end

            enum_type.define_members(backing_type, member_names)

            member_values = {}

            decl.members.each do |member|
              begin
                actual_type = infer_expression(member.value, scopes: [], expected_type: backing_type)
                const_value = evaluate_enum_member_const_value(member.value, enum_type:, member_values:)

                compatible = types_compatible?(actual_type, backing_type, expression: member.value, scopes: [])
                compatible ||= const_value.is_a?(Integer) && numeric_constant_fits_type?(const_value, backing_type)
                raise_sema_error("member #{decl.name}.#{member.name} expects #{backing_type}, got #{actual_type}") unless compatible

                raise_sema_error("member #{decl.name}.#{member.name} must be a compile-time integer constant") unless const_value.is_a?(Integer)

                member_values[member.name] = const_value
              rescue SemaError => e
                collect_structural_error(e)
              end
            end

            enum_type.define_member_values(member_values)
          end
        rescue SemaError => e
          collect_structural_error(e)
        end
      end

      def resolve_variant_arms
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            next unless decl.is_a?(AST::VariantDecl)

            variant_type = @types.fetch(decl.name)
            type_params = if variant_type.is_a?(Types::GenericVariantDefinition)
                            seen = {}
                            variant_type.type_params.each_with_object({}) do |name, params|
                              raise_sema_error("duplicate type parameter #{decl.name}[#{name}]") if seen.key?(name)

                              seen[name] = true
                              params[name] = Types::TypeVar.new(name)
                            end
                          else
                            {}
                          end
            type_param_constraints = variant_type.is_a?(Types::GenericVariantDefinition) ? variant_type.type_param_constraints : {}
            seen_arms = []
            arms_hash = {}
            decl.arms.each do |arm|
              begin
                raise_sema_error("duplicate arm #{decl.name}.#{arm.name}") if seen_arms.include?(arm.name)
                unless raw_module?
                  ensure_non_reserved_type_binding_name!(
                    arm.name,
                    kind_label: "arm #{decl.name}",
                    line: arm.respond_to?(:line) ? arm.line : decl.line,
                    column: arm.respond_to?(:column) ? arm.column : nil,
                  )
                end

                seen_arms << arm.name
                field_types = {}
                seen_fields = []
                arm.fields.each do |field|
                  begin
                    raise_sema_error("duplicate field #{arm.name}.#{field.name}") if seen_fields.include?(field.name)
                    unless raw_module?
                      ensure_non_reserved_type_binding_name!(
                        field.name,
                        kind_label: "field #{decl.name}.#{arm.name}",
                        line: field.respond_to?(:line) ? field.line : decl.line,
                        column: field.respond_to?(:column) ? field.column : nil,
                      )
                    end

                    seen_fields << field.name
                    field_type = resolve_type_ref(field.type, type_params:, type_param_constraints:)
                    validate_stored_ref_type!(field_type, "field #{decl.name}.#{arm.name}.#{field.name}")
                    unless proc_storage_supported_type?(field_type)
                      raise_sema_error("field #{decl.name}.#{arm.name}.#{field.name} uses unsupported proc nesting")
                    end
                    field_types[field.name] = field_type
                  rescue SemaError => e
                    collect_structural_error(e)
                  end
                end
                arms_hash[arm.name] = field_types
              rescue SemaError => e
                collect_structural_error(e)
              end
            end

            variant_type.define_arms(arms_hash)
          end
        rescue SemaError => e
          collect_structural_error(e)
        end
      end

      def ensure_available_type_name!(name, line: nil, column: nil, length: nil)
        ensure_non_reserved_type_binding_name!(name, kind_label: "type", line:, column:, length:) unless raw_module?
        raise_sema_error("duplicate type #{name}") if @types.key?(name) || @interfaces.key?(name)
      end

      def ensure_available_value_name!(name, kind_label: "value", line: nil, column: nil, length: nil)
        ensure_non_reserved_value_type_name!(name, kind_label:, line:, column:, length:)
        raise_sema_error("duplicate value #{name}") if @top_level_values.key?(name) || @top_level_functions.key?(name)
      end

      def ensure_non_reserved_value_type_name!(name, kind_label:, line: nil, column: nil, length: nil)
        return unless Types::RESERVED_VALUE_TYPE_NAMES.include?(name)

        raise_sema_error("#{kind_label} #{name} uses reserved built-in type name #{name}", line:, column:, length:)
      end

      def ensure_non_reserved_import_alias_name!(name, kind_label:, line: nil, column: nil, length: nil)
        return unless Types::RESERVED_IMPORT_ALIAS_NAMES.include?(name)

        raise_sema_error("#{kind_label} #{name} uses reserved built-in type name #{name}", line:, column:, length:)
      end

      def ensure_non_reserved_type_binding_name!(name, kind_label:, line: nil, column: nil, length: nil)
        return unless Types::RESERVED_TYPE_BINDING_NAMES.include?(name)

        raise_sema_error("#{kind_label} #{name} uses reserved built-in type name #{name}", line:, column:, length:)
      end

      def declare_top_level_values
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            case decl
            when AST::ConstDecl
              ensure_available_value_name!(decl.name, kind_label: "constant", line: decl.line, column: decl.respond_to?(:column) ? decl.column : nil)
              type = resolve_type_ref(decl.type)
              validate_stored_ref_type!(type, "constant #{decl.name}")
              raise_sema_error("constant #{decl.name} cannot store proc values") if contains_proc_type?(type)
              @top_level_values[decl.name] = value_binding(
                name: decl.name,
                type: type,
                mutable: false,
                kind: :const,
              )
            when AST::VarDecl
              ensure_available_value_name!(decl.name, kind_label: "module variable", line: decl.line, column: decl.respond_to?(:column) ? decl.column : nil)
              raise_sema_error("module variable #{decl.name} requires an explicit type") unless decl.type

              type = resolve_type_ref(decl.type)
              validate_stored_ref_type!(type, "module variable #{decl.name}")
              raise_sema_error("module variable #{decl.name} cannot store proc values") if contains_proc_type?(type)
              @top_level_values[decl.name] = value_binding(
                name: decl.name,
                type: type,
                mutable: true,
                kind: :var,
              )
            when AST::EventDecl
              ensure_available_value_name!(decl.name, kind_label: "event", line: decl.line, column: decl.column)
              @top_level_values[decl.name] = value_binding(
                name: decl.name,
                type: resolve_event_decl_type(decl),
                mutable: false,
                kind: :event,
              )
            end
          end
        rescue SemaError => e
          collect_structural_error(e)
        end
      end

      def ensure_non_reserved_primitive_name!(name, kind_label:, line: nil, column: nil, length: nil)
        ensure_non_reserved_value_type_name!(name, kind_label:, line:, column:, length:)
      end


    end
  end
end
