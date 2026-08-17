# frozen_string_literal: true

require_relative "semantic_analyzer/type_declaration"
require_relative "semantic_analyzer/attributes"
require_relative "semantic_analyzer/function_binding"
require_relative "semantic_analyzer/top_level"
require_relative "semantic_analyzer/interface_conformance"
require_relative "semantic_analyzer/nullability"
require_relative "semantic_analyzer/statements"
require_relative "semantic_analyzer/expressions"
require_relative "semantic_analyzer/calls"
require_relative "semantic_analyzer/analysis_context"
require_relative "semantic_analyzer/type_compatibility"
require_relative "semantic_analyzer/flow_refinement"
require_relative "semantic_analyzer/name_resolution"
require_relative "semantic_analyzer/generics"
require_relative "semantic_analyzer/foreign_functions"
require_relative "semantic_analyzer/module_context"

module MilkTea
  class SemanticError < StandardError
    attr_reader :line, :column, :length, :path, :suggestion

    def initialize(msg = nil, line: nil, column: nil, length: nil, path: nil, suggestion: nil)
      super(msg)
      @line = line
      @column = column
      @length = length
      @path = path
      @suggestion = suggestion
    end

    def code
      "sema/error"
    end

    def to_diagnostic(path: nil)
      Diagnostic.new(
        path: @path || path,
        line: @line,
        column: @column,
        length: @length,
        code: "sema/error",
        message: message,
        severity: :error,
      )
    end
  end

  class SemanticAnalyzer
    Analysis = Data.define(:ast, :module_name, :module_kind, :directives, :imports, :types, :interfaces, :attributes, :attribute_applications, :values, :functions, :methods, :implemented_interfaces, :local_completion_frames, :binding_resolution, :callable_value_identifier_sites, :callable_value_member_access_sites, :required_unsafe_lines, :uses_parallel_for, :resolved_expr_types, :resolved_call_kinds, :const_values) do
      def initialize(ast:, module_name:, module_kind:, directives:, imports:, types:, interfaces:, attributes:, attribute_applications:, values:, functions:, methods:, implemented_interfaces:, local_completion_frames:, binding_resolution:, callable_value_identifier_sites:, callable_value_member_access_sites:, required_unsafe_lines:, uses_parallel_for:, resolved_expr_types: {}, resolved_call_kinds: {}, const_values: {}) = super
    end
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
    CallableResolution = Data.define(:kind, :value, :receiver)
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
    # Returns { analysis: Analysis|nil, errors: [SemanticError] }.
    def self.check_collecting_errors(ast, imported_modules: {}, allow_missing_imports: false, path: nil)
      Checker.new(ast, imported_modules:, allow_missing_imports:, path:).check_collecting_errors
    rescue SemanticError => e
      { analysis: nil, errors: [e] }
    end

    def self.tooling_snapshot(ast, imported_modules: {}, allow_missing_imports: false, path: nil)
      result = check_collecting_errors(ast, imported_modules:, allow_missing_imports:, path:)
      diagnostics = Array(result[:errors]).map { |error| error.to_diagnostic(path:) }.freeze

      ToolingSnapshot.new(facts: result[:analysis], diagnostics:)
    end

    class Checker
      include Intrinsics

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
        @predeclared_const_names = Set.new
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
        result = check_collecting_errors
        raise result[:errors].first unless result[:errors].empty?
        result[:analysis]
      end

      def run_phase(name, requires: [])
        requires.each do |required|
          unless @completed_phases&.include?(required)
            raise "BUG: phase #{required} must run before #{name} — check phase ordering"
          end
        end
        send(name)
      ensure
        @completed_phases << name if @completed_phases
      end

      def run_collecting_phase(name, requires: [])
        catch_structural { run_phase(name, requires:) }
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
          when AST::StructDecl
            # no emit in structs
          when AST::ExtendingBlock
            decl.methods.each do |method|
              next unless method.respond_to?(:const) && method.const && method.body

              collect_emit_from_statements(method.body)
            end
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
          when AST::ForStmt, AST::WhileStmt
            next unless stmt.inline
            stmt.body&.each { |s| collect_emit_from_statements([s]) }
          when AST::IfStmt
            next unless stmt.inline
            stmt.branches.each { |branch| collect_emit_from_statements(branch.body) }
            stmt.else_body&.each { |s| collect_emit_from_statements([s]) }
          when AST::MatchStmt
            next unless stmt.inline
            stmt.arms.each { |arm| collect_emit_from_statements(arm.body) }
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

      # Runs all sema phases and collects every error instead of stopping at
      # the first one.  Structural phases collect per-declaration, and
      # function-body phases collect per function/method.
      # Returns { analysis: Analysis, errors: [SemanticError] }.
      def check_collecting_errors
        @structural_errors = []
        @completed_phases = Set.new

        run_collecting_phase(:install_builtin_types)
        run_collecting_phase(:install_builtin_attributes)
        run_collecting_phase(:install_imports)
        run_collecting_phase(:install_prelude_types, requires: [:install_imports])
        run_collecting_phase(:declare_named_types, requires: [:install_builtin_types, :install_imports, :install_prelude_types])
        run_collecting_phase(:resolve_generic_type_param_constraints, requires: [:declare_named_types])
        run_collecting_phase(:resolve_type_aliases, requires: [:declare_named_types])
        run_collecting_phase(:declare_attributes)
        run_collecting_phase(:predeclare_top_level_consts)
        run_collecting_phase(:resolve_aggregate_fields, requires: [:resolve_type_aliases, :declare_named_types])
        run_collecting_phase(:resolve_enum_members, requires: [:declare_named_types])
        run_collecting_phase(:resolve_variant_arms, requires: [:declare_named_types])
        run_collecting_phase(:collect_emit_declarations)
        run_collecting_phase(:declare_top_level_values, requires: [:resolve_aggregate_fields, :resolve_type_aliases])
        run_collecting_phase(:check_attribute_applications, requires: [:declare_attributes])
        run_collecting_phase(:declare_functions, requires: [:resolve_aggregate_fields, :resolve_enum_members, :resolve_variant_arms])
        run_collecting_phase(:check_interface_conformances, requires: [:declare_functions, :resolve_aggregate_fields])

        errors = @structural_errors.dup

        begin
          check_top_level_values
        rescue SemanticError => e
          errors << e
        end
        errors.concat(@structural_errors.drop(errors.length))

        begin
          finalize_top_level_const_values
        rescue SemanticError => e
          errors << e
        end

        begin
          check_top_level_static_asserts
        rescue SemanticError => e
          errors << e
        end

        check_functions_collecting(errors)

        analysis = build_analysis

        { analysis: analysis, errors: errors.uniq { |e| [e.message, e.line, e.column, e.length] } }
      end

      def catch_structural
        yield
      rescue SemanticError => e
        @structural_errors << e
      end

      def collect_structural_error(error)
        @structural_errors << error
      end
    end
  end
end
