# frozen_string_literal: true

# Lowering transforms the Sema analysis into IR::Program.
#
# Contract with Sema::Analysis — the Lowerer reads these fields:
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

require_relative "lowering/scans"
require_relative "lowering/declarations"
require_relative "lowering/events"
require_relative "lowering/functions"
require_relative "lowering/async/analysis"
require_relative "lowering/async/normalization"
require_relative "lowering/async/lowering"
require_relative "lowering/async"
require_relative "lowering/block"
require_relative "lowering/proc"
require_relative "lowering/loops"
require_relative "lowering/expressions"
require_relative "lowering/calls"
require_relative "lowering/foreign_cstr"
require_relative "lowering/str_buffer"
require_relative "lowering/resolve"
require_relative "lowering/dyn"
require_relative "lowering/utils"
require_relative "lowering/artifacts"
require_relative "lowering/module_context"

module MilkTea
  class LoweringError < StandardError; end

  class Lowering
    def self.lower(program)
      lowerer = Lowerer.new(program)
      ir_program, _modules, _synths = lowerer.lower_and_assemble
      ir_program
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

    def initialize(program)
      @program = program
      @ctx = ModuleContext.new
      @artifacts = Artifacts.new
      @synthetic_proc_counter = 0
      @parallel_for_counter = 0
      @method_definitions = build_method_definitions
    end

    def lower
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

      @program.analyses_by_path.each_pair do |path, analysis|
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

        @program.analyses_by_path.each_pair do |path, analysis|
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

      all_constants = modules.values.flat_map(&:constants)
      all_constants.concat(@artifacts.synthetic_constants)
      all_globals = modules.values.flat_map(&:globals)
      all_opaques = modules.values.flat_map(&:opaques)
      all_structs = modules.values.flat_map(&:structs)
      all_unions = modules.values.flat_map(&:unions)
      all_enums = modules.values.flat_map(&:enums)
      all_variants = modules.values.flat_map(&:variants)
      all_static_asserts = modules.values.flat_map(&:static_asserts)
      all_static_asserts.concat(@artifacts.external_layout_assertions)
      all_functions = modules.values.flat_map(&:functions)

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
    include LowererDyn
    include LowererUtils
  end
end
