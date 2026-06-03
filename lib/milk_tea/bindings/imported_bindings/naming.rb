# frozen_string_literal: true

module MilkTea
  module ImportedBindings
    class Generator
      module GeneratorNaming
        OPENGL_TYPED_SUFFIX_TOKENS = [
          ["ui64v", %w[uint64 values]],
          ["i64v", %w[int64 values]],
          ["uiv", %w[uint values]],
          ["iv", %w[int values]],
          ["fi", %w[float int]],
          ["fv", %w[float values]],
          ["dv", %w[double values]],
          ["ubv", %w[ubyte values]],
          ["usv", %w[ushort values]],
          ["bv", %w[byte values]],
          ["sv", %w[short values]],
          ["ui64", %w[uint64]],
          ["i64", %w[int64]],
          ["ui", %w[uint]],
          ["i", %w[int]],
          ["f", %w[float]],
          ["d", %w[double]],
          ["ub", %w[ubyte]],
          ["us", %w[ushort]],
          ["b", %w[byte]],
          ["s", %w[short]],
          ["v", %w[values]],
        ].freeze
        OPENGL_DOMAIN_MARKERS = {
          "i" => "integer",
          "l" => "long",
          "p" => "packed",
        }.freeze
        OPENGL_INDEXED_PARAM_NAMES = %w[buf index mask_number].freeze
        OPENGL_TYPED_ALPHA_STEMS = %w[
          array
          attrib
          boolean
          buffer
          double
          feedback
          float
          framebuffer
          indexed
          integer
          internalformat
          interface
          multisample
          object
          parameter
          pipeline
          pointer
          program
          query
          resource
          shader
          stage
          subroutine
          subroutines
          sync
          uniform
        ].freeze
        OPENGL_TYPED_QUERY_BASES = %w[boolean double float integer].freeze
        OPENGL_NUMERIC_SUFFIX_CONTEXTS = %w[
          attrib
          boolean
          double
          feedback
          float
          int
          integer
          integer64
          long
          matrix
          normalized
          object
          packed
          parameter
          uint
          uniform
        ].freeze

        private

        def normalize_opengl_snake_case(name)
          tokens = name.to_s.split("_").reject(&:empty?)
          normalized = []
          index = 0

          while index < tokens.length
            token = tokens[index]
            next_token = tokens[index + 1]

            case token
            when "getn"
              normalized.concat(%w[get n])
              index += 1
              next
            when "64i"
              if next_token == "v"
                if normalized.last == "integer"
                  normalized[-1] = "integer64"
                  normalized.concat(%w[indexed values])
                else
                  normalized.concat(%w[int64 indexed values])
                end
                index += 2
                next
              end
            when "i"
              if next_token == "v"
                if OPENGL_TYPED_QUERY_BASES.include?(normalized.last)
                  normalized.concat(%w[indexed values])
                else
                  normalized.concat(%w[int indexed values])
                end
                index += 2
                next
              end
            when "i64"
              if next_token == "v"
                normalized.concat(%w[int64 indexed values])
                index += 2
                next
              end
            when "ui64"
              if next_token == "v"
                normalized.concat(%w[uint64 indexed values])
                index += 2
                next
              end
            when "64v"
              case normalized.last
              when "integer"
                normalized[-1] = "integer64"
                normalized << "values"
                index += 1
                next
              when "int"
                normalized[-1] = "int64"
                normalized << "values"
                index += 1
                next
              when "uint"
                normalized[-1] = "uint64"
                normalized << "values"
                index += 1
                next
              end
            end

            if (domain_marker = opengl_domain_marker(token, next_token))
              normalized << domain_marker
              index += 1
              next
            end

            if (expanded = expand_opengl_special_token(token, numeric_context: opengl_numeric_suffix_context?(normalized)))
              normalized.concat(expanded)
              index += 1
              next
            end

            normalized << token
            index += 1
          end

          normalized.join("_")
        end

        def normalize_opengl_terminal_suffix(name, raw_name)
          normalized = if name.end_with?("indexedfv")
                         "#{name.delete_suffix('indexedfv')}indexed_float_values"
                       elsif name.end_with?("indexedf")
                         "#{name.delete_suffix('indexedf')}indexed_float"
                       else
                         name
                       end

          raw_text = raw_name.to_s
          if raw_text.end_with?("i") && normalized.end_with?("i")
            suffix = opengl_indexed_terminal_variant?(raw_name) ? "indexed" : "int"
            return "#{normalized.delete_suffix('i')}_#{suffix}"
          end

          return "#{normalized.delete_suffix('f')}_float" if raw_text.end_with?("f") && normalized.end_with?("f")

          normalized
        end

        def opengl_indexed_terminal_variant?(raw_name)
          raw_declaration = @raw_function_declarations[raw_name]
          return false unless raw_declaration

          raw_declaration.params
            .map { |param| snake_case(param.name) }
            .any? { |name| OPENGL_INDEXED_PARAM_NAMES.include?(name) }
        end

        def opengl_domain_marker(token, next_token)
          return unless OPENGL_DOMAIN_MARKERS.key?(token)
          return unless next_token
          return unless next_token == "format" || next_token == "pointer" || next_token.match?(/\A\d/)

          OPENGL_DOMAIN_MARKERS.fetch(token)
        end

        def opengl_numeric_suffix_context?(normalized_tokens)
          last_token = normalized_tokens.last
          last_token && OPENGL_NUMERIC_SUFFIX_CONTEXTS.include?(last_token)
        end

        def expand_opengl_special_token(token, numeric_context:)
          return %w[integer int values] if token == "iiv"
          return %w[integer uint values] if token == "iuiv"

          if token.start_with?("n") && token.length > 1
            expanded = expand_opengl_typed_token(token[1..], numeric_context: true)
            return ["normalized", *expanded] if expanded
          end

          expand_opengl_typed_token(token, numeric_context:)
        end

        def expand_opengl_typed_token(token, numeric_context:)
          OPENGL_TYPED_SUFFIX_TOKENS.each do |suffix, replacement|
            next unless token.end_with?(suffix)

            prefix = token.delete_suffix(suffix)
            if prefix.empty?
              return nil if suffix == "v"
              return replacement if numeric_context

              next
            end

            if prefix.match?(/\A\d+\z|\A\d+x\d+\z/)
              return nil unless numeric_context

              return [prefix, *replacement]
            end

            if prefix.match?(/\A[a-z]+\z/) && OPENGL_TYPED_ALPHA_STEMS.include?(prefix)
              return [prefix, *replacement]
            end
          end

          nil
        end

        def snake_case(name)
          name.to_s
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
            .gsub(/([a-z0-9])([A-Z])/, '\\1_\\2')
            .downcase
            .gsub(/([a-z])(\d+)_d\b/, '\1_\2d')
        end

        def camelize_binding_name(name)
          parts = name.to_s.split("_").reject(&:empty?)
          return "" if parts.empty?

          parts.map do |part|
            if part.match?(/\A\d+\z/)
              part
            else
              part[0].upcase + part[1..].to_s.downcase
            end
          end.join
        end

        def openglize_binding_name(name)
          name.to_s
            .gsub(/([A-Za-z])((?:i64|i|ui)_v)(?=\z|_)/, '\\1_\\2')
            .gsub(/(?<!_)([A-Za-z])(\d[A-Za-z0-9]*)(?=[A-Z_]|\z)/, '\1_\2')
            .gsub(/_(\d)D(?=[A-Z_]|\z)/, '_\1d')
        end
      end
    end
  end
end
