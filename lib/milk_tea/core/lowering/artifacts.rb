# frozen_string_literal: true

module MilkTea
  class Lowerer
    class Artifacts
      attr_accessor :synthetic_structs, :synthetic_enums, :synthetic_functions, :synthetic_constants
      attr_accessor :emitted_declarations, :external_layout_assertions, :emitted_external_layout_pairs
      attr_accessor :lowered_function_linkage_names, :event_runtime_infos
      attr_accessor :subscription_runtime_emitted, :event_error_enum_emitted

      def initialize
        @synthetic_structs = []
        @synthetic_enums = []
        @synthetic_functions = []
        @synthetic_constants = []
        @emitted_declarations = []
        @external_layout_assertions = []
        @emitted_external_layout_pairs = {}
        @lowered_function_linkage_names = {}
        @event_runtime_infos = {}
        @subscription_runtime_emitted = false
        @event_error_enum_emitted = false
      end
    end
  end
end
