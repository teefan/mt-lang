# frozen_string_literal: true

module MilkTea
  module LSP
    class Workspace
      module WorkspaceAnalysis
        private

        # ── Compilation helpers ─────────────────────────────────────────────────

        def lex_document(uri)
          content = get_content(uri)
          return nil if content.empty?

          recovery_errors = []
          tokens = MilkTea::Lexer.lex(content, path: uri, recovery_errors:)
          @last_good_tokens_cache[uri] = tokens
          index_identifier_tokens(uri, tokens) if tokens
          tokens
        rescue StandardError
          @last_good_tokens_cache[uri] || @tokens_cache[uri]
        end

        def parse_document(uri)
          tokens = get_tokens(uri)
          return nil if tokens.nil?

          MilkTea::Parser.parse_collecting_errors(tokens: tokens, path: uri).ast
        rescue StandardError
          nil
        end

        def perf_logging?
          @perf_logging ||= !ENV.fetch('MILK_TEA_LSP_PERF', nil).to_s.empty?
        end

        def perf_verbose?
          @perf_verbose ||= ENV.fetch('MILK_TEA_LSP_PERF', nil).to_s == 'verbose'
        end

        def perf_breakdown_logging?(elapsed_ms_value)
          perf_logging? && (perf_verbose? || elapsed_ms_value > PERF_LOG_THRESHOLD_MS)
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def elapsed_ms(start_time)
          ((monotonic_time - start_time) * 1000).round(1)
        end

        def log_perf_breakdown(name, elapsed_ms_value, detail)
          return unless perf_breakdown_logging?(elapsed_ms_value)

          warn "[LSP perf] breakdown #{name} #{elapsed_ms_value}ms #{detail}"
        end

        def ast_for_content(uri, content)
          return get_ast(uri) if get_content(uri) == content

          MilkTea::Parser.parse(content, path: uri)
        rescue StandardError
          nil
        end

        def warm_document_facts(uri, content)
          ast = ast_for_content(uri, content)
          stats = {
            bytes: content.bytesize,
            lines: content.count("\n") + 1,
            eager_facts: false,
            facts_mode: nil,
            facts_ms: nil,
            skip_reason: nil,
            import_count: ast.respond_to?(:imports) ? ast.imports.length : 0,
            shared_module_cache_size: @shared_module_cache.length,
          }

          if background_document?(uri)
            stats[:skip_reason] = :background_document
            return stats
          end

          facts_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          facts_path = uri_to_path(uri)
          get_facts(uri)
          stats[:eager_facts] = true
          stats[:facts_mode] = facts_path && File.file?(facts_path) ? :module_loader : :memory
          stats[:facts_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - facts_start) * 1000).round(1)
          stats[:shared_module_cache_size] = @shared_module_cache.length
          stats
        end

        def compute_facts_for_content(uri, content)
          path = uri_to_path(uri)
          if path && File.file?(path)
            parse_result = MilkTea::Parser.parse_collecting_errors(content, path: uri)
            ast = parse_result.ast
            return nil unless ast

            effective_platform = effective_platform_for_path(path)
            ensure_root_platform_compatible!(path, effective_platform)
            loader = MilkTea::ModuleLoader.new(
              module_roots: module_roots_for_path(path),
              package_graph: package_graph_for_path(path),
              shared_cache: @shared_module_cache,
              source_overrides: file_backed_source_overrides,
              platform: effective_platform,
            )
            ast = with_inferred_module_name(ast, loader:, path:)
            import_resolution = loader.imported_modules_for_ast_collecting_errors(ast, importer_path: path)
            MilkTea::SemanticAnalyzer.tooling_snapshot(
              ast,
              imported_modules: import_resolution.modules,
              allow_missing_imports: true,
              path: path,
            ).facts
          else
            ast = MilkTea::Parser.parse(content, path: uri)
            MilkTea::SemanticAnalyzer.check(ast)
          end
        rescue MilkTea::LexError, MilkTea::SemanticError, ModuleLoadError
          nil
        end

          def analyze_document(uri)
            path = uri_to_path(uri)
            snapshot = if path && File.file?(path)
                         parse_result = MilkTea::Parser.parse_collecting_errors(get_content(uri), path: uri)
                         ast = parse_result.ast
                         return @last_good_tooling_snapshot_cache[uri] if ast.nil?

                         @ast_cache[uri] = ast

                         resolution = DependencyResolution.resolve(path, mode: @dependency_resolution_mode)
                         return nil unless resolution.ok?

                         effective_platform = effective_platform_for_path(path)
                         ensure_root_platform_compatible!(path, effective_platform)

                         loader = MilkTea::ModuleLoader.new(
                           module_roots: module_roots_for_path(path, locked: resolution.locked),
                           package_graph: package_graph_for_path(path, locked: resolution.locked),
                           shared_cache: @shared_module_cache,
                           source_overrides: file_backed_source_overrides,
                           platform: effective_platform,
                         )
                         ast = with_inferred_module_name(ast, loader:, path:)
                         import_resolution = loader.imported_modules_for_ast_collecting_errors(ast, importer_path: path)
                         MilkTea::SemanticAnalyzer.tooling_snapshot(
                           ast,
                           imported_modules: import_resolution.modules,
                           allow_missing_imports: true,
                           path: path,
                         )
                        else
                          ast = get_ast(uri)
                          return @last_good_tooling_snapshot_cache[uri] if ast.nil?

                          result = MilkTea::SemanticAnalyzer.check_collecting_errors(ast)
                          facts = result[:analysis]
                          MilkTea::SemanticAnalyzer::ToolingSnapshot.new(facts:, diagnostics: (Array(result[:errors]).map { |e| e.to_diagnostic(path: uri) } || []).freeze)
                        end
              if snapshot&.facts
                @last_good_tooling_snapshot_cache[uri] = snapshot
                @last_good_facts_cache[uri] = snapshot.facts
                @document_module_names[uri] = snapshot.facts.module_name
              end
            snapshot
          rescue MilkTea::LexError, MilkTea::SemanticError, ModuleLoadError, PackageLockError
            @last_good_tooling_snapshot_cache[uri]
          rescue StandardError => e
            warn "LSP sema error #{uri}: #{e.message}"
            @last_good_tooling_snapshot_cache[uri]
          end

        def package_graph_for_path(path, locked: false)
          PackageGraph.load(path, locked:)
        rescue PackageManifestError
          nil
        end

        def with_inferred_module_name(ast, loader:, path:)
          inferred_module_name = loader.send(:inferred_module_name_for_path, path)
          AST::SourceFile.new(
            module_name: AST::QualifiedName.new(inferred_module_name.split('.')),
            module_kind: ast.module_kind,
            imports: ast.imports,
            directives: ast.directives,
            declarations: ast.declarations,
            line: ast.line,
          )
        end

        def effective_platform_for_path(path)
          ModuleLoader.effective_platform_for_path(path, platform_override: @platform_override)
        end

        def ensure_root_platform_compatible!(path, effective_platform)
          return unless ModuleLoader.platform_suffix_for_path(path)

          ModuleLoader.resolve_source_path(path, platform: effective_platform, error_class: ModuleLoadError)
        end
      end
    end
  end
end
