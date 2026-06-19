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

      def synthetic_counts
        [@synthetic_structs.length, @synthetic_enums.length, @synthetic_functions.length, @synthetic_constants.length]
      end

      def synthetic_slice(struct_start:, enum_start:, function_start:, constant_start:)
        {
          structs: slice_from(@synthetic_structs, struct_start),
          enums: slice_from(@synthetic_enums, enum_start),
          functions: slice_from(@synthetic_functions, function_start),
          constants: slice_from(@synthetic_constants, constant_start),
        }
      end

      def merge_cached_synthetics(cached)
        cached&.each do |_name, synths|
          @synthetic_structs.concat(synths[:structs] || [])
          @synthetic_enums.concat(synths[:enums] || [])
          @synthetic_functions.concat(synths[:functions] || [])
          @synthetic_constants.concat(synths[:constants] || [])
        end
      end

      private

      def slice_from(array, start)
        return [] unless start
        return array if start.zero?

        array[start..] || []
      end
    end
  end
end
