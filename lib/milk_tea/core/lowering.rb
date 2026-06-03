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
      Lowerer.new(program).lower
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
      if @program.root_analysis.module_kind == :raw_module
        raise LoweringError, "cannot emit C for external file #{@program.root_analysis.module_name}"
      end

      includes = collect_includes

      constants = []
      globals = []
      opaques = []
      structs = []
      unions = []
      enums = []
      static_asserts = []
      functions = []

      @program.analyses_by_path.each_pair do |path, analysis|
        next if analysis.module_kind == :raw_module

        prepare_analysis(analysis, source_path: path)
        collect_structs

        constants.concat(lower_constants)
        globals.concat(lower_globals)
        opaques.concat(lower_opaques)
        structs.concat(lower_structs)
        unions.concat(lower_unions)
        enums.concat(lower_enums)
        static_asserts.concat(lower_static_asserts)
        functions.concat(lower_functions)
      end

      pending_functions = true
      while pending_functions
        pending_functions = false

        @program.analyses_by_path.each_pair do |path, analysis|
          next if analysis.module_kind == :raw_module

          prepare_analysis(analysis, source_path: path)
          newly_lowered = lower_functions
          next if newly_lowered.empty?

          functions.concat(newly_lowered)
          pending_functions = true
        end
      end

      opaques.concat(lower_imported_external_opaques)
      structs.concat(@synthetic_structs)
      enums.concat(@synthetic_enums)
      functions.concat(@synthetic_functions)

      IR::Program.new(
        module_name: @program.root_analysis.module_name,
        includes:,
        constants:,
        globals:,
        opaques:,
        structs:,
        unions:,
        enums:,
        variants: lower_variants,
        static_asserts:,
        functions:,
        source_path: @program.root_path,
      )
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
