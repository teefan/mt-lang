# frozen_string_literal: true

module MilkTea
  class SemaError < StandardError
    attr_reader :line, :column, :length

    def initialize(msg = nil, line: nil, column: nil, length: nil)
      super(msg)
      @line = line
      @column = column
      @length = length
    end

    def to_diagnostic(path: nil)
      Diagnostic.new(
        path:,
        line: @line,
        column: @column,
        length: @length,
        code: "sema/error",
        message: message,
        severity: :error,
      )
    end
  end

  class Sema
    Analysis = Data.define(:ast, :module_name, :module_kind, :directives, :imports, :types, :interfaces, :values, :functions, :methods, :implemented_interfaces, :local_completion_frames, :binding_resolution, :callable_value_identifier_sites, :callable_value_member_access_sites, :required_unsafe_lines)
    Facts = Analysis
    ToolingSnapshot = Data.define(:facts, :diagnostics) do
      def analysis
        facts
      end

      def ok?
        diagnostics.none?(&:error?)
      end
    end
    LocalCompletionFrame = Data.define(:start_line, :end_line, :function_name, :receiver_type, :snapshots)
    LocalCompletionSnapshot = Data.define(:line, :column, :bindings)
    BindingResolution = Data.define(:identifier_binding_ids, :declaration_binding_ids, :mutating_argument_identifier_ids, :mutable_receiver_expression_ids, :binding_types)
    class FlowScope
      def initialize = (@bindings = {})
      def [](key) = @bindings[key]
      def []=(key, val); @bindings[key] = val; end
      def key?(key) = @bindings.key?(key)
      def empty? = @bindings.empty?
      def each(&block) = @bindings.each(&block)
      def each_with_object(init, &block) = @bindings.each_with_object(init, &block)
    end
    ValueBinding = Data.define(:id, :name, :storage_type, :flow_type, :mutable, :kind, :const_value) do
      def type
        flow_type || storage_type
      end

      def with_flow_type(refined_type)
        ValueBinding.new(
          id:,
          name:,
          storage_type:,
          flow_type: refined_type == storage_type ? nil : refined_type,
          mutable:,
          kind:,
          const_value:,
        )
      end
    end
    InterfaceMethodBinding = Data.define(:name, :params, :return_type, :kind, :async, :ast)
    InterfaceBinding = Data.define(:name, :methods, :ast, :module_name)
    FunctionBinding = Data.define(:name, :type, :body_params, :body_return_type, :ast, :external, :async, :type_params, :type_param_constraints, :instances, :type_arguments, :owner, :specialization_owner, :type_substitutions, :declared_receiver_type)
    TypeParamConstraintBinding = Data.define(:interfaces) do
      def initialize(interfaces: []) = super
    end
    DefaultResolution = Data.define(:target_type, :binding)
    HashResolution = Data.define(:target_type, :binding)
    EqualResolution = Data.define(:target_type, :binding)
    OrderResolution = Data.define(:target_type, :binding)
    ModuleBinding = Data.define(:name, :types, :interfaces, :values, :functions, :methods, :implemented_interfaces, :imports, :private_types, :private_interfaces, :private_values, :private_functions, :private_methods, :private_implemented_interfaces) do
      def private_type?(name)
        private_types.key?(name)
      end

      def private_interface?(name)
        private_interfaces.key?(name)
      end

      def private_value?(name)
        private_values.key?(name)
      end

      def private_function?(name)
        private_functions.key?(name)
      end

      def private_method?(receiver_type, name)
        return true if private_methods.fetch(receiver_type, {}).key?(name)

        if receiver_type.is_a?(Types::GenericInstance)
          dispatch_receiver_type = Types::GenericInstance.new(
            receiver_type.name,
            receiver_type.arguments.each_with_index.map do |argument, index|
              argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
            end,
          )
          return true if dispatch_receiver_type != receiver_type && private_methods.fetch(dispatch_receiver_type, {}).key?(name)
        end

        if receiver_type.is_a?(Types::Nullable)
          dispatch_base_type = receiver_type.base
          if dispatch_base_type.is_a?(Types::StructInstance)
            dispatch_base_type = dispatch_base_type.definition
          elsif dispatch_base_type.is_a?(Types::GenericInstance)
            dispatch_base_type = Types::GenericInstance.new(
              dispatch_base_type.name,
              dispatch_base_type.arguments.each_with_index.map do |argument, index|
                argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
              end,
            )
          end

          dispatch_receiver_type = Types::Nullable.new(dispatch_base_type)
          return true if dispatch_receiver_type != receiver_type && private_methods.fetch(dispatch_receiver_type, {}).key?(name)
        end

        receiver_type.is_a?(Types::StructInstance) && private_methods.fetch(receiver_type.definition, {}).key?(name)
      end
    end

    BUILTIN_TYPE_NAMES = (Types::BUILTIN_PRIMITIVE_NAMES + %w[Option Result]).freeze

    def self.check(ast, imported_modules: {}, allow_missing_imports: false)
      Checker.new(ast, imported_modules:, allow_missing_imports:).check
    end

    # LSP-oriented entry point: runs all sema phases and collects errors from
    # each function/method individually instead of stopping at the first one.
    # Returns { analysis: Analysis|nil, errors: [SemaError] }.
    # Structural errors (bad imports, unknown types) still abort early with a
    # single error; only function-body errors are collected in bulk.
    def self.check_collecting_errors(ast, imported_modules: {}, allow_missing_imports: false)
      Checker.new(ast, imported_modules:, allow_missing_imports:).check_collecting_errors
    rescue SemaError => e
      { analysis: nil, errors: [e] }
    end

    def self.tooling_snapshot(ast, imported_modules: {}, allow_missing_imports: false, path: nil)
      result = check_collecting_errors(ast, imported_modules:, allow_missing_imports:)
      diagnostics = Array(result[:errors]).map { |error| error.to_diagnostic(path:) }.freeze

      ToolingSnapshot.new(facts: result[:analysis], diagnostics:)
    end

    class Checker
      include TypeCompatibilityPredicates

      attr_reader :module_name

      def initialize(ast, imported_modules: {}, allow_missing_imports: false)
        @ast = ast
        @imported_modules = imported_modules
        @allow_missing_imports = allow_missing_imports
        @module_name = ast.module_name&.to_s
        @module_kind = ast.module_kind
        @const_declarations = ast.declarations.grep(AST::ConstDecl).each_with_object({}) { |decl, result| result[decl.name] = decl }
        @types = {}
        @interfaces = {}
        @top_level_values = {}
        @top_level_functions = {}
        @imports = {}
        @methods = Hash.new { |hash, key| hash[key] = {} }
        @implemented_interfaces = Hash.new { |hash, key| hash[key] = [] }
        @null_type = Types::Null.new
        @error_type = Types::Error.new
        @loop_depth = 0
        @unsafe_depth = 0
        @foreign_mapping_depth = 0
        @async_function_depth = 0
        @proc_expression_depth = 0
        @checked_function_bindings = {}
        @checking_function_bindings = {}
        @evaluating_const_values = []
        @evaluated_const_values = {}
        @error_node_stack = []
        @local_completion_frames = []
        @active_local_completion_stack = []
        @next_binding_id = 1
        @binding_name_by_id = {}
        @binding_type_by_id = {}
        @identifier_binding_ids = {}
        @declaration_binding_ids = {}
        @mutating_argument_identifier_ids = {}
        @mutable_receiver_expression_ids = {}
        @preassigned_local_binding_ids = {}
        @nullability_flow_result = nil
        @unsafe_statement_lines = []
        @callable_value_identifier_sites = {}
        @callable_value_member_access_sites = {}
        @required_unsafe_lines = []
        @current_specialization_owner = nil
        @return_context_stack = []
      end

      def check
        install_builtin_types
        install_imports
        declare_named_types
        resolve_generic_type_param_constraints
        resolve_type_aliases
        resolve_aggregate_fields
        resolve_enum_members
        resolve_variant_arms
        declare_top_level_values
        declare_functions
        check_interface_conformances
        check_top_level_values
        finalize_top_level_const_values
        check_top_level_static_asserts
        check_functions

        Analysis.new(
          ast: @ast,
          module_name: @module_name,
          module_kind: @module_kind,
          directives: @ast.directives,
          imports: @imports,
          types: @types,
          interfaces: @interfaces,
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

      # Like check, but collects per-function errors instead of raising at first.
      # Structural phases (imports, type resolution, declaration) still raise; only
      # the value-checking and function-body phases collect errors individually.
      # Returns { analysis: Analysis, errors: [SemaError] }.
      def check_collecting_errors
        install_builtin_types
        install_imports
        declare_named_types
        resolve_generic_type_param_constraints
        resolve_type_aliases
        resolve_aggregate_fields
        resolve_enum_members
        resolve_variant_arms
        declare_top_level_values
        declare_functions
        check_interface_conformances

        errors = []

        begin
          check_top_level_values
        rescue SemaError => e
          errors << e
        end

        begin
          finalize_top_level_const_values
        rescue SemaError => e
          errors << e
        end

        begin
          check_top_level_static_asserts
        rescue SemaError => e
          errors << e
        end

        check_functions_collecting(errors)

        analysis = Analysis.new(
          ast: @ast,
          module_name: @module_name,
          module_kind: @module_kind,
          directives: @ast.directives,
          imports: @imports,
          types: @types,
          interfaces: @interfaces,
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

        { analysis: analysis, errors: errors.uniq { |e| [e.message, e.line, e.column, e.length] } }
      end

      private

      def install_builtin_types
        BUILTIN_TYPE_NAMES.each do |name|
          @types[name] = case name
                         when "str"
                           Types::StringView.new
                         when "Option"
                           builtin_option_type
                         when "Result"
                           builtin_result_type
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

      def resolve_aggregate_fields
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            next unless decl.is_a?(AST::StructDecl) || decl.is_a?(AST::UnionDecl)

            struct_type = @types.fetch(decl.name)
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

            decl.fields.each do |field|
              raise_sema_error("duplicate field #{decl.name}.#{field.name}") if fields.key?(field.name)
              unless raw_module?
                ensure_non_reserved_type_binding_name!(
                  field.name,
                  kind_label: "field #{decl.name}",
                  line: field.respond_to?(:line) ? field.line : decl.line,
                  column: field.respond_to?(:column) ? field.column : nil,
                )
              end

              field_type = resolve_type_ref(field.type, type_params:, type_param_constraints:)
              validate_stored_ref_type!(field_type, "field #{decl.name}.#{field.name}")
              unless proc_storage_supported_type?(field_type)
                raise_sema_error("field #{decl.name}.#{field.name} uses unsupported proc nesting")
              end
              fields[field.name] = field_type
            end

            struct_type.define_fields(fields)
          end
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
              actual_type = infer_expression(member.value, scopes: [], expected_type: backing_type)
              const_value = evaluate_enum_member_const_value(member.value, enum_type:, member_values:)

              compatible = types_compatible?(actual_type, backing_type, expression: member.value, scopes: [])
              compatible ||= const_value.is_a?(Integer) && numeric_constant_fits_type?(const_value, backing_type)
              raise_sema_error("member #{decl.name}.#{member.name} expects #{backing_type}, got #{actual_type}") unless compatible

              raise_sema_error("member #{decl.name}.#{member.name} must be a compile-time integer constant") unless const_value.is_a?(Integer)

              member_values[member.name] = const_value
            end

            enum_type.define_member_values(member_values)
          end
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
                field_types[field.name] = resolve_type_ref(field.type, type_params:, type_param_constraints:)
              end
              arms_hash[arm.name] = field_types
            end

            variant_type.define_arms(arms_hash)
          end
        end
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
            end
          end
        end
      end

      def declare_functions
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            case decl
            when AST::FunctionDef
              ensure_available_value_name!(decl.name, kind_label: "function", line: decl.line, column: decl.respond_to?(:column) ? decl.column : nil)
              @top_level_functions[decl.name] = declare_function_binding(decl)
            when AST::ExternFunctionDecl
              ensure_available_value_name!(decl.name, kind_label: "function", line: decl.line, column: decl.respond_to?(:column) ? decl.column : nil)
              @top_level_functions[decl.name] = declare_function_binding(decl, external: true)
            when AST::ForeignFunctionDecl
              ensure_available_value_name!(decl.name, kind_label: "function", line: decl.line, column: decl.respond_to?(:column) ? decl.column : nil)
              @top_level_functions[decl.name] = declare_function_binding(decl)
            when AST::ExtendingBlock
              dispatch_receiver_type, receiver_type, receiver_type_param_names, receiver_type_param_constraints = resolve_methods_receiver_target(decl.type_name)

              decl.methods.each do |method|
                binding = declare_function_binding(
                  method,
                  receiver_type:,
                  declared_receiver_type: receiver_type,
                  receiver_type_param_names:,
                  receiver_type_param_constraints:,
                )
                raise_sema_error("duplicate method #{decl.type_name}.#{binding.name}") if @methods[dispatch_receiver_type].key?(binding.name)

                @methods[dispatch_receiver_type][binding.name] = binding
              end
            end
          end
        end
      end

      def declare_function_binding(decl, receiver_type: nil, declared_receiver_type: nil, receiver_type_param_names: [], receiver_type_param_constraints: {}, external: false)
        foreign = decl.is_a?(AST::ForeignFunctionDecl)
        async_function = decl.respond_to?(:async) ? decl.async : false
        if decl.is_a?(AST::MethodDef)
          ensure_non_reserved_primitive_name!(decl.name, kind_label: "function", line: decl.line, column: decl.column)
        end
        type_param_names = receiver_type_param_names + decl.type_params.map(&:name)
        type_param_constraints = receiver_type_param_constraints.merge(resolve_type_param_constraints(decl.type_params))
        raise_sema_error("external function #{decl.name} cannot be generic") if external && type_param_names.any?
        raise_sema_error("main cannot be generic") if decl.name == "main" && type_param_names.any?
        raise_sema_error("external function #{decl.name} cannot be async") if external && async_function
        raise_sema_error("foreign function #{decl.name} cannot be async") if foreign && async_function

        method_kind = decl.is_a?(AST::MethodDef) ? decl.kind : nil
        instance_method = receiver_type && method_kind != :static

        type_params = {}
        type_param_names.each do |name|
          raise_sema_error("duplicate type parameter #{decl.name}[#{name}]") if type_params.key?(name)

          type_params[name] = Types::TypeVar.new(name)
        end

        body_params = []
        if instance_method
          body_params << value_binding(
            name: "this",
            type: receiver_type,
            mutable: method_kind == :mutable,
            kind: :param,
          )
        end

        public_params = []
        decl.params.each do |param|
          ensure_non_reserved_primitive_name!(param.name, kind_label: "parameter", line: param.respond_to?(:line) ? param.line : decl.line, column: param.respond_to?(:column) ? param.column : nil)
          type = resolve_type_ref(param.type, type_params:, type_param_constraints:)
          validate_parameter_ref_type!(type, function_name: decl.name, parameter_name: param.name, external:)
          validate_parameter_proc_type!(type, function_name: decl.name, parameter_name: param.name, external:, foreign:)

          if external && array_type?(type)
            raise_sema_error("external function #{decl.name} cannot take array parameters")
          end

          if param.is_a?(AST::ForeignParam)
            if external
              raise_sema_error("external parameter #{param.name} of #{decl.name} cannot use `as`") if param.boundary_type
              unless %i[plain out inout].include?(param.mode)
                raise_sema_error("external parameter #{param.name} of #{decl.name} cannot use `#{param.mode}`")
              end
            elsif foreign
              raise_sema_error("foreign parameter #{param.name} cannot use `as` with #{param.mode}") if ![:plain, :in].include?(param.mode) && param.boundary_type
              validate_consuming_foreign_parameter!(type, function_name: decl.name, parameter_name: param.name) if param.mode == :consuming
            end

            boundary_type = foreign_parameter_boundary_type(param, type, type_params:, type_param_constraints:)
            validate_foreign_boundary_type!(type, boundary_type, function_name: decl.name, parameter_name: param.name) if foreign && param.boundary_type && param.mode != :in
            validate_in_foreign_parameter!(type, boundary_type, function_name: decl.name, parameter_name: param.name) if foreign && param.mode == :in
            param_binding = value_binding(name: param.name, type: boundary_type || type, mutable: false, kind: :param)
            body_params << param_binding
            record_declaration_binding(param, param_binding)
            if foreign && param.boundary_type
              body_params << value_binding(
                name: foreign_mapping_public_alias_name(param.name),
                type:,
                mutable: false,
                kind: :param,
              )
            end
            public_params << Types::Parameter.new(param.name, type, passing_mode: param.mode, boundary_type: boundary_type)
          else
            param_binding = value_binding(name: param.name, type:, mutable: false, kind: :param)
            body_params << param_binding
            record_declaration_binding(param, param_binding)
            public_params << Types::Parameter.new(param.name, type) if external
          end
        end

        receiver_mutable = false
        call_params = body_params
        function_receiver_type = nil
        if instance_method
          receiver_mutable = method_kind == :mutable
          call_params = body_params.drop(1)
          function_receiver_type = receiver_type
        end

        call_params = public_params if foreign || external

        seen = {}
        body_params.each do |param|
          raise_sema_error("duplicate parameter #{param.name} in #{decl.name}") if seen.key?(param.name)

          seen[param.name] = true
        end

        body_return_type = decl.return_type ? resolve_type_ref(decl.return_type, type_params:, type_param_constraints:) : @types.fetch("void")
        validate_return_ref_type!(body_return_type, function_name: decl.name)
        validate_return_proc_type!(body_return_type, function_name: decl.name)
        if decl.name == "main" && async_function && body_return_type != @types.fetch("int") && body_return_type != @types.fetch("void")
          raise_sema_error("async main must return int or void")
        end
        if foreign && public_params.any? { |param| param.passing_mode == :consuming } && body_return_type != @types.fetch("void")
          raise_sema_error("foreign function #{decl.name} with consuming parameters must return void")
        end
        if external && array_type?(body_return_type)
          raise_sema_error("external function #{decl.name} cannot return arrays")
        end
        function_return_type = async_function ? Types::Task.new(body_return_type) : body_return_type

        function_type = Types::Function.new(
          decl.name,
          params: (foreign || external) ? call_params : call_params.map { |param| Types::Parameter.new(param.name, param.type) },
          return_type: function_return_type,
          receiver_type: function_receiver_type,
          receiver_mutable:,
          variadic: decl.respond_to?(:variadic) ? decl.variadic : false,
          external:,
        )

        FunctionBinding.new(
          name: decl.name,
          type: function_type,
          body_params:,
          body_return_type: body_return_type,
          ast: decl,
          external:,
          async: async_function,
          type_params: type_param_names.freeze,
          type_param_constraints: type_param_constraints.freeze,
          instances: {},
          type_arguments: [].freeze,
          owner: self,
          specialization_owner: nil,
          type_substitutions: {}.freeze,
          declared_receiver_type: declared_receiver_type,
        )
      end

      def resolve_type_param_constraints(type_params)
        type_params.each_with_object({}) do |type_param, constraints|
          ensure_non_reserved_type_binding_name!(
            type_param.name,
            kind_label: "type parameter",
            line: type_param.line,
            column: type_param.column,
            length: type_param.length,
          )
          next if type_param.constraints.empty?

          resolved_interfaces = []
          seen_interfaces = {}

          type_param.constraints.each do |constraint|
            case constraint.kind
            when :interface
              interface = resolve_interface_ref(constraint.interface_ref)
              raise_sema_error("duplicate interface constraint #{type_param.name} implements #{interface.name}") if seen_interfaces.key?(interface)

              seen_interfaces[interface] = true
              resolved_interfaces << interface
            else
              raise_sema_error("unsupported type parameter constraint #{constraint.kind}")
            end
          end

          constraints[type_param.name] = TypeParamConstraintBinding.new(
            interfaces: resolved_interfaces.freeze,
          )
        end
      end

      def check_top_level_values
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            case decl
            when AST::ConstDecl
              binding = @top_level_values.fetch(decl.name)
              validate_consuming_foreign_expression!(decl.value, scopes: [], root_allowed: false)
              validate_hoistable_foreign_expression!(decl.value, scopes: [], root_hoistable: false)
              actual_type = infer_expression(decl.value, scopes: [], expected_type: binding.type)
              ensure_assignable!(
                actual_type,
                binding.type,
                "cannot assign #{actual_type} to constant #{decl.name}: expected #{binding.type}",
                expression: decl.value,
                line: decl.line,
              )
            when AST::VarDecl
              binding = @top_level_values.fetch(decl.name)
              if decl.value
                validate_consuming_foreign_expression!(decl.value, scopes: [], root_allowed: false)
                validate_hoistable_foreign_expression!(decl.value, scopes: [], root_hoistable: false)
                actual_type = infer_expression(decl.value, scopes: [], expected_type: binding.type)
                ensure_assignable!(
                  actual_type,
                  binding.type,
                  "cannot assign #{actual_type} to module variable #{decl.name}: expected #{binding.type}",
                  expression: decl.value,
                  line: decl.line,
                )
                validate_static_storage_initializer!(decl.value, scopes: [])
              else
                zero_initializable_type?(binding.type)
              end
            end
          end
        end
      end

      def validate_static_storage_initializer!(expression, scopes:)
        case expression
        when AST::ErrorExpr
          return
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral,
             AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
          return
        when AST::Identifier
          if (binding = lookup_value(expression.name, scopes))
            return if binding.kind == :const

            raise_sema_error("module variable initializer cannot reference mutable value #{expression.name}")
          end

          function = @top_level_functions[expression.name]
          return if function && static_storage_function_value?(function)

          raise_sema_error("module variable initializer must be static-storage-safe")
        when AST::MemberAccess
          return if static_storage_member_initializer?(expression, scopes:)

          raise_sema_error("module variable initializer must be static-storage-safe")
        when AST::UnaryOp
          validate_static_storage_initializer!(expression.operand, scopes:)
        when AST::BinaryOp
          validate_static_storage_initializer!(expression.left, scopes:)
          validate_static_storage_initializer!(expression.right, scopes:)
        when AST::IfExpr
          validate_static_storage_initializer!(expression.condition, scopes:)
          validate_static_storage_initializer!(expression.then_expression, scopes:)
          validate_static_storage_initializer!(expression.else_expression, scopes:)
        when AST::UnsafeExpr
          validate_static_storage_initializer!(expression.expression, scopes:)
        when AST::Specialization
          if expression.callee.is_a?(AST::Identifier)
            return if expression.callee.name == "zero"
          end

          raise_sema_error("module variable initializer must be static-storage-safe")
        when AST::Call
          validate_static_storage_call_initializer!(expression, scopes:)
        else
          raise_sema_error("module variable initializer must be static-storage-safe")
        end
      end

      def static_storage_member_initializer?(expression, scopes:)
        if (type_expr = resolve_type_expression(expression.receiver))
          return true if resolve_type_member(type_expr, expression.member)
        end

        return false unless expression.receiver.is_a?(AST::Identifier)
        return false unless @imports.key?(expression.receiver.name)

        imported_module = @imports.fetch(expression.receiver.name)
        if imported_module.private_value?(expression.member) || imported_module.private_function?(expression.member) || imported_module.private_type?(expression.member)
          raise_sema_error("#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}")
        end

        if (binding = imported_module.values[expression.member])
          return true if binding.kind == :const

          raise_sema_error("module variable initializer cannot reference mutable value #{expression.receiver.name}.#{expression.member}")
        end

        function = imported_module.functions[expression.member]
        function && static_storage_function_value?(function)
      end

      def validate_static_storage_call_initializer!(expression, scopes:)
        expression.arguments.each do |argument|
          validate_static_storage_initializer!(argument.value, scopes:)
        end

        callee = expression.callee
        if callee.is_a?(AST::Identifier)
          if (type_expr = resolve_type_expression(callee))
            return if type_expr.is_a?(Types::Struct) || type_expr.is_a?(Types::StringView)
          end
        end

        if callee.is_a?(AST::MemberAccess)
          if (type_expr = resolve_type_expression(callee))
            return if type_expr.is_a?(Types::Struct) || type_expr.is_a?(Types::StringView)
          end
        end

        if callee.is_a?(AST::Specialization)
          if callee.callee.is_a?(AST::Identifier)
            case callee.callee.name
            when "array", "span", "zero", "cast", "reinterpret"
              return
            end
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return if specialized_type.is_a?(Types::Struct) || result_type?(specialized_type)
          end
        end

        raise_sema_error("module variable initializer must be static-storage-safe")
      end

      def static_storage_function_value?(binding)
        !binding.external && binding.type_params.empty?
      end

      def finalize_top_level_const_values
        @const_declarations.each_key { |name| evaluate_top_level_const_value(name) }
      end

      def evaluate_top_level_const_value(name)
        return @top_level_values.fetch(name).const_value if @evaluated_const_values.key?(name)

        raise_sema_error("cyclic constant value dependency involving #{name}") if @evaluating_const_values.include?(name)

        decl = @const_declarations.fetch(name)
        if decl.value.is_a?(AST::ErrorExpr)
          @evaluated_const_values[name] = true
          return nil
        end

        @evaluating_const_values << name
        value = evaluate_compile_time_const_value(decl.value)
        @evaluating_const_values.pop

        binding = @top_level_values.fetch(name)
        @top_level_values[name] = ValueBinding.new(
          id: binding.id,
          name: binding.name,
          storage_type: binding.storage_type,
          flow_type: binding.flow_type,
          mutable: binding.mutable,
          kind: binding.kind,
          const_value: value,
        )
        @evaluated_const_values[name] = true
        value
      end

      def evaluate_compile_time_const_value(expression, scopes: nil)
        CompileTime.evaluate(
          expression,
          resolve_identifier: lambda do |identifier_expression|
            if scopes
              binding = lookup_value(identifier_expression.name, scopes)
              return binding.const_value unless binding&.const_value.nil?
            end

            resolve_current_module_const_value(identifier_expression.name)
          end,
          resolve_member_access: lambda do |member_access_expression|
            if (receiver_type = resolve_type_expression(member_access_expression.receiver))
              next resolve_enum_member_const_value(receiver_type, member_access_expression.member)
            end

            next unless member_access_expression.receiver.is_a?(AST::Identifier)

            resolve_imported_module_const_value(member_access_expression.receiver.name, member_access_expression.member)
          end,
          resolve_type_ref: lambda do |type_ref|
            resolve_type_ref(type_ref)
          end,
        )
      end

      def evaluate_enum_member_const_value(expression, enum_type:, member_values:)
        CompileTime.evaluate(
          expression,
          resolve_identifier: lambda do |identifier_expression|
            resolve_current_module_const_value(identifier_expression.name)
          end,
          resolve_member_access: lambda do |member_access_expression|
            if (receiver_type = resolve_type_expression(member_access_expression.receiver))
              next resolve_enum_member_const_value(
                receiver_type,
                member_access_expression.member,
                local_enum_type: enum_type,
                local_member_values: member_values,
              )
            end

            next unless member_access_expression.receiver.is_a?(AST::Identifier)

            resolve_imported_module_const_value(member_access_expression.receiver.name, member_access_expression.member)
          end,
          resolve_type_ref: lambda do |type_ref|
            resolve_type_ref(type_ref)
          end,
        )
      end

      def check_top_level_static_asserts
        @ast.declarations.grep(AST::StaticAssert).each do |statement|
          check_static_assert(statement, scopes: [])
        end
      end

      def check_interface_conformances
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            next unless decl.is_a?(AST::StructDecl) || decl.is_a?(AST::OpaqueDecl)
            next if decl.implements.empty?

            receiver_type = @types.fetch(decl.name)
            resolved_interfaces = []
            seen = {}

            decl.implements.each do |interface_ref|
              interface = resolve_interface_ref(interface_ref)
              raise_sema_error("duplicate interface #{decl.name} implements #{interface.name}") if seen.key?(interface)

              seen[interface] = true
              resolved_interfaces << interface
              validate_interface_conformance!(receiver_type, interface)
            end

            @implemented_interfaces[interface_implementation_key(receiver_type)] = resolved_interfaces.freeze
          end
        end
      end

      def check_functions
        @top_level_functions.each_value do |binding|
          check_function(binding)
        end

        @methods.each_value do |method_map|
          method_map.each_value do |binding|
            check_function(binding)
          end
        end
      end

      def validate_interface_conformance!(receiver_type, interface)
        interface.methods.each_value do |interface_method|
          method = lookup_local_method_for_interface(receiver_type, interface_method.name)
          raise_sema_error("type #{receiver_type} implements interface #{interface.name} but is missing method #{interface_method.name}") unless method

          validate_interface_method_match!(receiver_type, interface, interface_method, method)
        end
      end

      def lookup_local_method_for_interface(receiver_type, name)
        dispatch_receiver_type = method_dispatch_receiver_type(receiver_type)

        method = @methods.fetch(receiver_type, {})[name]
        method ||= @methods.fetch(dispatch_receiver_type, {})[name] unless dispatch_receiver_type == receiver_type
        method
      end

      def validate_interface_method_match!(receiver_type, interface, interface_method, method)
        if method.ast.is_a?(AST::MethodDef) && method.ast.type_params.any?
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: interface methods cannot be implemented by generic methods")
        end

        if interface_method.kind == :static
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: method kind does not match") unless method.type.receiver_type.nil?
        else
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: method kind does not match") if method.type.receiver_type.nil?

          expected_mutable = interface_method.kind == :mutable
          actual_mutable = method.type.receiver_mutable
          if actual_mutable != expected_mutable
            raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: receiver mutability does not match")
          end
        end

        method_params = method.type.params.map(&:type)
        interface_params = interface_method.params.map(&:type)
        unless method_params == interface_params && method.type.return_type == interface_method.return_type && method.async == interface_method.async
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: signature does not match")
        end
      end

      # Per-function error collection used by check_collecting_errors.
      # Continues past individual function failures, accumulating SemaErrors.
      def check_functions_collecting(errors)
        @top_level_functions.each_value do |binding|
          next if @checked_function_bindings[binding.object_id]

          begin
            check_function(binding)
          rescue SemaError => e
            errors << e
          end
        end

        @methods.each_value do |method_map|
          method_map.each_value do |binding|
            next if @checked_function_bindings[binding.object_id]

            begin
              check_function(binding)
            rescue SemaError => e
              errors << e
            end
          end
        end
      end

      def check_function(binding)
        @local_completion_frames = @local_completion_frames.dup if @local_completion_frames.frozen?

        previous_type_substitutions = @current_type_substitutions
        previous_specialization_owner = @current_specialization_owner
        started_check = false
        return if binding.external || binding.type_params.any?
        return if @checked_function_bindings[binding.object_id]
        return if @checking_function_bindings[binding.object_id]

        @checking_function_bindings[binding.object_id] = true
        started_check = true
        @current_type_substitutions = binding.type_substitutions
        @current_specialization_owner = binding.specialization_owner
        with_scope(binding.body_params) do |scopes|
          start_local_completion_frame(binding, scopes)
          if binding.ast.is_a?(AST::ForeignFunctionDecl)
            record_callable_value_expression_site(binding.ast.mapping) unless binding.ast.mapping.is_a?(AST::Call)
            expression = foreign_mapping_expression(binding.ast)
            actual_type = with_foreign_mapping_context do
              infer_expression(expression, scopes:, expected_type: binding.type.return_type)
            end
            unless types_compatible?(actual_type, binding.type.return_type, expression:) || foreign_identity_projection_compatible?(actual_type, binding.type.return_type)
              raise_sema_error("foreign mapping #{binding.name} expects #{binding.type.return_type}, got #{actual_type}")
            end
          else
            validate_async_function_body!(binding.ast.body) if binding.async
            preassign_local_binding_ids(binding.ast.body)
            run_nullability_pre_pass(binding, scopes)
            if binding.async
              with_async_function do
                check_block(binding.ast.body, scopes:, return_type: binding.body_return_type)
              end
            else
              check_block(binding.ast.body, scopes:, return_type: binding.type.return_type)
            end
            check_definite_assignment(binding)
          end
        end
        @checked_function_bindings[binding.object_id] = true
      ensure
        return unless started_check

        finish_local_completion_frame(binding)
        @preassigned_local_binding_ids = {}
        @nullability_flow_result = nil
        @current_type_substitutions = previous_type_substitutions
        @current_specialization_owner = previous_specialization_owner
        @checking_function_bindings.delete(binding.object_id)
      end

      def check_block(statements, scopes:, return_type:, allow_return: true)
        with_return_context(return_type, allow_return:) do
          with_nested_scope(scopes) do |nested_scopes|
            statements.each_with_index do |statement, idx|
              begin
                record_local_completion_snapshot(
                  statement.respond_to?(:line) ? statement.line : nil,
                  statement.respond_to?(:column) ? statement.column : 0,
                  nested_scopes,
                )
                refinements = check_statement(statement, scopes: nested_scopes, return_type:, allow_return:)
                apply_continuation_refinements!(nested_scopes, refinements)
                # Apply CFG-derived nullability refinements before the next statement.
                if @nullability_flow_result && idx + 1 < statements.length
                  apply_nullability_continuation_refinements!(nested_scopes, statements[idx + 1])
                end
                record_local_completion_snapshot(statement_end_line(statement), 1_000_000, nested_scopes)
              rescue SemaError => e
                # Propagate as-is if position is already attached (set by an inner
                # check_block call on a nested statement) or if this statement type
                # carries no line information.
                raise e unless e.line.nil?

                stmt_line = statement.respond_to?(:line) ? statement.line : nil
                raise e if stmt_line.nil?

                raise SemaError.new(e.message, line: stmt_line)
              end
            end
          end
        end
      end

      def check_definite_assignment(binding)
        return unless binding.ast.respond_to?(:body)

        resolution = binding_resolution_snapshot
        graph = CFG::Builder.new(
          binding_resolution: CFG::BindingResolution.new(
            identifier_binding_ids: resolution.identifier_binding_ids,
            declaration_binding_ids: resolution.declaration_binding_ids,
            mutating_argument_identifier_ids: resolution.mutating_argument_identifier_ids,
          ),
          strict_binding_ids: true,
          local_decl_without_initializer_writes: true,
        ).build(binding.ast.body)

        local_declared_ids = Set.new
        graph.each_node do |node|
          node.writes_info.each do |write|
            origin = write[:origin]
            next unless %i[declaration for_binding match_binding].include?(origin)

            local_declared_ids << write[:binding_key]
          end
        end

        initially_assigned = binding.body_params.each_with_object(Set.new) do |param, set|
          set << param.id if param.id
        end
        # Any binding read but never defined in this function body is treated as
        # preassigned (for example module-level const/var bindings).
        initially_assigned.merge(graph.read_bindings - local_declared_ids)

        result = CFG::DefiniteAssignment.solve(graph, initially_assigned:)
        first_issue = result.read_before_assignment.min_by do |issue|
          [issue.line || Float::INFINITY, issue.column || Float::INFINITY, issue.node_id]
        end
        return unless first_issue

        name = @binding_name_by_id[first_issue.binding_key] || first_issue.binding_key
        raise SemaError.new(
          "read of '#{name}' before definite assignment",
          line: first_issue.line,
          column: first_issue.column,
          length: first_issue.length || name.to_s.length,
        )
      end

      # Runs a strict binding-ID nullability pass before statement checks.
      # Resolution is computed with a lexical pre-check walk so shadowed names
      # are disambiguated without relying on name fallback.
      def run_nullability_pre_pass(binding, scopes)
        return unless binding.ast.respond_to?(:body)

        @nullability_flow_result = nil
        resolution = precheck_binding_resolution(binding.ast.body, scopes)
        graph = CFG::Builder.new(
          binding_resolution: CFG::BindingResolution.new(
            identifier_binding_ids: resolution.identifier_binding_ids,
            declaration_binding_ids: resolution.declaration_binding_ids,
            mutating_argument_identifier_ids: resolution.mutating_argument_identifier_ids,
          ),
          strict_binding_ids: true,
        ).build(binding.ast.body)
        @nullability_flow_result = CFG::NullabilityFlow.solve(graph)
      end

      # After processing a statement, apply CFG-derived non-null refinements to
      # the scopes so the *next* statement benefits from cross-branch narrowing.
      def apply_nullability_continuation_refinements!(scopes, next_stmt)
        return unless @nullability_flow_result

        nonnull_binding_ids = @nullability_flow_result.nonnull_before(next_stmt)
        return if nonnull_binding_ids.empty?

        refinements = {}
        nonnull_binding_ids.each do |binding_id|
          next unless binding_id.is_a?(Integer)

          name = @binding_name_by_id[binding_id]
          next unless name

          binding = lookup_value(name, scopes)
          next unless binding&.id == binding_id
          next unless binding&.storage_type.is_a?(Types::Nullable)

          refinements[name] = binding.storage_type.base
        end
        apply_continuation_refinements!(scopes, refinements) unless refinements.empty?
      end

      def preassign_local_binding_ids(statements)
        @preassigned_local_binding_ids = {}
        preassign_local_binding_ids_in_statements(statements || [])
      end

      def preassign_local_binding_ids_in_statements(statements)
        statements.each do |statement|
          case statement
          when AST::ErrorBlockStmt
            preassign_local_binding_ids_in_expression(statement.header_expression) if statement.header_expression
            Array(statement.header_iterables).each { |iterable| preassign_local_binding_ids_in_expression(iterable) }
            Array(statement.header_bindings).each do |binding|
              @preassigned_local_binding_ids[binding.object_id] ||= allocate_binding_id
            end if statement.header_type == :for
            preassign_local_binding_ids_in_statements(statement.body || [])
          when AST::LocalDecl
            @preassigned_local_binding_ids[statement.object_id] ||= allocate_binding_id
            preassign_local_binding_ids_in_expression(statement.value) if statement.value
            if statement.else_binding && (statement.else_body || statement.recovered_else)
              @preassigned_local_binding_ids[statement.else_binding.object_id] ||= allocate_binding_id
            end
            preassign_local_binding_ids_in_statements(statement.else_body || [])
          when AST::Assignment
            preassign_local_binding_ids_in_expression(statement.target)
            preassign_local_binding_ids_in_expression(statement.value)
          when AST::IfStmt
            statement.branches.each do |branch|
              preassign_local_binding_ids_in_expression(branch.condition)
              preassign_local_binding_ids_in_statements(branch.body || [])
            end
            preassign_local_binding_ids_in_statements(statement.else_body || [])
          when AST::MatchStmt
            preassign_local_binding_ids_in_expression(statement.expression)
            statement.arms.each do |arm|
              preassign_local_binding_ids_in_expression(arm.pattern)
              @preassigned_local_binding_ids[arm.object_id] ||= allocate_binding_id if arm.binding_name
              preassign_local_binding_ids_in_statements(arm.body || [])
            end
          when AST::UnsafeStmt
            preassign_local_binding_ids_in_statements(statement.body || [])
          when AST::WhileStmt
            preassign_local_binding_ids_in_expression(statement.condition)
            preassign_local_binding_ids_in_statements(statement.body || [])
          when AST::ForStmt
            statement.bindings.each do |binding|
              @preassigned_local_binding_ids[binding.object_id] ||= allocate_binding_id
            end
            statement.iterables.each { |iterable| preassign_local_binding_ids_in_expression(iterable) }
            preassign_local_binding_ids_in_statements(statement.body || [])
          when AST::DeferStmt
            preassign_local_binding_ids_in_expression(statement.expression) if statement.expression
            preassign_local_binding_ids_in_statements(statement.body || []) if statement.body
          when AST::ReturnStmt
            preassign_local_binding_ids_in_expression(statement.value) if statement.value
          when AST::StaticAssert
            preassign_local_binding_ids_in_expression(statement.condition)
            preassign_local_binding_ids_in_expression(statement.message)
          when AST::ExpressionStmt
            preassign_local_binding_ids_in_expression(statement.expression)
          end
        end
      end

      def preassign_local_binding_ids_in_expression(expression)
        case expression
        when nil, AST::Identifier, AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral,
             AST::BooleanLiteral, AST::NullLiteral, AST::SizeofExpr, AST::AlignofExpr,
             AST::OffsetofExpr, AST::ErrorExpr
          nil
        when AST::MemberAccess
          preassign_local_binding_ids_in_expression(expression.receiver)
        when AST::IndexAccess
          preassign_local_binding_ids_in_expression(expression.receiver)
          preassign_local_binding_ids_in_expression(expression.index)
        when AST::Specialization, AST::Call
          preassign_local_binding_ids_in_expression(expression.callee)
          expression.arguments.each { |argument| preassign_local_binding_ids_in_expression(argument.value) }
        when AST::UnaryOp
          preassign_local_binding_ids_in_expression(expression.operand)
        when AST::BinaryOp
          preassign_local_binding_ids_in_expression(expression.left)
          preassign_local_binding_ids_in_expression(expression.right)
        when AST::RangeExpr
          preassign_local_binding_ids_in_expression(expression.start_expr)
          preassign_local_binding_ids_in_expression(expression.end_expr)
        when AST::IfExpr
          preassign_local_binding_ids_in_expression(expression.condition)
          preassign_local_binding_ids_in_expression(expression.then_expression)
          preassign_local_binding_ids_in_expression(expression.else_expression)
        when AST::MatchExpr
          preassign_local_binding_ids_in_expression(expression.expression)
          expression.arms.each do |arm|
            preassign_local_binding_ids_in_expression(arm.pattern)
            @preassigned_local_binding_ids[arm.object_id] ||= allocate_binding_id if arm.binding_name
            preassign_local_binding_ids_in_expression(arm.value)
          end
        when AST::UnsafeExpr
          preassign_local_binding_ids_in_expression(expression.expression)
        when AST::AwaitExpr
          preassign_local_binding_ids_in_expression(expression.expression)
        when AST::FormatString
          expression.parts.each do |part|
            preassign_local_binding_ids_in_expression(part.expression) if part.is_a?(AST::FormatExprPart)
          end
        when AST::ProcExpr
          preassign_local_binding_ids_in_statements(expression.body)
        end
      end

      def precheck_binding_resolution(statements, scopes)
        declaration_binding_ids = {}
        identifier_binding_ids = {}

        initial_scope = {}
        scopes.each do |scope|
          scope.each do |name, binding|
            initial_scope[name] = binding.id if binding.respond_to?(:id) && binding.id
          end
        end

        walk_statements_for_precheck_resolution(
          statements || [],
          [initial_scope],
          declaration_binding_ids,
          identifier_binding_ids,
        )

        BindingResolution.new(
          identifier_binding_ids: identifier_binding_ids,
          declaration_binding_ids: declaration_binding_ids,
          mutating_argument_identifier_ids: {},
          mutable_receiver_expression_ids: {},
          binding_types: {},
        )
      end

      def walk_statements_for_precheck_resolution(statements, scopes, declaration_ids, identifier_ids)
        block_scopes = scopes + [{}]
        statements.each do |statement|
          case statement
          when AST::ErrorBlockStmt
            if statement.header_type == :for
              Array(statement.header_iterables).each do |iterable|
                walk_expression_for_precheck_resolution(iterable, block_scopes, identifier_ids, declaration_ids)
              end
              for_scopes = block_scopes + [{}]
              Array(statement.header_bindings).each do |binding|
                binding_id = @preassigned_local_binding_ids.fetch(binding.object_id)
                for_scopes.last[binding.name] = binding_id
                declaration_ids[binding.object_id] = binding_id
              end
              walk_statements_for_precheck_resolution(statement.body || [], for_scopes, declaration_ids, identifier_ids)
            else
              walk_expression_for_precheck_resolution(statement.header_expression, block_scopes, identifier_ids, declaration_ids) if statement.header_expression
              walk_statements_for_precheck_resolution(statement.body || [], block_scopes, declaration_ids, identifier_ids)
            end
          when AST::LocalDecl
            walk_expression_for_precheck_resolution(statement.value, block_scopes, identifier_ids, declaration_ids) if statement.value
            if statement.else_binding && (statement.else_body || statement.recovered_else)
              else_scopes = block_scopes + [{}]
              binding_id = @preassigned_local_binding_ids.fetch(statement.else_binding.object_id)
              else_scopes.last[statement.else_binding.name] = binding_id
              declaration_ids[statement.else_binding.object_id] = binding_id
              walk_statements_for_precheck_resolution(statement.else_body || [], else_scopes, declaration_ids, identifier_ids)
            else
              walk_statements_for_precheck_resolution(statement.else_body || [], block_scopes, declaration_ids, identifier_ids)
            end
            binding_id = @preassigned_local_binding_ids.fetch(statement.object_id)
            unless let_else_discard_binding_syntax?(statement)
              block_scopes.last[statement.name] = binding_id
              declaration_ids[statement.object_id] = binding_id
            end
          when AST::Assignment
            walk_expression_for_precheck_resolution(statement.value, block_scopes, identifier_ids, declaration_ids)
            walk_assignment_target_reads_for_precheck_resolution(statement.target, statement.operator, block_scopes, identifier_ids, declaration_ids)
            if statement.target.is_a?(AST::Identifier)
              if (binding_id = resolve_name_in_precheck_scopes(statement.target.name, block_scopes))
                identifier_ids[statement.target.object_id] = binding_id
              end
            end
          when AST::IfStmt
            statement.branches.each do |branch|
              walk_expression_for_precheck_resolution(branch.condition, block_scopes, identifier_ids, declaration_ids)
              walk_statements_for_precheck_resolution(branch.body || [], block_scopes, declaration_ids, identifier_ids)
            end
            walk_statements_for_precheck_resolution(statement.else_body || [], block_scopes, declaration_ids, identifier_ids)
          when AST::MatchStmt
            walk_expression_for_precheck_resolution(statement.expression, block_scopes, identifier_ids, declaration_ids)
            statement.arms.each do |arm|
              arm_scopes = block_scopes + [{}]
              if arm.binding_name
                binding_id = @preassigned_local_binding_ids.fetch(arm.object_id)
                arm_scopes.last[arm.binding_name] = binding_id
                declaration_ids[arm.object_id] = binding_id
              end
              walk_statements_for_precheck_resolution(arm.body || [], arm_scopes, declaration_ids, identifier_ids)
            end
          when AST::UnsafeStmt, AST::WhileStmt
            walk_expression_for_precheck_resolution(statement.condition, block_scopes, identifier_ids, declaration_ids) if statement.is_a?(AST::WhileStmt)
            walk_statements_for_precheck_resolution(statement.body || [], block_scopes, declaration_ids, identifier_ids)
          when AST::ForStmt
            statement.iterables.each do |iterable|
              walk_expression_for_precheck_resolution(iterable, block_scopes, identifier_ids, declaration_ids)
            end
            for_scopes = block_scopes + [{}]
            statement.bindings.each do |binding|
              binding_id = @preassigned_local_binding_ids.fetch(binding.object_id)
              for_scopes.last[binding.name] = binding_id
              declaration_ids[binding.object_id] = binding_id
            end
            walk_statements_for_precheck_resolution(statement.body || [], for_scopes, declaration_ids, identifier_ids)
          when AST::DeferStmt
            walk_expression_for_precheck_resolution(statement.expression, block_scopes, identifier_ids, declaration_ids) if statement.expression
            walk_statements_for_precheck_resolution(statement.body || [], block_scopes, declaration_ids, identifier_ids) if statement.body
          when AST::ExpressionStmt
            walk_expression_for_precheck_resolution(statement.expression, block_scopes, identifier_ids, declaration_ids)
          when AST::ReturnStmt
            walk_expression_for_precheck_resolution(statement.value, block_scopes, identifier_ids, declaration_ids) if statement.value
          when AST::StaticAssert
            walk_expression_for_precheck_resolution(statement.condition, block_scopes, identifier_ids, declaration_ids)
          end
        end
      end

      def walk_expression_for_precheck_resolution(expression, scopes, identifier_ids, declaration_ids = nil)
        case expression
        when nil
          nil
        when AST::Identifier
          if (binding_id = resolve_name_in_precheck_scopes(expression.name, scopes))
            identifier_ids[expression.object_id] = binding_id
          end
        when AST::MemberAccess
          walk_expression_for_precheck_resolution(expression.receiver, scopes, identifier_ids, declaration_ids)
        when AST::IndexAccess
          walk_expression_for_precheck_resolution(expression.receiver, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.index, scopes, identifier_ids, declaration_ids)
        when AST::Specialization
          walk_expression_for_precheck_resolution(expression.callee, scopes, identifier_ids, declaration_ids)
        when AST::Call
          walk_expression_for_precheck_resolution(expression.callee, scopes, identifier_ids, declaration_ids)
          expression.arguments.each { |argument| walk_expression_for_precheck_resolution(argument.value, scopes, identifier_ids, declaration_ids) }
        when AST::UnaryOp
          walk_expression_for_precheck_resolution(expression.operand, scopes, identifier_ids, declaration_ids)
        when AST::BinaryOp
          walk_expression_for_precheck_resolution(expression.left, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.right, scopes, identifier_ids, declaration_ids)
        when AST::RangeExpr
          walk_expression_for_precheck_resolution(expression.start_expr, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.end_expr, scopes, identifier_ids, declaration_ids)
        when AST::IfExpr
          walk_expression_for_precheck_resolution(expression.condition, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.then_expression, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.else_expression, scopes, identifier_ids, declaration_ids)
        when AST::MatchExpr
          walk_expression_for_precheck_resolution(expression.expression, scopes, identifier_ids, declaration_ids)
          expression.arms.each do |arm|
            walk_expression_for_precheck_resolution(arm.pattern, scopes, identifier_ids, declaration_ids)
            arm_scopes = scopes
            if arm.binding_name
              binding_id = @preassigned_local_binding_ids.fetch(arm.object_id)
              arm_scopes = scopes + [{ arm.binding_name => binding_id }]
              declaration_ids[arm.object_id] = binding_id if declaration_ids
            end
            walk_expression_for_precheck_resolution(arm.value, arm_scopes, identifier_ids, declaration_ids)
          end
        when AST::UnsafeExpr
          walk_expression_for_precheck_resolution(expression.expression, scopes, identifier_ids, declaration_ids)
        when AST::AwaitExpr
          walk_expression_for_precheck_resolution(expression.expression, scopes, identifier_ids, declaration_ids)
        when AST::FormatString
          expression.parts.each do |part|
            next unless part.is_a?(AST::FormatExprPart)

            walk_expression_for_precheck_resolution(part.expression, scopes, identifier_ids, declaration_ids)
          end
        end
      end

      def walk_assignment_target_reads_for_precheck_resolution(target, operator, scopes, identifier_ids, declaration_ids = nil)
        if operator != "=" && target.is_a?(AST::Identifier)
          if (binding_id = resolve_name_in_precheck_scopes(target.name, scopes))
            identifier_ids[target.object_id] = binding_id
          end
        end

        case target
        when AST::Identifier
          nil
        when AST::MemberAccess
          walk_expression_for_precheck_resolution(target.receiver, scopes, identifier_ids, declaration_ids)
        when AST::IndexAccess
          walk_expression_for_precheck_resolution(target.receiver, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(target.index, scopes, identifier_ids, declaration_ids)
        else
          walk_expression_for_precheck_resolution(target, scopes, identifier_ids, declaration_ids)
        end
      end

      def resolve_name_in_precheck_scopes(name, scopes)
        scopes.reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        nil
      end

      def cfg_block_always_terminates?(statements)
        CFG::Termination.block_always_terminates?(statements, ignore_name: ->(_name) { false })
      end

      def check_statement(statement, scopes:, return_type:, allow_return: true)
        with_error_node(statement) do
          case statement
          when AST::ErrorBlockStmt
            if statement.header_type == :unsafe
              @unsafe_statement_lines << statement.line
              begin
                with_unsafe do
                  check_block(statement.body, scopes:, return_type:, allow_return:)
                end
              ensure
                @unsafe_statement_lines.pop
              end
            elsif statement.header_type == :if && statement.header_expression
              validate_consuming_foreign_expression!(statement.header_expression, scopes:, root_allowed: false)
              condition_type = infer_expression(statement.header_expression, scopes:, expected_type: @types.fetch("bool"))
              ensure_assignable!(condition_type, @types.fetch("bool"), "if condition must be bool, got #{condition_type}")
              true_refinements = flow_refinements(statement.header_expression, truthy: true, scopes:)
              check_block(statement.body, scopes: scopes_with_refinements(scopes, true_refinements), return_type:, allow_return:)
              return flow_refinements(statement.header_expression, truthy: false, scopes:) if cfg_block_always_terminates?(statement.body)
            elsif statement.header_type == :while && statement.header_expression
              validate_consuming_foreign_expression!(statement.header_expression, scopes:, root_allowed: false)
              condition_type = infer_expression(statement.header_expression, scopes:, expected_type: @types.fetch("bool"))
              ensure_assignable!(condition_type, @types.fetch("bool"), "while condition must be bool, got #{condition_type}")
              with_loop do
                body_scopes = scopes_with_refinements(scopes, flow_refinements(statement.header_expression, truthy: true, scopes:))
                check_block(statement.body, scopes: body_scopes, return_type:, allow_return:)
              end
            elsif statement.header_type == :for
              if statement.header_bindings && statement.header_iterables
                check_for_stmt(recovered_for_statement(statement), scopes:, return_type:, allow_return:)
              else
                with_loop do
                  check_block(statement.body, scopes:, return_type:, allow_return:)
                end
              end
            else
              check_block(statement.body, scopes:, return_type:, allow_return:)
            end
          when AST::LocalDecl
            check_local_decl(statement, scopes:, return_type:, allow_return:)
          when AST::ErrorStmt
            nil
          when AST::Assignment
            check_assignment(statement, scopes:)
          when AST::IfStmt
            false_refinements = {}
            branch_bodies_terminate = []
            statement.branches.each do |branch|
              branch_scopes = scopes_with_refinements(scopes, false_refinements)
              if branch.condition.is_a?(AST::ErrorExpr)
                check_block(branch.body, scopes: branch_scopes, return_type:, allow_return:)
                branch_bodies_terminate << cfg_block_always_terminates?(branch.body)
                next
              end

              validate_consuming_foreign_expression!(branch.condition, scopes: branch_scopes, root_allowed: false)
              condition_type = infer_expression(branch.condition, scopes: branch_scopes, expected_type: @types.fetch("bool"))
              ensure_assignable!(condition_type, @types.fetch("bool"), "if condition must be bool, got #{condition_type}")
              true_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: true, scopes: branch_scopes))
              check_block(branch.body, scopes: scopes_with_refinements(scopes, true_refinements), return_type:, allow_return:)
              branch_bodies_terminate << cfg_block_always_terminates?(branch.body)
              false_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: false, scopes: branch_scopes))
            end
            check_block(statement.else_body, scopes: scopes_with_refinements(scopes, false_refinements), return_type:, allow_return:) if statement.else_body
            return false_refinements if statement.else_body.nil? && branch_bodies_terminate.all?
          when AST::MatchStmt
            check_match_stmt(statement, scopes:, return_type:, allow_return:)
          when AST::UnsafeStmt
            @unsafe_statement_lines << statement.line
            begin
              with_unsafe do
                check_block(statement.body, scopes:, return_type:, allow_return:)
              end
            ensure
              @unsafe_statement_lines.pop
            end
          when AST::StaticAssert
            check_static_assert(statement, scopes:)
          when AST::ForStmt
            check_for_stmt(statement, scopes:, return_type:, allow_return:)
          when AST::WhileStmt
            if statement.condition.is_a?(AST::ErrorExpr)
              with_loop do
                check_block(statement.body, scopes:, return_type:, allow_return:)
              end
            else
              validate_consuming_foreign_expression!(statement.condition, scopes:, root_allowed: false)
              condition_type = infer_expression(statement.condition, scopes:, expected_type: @types.fetch("bool"))
              ensure_assignable!(condition_type, @types.fetch("bool"), "while condition must be bool, got #{condition_type}")
              with_loop do
                body_scopes = scopes_with_refinements(scopes, flow_refinements(statement.condition, truthy: true, scopes:))
                check_block(statement.body, scopes: body_scopes, return_type:, allow_return:)
              end
            end
          when AST::PassStmt
            nil
          when AST::BreakStmt
            raise_sema_error("break must be inside a loop") unless inside_loop?
          when AST::ContinueStmt
            raise_sema_error("continue must be inside a loop") unless inside_loop?
          when AST::ReturnStmt
            raise_sema_error("return is not allowed inside defer blocks") unless allow_return

            validate_consuming_foreign_expression!(statement.value, scopes:, root_allowed: false) if statement.value
            value_type = statement.value ? infer_expression(statement.value, scopes:, expected_type: return_type) : @types.fetch("void")
            ensure_assignable!(
              value_type,
              return_type,
              "return type mismatch: expected #{return_type}, got #{value_type}",
              expression: statement.value,
              contextual_int_to_float: contextual_int_to_float_target?(return_type),
              line: statement.line,
            )
          when AST::DeferStmt
            if statement.body
              with_loop_barrier do
                check_block(statement.body, scopes:, return_type:, allow_return: false)
              end
            else
              validate_consuming_foreign_expression!(statement.expression, scopes:, root_allowed: true)
              validate_hoistable_foreign_expression!(statement.expression, scopes:, root_hoistable: false)
              infer_expression(statement.expression, scopes:)
            end
          when AST::ExpressionStmt
            validate_consuming_foreign_expression!(statement.expression, scopes:, root_allowed: true)
            if statement.expression.is_a?(AST::UnaryOp) && statement.expression.operator == "?"
              infer_propagate_expression(statement.expression.operand, scopes:, allow_void_success: true)
            else
              infer_expression(statement.expression, scopes:)
            end
            return consuming_foreign_call_refinements(statement.expression, scopes:)
          else
            raise_sema_error("unsupported statement #{statement.class.name}")
          end

          nil
        end
      end

      def check_local_decl(statement, scopes:, return_type:, allow_return:)
        current_scope = current_actual_scope(scopes)
        discard_binding = let_else_discard_binding_syntax?(statement)
        raise_sema_error("duplicate local #{statement.name}") if !discard_binding && current_scope.key?(statement.name)
        ensure_non_reserved_primitive_name!(statement.name, kind_label: "local", line: statement.line, column: statement.column) unless discard_binding

        declared_type = statement.type ? resolve_type_ref(statement.type) : nil
        if statement.value
          validate_consuming_foreign_expression!(statement.value, scopes:, root_allowed: false)
          inferred_type = if statement.value.is_a?(AST::ProcExpr)
                            with_proc_expression do
                              infer_expression(statement.value, scopes:, expected_type: declared_type)
                            end
                          else
                            infer_expression(statement.value, scopes:, expected_type: declared_type)
                          end
        else
          raise_sema_error("local #{statement.name} without initializer requires an explicit type") unless declared_type

          begin
            zero_initializable_type?(declared_type)
          rescue SemaError
            raise_sema_error("local #{statement.name} without initializer requires a zero-initializable type, got #{declared_type}")
          end

          inferred_type = declared_type
        end

        if statement.else_body || statement.recovered_else
          raise_sema_error("let-else is only allowed on let declarations") unless statement.kind == :let
          success_type = let_else_success_type(inferred_type)
          error_type = let_else_error_type(inferred_type)

          if statement.recovered_else
            success_type ||= declared_type || @error_type
            error_type ||= @error_type if statement.else_binding
          else
            raise_sema_error("let-else initializer for #{statement.name} must be nullable, Option[T], or Result[T, E], got #{inferred_type}") unless success_type
          end

          if discard_binding && declared_type
            raise_sema_error("let-else discard binding _ cannot have a type annotation")
          end

          if statement.else_binding && !error_type
            raise_sema_error("let-else error binding for #{statement.name} requires Result[T, E], got #{inferred_type}")
          end

          if declared_type && let_else_source_type?(declared_type)
            raise_sema_error("let-else type annotation for #{statement.name} must be the success type, got #{declared_type}")
          end

          if declared_type
            validate_local_ref_type!(declared_type, statement.name)
            validate_local_proc_type!(declared_type, statement.name, initializer: statement.value)
            ensure_assignable!(
              success_type,
              declared_type,
              "cannot assign #{success_type} to #{statement.name}: expected #{declared_type}",
              expression: statement.value,
              scopes:,
              contextual_int_to_float: contextual_int_to_float_target?(declared_type),
              line: statement.line,
              column: statement.column,
            )
            final_type = declared_type
          else
            raise_sema_error("cannot bind void result to #{statement.name}") if success_type.void? && !discard_binding

            final_type = success_type
          end

          unless discard_binding
            validate_local_ref_type!(final_type, statement.name)
            validate_local_proc_type!(final_type, statement.name, initializer: statement.value)
          end

          else_scopes = scopes
          if statement.else_binding
            ensure_non_reserved_primitive_name!(statement.else_binding.name, kind_label: "let-else error binding", line: statement.else_binding.line, column: statement.else_binding.column)
            else_binding = value_binding(
              name: statement.else_binding.name,
              type: error_type,
              mutable: false,
              kind: :let,
              id: @preassigned_local_binding_ids.fetch(statement.else_binding.object_id),
            )
            record_declaration_binding(statement.else_binding, else_binding)
            else_scopes = scopes + [{ statement.else_binding.name => else_binding }]
          end

          check_block(statement.else_body, scopes: else_scopes, return_type:, allow_return:) if statement.else_body
          if statement.else_body && !statement.recovered_else
            raise_sema_error("else block for #{statement.name} must exit control flow") unless cfg_block_always_terminates?(statement.else_body)
          end

          storage_type = inferred_type
          const_value = nil
        else
          if declared_type
            validate_local_ref_type!(declared_type, statement.name)
            validate_local_proc_type!(declared_type, statement.name, initializer: statement.value)
            ensure_assignable!(
              inferred_type,
              declared_type,
              "cannot assign #{inferred_type} to #{statement.name}: expected #{declared_type}",
              expression: statement.value,
              scopes:,
              contextual_int_to_float: contextual_int_to_float_target?(declared_type),
              line: statement.line,
              column: statement.column,
            )
            final_type = declared_type
          else
            raise_sema_error("cannot infer type for #{statement.name} from null") if inferred_type.is_a?(Types::Null)
            raise_sema_error("cannot bind void result to #{statement.name}") if inferred_type.void?

            final_type = inferred_type
          end

          validate_local_ref_type!(final_type, statement.name)
          validate_local_proc_type!(final_type, statement.name, initializer: statement.value)

          storage_type = final_type
          const_value = statement.kind == :let && statement.value ? evaluate_compile_time_const_value(statement.value, scopes:) : nil
        end

        unless discard_binding
          current_scope[statement.name] = value_binding(
            name: statement.name,
            type: storage_type,
            mutable: statement.kind == :var,
            kind: statement.kind,
            flow_type: final_type,
            const_value:,
            id: @preassigned_local_binding_ids[statement.object_id],
          )
          record_declaration_binding(statement, current_scope[statement.name])
        end
      end

      def check_assignment(statement, scopes:)
        if statement.operator == "=" &&
           statement.target.is_a?(AST::IndexAccess) &&
           statement.target.index.is_a?(AST::RangeExpr)
          return check_range_index_assignment(statement, scopes:)
        end

        target_type = infer_lvalue(statement.target, scopes:)

        validate_consuming_foreign_expression!(statement.value, scopes:, root_allowed: false)
        value_type = infer_expression(statement.value, scopes:, expected_type: target_type)

        case statement.operator
        when "="
          ensure_assignable!(
            value_type,
            target_type,
            "cannot assign #{value_type} to #{target_type}",
            expression: statement.value,
            external_numeric: external_numeric_assignment_target?(statement.target, scopes:),
            contextual_int_to_float: contextual_int_to_float_target?(target_type),
            line: statement.line,
          )
        when "+=", "-=", "*=", "/="
          raise_sema_error("operator #{statement.operator} requires matching numeric types, got #{target_type} and #{value_type}") unless target_type.numeric? && value_type.numeric?

          ensure_assignable!(
            value_type,
            target_type,
            "operator #{statement.operator} requires matching numeric types, got #{target_type} and #{value_type}",
            expression: statement.value,
            contextual_int_to_float: contextual_int_to_float_target?(target_type),
            line: statement.line,
          )
        when "%="
          unless common_integer_type(target_type, value_type) == target_type
            raise_sema_error("operator #{statement.operator} requires compatible integer types, got #{target_type} and #{value_type}")
          end
        when "&=", "|=", "^="
          unless target_type == value_type && bitwise_type?(target_type)
            raise_sema_error("operator #{statement.operator} requires matching integer or flags types, got #{target_type} and #{value_type}")
          end
        when "<<=", ">>="
          unless target_type.is_a?(Types::Primitive) && target_type.integer? && value_type.is_a?(Types::Primitive) && value_type.integer?
            raise_sema_error("operator #{statement.operator} requires integer operands, got #{target_type} and #{value_type}")
          end
        else
          raise_sema_error("unsupported assignment operator #{statement.operator}")
        end
      end

      def check_range_index_assignment(statement, scopes:)
        target = statement.target
        range = target.index

        raise_sema_error("range index assignment requires an expression list on the right-hand side") unless statement.value.is_a?(AST::ExpressionList)
        raise_sema_error("range index assignment requires integer literal bounds") unless range.start_expr.is_a?(AST::IntegerLiteral) && range.end_expr.is_a?(AST::IntegerLiteral)

        start_val = range.start_expr.value
        end_val = range.end_expr.value
        raise_sema_error("range start must be less than end in range index assignment") unless start_val < end_val

        count = end_val - start_val
        raise_sema_error("range index assignment: range [#{start_val}..#{end_val}) spans #{count} elements but tuple has #{statement.value.elements.length}") unless statement.value.elements.length == count

        receiver_type = infer_lvalue_receiver(
          target.receiver,
          scopes:,
          allow_pointer_identifier: true,
          require_mutable_pointer: true,
          allow_span_param_identifier: true,
        )
        element_type = infer_index_result_type(receiver_type, @types.fetch("ptr_uint"))

        statement.value.elements.each_with_index do |elem, i|
          validate_consuming_foreign_expression!(elem, scopes:, root_allowed: false)
          elem_type = infer_expression(elem, scopes:, expected_type: element_type)
          ensure_assignable!(
            elem_type,
            element_type,
            "range index assignment element #{i}: cannot assign #{elem_type} to #{element_type}",
            expression: elem,
            contextual_int_to_float: contextual_int_to_float_target?(element_type),
            line: statement.line,
          )
        end
      end

      def check_match_stmt(statement, scopes:, return_type:, allow_return:)
        validate_consuming_foreign_expression!(statement.expression, scopes:, root_allowed: false)
        scrutinee_type = infer_expression(statement.expression, scopes:)
        if error_type?(scrutinee_type)
          check_recovered_match_stmt(statement, scopes:, return_type:, allow_return:)
        elsif scrutinee_type.is_a?(Types::Enum)
          check_enum_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        elsif scrutinee_type.is_a?(Types::Variant)
          check_variant_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        elsif integer_type?(scrutinee_type)
          check_integer_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        else
          raise_sema_error("match requires an enum, variant, or integer scrutinee, got #{scrutinee_type}")
        end
      end

      def check_enum_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        covered_members = {}
        wildcard_seen = false
        statement.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            check_recovered_match_arm_body(arm, scopes:, return_type:, allow_return:)
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen
            wildcard_seen = true
            check_block(arm.body, scopes:, return_type:, allow_return:)
            next
          end
          validate_consuming_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
          validate_hoistable_foreign_expression!(arm.pattern, scopes:, root_hoistable: false)
          pattern_type = infer_expression(arm.pattern, scopes:, expected_type: scrutinee_type)
          ensure_assignable!(pattern_type, scrutinee_type, "match arm expects #{scrutinee_type}, got #{pattern_type}")

          member_name = match_member_name(arm.pattern, scrutinee_type)
          raise_sema_error("match arm must be an enum member of #{scrutinee_type}") unless member_name
          raise_sema_error("duplicate match arm #{scrutinee_type}.#{member_name}") if covered_members.key?(member_name)

          covered_members[member_name] = true
          check_block(arm.body, scopes:, return_type:, allow_return:)
        end

        return if wildcard_seen

        missing_members = scrutinee_type.members - covered_members.keys
        return if missing_members.empty?

        raise_sema_error("match on #{scrutinee_type} is missing cases: #{missing_members.join(', ')}")
      end

      def check_integer_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        has_wildcard = statement.arms.any? { |arm| wildcard_pattern?(arm.pattern) }
        raise_sema_error("match on integer type #{scrutinee_type} requires a wildcard arm (_:)") unless has_wildcard

        covered_values = {}
        wildcard_seen = false
        statement.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            check_recovered_match_arm_body(arm, scopes:, return_type:, allow_return:)
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen
            wildcard_seen = true
            check_block(arm.body, scopes:, return_type:, allow_return:)
            next
          end
          unless arm.pattern.is_a?(AST::IntegerLiteral)
            raise_sema_error("match arm for integer scrutinee must be an integer literal or _, got #{arm.pattern.class.name}")
          end
          value = arm.pattern.value
          raise_sema_error("duplicate match arm value #{value}") if covered_values.key?(value)
          covered_values[value] = true
          check_block(arm.body, scopes:, return_type:, allow_return:)
        end
      end

      def wildcard_pattern?(expression)
        expression.is_a?(AST::Identifier) && expression.name == "_"
      end

      def let_else_discard_binding_syntax?(statement)
        statement.is_a?(AST::LocalDecl) && (statement.else_body || statement.recovered_else) && statement.name == "_"
      end

      def let_else_source_type?(type)
        type.is_a?(Types::Nullable) || result_let_else_type?(type) || option_let_else_type?(type)
      end

      def let_else_success_type(type)
        return @error_type if error_type?(type)
        return type.base if type.is_a?(Types::Nullable)
        return type.arm("some").fetch("value") if option_let_else_type?(type)
        return unless result_let_else_type?(type)

        type.arm("success").fetch("value")
      end

      def let_else_error_type(type)
        return @error_type if error_type?(type)
        return unless result_let_else_type?(type)

        type.arm("failure").fetch("error")
      end

      def option_let_else_type?(type)
        return false unless type.is_a?(Types::Variant)
        return false unless type.module_name.nil? && type.name == "Option"

        some_fields = type.arm("some")
        none_fields = type.arm("none")
        some_fields && some_fields.length == 1 && some_fields.key?("value") &&
          none_fields && none_fields.empty?
      end

      def result_let_else_type?(type)
        return false unless type.is_a?(Types::Variant)
        return false unless type.module_name.nil? && type.name == "Result"

        success_fields = type.arm("success")
        failure_fields = type.arm("failure")
        success_fields && success_fields.length == 1 && success_fields.key?("value") &&
          failure_fields && failure_fields.length == 1 && failure_fields.key?("error")
      end

      def check_variant_match_stmt(statement, scrutinee_type, scopes:, return_type:, allow_return:)
        covered_arms = {}
        wildcard_seen = false
        statement.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            check_recovered_match_arm_body(arm, scopes:, return_type:, allow_return:)
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen
            wildcard_seen = true
            check_block(arm.body, scopes:, return_type:, allow_return:)
            next
          end
          validate_consuming_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
          validate_hoistable_foreign_expression!(arm.pattern, scopes:, root_hoistable: false)

          arm_name = variant_match_arm_name(arm.pattern, scrutinee_type)
          raise_sema_error("match arm must be a variant arm of #{scrutinee_type}") unless arm_name
          raise_sema_error("duplicate match arm #{scrutinee_type}.#{arm_name}") if covered_arms.key?(arm_name)

          covered_arms[arm_name] = true

          arm_scopes = scopes.dup
          if arm.binding_name
            ensure_non_reserved_primitive_name!(arm.binding_name, kind_label: "match binding", line: arm.binding_line, column: arm.binding_column)
            fields = scrutinee_type.arm(arm_name)
            if fields.nil? || fields.empty?
              raise_sema_error("variant arm #{scrutinee_type}.#{arm_name} has no payload; 'as' binding is not allowed")
            end

            payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
            arm_scopes = [{
              arm.binding_name => value_binding(
                name: arm.binding_name,
                type: payload_type,
                mutable: false,
                kind: :local,
                id: @preassigned_local_binding_ids[arm.object_id],
              )
            }] + arm_scopes
            record_declaration_binding(arm, arm_scopes.first[arm.binding_name])
          end
          check_block(arm.body, scopes: arm_scopes, return_type:, allow_return:)
        end

        return if wildcard_seen

        missing_arms = scrutinee_type.arm_names - covered_arms.keys
        return if missing_arms.empty?

        raise_sema_error("match on #{scrutinee_type} is missing cases: #{missing_arms.join(', ')}")
      end

      def check_recovered_match_stmt(statement, scopes:, return_type:, allow_return:)
        statement.arms.each do |arm|
          check_recovered_match_arm_body(arm, scopes:, return_type:, allow_return:)
        end
      end

      def check_recovered_match_arm_body(arm, scopes:, return_type:, allow_return:)
        arm_scopes = scopes.dup
        if arm.binding_name
          ensure_non_reserved_primitive_name!(arm.binding_name, kind_label: "match binding", line: arm.binding_line, column: arm.binding_column)
          binding = value_binding(
            name: arm.binding_name,
            type: @error_type,
            mutable: false,
            kind: :local,
            id: @preassigned_local_binding_ids.fetch(arm.object_id),
          )
          arm_scopes = [{ arm.binding_name => binding }] + arm_scopes
          record_declaration_binding(arm, binding)
        end
        check_block(arm.body, scopes: arm_scopes, return_type:, allow_return:)
      end

      def variant_match_arm_name(pattern, scrutinee_type)
        # Pattern must be `TypeName.arm_name` or `module.TypeName.arm_name`
        return nil unless pattern.is_a?(AST::MemberAccess)

        member = pattern.member
        return nil unless scrutinee_type.arm_names.include?(member)

        # Verify the receiver resolves to the scrutinee variant type
        receiver_type = resolve_type_expression(pattern.receiver)
        return member if receiver_type == scrutinee_type

        if scrutinee_type.is_a?(Types::VariantInstance) && receiver_type.is_a?(Types::GenericVariantDefinition)
          return member if receiver_type == scrutinee_type.definition
        end

        return nil unless scrutinee_type.is_a?(Types::VariantInstance) && receiver_type.is_a?(Types::Variant)
        return nil unless receiver_type.name == scrutinee_type.name && receiver_type.module_name == scrutinee_type.module_name

        member
      end

      def check_for_stmt(statement, scopes:, return_type:, allow_return:)
        statement.iterables.each do |iterable|
          validate_consuming_foreign_expression!(iterable, scopes:, root_allowed: false)
        end

        raise_sema_error("for loop binder count must match iterable count") unless statement.bindings.length == statement.iterables.length

        binding_infos = if statement.parallel?
                          check_parallel_for_bindings(statement, scopes:)
                        else
                          iterable_type = nil
                          loop_type = if range_expr?(statement.iterable)
                                        check_range_expr_loop(statement.iterable, scopes:)
                                      else
                                        iterable_type = infer_expression(statement.iterable, scopes:)
                                        collection_loop_type(iterable_type) || iterator_loop_type(iterable_type)
                                      end

                          raise_sema_error("for loop expects start..stop, array[T, N], span[T], or an iterable with iter()/next()") unless loop_type

                          binding_type = if iterable_type
                                           collection_loop_binding_type(iterable_type, loop_type) || loop_type
                                         else
                                           loop_type
                                         end
                          [{ binding: statement.binding, type: binding_type }]
                        end

        with_nested_scope(scopes) do |loop_scopes|
          binding_infos.each do |entry|
            binding = entry[:binding]
            ensure_non_reserved_primitive_name!(binding.name, kind_label: "for binding", line: binding.line, column: binding.column)
            current_actual_scope(loop_scopes)[binding.name] = value_binding(
              name: binding.name,
              type: entry[:type],
              mutable: false,
              kind: :let,
              id: @preassigned_local_binding_ids[binding.object_id],
            )
            record_declaration_binding(binding, current_actual_scope(loop_scopes)[binding.name])
          end
          with_loop do
            check_block(statement.body, scopes: loop_scopes, return_type:, allow_return:)
          end
        end
      end

      def check_parallel_for_bindings(statement, scopes:)
        raise_sema_error("parallel for loops currently support arrays and spans only") if statement.iterables.any? { |iterable| range_expr?(iterable) }

        iterable_types = statement.iterables.map { |iterable| infer_expression(iterable, scopes:) }
        binding_infos = iterable_types.each_with_index.map do |iterable_type, index|
          loop_type = collection_loop_type(iterable_type)
          raise_sema_error("parallel for loops expect arrays or spans for each iterable") unless loop_type

          binding_type = collection_loop_binding_type(iterable_type, loop_type) || loop_type
          { binding: statement.bindings[index], iterable_type:, type: binding_type }
        end

        ensure_parallel_for_static_lengths_match!(binding_infos.map { |entry| entry[:iterable_type] })
        binding_infos
      end

      def ensure_parallel_for_static_lengths_match!(iterable_types)
        lengths = iterable_types.filter_map { |iterable_type| array_type?(iterable_type) ? array_length(iterable_type) : nil }
        return if lengths.empty? || lengths.all? { |length| length == lengths.first }

        raise_sema_error("parallel for iterables must have matching lengths")
      end


      def check_static_assert(statement, scopes:)
        validate_consuming_foreign_expression!(statement.condition, scopes:, root_allowed: false)
        validate_consuming_foreign_expression!(statement.message, scopes:, root_allowed: false)
        validate_hoistable_foreign_expression!(statement.condition, scopes:, root_hoistable: false)
        validate_hoistable_foreign_expression!(statement.message, scopes:, root_hoistable: false)
        condition_type = infer_expression(statement.condition, scopes:, expected_type: @types.fetch("bool"))
        ensure_assignable!(condition_type, @types.fetch("bool"), "static_assert condition must be bool, got #{condition_type}")
        condition_value = evaluate_compile_time_const_value(statement.condition, scopes:)
        raise_sema_error("static_assert condition must be a compile-time bool constant") unless condition_value == true || condition_value == false
        raise_sema_error("static_assert message must be a string literal") unless statement.message.is_a?(AST::StringLiteral)

        message_type = infer_expression(statement.message, scopes:, expected_type: @types.fetch("str"))
        return if string_like_type?(message_type)

        raise_sema_error("static_assert message must be str or cstr, got #{message_type}")
      end

      def check_range_expr_loop(expression, scopes:)
        start_type = infer_expression(expression.start_expr, scopes:)
        stop_type = infer_expression(expression.end_expr, scopes:)

        unless integer_type?(start_type) && integer_type?(stop_type)
          raise_sema_error("range bounds must be integer types, got #{start_type} and #{stop_type}")
        end

        if start_type != stop_type
          if expression.start_expr.is_a?(AST::IntegerLiteral)
            start_type = infer_expression(expression.start_expr, scopes:, expected_type: stop_type)
          elsif expression.end_expr.is_a?(AST::IntegerLiteral)
            stop_type = infer_expression(expression.end_expr, scopes:, expected_type: start_type)
          end
        end

        raise_sema_error("range bounds must use matching integer types, got #{start_type} and #{stop_type}") unless start_type == stop_type

        start_type
      end

      def infer_lvalue(expression, scopes:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, scopes)
          raise_sema_error("unknown name #{expression.name}") unless binding
          record_identifier_binding(expression, binding)
          raise_sema_error("cannot assign to immutable #{expression.name}") unless binding.mutable

          binding.storage_type
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:, allow_ref_identifier: true, allow_pointer_identifier: true, allow_span_param_identifier: true)
          receiver_type = project_field_receiver_type(receiver_type, require_mutable_pointer: true)
          unless aggregate_type?(receiver_type)
            raise_sema_error("cannot assign to member #{expression.member} of #{receiver_type}")
          end

          field_type = receiver_type.field(expression.member)
          raise_sema_error("unknown field #{receiver_type}.#{expression.member}") unless field_type

          field_type
        when AST::IndexAccess
          receiver_type = infer_lvalue_receiver(
            expression.receiver,
            scopes:,
            allow_pointer_identifier: true,
            require_mutable_pointer: true,
            allow_span_param_identifier: true,
          )

          index_type = infer_expression(expression.index, scopes:)
          infer_index_result_type(receiver_type, index_type)
        when AST::Call
          if read_call?(expression)
            validate_read_call_arguments!(expression.arguments)
            return infer_reference_value_type(expression.arguments.first.value, scopes:)
          end

          raise_sema_error("invalid assignment target")
        when AST::BinaryOp
          raise_sema_error("invalid assignment target")
        else
          raise_sema_error("invalid assignment target")
        end
      end

      def infer_lvalue_receiver(expression, scopes:, allow_ref_identifier: false, allow_pointer_identifier: false, require_mutable_pointer: false, allow_span_param_identifier: false)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, scopes)
          raise_sema_error("unknown name #{expression.name}") unless binding
          record_identifier_binding(expression, binding)

          return referenced_type(binding.type) if allow_ref_identifier && ref_type?(binding.type)
          if allow_pointer_identifier && pointer_type?(binding.type)
            require_unsafe!("raw pointer dereference requires unsafe")
            raise_sema_error("cannot assign through read-only raw pointer #{binding.type}") if require_mutable_pointer && const_pointer_type?(binding.type)

            return binding.type
          end
          if allow_span_param_identifier && binding.kind == :param && span_type?(binding.type)
            return binding.type
          end

          raise_sema_error("cannot assign through immutable #{expression.name}") unless binding.mutable

          binding.type
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(
            expression.receiver,
            scopes:,
            allow_ref_identifier:,
            allow_pointer_identifier:,
            require_mutable_pointer:,
            allow_span_param_identifier:,
          )
          receiver_type = project_field_receiver_type(receiver_type, require_mutable_pointer:)
          unless aggregate_type?(receiver_type)
            raise_sema_error("cannot access member #{expression.member} of #{receiver_type}")
          end

          field_type = receiver_type.field(expression.member)
          raise_sema_error("unknown field #{receiver_type}.#{expression.member}") unless field_type

          field_type
        when AST::IndexAccess
          receiver_type = infer_lvalue_receiver(
            expression.receiver,
            scopes:,
            allow_ref_identifier:,
            allow_pointer_identifier:,
            require_mutable_pointer:,
            allow_span_param_identifier:,
          )
          index_type = infer_expression(expression.index, scopes:)
          infer_index_result_type(receiver_type, index_type)
        when AST::Call
          if read_call?(expression)
            validate_read_call_arguments!(expression.arguments)
            return infer_reference_value_type(expression.arguments.first.value, scopes:)
          end

          raise_sema_error("invalid assignment target")
        when AST::BinaryOp
          require_unsafe!("raw pointer arithmetic as lvalue receiver requires unsafe")
          type = infer_expression(expression, scopes:)
          raise_sema_error("binary op lvalue receiver must be a pointer") unless pointer_type?(type)
          raise_sema_error("cannot assign through read-only raw pointer #{type}") if require_mutable_pointer && const_pointer_type?(type)

          type
        else
          raise_sema_error("invalid assignment target")
        end
      end

      def external_numeric_assignment_target?(expression, scopes:)
        case expression
        when AST::MemberAccess
          receiver_type = infer_field_receiver_type(expression.receiver, scopes:, require_mutable_pointer: true)
          receiver_type.respond_to?(:external) && receiver_type.external
        else
          false
        end
      end

      def infer_expression(expression, scopes:, expected_type: nil)
        with_error_node(expression) do
          case expression
          when AST::ErrorExpr
            expected_type || @error_type
          when AST::IntegerLiteral
            infer_integer_literal(expected_type)
          when AST::FloatLiteral
            infer_float_literal(expression, expected_type)
          when AST::SizeofExpr
            infer_layout_query_type(expression.type, context: "size_of")
            @types.fetch("ptr_uint")
          when AST::AlignofExpr
            infer_layout_query_type(expression.type, context: "align_of")
            @types.fetch("ptr_uint")
          when AST::OffsetofExpr
            infer_offsetof_type(expression.type, expression.field)
            @types.fetch("ptr_uint")
          when AST::StringLiteral
            @types.fetch(expression.cstring ? "cstr" : "str")
          when AST::FormatString
            check_format_string_literal(expression, scopes:)
            @types.fetch("str")
          when AST::BooleanLiteral
            @types.fetch("bool")
          when AST::NullLiteral
            infer_null_literal(expression)
          when AST::Identifier
            infer_identifier(expression, scopes:, expected_type:)
          when AST::MemberAccess
            infer_member_access(expression, scopes:, expected_type:)
          when AST::IndexAccess
            infer_index_access(expression, scopes:)
          when AST::UnaryOp
            infer_unary(expression, scopes:, expected_type:)
          when AST::BinaryOp
            infer_binary(expression, scopes:, expected_type:)
          when AST::IfExpr
            infer_if_expression(expression, scopes:, expected_type:)
          when AST::MatchExpr
            infer_match_expression(expression, scopes:, expected_type:)
          when AST::UnsafeExpr
            infer_unsafe_expression(expression, scopes:, expected_type:)
          when AST::ProcExpr
            infer_proc_expression(expression, scopes:, expected_type:)
          when AST::AwaitExpr
            infer_await_expression(expression, scopes:)
          when AST::Call
            infer_call(expression, scopes:, expected_type:)
          when AST::Specialization
            if expression.callee.is_a?(AST::Identifier)
              if expression.callee.name == "zero"
                callable_kind, callable, = resolve_callable(expression, scopes:)
                return check_zero_call(callable, [], expected_type:) if callable_kind == :zero
              end

              if expression.callee.name == "default"
                resolution = resolve_default_specialization(expression)
                return resolution.target_type
              end
            end

            if (callable_resolution = resolve_specialized_callable_binding(expression, scopes:))
              callable_kind, function_binding, = callable_resolution
              raise_sema_error("specialized method #{describe_expression(expression)} must be called") if callable_kind == :method

              return function_binding.type
            end

            raise_sema_error("specialized name #{describe_expression(expression)} must be called")
          when AST::RangeExpr
            raise_sema_error("range expression can only be used as a for-loop iterable or range index target")
          when AST::ExpressionList
            raise_sema_error("expression list can only be used as the right-hand side of a range index assignment")
          else
            raise_sema_error("unsupported expression #{expression.class.name}")
          end
        end
      end

      def infer_unsafe_expression(expression, scopes:, expected_type: nil)
        @unsafe_statement_lines << expression.line
        begin
          with_unsafe do
            infer_expression(expression.expression, scopes:, expected_type:)
          end
        ensure
          @unsafe_statement_lines.pop
        end
      end

      def infer_integer_literal(expected_type)
        if expected_type.is_a?(Types::Primitive) && expected_type.integer?
          expected_type
        else
          @types.fetch("int")
        end
      end

      def infer_float_literal(expression, expected_type)
        if expression.lexeme.end_with?("float")
          @types.fetch("float")
        elsif expression.lexeme.end_with?("double")
          @types.fetch("double")
        elsif expected_type.is_a?(Types::Primitive) && expected_type.float?
          expected_type
        else
          @types.fetch("double")
        end
      end

      def infer_identifier(expression, scopes:, expected_type: nil)
        binding = lookup_value(expression.name, scopes)
        if binding
          record_identifier_binding(expression, binding)
          return binding.type
        end

        if @top_level_functions.key?(expression.name)
          raise_sema_error("generic function #{expression.name} must be called") if @top_level_functions.fetch(expression.name).type_params.any?

          function_type = function_type_for_name(expression.name)
          if expected_type
            record_callable_value_identifier_site(expression)
            return function_type
          end

          raise_sema_error("function #{expression.name} must be called")
        end

        raise_sema_error("module #{expression.name} cannot be used as a value") if @imports.key?(expression.name)
        raise_sema_error("type #{expression.name} cannot be used as a value") if @types.key?(expression.name)

        raise_sema_error("unknown name #{expression.name}")
      end

      def infer_member_access(expression, scopes:, expected_type: nil)
        type = resolve_type_expression(expression.receiver)
        if type
          return @error_type if error_type?(type)

          member_type = resolve_type_member(type, expression.member)
          return member_type if member_type

          if type.is_a?(Types::Variant) && type.arm_names.include?(expression.member)
            raise_sema_error("variant arm #{type}.#{expression.member} has payload; construct it with #{type}.#{expression.member}(field: value, ...)")
          end

          if (method = lookup_method(type, expression.member))
            raise_sema_error("associated function #{type}.#{expression.member} must be called") unless method.type.receiver_type.nil?
            raise_sema_error("method #{type}.#{expression.member} must be called")
          end

          raise_sema_error("unknown member #{type}.#{expression.member}")
        end

        if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
          imported_module = @imports.fetch(expression.receiver.name)
          value = imported_module.values[expression.member]
          return value.type if value

          if imported_module.functions.key?(expression.member)
            function = imported_module.functions.fetch(expression.member)
            raise_sema_error("generic function #{expression.receiver.name}.#{expression.member} must be called") if function.type_params.any?
            if expected_type
              record_callable_value_member_access_site(expression)
              return function.type
            end

            raise_sema_error("function #{expression.receiver.name}.#{expression.member} must be called")
          end

          if imported_module.types.key?(expression.member)
            raise_sema_error("type #{expression.receiver.name}.#{expression.member} cannot be used as a value")
          end

          if imported_module.private_value?(expression.member) || imported_module.private_function?(expression.member) || imported_module.private_type?(expression.member)
            raise_sema_error("#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}")
          end

          raise_sema_error("unknown member #{expression.receiver.name}.#{expression.member}")
        end

        field_receiver_type = infer_field_receiver_type(expression.receiver, scopes:)
        method_receiver_type = infer_method_receiver_type(expression.receiver, scopes:, member_name: expression.member)
        return @error_type if error_type?(field_receiver_type) || error_type?(method_receiver_type)

        if char_array_removed_text_method?(method_receiver_type, expression.member)
          raise_sema_error("#{method_receiver_type}.#{expression.member} is not available; array[char, N] is raw storage, use str_buffer[N] or an explicit helper")
        end
        if str_buffer_type?(method_receiver_type) && str_buffer_method_kind(method_receiver_type, expression.member)
          raise_sema_error("method #{method_receiver_type}.#{expression.member} must be called")
        end

        unless aggregate_type?(field_receiver_type)
          raise_sema_error("cannot access member #{expression.member} of #{field_receiver_type}")
        end

        field_type = field_receiver_type.field(expression.member)
        return field_type if field_type

        if lookup_method(method_receiver_type, expression.member)
          raise_sema_error("method #{method_receiver_type.name}.#{expression.member} must be called")
        end

        if (imported_module = imported_module_with_private_method(method_receiver_type, expression.member))
          raise_sema_error("#{method_receiver_type}.#{expression.member} is private to module #{imported_module.name}")
        end

        raise_sema_error("unknown field #{field_receiver_type}.#{expression.member}")
      end

      def infer_index_access(expression, scopes:)
        receiver_type = infer_expression(expression.receiver, scopes:)
        index_type = infer_expression(expression.index, scopes:)

        if array_type?(receiver_type) && !unsafe_context? && !addressable_storage_expression?(expression.receiver, scopes:)
          raise_sema_error("safe array indexing requires an addressable array value; bind it to a local first")
        end

        infer_index_result_type(receiver_type, index_type)
      end

      def infer_unary(expression, scopes:, expected_type: nil)
        return infer_propagate_expression(expression.operand, scopes:) if expression.operator == "?"

        operand_type = infer_expression(expression.operand, scopes:, expected_type:)

        case expression.operator
        when "not"
          ensure_assignable!(operand_type, @types.fetch("bool"), "operator not requires bool, got #{operand_type}")
          @types.fetch("bool")
        when "+", "-"
          raise_sema_error("operator #{expression.operator} requires a numeric operand, got #{operand_type}") unless operand_type.numeric?

          operand_type
        when "~"
          raise_sema_error("operator ~ requires an integer or flags operand, got #{operand_type}") unless bitwise_type?(operand_type)

          operand_type
        when "out", "in", "inout"
          raise_sema_error("#{expression.operator} is only allowed for foreign call arguments")
        else
          raise_sema_error("unsupported unary operator #{expression.operator}")
        end
      end

      def infer_propagate_expression(operand, scopes:, allow_void_success: false)
        source_type = infer_expression(operand, scopes:)
        raise_sema_error("propagation expects Result[T, E], got #{source_type}") unless result_let_else_type?(source_type)

        success_type = let_else_success_type(source_type)
        error_type = let_else_error_type(source_type)
        raise_sema_error("propagation requires a non-void Result success type") if success_type == @types.fetch("void") && !allow_void_success

        context = current_return_context
        raise_sema_error("propagation is only allowed inside function and proc bodies") unless context
        raise_sema_error("propagation is not allowed inside defer blocks") unless context[:allow_return]

        return_type = context[:return_type]
        unless result_let_else_type?(return_type)
          raise_sema_error("propagation requires enclosing function/proc to return Result[_, #{error_type}], got #{return_type}")
        end

        return_error_type = let_else_error_type(return_type)
        unless return_error_type == error_type
          raise_sema_error("propagation error type #{error_type} must match enclosing Result error type #{return_error_type}")
        end

        success_type
      end


      def infer_binary(expression, scopes:, expected_type: nil)
        propagated_type = propagating_expected_type(expression.operator, expected_type)
        left_type = infer_expression(expression.left, scopes:, expected_type: propagated_type)

        right_scopes = case expression.operator
                       when "and"
                         scopes_with_refinements(scopes, flow_refinements(expression.left, truthy: true, scopes:))
                       when "or"
                         scopes_with_refinements(scopes, flow_refinements(expression.left, truthy: false, scopes:))
                       else
                         scopes
                       end

        right_expected_type = case expression.operator
                              when "<<", ">>"
                                propagated_type || left_type
                              when "+", "-", "*", "/", "%"
                                propagated_type || left_type
                              when "|", "&", "^"
                                left_type
                              else
                                left_type
                              end

        right_type = infer_expression(expression.right, scopes: right_scopes, expected_type: right_expected_type)
        left_type, right_type = harmonize_binary_float_literal_types(
          expression.left,
          expression.right,
          left_type,
          right_type,
          scopes: right_scopes,
        )

        case expression.operator
        when "and", "or"
          ensure_assignable!(left_type, @types.fetch("bool"), "operator #{expression.operator} requires bool operands")
          ensure_assignable!(right_type, @types.fetch("bool"), "operator #{expression.operator} requires bool operands")
          @types.fetch("bool")
        when "|", "&", "^"
          unless left_type == right_type && bitwise_type?(left_type)
            raise_sema_error("operator #{expression.operator} requires matching integer or flags types, got #{left_type} and #{right_type}")
          end

          left_type
        when "+", "-", "*", "/"
          if expression.operator == "+" && (string_like_type?(left_type) || string_like_type?(right_type))
            raise_sema_error("operator + does not support str/cstr concatenation; use continued string literals for static text or string.String/str_buffer for dynamic text")
          end

          pointer_result = pointer_arithmetic_result(expression.operator, left_type, right_type)
          return pointer_result if pointer_result

          result_type = common_numeric_type(left_type, right_type)
          unless result_type
            raise_sema_error("operator #{expression.operator} requires compatible numeric types, got #{left_type} and #{right_type}")
          end

          result_type
        when "%"
          result_type = common_integer_type(left_type, right_type)
          unless result_type
            raise_sema_error("operator % requires compatible integer types, got #{left_type} and #{right_type}")
          end

          result_type
        when "<<", ">>"
          unless left_type.is_a?(Types::Primitive) && left_type.integer? && right_type.is_a?(Types::Primitive) && right_type.integer?
            raise_sema_error("operator #{expression.operator} requires integer operands, got #{left_type} and #{right_type}")
          end

          left_type
        when "<", "<=", ">", ">="
          unless common_numeric_type(left_type, right_type)
            raise_sema_error("operator #{expression.operator} requires compatible numeric types, got #{left_type} and #{right_type}")
          end

          @types.fetch("bool")
        when "==", "!="
          unless common_numeric_type(left_type, right_type) || types_compatible?(left_type, right_type) || types_compatible?(right_type, left_type)
            raise_sema_error("operator #{expression.operator} requires comparable types, got #{left_type} and #{right_type}")
          end

          @types.fetch("bool")
        else
          raise_sema_error("unsupported binary operator #{expression.operator}")
        end
      end

      def infer_if_expression(expression, scopes:, expected_type: nil)
        condition_type = infer_expression(expression.condition, scopes:, expected_type: @types.fetch("bool"))
        ensure_assignable!(condition_type, @types.fetch("bool"), "if expression condition must be bool, got #{condition_type}")

        then_scopes = scopes_with_refinements(scopes, flow_refinements(expression.condition, truthy: true, scopes:))
        else_scopes = scopes_with_refinements(scopes, flow_refinements(expression.condition, truthy: false, scopes:))
        then_type = infer_expression(expression.then_expression, scopes: then_scopes, expected_type:)
        else_type = infer_expression(expression.else_expression, scopes: else_scopes, expected_type:)

        return expected_type if expected_type &&
          types_compatible?(then_type, expected_type, expression: expression.then_expression) &&
          types_compatible?(else_type, expected_type, expression: expression.else_expression)

        common_type = conditional_common_type(
          then_type,
          else_type,
          then_expression: expression.then_expression,
          else_expression: expression.else_expression,
        )
        return common_type if common_type

        raise_sema_error("if expression branches require compatible types, got #{then_type} and #{else_type}")
      end

      def infer_match_expression(expression, scopes:, expected_type: nil)
        validate_consuming_foreign_expression!(expression.expression, scopes:, root_allowed: false)
        validate_hoistable_foreign_expression!(expression.expression, scopes:, root_hoistable: false)
        scrutinee_type = infer_expression(expression.expression, scopes:)

        if error_type?(scrutinee_type)
          infer_recovered_match_expression(expression, scopes:, expected_type:)
        elsif scrutinee_type.is_a?(Types::Enum)
          infer_enum_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        elsif scrutinee_type.is_a?(Types::Variant)
          infer_variant_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        elsif integer_type?(scrutinee_type)
          infer_integer_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        else
          raise_sema_error("match requires an enum, variant, or integer scrutinee, got #{scrutinee_type}")
        end
      end

      def infer_recovered_match_expression(expression, scopes:, expected_type:)
        arm_entries = expression.arms.map do |arm|
          arm_scopes = scopes
          if arm.binding_name
            ensure_non_reserved_primitive_name!(arm.binding_name, kind_label: "match binding", line: arm.binding_line, column: arm.binding_column)
            binding = value_binding(
              name: arm.binding_name,
              type: @error_type,
              mutable: false,
              kind: :local,
              id: @preassigned_local_binding_ids.fetch(arm.object_id),
            )
            arm_scopes = [{ arm.binding_name => binding }] + scopes
            record_declaration_binding(arm, binding)
          end
          [infer_match_expression_arm_value(arm, scopes: arm_scopes, expected_type:), arm.value]
        end

        match_expression_common_type(arm_entries, expected_type)
      end

      def infer_enum_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        covered_members = {}
        wildcard_seen = false
        arm_entries = []

        expression.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen

            wildcard_seen = true
            arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
            next
          end

          validate_consuming_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
          validate_hoistable_foreign_expression!(arm.pattern, scopes:, root_hoistable: false)
          pattern_type = infer_expression(arm.pattern, scopes:, expected_type: scrutinee_type)
          ensure_assignable!(pattern_type, scrutinee_type, "match arm expects #{scrutinee_type}, got #{pattern_type}")

          member_name = match_member_name(arm.pattern, scrutinee_type)
          raise_sema_error("match arm must be an enum member of #{scrutinee_type}") unless member_name
          raise_sema_error("duplicate match arm #{scrutinee_type}.#{member_name}") if covered_members.key?(member_name)

          covered_members[member_name] = true
          arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
        end

        unless wildcard_seen
          missing_members = scrutinee_type.members - covered_members.keys
          raise_sema_error("match on #{scrutinee_type} is missing cases: #{missing_members.join(', ')}") unless missing_members.empty?
        end

        match_expression_common_type(arm_entries, expected_type)
      end

      def infer_integer_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        has_wildcard = expression.arms.any? { |arm| wildcard_pattern?(arm.pattern) }
        raise_sema_error("match on integer type #{scrutinee_type} requires a wildcard arm (_:)") unless has_wildcard

        covered_values = {}
        wildcard_seen = false
        arm_entries = []

        expression.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen

            wildcard_seen = true
            arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
            next
          end

          unless arm.pattern.is_a?(AST::IntegerLiteral)
            raise_sema_error("match arm for integer scrutinee must be an integer literal or _, got #{arm.pattern.class.name}")
          end

          value = arm.pattern.value
          raise_sema_error("duplicate match arm value #{value}") if covered_values.key?(value)

          covered_values[value] = true
          arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
        end

        match_expression_common_type(arm_entries, expected_type)
      end

      def infer_variant_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        covered_arms = {}
        wildcard_seen = false
        arm_entries = []

        expression.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen

            wildcard_seen = true
            arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
            next
          end

          validate_consuming_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
          validate_hoistable_foreign_expression!(arm.pattern, scopes:, root_hoistable: false)

          arm_name = variant_match_arm_name(arm.pattern, scrutinee_type)
          raise_sema_error("match arm must be a variant arm of #{scrutinee_type}") unless arm_name
          raise_sema_error("duplicate match arm #{scrutinee_type}.#{arm_name}") if covered_arms.key?(arm_name)

          covered_arms[arm_name] = true

          arm_scopes = scopes.dup
          if arm.binding_name
            ensure_non_reserved_primitive_name!(arm.binding_name, kind_label: "match binding", line: arm.binding_line, column: arm.binding_column)
            fields = scrutinee_type.arm(arm_name)
            if fields.nil? || fields.empty?
              raise_sema_error("variant arm #{scrutinee_type}.#{arm_name} has no payload; 'as' binding is not allowed")
            end

            payload_type = Types::VariantArmPayload.new(scrutinee_type, arm_name, fields)
            binding = value_binding(
              name: arm.binding_name,
              type: payload_type,
              mutable: false,
              kind: :local,
              id: @preassigned_local_binding_ids.fetch(arm.object_id),
            )
            arm_scopes = [{ arm.binding_name => binding }] + arm_scopes
            record_declaration_binding(arm, binding)
          end

          arm_entries << [infer_match_expression_arm_value(arm, scopes: arm_scopes, expected_type:), arm.value]
        end

        unless wildcard_seen
          missing_arms = scrutinee_type.arm_names - covered_arms.keys
          raise_sema_error("match on #{scrutinee_type} is missing cases: #{missing_arms.join(', ')}") unless missing_arms.empty?
        end

        match_expression_common_type(arm_entries, expected_type)
      end

      def infer_match_expression_arm_value(arm, scopes:, expected_type:)
        validate_consuming_foreign_expression!(arm.value, scopes:, root_allowed: false)
        validate_hoistable_foreign_expression!(arm.value, scopes:, root_hoistable: false)
        infer_expression(arm.value, scopes:, expected_type:)
      end

      def match_expression_common_type(arm_entries, expected_type)
        return expected_type || @error_type if arm_entries.empty?

        if expected_type && arm_entries.all? { |type, expr| types_compatible?(type, expected_type, expression: expr) }
          return expected_type
        end

        common_type, common_expression = arm_entries.first
        arm_entries.drop(1).each do |type, expr|
          next if type == common_type

          merged_type = conditional_common_type(
            common_type,
            type,
            then_expression: common_expression,
            else_expression: expr,
          )
          raise_sema_error("match expression arms require compatible types, got #{common_type} and #{type}") unless merged_type

          common_type = merged_type
          common_expression = expr
        end

        common_type
      end

      def infer_proc_expression(expression, scopes:, expected_type: nil)
        proc_type = resolve_type_ref(AST::ProcType.new(params: expression.params, return_type: expression.return_type))
        if expected_type && !proc_type_compatible?(proc_type, expected_type)
          raise_sema_error("proc expression expects #{proc_type}, got #{expected_type}")
        end

        proc_scopes = scopes.map { |scope| freeze_scope_bindings(scope) }
        proc_scope = {}
        expression.params.each do |param|
          ensure_non_reserved_primitive_name!(param.name, kind_label: "parameter", line: param.respond_to?(:line) ? param.line : nil, column: param.respond_to?(:column) ? param.column : nil)
          param_type = resolve_type_ref(param.type)
          validate_parameter_ref_type!(param_type, function_name: "proc", parameter_name: param.name, external: false)
          validate_parameter_proc_type!(param_type, function_name: "proc", parameter_name: param.name, external: false, foreign: false)
          proc_scope[param.name] = value_binding(name: param.name, type: param_type, mutable: false, kind: :param)
        end

        check_block(expression.body, scopes: proc_scopes + [proc_scope], return_type: proc_type.return_type, allow_return: true)
        proc_type
      end

      def infer_await_expression(expression, scopes:)
        raise_sema_error("await is only allowed inside async functions") unless inside_async_function?

        task_type = infer_expression(expression.expression, scopes:)
        raise_sema_error("await expects Task[T], got #{task_type}") unless task_type.is_a?(Types::Task)

        task_type.result_type
      end

      def harmonize_binary_float_literal_types(left_expression, right_expression, left_type, right_type, scopes:)
        if float_literal_expression?(left_expression) && right_type.is_a?(Types::Primitive) && right_type.float?
          left_type = infer_expression(left_expression, scopes:, expected_type: right_type)
        end

        if float_literal_expression?(right_expression) && left_type.is_a?(Types::Primitive) && left_type.float?
          right_type = infer_expression(right_expression, scopes:, expected_type: left_type)
        end

        [left_type, right_type]
      end

      def float_literal_expression?(expression)
        expression.is_a?(AST::FloatLiteral) ||
          (expression.is_a?(AST::UnaryOp) && ["+", "-"].include?(expression.operator) && float_literal_expression?(expression.operand))
      end

      def propagating_expected_type(operator, expected_type)
        case operator
        when "+", "-", "*", "/", "%", "<<", ">>"
          return expected_type if expected_type.is_a?(Types::Primitive) && expected_type.numeric?
        when "|", "&", "^"
          return expected_type if expected_type.is_a?(Types::Primitive) && expected_type.integer?
          return expected_type if expected_type.is_a?(Types::Flags)
        end

        nil
      end

      def infer_call(expression, scopes:, expected_type: nil)
        if expression.callee.is_a?(AST::Specialization) && expression.callee.callee.is_a?(AST::Identifier)
          case expression.callee.callee.name
          when "zero"
            raise_sema_error("zero[T]() is no longer supported; use zero[T]")
          when "default"
            raise_sema_error("default[T]() is no longer supported; use default[T]")
          end
        end

        callable_kind, callable, receiver = resolve_callable(expression.callee, scopes:)

        case callable_kind
        when :function
          callable = specialize_function_binding(
            callable,
            expression.arguments,
            scopes:,
            receiver_type: callable_receiver_type_for_specialization(expression.callee, scopes:),
          )

          check_function_call(callable, expression.arguments, scopes:)
          callable.owner.send(:check_function, callable) unless callable.type_arguments.empty?
          callable.type.return_type
        when :method
          callable = specialize_function_binding(
            callable,
            expression.arguments,
            scopes:,
            receiver_type: infer_method_receiver_type(receiver, scopes:, member_name: expression.callee.member),
          ) if callable.type_params.any?
          record_mutable_receiver_expression(receiver) if callable.type.receiver_mutable
          raise_sema_error("cannot call mutable method #{callable.name} on an immutable receiver") if callable.type.receiver_mutable && !assignable_receiver?(receiver, scopes)

          check_function_call(callable, expression.arguments, scopes:)
          callable.owner.send(:check_function, callable) unless callable.type_arguments.empty?
          callable.type.return_type
        when :callable_value
          check_callable_value_call(callable, expression.arguments, scopes:, callee_expression: expression.callee)
          callable.return_type
        when :str_buffer_clear, :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format,
          :str_buffer_len, :str_buffer_capacity, :str_buffer_as_str, :str_buffer_as_cstr
          check_str_buffer_method_call(callable_kind, receiver, expression.arguments, scopes:)
        when :struct
          check_aggregate_construction(callable, expression.arguments, scopes:)
        when :variant_arm_ctor
          check_variant_arm_construction(callable, expression.arguments, scopes:)
        when :array
          check_array_construction(callable, expression.arguments, scopes:)
        when :cast
          check_cast_call(callable, expression.arguments, scopes:)
        when :reinterpret
          check_reinterpret_call(callable, expression.arguments, scopes:)
        when :hash
          check_hash_call(callable, expression.arguments, scopes:)
        when :equal
          check_equal_call(callable, expression.arguments, scopes:)
        when :order
          check_order_call(callable, expression.arguments, scopes:)
        when :zero
          raise_sema_error("zero[T]() is no longer supported; use zero[T]")
        when :default
          raise_sema_error("default[T]() is no longer supported; use default[T]")
        when :fatal
          check_fatal_call(expression.arguments, scopes:)
        when :ref_of
          check_ref_of_call(expression.arguments, scopes:)
        when :const_ptr_of
          check_const_ptr_of_call(expression.arguments, scopes:)
        when :read
          check_read_call(expression.arguments, scopes:)
        when :ptr_of
          check_ptr_of_call(expression.arguments, scopes:)
        else
          raise_sema_error("#{describe_expression(expression.callee)} is not callable")
        end
      end

      def validate_consuming_foreign_expression!(expression, scopes:, root_allowed: false)
        return unless expression
        return if expression.is_a?(AST::ErrorExpr)

        if (foreign_call = resolve_foreign_call_expression(expression, scopes:)) && foreign_call_consumes_binding?(foreign_call[:binding])
          raise_sema_error("consuming foreign calls must be top-level expression statements") unless root_allowed
        end

        case expression
        when AST::Call, AST::Specialization
          validate_consuming_foreign_expression!(expression.callee, scopes:, root_allowed: false)
          expression.arguments.each do |argument|
            validate_consuming_foreign_expression!(argument.value, scopes:, root_allowed: false)
          end
        when AST::UnaryOp
          validate_consuming_foreign_expression!(expression.operand, scopes:, root_allowed: false)
        when AST::BinaryOp
          validate_consuming_foreign_expression!(expression.left, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.right, scopes:, root_allowed: false)
        when AST::IfExpr
          validate_consuming_foreign_expression!(expression.condition, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.then_expression, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.else_expression, scopes:, root_allowed: false)
        when AST::MatchExpr
          validate_consuming_foreign_expression!(expression.expression, scopes:, root_allowed: false)
          expression.arms.each do |arm|
            validate_consuming_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
            arm_scopes = arm.binding_name ? [{ arm.binding_name => value_binding(name: arm.binding_name, type: @error_type, mutable: false, kind: :local, id: @preassigned_local_binding_ids.fetch(arm.object_id)) }] + scopes : scopes
            validate_consuming_foreign_expression!(arm.value, scopes: arm_scopes, root_allowed: false)
          end
        when AST::UnsafeExpr
          validate_consuming_foreign_expression!(expression.expression, scopes:, root_allowed: false)
        when AST::FormatString
          expression.parts.each do |part|
            next unless part.is_a?(AST::FormatExprPart)

            validate_consuming_foreign_expression!(part.expression, scopes:, root_allowed: false)
          end
        when AST::MemberAccess
          validate_consuming_foreign_expression!(expression.receiver, scopes:, root_allowed: false)
        when AST::IndexAccess
          validate_consuming_foreign_expression!(expression.receiver, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.index, scopes:, root_allowed: false)
        when AST::RangeExpr
          validate_consuming_foreign_expression!(expression.start_expr, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.end_expr, scopes:, root_allowed: false)
        end
      end

      def validate_hoistable_foreign_expression!(expression, scopes:, root_hoistable: false)
        return unless expression
        return if expression.is_a?(AST::ErrorExpr)

        if (foreign_call = resolve_foreign_call_expression(expression, scopes:)) && (message = inline_foreign_call_requires_hoisting_message(foreign_call, scopes:))
          raise_sema_error(message) unless root_hoistable
        end

        case expression
        when AST::Call, AST::Specialization
          validate_hoistable_foreign_expression!(expression.callee, scopes:, root_hoistable: false)
          expression.arguments.each do |argument|
            validate_hoistable_foreign_expression!(argument.value, scopes:, root_hoistable: false)
          end
        when AST::UnaryOp
          validate_hoistable_foreign_expression!(expression.operand, scopes:, root_hoistable: false)
        when AST::BinaryOp
          validate_hoistable_foreign_expression!(expression.left, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.right, scopes:, root_hoistable: false)
        when AST::IfExpr
          validate_hoistable_foreign_expression!(expression.condition, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.then_expression, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.else_expression, scopes:, root_hoistable: false)
        when AST::MatchExpr
          validate_hoistable_foreign_expression!(expression.expression, scopes:, root_hoistable: false)
          expression.arms.each do |arm|
            validate_hoistable_foreign_expression!(arm.pattern, scopes:, root_hoistable: false)
            arm_scopes = arm.binding_name ? [{ arm.binding_name => value_binding(name: arm.binding_name, type: @error_type, mutable: false, kind: :local, id: @preassigned_local_binding_ids.fetch(arm.object_id)) }] + scopes : scopes
            validate_hoistable_foreign_expression!(arm.value, scopes: arm_scopes, root_hoistable: false)
          end
        when AST::UnsafeExpr
          validate_hoistable_foreign_expression!(expression.expression, scopes:, root_hoistable: false)
        when AST::FormatString
          expression.parts.each do |part|
            next unless part.is_a?(AST::FormatExprPart)

            validate_hoistable_foreign_expression!(part.expression, scopes:, root_hoistable: false)
          end
        when AST::MemberAccess
          validate_hoistable_foreign_expression!(expression.receiver, scopes:, root_hoistable: false)
        when AST::IndexAccess
          validate_hoistable_foreign_expression!(expression.receiver, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.index, scopes:, root_hoistable: false)
        when AST::RangeExpr
          validate_hoistable_foreign_expression!(expression.start_expr, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.end_expr, scopes:, root_hoistable: false)
        end
      end

      def inline_foreign_call_requires_hoisting_message(foreign_call, scopes:)
        binding = foreign_call[:binding]
        call = foreign_call[:call]
        reference_counts = foreign_mapping_reference_counts(foreign_mapping_expression(binding.ast))

        binding.ast.params.each_with_index do |param_ast, index|
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil
          total_references = reference_counts.fetch(param_ast.name, 0)
          total_references += reference_counts.fetch(public_alias, 0) if public_alias
          next if total_references <= 1 || simple_foreign_argument_expression?(call.arguments.fetch(index).value)

          return inline_foreign_hoisting_message(binding.name, param_ast.name, reason: "is referenced multiple times in its mapping")
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          argument_expression = call.arguments.fetch(index).value
          next unless automatic_foreign_cstr_temp_needed?(parameter, argument_expression, scopes:) || automatic_foreign_cstr_list_temp_needed?(parameter)

          return inline_foreign_hoisting_message(binding.name, param_ast.name, reason: "needs temporary foreign text storage")
        end

        nil
      end

      def inline_foreign_hoisting_message(binding_name, parameter_name, reason:)
        "foreign call #{binding_name} cannot be used inline because #{parameter_name} #{reason}; use it as a statement, local initializer, assignment, or return expression"
      end

      def resolve_foreign_call_expression(expression, scopes:)
        call = expression
        return unless call.is_a?(AST::Call)

        callable_kind, callable, _receiver = resolve_callable(call.callee, scopes:)
        return unless callable_kind == :function

        callable = specialize_function_binding(
          callable,
          call.arguments,
          scopes:,
          receiver_type: callable_receiver_type_for_specialization(call.callee, scopes:),
        ) if callable.type_params.any?
        return unless foreign_function_binding?(callable)

        { call:, binding: callable }
      rescue SemaError
        nil
      end

      def foreign_call_consumes_binding?(binding)
        binding.type.params.any? { |parameter| parameter.passing_mode == :consuming }
      end

      def foreign_mapping_reference_counts(expression, counts = Hash.new(0))
        case expression
        when AST::Identifier
          counts[expression.name] += 1
        when AST::MemberAccess
          foreign_mapping_reference_counts(expression.receiver, counts)
        when AST::IndexAccess
          foreign_mapping_reference_counts(expression.receiver, counts)
          foreign_mapping_reference_counts(expression.index, counts)
        when AST::Specialization, AST::Call
          foreign_mapping_reference_counts(expression.callee, counts)
          expression.arguments.each { |argument| foreign_mapping_reference_counts(argument.value, counts) }
        when AST::UnaryOp
          foreign_mapping_reference_counts(expression.operand, counts)
        when AST::BinaryOp
          foreign_mapping_reference_counts(expression.left, counts)
          foreign_mapping_reference_counts(expression.right, counts)
        when AST::IfExpr
          foreign_mapping_reference_counts(expression.condition, counts)
          foreign_mapping_reference_counts(expression.then_expression, counts)
          foreign_mapping_reference_counts(expression.else_expression, counts)
        when AST::UnsafeExpr
          foreign_mapping_reference_counts(expression.expression, counts)
        end

        counts
      end

      def simple_foreign_argument_expression?(expression)
        case expression
        when AST::Identifier, AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral
          true
        when AST::MemberAccess
          simple_foreign_argument_expression?(expression.receiver)
        else
          false
        end
      end

      def automatic_foreign_cstr_list_temp_needed?(parameter)
        return false unless parameter.type.is_a?(Types::Span) && parameter.type.element_type == @types.fetch("str")
        return false unless parameter.boundary_type.is_a?(Types::Span)

        boundary_element_type = parameter.boundary_type.element_type
        boundary_element_type == @types.fetch("cstr") || char_pointer_type?(boundary_element_type)
      end

      def automatic_foreign_cstr_temp_needed?(parameter, expression, scopes:)
        return false unless parameter.boundary_type == @types.fetch("cstr") && parameter.type == @types.fetch("str")
        return false if expression.is_a?(AST::StringLiteral) && !expression.cstring

        infer_expression(expression, scopes:) != @types.fetch("cstr")
      end

      def consuming_foreign_call_refinements(expression, scopes:)
        foreign_call = resolve_foreign_call_expression(expression, scopes:)
        return {} unless foreign_call

        binding = foreign_call[:binding]
        return {} unless foreign_call_consumes_binding?(binding)

        binding.type.params.each_with_index.each_with_object({}) do |(parameter, index), refinements|
          next unless parameter.passing_mode == :consuming

          argument = foreign_call[:call].arguments.fetch(index)
          argument_binding = foreign_consuming_argument_binding(parameter, argument, scopes:, function_name: binding.name)
          refinements[argument.value.name] = @null_type if argument_binding.storage_type.is_a?(Types::Nullable)
        end
      end

      def resolve_callable(callee, scopes:)
        case callee
        when AST::Identifier
          if (binding = lookup_value(callee.name, scopes))
            return [:callable_value, binding.type, nil] if callable_type?(binding.type)

            raise_sema_error("#{callee.name} is not callable")
          end

          return [:function, @top_level_functions.fetch(callee.name), nil] if @top_level_functions.key?(callee.name)
          return [:fatal, nil, nil] if callee.name == "fatal"
          return [:ref_of, nil, nil] if callee.name == "ref_of"
          return [:const_ptr_of, nil, nil] if callee.name == "const_ptr_of"
          return [:read, nil, nil] if callee.name == "read"
          return [:ptr_of, nil, nil] if callee.name == "ptr_of"

          type = @types[callee.name]
          return [:struct, type, nil] if type.is_a?(Types::Struct) || type.is_a?(Types::StringView) || task_type?(type)

          raise_sema_error("unknown callable #{callee.name}")
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @imports.key?(callee.receiver.name)
            imported_module = @imports.fetch(callee.receiver.name)
            return [:function, imported_module.functions.fetch(callee.member), nil] if imported_module.functions.key?(callee.member)
            imported_type = imported_module.types[callee.member]
            if imported_type.is_a?(Types::Struct) || imported_type.is_a?(Types::StringView) || task_type?(imported_type)
              return [:struct, imported_module.types.fetch(callee.member), nil]
            end

            if imported_type.is_a?(Types::Variant)
              arm_name = callee.member
              unless imported_type.arm_names.include?(arm_name)
                raise_sema_error("unknown arm #{arm_name} for variant #{imported_type}")
              end

              return [:variant_arm_ctor, [imported_type, arm_name], nil]
            end

            if imported_module.private_function?(callee.member) || imported_module.private_type?(callee.member) || imported_module.private_value?(callee.member)
              raise_sema_error("#{callee.receiver.name}.#{callee.member} is private to module #{imported_module.name}")
            end

            raise_sema_error("unknown callable #{callee.receiver.name}.#{callee.member}")
          end

          if (type_expr = resolve_type_expression(callee.receiver))
            if type_expr.is_a?(Types::Variant)
              arm_name = callee.member
              unless type_expr.arm_names.include?(arm_name)
                raise_sema_error("unknown arm #{arm_name} for variant #{type_expr}")
              end

              return [:variant_arm_ctor, [type_expr, arm_name], nil]
            end

            method = lookup_method(type_expr, callee.member)
            return [:function, method, nil] if method && method.type.receiver_type.nil?

            raise_sema_error("unknown associated function #{type_expr}.#{callee.member}")
          end

          method_receiver_type = infer_method_receiver_type(callee.receiver, scopes:, member_name: callee.member)
          method = lookup_method(method_receiver_type, callee.member)
          return [:method, method, callee.receiver] if method

          if char_array_removed_text_method?(method_receiver_type, callee.member)
            raise_sema_error("#{method_receiver_type}.#{callee.member} is not available; array[char, N] is raw storage, use str_buffer[N] or an explicit helper")
          end

          if (str_buffer_method = str_buffer_method_kind(method_receiver_type, callee.member))
            return [str_buffer_method, method_receiver_type, callee.receiver]
          end

          field_receiver_type = infer_field_receiver_type(callee.receiver, scopes:)
          return [:callable_value, field_receiver_type.field(callee.member), nil] if aggregate_type?(field_receiver_type) && callable_type?(field_receiver_type.field(callee.member))

          if (imported_module = imported_module_with_private_method(method_receiver_type, callee.member))
            raise_sema_error("#{method_receiver_type}.#{callee.member} is private to module #{imported_module.name}")
          end

          raise_sema_error("unknown method #{method_receiver_type}.#{callee.member}")
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
            raise_sema_error("cast requires exactly one type argument") unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise_sema_error("cast type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

            return [:cast, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "reinterpret"
            raise_sema_error("reinterpret requires exactly one type argument") unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise_sema_error("reinterpret type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

            return [:reinterpret, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "array"
            raise_sema_error("array requires exactly two type arguments") unless callee.arguments.length == 2

            array_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["array"]), arguments: callee.arguments, nullable: false))
            raise_sema_error("array specialization must be array[T, N]") unless array_type?(array_type)

            return [:array, array_type, nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "span"
            raise_sema_error("span requires exactly one type argument") unless callee.arguments.length == 1

            span_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: callee.arguments, nullable: false))
            raise_sema_error("span specialization must be span[T]") unless span_type?(span_type)

            return [:struct, span_type, nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "zero"
            raise_sema_error("zero requires exactly one type argument") unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise_sema_error("zero type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

            return [:zero, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "default"
            return [:default, resolve_default_specialization(callee), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "hash"
            return [:hash, resolve_hash_specialization(callee), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "equal"
            return [:equal, resolve_equal_specialization(callee), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "order"
            return [:order, resolve_order_specialization(callee), nil]
          end

          if (callable_resolution = resolve_specialized_callable_binding(callee, scopes:))
            return callable_resolution
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct, specialized_type, nil] if specialized_type.is_a?(Types::Struct) || task_type?(specialized_type)
          end

          raise_sema_error("unsupported callable specialization #{describe_expression(callee)}")
        else
          callee_type = infer_expression(callee, scopes:)
          return [:callable_value, callee_type, nil] if callable_type?(callee_type)

          raise_sema_error("unsupported callee #{describe_expression(callee)}")
        end
      end

      def check_function_call(binding, arguments, scopes:)
        if arguments.any?(&:name)
          raise_sema_error("function #{binding.name} does not support named arguments")
        end

        expected_params = binding.type.params
        unless call_arity_matches?(binding.type, arguments.length)
          raise_sema_error(arity_error_message(binding.type, binding.name, arguments.length))
        end

        expected_params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          actual_type = foreign_argument_actual_type(parameter, argument, scopes:, function_name: binding.name, expected_type: parameter.type)
          record_mutating_argument_identifier(argument, parameter)
          if foreign_cstr_boundary_parameter?(parameter)
            unless foreign_cstr_argument_compatible?(actual_type, parameter, expression: foreign_argument_expression(argument))
              raise_sema_error("argument #{parameter.name} to #{binding.name} expects #{parameter.type}, got #{actual_type}")
            end
          else
            unless array_to_span_call_argument_compatible?(actual_type, parameter.type, expression: foreign_argument_expression(argument), scopes:) ||
                   call_argument_compatible?(actual_type, parameter.type, scopes:, external: binding.external, expression: foreign_argument_expression(argument))
              raise_sema_error("argument #{parameter.name} to #{binding.name} expects #{parameter.type}, got #{actual_type}")
            end
          end
        end

        arguments.drop(expected_params.length).each do |argument|
          infer_expression(argument.value, scopes:)
        end
      end

      def record_mutating_argument_identifier(argument, parameter)
        return unless %i[out inout].include?(parameter.passing_mode)
        return unless argument.value.is_a?(AST::Identifier)

        @mutating_argument_identifier_ids[argument.value.object_id] = true
      end

      def record_mutable_receiver_expression(receiver)
        return unless receiver

        @mutable_receiver_expression_ids[receiver.object_id] = true
      end

      def check_format_string_literal(format_string, scopes:)
        format_string.parts.each do |part|
          next unless part.is_a?(AST::FormatExprPart)

          value_type = infer_expression(part.expression, scopes:)

          if part.format_spec
            case part.format_spec[:kind]
            when :precision
              unless value_type.is_a?(Types::Primitive) && value_type.float?
                raise_sema_error("format spec ':.N' is only valid for float and double, got #{value_type}")
              end
            when :hex
              unless format_string_integer_base_spec_supported?(value_type)
                raise_sema_error("format spec ':x' and ':X' are only valid for integer primitives and integer-backed enums/flags, got #{value_type}")
              end
            when :oct
              unless format_string_integer_base_spec_supported?(value_type)
                raise_sema_error("format spec ':o' and ':O' are only valid for integer primitives and integer-backed enums/flags, got #{value_type}")
              end
            when :bin
              unless format_string_integer_base_spec_supported?(value_type)
                raise_sema_error("format spec ':b' and ':B' are only valid for integer primitives and integer-backed enums/flags, got #{value_type}")
              end
            else
              raise_sema_error("unsupported format spec #{part.format_spec.inspect}")
            end
          else
            next if format_string_interpolation_supported?(value_type, context: "formatted string interpolation of #{value_type}")
            raise_sema_error("formatted string interpolation supports str, cstr, bool, numeric primitives, integer-backed enums/flags, and types implementing format_len()/append_format(output: ref[std.string.String]), got #{value_type}")
          end
        end
      end

      def format_string_integer_base_spec_supported?(type)
        resolved = type.is_a?(Types::EnumBase) ? type.backing_type : type
        resolved.is_a?(Types::Primitive) && resolved.integer?
      end

      def format_string_interpolation_supported?(type, context:)
        return true if type == @types.fetch("str")
        return true if type == @types.fetch("cstr")
        return true if type == @types.fetch("bool")
        return true if type.is_a?(Types::Primitive) && type.integer?
        return true if type.is_a?(Types::Primitive) && type.float?
        return true if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
        return true if resolve_explicit_format_binding(type, context:)

        false
      end

      def string_builder_type?(type)
        type.respond_to?(:name) && type.respond_to?(:module_name) && type.name == "String" && type.module_name == "std.string"
      end

      def string_builder_ref_type?(type)
        ref_type?(type) && string_builder_type?(referenced_type(type))
      end

      def check_callable_value_call(function_type, arguments, scopes:, callee_expression:)
        if arguments.any?(&:name)
          raise_sema_error("#{describe_expression(callee_expression)} does not support named arguments")
        end

        unless call_arity_matches?(function_type, arguments.length)
          raise_sema_error(arity_error_message(function_type, describe_expression(callee_expression), arguments.length))
        end

        function_type.params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          actual_type = infer_expression(argument.value, scopes:, expected_type: parameter.type)
          unless call_argument_compatible?(actual_type, parameter.type, scopes:, external: false, expression: argument.value)
            raise_sema_error("argument #{parameter.name || index} to #{describe_expression(callee_expression)} expects #{parameter.type}, got #{actual_type}")
          end
        end

        arguments.drop(function_type.params.length).each do |argument|
          infer_expression(argument.value, scopes:)
        end
      end

      def call_arity_matches?(function_type, actual_count)
        return actual_count >= function_type.params.length if function_type.is_a?(Types::Function) && function_type.variadic

        actual_count == function_type.params.length
      end

      def arity_error_message(function_type, name, actual_count)
        if function_type.is_a?(Types::Function) && function_type.variadic
          "function #{name} expects at least #{function_type.params.length} arguments, got #{actual_count}"
        else
          "function #{name} expects #{function_type.params.length} arguments, got #{actual_count}"
        end
      end

      def check_fatal_call(arguments, scopes:)
        raise_sema_error("fatal does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("fatal expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        message_type = infer_expression(arguments.first.value, scopes:, expected_type: @types.fetch("str"))
        return @types.fetch("void") if string_like_type?(message_type)

        raise_sema_error("fatal expects str or cstr, got #{message_type}")
      end

      def check_ref_of_call(arguments, scopes:)
        raise_sema_error("ref_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("ref_of expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        source_type = infer_addr_source_type(arguments.first.value, scopes:)
        Types::GenericInstance.new("ref", [source_type])
      end

      def check_const_ptr_of_call(arguments, scopes:)
        raise_sema_error("const_ptr_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("const_ptr_of expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        source_type = infer_ro_addr_source_type(arguments.first.value, scopes:)
        const_pointer_to(source_type)
      end

      def check_read_call(arguments, scopes:)
        validate_read_call_arguments!(arguments)

        infer_reference_value_type(arguments.first.value, scopes:)
      end

      def check_ptr_of_call(arguments, scopes:)
        raise_sema_error("ptr_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("ptr_of expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        source_expression = arguments.first.value
        source_type = infer_expression(source_expression, scopes:)
        return pointer_to(referenced_type(source_type)) if ref_type?(source_type)

        pointer_to(infer_addr_source_type(source_expression, scopes:))
      end

      def check_aggregate_construction(struct_type, arguments, scopes:)
        display_name = aggregate_display_name(struct_type)

        if struct_type.is_a?(Types::StringView)
          require_unsafe!("str construction requires unsafe")
        end

        raise_sema_error("aggregate construction for #{display_name} requires named arguments") unless arguments.all?(&:name)

        provided = {}
        arguments.each do |argument|
          field_type = struct_type.field(argument.name)
          raise_sema_error("unknown field #{display_name}.#{argument.name}") unless field_type
          raise_sema_error("duplicate field #{display_name}.#{argument.name}") if provided.key?(argument.name)

          actual_type = infer_expression(argument.value, scopes:, expected_type: field_type)
          ensure_assignable!(
            actual_type,
            field_type,
            "field #{display_name}.#{argument.name} expects #{field_type}, got #{actual_type}",
            expression: argument.value,
            external_numeric: struct_type.respond_to?(:external) && struct_type.external,
            external_pointer_null: struct_type.respond_to?(:external) && struct_type.external,
            contextual_int_to_float: contextual_int_to_float_target?(field_type),
          )
          provided[argument.name] = true
        end

        struct_type
      end

      def check_variant_arm_construction(callable, arguments, scopes:)
        variant_type, arm_name = callable
        fields = variant_type.arm(arm_name)

        if fields.nil? || fields.empty?
          raise_sema_error("variant arm #{variant_type}.#{arm_name} has no payload; construct it without arguments") unless arguments.empty?

          return variant_type
        end

        raise_sema_error("variant arm construction requires named arguments") unless arguments.all?(&:name)

        provided = {}
        arguments.each do |argument|
          field_type = fields[argument.name]
          raise_sema_error("unknown field #{variant_type}.#{arm_name}.#{argument.name}") unless field_type
          raise_sema_error("duplicate field #{variant_type}.#{arm_name}.#{argument.name}") if provided.key?(argument.name)

          actual_type = infer_expression(argument.value, scopes:, expected_type: field_type)
          ensure_assignable!(
            actual_type,
            field_type,
            "field #{variant_type}.#{arm_name}.#{argument.name} expects #{field_type}, got #{actual_type}",
            expression: argument.value,
            contextual_int_to_float: contextual_int_to_float_target?(field_type),
          )
          provided[argument.name] = true
        end

        missing = fields.keys - provided.keys
        raise_sema_error("variant arm #{variant_type}.#{arm_name} is missing fields: #{missing.join(', ')}") unless missing.empty?

        variant_type
      end

      def check_array_construction(array_type, arguments, scopes:)
        raise_sema_error("array construction does not support named arguments") if arguments.any?(&:name)

        element_type = array_element_type(array_type)
        length = array_length(array_type)
        raise_sema_error("array expects at most #{length} elements, got #{arguments.length}") if arguments.length > length

        arguments.each do |argument|
          actual_type = infer_expression(argument.value, scopes:, expected_type: element_type)
          ensure_assignable!(
            actual_type,
            element_type,
            "array element expects #{element_type}, got #{actual_type}",
            expression: argument.value,
          )
        end

        array_type
      end

      def check_cast_call(target_type, arguments, scopes:)
        raise_sema_error("cast requires exactly one argument") unless arguments.length == 1
        raise_sema_error("cast does not support named arguments") if arguments.first.name

        source_type = infer_expression(arguments.first.value, scopes:)
        if source_type == target_type
          return target_type
        end

        if pointer_cast?(source_type, target_type)
          expression = arguments.first.value
          require_unsafe!("pointer cast requires unsafe", line: source_line(expression), column: source_column(expression))

          return target_type
        end

        if ref_to_pointer_cast?(source_type, target_type)
          expression = arguments.first.value
          require_unsafe!("ref to pointer cast requires unsafe", line: source_line(expression), column: source_column(expression))

          return target_type
        end

        source_numeric_type = cast_numeric_type(source_type)
        target_numeric_type = cast_numeric_type(target_type)

        unless source_numeric_type && target_numeric_type
          raise_sema_error("cast currently only supports numeric primitive types, got #{source_type} -> #{target_type}")
        end

        target_type
      end

      def cast_numeric_type(type)
        return type if type.is_a?(Types::Primitive) && type.numeric?
        return type.backing_type if type.is_a?(Types::EnumBase) && type.backing_type.numeric?
        return type if char_type?(type)
        return type.backing_type if type.is_a?(Types::EnumBase) && char_type?(type.backing_type)

        nil
      end

      def infer_null_literal(expression)
        return @null_type unless expression.type

        target_type = resolve_type_ref(expression.type)
        unless typed_null_target_type?(target_type)
          raise_sema_error("typed null requires pointer-like type, got #{target_type}")
        end

        Types::Null.new(target_type)
      end

      def check_reinterpret_call(target_type, arguments, scopes:)
        raise_sema_error("reinterpret requires exactly one argument") unless arguments.length == 1
        raise_sema_error("reinterpret does not support named arguments") if arguments.first.name
        require_unsafe!("reinterpret requires unsafe")

        source_type = infer_expression(arguments.first.value, scopes:)
        unless reinterpretable_type?(source_type) && reinterpretable_type?(target_type)
          raise_sema_error("reinterpret requires non-array concrete sized types, got #{source_type} -> #{target_type}")
        end

        target_type
      end

      def check_zero_call(target_type, arguments, expected_type: nil, operation: "zero")
        raise_sema_error("#{operation} expects 0 arguments, got #{arguments.length}") unless arguments.empty?

        zero_initializable_type?(target_type, operation:)
        if expected_type.is_a?(Types::Nullable) && typed_null_target_type?(expected_type.base) && types_compatible?(target_type, expected_type.base)
          raise_sema_error("use null instead of #{operation}[#{target_type}] in nullable pointer-like context #{expected_type}")
        end

        target_type
      end

      def resolve_default_specialization(callee)
        raise_sema_error("default requires exactly one type argument") unless callee.arguments.length == 1

        type_arg = callee.arguments.first.value
        raise_sema_error("default type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

        target_type = resolve_type_ref(type_arg)
        binding = resolve_explicit_default_binding(target_type, context: "default[#{target_type}]")
        raise_sema_error("default[#{target_type}] requires associated function #{target_type}.default()") unless binding

        DefaultResolution.new(
          target_type:,
          binding:,
        )
      end

      def resolve_hash_specialization(callee)
        raise_sema_error("hash requires exactly one type argument") unless callee.arguments.length == 1

        type_arg = callee.arguments.first.value
        raise_sema_error("hash type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

        target_type = resolve_type_ref(type_arg)
        binding = resolve_explicit_hash_binding(target_type, context: "hash[#{target_type}]")
        raise_sema_error("hash[#{target_type}] requires associated function #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint") unless binding

        HashResolution.new(
          target_type:,
          binding:,
        )
      end

      def resolve_equal_specialization(callee)
        raise_sema_error("equal requires exactly one type argument") unless callee.arguments.length == 1

        type_arg = callee.arguments.first.value
        raise_sema_error("equal type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

        target_type = resolve_type_ref(type_arg)
        binding = resolve_explicit_equal_binding(target_type, context: "equal[#{target_type}]")
        raise_sema_error("equal[#{target_type}] requires associated function #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool") unless binding

        EqualResolution.new(
          target_type:,
          binding:,
        )
      end

      def resolve_order_specialization(callee)
        raise_sema_error("order requires exactly one type argument") unless callee.arguments.length == 1

        type_arg = callee.arguments.first.value
        raise_sema_error("order type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

        target_type = resolve_type_ref(type_arg)
        binding = resolve_explicit_order_binding(target_type, context: "order[#{target_type}]")
        raise_sema_error("order[#{target_type}] requires associated function #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int") unless binding

        OrderResolution.new(
          target_type:,
          binding:,
        )
      end

      def resolve_explicit_default_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.default()"
        resolve_explicit_associated_binding(target_type, "default", requirement_message:) do |method|
          raise_sema_error("#{context} requires #{target_type}.default() to take 0 arguments") unless method.type.params.empty?
          unless types_compatible?(method.type.return_type, target_type)
            raise_sema_error("#{context} requires #{target_type}.default() to return #{target_type}, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_hash_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint"
        resolve_explicit_associated_binding(target_type, "hash", requirement_message:) do |method|
          unless method.type.params.map(&:type) == [const_pointer_to(target_type)]
            raise_sema_error("#{context} requires #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint")
          end
          unless method.type.return_type == @types.fetch("uint")
            raise_sema_error("#{context} requires #{target_type}.hash(value: const_ptr[#{target_type}]) -> uint, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_equal_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool"
        resolve_explicit_associated_binding(target_type, "equal", requirement_message:) do |method|
          expected_param_types = [const_pointer_to(target_type), const_pointer_to(target_type)]
          unless method.type.params.map(&:type) == expected_param_types
            raise_sema_error("#{context} requires #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool")
          end
          unless method.type.return_type == @types.fetch("bool")
            raise_sema_error("#{context} requires #{target_type}.equal(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> bool, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_order_binding(target_type, context:)
        requirement_message = "#{context} requires associated function #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int"
        resolve_explicit_associated_binding(target_type, "order", requirement_message:) do |method|
          expected_param_types = [const_pointer_to(target_type), const_pointer_to(target_type)]
          unless method.type.params.map(&:type) == expected_param_types
            raise_sema_error("#{context} requires #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int")
          end
          unless method.type.return_type == @types.fetch("int")
            raise_sema_error("#{context} requires #{target_type}.order(left: const_ptr[#{target_type}], right: const_ptr[#{target_type}]) -> int, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_format_binding(target_type, context:)
        length_binding = resolve_explicit_format_len_binding(target_type, context:)
        append_binding = resolve_explicit_format_append_binding(target_type, context:)

        return [length_binding, append_binding] if length_binding && append_binding

        if length_binding || append_binding
          raise_sema_error("#{context} requires methods #{target_type}.format_len() -> ptr_uint and #{target_type}.append_format(output: ref[std.string.String]) -> void")
        end

        nil
      end

      def resolve_explicit_format_len_binding(target_type, context:)
        requirement_message = "#{context} requires method #{target_type}.format_len() -> ptr_uint"
        resolve_explicit_instance_binding(target_type, "format_len", requirement_message:) do |method|
          raise_sema_error("#{context} requires #{target_type}.format_len() to take 0 arguments") unless method.type.params.empty?
          raise_sema_error("#{context} requires #{target_type}.format_len() to be non-mutable") if method.type.receiver_mutable
          unless method.type.return_type == @types.fetch("ptr_uint")
            raise_sema_error("#{context} requires #{target_type}.format_len() -> ptr_uint, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_format_append_binding(target_type, context:)
        requirement_message = "#{context} requires method #{target_type}.append_format(output: ref[std.string.String]) -> void"
        resolve_explicit_instance_binding(target_type, "append_format", requirement_message:) do |method|
          raise_sema_error("#{context} requires #{target_type}.append_format() to be non-mutable") if method.type.receiver_mutable
          unless method.type.params.length == 1 && string_builder_ref_type?(method.type.params.first.type)
            raise_sema_error("#{context} requires #{target_type}.append_format(output: ref[std.string.String]) -> void")
          end
          unless method.type.return_type == @types.fetch("void")
            raise_sema_error("#{context} requires #{target_type}.append_format(output: ref[std.string.String]) -> void, got #{method.type.return_type}")
          end
        end
      end

      def resolve_explicit_associated_binding(target_type, method_name, requirement_message:)
        method = lookup_method(target_type, method_name)
        if method
          raise_sema_error(requirement_message) unless method.type.receiver_type.nil?

          method = instantiate_function_binding_with_receiver(method, [], receiver_type: target_type) if method.type_params.any?
          yield method

          return method
        end

        if (imported_module = imported_module_with_private_method(target_type, method_name))
          raise_sema_error("#{target_type}.#{method_name} is private to module #{imported_module.name}")
        end

        nil
      end

      def resolve_explicit_instance_binding(target_type, method_name, requirement_message:)
        method = lookup_method(target_type, method_name)
        if method
          raise_sema_error(requirement_message) if method.type.receiver_type.nil?

          method = instantiate_function_binding_with_receiver(method, [], receiver_type: target_type) if method.type_params.any?
          yield method

          return method
        end

        if (imported_module = imported_module_with_private_method(target_type, method_name))
          raise_sema_error("#{target_type}.#{method_name} is private to module #{imported_module.name}")
        end

        nil
      end

      def check_hash_call(resolution, arguments, scopes:)
        raise_sema_error("hash does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("hash expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        validate_hash_operation_argument!(arguments.first.value, resolution.target_type, scopes:, operation: "hash")
        @types.fetch("uint")
      end

      def check_equal_call(resolution, arguments, scopes:)
        raise_sema_error("equal does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("equal expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        arguments.each do |argument|
          validate_hash_operation_argument!(argument.value, resolution.target_type, scopes:, operation: "equal")
        end

        @types.fetch("bool")
      end

      def check_order_call(resolution, arguments, scopes:)
        raise_sema_error("order does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("order expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        arguments.each do |argument|
          validate_hash_operation_argument!(argument.value, resolution.target_type, scopes:, operation: "order")
        end

        @types.fetch("int")
      end

      def validate_hash_operation_argument!(expression, target_type, scopes:, operation:)
        actual_type = infer_expression(expression, scopes:)
        expected_pointer_type = const_pointer_to(target_type)
        return if argument_types_compatible?(actual_type, expected_pointer_type, external: false, expression:, scopes:)
        return if ref_type?(actual_type) && types_compatible?(referenced_type(actual_type), target_type, expression:, scopes:)
        return if safe_reference_source_expression?(expression, scopes:) && types_compatible?(actual_type, target_type, expression:, scopes:)

        raise_sema_error("#{operation}[#{target_type}] expects a safe #{target_type} lvalue, ref[#{target_type}], ptr[#{target_type}], or const_ptr[#{target_type}], got #{actual_type}")
      end

      def check_str_buffer_method_call(kind, receiver, arguments, scopes:)
        method_name = str_buffer_method_name(kind)
        receiver_type = infer_expression(receiver, scopes:)
        raise_sema_error("unknown method #{receiver_type}.#{method_name}") unless str_buffer_type?(receiver_type)

        case kind
        when :str_buffer_clear, :str_buffer_len, :str_buffer_capacity, :str_buffer_as_str, :str_buffer_as_cstr
          raise_sema_error("#{method_name} does not support named arguments") if arguments.any?(&:name)
          raise_sema_error("#{method_name} expects 0 arguments, got #{arguments.length}") unless arguments.empty?
        when :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format
          raise_sema_error("#{method_name} does not support named arguments") if arguments.any?(&:name)
          raise_sema_error("#{method_name} expects 1 argument, got #{arguments.length}") unless arguments.length == 1
        else
          raise_sema_error("unsupported str_buffer method #{kind}")
        end

        case kind
        when :str_buffer_clear
          record_mutable_receiver_expression(receiver)
          raise_sema_error("cannot call mutable method #{receiver_type}.clear on an immutable receiver") unless assignable_receiver?(receiver, scopes)

          @types.fetch("void")
        when :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format
          record_mutable_receiver_expression(receiver)
          raise_sema_error("cannot call mutable method #{receiver_type}.#{method_name} on an immutable receiver") unless assignable_receiver?(receiver, scopes)

          actual_type = infer_expression(arguments.first.value, scopes:, expected_type: @types.fetch("str"))
          ensure_argument_assignable!(
            actual_type,
            @types.fetch("str"),
            external: false,
            message: "argument value to #{receiver_type}.#{method_name} expects str, got #{actual_type}",
            expression: arguments.first.value,
          )

          @types.fetch("void")
        when :str_buffer_len, :str_buffer_capacity
          @types.fetch("ptr_uint")
        when :str_buffer_as_str
          raise_sema_error("#{receiver_type}.as_str requires a safe stored receiver") unless safe_reference_source_expression?(receiver, scopes:)

          @types.fetch("str")
        when :str_buffer_as_cstr
          raise_sema_error("#{receiver_type}.as_cstr requires a safe stored receiver") unless safe_reference_source_expression?(receiver, scopes:)

          @types.fetch("cstr")
        else
          raise_sema_error("unsupported str_buffer method #{kind}")
        end
      end

      def lookup_value(name, scopes)
        scopes.reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        @top_level_values[name]
      end

      def lookup_method(receiver_type, name)
        method = lookup_method_local_or_imported(receiver_type, name)
        return method if method

        fallback_owner = specialization_lookup_owner
        return nil unless fallback_owner

        fallback_owner.send(:lookup_method_local_or_imported, receiver_type, name)
      end

      def lookup_method_local_or_imported(receiver_type, name)
        dispatch_receiver_type = method_dispatch_receiver_type(receiver_type)

        method = @methods.fetch(receiver_type, {})[name]
        method ||= @methods.fetch(dispatch_receiver_type, {})[name] unless dispatch_receiver_type == receiver_type
        return method if method

        imported_candidates = []

        @imports.each_value do |module_binding|
          imported_method = module_binding.methods.fetch(receiver_type, {})[name]
          if imported_method.nil? && dispatch_receiver_type != receiver_type
            imported_method = module_binding.methods.fetch(dispatch_receiver_type, {})[name]
          end

          imported_candidates << [module_binding, imported_method] if imported_method
        end

        if imported_candidates.empty?
          owner_module = reachable_module_binding_for_type(receiver_type)
          return nil unless owner_module

          return module_binding_method(owner_module, receiver_type, dispatch_receiver_type, name)
        end

        if imported_candidates.length > 1
          modules = imported_candidates.map { |module_binding, _binding| module_binding.name }.join(", ")
          raise_sema_error("ambiguous imported method #{receiver_type}.#{name}; found in modules #{modules}")
        end

        imported_candidates.first.last
      end

      def module_binding_method(module_binding, receiver_type, dispatch_receiver_type, name)
        method = module_binding.methods.fetch(receiver_type, {})[name]
        method ||= module_binding.methods.fetch(dispatch_receiver_type, {})[name] unless dispatch_receiver_type == receiver_type
        method
      end

      def reachable_module_binding_for_type(receiver_type)
        module_name = receiver_type_module_name(receiver_type)
        return nil unless module_name
        return nil if module_name == @module_name

        find_reachable_imported_module(module_name)
      end

      def receiver_type_module_name(receiver_type)
        return receiver_type_module_name(receiver_type.base) if receiver_type.is_a?(Types::Nullable)
        return receiver_type.module_name if receiver_type.respond_to?(:module_name)

        nil
      end

      def find_reachable_imported_module(module_name)
        visited = {}

        @imports.each_value do |module_binding|
          found = find_reachable_imported_module_from(module_binding, module_name, visited)
          return found if found
        end

        nil
      end

      def find_reachable_imported_module_from(module_binding, module_name, visited)
        return nil unless module_binding
        return module_binding if module_binding.name == module_name
        return nil if visited[module_binding.name]

        visited[module_binding.name] = true
        module_binding.imports.each_value do |imported_module|
          found = find_reachable_imported_module_from(imported_module, module_name, visited)
          return found if found
        end

        nil
      end

      def specialization_lookup_owner
        return nil if @current_specialization_owner.nil?
        return nil if @current_specialization_owner.equal?(self)

        @current_specialization_owner
      end

      def char_array_removed_text_method?(receiver_type, name)
        return unless char_array_text_type?(receiver_type)

        name == "as_str" || name == "as_cstr"
      end

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

      def str_buffer_method_name(kind)
        {
          str_buffer_clear: "clear",
          str_buffer_assign: "assign",
          str_buffer_append: "append",
          str_buffer_assign_format: "assign_format",
          str_buffer_append_format: "append_format",
          str_buffer_len: "len",
          str_buffer_capacity: "capacity",
          str_buffer_as_str: "as_str",
          str_buffer_as_cstr: "as_cstr",
        }.fetch(kind)
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

      def ensure_non_reserved_primitive_name!(name, kind_label:, line: nil, column: nil, length: nil)
        ensure_non_reserved_value_type_name!(name, kind_label:, line:, column:, length:)
      end

      def current_type_params
        @current_type_substitutions || {}
      end

      def current_type_param_constraints
        @current_type_param_constraints || {}
      end

      def resolve_interface_ref(interface_ref)
        parts = interface_ref.parts

        if parts.length == 1
          interface = @interfaces[parts.first]
          raise_sema_error("unknown interface #{parts.first}") unless interface

          return interface
        end

        if parts.length == 2 && @imports.key?(parts.first)
          imported_module = @imports.fetch(parts.first)
          interface = imported_module.interfaces[parts.last]
          if imported_module.private_interface?(parts.last)
            raise_sema_error("#{parts.first}.#{parts.last} is private to module #{imported_module.name}")
          end
          raise_sema_error("unknown interface #{interface_ref}") unless interface

          return interface
        end

        raise_sema_error("unknown interface #{interface_ref}")
      end

      def interface_implementation_key(type)
        return type.definition if type.is_a?(Types::StructInstance)

        type
      end

      def type_implements_interface?(type, interface)
        key = interface_implementation_key(type)
        return true if @implemented_interfaces.fetch(key, []).include?(interface)

        @imports.each_value do |module_binding|
          return true if module_binding.implemented_interfaces.fetch(key, []).include?(interface)
        end

        false
      end

      def type_satisfies_interface_constraint?(type, interface, available_type_param_constraints: current_type_param_constraints)
        if type.is_a?(Types::TypeVar)
          constraint = available_type_param_constraints[type.name]
          return constraint && constraint.interfaces.include?(interface)
        end

        type_implements_interface?(type, interface)
      end

      def validate_type_param_constraint_binding!(constraints, actual_type, context:, available_type_param_constraints: current_type_param_constraints)
        constraints.interfaces.each do |interface|
          next if type_satisfies_interface_constraint?(actual_type, interface, available_type_param_constraints:)

          raise_sema_error("type #{actual_type} does not implement interface #{interface.name} for #{context}")
        end
      end

      def validate_generic_type_param_constraints!(generic_type, arguments, context:, available_type_param_constraints: current_type_param_constraints)
        return if generic_type.type_param_constraints.empty?

        generic_type.type_params.zip(arguments).each do |name, actual_type|
          constraints = generic_type.type_param_constraints[name]
          next unless constraints

          validate_type_param_constraint_binding!(constraints, actual_type, context:, available_type_param_constraints:)
        end
      end

      def resolve_type_ref(type_ref, type_params: current_type_params, type_param_constraints: current_type_param_constraints)
        base = resolve_non_nullable_type(type_ref, type_params:, type_param_constraints:)
        return base if type_ref.is_a?(AST::FunctionType) || type_ref.is_a?(AST::ProcType)

        raise_sema_error("ref types are non-null and cannot be nullable") if type_ref.nullable && ref_type?(base)

        type_ref.nullable ? Types::Nullable.new(base) : base
      end

      def resolve_non_nullable_type(type_ref, type_params: {}, type_param_constraints: {})
        if type_ref.is_a?(AST::FunctionType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:, type_param_constraints:))
          end
          return Types::Function.new(nil, params:, return_type: resolve_type_ref(type_ref.return_type, type_params:, type_param_constraints:))
        end

        if type_ref.is_a?(AST::ProcType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:, type_param_constraints:))
          end
          return Types::Proc.new(params:, return_type: resolve_type_ref(type_ref.return_type, type_params:, type_param_constraints:))
        end

        parts = type_ref.name.parts

        if type_ref.arguments.any?
          name = parts.join(".")
          arguments = type_ref.arguments.map { |argument| resolve_type_argument(argument.value, type_params:, type_param_constraints:) }

          if name != "ref" && arguments.any? { |argument| contains_ref_type?(argument) }
            raise_sema_error("ref types cannot be nested inside #{name}")
          end

          if name == "Task"
            validate_generic_type!(name, arguments)
            return Types::Task.new(arguments[0])
          end

          if (generic_type = resolve_named_generic_type(parts))
            begin
              validate_generic_type_param_constraints!(generic_type, arguments, context: "type #{generic_type}", available_type_param_constraints: type_param_constraints)
              return generic_type.instantiate(arguments)
            rescue ArgumentError => error
              raise_sema_error(error.message)
            end
          end

          validate_generic_type!(name, arguments)
          return Types::Span.new(arguments.first) if name == "span"

          return Types::GenericInstance.new(name, arguments)
        end

        if parts.length == 1
          return type_params.fetch(parts.first) if type_params.key?(parts.first)

          type = @types[parts.first]
          raise_sema_error("unknown type #{parts.first}") unless type
          raise_sema_error("generic type #{parts.first} requires type arguments") if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

          return type
        end

        if parts.length == 2 && @imports.key?(parts.first)
          imported_module = @imports.fetch(parts.first)
          type = imported_module.types[parts.last]
          if imported_module.private_type?(parts.last)
            raise_sema_error("#{parts.first}.#{parts.last} is private to module #{imported_module.name}")
          end
          raise_sema_error("unknown type #{type_ref.name}") unless type
          raise_sema_error("generic type #{type_ref.name} requires type arguments") if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)

          return type
        end

        raise_sema_error("unknown type #{type_ref.name}")
      end

      def resolve_type_argument(argument, type_params: current_type_params, type_param_constraints: current_type_param_constraints)
        case argument
        when AST::TypeRef
          resolve_type_argument_ref(argument, type_params:, type_param_constraints:)
        when AST::FunctionType
          resolve_type_ref(argument, type_params:, type_param_constraints:)
        when AST::IntegerLiteral, AST::FloatLiteral
          Types::LiteralTypeArg.new(argument.value)
        else
          raise_sema_error("unsupported type argument #{argument.class.name}")
        end
      end

      def resolve_type_argument_ref(type_ref, type_params:, type_param_constraints:)
        return resolve_type_ref(type_ref, type_params:, type_param_constraints:) unless literal_type_argument_name_candidate?(type_ref)

        resolve_type_ref(type_ref, type_params:, type_param_constraints:)
      rescue SemaError => error
        literal_type_argument = resolve_named_literal_type_argument(type_ref)
        return literal_type_argument if literal_type_argument

        raise error
      end

      def literal_type_argument_name_candidate?(type_ref)
        type_ref.arguments.empty? && !type_ref.nullable
      end

      def resolve_named_literal_type_argument(type_ref)
        value = case type_ref.name.parts.length
                when 1
                  resolve_current_module_const_value(type_ref.name.parts.first)
                when 2
                  resolve_imported_module_const_value(type_ref.name.parts.first, type_ref.name.parts.last)
                end

        return unless value.is_a?(Integer) || value.is_a?(Float)

        Types::LiteralTypeArg.new(value)
      end

      def resolve_current_module_const_value(name)
        binding = @top_level_values[name]
        return unless binding&.kind == :const

        evaluate_top_level_const_value(name)
      end

      def resolve_imported_module_const_value(import_name, value_name)
        imported_module = @imports[import_name]
        return unless imported_module
        if imported_module.private_value?(value_name)
          raise_sema_error("#{import_name}.#{value_name} is private to module #{imported_module.name}")
        end

        binding = imported_module.values[value_name]
        return unless binding&.kind == :const

        binding.const_value
      end

      def resolve_enum_member_const_value(receiver_type, member_name, local_enum_type: nil, local_member_values: nil)
        return unless receiver_type.is_a?(Types::EnumBase)
        return unless receiver_type.member(member_name)

        if local_enum_type && receiver_type == local_enum_type && local_member_values&.key?(member_name)
          return local_member_values[member_name]
        end

        receiver_type.member_value(member_name)
      end

      def ensure_assignable!(actual_type, expected_type, message, expression: nil, scopes: nil, external_numeric: false, external_pointer_null: false, contextual_int_to_float: false, line: nil, column: nil)
        line ||= source_line(expression)
        column ||= source_column(expression)

        raise SemaError.new(message, line:, column:) unless types_compatible?(actual_type, expected_type, expression:, scopes:, external_numeric:, external_pointer_null:, contextual_int_to_float:)
      end

      def ensure_argument_assignable!(actual_type, expected_type, external:, message:, expression: nil, scopes: nil)
        line = source_line(expression)
        column = source_column(expression)
        raise SemaError.new(message, line:, column:) unless argument_types_compatible?(actual_type, expected_type, external:, expression:, scopes:)
      end

      def with_error_node(node)
        @error_node_stack << node
        yield
      ensure
        @error_node_stack.pop
      end

      def with_return_context(return_type, allow_return:)
        @return_context_stack << { return_type:, allow_return: }
        yield
      ensure
        @return_context_stack.pop
      end

      def current_return_context
        @return_context_stack.last
      end

      def current_error_node
        @error_node_stack.reverse_each.find { |node| !node.nil? }
      end

      def raise_sema_error(message, node = nil, line: nil, column: nil, length: nil)
        target = node || current_error_node
        line ||= source_line(target)
        column ||= source_column(target)
        length ||= source_length(target)
        raise SemaError.new(message, line:, column:, length:)
      end

      def source_line(node)
        return nil unless node
        return node.line if node.respond_to?(:line) && node.line

        case node
        when AST::MemberAccess then source_line(node.receiver)
        when AST::IndexAccess then source_line(node.receiver) || source_line(node.index)
        when AST::Specialization then source_line(node.callee)
        when AST::Call then source_line(node.callee) || node.arguments.filter_map { |argument| source_line(argument.value) }.first
        when AST::Argument then source_line(node.value)
        when AST::UnaryOp then source_line(node.operand)
        when AST::BinaryOp then source_line(node.left) || source_line(node.right)
        when AST::IfExpr then source_line(node.condition) || source_line(node.then_expression) || source_line(node.else_expression)
        when AST::MatchExpr then source_line(node.expression) || node.arms.filter_map { |arm| source_line(arm.pattern) || source_line(arm.value) }.first
        when AST::AwaitExpr then source_line(node.expression)
        when AST::FormatExprPart then source_line(node.expression)
        else nil
        end
      end

      def source_length(node)
        return nil unless node
        return node.length if node.respond_to?(:length) && node.length

        case node
        when AST::Identifier then node.name.to_s.length
        when AST::MemberAccess then node.member.to_s.length
        else
          nil
        end
      end

      def source_column(node)
        return nil unless node
        return node.column if node.respond_to?(:column) && node.column

        case node
        when AST::MemberAccess then source_column(node.receiver)
        when AST::IndexAccess then source_column(node.receiver) || source_column(node.index)
        when AST::Specialization then source_column(node.callee)
        when AST::Call then source_column(node.callee) || node.arguments.filter_map { |argument| source_column(argument.value) }.first
        when AST::Argument then source_column(node.value)
        when AST::UnaryOp then source_column(node.operand)
        when AST::BinaryOp then source_column(node.left) || source_column(node.right)
        when AST::IfExpr then source_column(node.condition) || source_column(node.then_expression) || source_column(node.else_expression)
        when AST::MatchExpr then source_column(node.expression) || node.arms.filter_map { |arm| source_column(arm.pattern) || source_column(arm.value) }.first
        when AST::AwaitExpr then source_column(node.expression)
        when AST::FormatExprPart then source_column(node.expression)
        else nil
        end
      end

      def call_argument_compatible?(actual_type, expected_type, scopes:, external:, expression: nil)
        return true if argument_types_compatible?(actual_type, expected_type, external:, expression:, scopes:, contextual_int_to_float: !external)
        return true if implicit_ref_argument_compatible?(actual_type, expected_type, expression, scopes)
        return true if direct_task_to_proc_argument_compatible?(actual_type, expected_type)
        return true if direct_function_to_proc_argument_compatible?(actual_type, expected_type, expression, scopes)

        false
      end

      def implicit_ref_argument_compatible?(actual_type, expected_type, expression, scopes)
        return false unless expression && scopes
        return false unless ref_type?(expected_type)
        return false unless actual_type == referenced_type(expected_type)
        return false unless safe_reference_source_expression?(expression, scopes:)

        infer_lvalue(expression, scopes:)
        true
      rescue SemaError
        false
      end

      def types_compatible?(actual_type, expected_type, expression: nil, scopes: nil, external_numeric: false, external_pointer_null: false, contextual_int_to_float: false)
        return true if error_type?(actual_type) || error_type?(expected_type)
        return true if actual_type == expected_type
        return true if null_assignable_to?(actual_type, expected_type)
        return true if external_pointer_null && external_typed_null_pointer_compatibility?(actual_type, expected_type)
        return true if expected_type.is_a?(Types::Nullable) && actual_type == expected_type.base
        return true if mutable_to_const_pointer_compatibility?(actual_type, expected_type)
        return true if string_literal_cstr_compatibility?(expression, expected_type)
        return true if exact_compile_time_numeric_compatibility?(actual_type, expression, expected_type, scopes:)
        return true if integer_to_char_compatibility?(actual_type, expected_type)
        return true if external_numeric && external_numeric_compatibility?(actual_type, expected_type)
        return true if contextual_int_to_float && contextual_int_to_float_compatibility?(actual_type, expected_type)

        false
      end

      def argument_types_compatible?(actual_type, expected_type, external:, expression: nil, scopes: nil, contextual_int_to_float: false)
        return true if types_compatible?(actual_type, expected_type, expression:, scopes:, external_numeric: external, contextual_int_to_float:)
        return true if external && external_void_pointer_argument_compatibility?(actual_type, expected_type)
        return true if external && extern_enum_integer_argument_compatibility?(actual_type, expected_type)
        if external && foreign_mapping_context? && foreign_identity_projection_compatible?(actual_type, expected_type)
          return false if actual_type == @types.fetch("cstr") && char_pointer_type?(expected_type)

          return true
        end

        false
      end

      def direct_function_to_proc_argument_compatible?(actual_type, expected_type, expression, scopes)
        return false unless expression
        return false unless actual_type.is_a?(Types::Function) && proc_type?(expected_type)
        return false unless direct_function_identity_expression?(expression, scopes)

        function_type_matches_proc_type?(actual_type, expected_type)
      end

      def direct_task_to_proc_argument_compatible?(actual_type, expected_type)
        return false unless actual_type.is_a?(Types::Task)
        return false unless task_root_proc_type?(expected_type)

        actual_type == expected_type.return_type
      end

      def direct_function_identity_expression?(expression, scopes)
        case expression
        when AST::Identifier
          return false if lookup_value(expression.name, scopes)
          return false unless @top_level_functions.key?(expression.name)

          binding = @top_level_functions.fetch(expression.name)
          !binding.type_params.any? && !foreign_function_binding?(binding)
        when AST::MemberAccess
          return false unless expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)

          imported_module = @imports.fetch(expression.receiver.name)
          return false unless imported_module.functions.key?(expression.member)

          binding = imported_module.functions.fetch(expression.member)
          !binding.type_params.any? && !foreign_function_binding?(binding)
        when AST::Specialization
          binding = resolve_specialized_function_binding(expression)
          binding && !foreign_function_binding?(binding)
        else
          false
        end
      end

      def external_void_pointer_argument_compatibility?(actual_type, expected_type)
        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          return external_void_pointer_argument_compatibility?(actual_type.base, expected_type.base)
        end

        return external_void_pointer_argument_compatibility?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
        return false if actual_type.is_a?(Types::Nullable)
        return false unless pointer_type?(actual_type) && pointer_type?(expected_type)
        return false if const_pointer_type?(actual_type) && mutable_pointer_type?(expected_type)

        actual_pointee = pointee_type(actual_type)
        expected_pointee = pointee_type(expected_type)

        actual_pointee == @types.fetch("void") || expected_pointee == @types.fetch("void")
      end

      def exact_compile_time_numeric_compatibility?(actual_type, expression, expected_type, scopes: nil)
        return false unless expected_type.is_a?(Types::Primitive) && expected_type.numeric?
        return false if actual_type.is_a?(Types::EnumBase)

        value = evaluate_compile_time_const_value(expression, scopes:)
        return false unless value.is_a?(Numeric)

        numeric_constant_fits_type?(value, expected_type)
      end

      def extern_enum_integer_argument_compatibility?(actual_type, expected_type)
        return unless actual_type.is_a?(Types::EnumBase)
        return unless expected_type.is_a?(Types::Primitive) && expected_type.integer? && expected_type.fixed_width_integer?

        backing_type = actual_type.backing_type
        return unless backing_type.is_a?(Types::Primitive) && backing_type.integer? && backing_type.fixed_width_integer?

        backing_type.integer_width == expected_type.integer_width
      end

      def common_numeric_type(left_type, right_type)
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.numeric? && right_type.numeric?
        return left_type if left_type == right_type

        return common_integer_type(left_type, right_type) if left_type.integer? && right_type.integer?
        return wider_float_type(left_type, right_type) if left_type.float? && right_type.float?

        float_type, integer_type = left_type.float? ? [left_type, right_type] : [right_type, left_type]
        return unless integer_type.integer? && integer_type.fixed_width_integer?

        float_type
      end

      def common_integer_type(left_type, right_type)
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.integer? && right_type.integer?
        return left_type if left_type == right_type
        return unless left_type.fixed_width_integer? && right_type.fixed_width_integer?
        return unless left_type.signed_integer? == right_type.signed_integer?

        left_type.integer_width >= right_type.integer_width ? left_type : right_type
      end

      def wider_float_type(left_type, right_type)
        left_type.float_width >= right_type.float_width ? left_type : right_type
      end

      def with_unsafe
        @unsafe_depth += 1
        yield
      ensure
        @unsafe_depth -= 1
      end

      def mark_current_unsafe_required!
        current_line = @unsafe_statement_lines.last
        return unless current_line

        @required_unsafe_lines << current_line
      end

      def require_unsafe!(message, line: nil, column: nil)
        if unsafe_context?
          mark_current_unsafe_required!
          return
        end

        if line || column
          raise SemaError.new(message, line:, column:)
        end

        raise_sema_error(message)
      end

      def with_foreign_mapping_context
        @foreign_mapping_depth += 1
        yield
      ensure
        @foreign_mapping_depth -= 1
      end

      def with_async_function
        @async_function_depth += 1
        yield
      ensure
        @async_function_depth -= 1
      end

      def with_loop
        @loop_depth += 1
        yield
      ensure
        @loop_depth -= 1
      end

      def with_loop_barrier
        previous_loop_depth = @loop_depth
        @loop_depth = 0
        yield
      ensure
        @loop_depth = previous_loop_depth
      end

      def unsafe_context?
        @unsafe_depth.positive?
      end

      def inside_async_function?
        @async_function_depth.positive?
      end

      def inside_loop?
        @loop_depth.positive?
      end

      def foreign_mapping_context?
        @foreign_mapping_depth.positive?
      end

      def validate_async_function_body!(statements)
        statements.each { |statement| validate_async_statement!(statement) }
      end

      def validate_async_statement!(statement)
        case statement
        when AST::ErrorBlockStmt
          if statement.header_expression
            context = case statement.header_type
                      when :if then "if conditions"
                      when :while then "while conditions"
                      end
            validate_async_expression_support!(statement.header_expression, context:) if context
          end
          if statement.header_type == :for
            Array(statement.header_iterables).each do |iterable|
              validate_async_expression_support!(iterable, context: "for iterables")
            end
          end
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::ErrorStmt
          nil
        when AST::LocalDecl
          validate_async_expression_support!(statement.value, context: "local initializer") if statement.value
          statement.else_body&.each { |s| validate_async_statement!(s) }
        when AST::Assignment
          validate_async_expression_support!(statement.target, context: "assignment target")
          validate_async_expression_support!(statement.value, context: "assignment")
        when AST::ExpressionStmt
          validate_async_expression_support!(statement.expression, context: "expression statement")
        when AST::ReturnStmt
          return unless statement.value

          validate_async_expression_support!(statement.value, context: "return statement")
        when AST::IfStmt
          statement.branches.each do |branch|
            validate_async_expression_support!(branch.condition, context: "if conditions")

            branch.body.each { |s| validate_async_statement!(s) }
          end
          statement.else_body&.each { |s| validate_async_statement!(s) }
        when AST::WhileStmt
          validate_async_expression_support!(statement.condition, context: "while conditions")

          statement.body.each { |s| validate_async_statement!(s) }
        when AST::ForStmt
          statement.iterables.each do |iterable|
            validate_async_expression_support!(iterable, context: "for iterables")
          end

          statement.body.each { |s| validate_async_statement!(s) }
        when AST::MatchStmt
          validate_async_expression_support!(statement.expression, context: "match discriminants")

          statement.arms.each { |arm| arm.body.each { |s| validate_async_statement!(s) } }
        when AST::UnsafeStmt
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::DeferStmt
          validate_async_expression_support!(statement.expression, context: "defer cleanup") if statement.expression
          statement.body&.each { |s| validate_async_statement!(s) }
        when AST::BreakStmt, AST::ContinueStmt, AST::StaticAssert, AST::PassStmt
          nil
        else
          raise_sema_error("async functions currently only support straight-line local declarations, assignments, expression statements, and return statements")
        end
      end

      def validate_async_expression_support!(expression, context:)
        unsupported_context = unsupported_async_await_context(expression)
        return unless unsupported_context

        raise_sema_error("await in async functions is not supported inside #{unsupported_context} yet")
      end

      def unsupported_async_await_context(expression)
        case expression
        when AST::AwaitExpr
          nil
        when AST::Call, AST::Specialization
          unsupported_async_await_context(expression.callee) || expression.arguments.filter_map { |argument| unsupported_async_await_context(argument.value) }.first
        when AST::UnaryOp
          unsupported_async_await_context(expression.operand)
        when AST::BinaryOp
          unsupported_async_await_context(expression.left) || unsupported_async_await_context(expression.right)
        when AST::IfExpr
          unsupported_async_await_context(expression.condition) ||
            unsupported_async_await_context(expression.then_expression) ||
            unsupported_async_await_context(expression.else_expression)
        when AST::MatchExpr
          unsupported_async_await_context(expression.expression) ||
            expression.arms.filter_map { |arm| unsupported_async_await_context(arm.pattern) || unsupported_async_await_context(arm.value) }.first
        when AST::UnsafeExpr
          unsupported_async_await_context(expression.expression)
        when AST::MemberAccess
          unsupported_async_await_context(expression.receiver)
        when AST::IndexAccess
          unsupported_async_await_context(expression.receiver) || unsupported_async_await_context(expression.index)
        when AST::FormatString
          expression.parts.filter_map do |part|
            next unless part.is_a?(AST::FormatExprPart)

            unsupported_async_await_context(part.expression)
          end.first
        else
          nil
        end
      end

      def statement_contains_await?(statement)
        case statement
        when AST::ErrorBlockStmt
          (statement.header_expression && expression_contains_await?(statement.header_expression)) ||
            Array(statement.header_iterables).any? { |iterable| expression_contains_await?(iterable) } ||
            statements_contain_await?(statement.body)
        when AST::LocalDecl
          (statement.value && expression_contains_await?(statement.value)) ||
            (statement.else_body && statements_contain_await?(statement.else_body))
        when AST::Assignment
          expression_contains_await?(statement.target) || expression_contains_await?(statement.value)
        when AST::IfStmt
          statement.branches.any? { |branch| expression_contains_await?(branch.condition) || statements_contain_await?(branch.body) } ||
            (statement.else_body && statements_contain_await?(statement.else_body))
        when AST::MatchStmt
          expression_contains_await?(statement.expression) || statement.arms.any? { |arm| expression_contains_await?(arm.pattern) || statements_contain_await?(arm.body) }
        when AST::UnsafeStmt
          statements_contain_await?(statement.body)
        when AST::StaticAssert
          expression_contains_await?(statement.condition) || expression_contains_await?(statement.message)
        when AST::ForStmt
          statement.iterables.any? { |iterable| expression_contains_await?(iterable) } || statements_contain_await?(statement.body)
        when AST::WhileStmt
          expression_contains_await?(statement.condition) || statements_contain_await?(statement.body)
        when AST::ReturnStmt
          statement.value && expression_contains_await?(statement.value)
        when AST::DeferStmt
          (statement.expression && expression_contains_await?(statement.expression)) || (statement.body && statements_contain_await?(statement.body))
        when AST::ExpressionStmt
          expression_contains_await?(statement.expression)
        else
          false
        end
      end

      def statements_contain_await?(statements)
        statements.any? { |statement| statement_contains_await?(statement) }
      end

      def await_expression?(expression)
        expression.is_a?(AST::AwaitExpr)
      end

      def expression_contains_await?(expression)
        case expression
        when AST::AwaitExpr
          true
        when AST::Call, AST::Specialization
          expression_contains_await?(expression.callee) || expression.arguments.any? { |argument| expression_contains_await?(argument.value) }
        when AST::UnaryOp
          expression_contains_await?(expression.operand)
        when AST::BinaryOp
          expression_contains_await?(expression.left) || expression_contains_await?(expression.right)
        when AST::IfExpr
          expression_contains_await?(expression.condition) || expression_contains_await?(expression.then_expression) || expression_contains_await?(expression.else_expression)
        when AST::MatchExpr
          expression_contains_await?(expression.expression) || expression.arms.any? { |arm| expression_contains_await?(arm.pattern) || expression_contains_await?(arm.value) }
        when AST::UnsafeExpr
          expression_contains_await?(expression.expression)
        when AST::MemberAccess
          expression_contains_await?(expression.receiver)
        when AST::IndexAccess
          expression_contains_await?(expression.receiver) || expression_contains_await?(expression.index)
        when AST::FormatString
          expression.parts.any? { |part| part.is_a?(AST::FormatExprPart) && expression_contains_await?(part.expression) }
        else
          false
        end
      end

      def pointer_arithmetic_result(operator, left_type, right_type)
        if pointer_type?(left_type) && integer_type?(right_type)
          require_unsafe!("pointer arithmetic requires unsafe")

          return left_type if operator == "+" || operator == "-"
        end

        if operator == "+" && integer_type?(left_type) && pointer_type?(right_type)
          require_unsafe!("pointer arithmetic requires unsafe")

          return right_type
        end

        nil
      end

      def pointer_cast?(source_type, target_type)
        pointer_cast_type?(source_type) && pointer_cast_type?(target_type)
      end

      def ref_to_pointer_cast?(source_type, target_type)
        ref_type?(source_type) && pointer_cast_type?(target_type)
      end

      def pointer_cast_type?(type)
        return typed_null_target_type?(type.target_type) if type.is_a?(Types::Null)
        return true if type == @types.fetch("cstr")
        if type.is_a?(Types::Nullable)
          return true if function_pointer_type?(type.base)

          return pointer_type?(type.base)
        end

        return true if function_pointer_type?(type)

        pointer_type?(type)
      end

      def typed_null_target_type?(type)
        type == @types.fetch("cstr") || pointer_type?(type) || function_pointer_type?(type)
      end

      def pointer_type?(type)
        mutable_pointer_type?(type) || const_pointer_type?(type)
      end

      def mutable_pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
      end

      def const_pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "const_ptr" && type.arguments.length == 1
      end

      def function_pointer_type?(type)
        type.is_a?(Types::Function)
      end

      def ref_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ref" && type.arguments.length == 1
      end

      def span_type?(type)
        type.is_a?(Types::Span)
      end

      def string_view_type?(type)
        type.is_a?(Types::StringView)
      end

      def task_type?(type)
        type.is_a?(Types::Task)
      end

      def infer_layout_query_type(type_ref, context:)
        type = resolve_type_ref(type_ref)
        return type if sized_layout_type?(type)

        raise_sema_error("#{context} requires a concrete sized type, got #{type}")
      end

      def infer_offsetof_type(type_ref, field_name)
        type = resolve_type_ref(type_ref)
        unless layout_aggregate_type?(type)
          raise_sema_error("offset_of requires a struct, union, span, or str type, got #{type}")
        end

        field_type = type.field(field_name)
        raise_sema_error("unknown field #{type}.#{field_name}") unless field_type

        type
      end

      def sized_layout_type?(type)
        case type
        when Types::Primitive, Types::Struct, Types::StructInstance, Types::Union, Types::Enum, Types::Flags, Types::Variant, Types::Span, Types::StringView, Types::Task
          true
        when Types::Nullable
          true
        when Types::GenericInstance
          pointer_type?(type) || array_type?(type) || str_buffer_type?(type)
        else
          false
        end
      end

      def reinterpretable_type?(type)
        return false if array_type?(type)
        return false if type.is_a?(Types::Primitive) && type.void?

        sized_layout_type?(type)
      end

      def zero_initializable_type?(type, operation: "zero")
        return true if type.is_a?(Types::Primitive) && !type.void?
        return true if type.is_a?(Types::Nullable)
        return true if type.is_a?(Types::EnumBase)
        return true if span_type?(type)
        return true if string_view_type?(type)
        return true if task_type?(type)
        return true if type.is_a?(Types::Struct)
        return true if type.is_a?(Types::Variant)
        return true if pointer_type?(type)
        return true if type.is_a?(Types::Opaque) && !type.external
        return true if array_type?(type)
        return true if str_buffer_type?(type)

        raise_sema_error("#{operation} does not support type #{type}")
      end

      def layout_aggregate_type?(type)
        type.respond_to?(:field) && !type.is_a?(Types::Opaque) && !type.is_a?(Types::EnumBase)
      end

      def power_of_two?(value)
        (value & (value - 1)).zero?
      end

      def aggregate_type?(type)
        type.is_a?(Types::Struct) || span_type?(type) || string_view_type?(type) || task_type?(type)
      end

      def array_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
          !type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments[1].is_a?(Types::LiteralTypeArg)
      end

      def array_element_type(type)
        return unless array_type?(type)

        type.arguments.first
      end

      def array_length(type)
        return unless array_type?(type)

        type.arguments[1].value
      end

      def char_array_text_type?(type)
        array_type?(type) && array_element_type(type) == @types.fetch("char")
      end

      def str_buffer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1 &&
          generic_integer_type_argument?(type.arguments.first)
      end

      def str_buffer_capacity(type)
        type.arguments.first.value
      end

      def integer_type_argument?(argument)
        argument.is_a?(Types::LiteralTypeArg) && argument.value.is_a?(Integer)
      end

      def generic_integer_type_argument?(argument)
        integer_type_argument?(argument) || argument.is_a?(Types::TypeVar)
      end

      def pointee_type(type)
        return unless pointer_type?(type)

        type.arguments.first
      end

      def referenced_type(type)
        return unless ref_type?(type)

        type.arguments.first
      end

      def pointer_to(type)
        Types::GenericInstance.new("ptr", [type])
      end

      def const_pointer_to(type)
        Types::GenericInstance.new("const_ptr", [type])
      end

      def contains_ref_type?(type)
        case type
        when Types::Nullable
          contains_ref_type?(type.base)
        when Types::GenericInstance
          return true if ref_type?(type)

          type.arguments.any? { |argument| !argument.is_a?(Types::LiteralTypeArg) && contains_ref_type?(argument) }
        when Types::Span
          contains_ref_type?(type.element_type)
        when Types::Task
          contains_ref_type?(type.result_type)
        when Types::StructInstance
          type.arguments.any? { |argument| contains_ref_type?(argument) }
        when Types::VariantInstance
          type.arguments.any? { |argument| contains_ref_type?(argument) }
        when Types::Proc
          type.params.any? { |param| contains_ref_type?(param.type) } || contains_ref_type?(type.return_type)
        when Types::Function
          type.params.any? { |param| contains_ref_type?(param.type) } ||
            contains_ref_type?(type.return_type) ||
            (type.receiver_type && contains_ref_type?(type.receiver_type))
        else
          false
        end
      end

      def contains_type_var?(type)
        case type
        when Types::TypeVar
          true
        when Types::Nullable
          contains_type_var?(type.base)
        when Types::GenericInstance
          type.arguments.any? { |argument| !argument.is_a?(Types::LiteralTypeArg) && contains_type_var?(argument) }
        when Types::Span
          contains_type_var?(type.element_type)
        when Types::Task
          contains_type_var?(type.result_type)
        when Types::StructInstance
          type.arguments.any? { |argument| contains_type_var?(argument) }
        when Types::VariantInstance
          type.arguments.any? { |argument| contains_type_var?(argument) }
        when Types::Proc
          type.params.any? { |param| contains_type_var?(param.type) } || contains_type_var?(type.return_type)
        when Types::Function
          type.params.any? { |param| contains_type_var?(param.type) } ||
            contains_type_var?(type.return_type) ||
            (type.receiver_type && contains_type_var?(type.receiver_type))
        else
          false
        end
      end

      def resolve_named_generic_type(parts)
        if parts.length == 1
          type = @types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        elsif parts.length == 2 && @imports.key?(parts.first)
          type = @imports.fetch(parts.first).types[parts.last]
          return type if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
        end

        nil
      end

      BUILTIN_VALUE_SPECIALIZATIONS = %w[zero default reinterpret cast].freeze

      def type_ref_from_specialization(expression)
        case expression.callee
        when AST::Identifier
          return nil if BUILTIN_VALUE_SPECIALIZATIONS.include?(expression.callee.name)

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

      def aggregate_display_name(type)
        type.is_a?(Types::StructInstance) ? type.to_s : type.name
      end

      def validate_generic_type!(name, arguments)
        case name
        when "ptr"
          raise_sema_error("ptr requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("ptr type argument must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
        when "const_ptr"
          raise_sema_error("const_ptr requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("const_ptr type argument must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
          raise_sema_error("const_ptr cannot target ref types") if contains_ref_type?(arguments.first)
        when "ref"
          raise_sema_error("ref requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("ref type argument must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
          raise_sema_error("ref cannot target void") if arguments.first.is_a?(Types::Primitive) && arguments.first.void?
          raise_sema_error("ref cannot target another ref type") if contains_ref_type?(arguments.first)
        when "span"
          raise_sema_error("span requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("span element type must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
        when "array"
          raise_sema_error("array requires exactly two type arguments") unless arguments.length == 2
          raise_sema_error("array element type must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
          raise_sema_error("array length must be an integer literal, named const, or type parameter") unless generic_integer_type_argument?(arguments[1])
          raise_sema_error("array length must be positive") if integer_type_argument?(arguments[1]) && !arguments[1].value.positive?
        when "str_buffer"
          raise_sema_error("str_buffer requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("str_buffer capacity must be an integer literal, named const, or type parameter") unless generic_integer_type_argument?(arguments.first)
          raise_sema_error("str_buffer capacity must be positive") if integer_type_argument?(arguments.first) && !arguments.first.value.positive?
        when "Task"
          raise_sema_error("Task requires exactly one type argument") unless arguments.length == 1
          raise_sema_error("Task result type must be a type") if arguments.first.is_a?(Types::LiteralTypeArg)
        else
          raise_sema_error("unknown generic type #{name}")
        end
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def range_expr?(expression)
        expression.is_a?(AST::RangeExpr)
      end

      def collection_loop_type(type)
        return array_element_type(type) if array_type?(type)
        return type.element_type if span_type?(type)

        nil
      end

      def collection_loop_binding_type(iterable_type, element_type)
        return nil unless array_type?(iterable_type) || span_type?(iterable_type)
        return nil unless collection_loop_ref_element_type?(element_type)

        Types::GenericInstance.new("ref", [element_type])
      end

      def collection_loop_ref_element_type?(type)
        type.is_a?(Types::Struct)
      end

      def iterator_loop_type(type)
        iter_method = lookup_method(type, "iter")
        return nil unless iter_method

        iter_method = instantiate_function_binding_with_receiver(iter_method, [], receiver_type: type) if iter_method.type_params.any?

        unless iter_method.type.params.empty?
          raise_sema_error("for iterator #{type}.iter expects 0 arguments")
        end
        if iter_method.type.receiver_mutable
          raise_sema_error("for iterator #{type}.iter cannot be a mutable method")
        end

        iterator_type = iter_method.type.return_type
        next_method = lookup_method(iterator_type, "next")
        raise_sema_error("for iterator #{iterator_type} must define next()") unless next_method
        next_method = instantiate_function_binding_with_receiver(next_method, [], receiver_type: iterator_type) if next_method.type_params.any?
        unless next_method.type.params.empty?
          raise_sema_error("for iterator #{iterator_type}.next expects 0 arguments")
        end

        next_type = next_method.type.return_type
        if next_type.is_a?(Types::Nullable) && typed_null_target_type?(next_type.base)
          return next_type.base
        end

        if next_type == @types.fetch("bool")
          current_method = lookup_method(iterator_type, "current")
          raise_sema_error("for iterator #{iterator_type} must define current() when next() returns bool") unless current_method
          current_method = instantiate_function_binding_with_receiver(current_method, [], receiver_type: iterator_type) if current_method.type_params.any?
          unless current_method.type.params.empty?
            raise_sema_error("for iterator #{iterator_type}.current expects 0 arguments")
          end
          raise_sema_error("for iterator #{iterator_type}.current cannot return void") if current_method.type.return_type == @types.fetch("void")

          return current_method.type.return_type
        end

        raise_sema_error("for iterator #{iterator_type}.next must return bool or a nullable pointer-like item, got #{next_type}")
      end

      def string_like_type?(type)
        type == @types.fetch("str") || type == @types.fetch("cstr")
      end

      def infer_index_result_type(receiver_type, index_type)
        raise_sema_error("index must be an integer type, got #{index_type}") unless integer_type?(index_type)

        if array_type?(receiver_type)
          return array_element_type(receiver_type)
        end

        if span_type?(receiver_type)
          return receiver_type.element_type
        end

        if pointer_type?(receiver_type)
          require_unsafe!("pointer indexing requires unsafe")

          return pointee_type(receiver_type)
        end

        raise_sema_error("cannot index #{receiver_type}")
      end

      def addressable_storage_expression?(expression, scopes:)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          addressable_storage_expression?(expression.receiver, scopes:)
        when AST::Call
          return false unless expression.arguments.length == 1 && expression.arguments.first.name.nil?

          read_call?(expression) && ref_type?(infer_expression(expression.arguments.first.value, scopes:))
        else
          false
        end
      end

      def match_member_name(expression, enum_type)
        return unless expression.is_a?(AST::MemberAccess)

        receiver_type = resolve_type_expression(expression.receiver)
        return unless receiver_type == enum_type
        return expression.member if enum_type.member(expression.member)

        nil
      end

      def resolve_type_expression(expression)
        case expression
        when AST::Identifier
          return current_type_params[expression.name] if current_type_params.key?(expression.name)

          @types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)
          return nil unless @imports.key?(expression.receiver.name)

          imported_module = @imports.fetch(expression.receiver.name)
          if imported_module.private_type?(expression.member)
            raise_sema_error("#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}")
          end

          imported_module.types[expression.member]
        when AST::Specialization
          type_ref = type_ref_from_specialization(expression)
          return nil unless type_ref

          resolve_type_ref(type_ref)
        end
      end

      def imported_module_with_private_method(receiver_type, method_name)
        imported_module = imported_module_with_private_method_local(receiver_type, method_name)
        return imported_module if imported_module

        fallback_owner = specialization_lookup_owner
        return nil unless fallback_owner

        fallback_owner.send(:imported_module_with_private_method_local, receiver_type, method_name)
      end

      def imported_module_with_private_method_local(receiver_type, method_name)
        @imports.each_value do |module_binding|
          return module_binding if module_binding.private_method?(receiver_type, method_name)
        end

        nil
      end

      def method_dispatch_receiver_type(receiver_type)
        return receiver_type.definition if receiver_type.is_a?(Types::StructInstance)
        if receiver_type.is_a?(Types::Nullable)
          dispatch_base_type = method_dispatch_receiver_type(receiver_type.base)
          return receiver_type if dispatch_base_type == receiver_type.base

          return Types::Nullable.new(dispatch_base_type)
        end
        return receiver_type unless receiver_type.is_a?(Types::GenericInstance)

        dispatch_receiver_type = Types::GenericInstance.new(
          receiver_type.name,
          receiver_type.arguments.each_with_index.map do |argument, index|
            argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
          end,
        )
        dispatch_receiver_type == receiver_type ? receiver_type : dispatch_receiver_type
      end

      def resolve_methods_receiver_target(type_ref)
        if type_ref.is_a?(AST::TypeRef)
          generic_type = resolve_named_generic_type(type_ref.name.parts)
          if generic_type.is_a?(Types::GenericStructDefinition)
            receiver_type_param_names = validate_methods_receiver_type_arguments!(type_ref, generic_type)
            receiver_type_params = receiver_type_param_names.to_h { |name| [name, Types::TypeVar.new(name)] }
            receiver_type_param_constraints = generic_type.type_param_constraints
            receiver_type = resolve_type_ref(type_ref, type_params: receiver_type_params, type_param_constraints: receiver_type_param_constraints)
            return [generic_type, receiver_type, receiver_type_param_names, receiver_type_param_constraints]
          end

          begin
            receiver_type = resolve_type_ref(type_ref)
            unless receiver_type.is_a?(Types::Struct) || receiver_type.is_a?(Types::StructInstance) || receiver_type.is_a?(Types::Opaque) || receiver_type.is_a?(Types::GenericInstance) || receiver_type.is_a?(Types::Nullable) || receiver_type.is_a?(Types::StringView)
              raise_sema_error("extending target #{type_ref} must be a struct, opaque, nullable/generic receiver, or str")
            end

            return [receiver_type, receiver_type, [], {}]
          rescue MilkTea::SemaError => error
            receiver_type_param_names = methods_receiver_type_argument_names!(type_ref)
            raise error if receiver_type_param_names.empty?

            receiver_type_params = receiver_type_param_names.to_h { |name| [name, Types::TypeVar.new(name)] }
            receiver_type = resolve_type_ref(type_ref, type_params: receiver_type_params)
            return [method_dispatch_receiver_type(receiver_type), receiver_type, receiver_type_param_names, {}]
          end
        end

        receiver_type = resolve_type_ref(type_ref)
        unless receiver_type.is_a?(Types::Struct) || receiver_type.is_a?(Types::StructInstance) || receiver_type.is_a?(Types::Opaque) || receiver_type.is_a?(Types::GenericInstance) || receiver_type.is_a?(Types::Nullable) || receiver_type.is_a?(Types::StringView)
          raise_sema_error("extending target #{type_ref} must be a struct, opaque, nullable/generic receiver, or str")
        end

        [receiver_type, receiver_type, [], {}]
      end

      def methods_receiver_type_argument_names!(type_ref)
        names = type_ref.arguments.map do |argument|
          value = argument.value
          next unless value.is_a?(AST::TypeRef)
          next unless value.arguments.empty? && !value.nullable && value.name.parts.length == 1

          value.name.parts.first
        end

        raise_sema_error("extending target #{type_ref} must use the receiver type parameters directly") if names.any?(&:nil?)

        names
      end

      def validate_methods_receiver_type_arguments!(type_ref, generic_type)
        names = type_ref.arguments.map do |argument|
          value = argument.value
          next unless value.is_a?(AST::TypeRef)
          next unless value.arguments.empty? && !value.nullable && value.name.parts.length == 1

          value.name.parts.first
        end

        expected_names = generic_type.type_params
        unless names == expected_names
          raise_sema_error("extending target #{type_ref} must use the receiver type parameters directly")
        end

        expected_names
      end

      def infer_receiver_type_substitutions(binding, receiver_type)
        declared_receiver_type = binding.declared_receiver_type
        return {} unless declared_receiver_type
        case declared_receiver_type
        when Types::Nullable
          unless receiver_type.is_a?(Types::Nullable)
            raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
          end

          infer_receiver_type_substitutions(
            binding.with(declared_receiver_type: declared_receiver_type.base),
            receiver_type.base,
          )
        when Types::StructInstance
          return {} unless declared_receiver_type.definition.is_a?(Types::GenericStructDefinition)

          unless receiver_type.is_a?(Types::StructInstance) && receiver_type.definition == declared_receiver_type.definition
            raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
          end

          declared_receiver_type.definition.type_params.zip(receiver_type.arguments).to_h
        when Types::GenericInstance
          unless receiver_type.is_a?(Types::GenericInstance) && receiver_type.name == declared_receiver_type.name && receiver_type.arguments.length == declared_receiver_type.arguments.length
            raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
          end

          declared_receiver_type.arguments.zip(receiver_type.arguments).each_with_object({}) do |(declared_argument, actual_argument), substitutions|
            if declared_argument.is_a?(Types::TypeVar)
              substitutions[declared_argument.name] = actual_argument
            elsif declared_argument != actual_argument
              raise_sema_error("cannot use method #{binding.name} with receiver #{receiver_type}")
            end
          end
        else
          {}
        end
      end

      def callable_receiver_type_for_specialization(callee, scopes:)
        return unless callee.is_a?(AST::MemberAccess)

        resolve_type_expression(callee.receiver)
      end

      def resolve_type_member(type, name)
        case type
        when Types::Enum, Types::Flags
          type.member(name)
        when Types::Variant
          # No-payload arms: return the variant type so they can be used as expressions
          # Payload arms: return nil here — callers use resolve_callable(:variant_arm_ctor) instead
          return type if type.arm_names.include?(name) && !type.has_payload?(name)

          nil
        end
      end

      def function_type_for_name(name)
        @top_level_functions.fetch(name).type
      end

      def resolve_specialized_callable_binding(expression, scopes:)
        callable_kind = :function
        receiver = nil
        receiver_type = nil
        binding = case expression.callee
                  when AST::Identifier
                    @top_level_functions[expression.callee.name]
                  when AST::MemberAccess
                    if expression.callee.receiver.is_a?(AST::Identifier) && @imports.key?(expression.callee.receiver.name)
                      imported_module = @imports.fetch(expression.callee.receiver.name)
                      imported_function = imported_module.functions[expression.callee.member]
                      if imported_function.nil? && imported_module.private_function?(expression.callee.member)
                        raise_sema_error("#{expression.callee.receiver.name}.#{expression.callee.member} is private to module #{imported_module.name}")
                      end

                      imported_function
                    elsif (type_expr = resolve_type_expression(expression.callee.receiver))
                      associated_function = lookup_method(type_expr, expression.callee.member)
                      if associated_function&.type&.receiver_type.nil?
                        receiver_type = type_expr
                        associated_function
                      else
                        if (imported_module = imported_module_with_private_method(type_expr, expression.callee.member))
                          raise_sema_error("#{type_expr}.#{expression.callee.member} is private to module #{imported_module.name}")
                        end

                        nil
                      end
                    else
                      receiver_type = infer_method_receiver_type(expression.callee.receiver, scopes:, member_name: expression.callee.member)
                      method = lookup_method(receiver_type, expression.callee.member)
                      if method
                        callable_kind = :method
                        receiver = expression.callee.receiver
                        method
                      else
                        if (imported_module = imported_module_with_private_method(receiver_type, expression.callee.member))
                          raise_sema_error("#{receiver_type}.#{expression.callee.member} is private to module #{imported_module.name}")
                        end

                        nil
                      end
                    end
                  end
        return nil unless binding

        type_arguments = resolve_specialization_type_arguments(expression)
        [callable_kind, instantiate_function_binding_with_receiver(binding, type_arguments, receiver_type:), receiver]
      end

      def resolve_specialization_type_arguments(expression)
        expression.arguments.map do |argument|
          resolve_type_argument(argument.value, type_params: current_type_params)
        end
      end

      def specialize_function_binding(binding, arguments, scopes:, receiver_type: nil)
        return binding if binding.type_params.empty?

        type_arguments = infer_function_type_arguments(binding, arguments, scopes:, receiver_type:)
        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding_with_receiver(binding, explicit_type_arguments, receiver_type: nil)
        if binding.type_params.empty?
          raise_sema_error("function #{binding.name} is not generic and cannot be specialized")
        end

        receiver_substitutions = infer_receiver_type_substitutions(binding, receiver_type)
        remaining_type_params = binding.type_params.reject { |name| receiver_substitutions.key?(name) }
        unless remaining_type_params.length == explicit_type_arguments.length
          raise_sema_error("function #{binding.name} expects #{remaining_type_params.length} type arguments, got #{explicit_type_arguments.length}")
        end

        substitutions = receiver_substitutions.dup
        remaining_type_params.zip(explicit_type_arguments).each do |name, type_argument|
          raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types") if contains_ref_type?(type_argument)

          substitutions[name] = type_argument
        end

        type_arguments = binding.type_params.map do |name|
          inferred = substitutions[name]
          raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless inferred

          inferred
        end

        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding(binding, type_arguments)
        if binding.type_params.empty?
          raise_sema_error("function #{binding.name} is not generic and cannot be specialized")
        end

        unless binding.type_params.length == type_arguments.length
          raise_sema_error("function #{binding.name} expects #{binding.type_params.length} type arguments, got #{type_arguments.length}")
        end

        if type_arguments.any? { |type_argument| contains_ref_type?(type_argument) }
          raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types")
        end

        key = type_arguments.freeze
        return binding.instances.fetch(key) if binding.instances.key?(key)

        substitutions = binding.type_params.zip(type_arguments).to_h
        validate_function_type_param_constraints!(binding, substitutions)
        type = substitute_type(binding.type, substitutions)
        body_params = binding.body_params.map { |param| substitute_value_binding(param, substitutions) }
        validate_specialized_function_binding!(binding.name, type, body_params)

        instance = FunctionBinding.new(
          name: binding.name,
          type:,
          body_params:,
          body_return_type: substitute_type(binding.body_return_type, substitutions),
          ast: binding.ast,
          external: binding.external,
          async: binding.async,
          type_params: [].freeze,
          type_param_constraints: {}.freeze,
          instances: {},
          type_arguments: key,
          owner: binding.owner,
          specialization_owner: @current_specialization_owner || (binding.owner == self ? nil : self),
          type_substitutions: substitutions.freeze,
          declared_receiver_type: binding.declared_receiver_type ? substitute_type(binding.declared_receiver_type, substitutions) : nil,
        )
        binding.instances[key] = instance
      end

      def validate_function_type_param_constraints!(binding, substitutions)
        binding.type_param_constraints.each do |name, constraints|
          actual_type = substitutions[name]
          raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless actual_type

          validate_type_param_constraint_binding!(constraints, actual_type, context: "function #{binding.name}")
        end
      end

      def infer_function_type_arguments(binding, arguments, scopes:, receiver_type: nil)
        expected_params = binding.type.params
        unless call_arity_matches?(binding.type, arguments.length)
          raise_sema_error(arity_error_message(binding.type, binding.name, arguments.length))
        end

        substitutions = infer_receiver_type_substitutions(binding, receiver_type)
        expected_params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          expected_argument_type = if callable_type?(parameter.type)
                                     candidate_type = substitute_type(parameter.type, substitutions)
                                     callable_type?(candidate_type) ? candidate_type : (contains_type_var?(candidate_type) ? nil : candidate_type)
                                   end
          actual_type = foreign_argument_actual_type(parameter, argument, scopes:, function_name: binding.name, expected_type: expected_argument_type)
          collect_type_substitutions(parameter.type, actual_type, substitutions, binding.name)
        end

        binding.type_params.map do |name|
          inferred = substitutions[name]
          raise_sema_error("cannot infer type argument #{name} for function #{binding.name}") unless inferred

          raise_sema_error("generic function #{binding.name} cannot be instantiated with ref types") if contains_ref_type?(inferred)

          inferred
        end
      end

      def collect_type_substitutions(pattern_type, actual_type, substitutions, function_name)
        case pattern_type
        when Types::TypeVar
          existing = substitutions[pattern_type.name]
          if existing && existing != actual_type
            raise_sema_error("conflicting type argument #{pattern_type.name} for function #{function_name}: got #{existing} and #{actual_type}")
          end

          substitutions[pattern_type.name] ||= actual_type
        when Types::Nullable
          candidate = actual_type.is_a?(Types::Nullable) ? actual_type.base : actual_type
          collect_type_substitutions(pattern_type.base, candidate, substitutions, function_name)
        when Types::GenericInstance
          if ref_type?(pattern_type) && !ref_type?(actual_type)
            collect_type_substitutions(referenced_type(pattern_type), actual_type, substitutions, function_name)
            return
          end

          return unless actual_type.is_a?(Types::GenericInstance)
          return unless actual_type.name == pattern_type.name && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            next if expected_argument.is_a?(Types::LiteralTypeArg)

            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Span
          return unless actual_type.is_a?(Types::Span)

          collect_type_substitutions(pattern_type.element_type, actual_type.element_type, substitutions, function_name)
        when Types::Task
          return unless actual_type.is_a?(Types::Task)

          collect_type_substitutions(pattern_type.result_type, actual_type.result_type, substitutions, function_name)
        when Types::Proc
          if task_root_proc_type?(pattern_type) && actual_type.is_a?(Types::Task)
            collect_type_substitutions(pattern_type.return_type, actual_type, substitutions, function_name)
            return
          end

          actual_params = case actual_type
                          when Types::Proc
                            return unless actual_type.params.length == pattern_type.params.length

                            actual_type.params
                          when Types::Function
                            return if actual_type.receiver_type || actual_type.variadic
                            return unless actual_type.params.length == pattern_type.params.length

                            actual_type.params
                          else
                            return
                          end

          pattern_type.params.zip(actual_params).each do |expected_param, actual_param|
            collect_type_substitutions(expected_param.type, actual_param.type, substitutions, function_name)
          end
          collect_type_substitutions(pattern_type.return_type, actual_type.return_type, substitutions, function_name)
        when Types::StructInstance
          return unless actual_type.is_a?(Types::StructInstance)
          return unless actual_type.definition == pattern_type.definition && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::VariantInstance
          return unless actual_type.is_a?(Types::VariantInstance)
          return unless actual_type.definition == pattern_type.definition && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Function
          return unless actual_type.is_a?(Types::Function)
          return unless actual_type.params.length == pattern_type.params.length

          pattern_type.params.zip(actual_type.params).each do |expected_param, actual_param|
            collect_type_substitutions(expected_param.type, actual_param.type, substitutions, function_name)
          end
          collect_type_substitutions(pattern_type.return_type, actual_type.return_type, substitutions, function_name)
        end
      end

      def substitute_value_binding(binding, substitutions)
        ValueBinding.new(
          id: binding.id,
          name: binding.name,
          storage_type: substitute_type(binding.storage_type, substitutions),
          flow_type: binding.flow_type ? substitute_type(binding.flow_type, substitutions) : nil,
          mutable: binding.mutable,
          kind: binding.kind,
          const_value: binding.const_value,
        )
      end

      def validate_specialized_function_binding!(function_name, function_type, body_params)
        function_type.params.each do |param|
          validate_specialized_function_type!(param.type, function_name:, context: "parameter #{param.name}")
          validate_specialized_function_type!(param.boundary_type, function_name:, context: "boundary parameter #{param.name}") if param.boundary_type
        end
        validate_specialized_function_type!(function_type.return_type, function_name:, context: "return type")
        validate_specialized_function_type!(function_type.receiver_type, function_name:, context: "receiver type") if function_type.receiver_type

        body_params.each do |param|
          validate_specialized_function_type!(param.type, function_name:, context: "body parameter #{param.name}")
        end
      end

      def validate_specialized_function_type!(type, function_name:, context:)
        case type
        when nil, Types::Primitive, Types::Enum, Types::Flags, Types::Opaque, Types::Struct
          nil
        when Types::LiteralTypeArg
          raise_sema_error("#{context} of function #{function_name} must be a type, got #{type}")
        when Types::TypeVar
          raise_sema_error("cannot infer type argument #{type.name} for function #{function_name}")
        when Types::Nullable
          validate_specialized_function_type!(type.base, function_name:, context:)
        when Types::GenericInstance
          validate_generic_type!(type.name, type.arguments)
          type.arguments.each do |argument|
            next if argument.is_a?(Types::LiteralTypeArg)

            validate_specialized_function_type!(argument, function_name:, context:)
          end
        when Types::Span
          validate_specialized_function_type!(type.element_type, function_name:, context:)
        when Types::Task
          validate_specialized_function_type!(type.result_type, function_name:, context:)
        when Types::Proc
          type.params.each do |param|
            validate_specialized_function_type!(param.type, function_name:, context: "#{context} parameter #{param.name}")
          end
          validate_specialized_function_type!(type.return_type, function_name:, context: "#{context} return type")
        when Types::StructInstance
          type.arguments.each do |argument|
            next if argument.is_a?(Types::LiteralTypeArg)

            validate_specialized_function_type!(argument, function_name:, context:)
          end
        when Types::Function
          type.params.each do |param|
            validate_specialized_function_type!(param.type, function_name:, context: "#{context} parameter #{param.name}")
            validate_specialized_function_type!(param.boundary_type, function_name:, context: "#{context} boundary parameter #{param.name}") if param.boundary_type
          end
          validate_specialized_function_type!(type.return_type, function_name:, context: "#{context} return type")
          validate_specialized_function_type!(type.receiver_type, function_name:, context: "#{context} receiver type") if type.receiver_type
        end
      end

      def substitute_type(type, substitutions)
        case type
        when Types::TypeVar
          substitutions.fetch(type.name, type)
        when Types::Nullable
          Types::Nullable.new(substitute_type(type.base, substitutions))
        when Types::GenericInstance
          Types::GenericInstance.new(
            type.name,
            type.arguments.map { |argument| argument.is_a?(Types::LiteralTypeArg) ? argument : substitute_type(argument, substitutions) },
          )
        when Types::Span
          Types::Span.new(substitute_type(type.element_type, substitutions))
        when Types::Task
          Types::Task.new(substitute_type(type.result_type, substitutions))
        when Types::Proc
          Types::Proc.new(
            params: type.params.map do |param|
              Types::Parameter.new(
                param.name,
                substitute_type(param.type, substitutions),
                mutable: param.mutable,
                passing_mode: param.passing_mode,
                boundary_type: param.boundary_type ? substitute_type(param.boundary_type, substitutions) : nil,
              )
            end,
            return_type: substitute_type(type.return_type, substitutions),
          )
        when Types::StructInstance
          type.definition.instantiate(type.arguments.map { |argument| substitute_type(argument, substitutions) })
        when Types::VariantInstance
          type.definition.instantiate(type.arguments.map { |argument| substitute_type(argument, substitutions) })
        when Types::Function
          Types::Function.new(
            type.name,
            params: type.params.map do |param|
              Types::Parameter.new(
                param.name,
                substitute_type(param.type, substitutions),
                mutable: param.mutable,
                passing_mode: param.passing_mode,
                boundary_type: param.boundary_type ? substitute_type(param.boundary_type, substitutions) : nil,
              )
            end,
            return_type: substitute_type(type.return_type, substitutions),
            receiver_type: type.receiver_type ? substitute_type(type.receiver_type, substitutions) : nil,
            receiver_mutable: type.receiver_mutable,
            variadic: type.variadic,
            external: type.external,
          )
        else
          type
        end
      end

      def bitwise_type?(type)
        type.respond_to?(:bitwise?) && type.bitwise?
      end

      def callable_type?(type)
        type.is_a?(Types::Function) || type.is_a?(Types::Proc)
      end

      def proc_type?(type)
        type.is_a?(Types::Proc)
      end

      def proc_type_compatible?(actual_type, expected_type)
        return true unless expected_type
        return actual_type == expected_type if proc_type?(expected_type)

        false
      end

      def proc_expression_allowed?
        @proc_expression_depth.positive?
      end

      def with_proc_expression
        @proc_expression_depth += 1
        yield
      ensure
        @proc_expression_depth -= 1
      end

      def freeze_scope_bindings(scope)
        frozen_scope = scope.is_a?(FlowScope) ? FlowScope.new : {}
        scope.each do |name, binding|
          frozen_scope[name] = ValueBinding.new(
            id: binding.id,
            name: binding.name,
            storage_type: binding.storage_type,
            flow_type: binding.flow_type,
            mutable: false,
            kind: binding.kind,
            const_value: binding.const_value,
          )
        end
        frozen_scope
      end

      def validate_stored_ref_type!(type, context)
        raise_sema_error("#{context} cannot store ref types") if contains_ref_type?(type)
      end

      def contains_proc_type?(type, visited = {})
        return false unless type

        visit_key = [type.class, type.object_id]
        return false if visited[visit_key]

        visited[visit_key] = true
        case type
        when Types::Nullable
          contains_proc_type?(type.base, visited)
        when Types::GenericInstance
          if type.name == "array" && type.arguments.first && !type.arguments.first.is_a?(Types::LiteralTypeArg)
            contains_proc_type?(type.arguments.first, visited)
          else
            false
          end
        when Types::Span
          contains_proc_type?(type.element_type, visited)
        when Types::Task
          contains_proc_type?(type.result_type, visited)
        when Types::StructInstance
          type.arguments.any? { |argument| contains_proc_type?(argument, visited) }
        when Types::Struct, Types::Union
          type.fields.each_value.any? { |field_type| contains_proc_type?(field_type, visited) }
        when Types::Variant
          type.arm_names.any? { |arm_name| type.arm(arm_name).each_value.any? { |field_type| contains_proc_type?(field_type, visited) } }
        when Types::Proc
          true
        when Types::Function
          type.params.any? { |param| contains_proc_type?(param.type, visited) } ||
            contains_proc_type?(type.return_type, visited) ||
            (type.receiver_type && contains_proc_type?(type.receiver_type, visited))
        else
          false
        end
      end

      def proc_storage_supported_type?(type, visited = {})
        return true unless contains_proc_type?(type)

        visit_key = [type.class, type.object_id]
        return true if visited[visit_key]

        visited[visit_key] = true
        case type
        when Types::Proc
          true
        when Types::Struct
          type.fields.each_value.all? { |field_type| proc_storage_supported_type?(field_type, visited) }
        when Types::StructInstance
          type.arguments.all? { |argument| argument.is_a?(Types::LiteralTypeArg) || proc_storage_supported_type?(argument, visited) }
        when Types::Variant
          type.arm_names.all? { |arm_name| type.arm(arm_name).each_value.all? { |field_type| proc_storage_supported_type?(field_type, visited) } }
        when Types::Nullable
          proc_storage_supported_type?(type.base, visited)
        else
          false
        end
      end

      def validate_stored_proc_type!(type, context)
        if contains_proc_type?(type)
          raise_sema_error("#{context} cannot store proc values") unless proc_storage_supported_type?(type)
        end
      end

      def validate_parameter_ref_type!(type, function_name:, parameter_name:, external:)
        if ref_type?(type)
          raise_sema_error("external function #{function_name} cannot take ref parameters") if external

          return
        end

        return if callable_param_ref_supported?(type)

        raise_sema_error("parameter #{parameter_name} of #{function_name} cannot nest ref types") if contains_ref_type?(type)
      end

      def callable_param_ref_supported?(type)
        case type
        when Types::Proc
          type.params.all? { |param| ref_type?(param.type) || !contains_ref_type?(param.type) } &&
            !contains_ref_type?(type.return_type)
        when Types::Function
          type.params.all? { |param| ref_type?(param.type) || !contains_ref_type?(param.type) } &&
            !contains_ref_type?(type.return_type) &&
            (type.receiver_type.nil? || !contains_ref_type?(type.receiver_type))
        else
          false
        end
      end

      def validate_parameter_proc_type!(type, function_name:, parameter_name:, external:, foreign:)
        if contains_proc_type?(type)
          raise_sema_error("external function #{function_name} cannot take proc parameters") if external
          raise_sema_error("foreign function #{function_name} cannot take proc parameters") if foreign
          raise_sema_error("parameter #{parameter_name} of #{function_name} uses unsupported proc nesting") unless proc_storage_supported_type?(type)
        end
      end

      def validate_return_ref_type!(type, function_name:)
        raise_sema_error("function #{function_name} cannot return ref types") if contains_ref_type?(type)
      end

      def validate_return_proc_type!(type, function_name:)
        if contains_proc_type?(type)
          raise_sema_error("function #{function_name} uses unsupported proc nesting in return type") unless proc_storage_supported_type?(type)
        end
      end

      def validate_local_ref_type!(type, local_name)
        return if ref_type?(type)

        raise_sema_error("local #{local_name} cannot store nested ref types") if contains_ref_type?(type)
      end

      def validate_local_proc_type!(type, local_name, initializer:)
        return unless contains_proc_type?(type)

        raise_sema_error("local #{local_name} uses unsupported proc nesting") unless proc_storage_supported_type?(type)
      end

      def error_type?(type)
        type.is_a?(Types::Error)
      end

      def validate_consuming_foreign_parameter!(type, function_name:, parameter_name:)
        if type.is_a?(Types::Nullable) || !(opaque_type?(type) || pointer_type?(type))
          raise_sema_error("consuming parameter #{parameter_name} of #{function_name} must use a non-null opaque or ptr[...] type")
        end
      end

      def foreign_cstr_boundary_parameter?(parameter)
        parameter.boundary_type == @types.fetch("cstr") && parameter.type == @types.fetch("str")
      end

      def foreign_cstr_argument_compatible?(actual_type, parameter, expression:)
        types_compatible?(actual_type, parameter.type, expression:) || actual_type == @types.fetch("cstr")
      end

      def array_to_span_call_argument_compatible?(actual_type, expected_type, expression:, scopes:)
        return false unless expected_type.is_a?(Types::Span)

        if array_type?(actual_type)
          return false unless array_element_type(actual_type) == expected_type.element_type

          infer_addr_source_type(expression, scopes:)
          return true
        end

        if str_buffer_type?(actual_type)
          return false unless expected_type.element_type == @types.fetch("char")

          infer_addr_source_type(expression, scopes:)
          return true
        end

        false
      rescue SemaError
        false
      end

      def foreign_parameter_boundary_type(param, public_type, type_params:, type_param_constraints: current_type_param_constraints)
        return resolve_type_ref(param.boundary_type, type_params:, type_param_constraints:) if param.boundary_type
        return const_pointer_to(public_type) if param.mode == :in
        return pointer_to(foreign_slot_boundary_value_type(public_type)) if [:out, :inout].include?(param.mode)

        nil
      end

      def foreign_slot_boundary_value_type(public_type)
        if public_type.is_a?(Types::Nullable) && pointer_type?(public_type.base)
          return public_type.base
        end

        public_type
      end

      def validate_in_foreign_parameter!(public_type, boundary_type, function_name:, parameter_name:)
        unless const_pointer_type?(boundary_type)
          raise_sema_error("in parameter #{parameter_name} of #{function_name} must lower to const_ptr[...], got #{boundary_type || public_type}")
        end

        expected_public_type = pointee_type(boundary_type)
        return if expected_public_type == public_type
        return if expected_public_type == @types.fetch("void")
        return if foreign_identity_projection_compatible?(public_type, expected_public_type)

        raise_sema_error("in parameter #{parameter_name} of #{function_name} cannot map #{public_type} as #{boundary_type}")
      end

      def foreign_mapping_public_alias_name(name)
        "#{name}_public"
      end

      def validate_foreign_boundary_type!(public_type, boundary_type, function_name:, parameter_name:)
        return if boundary_type == public_type
        return if boundary_type == @types.fetch("cstr") && public_type == @types.fetch("str")
        return if foreign_span_boundary_compatible?(public_type, boundary_type)
        return if foreign_char_pointer_buffer_boundary_compatible?(public_type, boundary_type)
        return if foreign_identity_projection_compatible?(public_type, boundary_type)

        raise_sema_error("foreign parameter #{parameter_name} of #{function_name} cannot map #{public_type} as #{boundary_type}")
      end

      def foreign_function_binding?(binding)
        binding.ast.is_a?(AST::ForeignFunctionDecl)
      end

      def foreign_mapping_expression(decl)
        return decl.mapping unless foreign_mapping_auto_call_shorthand?(decl.mapping)

        AST::Call.new(
          callee: decl.mapping,
          arguments: decl.params.map { |param| AST::Argument.new(name: nil, value: AST::Identifier.new(name: param.name)) },
        )
      end

      def foreign_mapping_auto_call_shorthand?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess
          foreign_mapping_auto_call_shorthand?(expression.receiver)
        when AST::Specialization
          foreign_mapping_auto_call_shorthand?(expression.callee)
        else
          false
        end
      end

      def foreign_argument_expression(argument)
        if argument.value.is_a?(AST::UnaryOp) && ["out", "in", "inout"].include?(argument.value.operator)
          argument.value.operand
        else
          argument.value
        end
      end

      def foreign_argument_legacy_passing_mode(argument)
        return nil unless argument.value.is_a?(AST::UnaryOp) && ["out", "in", "inout"].include?(argument.value.operator)

        argument.value.operator
      end

      def foreign_argument_actual_type(parameter, argument, scopes:, function_name:, expected_type: parameter.type)
        case parameter.passing_mode
        when :plain
          infer_expression(argument.value, scopes:, expected_type:)
        when :consuming
          foreign_consuming_argument_binding(parameter, argument, scopes:, function_name:)
          parameter.type
        when :in, :out, :inout
          if (legacy_passing_mode = foreign_argument_legacy_passing_mode(argument))
            raise_sema_error("argument #{parameter.name} to #{function_name} must not use #{legacy_passing_mode}; directional passing is declared on #{function_name}")
          end

          if parameter.passing_mode == :in
            infer_expression(argument.value, scopes:, expected_type: expected_type)
          else
            infer_lvalue(argument.value, scopes:)
          end
        else
          raise_sema_error("unsupported foreign passing mode #{parameter.passing_mode}")
        end
      end

      def foreign_consuming_argument_binding(parameter, argument, scopes:, function_name:)
        unless argument.value.is_a?(AST::Identifier)
          raise_sema_error("consuming argument #{parameter.name} to #{function_name} must be a bare nullable local or parameter binding")
        end

        binding = lookup_value(argument.value.name, scopes)
        unless binding && %i[let var param].include?(binding.kind) && binding.storage_type.is_a?(Types::Nullable) && binding.storage_type.base == parameter.type
          raise_sema_error("consuming argument #{parameter.name} to #{function_name} must be a bare nullable local or parameter binding")
        end

        binding
      end

      def safe_reference_source_expression?(expression, scopes:)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          safe_reference_source_expression?(expression.receiver, scopes:)
        when AST::BinaryOp
          unsafe_context?
        when AST::Call
          return false unless expression.arguments.length == 1 && expression.arguments.first.name.nil?

          if read_call?(expression)
            argument_type = infer_expression(expression.arguments.first.value, scopes:)
            ref_type?(argument_type) || pointer_type?(argument_type)
          else
            false
          end
        else
          false
        end
      end

      def infer_ro_addr_source_type(expression, scopes:)
        raise_sema_error("const_ptr_of requires a safe lvalue source") unless safe_reference_source_expression?(expression, scopes:)

        source_type = infer_expression(expression, scopes:)
        raise_sema_error("const_ptr_of cannot target ref values") if contains_ref_type?(source_type)

        source_type
      end

      def infer_addr_source_type(expression, scopes:)
        raise_sema_error("ref_of requires a mutable safe lvalue source") unless safe_reference_source_expression?(expression, scopes:)

        source_type = infer_lvalue(expression, scopes:)
        raise_sema_error("ref_of cannot target ref values") if contains_ref_type?(source_type)

        source_type
      end

      def validate_read_call_arguments!(arguments)
        raise_sema_error("read does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("read expects 1 argument, got #{arguments.length}") unless arguments.length == 1
      end

      def infer_reference_value_type(handle_expression, scopes:)
        handle_type = infer_expression(handle_expression, scopes:)
        return referenced_type(handle_type) if ref_type?(handle_type)

        pointee = pointee_type(handle_type)
        if pointee
          require_unsafe!("raw pointer dereference requires unsafe")

          return pointee
        end

        raise_sema_error("read expects ref[...] or ptr[...], got #{handle_type}")
      end

      def infer_method_receiver_type(receiver_expression, scopes:, member_name: nil)
        receiver_type = infer_expression(receiver_expression, scopes:)
        project_method_receiver_type(receiver_type, member_name:)
      end

      def infer_field_receiver_type(receiver_expression, scopes:, require_mutable_pointer: false)
        receiver_type = infer_expression(receiver_expression, scopes:)
        project_field_receiver_type(receiver_type, require_mutable_pointer:)
      end

      def project_field_receiver_type(receiver_type, require_mutable_pointer: false)
        return referenced_type(receiver_type) if ref_type?(receiver_type)
        return receiver_type unless pointer_type?(receiver_type)

        require_unsafe!("raw pointer dereference requires unsafe")
        if require_mutable_pointer && const_pointer_type?(receiver_type)
          raise_sema_error("cannot assign through read-only raw pointer #{receiver_type}")
        end

        pointee_type(receiver_type)
      end

      def project_method_receiver_type(receiver_type, member_name: nil)
        receiver_type = referenced_type(receiver_type) if ref_type?(receiver_type)
        return receiver_type unless pointer_type?(receiver_type)

        return receiver_type if member_name && lookup_method(receiver_type, member_name)

        require_unsafe!("raw pointer dereference requires unsafe")

        pointee_type(receiver_type)
      end

      def read_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "read"
      end

      def raw_module?
        @module_kind == :raw_module
      end

      def assignable_receiver?(receiver_expression, scopes)
        infer_lvalue_receiver(receiver_expression, scopes:, allow_ref_identifier: true, allow_pointer_identifier: true, require_mutable_pointer: true)
        true
      rescue SemaError
        false
      end

      def with_scope(bindings)
        scope = {}
        bindings.each do |binding|
          raise_sema_error("duplicate local #{binding.name}") if scope.key?(binding.name)

          scope[binding.name] = binding
        end

        yield([scope])
      end

      def with_nested_scope(scopes)
        nested_scopes = scopes + [{}]
        yield(nested_scopes)
      end

      def value_binding(name:, type:, mutable:, kind:, flow_type: nil, const_value: nil, id: nil)
        id ||= allocate_binding_id
        @binding_name_by_id[id] = name
        @binding_type_by_id[id] = flow_type == type ? type : (flow_type || type)
        ValueBinding.new(id:, name:, storage_type: type, flow_type: flow_type == type ? nil : flow_type, mutable:, kind:, const_value:)
      end

      def binding_resolution_snapshot
        BindingResolution.new(
          identifier_binding_ids: @identifier_binding_ids.dup.freeze,
          declaration_binding_ids: @declaration_binding_ids.dup.freeze,
          mutating_argument_identifier_ids: @mutating_argument_identifier_ids.dup.freeze,
          mutable_receiver_expression_ids: @mutable_receiver_expression_ids.dup.freeze,
          binding_types: @binding_type_by_id.dup.freeze,
        )
      end

      def allocate_binding_id
        id = @next_binding_id
        @next_binding_id += 1
        id
      end

      def record_identifier_binding(expression, binding)
        return unless expression.is_a?(AST::Identifier)
        return unless binding&.id

        @identifier_binding_ids[expression.object_id] = binding.id
      end

      def record_callable_value_identifier_site(expression)
        return unless expression.is_a?(AST::Identifier)
        return unless expression.line && expression.column

        @callable_value_identifier_sites[[expression.line, expression.column]] = true
      end

      def record_callable_value_expression_site(expression)
        case expression
        when AST::Identifier
          record_callable_value_identifier_site(expression)
        when AST::MemberAccess
          record_callable_value_member_access_site(expression)
        end
      end

      def record_callable_value_member_access_site(expression)
        return unless expression.is_a?(AST::MemberAccess)
        return unless expression.receiver.is_a?(AST::Identifier)
        return unless expression.receiver.line && expression.receiver.column

        @callable_value_member_access_sites[
          [expression.receiver.name, expression.receiver.line, expression.receiver.column, expression.member]
        ] = true
      end

      def record_declaration_binding(node, binding)
        return unless node
        return unless binding&.id

        @declaration_binding_ids[node.object_id] = binding.id
      end

      def current_actual_scope(scopes)
        scopes.reverse_each do |scope|
          return scope unless scope.is_a?(FlowScope)
        end

        raise_sema_error("missing lexical scope")
      end

      def apply_continuation_refinements!(scopes, refinements)
        return if refinements.nil? || refinements.empty?

        scopes.replace(scopes_with_refinements(scopes, refinements))
      end

      def scopes_with_refinements(scopes, refinements)
        return scopes if refinements.nil? || refinements.empty?

        base_scopes = scopes.last.is_a?(FlowScope) ? scopes[0...-1] : scopes
        merged_refinements = scopes.last.is_a?(FlowScope) ? scopes.last.each_with_object({}) { |(name, binding), result| result[name] = binding.type } : {}
        merged_refinements = merge_refinements(merged_refinements, refinements)
        flow_scope = FlowScope.new

        merged_refinements.each do |name, refined_type|
          binding = lookup_value(name, base_scopes)
          next unless binding

          flow_scope[name] = binding.with_flow_type(refined_type)
        end

        return base_scopes if flow_scope.empty?

        base_scopes + [flow_scope]
      end

      def merge_refinements(existing, incoming)
        merged = existing.dup
        incoming.each do |name, refined_type|
          if merged.key?(name) && merged[name] != refined_type
            merged.delete(name)
          else
            merged[name] = refined_type
          end
        end

        merged
      end

      def flow_refinements(expression, truthy:, scopes:)
        case expression
        when AST::UnaryOp
          return flow_refinements(expression.operand, truthy: !truthy, scopes:) if expression.operator == "not"
        when AST::BinaryOp
          case expression.operator
          when "and"
            if truthy
              left_truthy = flow_refinements(expression.left, truthy: true, scopes:)
              right_scopes = scopes_with_refinements(scopes, left_truthy)
              right_truthy = flow_refinements(expression.right, truthy: true, scopes: right_scopes)
              return merge_refinements(left_truthy, right_truthy)
            end
          when "or"
            unless truthy
              left_falsy = flow_refinements(expression.left, truthy: false, scopes:)
              right_scopes = scopes_with_refinements(scopes, left_falsy)
              right_falsy = flow_refinements(expression.right, truthy: false, scopes: right_scopes)
              return merge_refinements(left_falsy, right_falsy)
            end
          when "==", "!="
            return null_test_refinements(expression, truthy:, scopes:)
          end
        end

        {}
      end

      def start_local_completion_frame(binding, scopes)
        frame = {
          function_name: binding.name,
          receiver_type: binding.type.receiver_type,
          snapshots: [],
        }
        @active_local_completion_stack << frame
        record_local_completion_snapshot(binding.ast.respond_to?(:line) ? binding.ast.line : nil, 0, scopes)
      end

      def finish_local_completion_frame(binding)
        return if @active_local_completion_stack.empty?

        frame = @active_local_completion_stack.pop
        snapshots = frame[:snapshots]
        if snapshots.empty?
          return
        end

        start_line = [binding.ast.respond_to?(:line) ? binding.ast.line : nil, snapshots.first.line].compact.min
        end_line = snapshots.last.line

        @local_completion_frames << LocalCompletionFrame.new(
          start_line:,
          end_line:,
          function_name: frame[:function_name],
          receiver_type: frame[:receiver_type],
          snapshots: snapshots.freeze,
        )
      end

      def record_local_completion_snapshot(line, column, scopes)
        return if @active_local_completion_stack.empty?
        return if line.nil?

        snapshot = LocalCompletionSnapshot.new(
          line:,
          column: (column || 0),
          bindings: merged_scope_bindings(scopes).freeze,
        )

        snapshots = @active_local_completion_stack.last[:snapshots]
        prev = snapshots.last
        if prev && prev.line == snapshot.line && prev.column == snapshot.column
          snapshots[-1] = snapshot
        else
          snapshots << snapshot
        end
      end

      def merged_scope_bindings(scopes)
        scopes.each_with_object({}) do |scope, bindings|
          scope.each do |name, binding|
            bindings[name] = binding
          end
        end
      end

      def statement_end_line(statement)
        return nil unless statement

        lines = [statement.respond_to?(:line) ? statement.line : nil]

        case statement
        when AST::ErrorBlockStmt
          lines.concat(statement_list_lines(statement.body))
        when AST::IfStmt
          statement.branches.each do |branch|
            lines.concat(statement_list_lines(branch.body))
          end
          lines.concat(statement_list_lines(statement.else_body)) if statement.else_body
        when AST::UnsafeStmt, AST::ForStmt, AST::WhileStmt
          lines.concat(statement_list_lines(statement.body))
        when AST::MatchStmt
          statement.arms.each do |arm|
            lines.concat(statement_list_lines(arm.body))
          end
        when AST::DeferStmt
          lines.concat(statement_list_lines(statement.body)) if statement.body
        end

        lines.compact.max
      end

      def statement_list_lines(statements)
        return [] unless statements

        statements.each_with_object([]) do |stmt, lines|
          end_line = statement_end_line(stmt)
          lines << end_line if end_line
        end
      end

      def recovered_for_statement(statement)
        AST::ForStmt.new(
          bindings: Array(statement.header_bindings),
          iterables: Array(statement.header_iterables),
          body: statement.body,
          line: statement.line,
          column: statement.column,
        )
      end

      def null_test_refinements(expression, truthy:, scopes:)
        identifier_expression = nil
        if expression.left.is_a?(AST::Identifier) && expression.right.is_a?(AST::NullLiteral)
          identifier_expression = expression.left
        elsif expression.left.is_a?(AST::NullLiteral) && expression.right.is_a?(AST::Identifier)
          identifier_expression = expression.right
        else
          return {}
        end

        binding = lookup_value(identifier_expression.name, scopes)
        return {} unless binding&.storage_type.is_a?(Types::Nullable)

        null_result = expression.operator == "==" ? truthy : !truthy
        refined_type = null_result ? @null_type : binding.storage_type.base
        { identifier_expression.name => refined_type }
      end

      def conditional_common_type(then_type, else_type, then_expression:, else_expression:)
        return then_type if then_type == else_type

        numeric_type = common_numeric_type(then_type, else_type)
        return numeric_type if numeric_type

        if (nullable_type = conditional_null_common_type(then_type, else_type))
          return nullable_type
        end

        if (nullable_type = conditional_null_common_type(else_type, then_type))
          return nullable_type
        end

        return then_type if types_compatible?(else_type, then_type, expression: else_expression)
        return else_type if types_compatible?(then_type, else_type, expression: then_expression)

        nil
      end

      def nullable_candidate?(type)
        return false if ref_type?(type)

        sized_layout_type?(type) || pointer_type?(type) || type.is_a?(Types::Nullable)
      end

      def conditional_null_common_type(null_type, other_type)
        return unless null_type.is_a?(Types::Null)

        if other_type.is_a?(Types::Nullable)
          return other_type if null_type.target_type.nil? || null_type.target_type == other_type.base

          return nil
        end

        return unless nullable_candidate?(other_type)
        return if null_type.target_type && null_type.target_type != other_type

        Types::Nullable.new(other_type)
      end

      def describe_expression(expression)
        case expression
        when AST::Identifier
          expression.name
        when AST::MemberAccess
          "#{describe_expression(expression.receiver)}.#{expression.member}"
        when AST::IndexAccess
          "#{describe_expression(expression.receiver)}[...]"
        when AST::Specialization
          "#{describe_expression(expression.callee)}[...]"
        when AST::FormatString
          'f"..."'
        else
          expression.class.name.split("::").last
        end
      end

    end
  end
end
