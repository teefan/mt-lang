# frozen_string_literal: true

require 'cgi/escape'
require 'uri'

module MilkTea
  module LSP
    # Manages open documents, AST cache, token cache, semantic analysis cache, and symbol index.
    # Supports incremental document edits and workspace-wide indexing.
    class Workspace
      # Token types that introduce a named definition, in order of precedence
      DEFINITION_KEYWORDS = %i[def struct union enum flags variant type const var methods opaque].freeze

      def initialize
        @open_documents = {}   # uri -> content String from didOpen/didChange
        @indexed_documents = {} # uri -> content String loaded from disk index
        @tokens_cache = {}   # uri -> [Token]
        @ast_cache = {}      # uri -> AST::SourceFile (nil on parse failure)
        @analysis_cache = {} # uri -> Sema::Analysis (nil on analysis failure)
        @symbols_cache = {}  # uri -> [{name, kind, line, column}]
      end

      # ── Document lifecycle ──────────────────────────────────────────────────

      def open_document(uri, content)
        @open_documents[uri] = content
        invalidate_cache(uri)
      end

      def close_document(uri)
        # Keep indexed snapshot available for workspace-level features.
        @open_documents.delete(uri)
        invalidate_cache(uri)
      end

      def update_document(uri, content)
        @open_documents[uri] = content
        invalidate_cache(uri)
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
          new_content = content[0...start_off] + change['text'].to_s + content[end_off..]
        else
          # Full-document fallback within an incremental-sync session
          new_content = change['text'].to_s
        end

        @open_documents[uri] = new_content
        invalidate_cache(uri)
      end

      # Index all .mt files under root_uri so they are available for workspace-wide queries.
      def index_workspace(root_uri)
        root_path = uri_to_path(root_uri)
        return unless root_path && File.directory?(root_path)

        Dir.glob(File.join(root_path, '**', '*.mt')).each do |path|
          file_uri = path_to_uri(path)
          @indexed_documents[file_uri] ||= begin
            File.read(path)
          rescue StandardError
            nil
          end
        end
      end

      # ── Accessors ───────────────────────────────────────────────────────────

      def get_content(uri)
        @open_documents[uri] || @indexed_documents[uri] || ''
      end

      def get_tokens(uri)
        @tokens_cache[uri] ||= lex_document(uri)
      end

      def get_ast(uri)
        @ast_cache[uri] ||= parse_document(uri)
      end

      def get_analysis(uri)
        @analysis_cache[uri] ||= analyze_document(uri)
      end

      def get_symbols(uri)
        @symbols_cache[uri] ||= extract_symbols_from_tokens(uri)
      end

      def all_documents
        (@indexed_documents.keys + @open_documents.keys).uniq
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

          tok.line == target_line &&
            tok.column <= target_char &&
            (tok.column + tok.lexeme.length - 1) >= target_char
        end
      end

      # Find the name identifier token immediately after a definition keyword
      # (def, struct, union, enum, flags, variant, type, const, var) for the given name.
      # Returns the identifier Token, or nil if not found.
      def find_definition_token(uri, name)
        tokens = get_tokens(uri)
        return nil if tokens.nil?

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
        @analysis_cache.delete(uri)
        @symbols_cache.delete(uri)
      end

      # ── Compilation helpers ─────────────────────────────────────────────────

      def lex_document(uri)
        content = get_content(uri)
        return nil if content.empty?

        MilkTea::Lexer.lex(content, path: uri)
      rescue StandardError => e
        warn "LSP lex error #{uri}: #{e.message}"
        nil
      end

      def parse_document(uri)
        tokens = get_tokens(uri)
        return nil if tokens.nil?

        MilkTea::Parser.parse(tokens: tokens, path: uri)
      rescue StandardError => e
        warn "LSP parse error #{uri}: #{e.message}"
        nil
      end

      def analyze_document(uri)
        ast = get_ast(uri)
        return nil if ast.nil?

        MilkTea::Sema.check(ast)
      rescue StandardError => e
        warn "LSP sema error #{uri}: #{e.message}"
        nil
      end

      # ── Symbol extraction (token-based, no AST position requirement) ────────

      def extract_symbols_from_tokens(uri)
        tokens = get_tokens(uri)
        return [] if tokens.nil?

        symbols = []
        tokens.each_cons(2) do |kw_tok, id_tok|
          next unless DEFINITION_KEYWORDS.include?(kw_tok.type)
          next unless id_tok.type == :identifier

          kind = case kw_tok.type
                 when :def     then 'function'
                 when :struct  then 'struct'
                 when :union   then 'union'
                 when :enum    then 'enum'
                 when :flags   then 'enum'
                 when :variant then 'struct'
                 when :type    then 'type_alias'
                 when :const   then 'constant'
                 when :var     then 'variable'
                 when :methods then 'struct'
                 when :opaque  then 'struct'
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

      # ── Offset utilities ────────────────────────────────────────────────────

      # Convert a 0-based LSP (line, character) pair into a byte offset.
      def line_char_to_offset(content, line, char)
        lines = content.split("\n", -1)
        clamped_line = [[line.to_i, 0].max, lines.length - 1].min

        preceding = if clamped_line.zero?
                      ''
                    else
                      lines[0...clamped_line].join("\n") + "\n"
                    end

        line_text = lines[clamped_line] || ''
        chars = line_text.each_char.to_a
        clamped_char = [[char.to_i, 0].max, chars.length].min
        within_line = chars[0...clamped_char].join

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
    end
  end
end
