# frozen_string_literal: true

require 'cgi/escape'
require 'set'
require 'thread'
require 'uri'

module MilkTea
  module LSP
    # Manages open documents, AST cache, token cache, semantic analysis cache, and symbol index.
    # Supports incremental document edits and workspace-wide indexing.
    class Workspace
      DOCUMENT_SOURCES = %w[active-editor visible-editor background-document].freeze

      # Token types that introduce a named definition, in order of precedence
      DEFINITION_KEYWORDS = %i[function struct union enum flags variant type const var let extending opaque interface].freeze
      DOC_COMMENT_PREFIX = '##'
      DEFINITION_LINE_PREFIX = /^(?:\s)*(?:(?:public|foreign|external)\s+)*(?:function|struct|union|enum|flags|variant|type|const|var|let|extending|opaque|interface)\s+/m
      DEFINITION_NAME_REGEX = /^\s*(?:(?:public|foreign|external)\s+)*(?:function|struct|union|enum|flags|variant|type|const|var|let|extending|opaque|interface)\s+([A-Za-z_][A-Za-z0-9_]*)\b/

      def initialize(error_output: nil)
        @error_output = error_output
        @dependency_resolution_mode = :auto
        @platform_override = nil
        @open_documents = {}   # uri -> content String from didOpen/didChange
        @indexed_documents = {} # uri -> content String loaded from disk index
        @document_sources = {} # uri -> source string from the editor client
        @document_state_mutex = Mutex.new
        @tokens_cache = {}   # uri -> [Token]
        @ast_cache = {}      # uri -> AST::SourceFile (nil on parse failure)
        @analysis_cache = {} # uri -> Sema::Analysis (nil on analysis failure)
        @symbols_cache = {}  # uri -> [{name, kind, line, column}]
        @doc_comments_cache = {} # uri -> {"line:column" => markdown_doc}
        @last_good_analysis_cache = {} # uri -> last Sema::Analysis that succeeded
        @shared_module_cache = {}
        @analysis_state_mutex = Mutex.new
        # Diagnostics cache: uri -> { content_hash: Integer, diagnostics: Array }
        # Avoids re-running Sema.check_collecting_errors when content is unchanged.
        @diagnostics_cache = {}
        # Definition index: name -> { uri:, token: } — built lazily from symbols cache.
        # Caches known matching definitions without forcing a full-workspace index
        # build on the first global lookup.
        @definition_index = {} # name -> [{ uri:, token: Token }]
        @definition_miss_cache = Set.new
        @definition_candidate_uris = Hash.new { |hash, key| hash[key] = Set.new }
        @definition_names_by_uri = {}
        @definition_cache_mutex = Mutex.new
        @definition_warmup_queue = Queue.new
        @definition_warmup_enqueued = Set.new
        @definition_warmup_thread = nil
      end

      def shared_module_cache
        @shared_module_cache
      end

      def dependency_resolution_mode=(mode)
        normalized = DependencyResolution.normalize_mode(mode)
        return if @dependency_resolution_mode == normalized

        @dependency_resolution_mode = normalized
        @analysis_state_mutex.synchronize do
          @shared_module_cache.clear
          @analysis_cache.clear
          @diagnostics_cache.clear
          @last_good_analysis_cache.clear
        end
      end

      def dependency_resolution_mode
        @dependency_resolution_mode
      end

      def platform_override=(platform)
        normalized = platform.nil? ? nil : ModuleLoader.normalize_platform_name(platform)
        return if @platform_override == normalized

        @platform_override = normalized
        @analysis_state_mutex.synchronize do
          @shared_module_cache.clear
          @analysis_cache.clear
          @diagnostics_cache.clear
          @last_good_analysis_cache.clear
        end
      end

      def platform_override
        @platform_override
      end

      def set_document_source(uri, source)
        normalized = source.to_s
        raise ArgumentError, "invalid document source #{source.inspect}" unless DOCUMENT_SOURCES.include?(normalized)

        @document_state_mutex.synchronize do
          previous = @document_sources[uri]
          @document_sources[uri] = normalized
          previous
        end
      end

      def document_source(uri)
        @document_state_mutex.synchronize do
          @document_sources[uri]
        end
      end

      def background_document?(uri)
        @document_state_mutex.synchronize do
          @document_sources[uri] == 'background-document'
        end
      end

      # Return cached diagnostics for +uri+, re-collecting only when content changes.
      def collect_diagnostics(uri)
        content = get_content(uri)
        hash = content.hash
        @analysis_state_mutex.synchronize do
          entry = @diagnostics_cache[uri]
          return entry[:diagnostics] if entry && entry[:content_hash] == hash

          result = Diagnostics.collect(
            uri,
            content,
            shared_module_cache: @shared_module_cache,
            source_overrides: file_backed_source_overrides,
            dependency_resolution_mode: @dependency_resolution_mode,
            platform_override: @platform_override,
          )
          diagnostics = result[:diagnostics]
          analysis = result[:analysis]
          @analysis_cache[uri] = analysis if analysis
          @last_good_analysis_cache[uri] = analysis if analysis
          @diagnostics_cache[uri] = { content_hash: hash, diagnostics: diagnostics }
          diagnostics
        end
      rescue StandardError => e
        log_error("LSP diagnostics error #{uri}: #{e.message}")
        []
      end

      # ── Document lifecycle ──────────────────────────────────────────────────

      def open_document(uri, content)
        @document_state_mutex.synchronize do
          @open_documents[uri] = content
        end
        invalidate_cache(uri)
        enqueue_definition_warmup(uri) unless background_document?(uri)
        warm_document_analysis(uri, content)
      end

      def close_document(uri)
        # Keep indexed snapshot available for workspace-level features.
        @document_state_mutex.synchronize do
          @open_documents.delete(uri)
          @document_sources.delete(uri)
        end
        @last_good_analysis_cache.delete(uri)
        invalidate_cache(uri)
      end

      def update_document(uri, content)
        @document_state_mutex.synchronize do
          @open_documents[uri] = content
        end
        invalidate_cache(uri)
        enqueue_definition_warmup(uri) unless background_document?(uri)
        warm_document_analysis(uri, content)
      end

      # Apply one incremental change (LSP textDocumentSync == 2).
      # change is a Hash with optional 'range' and mandatory 'text'.
      def apply_incremental_change(uri, change)
        content = get_content(uri)

        if change['range']
          start_pos = change['range']['start']
          end_pos   = change['range']['end']
          start_off = line_char_to_offset(content, start_pos['line'], start_pos['character'])
          end_off   = line_char_to_offset(content, end_pos['line'],   end_pos['character'])
          prefix = content.byteslice(0, start_off).to_s
          suffix = content.byteslice(end_off..).to_s
          new_content = prefix + change['text'].to_s + suffix
        else
          # Full-document fallback within an incremental-sync session
          new_content = change['text'].to_s
        end

        @document_state_mutex.synchronize do
          @open_documents[uri] = new_content
        end
        invalidate_cache(uri)
        enqueue_definition_warmup(uri) unless background_document?(uri)
      end

      # Index all .mt files under root_uri so they are available for workspace-wide queries.
      def index_workspace(root_uri)
        root_path = uri_to_path(root_uri)
        return unless root_path && File.directory?(root_path)

        Dir.glob(File.join(root_path, '**', '*.mt')).each do |path|
          file_uri = path_to_uri(path)
          @document_state_mutex.synchronize do
            @indexed_documents[file_uri] ||= begin
              File.read(path)
            rescue StandardError
              nil
            end
          end
        end
      end

      def shutdown
        stop_definition_warmup
      end

      # ── Accessors ───────────────────────────────────────────────────────────

      def get_content(uri)
        @document_state_mutex.synchronize do
          @open_documents[uri] || @indexed_documents[uri] || ''
        end
      end

      def get_tokens(uri)
        @tokens_cache[uri] ||= lex_document(uri)
      end

      def get_ast(uri)
        @ast_cache[uri] ||= parse_document(uri)
      end

      def get_analysis(uri)
        @analysis_state_mutex.synchronize do
          @analysis_cache[uri] ||= analyze_document(uri)
        end
      end

      def get_symbols(uri)
        @symbols_cache[uri] ||= extract_symbols_from_tokens(uri)
      end

      def doc_comment_for_definition(uri, token)
        return nil unless token

        docs_by_location = @doc_comments_cache[uri] ||= extract_doc_comments_for_definitions(uri)
        docs_by_location[doc_comment_key(token.line, token.column)]
      end

      def position_to_offset(uri, line, char)
        content = get_content(uri)
        line_char_to_offset(content, line, char)
      end

      def all_documents
        @document_state_mutex.synchronize do
          (@indexed_documents.keys + @open_documents.keys).uniq
        end
      end

      # Return all identifier token locations matching +name+ across all known documents.
      # Each result is { uri:, range: { start: { line:, character: }, end: ... } }.
      def find_all_references(name)
        results = []
        all_documents.each do |doc_uri|
          toks = get_tokens(doc_uri)
          next unless toks

          toks.each do |tok|
            next unless tok.type == :identifier && tok.lexeme == name

            results << {
              uri:   doc_uri,
              range: {
                start: { line: tok.line - 1, character: tok.column - 1 },
                end:   { line: tok.line - 1, character: tok.column - 1 + name.length }
              }
            }
          end
        end
        results
      end

      # Find a definition token across the whole workspace, preferring +preferred_uri+.
      # Returns { uri:, token: } or nil.
      # Uses demand-driven name lookup to avoid cold full-workspace indexing.
      def find_definition_token_global(name, preferred_uri: nil, before_line: nil, before_char: nil)
        # Check preferred_uri first without going through the index.
        if preferred_uri
          token = find_definition_token(preferred_uri, name, before_line:, before_char:)
          return { uri: preferred_uri, token: token } if token
        end

        entries = nil
        miss = false
        @definition_cache_mutex.synchronize do
          entries = @definition_index[name]&.dup
          miss = @definition_miss_cache.include?(name)
        end
        if entries
          entries.each do |entry|
            next if entry[:uri] == preferred_uri

            return entry
          end
        end

        return nil if miss

        candidate_definition_uris(name, exclude_uri: preferred_uri).each do |doc_uri|
          token = find_definition_token(doc_uri, name)
          next unless token

          entry = { uri: doc_uri, token: token }
          cache_definition_entry(name, entry)
          return entry
        end

        @definition_cache_mutex.synchronize do
          @definition_miss_cache << name
        end
        nil
      end

      # Apply a workspace/didChangeWatchedFiles change to the indexed snapshot.
      # Open documents are source-of-truth and are left untouched.
      def apply_watched_file_change(uri, change_type)
        return [] if @document_state_mutex.synchronize { @open_documents.key?(uri) }

        if change_type.to_i == 3 # Deleted
          @document_state_mutex.synchronize do
            @indexed_documents.delete(uri)
          end
          invalidate_cache(uri)
          return refresh_import_dependent_caches(changed_uri: uri)
        end

        path = uri_to_path(uri)
        return [] unless path && File.file?(path)

        @document_state_mutex.synchronize do
          @indexed_documents[uri] = File.read(path)
        end
        invalidate_cache(uri)
        enqueue_definition_warmup(uri)
        refresh_import_dependent_caches(changed_uri: uri)
      rescue StandardError => e
        warn "LSP watched-file update error #{uri}: #{e.message}"
        []
      end

      def refresh_open_document_dependency_caches(changed_uri)
        path = uri_to_path(changed_uri)
        return [] unless path && File.file?(path)

        refresh_import_dependent_caches(changed_uri: changed_uri)
      end

      # Scan text up to the cursor to find the innermost open function call context.
      # Returns { name:, active_parameter: } or nil if not inside a call.
      def find_call_context(uri, lsp_line, lsp_char)
        content = get_content(uri)
        return nil if content.empty?

        lines = content.split("\n", -1)
        cursor_line = lines[lsp_line] || ''
        prefix = lsp_line.positive? ? lines[0...lsp_line].join("\n") + "\n" : ''
        text = prefix + cursor_line[0...lsp_char]

        depth = 0
        active_param = 0
        i = text.length - 1
        paren_pos = nil

        while i >= 0
          ch = text[i]
          case ch
          when ')', ']'
            depth += 1
          when '['
            return nil if depth.zero?
            depth -= 1
          when '('
            if depth.zero?
              paren_pos = i
              break
            end
            depth -= 1
          when ','
            active_param += 1 if depth.zero?
          end
          i -= 1
        end

        return nil unless paren_pos

        # Find identifier immediately before the '('
        j = paren_pos - 1
        j -= 1 while j >= 0 && (text[j] == ' ' || text[j] == "\t")
        return nil if j < 0 || text[j] !~ /[A-Za-z0-9_]/

        end_j = j
        j -= 1 while j > 0 && text[j - 1] =~ /[A-Za-z0-9_]/
        name = text[j..end_j]
        return nil if name.empty?

        { name: name, active_parameter: active_param }
      rescue StandardError => e
        warn "LSP call context error #{uri}: #{e.message}"
        nil
      end

      # ── Position helpers ────────────────────────────────────────────────────

      # Find the identifier/keyword token under the cursor.
      # lsp_line and lsp_character are 0-based (LSP convention).
      def find_token_at(uri, lsp_line, lsp_character)
        tokens = get_tokens(uri)
        return nil if tokens.nil?

        # Tokens use 1-based line/column
        target_line = lsp_line + 1
        target_char = lsp_character + 1

        tokens.find do |tok|
          next false if [:newline, :indent, :dedent, :eof].include?(tok.type)

          token_contains_position?(tok, target_line, target_char)
        end
      end

      def token_contains_position?(token, target_line, target_char)
        segments = token.lexeme.split("\n", -1)
        end_line = token.line + segments.length - 1
        return false if target_line < token.line || target_line > end_line

        if segments.length == 1
          return token.column <= target_char && target_char < (token.column + segments.first.length)
        end

        if target_line == token.line
          return token.column <= target_char && target_char <= (token.column + segments.first.length - 1)
        end

        target_char <= segments.fetch(target_line - token.line).length
      end

      # Returns the receiver name before '.' if the cursor is in a dot-access
      # context, e.g. for "vec.len|" returns "vec". Returns nil otherwise.
      # lsp_char is the 0-based cursor character position (LSP convention).
      def find_dot_receiver(uri, lsp_line, lsp_char)
        receiver_path = find_dot_receiver_path(uri, lsp_line, lsp_char)
        return nil unless receiver_path

        receiver_path.split('.').last
      rescue StandardError
        nil
      end

      def find_dot_receiver_path(uri, lsp_line, lsp_char)
        content = get_content(uri)
        lines = content.split("\n", -1)
        line_str = lines[lsp_line] || ''

        # Walk back over any partially-typed identifier after the dot.
        idx = [lsp_char - 1, line_str.length - 1].min
        idx -= 1 while idx >= 0 && line_str[idx] =~ /[A-Za-z0-9_]/
        return nil if idx < 0 || line_str[idx] != '.'

        dot_idx = idx
        receiver_match = line_str[0...dot_idx].match(/([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)\z/)
        receiver_match&.[](1)
      rescue StandardError
        nil
      end

      # Find the name identifier token immediately after a definition keyword
      # (def, struct, union, enum, flags, variant, type, const, var) for the given name.
      # Returns the identifier Token, or nil if not found.
      def find_definition_token(uri, name, before_line: nil, before_char: nil)
        tokens = get_tokens(uri)
        return nil if tokens.nil?

        nearest = nil
        tokens.each_cons(2) do |kw_tok, id_tok|
          next unless DEFINITION_KEYWORDS.include?(kw_tok.type)
          next unless id_tok.type == :identifier && id_tok.lexeme == name

          if before_line
            next if id_tok.line > before_line
            next if id_tok.line == before_line && before_char && id_tok.column >= before_char
          end

          if nearest.nil? || id_tok.line > nearest.line || (id_tok.line == nearest.line && id_tok.column > nearest.column)
            nearest = id_tok
          end
        end

        return nearest if nearest

        tokens.each_cons(2) do |kw_tok, id_tok|
          next unless DEFINITION_KEYWORDS.include?(kw_tok.type)
          next unless id_tok.type == :identifier && id_tok.lexeme == name

          return id_tok
        end
        nil
      end

      private

      # ── Cache management ────────────────────────────────────────────────────

      def invalidate_cache(uri)
        @tokens_cache.delete(uri)
        @ast_cache.delete(uri)
        @symbols_cache.delete(uri)
        @doc_comments_cache.delete(uri)
        @analysis_state_mutex.synchronize do
          @analysis_cache.delete(uri)
          @diagnostics_cache.delete(uri)
        end
        @definition_cache_mutex.synchronize do
          @definition_index.each_value { |entries| entries.delete_if { |e| e[:uri] == uri } }
          @definition_index.delete_if { |_k, v| v.empty? }
          remove_definition_name_candidates_for_uri(uri)
          @definition_miss_cache.clear
        end
      end

      def refresh_import_dependent_caches(changed_uri: nil)
        @analysis_state_mutex.synchronize do
          preserved_last_good_analysis = changed_uri ? @last_good_analysis_cache[changed_uri] : nil
          @shared_module_cache.clear
          @analysis_cache.clear
          @diagnostics_cache.clear
          @last_good_analysis_cache.clear
          @last_good_analysis_cache[changed_uri] = preserved_last_good_analysis if changed_uri && preserved_last_good_analysis
        end
        @document_state_mutex.synchronize do
          @open_documents.keys.reject { |open_uri| open_uri == changed_uri }
        end
      end

      # ── Compilation helpers ─────────────────────────────────────────────────

      def lex_document(uri)
        content = get_content(uri)
        return nil if content.empty?

        MilkTea::Lexer.lex(content, path: uri)
      rescue StandardError => e
        log_error("LSP lex error #{uri}: #{e.message}")
        nil
      end

      def parse_document(uri)
        tokens = get_tokens(uri)
        return nil if tokens.nil?

        MilkTea::Parser.parse(tokens: tokens, path: uri)
      rescue StandardError => e
        log_error("LSP parse error #{uri}: #{e.message}")
        nil
      end

      private def log_error(message)
        return unless @error_output

        @error_output.puts(message)
      rescue StandardError
        nil
      end

      def ast_for_content(uri, content)
        return get_ast(uri) if get_content(uri) == content

        MilkTea::Parser.parse(content, path: uri)
      rescue StandardError
        nil
      end

      def warm_document_analysis(uri, content)
        ast = ast_for_content(uri, content)
        stats = {
          bytes: content.bytesize,
          lines: content.count("\n") + 1,
          eager_analysis: false,
          analysis_mode: nil,
          analysis_ms: nil,
          skip_reason: nil,
          import_count: ast.respond_to?(:imports) ? ast.imports.length : 0,
          shared_module_cache_size: @shared_module_cache.length,
        }

        analysis_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        analysis_path = uri_to_path(uri)
        get_analysis(uri)
        stats[:eager_analysis] = true
        stats[:analysis_mode] = analysis_path && File.file?(analysis_path) ? :module_loader : :memory
        stats[:analysis_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - analysis_start) * 1000).round(1)
        stats[:shared_module_cache_size] = @shared_module_cache.length
        stats
      end

      def compute_analysis_for_content(uri, content)
        path = uri_to_path(uri)
        if path && File.file?(path)
          parse_result = MilkTea::Parser.parse_collecting_errors(content, path: uri)
          ast = parse_result.ast
          return nil unless ast

          effective_platform = effective_platform_for_path(path)
          ensure_root_platform_compatible!(path, effective_platform)
          loader = MilkTea::ModuleLoader.new(
            module_roots: MilkTea::ModuleRoots.roots_for_path(path),
            package_graph: package_graph_for_path(path),
            shared_cache: @shared_module_cache,
            source_overrides: file_backed_source_overrides,
            platform: effective_platform,
          )
          ast = with_inferred_module_name(ast, loader:, path:)
          import_resolution = loader.imported_modules_for_ast_collecting_errors(ast, importer_path: path)
          MilkTea::Sema.check_collecting_errors(
            ast,
            imported_modules: import_resolution.modules,
            allow_missing_imports: true,
          )[:analysis]
        else
          ast = MilkTea::Parser.parse(content, path: uri)
          MilkTea::Sema.check(ast)
        end
      rescue MilkTea::LexError, MilkTea::SemaError, ModuleLoadError
        nil
      end

      def analyze_document(uri)
        path = uri_to_path(uri)
        result = if path && File.file?(path)
                   parse_result = MilkTea::Parser.parse_collecting_errors(get_content(uri), path: uri)
                   ast = parse_result.ast
                   # Fall back to the last successful analysis so completions/hover still
                   # work when the user is mid-edit and the file does not parse/check.
                   return @last_good_analysis_cache[uri] if ast.nil?

                   resolution = DependencyResolution.resolve(path, mode: @dependency_resolution_mode)
                   return nil unless resolution.ok?
                   effective_platform = effective_platform_for_path(path)
                   ensure_root_platform_compatible!(path, effective_platform)

                   loader = MilkTea::ModuleLoader.new(
                     module_roots: MilkTea::ModuleRoots.roots_for_path(path, locked: resolution.locked),
                     package_graph: package_graph_for_path(path, locked: resolution.locked),
                     shared_cache: @shared_module_cache,
                     source_overrides: file_backed_source_overrides,
                     platform: effective_platform,
                   )
                   ast = with_inferred_module_name(ast, loader:, path:)
                   import_resolution = loader.imported_modules_for_ast_collecting_errors(ast, importer_path: path)
                   MilkTea::Sema.check_collecting_errors(
                     ast,
                     imported_modules: import_resolution.modules,
                     allow_missing_imports: true,
                   )[:analysis]
                 else
                   ast = get_ast(uri)
                   return @last_good_analysis_cache[uri] if ast.nil?

                   MilkTea::Sema.check(ast)
                 end
        @last_good_analysis_cache[uri] = result
        result
      rescue MilkTea::LexError, MilkTea::SemaError, ModuleLoadError, PackageLockError
        @last_good_analysis_cache[uri]
      rescue StandardError => e
        warn "LSP sema error #{uri}: #{e.message}"
        @last_good_analysis_cache[uri]
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

      public

      def open_document_uris
        @document_state_mutex.synchronize do
          @open_documents.keys.dup
        end
      end

      private

      # ── Symbol extraction (token-based, no AST position requirement) ────────

      def extract_symbols_from_tokens(uri)
        tokens = get_tokens(uri)
        return [] if tokens.nil?

        symbols = []
        tokens.each_cons(2) do |kw_tok, id_tok|
          next unless DEFINITION_KEYWORDS.include?(kw_tok.type)
          next unless id_tok.type == :identifier

          kind = case kw_tok.type
                 when :function then 'function'
                 when :struct  then 'struct'
                 when :union   then 'union'
                 when :enum    then 'enum'
                 when :flags   then 'enum'
                 when :variant then 'struct'
                 when :type    then 'type_alias'
                 when :const   then 'constant'
                 when :var     then 'variable'
                 when :extending then 'struct'
                 when :opaque  then 'struct'
               when :interface then 'interface'
                 end

          symbols << {
            name:   id_tok.lexeme,
            kind:   kind,
            line:   id_tok.line,
            column: id_tok.column
          }
        end
        symbols
      end

      def file_backed_source_overrides
        open_documents = @document_state_mutex.synchronize do
          @open_documents.dup
        end

        open_documents.each_with_object({}) do |(uri, content), overrides|
          path = uri_to_path(uri)
          next unless path && File.file?(path)

          use_override = true
          begin
            use_override = File.read(path) != content
          rescue StandardError
            use_override = true
          end

          overrides[File.expand_path(path)] = content if use_override
        end
      end

      def extract_doc_comments_for_definitions(uri)
        content = get_content(uri)
        return {} if content.empty?

        tokens = get_tokens(uri)
        return {} if tokens.nil?

        lines = content.split("\n", -1)
        docs_by_location = {}

        tokens.each_cons(2) do |kw_tok, id_tok|
          next unless DEFINITION_KEYWORDS.include?(kw_tok.type)
          next unless id_tok.type == :identifier

          docs = extract_doc_comment_for_line(lines, id_tok.line - 1)
          next unless docs

          docs_by_location[doc_comment_key(id_tok.line, id_tok.column)] = docs
        end

        docs_by_location
      end

      def extract_doc_comment_for_line(lines, declaration_line)
        index = declaration_line - 1
        return nil if index.negative?

        docs = []
        while index >= 0
          stripped = lines[index].to_s.strip
          break if stripped.empty?
          break unless stripped.start_with?(DOC_COMMENT_PREFIX)

          docs << stripped.sub(/\A##\s?/, '')
          index -= 1
        end

        return nil if docs.empty?

        docs.reverse.join("\n")
      end

      def doc_comment_key(line, column)
        "#{line}:#{column}"
      end

      # ── Offset utilities ────────────────────────────────────────────────────

      # Convert a 0-based LSP (line, character) pair into a byte offset.
      # LSP positions use UTF-16 code units for +character+.
      def line_char_to_offset(content, line, char)
        lines = content.split("\n", -1)
        clamped_line = [[line.to_i, 0].max, lines.length - 1].min

        preceding = if clamped_line.zero?
                      ''
                    else
                      lines[0...clamped_line].join("\n") + "\n"
                    end

        line_text = lines[clamped_line] || ''
        target_units = [char.to_i, 0].max

        utf16_units_seen = 0
        byte_index = 0
        line_text.each_char do |ch|
          codepoint = ch.ord
          units = codepoint > 0xFFFF ? 2 : 1
          break if utf16_units_seen + units > target_units

          utf16_units_seen += units
          byte_index += ch.bytesize
        end

        within_line = line_text.byteslice(0, byte_index).to_s

        (preceding + within_line).bytesize
      end

      def uri_to_path(uri)
        parsed = URI.parse(uri)
        return nil unless parsed.scheme == 'file'

        CGI.unescape(parsed.path)
      rescue URI::InvalidURIError
        nil
      end

      def path_to_uri(path)
        escaped_path = path.split('/').map { |seg| CGI.escape(seg).gsub('+', '%20') }.join('/')
        "file://#{escaped_path}"
      end

      def candidate_definition_uris(name, exclude_uri: nil)
        matcher = definition_line_matcher(name)
        open_uris, indexed_uris = @document_state_mutex.synchronize do
          [@open_documents.keys, @indexed_documents.keys]
        end

        ordered_uris = (open_uris + indexed_uris).uniq
        warmed_candidates = nil
        warmed_uris = nil
        @definition_cache_mutex.synchronize do
          warmed_candidates = @definition_candidate_uris[name].dup
          warmed_uris = @definition_names_by_uri.keys.to_set
        end

        matches = warmed_candidates.to_a.filter_map do |doc_uri|
          next if doc_uri == exclude_uri

          doc_uri
        end

        ordered_uris.each do |doc_uri|
          next if doc_uri == exclude_uri
          next if warmed_uris.include?(doc_uri)

          content = get_content(doc_uri)
          next if content.empty?
          next unless content.match?(matcher)

          warm_definition_candidates_for_uri(doc_uri, content)
          matches << doc_uri
        end

        matches.uniq
      end

      def definition_line_matcher(name)
        /#{DEFINITION_LINE_PREFIX}#{Regexp.escape(name)}\b/
      end

      def cache_definition_entry(name, entry)
        @definition_cache_mutex.synchronize do
          entries = (@definition_index[name] ||= [])
          return if entries.any? { |existing| existing[:uri] == entry[:uri] && existing[:token].line == entry[:token].line && existing[:token].column == entry[:token].column }

          entries << entry
        end
      end

      def start_definition_warmup
        return if @definition_warmup_thread&.alive?

        @definition_warmup_thread = Thread.new do
          Thread.current.name = 'mt-lsp-def-warmup' if Thread.current.respond_to?(:name=)

          loop do
            uri = @definition_warmup_queue.pop
            break if uri == :__stop__

            content = get_content(uri)
            warm_definition_candidates_for_uri(uri, content)
          end
        rescue StandardError => e
          warn "LSP definition warmup error: #{e.message}"
        end
      end

      def stop_definition_warmup
        worker = @definition_warmup_thread
        return unless worker

        @definition_warmup_queue << :__stop__
        worker.join(0.25)
        @definition_warmup_thread = nil
      rescue StandardError => e
        warn "LSP definition warmup shutdown error: #{e.message}"
      end

      def enqueue_definition_warmup(uri)
        return if uri.nil?

        start_definition_warmup unless @definition_warmup_thread&.alive?

        should_enqueue = false
        @definition_cache_mutex.synchronize do
          unless @definition_warmup_enqueued.include?(uri)
            @definition_warmup_enqueued << uri
            should_enqueue = true
          end
        end

        @definition_warmup_queue << uri if should_enqueue
      end

      def warm_definition_candidates_for_uri(uri, content)
        names = extract_definition_names(content)

        @definition_cache_mutex.synchronize do
          remove_definition_name_candidates_for_uri(uri)
          @definition_names_by_uri[uri] = names
          names.each { |name| @definition_candidate_uris[name] << uri }
          @definition_warmup_enqueued.delete(uri)
          @definition_miss_cache.clear unless names.empty?
        end
      end

      def remove_definition_name_candidates_for_uri(uri)
        names = @definition_names_by_uri.delete(uri)
        return unless names

        names.each do |name|
          next unless @definition_candidate_uris.key?(name)

          @definition_candidate_uris[name].delete(uri)
          @definition_candidate_uris.delete(name) if @definition_candidate_uris[name].empty?
        end
      end

      def extract_definition_names(content)
        return Set.new if content.empty?

        names = Set.new
        content.each_line do |line|
          match = line.match(DEFINITION_NAME_REGEX)
          names << match[1] if match
        end
        names
      end
    end
  end
end
