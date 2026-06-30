# frozen_string_literal: true

# Lowering transforms the SemanticAnalyzer analysis into IR::Program.
#
# Contract with SemanticAnalyzer::Analysis — the Lowerer reads these fields:
#   .ast                    raw parsed AST
#   .module_name            module identifier string
#   .module_kind            :module or :raw_module
#   .directives             compiler/link/include directives
#   .imports                imported module bindings
#   .types                  Hash[name → Types::Base]
#   .interfaces             Hash[name → InterfaceBinding|GenericInterfaceBinding]
#   .attributes             Hash[name → AttributeBinding]
#   .attribute_applications Hash[...]
#   .values                 Hash[name → ValueBinding]
#   .functions              Hash[name → FunctionBinding]
#   .methods                Hash[type → Hash[name → FunctionBinding]]
#   .implemented_interfaces Hash[type → Set[InterfaceBinding]]
#   .resolved_expr_types   Hash[expression.object_id → Types::Base]
#   .uses_parallel_for      bool
#
# Cross-module access uses analysis_for_module(name) which returns
# another module's Analysis and its fields as listed above.
#
# The output is IR::Program, consumed by CBackend.

require_relative "lowering/collectors"
require_relative "lowering/declarations"
require_relative "lowering/events"
require_relative "lowering/functions"
require_relative "lowering/async/analysis"
require_relative "lowering/async/normalization"
require_relative "lowering/async/lowering"
require_relative "lowering/async"
require_relative "lowering/statement_blocks"
require_relative "lowering/proc"
require_relative "lowering/loops"
require_relative "lowering/expressions"
require_relative "lowering/calls"
require_relative "lowering/foreign_cstr"
require_relative "lowering/str_buffer"
require_relative "lowering/type_resolution"
require_relative "lowering/dyn"
require_relative "lowering/utils"
require_relative "lowering/artifacts"
require_relative "lowering/lowering_context"

