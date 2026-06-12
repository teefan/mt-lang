# frozen_string_literal: true

require_relative "lowering/scans"
require_relative "lowering/declarations"
require_relative "lowering/events"
require_relative "lowering/functions"
require_relative "lowering/async"
require_relative "lowering/block"
require_relative "lowering/proc"
require_relative "lowering/loops"
require_relative "lowering/expressions"
require_relative "lowering/calls"
require_relative "lowering/foreign_cstr"
require_relative "lowering/str_buffer"
require_relative "lowering/resolve"
require_relative "lowering/utils"

module MilkTea
  class LoweringError < StandardError; end

  class Lowering
    def self.lower(program)
      lowerer = Lowerer.new(program)
      ir_program, _modules = lowerer.lower_and_assemble
      ir_program
    end

    def self.lower_incremental(program, cached: nil)
      lowerer = Lowerer.new(program)
      lowerer.lower_and_assemble(cached:)
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
    include TypeCompatibilityPredicates

    def initialize(program)
      @program = program
      @analysis = nil
      @current_analysis_path = nil
      @module_name = nil
      @module_prefix = nil
      @imports = {}
      @types = {}
      @values = {}
      @functions = {}
      @struct_types = {}
      @union_types = {}
      @synthetic_structs = []
      @synthetic_enums = []
      @synthetic_functions = []
      @synthetic_proc_counter = 0
      @event_runtime_infos = {}
      @subscription_runtime_emitted = false
      @event_error_enum_emitted = false
      @lowered_function_c_names = {}
      @method_definitions = build_method_definitions
    end

    def lower
      lower_and_assemble
    end

    def lower_and_assemble(cached: nil)
      modules = lower_modules(cached:)
      [assemble_modules(modules), modules]
    end

    def lower_modules(cached: nil)
      if @program.root_analysis.module_kind == :raw_module
        raise LoweringError, "cannot emit C for external file #{@program.root_analysis.module_name}"
      end

      per_module_funcs = Hash.new { |h, k| h[k] = [] }
      modules = {}

      cached&.each do |module_name, cached_ir|
        modules[module_name] = cached_ir.with(functions: [])
        per_module_funcs[module_name] = cached_ir.functions.dup
        cached_ir.functions.each { |f| @lowered_function_c_names[f.c_name] = true }
      end

      @program.analyses_by_path.each_pair do |path, analysis|
        next if analysis.module_kind == :raw_module
        next if modules.key?(analysis.module_name)

        prepare_analysis(analysis, source_path: path)
        collect_structs

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
      end

      pending = true
      while pending
        pending = false

        @program.analyses_by_path.each_pair do |path, analysis|
          next if analysis.module_kind == :raw_module

          prepare_analysis(analysis, source_path: path)
          ensure_events_for_analysis(analysis)
          newly_lowered = lower_functions
          next if newly_lowered.empty?

          per_module_funcs[analysis.module_name].concat(newly_lowered)
          pending = true
        end
      end

      modules.transform_values do |fragment|
        fragment.with(functions: per_module_funcs[fragment.module_name])
      end
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

      all_constants = modules.values.flat_map(&:constants)
      all_globals = modules.values.flat_map(&:globals)
      all_opaques = modules.values.flat_map(&:opaques)
      all_structs = modules.values.flat_map(&:structs)
      all_unions = modules.values.flat_map(&:unions)
      all_enums = modules.values.flat_map(&:enums)
      all_variants = modules.values.flat_map(&:variants)
      all_static_asserts = modules.values.flat_map(&:static_asserts)
      all_functions = modules.values.flat_map(&:functions)

      all_opaques.concat(lower_imported_external_opaques)
      all_structs.concat(@synthetic_structs)
      all_enums.concat(@synthetic_enums)
      all_functions.concat(@synthetic_functions)

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
      @program.analyses_by_path.each_pair do |path, analysis|
        next if analysis.module_kind == :raw_module

        prepare_analysis(analysis, source_path: path)
        analysis.ast.declarations.grep(AST::EventDecl).each do |decl|
          event_type = analysis.values.fetch(decl.name).type
          ensure_event_runtime(event_type) if event_type.is_a?(Types::Event)
        end
      end
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
    include LowererUtils
  end
end
