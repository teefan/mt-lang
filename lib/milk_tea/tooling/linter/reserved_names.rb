# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterReservedNames
      private

      def declare_reserved_value_type_module_binding(name, kind_label:, line:, column:, unavailable_names:)
        declare_reserved_module_binding(
          name,
          kind_label:,
          line:,
          column:,
          unavailable_names:,
          reserved_names: RESERVED_VALUE_TYPE_NAMES,
        )
      end
  
      def declare_reserved_import_alias_module_binding(name, kind_label:, line:, column:, unavailable_names:)
        declare_reserved_module_binding(
          name,
          kind_label:,
          line:,
          column:,
          unavailable_names:,
          reserved_names: RESERVED_IMPORT_ALIAS_NAMES,
        )
      end
  
      def declare_reserved_module_binding(name, kind_label:, line:, column:, unavailable_names:, reserved_names:)
        replacement_name = nil
        replacement_base_name = nil
        if reserved_names.include?(name)
          replacement_base_name = suggested_reserved_primitive_name(name, kind_label:)
          replacement_name = next_available_reserved_primitive_name(
            replacement_base_name,
            unavailable_names,
          )
        end
  
        binding = Binding.new(
          name:,
          line:,
          column:,
          used: false,
          binding_kind: :module,
          allow_prefer_let: false,
          mutated: false,
          replacement_name:,
          replacement_base_name:,
        )
        register_reserved_primitive_name_fix(binding, kind_label:, replacement_name:) if replacement_name
        @module_bindings[name] = binding
      end
  
      def declare_reserved_primitive_module_binding(name, kind_label:, line:, column:, unavailable_names:)
        declare_reserved_value_type_module_binding(name, kind_label:, line:, column:, unavailable_names:)
      end
      def warn_reserved_primitive_name(name, line:, column:, kind_label:, reserved_names: RESERVED_VALUE_TYPE_NAMES)
        return unless reserved_names.include?(name)
  
        @warnings << Warning.new(
          path: @path,
          line:,
          column:,
          length: name.length,
          code: "reserved-primitive-name",
          message: "#{kind_label} '#{name}' uses reserved built-in type name '#{name}'; rename it before this becomes a hard error",
          severity: :warning,
          symbol_name: name,
        )
      end
  
      def warn_large_event_capacity(event_decl, owner_name:)
        label = owner_name ? "#{owner_name}.#{event_decl.name}" : event_decl.name
  
        @warnings << Warning.new(
          path: @path,
          line: event_decl.line,
          column: event_decl.column,
          length: event_decl.name.length,
          code: "event-capacity",
          message: "event '#{label}' capacity #{event_decl.capacity} makes emit() copy up to #{event_decl.capacity} listeners onto the stack; prefer a smaller fixed capacity or a managed queue abstraction",
          severity: :warning,
          symbol_name: event_decl.name,
        )
      end
  
      def warn_redundant_ignored_match_binding(name, line:, column:)
        return unless name == "_"
  
        span = nil
        if line && column
          source_line = @source_lines[line - 1].to_s
          span = self.class.redundant_ignored_match_binding_span(source_line, column:)
        end
  
        @warnings << Warning.new(
          path: @path,
          line:,
          column: span ? span[:start_char] + 1 : column,
          length: span ? span[:end_char] - span[:start_char] : 1,
          code: "redundant-ignored-match-binding",
          message: "ignored match binding is redundant; remove 'as _'",
          severity: :hint,
        )
      end
  
      def warn_reserved_primitive_type_params(type_params, kind_label:)
        Array(type_params).each do |type_param|
          warn_reserved_primitive_name(
            type_param.name,
            line: type_param.line,
            column: type_param.column,
            kind_label:,
            reserved_names: RESERVED_TYPE_BINDING_NAMES,
          )
        end
      end
      def register_reserved_primitive_name_fix(binding, kind_label:, replacement_name:)
        warn_reserved_primitive_name(binding.name, line: binding.line, column: binding.column, kind_label:)
        return unless binding.line && binding.column
  
        binding.fix_index = @reserved_primitive_name_fixes.length
        @reserved_primitive_name_fixes << ReservedPrimitiveNameFix.new(
          kind: kind_label,
          original_name: binding.name,
          replacement_name: replacement_name,
          sites: [ReservedPrimitiveNameSite.new(line: binding.line, column: binding.column, length: binding.name.length)],
        )
      end
  
      def suggested_reserved_primitive_name(name, kind_label:)
        case kind_label
        when "function"
          "#{name}_fn"
        when "import alias"
          "#{name}_module"
        else
          "#{name}_value"
        end
      end
  
      def next_available_reserved_primitive_name(base_name, unavailable_names)
        unavailable = unavailable_names.to_set
        return base_name unless unavailable.include?(base_name)
  
        suffix = 2
        loop do
          candidate = "#{base_name}_#{suffix}"
          return candidate unless unavailable.include?(candidate)
  
          suffix += 1
        end
      end
  
      def visible_binding_names(excluding_name: nil)
        names = visible_bindings.each_with_object(Set.new) do |binding, result|
          result << binding.name
          result << binding.replacement_name if binding.replacement_name
        end
        names.delete(excluding_name) if excluding_name
        names
      end
  
      def visible_bindings
        @module_bindings.values + @scopes.flat_map(&:values)
      end
  
      def resolve_reserved_primitive_name_conflicts!(declared_name)
        visible_bindings.each do |binding|
          next unless binding.replacement_name == declared_name
  
          replacement_name = next_available_reserved_primitive_name(
            binding.replacement_base_name || binding.replacement_name,
            visible_binding_names(excluding_name: binding.name),
          )
          next if replacement_name == binding.replacement_name
  
          binding.replacement_name = replacement_name
          next unless binding.fix_index
  
          fix = @reserved_primitive_name_fixes[binding.fix_index]
          @reserved_primitive_name_fixes[binding.fix_index] = fix.with(replacement_name:)
        end
      end
      def record_reserved_primitive_identifier_use(binding, identifier)
        return unless binding.fix_index
        return unless identifier&.line && identifier&.column
  
        @reserved_primitive_name_fixes[binding.fix_index].sites << ReservedPrimitiveNameSite.new(
          line: identifier.line,
          column: identifier.column,
          length: binding.name.length,
        )
      end
    end
  end
end
