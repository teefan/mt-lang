# frozen_string_literal: true

module MilkTea
  module Bindgen
    class Generator
      module GeneratorOverrides
        private

        def function_param_type_override(function_name, param_name)
          @function_param_type_overrides.dig(function_name, param_name)
        end

        def function_return_type_override(function_name)
          @function_return_type_overrides[function_name]
        end

        def field_type_override(type_name, field_name)
          @field_type_overrides.dig(type_name, field_name)
        end

        def normalize_function_param_type_overrides(overrides)
          return {} if overrides.nil?

          raise BindgenError, "function_param_type_overrides must be a hash" unless overrides.is_a?(Hash)

          overrides.each_with_object({}) do |(function_name, param_overrides), normalized|
            unless function_name.is_a?(String) || function_name.is_a?(Symbol)
              raise BindgenError, "function_param_type_overrides function names must be strings or symbols"
            end

            raise BindgenError, "function_param_type_overrides for #{function_name} must be a hash" unless param_overrides.is_a?(Hash)

            normalized[function_name.to_s] = param_overrides.each_with_object({}) do |(param_name, type), params|
              unless param_name.is_a?(String) || param_name.is_a?(Symbol)
                raise BindgenError, "function_param_type_overrides parameter names must be strings or symbols"
              end

              raise BindgenError, "function_param_type_overrides for #{function_name}.#{param_name} must be a non-empty string" unless type.is_a?(String) && !type.empty?

              params[param_name.to_s] = type
            end.freeze
          end.freeze
        end

        def normalize_field_type_overrides(overrides)
          return {} if overrides.nil?

          raise BindgenError, "field_type_overrides must be a hash" unless overrides.is_a?(Hash)

          overrides.each_with_object({}) do |(type_name, field_overrides), normalized|
            unless type_name.is_a?(String) || type_name.is_a?(Symbol)
              raise BindgenError, "field_type_overrides type names must be strings or symbols"
            end

            raise BindgenError, "field_type_overrides for #{type_name} must be a hash" unless field_overrides.is_a?(Hash)

            normalized[type_name.to_s] = field_overrides.each_with_object({}) do |(field_name, type), fields|
              unless field_name.is_a?(String) || field_name.is_a?(Symbol)
                raise BindgenError, "field_type_overrides field names must be strings or symbols"
              end

              raise BindgenError, "field_type_overrides for #{type_name}.#{field_name} must be a non-empty string" unless type.is_a?(String) && !type.empty?

              fields[field_name.to_s] = type
            end.freeze
          end.freeze
        end

        def normalize_module_imports(imports)
          return [] if imports.nil?
          raise BindgenError, "module_imports must be an array" unless imports.is_a?(Array)

          imports.map do |entry|
            raise BindgenError, "module_imports entries must be hashes" unless entry.is_a?(Hash)

            module_name = entry.fetch(:module_name) { entry.fetch("module_name", nil) }
            import_alias = entry.fetch(:alias) { entry.fetch("alias", nil) }
            raise BindgenError, "module_imports module_name must be a non-empty string" unless module_name.is_a?(String) && !module_name.empty?
            raise BindgenError, "module_imports alias must be a non-empty string" unless import_alias.is_a?(String) && !import_alias.empty?

            { module_name:, alias: import_alias }
          end.freeze
        end

        def normalize_type_overrides(overrides)
          return {} if overrides.nil?
          raise BindgenError, "type_overrides must be a hash" unless overrides.is_a?(Hash)

          overrides.each_with_object({}) do |(type_name, mapped_type), normalized|
            unless type_name.is_a?(String) || type_name.is_a?(Symbol)
              raise BindgenError, "type_overrides type names must be strings or symbols"
            end

            raise BindgenError, "type_overrides for #{type_name} must be a non-empty string" unless mapped_type.is_a?(String) && !mapped_type.empty?

            normalized[type_name.to_s] = mapped_type
          end.freeze
        end

        def normalize_type_name_overrides(overrides)
          return {} if overrides.nil?
          raise BindgenError, "type_name_overrides must be a hash" unless overrides.is_a?(Hash)

          overrides.each_with_object({}) do |(type_name, visible_name), normalized|
            unless type_name.is_a?(String) || type_name.is_a?(Symbol)
              raise BindgenError, "type_name_overrides type names must be strings or symbols"
            end
            unless visible_name.is_a?(String) && !visible_name.empty?
              raise BindgenError, "type_name_overrides for #{type_name} must be a non-empty string"
            end

            normalized[type_name.to_s] = visible_name
          end.freeze
        end

        def normalize_function_return_type_overrides(overrides)
          return {} if overrides.nil?

          raise BindgenError, "function_return_type_overrides must be a hash" unless overrides.is_a?(Hash)

          overrides.each_with_object({}) do |(function_name, type), normalized|
            unless function_name.is_a?(String) || function_name.is_a?(Symbol)
              raise BindgenError, "function_return_type_overrides function names must be strings or symbols"
            end

            raise BindgenError, "function_return_type_overrides for #{function_name} must be a non-empty string" unless type.is_a?(String) && !type.empty?

            normalized[function_name.to_s] = type
          end.freeze
        end
      end
    end
  end
end
