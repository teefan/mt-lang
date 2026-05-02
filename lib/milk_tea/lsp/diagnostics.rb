# frozen_string_literal: true

require 'cgi/escape'
require 'uri'

module MilkTea
  module LSP
    # Collects parse and semantic errors and formats them as LSP Diagnostics
    class Diagnostics
      def self.collect(uri, content, shared_module_cache: nil)
        diagnostics = []

        # Parse
        begin
          ast = Parser.parse(content, path: uri)
          imported_modules = resolve_imported_modules(uri, ast, diagnostics, shared_module_cache: shared_module_cache)

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
          Linter.lint_source(content, path: uri).each { |w| diagnostics << format_warning(w, content: content) }
        rescue StandardError => e
          warn "Error collecting lint diagnostics: #{e.message}"
        end

        diagnostics
      end

      private

      def self.resolve_imported_modules(uri, ast, diagnostics, shared_module_cache: nil)
        path = uri_to_path(uri)
        return {} unless path && File.file?(path)

        loader = ModuleLoader.new(
          module_roots: MilkTea::ModuleRoots.roots_for_path(path),
          shared_cache: shared_module_cache,
        )
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

      def self.format_warning(warning, content: nil)
        line = warning.line.to_i
        line_index = [line - 1, 0].max
        start_char, end_char = extract_warning_range(warning, content)

        lsp_severity = case warning.severity
                       when :error   then 1
                       when :warning then 2
                       when :hint    then 4
                       else               2
                       end
        {
          range: {
            start: { line: line_index, character: start_char },
            end:   { line: line_index, character: end_char }
          },
          severity: lsp_severity,
          code: warning.code,
          message: warning.message.to_s,
          source: 'milk-tea'
        }
      end

      # Returns [start_char, end_char] in 0-based LSP coordinates.
      # Falls back to [0, 1] when a precise token span cannot be inferred.
      def self.extract_warning_range(warning, content)
        if warning.respond_to?(:column) && warning.column
          start_char = [warning.column.to_i - 1, 0].max
          len = warning.respond_to?(:length) ? warning.length.to_i : 0
          len = 1 if len <= 0
          return [start_char, start_char + len]
        end

        return [0, 1] unless content && warning.line

        lines = content.split("\n", -1)
        line_text = lines[warning.line - 1]
        return [0, 1] unless line_text

        token_name = warning.respond_to?(:symbol_name) ? warning.symbol_name : nil
        token_name ||= extract_quoted_name(warning.message.to_s)
        return [0, 1] unless token_name && !token_name.empty?

        # Prefer whole-token matches so names like "arg" don't match inside "argv".
        token_match = line_text.match(/\b#{Regexp.escape(token_name)}\b/)
        return [token_match.begin(0), token_match.end(0)] if token_match

        # Fallback for non-word symbols if any rule introduces them.
        index = line_text.index(token_name)
        return [index, index + token_name.length] if index

        [0, 1]
      rescue StandardError
        [0, 1]
      end

      def self.extract_quoted_name(message)
        match = message.match(/'([^']+)'/)
        match && match[1]
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
