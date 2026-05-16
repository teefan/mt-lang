# frozen_string_literal: true

require 'cgi/escape'
require 'uri'

module MilkTea
  module LSP
    # Collects parse and semantic errors and formats them as LSP Diagnostics
    class Diagnostics
      def self.collect(uri, content, shared_module_cache: nil, source_overrides: nil, dependency_resolution_mode: :auto, platform_override: nil)
        diagnostics = []
        sema_analysis = nil
        unresolved_import_paths = []
        path = uri_to_path(uri)
        resolution = DependencyResolution.resolve(path, mode: dependency_resolution_mode)
        effective_platform = effective_platform_for_path(path, platform_override:)

        # Parse
        begin
          ast = if path && File.file?(path)
                  parse_result = Parser.parse_collecting_errors(content, path: uri)
                  parse_result.errors.each { |error| diagnostics << format_error(error) }
                  parse_result.ast
                else
                  Parser.parse(content, path: uri)
                end
          return { diagnostics: diagnostics, analysis: sema_analysis } unless ast

          if resolution.error_message
            diagnostics << format_error(SemaError.new(resolution.error_message, line: 1, column: 1))
            return { diagnostics: diagnostics, analysis: sema_analysis }
          end

          conflict_error = root_platform_conflict_error(path, effective_platform)
          if conflict_error
            diagnostics << format_error(SemaError.new(conflict_error.message, line: 1, column: 1))
            return { diagnostics: diagnostics, analysis: sema_analysis }
          end

          imported_modules = resolve_imported_modules(
            uri,
            ast,
            diagnostics,
            resolution:,
            effective_platform:,
            shared_module_cache: shared_module_cache,
            source_overrides: source_overrides,
            content: content,
          )
          unresolved_import_paths = imported_modules.fetch(:unresolved_import_paths)

          # Semantic analysis — collect errors from all functions, not just first.
          begin
            result = Sema.check_collecting_errors(ast, imported_modules: imported_modules.fetch(:modules))
            sema_analysis = result[:analysis]
            result[:errors].reject { |e| redundant_unknown_import_error?(e, unresolved_import_paths) }
                           .each { |e| diagnostics << format_error(e) }
          rescue StandardError => e
            warn "Error collecting diagnostics: #{e.message}"
          end
        rescue MilkTea::LexError => e
          diagnostics << format_error(e)
        rescue StandardError => e
          warn "Error collecting diagnostics: #{e.message}"
        end

        # Lint warnings (severity: 2 = Warning)
        begin
          Linter.lint_source(content, path: uri, sema_analysis: sema_analysis, unresolved_import_paths: unresolved_import_paths).each do |w|
            diagnostics << format_warning(w, content: content)
          end
        rescue MilkTea::LexError, MilkTea::ParseError
          # Best-effort only while the user is mid-edit; lex/parse failures are
          # already reported by the main diagnostics path.
        rescue StandardError => e
          warn "Error collecting lint diagnostics: #{e.message}"
        end

        { diagnostics: diagnostics, analysis: sema_analysis }
      end

      private

      def self.resolve_imported_modules(uri, ast, diagnostics, resolution:, effective_platform:, shared_module_cache: nil, source_overrides: nil, content: nil)
        path = uri_to_path(uri)
        return { modules: {}, unresolved_import_paths: [] } unless path && File.file?(path)

        loader = ModuleLoader.new(
          module_roots: MilkTea::ModuleRoots.roots_for_path(path, locked: resolution.locked),
          package_graph: load_package_graph(path, locked: resolution.locked),
          shared_cache: shared_module_cache,
          source_overrides: source_overrides,
          platform: effective_platform,
        )
        resolution_result = loader.imported_modules_for_ast_collecting_errors(ast, importer_path: path)
        unresolved_import_paths = []

        resolution_result.errors.each do |entry|
          if entry.error.is_a?(ModuleLoadError)
            diagnostics << format_import_error(entry.error, entry.import, content: content)
            unresolved_import_paths << entry.import.path.to_s if entry.import
          else
            diagnostics << format_error(SemaError.new(entry.error.message))
          end
        end

        { modules: resolution_result.modules, unresolved_import_paths: unresolved_import_paths.uniq }
      rescue ModuleLoadError, PackageLockError => e
        if e.is_a?(ModuleLoadError)
          import = ast.imports.find { |candidate| candidate.path.to_s == e.path }
          diagnostics << format_import_error(e, import, content: content)
        else
          diagnostics << format_error(SemaError.new(e.message))
        end
        { modules: {}, unresolved_import_paths: [] }
      end

      def self.redundant_unknown_import_error?(error, unresolved_import_paths)
        return false unless error.is_a?(SemaError)
        return false unless error.message.start_with?("unknown import ")

        unresolved_import_paths.include?(error.message.delete_prefix("unknown import "))
      end

      def self.uri_to_path(uri)
        parsed = URI.parse(uri)
        return nil unless parsed.scheme == "file"

        CGI.unescape(parsed.path)
      rescue URI::InvalidURIError
        nil
      end

      def self.load_package_graph(path, locked: false)
        PackageGraph.load(path, locked:)
      rescue PackageManifestError
        nil
      end
      private_class_method :load_package_graph

      def self.effective_platform_for_path(path, platform_override: nil)
        return nil unless path

        ModuleLoader.effective_platform_for_path(path, platform_override:)
      end
      private_class_method :effective_platform_for_path

      def self.root_platform_conflict_error(path, effective_platform)
        return nil unless path && File.file?(path)
        return nil unless ModuleLoader.platform_suffix_for_path(path)

        ModuleLoader.resolve_source_path(path, platform: effective_platform, error_class: ModuleLoadError)
        nil
      rescue ModuleLoadError => e
        e
      end
      private_class_method :root_platform_conflict_error

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
          source: 'milk-tea',
          data: {
            stage: 'lint'
          }
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
          code: diagnostic_code(error),
          message: error.message.to_s,
          source: 'milk-tea',
          data: {
            stage: diagnostic_stage(error)
          }
        }
      end

      def self.format_import_error(error, import, content: nil)
        return format_error(SemaError.new(error.message)) unless import

        column, length = import_path_span(import, content)
        line_index = [import.line.to_i - 1, 0].max
        start_char = [column.to_i - 1, 0].max
        end_char = start_char + [length.to_i, 1].max

        {
          range: {
            start: {
              line: line_index,
              character: start_char,
            },
            end: {
              line: line_index,
              character: end_char,
            }
          },
          severity: 1,
          code: diagnostic_code(error),
          message: error.message.to_s,
          source: 'milk-tea',
          data: {
            stage: diagnostic_stage(error)
          }
        }
      end

      def self.diagnostic_code(error)
        case error
        when MilkTea::LexError
          'lex/error'
        when MilkTea::ParseError
          'parse/error'
        when MilkTea::ModuleLoadError
          'import/load-error'
        when MilkTea::SemaError
          'sema/error'
        else
          'tooling/error'
        end
      end

      def self.diagnostic_stage(error)
        case error
        when MilkTea::LexError
          'lex'
        when MilkTea::ParseError
          'parse'
        when MilkTea::ModuleLoadError
          'import'
        when MilkTea::SemaError
          'sema'
        else
          'tooling'
        end
      end

      def self.import_path_span(import, content)
        return [import.column || 1, import.length || 1] unless content && import.line

        line_text = content.split("\n", -1)[import.line - 1]
        return [import.column || 1, import.length || 1] unless line_text

        path_text = import.path.to_s
        index = line_text.index(path_text)
        return [index + 1, path_text.length] if index

        [import.column || 1, import.length || 1]
      rescue StandardError
        [import.column || 1, import.length || 1]
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
