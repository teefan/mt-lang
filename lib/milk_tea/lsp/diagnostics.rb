# frozen_string_literal: true

require 'cgi/escape'
require 'uri'

module MilkTea
  module LSP
    # Collects parse and semantic errors and formats them as LSP Diagnostics
    class Diagnostics
      def self.collect(uri, content)
        diagnostics = []

        # Parse
        begin
          ast = Parser.parse(content, path: uri)
          imported_modules = resolve_imported_modules(uri, ast, diagnostics)

          # Semantic analysis — collect errors from all functions, not just first.
          begin
            result = Sema.check_collecting_errors(ast, imported_modules: imported_modules)
            result[:errors].each { |e| diagnostics << format_error(e) }
          rescue StandardError => e
            warn "Error collecting diagnostics: #{e.message}"
          end
        rescue MilkTea::LexError => e
          diagnostics << format_error(e)
        rescue MilkTea::ParseError => e
          diagnostics << format_error(e)
        rescue StandardError => e
          warn "Error collecting diagnostics: #{e.message}"
        end

        # Lint warnings (severity: 2 = Warning)
        begin
          Linter.lint_source(content, path: uri).each { |w| diagnostics << format_warning(w) }
        rescue StandardError => e
          warn "Error collecting lint diagnostics: #{e.message}"
        end

        diagnostics
      end

      private

      def self.resolve_imported_modules(uri, ast, diagnostics)
        path = uri_to_path(uri)
        return {} unless path && File.file?(path)

        loader = ModuleLoader.new(module_roots: MilkTea::ModuleRoots.roots_for_path(path))
        loader.imported_modules_for_ast(ast)
      rescue ModuleLoadError => e
        diagnostics << format_error(SemaError.new(e.message))
        {}
      end

      def self.uri_to_path(uri)
        parsed = URI.parse(uri)
        return nil unless parsed.scheme == "file"

        CGI.unescape(parsed.path)
      rescue URI::InvalidURIError
        nil
      end

      def self.format_warning(warning)
        line = warning.line.to_i
        lsp_severity = case warning.severity
                       when :error   then 1
                       when :warning then 2
                       when :hint    then 4
                       else               2
                       end
        {
          range: {
            start: { line: [line - 1, 0].max, character: 0 },
            end:   { line: [line - 1, 0].max, character: 0 }
          },
          severity: lsp_severity,
          code: warning.code,
          message: warning.message.to_s,
          source: 'milk-tea'
        }
      end

      def self.format_error(error)
        line = extract_line(error)
        column = extract_column(error)

        {
          range: {
            start: {
              line: (line.to_i - 1),
              character: (column.to_i - 1)
            },
            end: {
              line: (line.to_i - 1),
              character: (column.to_i)
            }
          },
          severity: 1,  # Error
          message: error.message.to_s,
          source: 'milk-tea'
        }
      end

      def self.extract_line(error)
        case error
        when MilkTea::LexError
          error.line || 1
        when MilkTea::ParseError
          error.token&.line || 1
        when MilkTea::SemaError
          error.line || 1
        else
          1
        end
      end

      def self.extract_column(error)
        case error
        when MilkTea::LexError
          error.column || 1
        when MilkTea::ParseError
          error.token&.column || 1
        when MilkTea::SemaError
          error.column || 1
        else
          1
        end
      end
    end
  end
end
