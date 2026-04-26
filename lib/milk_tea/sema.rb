# frozen_string_literal: true

module MilkTea
  class SemaError < StandardError; end

  class Sema
    Analysis = Data.define(:ast, :module_name, :module_kind, :directives, :imports, :types, :values, :functions, :methods)
    FlowScope = Class.new(Hash)
    ValueBinding = Data.define(:name, :storage_type, :flow_type, :mutable, :kind) do
      def type
        flow_type || storage_type
      end

      def with_flow_type(refined_type)
        ValueBinding.new(
          name:,
          storage_type:,
          flow_type: refined_type == storage_type ? nil : refined_type,
          mutable:,
          kind:,
        )
      end
    end
    FunctionBinding = Data.define(:name, :type, :body_params, :ast, :external, :type_params, :instances, :type_arguments, :owner, :type_substitutions)
    ModuleBinding = Data.define(:name, :types, :values, :functions, :methods, :private_types, :private_values, :private_functions, :private_methods) do
      def private_type?(name)
        private_types.key?(name)
      end

      def private_value?(name)
        private_values.key?(name)
      end

      def private_function?(name)
        private_functions.key?(name)
      end

      def private_method?(receiver_type, name)
        private_methods.fetch(receiver_type, {}).key?(name)
      end
    end

    BUILTIN_TYPE_NAMES = %w[
      bool byte char i8 i16 i32 i64 u8 u16 u32 u64 isize usize f32 f64 void str cstr
    ].freeze

    def self.check(ast, imported_modules: {})
      Checker.new(ast, imported_modules:).check
    end

    class Checker
      attr_reader :module_name

      def initialize(ast, imported_modules: {})
        @ast = ast
        @imported_modules = imported_modules
        @module_name = ast.module_name&.to_s
        @module_kind = ast.module_kind
        @types = {}
        @top_level_values = {}
        @top_level_functions = {}
        @imports = {}
        @methods = Hash.new { |hash, key| hash[key] = {} }
        @null_type = Types::Null.new
        @loop_depth = 0
        @unsafe_depth = 0
        @foreign_mapping_depth = 0
        @checked_function_bindings = {}
        @checking_function_bindings = {}
      end

      def check
        install_builtin_types
        install_imports
        declare_named_types
        resolve_type_aliases
        resolve_aggregate_fields
        resolve_enum_members
        declare_top_level_values
        declare_functions
        check_top_level_values
        check_top_level_static_asserts
        check_functions

        Analysis.new(
          ast: @ast,
          module_name: @module_name,
          module_kind: @module_kind,
          directives: @ast.directives,
          imports: @imports,
          types: @types,
          values: @top_level_values,
          functions: @top_level_functions,
          methods: snapshot_methods,
        )
      end

      private

      def install_builtin_types
        BUILTIN_TYPE_NAMES.each do |name|
          @types[name] = name == "str" ? Types::StringView.new : Types::Primitive.new(name)
        end
      end

      def snapshot_methods
        @methods.each_with_object({}) do |(receiver_type, bindings), methods|
          methods[receiver_type] = bindings.dup.freeze
        end.freeze
      end

      def install_imports
        @ast.imports.each do |import|
          alias_name = import.alias_name || import.path.parts.last
          raise SemaError, "duplicate import alias #{alias_name}" if @imports.key?(alias_name)

          module_binding = @imported_modules[import.path.to_s]
          raise SemaError, "unknown import #{import.path}" unless module_binding

          @imports[alias_name] = module_binding
        end
      end

      def declare_named_types
        @ast.declarations.each do |decl|
          case decl
          when AST::StructDecl
            validate_struct_layout!(decl)
            ensure_available_type_name!(decl.name)
            @types[decl.name] = if decl.type_params.empty?
                                  Types::Struct.new(
                                    decl.name,
                                    module_name: @module_name,
                                    external: external_module?,
                                    packed: decl.packed,
                                    alignment: decl.alignment,
                                  )
                                else
                                  Types::GenericStructDefinition.new(
                                    decl.name,
                                    decl.type_params.map(&:name),
                                    module_name: @module_name,
                                    external: external_module?,
                                    packed: decl.packed,
                                    alignment: decl.alignment,
                                  )
                                end
          when AST::UnionDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = Types::Union.new(decl.name, module_name: @module_name, external: external_module?)
          when AST::EnumDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = Types::Enum.new(decl.name, module_name: @module_name, external: external_module?)
          when AST::FlagsDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = Types::Flags.new(decl.name, module_name: @module_name, external: external_module?)
          when AST::OpaqueDecl
            ensure_available_type_name!(decl.name)
            @types[decl.name] = Types::Opaque.new(decl.name, module_name: @module_name, external: external_module?)
          end
        end
      end

      def resolve_type_aliases
        @ast.declarations.grep(AST::TypeAliasDecl).each do |decl|
          ensure_available_type_name!(decl.name)
          @types[decl.name] = resolve_type_ref(decl.target)
        end
      end

      def validate_struct_layout!(decl)
        return unless decl.alignment

        raise SemaError, "align(...) requires a positive alignment" unless decl.alignment.positive?
        return if power_of_two?(decl.alignment)

        raise SemaError, "align(...) requires a power-of-two alignment, got #{decl.alignment}"
      end

      def resolve_aggregate_fields
        @ast.declarations.each do |decl|
          next unless decl.is_a?(AST::StructDecl) || decl.is_a?(AST::UnionDecl)

          struct_type = @types.fetch(decl.name)
          type_params = if struct_type.is_a?(Types::GenericStructDefinition)
                          seen = {}
                          struct_type.type_params.each_with_object({}) do |name, params|
                            raise SemaError, "duplicate type parameter #{decl.name}[#{name}]" if seen.key?(name)

                            seen[name] = true
                            params[name] = Types::TypeVar.new(name)
                          end
                        else
                          {}
                        end
          fields = {}

          decl.fields.each do |field|
            raise SemaError, "duplicate field #{decl.name}.#{field.name}" if fields.key?(field.name)

            field_type = resolve_type_ref(field.type, type_params:)
            validate_stored_ref_type!(field_type, "field #{decl.name}.#{field.name}")
            fields[field.name] = field_type
          end

          struct_type.define_fields(fields)
        end
      end

      def resolve_enum_members
        @ast.declarations.each do |decl|
          next unless decl.is_a?(AST::EnumDecl) || decl.is_a?(AST::FlagsDecl)

          enum_type = @types.fetch(decl.name)
          backing_type = resolve_type_ref(decl.backing_type)
          unless backing_type.is_a?(Types::Primitive) && backing_type.integer?
            raise SemaError, "#{decl.name} backing type must be an integer primitive, got #{backing_type}"
          end

          member_names = []
          decl.members.each do |member|
            raise SemaError, "duplicate member #{decl.name}.#{member.name}" if member_names.include?(member.name)

            member_names << member.name
          end

          enum_type.define_members(backing_type, member_names)

          decl.members.each do |member|
            actual_type = infer_expression(member.value, scopes: [], expected_type: backing_type)
            ensure_assignable!(actual_type, backing_type, "member #{decl.name}.#{member.name} expects #{backing_type}, got #{actual_type}")
          end
        end
      end

      def declare_top_level_values
        @ast.declarations.grep(AST::ConstDecl).each do |decl|
          ensure_available_value_name!(decl.name)
          type = resolve_type_ref(decl.type)
          validate_stored_ref_type!(type, "constant #{decl.name}")
          @top_level_values[decl.name] = value_binding(
            name: decl.name,
            type: type,
            mutable: false,
            kind: :const,
          )
        end
      end

      def declare_functions
        @ast.declarations.each do |decl|
          case decl
          when AST::FunctionDef
            ensure_available_value_name!(decl.name)
            @top_level_functions[decl.name] = declare_function_binding(decl)
          when AST::ExternFunctionDecl
            ensure_available_value_name!(decl.name)
            @top_level_functions[decl.name] = declare_function_binding(decl, external: true)
          when AST::ForeignFunctionDecl
            ensure_available_value_name!(decl.name)
            @top_level_functions[decl.name] = declare_function_binding(decl)
          when AST::MethodsBlock
            receiver_type = resolve_type_ref(AST::TypeRef.new(name: decl.type_name, arguments: [], nullable: false))
            unless receiver_type.is_a?(Types::Struct) || receiver_type.is_a?(Types::StringView)
              raise SemaError, "methods target #{decl.type_name} must be a struct or str"
            end

            decl.methods.each do |method|
              binding = declare_function_binding(method, receiver_type:)
              raise SemaError, "duplicate method #{receiver_type.name}.#{binding.name}" if @methods[receiver_type].key?(binding.name)

              @methods[receiver_type][binding.name] = binding
            end
          end
        end
      end

      def declare_function_binding(decl, receiver_type: nil, external: false)
        foreign = decl.is_a?(AST::ForeignFunctionDecl)
        type_param_names = decl.type_params.map(&:name)
        raise SemaError, "extern function #{decl.name} cannot be generic" if external && type_param_names.any?
        raise SemaError, "generic methods are not supported yet in #{decl.name}" if receiver_type && type_param_names.any?
        raise SemaError, "main cannot be generic" if decl.name == "main" && type_param_names.any?

        method_kind = decl.is_a?(AST::MethodDef) ? decl.kind : nil
        instance_method = receiver_type && method_kind != :static

        type_params = {}
        type_param_names.each do |name|
          raise SemaError, "duplicate type parameter #{decl.name}[#{name}]" if type_params.key?(name)

          type_params[name] = Types::TypeVar.new(name)
        end

        body_params = []
        if instance_method
          body_params << value_binding(
            name: "this",
            type: receiver_type,
            mutable: method_kind == :edit,
            kind: :param,
          )
        end

        public_params = []
        decl.params.each do |param|
          type = resolve_type_ref(param.type, type_params:)
          validate_parameter_ref_type!(type, function_name: decl.name, parameter_name: param.name, external:)

          if external && array_type?(type)
            raise SemaError, "extern function #{decl.name} cannot take array parameters"
          end

          if foreign
            raise SemaError, "foreign parameter #{param.name} cannot use `as` with #{param.mode}" if param.mode != :plain && param.boundary_type
            validate_owned_foreign_parameter!(type, function_name: decl.name, parameter_name: param.name) if param.mode == :owned

            boundary_type = foreign_parameter_boundary_type(param, type, type_params:)
            validate_foreign_boundary_type!(type, boundary_type, function_name: decl.name, parameter_name: param.name) if param.boundary_type
            body_params << value_binding(name: param.name, type: boundary_type || type, mutable: false, kind: :param)
            if param.boundary_type
              body_params << value_binding(
                name: foreign_mapping_public_alias_name(param.name),
                type:,
                mutable: false,
                kind: :param,
              )
            end
            public_params << Types::Parameter.new(param.name, type, passing_mode: param.mode, boundary_type: boundary_type)
          else
            body_params << value_binding(name: param.name, type:, mutable: param.mutable, kind: :param)
          end
        end

        receiver_mutable = false
        call_params = body_params
        function_receiver_type = nil
        if instance_method
          receiver_mutable = method_kind == :edit
          call_params = body_params.drop(1)
          function_receiver_type = receiver_type
        end

        call_params = public_params if foreign

        seen = {}
        body_params.each do |param|
          raise SemaError, "duplicate parameter #{param.name} in #{decl.name}" if seen.key?(param.name)

          seen[param.name] = true
        end

        return_type = decl.return_type ? resolve_type_ref(decl.return_type, type_params:) : @types.fetch("void")
        validate_return_ref_type!(return_type, function_name: decl.name)
        if foreign && public_params.any? { |param| param.passing_mode == :owned } && return_type != @types.fetch("void")
          raise SemaError, "foreign function #{decl.name} with owned parameters must return void"
        end
        if external && array_type?(return_type)
          raise SemaError, "extern function #{decl.name} cannot return arrays"
        end

        function_type = Types::Function.new(
          decl.name,
          params: foreign ? call_params : call_params.map { |param| Types::Parameter.new(param.name, param.type, mutable: param.mutable) },
          return_type:,
          receiver_type: function_receiver_type,
          receiver_mutable:,
          variadic: decl.respond_to?(:variadic) ? decl.variadic : false,
          external:,
        )

        FunctionBinding.new(
          name: decl.name,
          type: function_type,
          body_params:,
          ast: decl,
          external:,
          type_params: type_param_names.freeze,
          instances: {},
          type_arguments: [].freeze,
          owner: self,
          type_substitutions: {}.freeze,
        )
      end

      def check_top_level_values
        @ast.declarations.grep(AST::ConstDecl).each do |decl|
          binding = @top_level_values.fetch(decl.name)
          validate_using_scratch_expression!(decl.value, root_allowed: false)
          validate_owned_foreign_expression!(decl.value, scopes: [], root_allowed: false)
          actual_type = infer_expression(decl.value, scopes: [], expected_type: binding.type)
          ensure_assignable!(
            actual_type,
            binding.type,
            "cannot assign #{actual_type} to constant #{decl.name}: expected #{binding.type}",
            expression: decl.value,
          )
        end
      end

      def check_top_level_static_asserts
        @ast.declarations.grep(AST::StaticAssert).each do |statement|
          check_static_assert(statement, scopes: [])
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

      def check_function(binding)
        return if binding.external || binding.type_params.any?
        return if @checked_function_bindings[binding.object_id]
        return if @checking_function_bindings[binding.object_id]

        @checking_function_bindings[binding.object_id] = true
        previous_type_substitutions = @current_type_substitutions
        @current_type_substitutions = binding.type_substitutions
        with_scope(binding.body_params) do |scopes|
          if binding.ast.is_a?(AST::ForeignFunctionDecl)
            expression = foreign_mapping_expression(binding.ast)
            actual_type = with_foreign_mapping_context do
              infer_expression(expression, scopes:, expected_type: binding.type.return_type)
            end
            unless types_compatible?(actual_type, binding.type.return_type, expression:) || foreign_identity_projection_compatible?(actual_type, binding.type.return_type)
              raise SemaError, "foreign mapping #{binding.name} expects #{binding.type.return_type}, got #{actual_type}"
            end
          else
            check_block(binding.ast.body, scopes:, return_type: binding.type.return_type)
          end
        end
        @checked_function_bindings[binding.object_id] = true
      ensure
        @current_type_substitutions = previous_type_substitutions
        @checking_function_bindings.delete(binding.object_id)
      end

      def check_block(statements, scopes:, return_type:)
        with_nested_scope(scopes) do |nested_scopes|
          statements.each do |statement|
            refinements = check_statement(statement, scopes: nested_scopes, return_type:)
            apply_continuation_refinements!(nested_scopes, refinements)
          end
        end
      end

      def check_statement(statement, scopes:, return_type:)
        case statement
        when AST::LocalDecl
          check_local_decl(statement, scopes:)
        when AST::Assignment
          check_assignment(statement, scopes:)
        when AST::IfStmt
          false_refinements = {}
          branch_bodies_terminate = []
          statement.branches.each do |branch|
            branch_scopes = scopes_with_refinements(scopes, false_refinements)
            validate_using_scratch_expression!(branch.condition, root_allowed: false)
            validate_owned_foreign_expression!(branch.condition, scopes: branch_scopes, root_allowed: false)
            condition_type = infer_expression(branch.condition, scopes: branch_scopes, expected_type: @types.fetch("bool"))
            ensure_assignable!(condition_type, @types.fetch("bool"), "if condition must be bool, got #{condition_type}")
            true_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: true, scopes: branch_scopes))
            check_block(branch.body, scopes: scopes_with_refinements(scopes, true_refinements), return_type:)
            branch_bodies_terminate << block_always_terminates?(branch.body)
            false_refinements = merge_refinements(false_refinements, flow_refinements(branch.condition, truthy: false, scopes: branch_scopes))
          end
          check_block(statement.else_body, scopes: scopes_with_refinements(scopes, false_refinements), return_type:) if statement.else_body
          return false_refinements if statement.else_body.nil? && branch_bodies_terminate.all?
        when AST::MatchStmt
          check_match_stmt(statement, scopes:, return_type:)
        when AST::UnsafeStmt
          with_unsafe do
            check_block(statement.body, scopes:, return_type:)
          end
        when AST::StaticAssert
          check_static_assert(statement, scopes:)
        when AST::ForStmt
          check_for_stmt(statement, scopes:, return_type:)
        when AST::WhileStmt
          validate_using_scratch_expression!(statement.condition, root_allowed: false)
          validate_owned_foreign_expression!(statement.condition, scopes:, root_allowed: false)
          condition_type = infer_expression(statement.condition, scopes:, expected_type: @types.fetch("bool"))
          ensure_assignable!(condition_type, @types.fetch("bool"), "while condition must be bool, got #{condition_type}")
          with_loop do
            body_scopes = scopes_with_refinements(scopes, flow_refinements(statement.condition, truthy: true, scopes:))
            check_block(statement.body, scopes: body_scopes, return_type:)
          end
        when AST::BreakStmt
          raise SemaError, "break must be inside a loop" unless inside_loop?
        when AST::ContinueStmt
          raise SemaError, "continue must be inside a loop" unless inside_loop?
        when AST::ReturnStmt
          validate_using_scratch_expression!(statement.value, root_allowed: true) if statement.value
          validate_owned_foreign_expression!(statement.value, scopes:, root_allowed: false) if statement.value
          value_type = statement.value ? infer_expression(statement.value, scopes:, expected_type: return_type) : @types.fetch("void")
          ensure_assignable!(
            value_type,
            return_type,
            "return type mismatch: expected #{return_type}, got #{value_type}",
            expression: statement.value,
            contextual_int_to_float: contextual_int_to_float_target?(return_type),
          )
        when AST::DeferStmt
          validate_using_scratch_expression!(statement.expression, root_allowed: false)
          validate_owned_foreign_expression!(statement.expression, scopes:, root_allowed: false)
          infer_expression(statement.expression, scopes:)
        when AST::ExpressionStmt
          validate_using_scratch_expression!(statement.expression, root_allowed: true)
          validate_owned_foreign_expression!(statement.expression, scopes:, root_allowed: true)
          infer_expression(statement.expression, scopes:)
          return owned_foreign_call_refinements(statement.expression, scopes:)
        else
          raise SemaError, "unsupported statement #{statement.class.name}"
        end

        nil
      end

      def check_local_decl(statement, scopes:)
        current_scope = current_actual_scope(scopes)
        raise SemaError, "duplicate local #{statement.name}" if current_scope.key?(statement.name)

        declared_type = statement.type ? resolve_type_ref(statement.type) : nil
        if statement.value
          validate_using_scratch_expression!(statement.value, root_allowed: true)
          validate_owned_foreign_expression!(statement.value, scopes:, root_allowed: false)
          inferred_type = infer_expression(statement.value, scopes:, expected_type: declared_type)
        else
          raise SemaError, "local #{statement.name} without initializer requires an explicit type" unless declared_type

          begin
            zero_initializable_type?(declared_type)
          rescue SemaError
            raise SemaError, "local #{statement.name} without initializer requires a zero-initializable type, got #{declared_type}"
          end

          inferred_type = declared_type
        end

        if declared_type
          validate_local_ref_type!(declared_type, statement.name)
          ensure_assignable!(
            inferred_type,
            declared_type,
            "cannot assign #{inferred_type} to #{statement.name}: expected #{declared_type}",
            expression: statement.value,
            contextual_int_to_float: contextual_int_to_float_target?(declared_type),
          )
          final_type = declared_type
        else
          raise SemaError, "cannot infer type for #{statement.name} from null" if inferred_type.is_a?(Types::Null)
          raise SemaError, "cannot bind void result to #{statement.name}" if inferred_type.void?

          final_type = inferred_type
        end

        validate_local_ref_type!(final_type, statement.name)

        current_scope[statement.name] = value_binding(
          name: statement.name,
          type: final_type,
          mutable: statement.kind == :var,
          kind: statement.kind,
        )
      end

      def check_assignment(statement, scopes:)
        target_type = infer_lvalue(statement.target, scopes:)

        validate_using_scratch_expression!(statement.value, root_allowed: true)
        validate_owned_foreign_expression!(statement.value, scopes:, root_allowed: false)
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
          )
        when "+=", "-=", "*=", "/="
          unless target_type.numeric? && value_type.numeric? && target_type == value_type
            raise SemaError, "operator #{statement.operator} requires matching numeric types, got #{target_type} and #{value_type}"
          end
        else
          raise SemaError, "unsupported assignment operator #{statement.operator}"
        end
      end

      def check_match_stmt(statement, scopes:, return_type:)
        validate_using_scratch_expression!(statement.expression, root_allowed: false)
        validate_owned_foreign_expression!(statement.expression, scopes:, root_allowed: false)
        scrutinee_type = infer_expression(statement.expression, scopes:)
        unless scrutinee_type.is_a?(Types::Enum)
          raise SemaError, "match requires an enum scrutinee, got #{scrutinee_type}"
        end

        covered_members = {}
        statement.arms.each do |arm|
          validate_using_scratch_expression!(arm.pattern, root_allowed: false)
          validate_owned_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
          pattern_type = infer_expression(arm.pattern, scopes:, expected_type: scrutinee_type)
          ensure_assignable!(pattern_type, scrutinee_type, "match arm expects #{scrutinee_type}, got #{pattern_type}")

          member_name = match_member_name(arm.pattern, scrutinee_type)
          raise SemaError, "match arm must be an enum member of #{scrutinee_type}" unless member_name
          raise SemaError, "duplicate match arm #{scrutinee_type}.#{member_name}" if covered_members.key?(member_name)

          covered_members[member_name] = true
          check_block(arm.body, scopes:, return_type:)
        end

        missing_members = scrutinee_type.members - covered_members.keys
        return if missing_members.empty?

        raise SemaError, "match on #{scrutinee_type} is missing cases: #{missing_members.join(', ')}"
      end

      def check_for_stmt(statement, scopes:, return_type:)
        validate_using_scratch_expression!(statement.iterable, root_allowed: false)
        validate_owned_foreign_expression!(statement.iterable, scopes:, root_allowed: false)
        loop_type = if range_call?(statement.iterable)
                      check_range_loop(statement.iterable, scopes:)
                    else
                      iterable_type = infer_expression(statement.iterable, scopes:)
                      collection_loop_type(iterable_type)
                    end

        raise SemaError, "for loop expects range(start, stop), array[T, N], or span[T], got #{infer_expression(statement.iterable, scopes:)}" unless loop_type

        with_nested_scope(scopes) do |loop_scopes|
          current_actual_scope(loop_scopes)[statement.name] = value_binding(
            name: statement.name,
            type: loop_type,
            mutable: false,
            kind: :let,
          )
          with_loop do
            check_block(statement.body, scopes: loop_scopes, return_type:)
          end
        end
      end

      def check_static_assert(statement, scopes:)
        validate_using_scratch_expression!(statement.condition, root_allowed: false)
        validate_using_scratch_expression!(statement.message, root_allowed: false)
        validate_owned_foreign_expression!(statement.condition, scopes:, root_allowed: false)
        validate_owned_foreign_expression!(statement.message, scopes:, root_allowed: false)
        condition_type = infer_expression(statement.condition, scopes:, expected_type: @types.fetch("bool"))
        ensure_assignable!(condition_type, @types.fetch("bool"), "static_assert condition must be bool, got #{condition_type}")
        raise SemaError, "static_assert message must be a string literal" unless statement.message.is_a?(AST::StringLiteral)

        message_type = infer_expression(statement.message, scopes:, expected_type: @types.fetch("str"))
        return if string_like_type?(message_type)

        raise SemaError, "static_assert message must be str or cstr, got #{message_type}"
      end

      def check_range_loop(expression, scopes:)
        raise SemaError, "range does not support named arguments" if expression.arguments.any?(&:name)
        raise SemaError, "range expects 2 arguments, got #{expression.arguments.length}" unless expression.arguments.length == 2

        start_expr = expression.arguments[0].value
        stop_expr = expression.arguments[1].value

        start_type = infer_expression(start_expr, scopes:)
        stop_type = infer_expression(stop_expr, scopes:)

        unless integer_type?(start_type) && integer_type?(stop_type)
          raise SemaError, "range bounds must be integer types, got #{start_type} and #{stop_type}"
        end

        if start_type != stop_type
          if start_expr.is_a?(AST::IntegerLiteral)
            start_type = infer_expression(start_expr, scopes:, expected_type: stop_type)
          elsif stop_expr.is_a?(AST::IntegerLiteral)
            stop_type = infer_expression(stop_expr, scopes:, expected_type: start_type)
          end
        end

        raise SemaError, "range bounds must use matching integer types, got #{start_type} and #{stop_type}" unless start_type == stop_type

        start_type
      end

      def infer_lvalue(expression, scopes:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, scopes)
          raise SemaError, "unknown name #{expression.name}" unless binding
          raise SemaError, "cannot assign to immutable #{expression.name}" unless binding.mutable

          binding.type
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          unless aggregate_type?(receiver_type)
            raise SemaError, "cannot assign to member #{expression.member} of #{receiver_type}"
          end

          field_type = receiver_type.field(expression.member)
          raise SemaError, "unknown field #{receiver_type}.#{expression.member}" unless field_type

          field_type
        when AST::IndexAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          index_type = infer_expression(expression.index, scopes:)
          infer_index_result_type(receiver_type, index_type)
        when AST::Call
          if value_call?(expression)
            validate_value_call_arguments!(expression.arguments)
            return infer_value_target_type(expression.arguments.first.value, scopes:)
          end

          raise SemaError, "invalid assignment target"
        else
          raise SemaError, "invalid assignment target"
        end
      end

      def infer_lvalue_receiver(expression, scopes:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, scopes)
          raise SemaError, "unknown name #{expression.name}" unless binding

          raise SemaError, "cannot assign through immutable #{expression.name}" unless binding.mutable

          binding.type
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          unless aggregate_type?(receiver_type)
            raise SemaError, "cannot access member #{expression.member} of #{receiver_type}"
          end

          field_type = receiver_type.field(expression.member)
          raise SemaError, "unknown field #{receiver_type}.#{expression.member}" unless field_type

          field_type
        when AST::IndexAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          index_type = infer_expression(expression.index, scopes:)
          infer_index_result_type(receiver_type, index_type)
        when AST::Call
          if value_call?(expression)
            validate_value_call_arguments!(expression.arguments)
            return infer_value_target_type(expression.arguments.first.value, scopes:)
          end

          raise SemaError, "invalid assignment target"
        else
          raise SemaError, "invalid assignment target"
        end
      end

      def external_numeric_assignment_target?(expression, scopes:)
        case expression
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:)
          receiver_type.respond_to?(:external) && receiver_type.external
        else
          false
        end
      end

      def infer_expression(expression, scopes:, expected_type: nil)
        case expression
        when AST::IntegerLiteral
          infer_integer_literal(expected_type)
        when AST::FloatLiteral
          infer_float_literal(expected_type)
        when AST::SizeofExpr
          infer_layout_query_type(expression.type, context: "sizeof")
          @types.fetch("usize")
        when AST::AlignofExpr
          infer_layout_query_type(expression.type, context: "alignof")
          @types.fetch("usize")
        when AST::OffsetofExpr
          infer_offsetof_type(expression.type, expression.field)
          @types.fetch("usize")
        when AST::StringLiteral
          @types.fetch(expression.cstring ? "cstr" : "str")
        when AST::BooleanLiteral
          @types.fetch("bool")
        when AST::NullLiteral
          infer_null_literal(expression)
        when AST::Identifier
          infer_identifier(expression, scopes:, expected_type:)
        when AST::MemberAccess
          infer_member_access(expression, scopes:)
        when AST::IndexAccess
          infer_index_access(expression, scopes:)
        when AST::UnaryOp
          infer_unary(expression, scopes:, expected_type:)
        when AST::BinaryOp
          infer_binary(expression, scopes:, expected_type:)
        when AST::IfExpr
          infer_if_expression(expression, scopes:, expected_type:)
        when AST::Call
          infer_call(expression, scopes:, expected_type:)
        when AST::UsingCall
          infer_using_call(expression, scopes:, expected_type:)
        when AST::Specialization
          raise SemaError, "specialized name #{describe_expression(expression)} must be called"
        else
          raise SemaError, "unsupported expression #{expression.class.name}"
        end
      end

      def infer_integer_literal(expected_type)
        if expected_type.is_a?(Types::Primitive) && expected_type.integer?
          expected_type
        else
          @types.fetch("i32")
        end
      end

      def infer_float_literal(expected_type)
        if expected_type.is_a?(Types::Primitive) && expected_type.float?
          expected_type
        else
          @types.fetch("f64")
        end
      end

      def infer_identifier(expression, scopes:, expected_type: nil)
        binding = lookup_value(expression.name, scopes)
        return binding.type if binding

        if @top_level_functions.key?(expression.name)
          raise SemaError, "generic function #{expression.name} must be called" if @top_level_functions.fetch(expression.name).type_params.any?

          function_type = function_type_for_name(expression.name)
          return function_type if expected_type

          raise SemaError, "function #{expression.name} must be called"
        end

        raise SemaError, "module #{expression.name} cannot be used as a value" if @imports.key?(expression.name)
        raise SemaError, "type #{expression.name} cannot be used as a value" if @types.key?(expression.name)

        raise SemaError, "unknown name #{expression.name}"
      end

      def infer_member_access(expression, scopes:)
        type = resolve_type_expression(expression.receiver)
        if type
          member_type = resolve_type_member(type, expression.member)
          return member_type if member_type

          if (method = lookup_method(type, expression.member))
            raise SemaError, "associated function #{type}.#{expression.member} must be called" unless method.type.receiver_type.nil?
            raise SemaError, "method #{type}.#{expression.member} must be called"
          end

          raise SemaError, "unknown member #{type}.#{expression.member}"
        end

        if expression.receiver.is_a?(AST::Identifier) && @imports.key?(expression.receiver.name)
          imported_module = @imports.fetch(expression.receiver.name)
          value = imported_module.values[expression.member]
          return value.type if value

          if imported_module.functions.key?(expression.member)
            raise SemaError, "function #{expression.receiver.name}.#{expression.member} must be called"
          end

          if imported_module.types.key?(expression.member)
            raise SemaError, "type #{expression.receiver.name}.#{expression.member} cannot be used as a value"
          end

          if imported_module.private_value?(expression.member) || imported_module.private_function?(expression.member) || imported_module.private_type?(expression.member)
            raise SemaError, "#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}"
          end

          raise SemaError, "unknown member #{expression.receiver.name}.#{expression.member}"
        end

        receiver_type = infer_expression(expression.receiver, scopes:)
        if text_buffer_type?(receiver_type) && text_buffer_method_kind(receiver_type, expression.member)
          raise SemaError, "method #{receiver_type}.#{expression.member} must be called"
        end
        if str_builder_type?(receiver_type) && str_builder_method_kind(receiver_type, expression.member)
          raise SemaError, "method #{receiver_type}.#{expression.member} must be called"
        end
        if cstr_list_buffer_type?(receiver_type) && cstr_list_buffer_method_kind(receiver_type, expression.member)
          raise SemaError, "method #{receiver_type}.#{expression.member} must be called"
        end

        unless aggregate_type?(receiver_type)
          raise SemaError, "cannot access member #{expression.member} of #{receiver_type}"
        end

        field_type = receiver_type.field(expression.member)
        return field_type if field_type

        if lookup_method(receiver_type, expression.member)
          raise SemaError, "method #{receiver_type.name}.#{expression.member} must be called"
        end

        if (imported_module = imported_module_with_private_method(receiver_type, expression.member))
          raise SemaError, "#{receiver_type}.#{expression.member} is private to module #{imported_module.name}"
        end

        raise SemaError, "unknown field #{receiver_type}.#{expression.member}"
      end

      def infer_index_access(expression, scopes:)
        receiver_type = infer_expression(expression.receiver, scopes:)
        index_type = infer_expression(expression.index, scopes:)

        if array_type?(receiver_type) && !unsafe_context? && !addressable_storage_expression?(expression.receiver)
          raise SemaError, "safe array indexing requires an addressable array value; bind it to a local first"
        end

        infer_index_result_type(receiver_type, index_type)
      end

      def infer_unary(expression, scopes:, expected_type: nil)
        operand_type = infer_expression(expression.operand, scopes:, expected_type:)

        case expression.operator
        when "not"
          ensure_assignable!(operand_type, @types.fetch("bool"), "operator not requires bool, got #{operand_type}")
          @types.fetch("bool")
        when "+", "-"
          raise SemaError, "operator #{expression.operator} requires a numeric operand, got #{operand_type}" unless operand_type.numeric?

          operand_type
        when "~"
          raise SemaError, "operator ~ requires an integer or flags operand, got #{operand_type}" unless bitwise_type?(operand_type)

          operand_type
        when "out", "inout"
          raise SemaError, "#{expression.operator} is only allowed for foreign call arguments"
        else
          raise SemaError, "unsupported unary operator #{expression.operator}"
        end
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
                              when "+", "-", "*", "/", "%", "|", "&", "^"
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
            raise SemaError, "operator #{expression.operator} requires matching integer or flags types, got #{left_type} and #{right_type}"
          end

          left_type
        when "+", "-", "*", "/"
          pointer_result = pointer_arithmetic_result(expression.operator, left_type, right_type)
          return pointer_result if pointer_result

          result_type = common_numeric_type(left_type, right_type)
          unless result_type
            raise SemaError, "operator #{expression.operator} requires compatible numeric types, got #{left_type} and #{right_type}"
          end

          result_type
        when "%"
          result_type = common_integer_type(left_type, right_type)
          unless result_type
            raise SemaError, "operator % requires compatible integer types, got #{left_type} and #{right_type}"
          end

          result_type
        when "<<", ">>"
          unless left_type.is_a?(Types::Primitive) && left_type.integer? && right_type.is_a?(Types::Primitive) && right_type.integer?
            raise SemaError, "operator #{expression.operator} requires integer operands, got #{left_type} and #{right_type}"
          end

          left_type
        when "<", "<=", ">", ">="
          unless common_numeric_type(left_type, right_type)
            raise SemaError, "operator #{expression.operator} requires compatible numeric types, got #{left_type} and #{right_type}"
          end

          @types.fetch("bool")
        when "==", "!="
          unless common_numeric_type(left_type, right_type) || types_compatible?(left_type, right_type) || types_compatible?(right_type, left_type)
            raise SemaError, "operator #{expression.operator} requires comparable types, got #{left_type} and #{right_type}"
          end

          @types.fetch("bool")
        else
          raise SemaError, "unsupported binary operator #{expression.operator}"
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

        raise SemaError, "if expression branches require compatible types, got #{then_type} and #{else_type}"
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

      def infer_call(expression, scopes:, expected_type: nil, scratch: nil)
        callable_kind, callable, receiver = resolve_callable(expression.callee, scopes:)

        case callable_kind
        when :function
          callable = specialize_function_binding(callable, expression.arguments, scopes:)
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch && !foreign_function_binding?(callable)

          check_function_call(callable, expression.arguments, scopes:, scratch:)
          callable.owner.send(:check_function, callable) unless callable.type_arguments.empty?
          callable.type.return_type
        when :method
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          raise SemaError, "cannot call mut method #{callable.name} on an immutable receiver" if callable.type.receiver_mutable && !assignable_receiver?(receiver, scopes)

          check_function_call(callable, expression.arguments, scopes:, scratch:)
          callable.type.return_type
        when :str_buffer_clear, :str_buffer_as_str, :str_buffer_as_cstr, :str_buffer_capacity
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch

          check_text_buffer_method_call(callable_kind, receiver, expression.arguments, scopes:)
        when :str_builder_clear, :str_builder_assign, :str_builder_append, :str_builder_len, :str_builder_capacity, :str_builder_as_str, :str_builder_as_cstr
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch

          check_str_builder_method_call(callable_kind, receiver, expression.arguments, scopes:)
        when :cstr_list_buffer_clear, :cstr_list_buffer_assign, :cstr_list_buffer_as_cstrs, :cstr_list_buffer_capacity, :cstr_list_buffer_byte_capacity
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch

          check_cstr_list_buffer_method_call(callable_kind, receiver, expression.arguments, scopes:)
        when :struct
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_aggregate_construction(callable, expression.arguments, scopes:)
        when :array
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_array_construction(callable, expression.arguments, scopes:)
        when :cast
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_cast_call(callable, expression.arguments, scopes:)
        when :reinterpret
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_reinterpret_call(callable, expression.arguments, scopes:)
        when :zero
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_zero_call(callable, expression.arguments)
        when :result_ok, :result_err
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_result_construction(callable_kind, expression.arguments, scopes:, expected_type:)
        when :panic
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_panic_call(expression.arguments, scopes:)
        when :addr
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_addr_call(expression.arguments, scopes:)
        when :value
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_value_call(expression.arguments, scopes:)
        when :raw
          raise SemaError, "using scratch is only allowed for foreign calls" if scratch
          check_raw_call(expression.arguments, scopes:)
        else
          raise SemaError, "#{describe_expression(expression.callee)} is not callable"
        end
      end

      def infer_using_call(expression, scopes:, expected_type: nil)
        infer_call(expression.call, scopes:, expected_type:, scratch: expression.scratch)
      end

      def validate_using_scratch_expression!(expression, root_allowed: false)
        return unless expression

        case expression
        when AST::UsingCall
          unless root_allowed
            raise SemaError, "using scratch must be the top-level expression of a local initializer, assignment, return, or expression statement"
          end

          validate_using_scratch_expression!(expression.call, root_allowed: false)
          validate_using_scratch_expression!(expression.scratch, root_allowed: false)
        when AST::Call, AST::Specialization
          validate_using_scratch_expression!(expression.callee, root_allowed: false)
          expression.arguments.each do |argument|
            validate_using_scratch_expression!(argument.value, root_allowed: false)
          end
        when AST::UnaryOp
          validate_using_scratch_expression!(expression.operand, root_allowed: false)
        when AST::BinaryOp
          validate_using_scratch_expression!(expression.left, root_allowed: false)
          validate_using_scratch_expression!(expression.right, root_allowed: false)
        when AST::IfExpr
          validate_using_scratch_expression!(expression.condition, root_allowed: false)
          validate_using_scratch_expression!(expression.then_expression, root_allowed: false)
          validate_using_scratch_expression!(expression.else_expression, root_allowed: false)
        when AST::MemberAccess
          validate_using_scratch_expression!(expression.receiver, root_allowed: false)
        when AST::IndexAccess
          validate_using_scratch_expression!(expression.receiver, root_allowed: false)
          validate_using_scratch_expression!(expression.index, root_allowed: false)
        end
      end

      def validate_owned_foreign_expression!(expression, scopes:, root_allowed: false)
        return unless expression

        if (foreign_call = resolve_foreign_call_expression(expression, scopes:)) && foreign_call_owns_binding?(foreign_call[:binding])
          raise SemaError, "owned foreign calls must be top-level expression statements" unless root_allowed
        end

        case expression
        when AST::UsingCall
          validate_owned_foreign_expression!(expression.call, scopes:, root_allowed: false)
          validate_owned_foreign_expression!(expression.scratch, scopes:, root_allowed: false)
        when AST::Call, AST::Specialization
          validate_owned_foreign_expression!(expression.callee, scopes:, root_allowed: false)
          expression.arguments.each do |argument|
            validate_owned_foreign_expression!(argument.value, scopes:, root_allowed: false)
          end
        when AST::UnaryOp
          validate_owned_foreign_expression!(expression.operand, scopes:, root_allowed: false)
        when AST::BinaryOp
          validate_owned_foreign_expression!(expression.left, scopes:, root_allowed: false)
          validate_owned_foreign_expression!(expression.right, scopes:, root_allowed: false)
        when AST::IfExpr
          validate_owned_foreign_expression!(expression.condition, scopes:, root_allowed: false)
          validate_owned_foreign_expression!(expression.then_expression, scopes:, root_allowed: false)
          validate_owned_foreign_expression!(expression.else_expression, scopes:, root_allowed: false)
        when AST::MemberAccess
          validate_owned_foreign_expression!(expression.receiver, scopes:, root_allowed: false)
        when AST::IndexAccess
          validate_owned_foreign_expression!(expression.receiver, scopes:, root_allowed: false)
          validate_owned_foreign_expression!(expression.index, scopes:, root_allowed: false)
        end
      end

      def resolve_foreign_call_expression(expression, scopes:)
        call = expression.is_a?(AST::UsingCall) ? expression.call : expression
        return unless call.is_a?(AST::Call)

        callable_kind, callable, _receiver = resolve_callable(call.callee, scopes:)
        return unless callable_kind == :function

        callable = specialize_function_binding(callable, call.arguments, scopes:) if callable.type_params.any?
        return unless foreign_function_binding?(callable)

        { call:, binding: callable }
      rescue SemaError
        nil
      end

      def foreign_call_owns_binding?(binding)
        binding.type.params.any? { |parameter| parameter.passing_mode == :owned }
      end

      def owned_foreign_call_refinements(expression, scopes:)
        foreign_call = resolve_foreign_call_expression(expression, scopes:)
        return {} unless foreign_call

        binding = foreign_call[:binding]
        return {} unless foreign_call_owns_binding?(binding)

        binding.type.params.each_with_index.each_with_object({}) do |(parameter, index), refinements|
          next unless parameter.passing_mode == :owned

          argument = foreign_call[:call].arguments.fetch(index)
          argument_binding = foreign_owned_argument_binding(parameter, argument, scopes:, function_name: binding.name)
          refinements[argument.value.name] = @null_type if argument_binding.storage_type.is_a?(Types::Nullable)
        end
      end

      def resolve_callable(callee, scopes:)
        case callee
        when AST::Identifier
          return [:function, @top_level_functions.fetch(callee.name), nil] if @top_level_functions.key?(callee.name)
          return [:result_ok, nil, nil] if callee.name == "ok"
          return [:result_err, nil, nil] if callee.name == "err"
          return [:panic, nil, nil] if callee.name == "panic"
          return [:addr, nil, nil] if callee.name == "addr"
          return [:value, nil, nil] if callee.name == "value"
          return [:raw, nil, nil] if callee.name == "raw"

          type = @types[callee.name]
          return [:struct, type, nil] if type.is_a?(Types::Struct) || type.is_a?(Types::StringView)

          raise SemaError, "unknown callable #{callee.name}"
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @imports.key?(callee.receiver.name)
            imported_module = @imports.fetch(callee.receiver.name)
            return [:function, imported_module.functions.fetch(callee.member), nil] if imported_module.functions.key?(callee.member)
            imported_type = imported_module.types[callee.member]
            if imported_type.is_a?(Types::Struct) || imported_type.is_a?(Types::StringView)
              return [:struct, imported_module.types.fetch(callee.member), nil]
            end

            if imported_module.private_function?(callee.member) || imported_module.private_type?(callee.member) || imported_module.private_value?(callee.member)
              raise SemaError, "#{callee.receiver.name}.#{callee.member} is private to module #{imported_module.name}"
            end

            raise SemaError, "unknown callable #{callee.receiver.name}.#{callee.member}"
          end

          if (type_expr = resolve_type_expression(callee.receiver))
            method = lookup_method(type_expr, callee.member)
            return [:function, method, nil] if method && method.type.receiver_type.nil?

            raise SemaError, "unknown associated function #{type_expr}.#{callee.member}"
          end

          receiver_type = infer_expression(callee.receiver, scopes:)
          method = lookup_method(receiver_type, callee.member)
          return [:method, method, callee.receiver] if method

          if (text_buffer_method = text_buffer_method_kind(receiver_type, callee.member))
            return [text_buffer_method, receiver_type, callee.receiver]
          end

          if (str_builder_method = str_builder_method_kind(receiver_type, callee.member))
            return [str_builder_method, receiver_type, callee.receiver]
          end

          if (cstr_list_buffer_method = cstr_list_buffer_method_kind(receiver_type, callee.member))
            return [cstr_list_buffer_method, receiver_type, callee.receiver]
          end

          if (imported_module = imported_module_with_private_method(receiver_type, callee.member))
            raise SemaError, "#{receiver_type}.#{callee.member} is private to module #{imported_module.name}"
          end

          raise SemaError, "unknown method #{receiver_type}.#{callee.member}"
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
            raise SemaError, "cast requires exactly one type argument" unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise SemaError, "cast type argument must be a type" unless type_arg.is_a?(AST::TypeRef)

            return [:cast, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "reinterpret"
            raise SemaError, "reinterpret requires exactly one type argument" unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise SemaError, "reinterpret type argument must be a type" unless type_arg.is_a?(AST::TypeRef)

            return [:reinterpret, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "array"
            raise SemaError, "array requires exactly two type arguments" unless callee.arguments.length == 2

            array_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["array"]), arguments: callee.arguments, nullable: false))
            raise SemaError, "array specialization must be array[T, N]" unless array_type?(array_type)

            return [:array, array_type, nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "str_buffer"
            raise SemaError, "str_buffer requires exactly one type argument" unless callee.arguments.length == 1

            text_buffer_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["str_buffer"]), arguments: callee.arguments, nullable: false))
            raise SemaError, "str_buffer specialization must be str_buffer[N]" unless text_buffer_type?(text_buffer_type)

            return [:array, text_buffer_type, nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "span"
            raise SemaError, "span requires exactly one type argument" unless callee.arguments.length == 1

            span_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: callee.arguments, nullable: false))
            raise SemaError, "span specialization must be span[T]" unless span_type?(span_type)

            return [:struct, span_type, nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "zero"
            raise SemaError, "zero requires exactly one type argument" unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise SemaError, "zero type argument must be a type" unless type_arg.is_a?(AST::TypeRef)

            return [:zero, resolve_type_ref(type_arg), nil]
          end

          if (function_binding = resolve_specialized_function_binding(callee))
            return [:function, function_binding, nil]
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct, specialized_type, nil] if specialized_type.is_a?(Types::Struct)
          end

          raise SemaError, "unsupported callable specialization #{describe_expression(callee)}"
        else
          raise SemaError, "unsupported callee #{describe_expression(callee)}"
        end
      end

      def check_function_call(binding, arguments, scopes:, scratch: nil)
        if arguments.any?(&:name)
          raise SemaError, "function #{binding.name} does not support named arguments"
        end

        expected_params = binding.type.params
        requires_scratch = false
        unless call_arity_matches?(binding.type, arguments.length)
          raise SemaError, arity_error_message(binding.type, binding.name, arguments.length)
        end

        expected_params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          actual_type = foreign_argument_actual_type(parameter, argument, scopes:, function_name: binding.name)
          if foreign_cstr_boundary_parameter?(parameter)
            unless foreign_cstr_argument_compatible?(actual_type, parameter, expression: foreign_argument_expression(argument))
              raise SemaError, "argument #{parameter.name} to #{binding.name} expects #{parameter.type}, got #{actual_type}"
            end

            requires_scratch ||= foreign_argument_requires_scratch?(parameter, argument, actual_type)
          else
            ensure_argument_assignable!(
              actual_type,
              parameter.type,
              external: binding.external,
              message: "argument #{parameter.name} to #{binding.name} expects #{parameter.type}, got #{actual_type}",
              expression: foreign_argument_expression(argument),
            ) unless array_to_span_call_argument_compatible?(actual_type, parameter.type, expression: foreign_argument_expression(argument), scopes:)

            requires_scratch ||= foreign_argument_requires_scratch?(parameter, argument, actual_type)
          end
        end

        if foreign_function_binding?(binding)
          if scratch
            raise SemaError, "using scratch is not needed for foreign call #{binding.name}" unless requires_scratch

            validate_foreign_scratch!(binding, scratch, scopes:, requires_scratch:)
          elsif requires_scratch
            raise SemaError, "foreign call #{binding.name} requires using scratch"
          end
        end

        arguments.drop(expected_params.length).each do |argument|
          infer_expression(argument.value, scopes:)
        end
      end

      def call_arity_matches?(function_type, actual_count)
        return actual_count >= function_type.params.length if function_type.variadic

        actual_count == function_type.params.length
      end

      def arity_error_message(function_type, name, actual_count)
        if function_type.variadic
          "function #{name} expects at least #{function_type.params.length} arguments, got #{actual_count}"
        else
          "function #{name} expects #{function_type.params.length} arguments, got #{actual_count}"
        end
      end

      def check_result_construction(kind, arguments, scopes:, expected_type:)
        name = kind == :result_ok ? "ok" : "err"
        raise SemaError, "#{name} does not support named arguments" if arguments.any?(&:name)
        raise SemaError, "#{name} expects 1 argument, got #{arguments.length}" unless arguments.length == 1
        raise SemaError, "cannot infer result type for #{name} without an expected Result[T, E]" unless result_type?(expected_type)

        field_type = kind == :result_ok ? expected_type.ok_type : expected_type.error_type
        actual_type = infer_expression(arguments.first.value, scopes:, expected_type: field_type)
        ensure_assignable!(
          actual_type,
          field_type,
          "argument to #{name} expects #{field_type}, got #{actual_type}",
          expression: arguments.first.value,
        )
        expected_type
      end

      def check_panic_call(arguments, scopes:)
        raise SemaError, "panic does not support named arguments" if arguments.any?(&:name)
        raise SemaError, "panic expects 1 argument, got #{arguments.length}" unless arguments.length == 1

        message_type = infer_expression(arguments.first.value, scopes:, expected_type: @types.fetch("str"))
        return @types.fetch("void") if string_like_type?(message_type)

        raise SemaError, "panic expects str or cstr, got #{message_type}"
      end

      def check_addr_call(arguments, scopes:)
        raise SemaError, "addr does not support named arguments" if arguments.any?(&:name)
        raise SemaError, "addr expects 1 argument, got #{arguments.length}" unless arguments.length == 1

        source_type = infer_addr_source_type(arguments.first.value, scopes:)
        Types::GenericInstance.new("ref", [source_type])
      end

      def check_value_call(arguments, scopes:)
        validate_value_call_arguments!(arguments)

        infer_value_target_type(arguments.first.value, scopes:)
      end

      def check_raw_call(arguments, scopes:)
        raise SemaError, "raw does not support named arguments" if arguments.any?(&:name)
        raise SemaError, "raw expects 1 argument, got #{arguments.length}" unless arguments.length == 1

        source_type = infer_expression(arguments.first.value, scopes:)
        raise SemaError, "raw expects ref[...] argument, got #{source_type}" unless ref_type?(source_type)

        pointer_to(referenced_type(source_type))
      end

      def check_aggregate_construction(struct_type, arguments, scopes:)
        display_name = aggregate_display_name(struct_type)

        if struct_type.is_a?(Types::StringView)
          raise SemaError, "str construction requires unsafe" unless unsafe_context?
        end

        raise SemaError, "aggregate construction for #{display_name} requires named arguments" unless arguments.all?(&:name)

        provided = {}
        arguments.each do |argument|
          field_type = struct_type.field(argument.name)
          raise SemaError, "unknown field #{display_name}.#{argument.name}" unless field_type
          raise SemaError, "duplicate field #{display_name}.#{argument.name}" if provided.key?(argument.name)

          actual_type = infer_expression(argument.value, scopes:, expected_type: field_type)
          ensure_assignable!(
            actual_type,
            field_type,
            "field #{display_name}.#{argument.name} expects #{field_type}, got #{actual_type}",
            expression: argument.value,
            external_numeric: struct_type.respond_to?(:external) && struct_type.external,
          )
          provided[argument.name] = true
        end

        struct_type
      end

      def check_array_construction(array_type, arguments, scopes:)
        raise SemaError, "array construction does not support named arguments" if arguments.any?(&:name)

        element_type = array_element_type(array_type)
        length = array_length(array_type)
        raise SemaError, "array expects at most #{length} elements, got #{arguments.length}" if arguments.length > length

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
        raise SemaError, "cast requires exactly one argument" unless arguments.length == 1
        raise SemaError, "cast does not support named arguments" if arguments.first.name

        source_type = infer_expression(arguments.first.value, scopes:)
        if source_type == target_type
          return target_type
        end

        if pointer_cast?(source_type, target_type)
          raise SemaError, "pointer cast requires unsafe" unless unsafe_context?

          return target_type
        end

        if ref_to_pointer_cast?(source_type, target_type)
          raise SemaError, "ref to pointer cast requires unsafe" unless unsafe_context?

          return target_type
        end

        source_numeric_type = cast_numeric_type(source_type)
        target_numeric_type = cast_numeric_type(target_type)

        unless source_numeric_type && target_numeric_type
          raise SemaError, "cast currently only supports numeric primitive types, got #{source_type} -> #{target_type}"
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
          raise SemaError, "typed null requires pointer-like type, got #{target_type}"
        end

        Types::Null.new(target_type)
      end

      def check_reinterpret_call(target_type, arguments, scopes:)
        raise SemaError, "reinterpret requires exactly one argument" unless arguments.length == 1
        raise SemaError, "reinterpret does not support named arguments" if arguments.first.name
        raise SemaError, "reinterpret requires unsafe" unless unsafe_context?

        source_type = infer_expression(arguments.first.value, scopes:)
        unless reinterpretable_type?(source_type) && reinterpretable_type?(target_type)
          raise SemaError, "reinterpret requires non-array concrete sized types, got #{source_type} -> #{target_type}"
        end

        target_type
      end

      def check_zero_call(target_type, arguments)
        raise SemaError, "zero expects 0 arguments, got #{arguments.length}" unless arguments.empty?

        zero_initializable_type?(target_type)
        target_type
      end

      def check_text_buffer_method_call(kind, receiver, arguments, scopes:)
        method_name = text_buffer_method_name(kind)
        raise SemaError, "#{method_name} does not support named arguments" if arguments.any?(&:name)
        raise SemaError, "#{method_name} expects 0 arguments, got #{arguments.length}" unless arguments.empty?

        receiver_type = infer_expression(receiver, scopes:)
        raise SemaError, "unknown method #{receiver_type}.#{method_name}" unless text_buffer_type?(receiver_type)

        case kind
        when :str_buffer_clear
          raise SemaError, "cannot call mut method #{receiver_type}.clear on an immutable receiver" unless assignable_receiver?(receiver, scopes)

          @types.fetch("void")
        when :str_buffer_as_str
          raise SemaError, "#{receiver_type}.as_str requires a safe stored receiver" unless safe_reference_source_expression?(receiver, scopes:)

          @types.fetch("str")
        when :str_buffer_as_cstr
          raise SemaError, "#{receiver_type}.as_cstr requires a safe stored receiver" unless safe_reference_source_expression?(receiver, scopes:)

          @types.fetch("cstr")
        when :str_buffer_capacity
          @types.fetch("usize")
        else
          raise SemaError, "unsupported str_buffer method #{kind}"
        end
      end

      def check_str_builder_method_call(kind, receiver, arguments, scopes:)
        method_name = str_builder_method_name(kind)
        receiver_type = infer_expression(receiver, scopes:)
        raise SemaError, "unknown method #{receiver_type}.#{method_name}" unless str_builder_type?(receiver_type)

        case kind
        when :str_builder_clear, :str_builder_len, :str_builder_capacity, :str_builder_as_str, :str_builder_as_cstr
          raise SemaError, "#{method_name} does not support named arguments" if arguments.any?(&:name)
          raise SemaError, "#{method_name} expects 0 arguments, got #{arguments.length}" unless arguments.empty?
        when :str_builder_assign, :str_builder_append
          raise SemaError, "#{method_name} does not support named arguments" if arguments.any?(&:name)
          raise SemaError, "#{method_name} expects 1 argument, got #{arguments.length}" unless arguments.length == 1
        else
          raise SemaError, "unsupported str_builder method #{kind}"
        end

        case kind
        when :str_builder_clear
          raise SemaError, "cannot call mut method #{receiver_type}.clear on an immutable receiver" unless assignable_receiver?(receiver, scopes)

          @types.fetch("void")
        when :str_builder_assign, :str_builder_append
          raise SemaError, "cannot call mut method #{receiver_type}.#{method_name} on an immutable receiver" unless assignable_receiver?(receiver, scopes)

          actual_type = infer_expression(arguments.first.value, scopes:, expected_type: @types.fetch("str"))
          ensure_argument_assignable!(
            actual_type,
            @types.fetch("str"),
            external: false,
            message: "argument value to #{receiver_type}.#{method_name} expects str, got #{actual_type}",
            expression: arguments.first.value,
          )

          @types.fetch("void")
        when :str_builder_len, :str_builder_capacity
          @types.fetch("usize")
        when :str_builder_as_str
          raise SemaError, "#{receiver_type}.as_str requires a safe stored receiver" unless safe_reference_source_expression?(receiver, scopes:)

          @types.fetch("str")
        when :str_builder_as_cstr
          raise SemaError, "#{receiver_type}.as_cstr requires a safe stored receiver" unless safe_reference_source_expression?(receiver, scopes:)

          @types.fetch("cstr")
        else
          raise SemaError, "unsupported str_builder method #{kind}"
        end
      end

      def check_cstr_list_buffer_method_call(kind, receiver, arguments, scopes:)
        method_name = cstr_list_buffer_method_name(kind)
        receiver_type = infer_expression(receiver, scopes:)
        raise SemaError, "unknown method #{receiver_type}.#{method_name}" unless cstr_list_buffer_type?(receiver_type)

        case kind
        when :cstr_list_buffer_clear
          raise SemaError, "#{method_name} does not support named arguments" if arguments.any?(&:name)
          raise SemaError, "#{method_name} expects 0 arguments, got #{arguments.length}" unless arguments.empty?
          raise SemaError, "cannot call mut method #{receiver_type}.clear on an immutable receiver" unless assignable_receiver?(receiver, scopes)

          @types.fetch("void")
        when :cstr_list_buffer_assign
          raise SemaError, "#{method_name} does not support named arguments" if arguments.any?(&:name)
          raise SemaError, "#{method_name} expects 1 argument, got #{arguments.length}" unless arguments.length == 1
          raise SemaError, "cannot call mut method #{receiver_type}.assign on an immutable receiver" unless assignable_receiver?(receiver, scopes)

          expected_type = Types::Span.new(@types.fetch("str"))
          argument = arguments.first
          actual_type = infer_expression(argument.value, scopes:, expected_type: expected_type)
          ensure_argument_assignable!(
            actual_type,
            expected_type,
            external: false,
            message: "argument items to #{receiver_type}.assign expects #{expected_type}, got #{actual_type}",
            expression: argument.value,
          ) unless array_to_span_call_argument_compatible?(actual_type, expected_type, expression: argument.value, scopes:)

          @types.fetch("void")
        when :cstr_list_buffer_as_cstrs
          raise SemaError, "#{method_name} does not support named arguments" if arguments.any?(&:name)
          raise SemaError, "#{method_name} expects 0 arguments, got #{arguments.length}" unless arguments.empty?
          raise SemaError, "#{receiver_type}.as_cstrs requires a safe stored receiver" unless safe_reference_source_expression?(receiver, scopes:)

          Types::Span.new(@types.fetch("cstr"))
        when :cstr_list_buffer_capacity, :cstr_list_buffer_byte_capacity
          raise SemaError, "#{method_name} does not support named arguments" if arguments.any?(&:name)
          raise SemaError, "#{method_name} expects 0 arguments, got #{arguments.length}" unless arguments.empty?

          @types.fetch("usize")
        else
          raise SemaError, "unsupported cstr_list_buffer method #{kind}"
        end
      end

      def lookup_value(name, scopes)
        scopes.reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        @top_level_values[name]
      end

      def lookup_method(receiver_type, name)
        method = @methods.fetch(receiver_type, {})[name]
        return method if method

        @imports.each_value do |module_binding|
          next unless module_binding.methods.key?(receiver_type)

          imported_method = module_binding.methods.fetch(receiver_type)[name]
          return imported_method if imported_method
        end

        nil
      end

      def text_buffer_method_kind(receiver_type, name)
        return unless text_buffer_type?(receiver_type)

        case name
        when "clear"
          :str_buffer_clear
        when "as_str"
          :str_buffer_as_str
        when "as_cstr"
          :str_buffer_as_cstr
        when "capacity"
          :str_buffer_capacity
        end
      end

      def str_builder_method_kind(receiver_type, name)
        return unless str_builder_type?(receiver_type)

        case name
        when "clear"
          :str_builder_clear
        when "assign"
          :str_builder_assign
        when "append"
          :str_builder_append
        when "len"
          :str_builder_len
        when "capacity"
          :str_builder_capacity
        when "as_str"
          :str_builder_as_str
        when "as_cstr"
          :str_builder_as_cstr
        end
      end

      def cstr_list_buffer_method_kind(receiver_type, name)
        return unless cstr_list_buffer_type?(receiver_type)

        case name
        when "clear"
          :cstr_list_buffer_clear
        when "assign"
          :cstr_list_buffer_assign
        when "as_cstrs"
          :cstr_list_buffer_as_cstrs
        when "capacity"
          :cstr_list_buffer_capacity
        when "byte_capacity"
          :cstr_list_buffer_byte_capacity
        end
      end

      def text_buffer_method_name(kind)
        {
          str_buffer_clear: "clear",
          str_buffer_as_str: "as_str",
          str_buffer_as_cstr: "as_cstr",
          str_buffer_capacity: "capacity",
        }.fetch(kind)
      end

      def str_builder_method_name(kind)
        {
          str_builder_clear: "clear",
          str_builder_assign: "assign",
          str_builder_append: "append",
          str_builder_len: "len",
          str_builder_capacity: "capacity",
          str_builder_as_str: "as_str",
          str_builder_as_cstr: "as_cstr",
        }.fetch(kind)
      end

      def cstr_list_buffer_method_name(kind)
        {
          cstr_list_buffer_clear: "clear",
          cstr_list_buffer_assign: "assign",
          cstr_list_buffer_as_cstrs: "as_cstrs",
          cstr_list_buffer_capacity: "capacity",
          cstr_list_buffer_byte_capacity: "byte_capacity",
        }.fetch(kind)
      end

      def ensure_available_type_name!(name)
        raise SemaError, "duplicate type #{name}" if @types.key?(name)
      end

      def ensure_available_value_name!(name)
        raise SemaError, "duplicate value #{name}" if @top_level_values.key?(name) || @top_level_functions.key?(name)
      end

      def current_type_params
        @current_type_substitutions || {}
      end

      def resolve_type_ref(type_ref, type_params: current_type_params)
        base = resolve_non_nullable_type(type_ref, type_params:)
        return base if type_ref.is_a?(AST::FunctionType)

        raise SemaError, "ref types are non-null and cannot be nullable" if type_ref.nullable && ref_type?(base)

        type_ref.nullable ? Types::Nullable.new(base) : base
      end

      def resolve_non_nullable_type(type_ref, type_params: {})
        if type_ref.is_a?(AST::FunctionType)
          params = type_ref.params.map do |param|
            Types::Parameter.new(param.name, resolve_type_ref(param.type, type_params:), mutable: param.mutable)
          end
          return Types::Function.new(nil, params:, return_type: resolve_type_ref(type_ref.return_type, type_params:))
        end

        parts = type_ref.name.parts

        if type_ref.arguments.any?
          name = parts.join(".")
          arguments = type_ref.arguments.map do |argument|
            case argument.value
            when AST::TypeRef
              resolve_type_ref(argument.value, type_params:)
            when AST::IntegerLiteral
              Types::LiteralTypeArg.new(argument.value.value)
            when AST::FloatLiteral
              Types::LiteralTypeArg.new(argument.value.value)
            else
              raise SemaError, "unsupported type argument #{argument.value.class.name}"
            end
          end

          if name != "ref" && arguments.any? { |argument| contains_ref_type?(argument) }
            raise SemaError, "ref types cannot be nested inside #{name}"
          end

          if name == "Result"
            validate_generic_type!(name, arguments)
            return Types::Result.new(arguments[0], arguments[1])
          end

          if (generic_type = resolve_named_generic_type(parts))
            begin
              return generic_type.instantiate(arguments)
            rescue ArgumentError => error
              raise SemaError, error.message
            end
          end

          validate_generic_type!(name, arguments)
          return Types::Span.new(arguments.first) if name == "span"

          return Types::GenericInstance.new(name, arguments)
        end

        if parts.length == 1
          return type_params.fetch(parts.first) if type_params.key?(parts.first)

          type = @types[parts.first]
          raise SemaError, "unknown type #{parts.first}" unless type
          raise SemaError, "generic type #{parts.first} requires type arguments" if type.is_a?(Types::GenericStructDefinition)

          return type
        end

        if parts.length == 2 && @imports.key?(parts.first)
          imported_module = @imports.fetch(parts.first)
          type = imported_module.types[parts.last]
          if imported_module.private_type?(parts.last)
            raise SemaError, "#{parts.first}.#{parts.last} is private to module #{imported_module.name}"
          end
          raise SemaError, "unknown type #{type_ref.name}" unless type
          raise SemaError, "generic type #{type_ref.name} requires type arguments" if type.is_a?(Types::GenericStructDefinition)

          return type
        end

        raise SemaError, "unknown type #{type_ref.name}"
      end

      def ensure_assignable!(actual_type, expected_type, message, expression: nil, external_numeric: false, contextual_int_to_float: false)
        raise SemaError, message unless types_compatible?(actual_type, expected_type, expression:, external_numeric:, contextual_int_to_float:)
      end

      def ensure_argument_assignable!(actual_type, expected_type, external:, message:, expression: nil)
        raise SemaError, message unless argument_types_compatible?(actual_type, expected_type, external:, expression:)
      end

      def types_compatible?(actual_type, expected_type, expression: nil, external_numeric: false, contextual_int_to_float: false)
        return true if actual_type == expected_type
        return true if null_assignable_to?(actual_type, expected_type)
        return true if expected_type.is_a?(Types::Nullable) && actual_type == expected_type.base
        return true if actual_type.is_a?(Types::EnumBase) && actual_type.backing_type == expected_type
        return true if string_literal_cstr_compatibility?(expression, expected_type)
        return true if integer_literal_numeric_compatibility?(expression, expected_type)
        return true if integer_to_char_compatibility?(actual_type, expected_type)
        return true if external_numeric && external_numeric_compatibility?(actual_type, expected_type)
        return true if contextual_int_to_float && contextual_int_to_float_compatibility?(actual_type, expected_type)

        false
      end

      def string_literal_cstr_compatibility?(expression, expected_type)
        expression.is_a?(AST::StringLiteral) && !expression.cstring && expected_type == @types.fetch("cstr")
      end

      def argument_types_compatible?(actual_type, expected_type, external:, expression: nil)
        return true if types_compatible?(actual_type, expected_type, expression:, external_numeric: external)
        return true if external && extern_enum_integer_argument_compatibility?(actual_type, expected_type)
        if external && foreign_mapping_context? && foreign_identity_projection_compatible?(actual_type, expected_type)
          return false if actual_type == @types.fetch("cstr") && char_pointer_type?(expected_type)

          return true
        end

        false
      end

      def integer_literal_numeric_compatibility?(expression, expected_type)
        integer_literal_expression?(expression) && expected_type.is_a?(Types::Primitive) && expected_type.numeric?
      end

      def integer_to_char_compatibility?(actual_type, expected_type)
        char_type?(expected_type) && integer_like_char_source_type?(actual_type)
      end

      def integer_like_char_source_type?(type)
        return true if type.is_a?(Types::Primitive) && type.integer?
        return true if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?

        false
      end

      def char_type?(type)
        type.is_a?(Types::Primitive) && type.name == "char"
      end

      def null_assignable_to?(actual_type, expected_type)
        return false unless actual_type.is_a?(Types::Null)
        return false unless expected_type.is_a?(Types::Nullable)
        return true unless actual_type.target_type

        actual_type.target_type == expected_type.base
      end

      def integer_literal_expression?(expression)
        expression.is_a?(AST::IntegerLiteral) ||
          (expression.is_a?(AST::UnaryOp) && ["+", "-"].include?(expression.operator) && integer_literal_expression?(expression.operand))
      end

      def external_numeric_compatibility?(actual_type, expected_type)
        actual_type.is_a?(Types::Primitive) && actual_type.numeric? &&
          expected_type.is_a?(Types::Primitive) && expected_type.numeric?
      end

      def contextual_int_to_float_compatibility?(actual_type, expected_type)
        actual_type.is_a?(Types::Primitive) && actual_type.integer? &&
          expected_type.is_a?(Types::Primitive) && expected_type.float?
      end

      def contextual_int_to_float_target?(type)
        type.is_a?(Types::Primitive) && type.float?
      end

      def foreign_identity_projection_compatible?(actual_type, expected_type)
        foreign_identity_projection_cast_compatible?(actual_type, expected_type) ||
          foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type)
      end

      def foreign_identity_projection_cast_compatible?(actual_type, expected_type)
        return true if actual_type == expected_type

        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          return foreign_identity_projection_cast_compatible?(actual_type.base, expected_type.base)
        end

        return foreign_identity_projection_cast_compatible?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
        return false if actual_type.is_a?(Types::Nullable)

        if pointer_type?(actual_type) && pointer_type?(expected_type)
          return true if void_pointer_type?(actual_type) || void_pointer_type?(expected_type)

          return true if foreign_identity_projection_cast_compatible?(actual_type.arguments.first, expected_type.arguments.first)

          return foreign_external_layout_compatible?(actual_type.arguments.first, expected_type.arguments.first)
        end

        return true if void_pointer_type?(actual_type) && opaque_type?(expected_type)
        return true if opaque_type?(actual_type) && void_pointer_type?(expected_type)
        return true if char_pointer_type?(actual_type) && expected_type == @types.fetch("cstr")
        return true if actual_type == @types.fetch("cstr") && char_pointer_type?(expected_type)

        false
      end

      def foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type)
        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          return foreign_identity_projection_reinterpret_compatible?(actual_type.base, expected_type.base)
        end

        return foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
        return false if actual_type.is_a?(Types::Nullable)

        foreign_external_layout_compatible?(actual_type, expected_type)
      end

      def foreign_external_layout_compatible?(actual_type, expected_type, seen = {})
        return false unless actual_type.is_a?(Types::Struct) && expected_type.is_a?(Types::Struct)
        return false if actual_type.is_a?(Types::Union) != expected_type.is_a?(Types::Union)
        return false unless actual_type.external && expected_type.external
        return false unless actual_type.name == expected_type.name
        return false unless actual_type.packed == expected_type.packed
        return false unless actual_type.alignment == expected_type.alignment

        key = [actual_type.object_id, expected_type.object_id]
        return true if seen[key]

        seen[key] = true
        actual_fields = actual_type.fields
        expected_fields = expected_type.fields
        return false unless actual_fields.keys == expected_fields.keys

        actual_fields.all? do |field_name, field_type|
          foreign_external_layout_field_compatible?(field_type, expected_fields.fetch(field_name), seen)
        end
      end

      def foreign_external_layout_field_compatible?(actual_type, expected_type, seen)
        return true if actual_type == expected_type

        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          return foreign_external_layout_field_compatible?(actual_type.base, expected_type.base, seen)
        end

        if pointer_type?(actual_type) && pointer_type?(expected_type)
          return foreign_external_layout_field_compatible?(actual_type.arguments.first, expected_type.arguments.first, seen)
        end

        if array_type?(actual_type) && array_type?(expected_type)
          return false unless array_length(actual_type) == array_length(expected_type)

          return foreign_external_layout_field_compatible?(array_element_type(actual_type), array_element_type(expected_type), seen)
        end

        foreign_external_layout_compatible?(actual_type, expected_type, seen)
      end

      def void_pointer_type?(type)
        pointer_type?(type) && type.arguments.first == @types.fetch("void")
      end

      def char_pointer_type?(type)
        pointer_type?(type) && type.arguments.first == @types.fetch("char")
      end

      def opaque_type?(type)
        type.is_a?(Types::Opaque)
      end

      def extern_enum_integer_argument_compatibility?(actual_type, expected_type)
        return unless actual_type.is_a?(Types::EnumBase)
        return unless expected_type.is_a?(Types::Primitive) && expected_type.integer? && expected_type.fixed_width_integer?

        backing_type = actual_type.backing_type
        return unless backing_type.is_a?(Types::Primitive) && backing_type.integer? && backing_type.fixed_width_integer?

        backing_type.integer_width == expected_type.integer_width
      end

      def common_numeric_type(left_type, right_type)
        return left_type if left_type == right_type
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.numeric? && right_type.numeric?

        return common_integer_type(left_type, right_type) if left_type.integer? && right_type.integer?
        return wider_float_type(left_type, right_type) if left_type.float? && right_type.float?

        float_type, integer_type = left_type.float? ? [left_type, right_type] : [right_type, left_type]
        return unless integer_type.integer? && integer_type.fixed_width_integer?

        float_type
      end

      def common_integer_type(left_type, right_type)
        return left_type if left_type == right_type
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.integer? && right_type.integer?
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

      def with_foreign_mapping_context
        @foreign_mapping_depth += 1
        yield
      ensure
        @foreign_mapping_depth -= 1
      end

      def with_loop
        @loop_depth += 1
        yield
      ensure
        @loop_depth -= 1
      end

      def unsafe_context?
        @unsafe_depth.positive?
      end

      def inside_loop?
        @loop_depth.positive?
      end

      def foreign_mapping_context?
        @foreign_mapping_depth.positive?
      end

      def pointer_arithmetic_result(operator, left_type, right_type)
        if pointer_type?(left_type) && integer_type?(right_type)
          raise SemaError, "pointer arithmetic requires unsafe" unless unsafe_context?

          return left_type if operator == "+" || operator == "-"
        end

        if operator == "+" && integer_type?(left_type) && pointer_type?(right_type)
          raise SemaError, "pointer arithmetic requires unsafe" unless unsafe_context?

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
        return pointer_type?(type.base) if type.is_a?(Types::Nullable)

        pointer_type?(type)
      end

      def typed_null_target_type?(type)
        type == @types.fetch("cstr") || pointer_type?(type)
      end

      def pointer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
      end

      def opaque_type?(type)
        type.is_a?(Types::Opaque)
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

      def result_type?(type)
        type.is_a?(Types::Result)
      end

      def infer_layout_query_type(type_ref, context:)
        type = resolve_type_ref(type_ref)
        return type if sized_layout_type?(type)

        raise SemaError, "#{context} requires a concrete sized type, got #{type}"
      end

      def infer_offsetof_type(type_ref, field_name)
        type = resolve_type_ref(type_ref)
        unless layout_aggregate_type?(type)
          raise SemaError, "offsetof requires a struct, union, span, Result, or str type, got #{type}"
        end

        field_type = type.field(field_name)
        raise SemaError, "unknown field #{type}.#{field_name}" unless field_type

        type
      end

      def sized_layout_type?(type)
        case type
        when Types::Primitive, Types::Struct, Types::StructInstance, Types::Union, Types::Enum, Types::Flags, Types::Span, Types::StringView, Types::Result
          true
        when Types::Nullable
          true
        when Types::GenericInstance
          pointer_type?(type) || array_type?(type) || str_builder_type?(type) || cstr_list_buffer_type?(type)
        else
          false
        end
      end

      def reinterpretable_type?(type)
        return false if array_type?(type)
        return false if type.is_a?(Types::Primitive) && type.void?

        sized_layout_type?(type)
      end

      def zero_initializable_type?(type)
        return true if type.is_a?(Types::Primitive) && !type.void?
        return true if type.is_a?(Types::Nullable)
        return true if type.is_a?(Types::EnumBase)
        return true if span_type?(type)
        return true if string_view_type?(type)
        return true if result_type?(type)
        return true if type.is_a?(Types::Struct)
        return true if pointer_type?(type)
        return true if array_type?(type)
        return true if str_builder_type?(type)
        return true if cstr_list_buffer_type?(type)

        raise SemaError, "zero does not support type #{type}"
      end

      def layout_aggregate_type?(type)
        type.respond_to?(:field) && !type.is_a?(Types::Opaque) && !type.is_a?(Types::EnumBase)
      end

      def power_of_two?(value)
        (value & (value - 1)).zero?
      end

      def aggregate_type?(type)
        type.is_a?(Types::Struct) || span_type?(type) || string_view_type?(type) || result_type?(type)
      end

      def array_type?(type)
        text_buffer_type?(type) ||
          (type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
          !type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments[1].is_a?(Types::LiteralTypeArg))
      end

      def array_element_type(type)
        return unless array_type?(type)

        return @types.fetch("char") if text_buffer_type?(type)

        type.arguments.first
      end

      def array_length(type)
        return unless array_type?(type)

        return type.arguments.first.value if text_buffer_type?(type)

        type.arguments[1].value
      end

      def str_builder_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "str_builder" && type.arguments.length == 1 &&
          generic_integer_type_argument?(type.arguments.first)
      end

      def str_builder_capacity(type)
        type.arguments.first.value
      end

      def text_buffer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1 &&
          generic_integer_type_argument?(type.arguments.first)
      end

      def cstr_list_buffer_type?(type)
        type.is_a?(Types::GenericInstance) && type.name == "cstr_list_buffer" && type.arguments.length == 2 &&
          type.arguments.all? { |argument| generic_integer_type_argument?(argument) }
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

      def contains_ref_type?(type)
        case type
        when Types::Nullable
          contains_ref_type?(type.base)
        when Types::GenericInstance
          return true if ref_type?(type)

          type.arguments.any? { |argument| !argument.is_a?(Types::LiteralTypeArg) && contains_ref_type?(argument) }
        when Types::Span
          contains_ref_type?(type.element_type)
        when Types::Result
          contains_ref_type?(type.ok_type) || contains_ref_type?(type.error_type)
        when Types::StructInstance
          type.arguments.any? { |argument| contains_ref_type?(argument) }
        when Types::Function
          type.params.any? { |param| contains_ref_type?(param.type) } ||
            contains_ref_type?(type.return_type) ||
            (type.receiver_type && contains_ref_type?(type.receiver_type))
        else
          false
        end
      end

      def resolve_named_generic_type(parts)
        if parts.length == 1
          type = @types[parts.first]
          return type if type.is_a?(Types::GenericStructDefinition)
        elsif parts.length == 2 && @imports.key?(parts.first)
          type = @imports.fetch(parts.first).types[parts.last]
          return type if type.is_a?(Types::GenericStructDefinition)
        end

        nil
      end

      def type_ref_from_specialization(expression)
        case expression.callee
        when AST::Identifier
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
          raise SemaError, "ptr requires exactly one type argument" unless arguments.length == 1
          raise SemaError, "ptr type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "ref"
          raise SemaError, "ref requires exactly one type argument" unless arguments.length == 1
          raise SemaError, "ref type argument must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise SemaError, "ref cannot target void" if arguments.first.is_a?(Types::Primitive) && arguments.first.void?
          raise SemaError, "ref cannot target another ref type" if contains_ref_type?(arguments.first)
        when "span"
          raise SemaError, "span requires exactly one type argument" unless arguments.length == 1
          raise SemaError, "span element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
        when "array"
          raise SemaError, "array requires exactly two type arguments" unless arguments.length == 2
          raise SemaError, "array element type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise SemaError, "array length must be an integer literal" unless generic_integer_type_argument?(arguments[1])
          raise SemaError, "array length must be positive" if integer_type_argument?(arguments[1]) && !arguments[1].value.positive?
        when "str_buffer"
          raise SemaError, "str_buffer requires exactly one type argument" unless arguments.length == 1
          raise SemaError, "str_buffer capacity must be an integer literal" unless generic_integer_type_argument?(arguments.first)
          raise SemaError, "str_buffer capacity must be positive" if integer_type_argument?(arguments.first) && !arguments.first.value.positive?
        when "str_builder"
          raise SemaError, "str_builder requires exactly one type argument" unless arguments.length == 1
          raise SemaError, "str_builder capacity must be an integer literal" unless generic_integer_type_argument?(arguments.first)
          raise SemaError, "str_builder capacity must be positive" if integer_type_argument?(arguments.first) && !arguments.first.value.positive?
        when "cstr_list_buffer"
          raise SemaError, "cstr_list_buffer requires exactly two type arguments" unless arguments.length == 2
          raise SemaError, "cstr_list_buffer item capacity must be an integer literal" unless generic_integer_type_argument?(arguments[0])
          raise SemaError, "cstr_list_buffer byte capacity must be an integer literal" unless generic_integer_type_argument?(arguments[1])
          raise SemaError, "cstr_list_buffer item capacity must be positive" if integer_type_argument?(arguments[0]) && !arguments[0].value.positive?
          raise SemaError, "cstr_list_buffer byte capacity must be positive" if integer_type_argument?(arguments[1]) && !arguments[1].value.positive?
        when "Result"
          raise SemaError, "Result requires exactly two type arguments" unless arguments.length == 2
          raise SemaError, "Result ok type must be a type" if arguments.first.is_a?(Types::LiteralTypeArg)
          raise SemaError, "Result error type must be a type" if arguments[1].is_a?(Types::LiteralTypeArg)
        else
          raise SemaError, "unknown generic type #{name}"
        end
      end

      def integer_type?(type)
        type.is_a?(Types::Primitive) && type.integer?
      end

      def range_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "range"
      end

      def collection_loop_type(type)
        return array_element_type(type) if array_type?(type)
        return type.element_type if span_type?(type)

        nil
      end

      def string_like_type?(type)
        type == @types.fetch("str") || type == @types.fetch("cstr")
      end

      def infer_index_result_type(receiver_type, index_type)
        raise SemaError, "index must be an integer type, got #{index_type}" unless integer_type?(index_type)

        if array_type?(receiver_type)
          return array_element_type(receiver_type)
        end

        if span_type?(receiver_type)
          return receiver_type.element_type
        end

        if pointer_type?(receiver_type)
          raise SemaError, "pointer indexing requires unsafe" unless unsafe_context?

          return pointee_type(receiver_type)
        end

        raise SemaError, "cannot index #{receiver_type}"
      end

      def addressable_storage_expression?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          addressable_storage_expression?(expression.receiver)
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
          @types[expression.name]
        when AST::MemberAccess
          return nil unless expression.receiver.is_a?(AST::Identifier)
          return nil unless @imports.key?(expression.receiver.name)

          imported_module = @imports.fetch(expression.receiver.name)
          if imported_module.private_type?(expression.member)
            raise SemaError, "#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}"
          end

          imported_module.types[expression.member]
        end
      end

      def imported_module_with_private_method(receiver_type, method_name)
        @imports.each_value do |module_binding|
          return module_binding if module_binding.private_method?(receiver_type, method_name)
        end

        nil
      end

      def resolve_type_member(type, name)
        case type
        when Types::Enum, Types::Flags
          type.member(name)
        end
      end

      def function_type_for_name(name)
        @top_level_functions.fetch(name).type
      end

      def resolve_specialized_function_binding(expression)
        binding = case expression.callee
                  when AST::Identifier
                    @top_level_functions[expression.callee.name]
                  when AST::MemberAccess
                    if expression.callee.receiver.is_a?(AST::Identifier) && @imports.key?(expression.callee.receiver.name)
                      @imports.fetch(expression.callee.receiver.name).functions[expression.callee.member]
                    end
                  end
        return nil unless binding

        type_arguments = resolve_specialization_type_arguments(expression)
        instantiate_function_binding(binding, type_arguments)
      end

      def resolve_specialization_type_arguments(expression)
        expression.arguments.map do |argument|
          case argument.value
          when AST::TypeRef
            resolve_type_ref(argument.value)
          when AST::IntegerLiteral, AST::FloatLiteral
            Types::LiteralTypeArg.new(argument.value.value)
          else
            raise SemaError, "callable specialization arguments must be types or literal type arguments"
          end
        end
      end

      def specialize_function_binding(binding, arguments, scopes:)
        return binding if binding.type_params.empty?

        type_arguments = infer_function_type_arguments(binding, arguments, scopes:)
        instantiate_function_binding(binding, type_arguments)
      end

      def instantiate_function_binding(binding, type_arguments)
        if binding.type_params.empty?
          raise SemaError, "function #{binding.name} is not generic and cannot be specialized"
        end

        unless binding.type_params.length == type_arguments.length
          raise SemaError, "function #{binding.name} expects #{binding.type_params.length} type arguments, got #{type_arguments.length}"
        end

        if type_arguments.any? { |type_argument| contains_ref_type?(type_argument) }
          raise SemaError, "generic function #{binding.name} cannot be instantiated with ref types"
        end

        key = type_arguments.freeze
        return binding.instances.fetch(key) if binding.instances.key?(key)

        substitutions = binding.type_params.zip(type_arguments).to_h
        type = substitute_type(binding.type, substitutions)
        body_params = binding.body_params.map { |param| substitute_value_binding(param, substitutions) }
        validate_specialized_function_binding!(binding.name, type, body_params)

        instance = FunctionBinding.new(
          name: binding.name,
          type:,
          body_params:,
          ast: binding.ast,
          external: binding.external,
          type_params: [].freeze,
          instances: {},
          type_arguments: key,
          owner: binding.owner,
          type_substitutions: substitutions.freeze,
        )
        binding.instances[key] = instance
      end

      def infer_function_type_arguments(binding, arguments, scopes:)
        expected_params = binding.type.params
        unless call_arity_matches?(binding.type, arguments.length)
          raise SemaError, arity_error_message(binding.type, binding.name, arguments.length)
        end

        substitutions = {}
        expected_params.each_with_index do |parameter, index|
          argument = arguments.fetch(index)
          actual_type = foreign_argument_actual_type(parameter, argument, scopes:, function_name: binding.name, expected_type: nil)
          collect_type_substitutions(parameter.type, actual_type, substitutions, binding.name)
        end

        binding.type_params.map do |name|
          inferred = substitutions[name]
          raise SemaError, "cannot infer type argument #{name} for function #{binding.name}" unless inferred

          raise SemaError, "generic function #{binding.name} cannot be instantiated with ref types" if contains_ref_type?(inferred)

          inferred
        end
      end

      def collect_type_substitutions(pattern_type, actual_type, substitutions, function_name)
        case pattern_type
        when Types::TypeVar
          existing = substitutions[pattern_type.name]
          if existing && existing != actual_type
            raise SemaError, "conflicting type argument #{pattern_type.name} for function #{function_name}: got #{existing} and #{actual_type}"
          end

          substitutions[pattern_type.name] ||= actual_type
        when Types::Nullable
          candidate = actual_type.is_a?(Types::Nullable) ? actual_type.base : actual_type
          collect_type_substitutions(pattern_type.base, candidate, substitutions, function_name)
        when Types::GenericInstance
          return unless actual_type.is_a?(Types::GenericInstance)
          return unless actual_type.name == pattern_type.name && actual_type.arguments.length == pattern_type.arguments.length

          pattern_type.arguments.zip(actual_type.arguments).each do |expected_argument, actual_argument|
            next if expected_argument.is_a?(Types::LiteralTypeArg)

            collect_type_substitutions(expected_argument, actual_argument, substitutions, function_name)
          end
        when Types::Span
          return unless actual_type.is_a?(Types::Span)

          collect_type_substitutions(pattern_type.element_type, actual_type.element_type, substitutions, function_name)
        when Types::Result
          return unless actual_type.is_a?(Types::Result)

          collect_type_substitutions(pattern_type.ok_type, actual_type.ok_type, substitutions, function_name)
          collect_type_substitutions(pattern_type.error_type, actual_type.error_type, substitutions, function_name)
        when Types::StructInstance
          return unless actual_type.is_a?(Types::StructInstance)
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
          name: binding.name,
          storage_type: substitute_type(binding.storage_type, substitutions),
          flow_type: binding.flow_type ? substitute_type(binding.flow_type, substitutions) : nil,
          mutable: binding.mutable,
          kind: binding.kind,
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
          raise SemaError, "#{context} of function #{function_name} must be a type, got #{type}"
        when Types::TypeVar
          raise SemaError, "cannot infer type argument #{type.name} for function #{function_name}"
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
        when Types::Result
          validate_specialized_function_type!(type.ok_type, function_name:, context:)
          validate_specialized_function_type!(type.error_type, function_name:, context:)
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
        when Types::Result
          Types::Result.new(substitute_type(type.ok_type, substitutions), substitute_type(type.error_type, substitutions))
        when Types::StructInstance
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

      def validate_stored_ref_type!(type, context)
        raise SemaError, "#{context} cannot store ref types" if contains_ref_type?(type)
      end

      def validate_parameter_ref_type!(type, function_name:, parameter_name:, external:)
        if ref_type?(type)
          raise SemaError, "extern function #{function_name} cannot take ref parameters" if external

          return
        end

        raise SemaError, "parameter #{parameter_name} of #{function_name} cannot nest ref types" if contains_ref_type?(type)
      end

      def validate_return_ref_type!(type, function_name:)
        raise SemaError, "function #{function_name} cannot return ref types" if contains_ref_type?(type)
      end

      def validate_local_ref_type!(type, local_name)
        return if ref_type?(type)

        raise SemaError, "local #{local_name} cannot store nested ref types" if contains_ref_type?(type)
      end

      def validate_owned_foreign_parameter!(type, function_name:, parameter_name:)
        if type.is_a?(Types::Nullable) || !(opaque_type?(type) || pointer_type?(type))
          raise SemaError, "owned parameter #{parameter_name} of #{function_name} must use a non-null opaque or ptr[...] type"
        end
      end

      def foreign_cstr_boundary_parameter?(parameter)
        parameter.boundary_type == @types.fetch("cstr") && parameter.type == @types.fetch("str")
      end

      def foreign_char_pointer_buffer_boundary_compatible?(public_type, boundary_type)
        return false unless char_pointer_type?(boundary_type)

        return true if public_type.is_a?(Types::Span) && public_type.element_type == @types.fetch("char")
        return true if str_builder_type?(public_type)

        text_buffer_type?(public_type)
      end

      def foreign_cstr_argument_compatible?(actual_type, parameter, expression:)
        types_compatible?(actual_type, parameter.type, expression:) || actual_type == @types.fetch("cstr")
      end

      def foreign_argument_requires_scratch?(parameter, argument, actual_type)
        if foreign_cstr_boundary_parameter?(parameter)
          return false if actual_type == @types.fetch("cstr")
          return false if argument.value.is_a?(AST::StringLiteral) && !argument.value.cstring

          return true
        end

        false
      end

      def array_to_span_call_argument_compatible?(actual_type, expected_type, expression:, scopes:)
        return false unless expected_type.is_a?(Types::Span)

        if array_type?(actual_type)
          return false unless array_element_type(actual_type) == expected_type.element_type

          infer_addr_source_type(expression, scopes:)
          return true
        end

        if str_builder_type?(actual_type)
          return false unless expected_type.element_type == @types.fetch("char")

          infer_addr_source_type(expression, scopes:)
          return true
        end

        false
      rescue SemaError
        false
      end

      def foreign_parameter_boundary_type(param, public_type, type_params:)
        return resolve_type_ref(param.boundary_type, type_params:) if param.boundary_type
        return pointer_to(public_type) if [:out, :inout].include?(param.mode)

        nil
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

        raise SemaError, "foreign parameter #{parameter_name} of #{function_name} cannot map #{public_type} as #{boundary_type}"
      end

      def foreign_span_boundary_compatible?(public_type, boundary_type)
        return false unless public_type.is_a?(Types::Span) && boundary_type.is_a?(Types::Span)

        foreign_boundary_element_compatible?(public_type.element_type, boundary_type.element_type)
      end

      def foreign_boundary_element_compatible?(public_type, boundary_type)
        return true if public_type == boundary_type

        foreign_identity_projection_compatible?(public_type, boundary_type)
      end

      def foreign_function_binding?(binding)
        binding.ast.is_a?(AST::ForeignFunctionDecl)
      end

      def foreign_mapping_expression(decl)
        return decl.mapping if decl.mapping.is_a?(AST::Call)

        AST::Call.new(
          callee: decl.mapping,
          arguments: decl.params.map { |param| AST::Argument.new(name: nil, value: AST::Identifier.new(name: param.name)) },
        )
      end

      def foreign_argument_expression(argument)
        if argument.value.is_a?(AST::UnaryOp) && ["out", "inout"].include?(argument.value.operator)
          argument.value.operand
        else
          argument.value
        end
      end

      def foreign_argument_actual_type(parameter, argument, scopes:, function_name:, expected_type: parameter.type)
        case parameter.passing_mode
        when :plain
          infer_expression(argument.value, scopes:, expected_type:)
        when :owned
          foreign_owned_argument_binding(parameter, argument, scopes:, function_name:).type
        when :out, :inout
          unless argument.value.is_a?(AST::UnaryOp) && argument.value.operator == parameter.passing_mode.to_s
            raise SemaError, "argument #{parameter.name} to #{function_name} must use #{parameter.passing_mode}"
          end

          infer_lvalue(argument.value.operand, scopes:)
        else
          raise SemaError, "unsupported foreign passing mode #{parameter.passing_mode}"
        end
      end

      def foreign_owned_argument_binding(parameter, argument, scopes:, function_name:)
        unless argument.value.is_a?(AST::Identifier)
          raise SemaError, "owned argument #{parameter.name} to #{function_name} must be a bare nullable local or parameter binding"
        end

        binding = lookup_value(argument.value.name, scopes)
        unless binding && %i[let var param].include?(binding.kind) && binding.storage_type.is_a?(Types::Nullable) && binding.storage_type.base == parameter.type
          raise SemaError, "owned argument #{parameter.name} to #{function_name} must be a bare nullable local or parameter binding"
        end

        binding
      end

      def validate_foreign_scratch!(binding, scratch, scopes:, requires_scratch:)
        raise SemaError, "using scratch is only allowed for foreign calls" unless foreign_function_binding?(binding)

        scratch_type = infer_expression(scratch, scopes:)
        raise SemaError, "using scratch expects ref[...] arena storage" unless ref_type?(scratch_type)

        receiver_type = referenced_type(scratch_type)
        mark_method = lookup_method(receiver_type, "mark")
        reset_method = lookup_method(receiver_type, "reset")
        to_cstr_method = lookup_method(receiver_type, "to_cstr")
        needs_to_cstr = binding.type.params.any? { |parameter| foreign_cstr_boundary_parameter?(parameter) }
        unless mark_method && reset_method && (!needs_to_cstr || to_cstr_method)
          raise SemaError, "using scratch expects ref[...] arena storage"
        end
      end

      def safe_reference_source_expression?(expression, scopes:)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess, AST::IndexAccess
          safe_reference_source_expression?(expression.receiver, scopes:)
        when AST::Call
          return false unless value_call?(expression)
          return false unless expression.arguments.length == 1 && expression.arguments.first.name.nil?

          ref_type?(infer_expression(expression.arguments.first.value, scopes:))
        else
          false
        end
      end

      def infer_addr_source_type(expression, scopes:)
        raise SemaError, "addr requires a mutable safe lvalue source" unless safe_reference_source_expression?(expression, scopes:)

        source_type = infer_lvalue(expression, scopes:)
        raise SemaError, "addr cannot target ref values" if contains_ref_type?(source_type)

        source_type
      end

      def validate_value_call_arguments!(arguments)
        raise SemaError, "value does not support named arguments" if arguments.any?(&:name)
        raise SemaError, "value expects 1 argument, got #{arguments.length}" unless arguments.length == 1
      end

      def infer_value_target_type(handle_expression, scopes:)
        handle_type = infer_expression(handle_expression, scopes:)
        return referenced_type(handle_type) if ref_type?(handle_type)

        pointee = pointee_type(handle_type)
        raise SemaError, "value expects ref[...] or ptr[...], got #{handle_type}" unless pointee
        raise SemaError, "raw pointer dereference requires unsafe" unless unsafe_context?

        pointee
      end

      def value_call?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "value"
      end

      def external_module?
        @module_kind == :extern_module
      end

      def assignable_receiver?(receiver_expression, scopes)
        infer_lvalue(receiver_expression, scopes:)
        true
      rescue SemaError
        false
      end

      def with_scope(bindings)
        scope = {}
        bindings.each do |binding|
          raise SemaError, "duplicate local #{binding.name}" if scope.key?(binding.name)

          scope[binding.name] = binding
        end

        yield([scope])
      end

      def with_nested_scope(scopes)
        nested_scopes = scopes + [{}]
        yield(nested_scopes)
      end

      def value_binding(name:, type:, mutable:, kind:, flow_type: nil)
        ValueBinding.new(name:, storage_type: type, flow_type: flow_type == type ? nil : flow_type, mutable:, kind:)
      end

      def current_actual_scope(scopes)
        scopes.reverse_each do |scope|
          return scope unless scope.is_a?(FlowScope)
        end

        raise SemaError, "missing lexical scope"
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

      def block_always_terminates?(statements)
        statements.any? { |statement| statement_always_terminates?(statement) }
      end

      def statement_always_terminates?(statement)
        case statement
        when AST::ReturnStmt, AST::BreakStmt, AST::ContinueStmt
          true
        when AST::IfStmt
          statement.else_body && statement.branches.all? { |branch| block_always_terminates?(branch.body) } && block_always_terminates?(statement.else_body)
        when AST::MatchStmt
          statement.arms.all? { |arm| block_always_terminates?(arm.body) }
        when AST::UnsafeStmt
          block_always_terminates?(statement.body)
        else
          false
        end
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
        else
          expression.class.name.split("::").last
        end
      end

    end
  end
end
