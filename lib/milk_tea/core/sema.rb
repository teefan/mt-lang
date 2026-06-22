# frozen_string_literal: true

require_relative "sema/type_declaration"
require_relative "sema/function_binding"
require_relative "sema/top_level"
require_relative "sema/interface_conformance"
require_relative "sema/nullability"
require_relative "sema/statement_checker"
require_relative "sema/expression_checker"
require_relative "sema/call_checker"
require_relative "sema/context_manager"
require_relative "sema/type_compatibility"
require_relative "sema/flow_refinement"
require_relative "sema/resolve"
require_relative "sema/module_context"

module MilkTea
  class SemaError < StandardError
    attr_reader :line, :column, :length, :path, :suggestion

    def initialize(msg = nil, line: nil, column: nil, length: nil, path: nil, suggestion: nil)
      super(msg)
      @line = line
      @column = column
      @length = length
      @path = path
      @suggestion = suggestion
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
    Analysis = Data.define(:ast, :module_name, :module_kind, :directives, :imports, :types, :interfaces, :attributes, :attribute_applications, :values, :functions, :methods, :implemented_interfaces, :local_completion_frames, :binding_resolution, :callable_value_identifier_sites, :callable_value_member_access_sites, :required_unsafe_lines, :uses_parallel_for, :resolved_expr_types, :resolved_call_kinds, :const_values) do
      def initialize(ast:, module_name:, module_kind:, directives:, imports:, types:, interfaces:, attributes:, attribute_applications:, values:, functions:, methods:, implemented_interfaces:, local_completion_frames:, binding_resolution:, callable_value_identifier_sites:, callable_value_member_access_sites:, required_unsafe_lines:, uses_parallel_for:, resolved_expr_types: {}, resolved_call_kinds: {}, const_values: {}) = super
    end
    Facts = Analysis
    ToolingSnapshot = Data.define(:facts, :diagnostics)
    LocalCompletionFrame = Data.define(:start_line, :end_line, :function_name, :receiver_type, :snapshots)
    LocalCompletionSnapshot = Data.define(:line, :column, :bindings)
    BindingResolution = Data.define(
      :identifier_binding_ids,
      :declaration_binding_ids,
      :mutating_argument_identifier_ids,
      :editable_receiver_expression_ids,
      :mutable_lvalue_argument_identifier_ids,
      :binding_types,
    )
    InterfaceMethodBinding = Data.define(:name, :params, :return_type, :kind, :async, :ast)
    InterfaceBinding = Data.define(:name, :methods, :ast, :module_name, :type_arguments) do
      def initialize(name:, methods:, ast:, module_name:, type_arguments: nil) = super
    end

    GenericInterfaceBinding = Data.define(:name, :type_params, :type_param_constraints, :methods, :ast, :module_name) do
      def instantiate(arguments)
        raise ArgumentError, "#{name} expects #{type_params.length} type arguments, got #{arguments.length}" unless arguments.length == type_params.length

        substitutions = type_params.zip(arguments).to_h
        substituted_methods = methods.transform_values do |method|
          InterfaceMethodBinding.new(
            name: method.name,
            params: method.params.map { |p| Types::Registry.parameter(p.name, Types.substitute_type_variables(p.type, substitutions)) },
            return_type: Types.substitute_type_variables(method.return_type, substitutions),
            kind: method.kind,
            async: method.async,
            ast: method.ast,
          )
        end

        InterfaceBinding.new(
          name:,
          methods: substituted_methods.freeze,
          ast:,
          module_name:,
          type_arguments: arguments.freeze,
        )
      end
    end
    ResolvedAttributeApplication = Data.define(:binding, :argument_values)
    AttributePresenceKey = Data.define(:target, :attribute_module_name, :attribute_name)
    TypeParamConstraintBinding = Data.define(:interfaces) do
      def initialize(interfaces: []) = super
    end
    DefaultResolution = Data.define(:target_type, :binding)
    HashResolution = Data.define(:target_type, :binding)
    EqualResolution = Data.define(:target_type, :binding)
    OrderResolution = Data.define(:target_type, :binding)

    INSTALLABLE_BUILTIN_TYPE_NAMES = (MilkTea::BUILTIN_PRIMITIVE_NAMES + %w[
      Subscription EventError
      struct_handle field_handle callable_handle attribute_handle member_handle type
    ]).freeze

    def self.check(ast, imported_modules: {}, allow_missing_imports: false, path: nil, global_import_index: {})
      Checker.new(ast, imported_modules:, allow_missing_imports:, path:, global_import_index:).check
    end

    # LSP-oriented entry point: runs all sema phases and collects every error
    # instead of stopping at the first one.  Structural phases collect per-
    # declaration, and function-body phases collect per function/method.
    # Returns { analysis: Analysis|nil, errors: [SemaError] }.
    def self.check_collecting_errors(ast, imported_modules: {}, allow_missing_imports: false, path: nil)
      Checker.new(ast, imported_modules:, allow_missing_imports:, path:).check_collecting_errors
    rescue SemaError => e
      { analysis: nil, errors: [e] }
    end

    def self.tooling_snapshot(ast, imported_modules: {}, allow_missing_imports: false, path: nil)
      result = check_collecting_errors(ast, imported_modules:, allow_missing_imports:, path:)
      diagnostics = Array(result[:errors]).map { |error| error.to_diagnostic(path:) }.freeze

      ToolingSnapshot.new(facts: result[:analysis], diagnostics:)
    end

    class Checker
      include CompatibilityHelpers

      attr_reader :ctx

      def module_name
        @ctx.module_name
      end

      def initialize(ast, imported_modules: {}, allow_missing_imports: false, path: nil, global_import_index: {})
        @path = path
        @allow_missing_imports = allow_missing_imports
        @ctx = ModuleContext.new(
          ast:,
          module_name: ast.module_name&.to_s,
          module_kind: ast.module_kind,
          imported_modules:,
          global_import_index:,
          const_declarations: ast.declarations.grep(AST::ConstDecl).each_with_object({}) { |decl, result| result[decl.name] = decl },
        )
        @null_type = Types::Null.new
        @error_type = Types::Error.new
        @loop_depth = 0
        @unsafe_depth = 0
        @compile_time_depth = 0
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
        @resolved_expr_types = {}
        @resolved_call_kinds = {}
        @const_values = {}
        @next_binding_id = 1
        @binding_name_by_id = {}
        @binding_type_by_id = {}
        @identifier_binding_ids = {}
        @declaration_binding_ids = {}
        @mutating_argument_identifier_ids = {}
        @mutable_lvalue_argument_identifier_ids = {}
        @editable_receiver_expression_ids = {}
        @preassigned_local_binding_ids = {}
        @nullability_flow_result = nil
        @unsafe_statement_lines = []
        @callable_value_identifier_sites = {}
        @callable_value_member_access_sites = {}
        @required_unsafe_lines = []
        @uses_parallel_for = false
        @current_specialization_owner = nil
        @return_context_stack = []
      end

      def check
        install_builtin_types
        install_builtin_attributes
        install_imports
        install_prelude_types
        declare_named_types
        resolve_generic_type_param_constraints
        resolve_type_aliases
        declare_attributes
        resolve_aggregate_fields
        resolve_enum_members
        resolve_variant_arms
        collect_emit_declarations
        declare_top_level_values
        validate_attribute_applications
        declare_functions
        check_interface_conformances
        check_top_level_values
        finalize_top_level_const_values
        check_top_level_static_asserts
        check_functions

        build_analysis
      end

      def collect_emit_declarations
        collect_emit_from_declarations(expanded_declarations)
        @ctx.ast.declarations.grep(AST::ConstDecl).each { |decl| @ctx.const_declarations[decl.name] ||= decl }
      end

      def collect_emit_from_declarations(declarations)
        declarations.each do |decl|
          case decl
          when AST::FunctionDef
            next unless decl.const && decl.body

            collect_emit_from_statements(decl.body)
          when AST::WhenStmt
            body = when_chosen_body(decl)
            collect_emit_from_declarations(body) if body
          when AST::StructDecl, AST::ExtendingBlock
            # no emit in structs/extending blocks
          end
        end
      end

      def collect_emit_from_statements(statements)
        statements.each do |stmt|
          case stmt
          when AST::EmitStmt
            emit_decl = stmt.declaration
            next if emit_decl.is_a?(AST::ErrorExpr)

            @ctx.ast.declarations << emit_decl
            collect_emit_from_node(emit_decl)
          when AST::WhenStmt
            body = when_chosen_body(stmt) || []
            body.each { |nested| collect_emit_from_statements([nested]) }
          when AST::ForStmt, AST::WhileStmt, AST::IfStmt, AST::MatchStmt
            next unless stmt.inline
            stmt.body&.each { |s| collect_emit_from_statements([s]) }
            if stmt.is_a?(AST::IfStmt)
              stmt.else_body&.each { |s| collect_emit_from_statements([s]) }
            end
          end
        end
      end

      def collect_emit_from_node(node)
        case node
        when AST::FunctionDef
          node.body&.each do |stmt|
            if stmt.is_a?(AST::EmitStmt)
              nested = stmt.declaration
              next if nested.is_a?(AST::ErrorExpr)

              @ctx.ast.declarations << nested
              collect_emit_from_node(nested)
            end
          end
        end
      end

      # Like check, but collects per-function errors instead of raising at first.
      # Structural phases (imports, type resolution, declaration) collect errors per
      # declaration so that the maximum number of diagnostics are surfaced.
      # Returns { analysis: Analysis, errors: [SemaError] }.
      def check_collecting_errors
        @collecting_errors = true
        @structural_errors = []

        catch_structural { install_builtin_types }
        catch_structural { install_builtin_attributes }
        catch_structural { install_imports }
        catch_structural { install_prelude_types }
        catch_structural { declare_named_types }
        catch_structural { resolve_generic_type_param_constraints }
        catch_structural { resolve_type_aliases }
        catch_structural { declare_attributes }
        catch_structural { resolve_aggregate_fields }
        catch_structural { resolve_enum_members }
        catch_structural { resolve_variant_arms }
        catch_structural { declare_top_level_values }
        catch_structural { validate_attribute_applications }
        catch_structural { collect_emit_declarations }
        catch_structural { declare_functions }
        catch_structural { check_interface_conformances }

        errors = @structural_errors.dup

        begin
          check_top_level_values
        rescue SemaError => e
          errors << e
        end
        errors.concat(@structural_errors.drop(errors.length))

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

        analysis = build_analysis

        { analysis: analysis, errors: errors.uniq { |e| [e.message, e.line, e.column, e.length] } }
      end

      def catch_structural
        yield
      rescue SemaError => e
        @structural_errors << e
      end

      def collect_structural_error(error)
        raise error unless @collecting_errors

        @structural_errors << error
      end


    end
  end
end
