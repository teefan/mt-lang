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
    Analysis = Data.define(:ast, :module_name, :module_kind, :directives, :imports, :types, :interfaces, :attributes, :attribute_applications, :values, :functions, :methods, :implemented_interfaces, :local_completion_frames, :binding_resolution, :callable_value_identifier_sites, :callable_value_member_access_sites, :required_unsafe_lines)
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
    BindingResolution = Data.define(
      :identifier_binding_ids,
      :declaration_binding_ids,
      :mutating_argument_identifier_ids,
      :editable_receiver_expression_ids,
      :mutable_lvalue_argument_identifier_ids,
      :binding_types,
    )
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
    AttributeBinding = Data.define(:name, :targets, :params, :module_name, :builtin, :ast)
    ResolvedAttributeApplication = Data.define(:binding, :argument_values)
    AttributePresenceKey = Data.define(:target, :attribute_module_name, :attribute_name)
    FunctionBinding = Data.define(:name, :type, :body_params, :body_return_type, :ast, :external, :async, :type_params, :type_param_constraints, :instances, :type_arguments, :owner, :specialization_owner, :type_substitutions, :declared_receiver_type)
    TypeParamConstraintBinding = Data.define(:interfaces) do
      def initialize(interfaces: []) = super
    end
    DefaultResolution = Data.define(:target_type, :binding)
    HashResolution = Data.define(:target_type, :binding)
    EqualResolution = Data.define(:target_type, :binding)
    OrderResolution = Data.define(:target_type, :binding)
    ModuleBinding = Data.define(:name, :types, :type_declarations, :interfaces, :attributes, :attribute_applications, :values, :functions, :methods, :implemented_interfaces, :imports, :private_types, :private_interfaces, :private_attributes, :private_values, :private_functions, :private_methods, :private_implemented_interfaces) do
      def private_type?(name)
        private_types.key?(name)
      end

      def private_interface?(name)
        private_interfaces.key?(name)
      end

      def private_attribute?(name)
        private_attributes.key?(name)
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

    BUILTIN_ATTRIBUTE_NAMES = %w[packed align].freeze

    def self.builtin_attribute_binding(name, types)
      case name
      when "packed"
        AttributeBinding.new(
          name: "packed",
          targets: [:struct].freeze,
          params: [].freeze,
          module_name: nil,
          builtin: true,
          ast: nil,
        )
      when "align"
        AttributeBinding.new(
          name: "align",
          targets: [:struct].freeze,
          params: [Types::Parameter.new("bytes", types.fetch("ptr_uint"))].freeze,
          module_name: nil,
          builtin: true,
          ast: nil,
        )
      end
    end

    INSTALLABLE_BUILTIN_TYPE_NAMES = (Types::BUILTIN_PRIMITIVE_NAMES + %w[
      Option Result Subscription EventError
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
      include TypeCompatibilityPredicates

      attr_reader :module_name

      def initialize(ast, imported_modules: {}, allow_missing_imports: false, path: nil, global_import_index: {})
        @ast = ast
        @path = path
        @imported_modules = imported_modules
        @allow_missing_imports = allow_missing_imports
        @global_import_index = global_import_index
        @module_name = ast.module_name&.to_s
        @module_kind = ast.module_kind
        @const_declarations = ast.declarations.grep(AST::ConstDecl).each_with_object({}) { |decl, result| result[decl.name] = decl }
        @types = {}
        @interfaces = {}
        @attributes = {}
        @top_level_values = {}
        @top_level_functions = {}
        @imports = {}
        @methods = Hash.new { |hash, key| hash[key] = {} }
        @implemented_interfaces = Hash.new { |hash, key| hash[key] = [] }
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
        @current_specialization_owner = nil
        @return_context_stack = []
        @resolved_attribute_applications = {}
        @validated_attribute_arguments = {}
        @attribute_application_bindings = {}
      end

      def check
        install_builtin_types
        install_builtin_attributes
        install_imports
        declare_named_types
        resolve_generic_type_param_constraints
        resolve_type_aliases
        declare_attributes
        resolve_aggregate_fields
        resolve_enum_members
        resolve_variant_arms
        declare_top_level_values
        validate_attribute_applications
        collect_emit_declarations
        declare_functions
        check_interface_conformances
        check_top_level_values
        finalize_top_level_const_values
        check_top_level_static_asserts
        check_functions

        build_analysis
      end

      def collect_emit_declarations
        collect_emit_from_declarations(@ast.declarations)
      end

      def collect_emit_from_declarations(declarations)
        declarations.each do |decl|
          case decl
          when AST::FunctionDef
            next unless decl.const && decl.body

            decl.body.each do |stmt|
              next unless stmt.is_a?(AST::EmitStmt)

              emit_decl = stmt.declaration
              next if emit_decl.is_a?(AST::ErrorExpr)

              @ast.declarations << emit_decl
              collect_emit_from_node(emit_decl)
            end
          when AST::StructDecl, AST::ExtendingBlock
            # no emit in structs/extending blocks (body is fields/methods, not statements)
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

              @ast.declarations << nested
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

        return { analysis: nil, errors: errors.uniq { |e| [e.message, e.line, e.column, e.length] } } unless errors.empty?

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