module MilkTea
  class LoweringError < StandardError
    attr_reader :line, :column, :path

    def initialize(msg = nil, line: nil, column: nil, path: nil)
      super(msg)
      @line = line
      @column = column
      @path = path
    end
  end

  class Lowering
    def self.lower(program)
      lowerer = Lowerer.new(program)
      ir_program, _modules, _synths = lowerer.lower_and_assemble
      ir_program
    end

    def self.lower_from_analysis(analysis)
      lower_from_analyses(analysis, {})
    end

    def self.lower_from_analyses(root_analysis, imported_analyses)
      analyses = { root_analysis.module_name.to_s => root_analysis }
      imported_analyses.each { |k, v| analyses[k] = v }

      proxy_analyses = analyses.transform_values { |a| ImportAnalysisProxy.new(a, analyses) }
      proxy_analyses.each { |k, v| analyses[k] = v }

      resolved_imports = root_analysis.imports.transform_values do |import_binding|
        mod_name = import_binding.name.to_s
        proxy_analyses[mod_name] || import_binding
      end
      if root_analysis.respond_to?(:with)
        root_analysis = root_analysis.with(imports: resolved_imports)
        proxy_analyses[root_analysis.module_name.to_s] = root_analysis
      end

      program = ModuleProgramStub.new(root_analysis, proxy_analyses)
      lower(program)
    end

    ImportAnalysisProxy = Struct.new(:analysis, :all_analyses) do
      def name = analysis.module_name.to_s
      def types = analysis.types
      def functions = analysis.functions
      def values = analysis.values
      def methods = analysis.methods
      def interfaces = analysis.interfaces
      def attributes = analysis.attributes
      def attribute_applications = analysis.attribute_applications
      def implemented_interfaces = analysis.implemented_interfaces
      def imports
        analysis.imports.transform_values do |import_binding|
          mod_name = import_binding.name.to_s
          all_analyses[mod_name] ? ImportAnalysisProxy.new(all_analyses[mod_name], all_analyses) : import_binding
        end
      end
      def directives = analysis.directives
      def module_kind = analysis.module_kind
      def module_name = analysis.module_name
      def private_types = analysis.respond_to?(:private_types) ? analysis.private_types : {}
      def private_interfaces = analysis.respond_to?(:private_interfaces) ? analysis.private_interfaces : {}
      def private_attributes = analysis.respond_to?(:private_attributes) ? analysis.private_attributes : {}
      def private_values = analysis.respond_to?(:private_values) ? analysis.private_values : {}
      def private_functions = analysis.respond_to?(:private_functions) ? analysis.private_functions : {}
      def private_methods = analysis.respond_to?(:private_methods) ? analysis.private_methods : {}
      def private_implemented_interfaces = analysis.respond_to?(:private_implemented_interfaces) ? analysis.private_implemented_interfaces : {}
      def private_type?(n) = analysis.respond_to?(:private_type?) ? analysis.private_type?(n) : false
      def private_interface?(n) = analysis.respond_to?(:private_interface?) ? analysis.private_interface?(n) : false
      def private_value?(n) = analysis.respond_to?(:private_value?) ? analysis.private_value?(n) : false
      def private_function?(n) = analysis.respond_to?(:private_function?) ? analysis.private_function?(n) : false

      def method_missing(method, *args, &block)
        if analysis.respond_to?(method)
          analysis.public_send(method, *args, &block)
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        analysis.respond_to?(method) || super
      end
    end

    ModuleProgramStub = Struct.new(:root_analysis, :analyses_by_mod) do
      def initialize(root_analysis, analyses_by_mod = {})
        super(root_analysis, analyses_by_mod)
      end
      def module_name = root_analysis.module_name
      def module_kind = root_analysis.module_kind
      def directives = root_analysis.directives
      def imports
        root_analysis.imports.transform_values do |import_binding|
          mod_name = import_binding.name.to_s
          analyses_by_mod[mod_name] || import_binding
        end
      end
      def types = root_analysis.types
      def interfaces = root_analysis.interfaces
      def attributes = root_analysis.attributes
      def attribute_applications = root_analysis.attribute_applications
      def values = root_analysis.values
      def functions = root_analysis.functions
      def methods = root_analysis.methods
      def implemented_interfaces = root_analysis.implemented_interfaces
      def resolved_expr_types = root_analysis.resolved_expr_types
      def resolved_call_kinds = root_analysis.resolved_call_kinds
      def const_values = root_analysis.const_values
      def ast = root_analysis.ast
      def binding_resolution = root_analysis.binding_resolution
      def local_completion_frames = root_analysis.local_completion_frames
      def callable_value_identifier_sites = root_analysis.callable_value_identifier_sites
      def callable_value_member_access_sites = root_analysis.callable_value_member_access_sites
      def required_unsafe_lines = root_analysis.required_unsafe_lines
      def uses_parallel_for = root_analysis.uses_parallel_for
      def module_name_str = root_analysis.module_name.to_s
      def root_path = nil
      def analyses_by_module_name
        all = { root_analysis.module_name.to_s => root_analysis }
        analyses_by_mod.each { |k, v| all[k] = v }
        all
      end
      def analyses_by_path = analyses_by_module_name
    end

    def self.lower_incremental(program, cached: nil, cached_synthetics: nil)
      lowerer = Lowerer.new(program)
      lowerer.lower_and_assemble(cached:, cached_synthetics:)
    end
  end

  ExplicitDefaultBinding = Data.define(:binding, :callee_name)
  ExplicitHashBinding = Data.define(:binding, :callee_name)
  ExplicitEqualBinding = Data.define(:binding, :callee_name)
  ExplicitOrderBinding = Data.define(:binding, :callee_name)
  ExplicitFormatBinding = Data.define(:length_binding, :length_callee_name, :append_binding, :append_callee_name)
  DefaultResolution = Data.define(:target_type, :binding, :callee_name)
  HashResolution = Data.define(:target_type, :binding, :callee_name)
  EqualResolution = Data.define(:target_type, :binding, :callee_name)
  OrderResolution = Data.define(:target_type, :binding, :callee_name)

  class Lowerer
    include CompatibilityHelpers

    attr_accessor :bypass_sema_type_cache
    attr_reader :recorded_expr_types

    def initialize(program)
      @program = program
      @ctx = ModuleContext.new
      @artifacts = Artifacts.new
      @synthetic_proc_counter = 0
      @parallel_for_counter = 0
      @async_binding_counter = 0
      @method_definitions = build_method_definitions
      @bypass_sema_type_cache = false
    end

    def lower
      @recorded_expr_types = {} if @bypass_sema_type_cache
      ir_program, _modules, _synths = lower_and_assemble
      ir_program
    end

    def lower_and_assemble(cached: nil, cached_synthetics: nil)
      modules, per_module_synthetics = lower_modules(cached:, cached_synthetics:)
      [assemble_modules(modules), modules, per_module_synthetics]
    end

    def lower_modules(cached: nil, cached_synthetics: nil)
      if @program.root_analysis.module_kind == :raw_module
        raise LoweringError, "cannot emit C for external file #{@program.root_analysis.module_name}"
      end

      per_module_synthetics = {}
      per_module_funcs = Hash.new { |h, k| h[k] = [] }
      modules = {}

      cached_synthetics&.each do |_module_name, synths|
        @artifacts.synthetic_structs.concat(synths[:structs] || [])
        @artifacts.synthetic_enums.concat(synths[:enums] || [])
        @artifacts.synthetic_functions.concat(synths[:functions] || [])
        @artifacts.synthetic_constants.concat(synths[:constants] || [])
      end

      cached&.each do |module_name, cached_ir|
        modules[module_name] = cached_ir.with(functions: [])
        per_module_funcs[module_name] = cached_ir.functions.dup
        cached_ir.functions.each { |f| @artifacts.lowered_function_linkage_names[f.linkage_name] = true }
      end

      ordered_analysis_pairs.each do |path, analysis|
        next if analysis.module_kind == :raw_module
        next if modules.key?(analysis.module_name)

        prepare_analysis(analysis, source_path: path)
        collect_structs

        synth_before_s = @artifacts.synthetic_structs.length
        synth_before_e = @artifacts.synthetic_enums.length
        synth_before_f = @artifacts.synthetic_functions.length
        synth_before_c = @artifacts.synthetic_constants.length

        modules[analysis.module_name] = IR::Program.new(
          module_name: analysis.module_name,
          includes: [],
          constants: lower_constants.dup,
          globals: lower_globals.dup,
          opaques: lower_opaques.dup,
          structs: lower_structs.dup,
          unions: lower_unions.dup,
          enums: lower_enums.dup,
          variants: lower_variants.dup,
          static_asserts: lower_static_asserts.dup,
          functions: [],
          source_path: path,
        )
        per_module_funcs[analysis.module_name].concat(lower_functions)

        per_module_synthetics[analysis.module_name] = {
          structs: @artifacts.synthetic_structs[synth_before_s..] || [],
          enums: @artifacts.synthetic_enums[synth_before_e..] || [],
          functions: @artifacts.synthetic_functions[synth_before_f..] || [],
          constants: @artifacts.synthetic_constants[synth_before_c..] || [],
        }
      end

      pending = true
      while pending
        pending = false

        ordered_analysis_pairs.each do |path, analysis|
          next if analysis.module_kind == :raw_module

          prepare_analysis(analysis, source_path: path)
          ensure_events_for_analysis(analysis)

          synth_before_s = @artifacts.synthetic_structs.length
          synth_before_e = @artifacts.synthetic_enums.length
          synth_before_f = @artifacts.synthetic_functions.length
          synth_before_c = @artifacts.synthetic_constants.length

          newly_lowered = lower_functions
          next if newly_lowered.empty?

          per_module_funcs[analysis.module_name].concat(newly_lowered)

          delta = {
            structs: @artifacts.synthetic_structs[synth_before_s..] || [],
            enums: @artifacts.synthetic_enums[synth_before_e..] || [],
            functions: @artifacts.synthetic_functions[synth_before_f..] || [],
            constants: @artifacts.synthetic_constants[synth_before_c..] || [],
          }
          existing = per_module_synthetics[analysis.module_name]
          per_module_synthetics[analysis.module_name] = existing ? merge_synthetics(existing, delta) : delta

          pending = true
        end
      end

      modules.transform_values! do |fragment|
        fragment.with(functions: per_module_funcs[fragment.module_name])
      end

      [modules, per_module_synthetics]
    end

    def merge_synthetics(a, b)
      {
        structs: (a[:structs] || []) + (b[:structs] || []),
        enums: (a[:enums] || []) + (b[:enums] || []),
        functions: (a[:functions] || []) + (b[:functions] || []),
        constants: (a[:constants] || []) + (b[:constants] || []),
      }
    end

    def ensure_events_for_analysis(analysis)
      analysis.ast.declarations.grep(AST::EventDecl).each do |decl|
        event_type = analysis.values.fetch(decl.name).type
        ensure_event_runtime(event_type)
      end
    end

    def assemble_modules(modules)
      if @program.root_analysis.module_kind == :raw_module
        raise LoweringError, "cannot emit C for external file #{@program.root_analysis.module_name}"
      end

      regenerate_cross_module_synthetics

      includes = collect_includes

      ordered = ordered_module_fragments(modules)
      all_constants = ordered.flat_map(&:constants)
      all_constants.concat(@artifacts.synthetic_constants)
      all_globals = ordered.flat_map(&:globals)
      all_opaques = ordered.flat_map(&:opaques)
      all_structs = ordered.flat_map(&:structs)
      all_unions = ordered.flat_map(&:unions)
      all_enums = ordered.flat_map(&:enums)
      all_variants = ordered.flat_map(&:variants)
      all_static_asserts = ordered.flat_map(&:static_asserts)
      all_static_asserts.concat(@artifacts.external_layout_assertions)
      all_functions = ordered.flat_map(&:functions)

      all_opaques.concat(lower_imported_external_opaques)
      all_structs.concat(@artifacts.synthetic_structs.uniq { |s| s.linkage_name })
      all_enums.concat(@artifacts.synthetic_enums.uniq { |e| e.linkage_name })
      all_functions.concat(@artifacts.synthetic_functions.uniq { |f| f.linkage_name })

      # Add emit-generated declarations
      @artifacts.emitted_declarations.each do |emitted|
        case emitted
        when IR::Function
          all_functions << emitted
        when IR::StructDecl
          all_structs << emitted
        when IR::Constant
          all_constants << emitted
        end
      end

      IR::Program.new(
        module_name: @program.root_analysis.module_name,
        includes:,
        constants: all_constants,
        globals: all_globals,
        opaques: all_opaques,
        structs: all_structs,
        unions: all_unions,
        enums: all_enums,
        variants: all_variants,
        static_asserts: all_static_asserts,
        functions: all_functions,
        source_path: @program.root_path,
      )
    end

    def regenerate_cross_module_synthetics
      ordered_analysis_pairs.each do |path, analysis|
        next if analysis.module_kind == :raw_module

        prepare_analysis(analysis, source_path: path)
        analysis.ast.declarations.grep(AST::EventDecl).each do |decl|
          event_type = analysis.values.fetch(decl.name).type
          ensure_event_runtime(event_type) if event_type.is_a?(Types::Event)
        end
      end
    end

    # Canonical, deterministic iteration order over the program's analyses so
    # that lowering — and therefore the emitted C — is byte-identical regardless
    # of how the analyses were assembled (live ModuleLoader vs. JSON-reconstructed
    # bundle). Modules are emitted in dependency-first topological order, with
    # lexicographic module-name order as a stable tiebreaker for independent
    # modules and as a cycle-breaking fallback.
    def ordered_analysis_pairs
      @ordered_analysis_pairs ||= compute_ordered_analysis_pairs
    end

    def compute_ordered_analysis_pairs
      pairs = @program.analyses_by_path.to_a
      by_name = {}
      pairs.each do |path, analysis|
        name = analysis.module_name.to_s
        by_name[name] ||= [path, analysis]
      end

      present = by_name.keys.to_set
      deps_of = Hash.new { |hash, key| hash[key] = [] }
      pairs.each do |_path, analysis|
        name = analysis.module_name.to_s
        imported_module_names(analysis).each do |dep|
          deps_of[name] << dep if present.include?(dep) && dep != name
        end
      end
      deps_of.each_value(&:uniq!)

      canonical_module_names(by_name.keys, deps_of).map { |name| by_name[name] }
    end

    def imported_module_names(analysis)
      imports = analysis.respond_to?(:imports) ? analysis.imports : nil
      return [] unless imports.respond_to?(:values)

      imports.values.filter_map do |binding|
        binding.name.to_s if binding.respond_to?(:name) && binding.name
      end
    end

    def canonical_module_names(names, deps_of)
      visited = {}
      on_stack = {}
      order = []
      visit = nil
      visit = lambda do |name|
        return if visited[name] || on_stack[name]

        on_stack[name] = true
        (deps_of[name] || []).sort.each { |dep| visit.call(dep) }
        on_stack.delete(name)
        visited[name] = true
        order << name
      end
      names.sort.each { |name| visit.call(name) }
      order
    end

    def ordered_module_fragments(modules)
      ordered = ordered_analysis_pairs.filter_map { |_path, analysis| modules[analysis.module_name] }
      ordered.concat(modules.values - ordered)
      ordered
    end

    private

    include LowererScans
    include LowererDeclarations
    include LowererEvents
    include LowererFunctions
    include LowererAsync
    include LowererBlock
    include LowererProc
    include LowererLoops
    include LowererExpressions
    include LowererCalls
    include LowererForeignCstr
    include LowererStrBuffer
    include LowererResolve
    include LowererDyn
    include LowererUtils
  end
end
