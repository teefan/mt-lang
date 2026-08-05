# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandDebug
      def debug_command
        unless @argv.any?
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end

        resolution = extract_resolution_flags!
        input_paths = @argv.dup
        return 1 unless validate_source_operands("debug", input_paths)

        path = expand_source_paths(input_paths).first
        unless path
          @err.puts("no .mt files found in #{input_paths.join(', ')}")
          return 1
        end

        ensure_current_lockfile!(path) if resolution[:frozen]

        source = read_source_file(path)
        resolved_path = File.expand_path(path)

        tokens = MilkTea::Lexer.lex(source, path: resolved_path)

        parse_result = MilkTea::Parser.parse_collecting_errors(source, path: resolved_path)
        ast = parse_result.ast
        parse_errors = parse_result.errors.dup

        facts = nil
        snapshot = nil
        loader_ast = ast

        if ast && parse_errors.empty?
          begin
            loader = create_module_loader(path, locked: resolution[:locked], platform: ModuleLoader.default_host_platform)
            loader_ast = loader.load_file(resolved_path)

            import_result = loader.send(:imported_modules_for_ast_collecting_errors, loader_ast, importer_path: resolved_path)
            import_errors = import_result.respond_to?(:errors) ? import_result.errors : []
            parse_errors.concat(import_errors) unless import_errors.empty?

            snapshot = MilkTea::SemanticAnalyzer.tooling_snapshot(
              loader_ast,
              imported_modules: import_result.modules,
              allow_missing_imports: true,
              path: resolved_path,
            )
            facts = snapshot&.facts
          rescue MilkTea::LexError, MilkTea::ParseError, ModuleLoadError, SemanticError => e
            parse_errors << e
          end
        end

        text = DebugInfoFormatter.format_all(
          content: source,
          tokens: tokens,
          ast: loader_ast,
          parse_errors: parse_errors,
          facts: facts,
          snapshot: snapshot,
          path: resolved_path,
        )

        @out.puts(text)
        0
      rescue MilkTea::LexError => e
        @err.puts(ErrorFormatter.format(e, color: use_color?(@err)))
        1
      end
    end
  end
end
