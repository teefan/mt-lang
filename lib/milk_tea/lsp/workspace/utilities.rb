# frozen_string_literal: true

module MilkTea
  module LSP
    class Workspace
      module WorkspaceUtilities
        def shared_module_cache
          @shared_module_cache
        end

        def workspace_root_path=(path)
          @workspace_root_path = normalize_workspace_root_path(path)
        end

        def workspace_root_path
          @workspace_root_path
        end

        def dependency_resolution_mode=(mode)
          normalized = DependencyResolution.normalize_mode(mode)
          return if @dependency_resolution_mode == normalized

          @dependency_resolution_mode = normalized
          @facts_state_mutex.synchronize do
            @facts_cache_mutex.synchronize do
              @shared_module_cache.clear
              @facts_cache.clear
              @tooling_snapshot_cache.clear
              @diagnostics_cache.clear
              @last_good_facts_cache.clear
              @last_good_tooling_snapshot_cache.clear
              clear_dependency_index
            end
          end
        end

        def dependency_resolution_mode
          @dependency_resolution_mode
        end

        def platform_override=(platform)
          normalized = platform.nil? ? nil : ModuleLoader.normalize_platform_name(platform)
          return if @platform_override == normalized

          @platform_override = normalized
          @facts_state_mutex.synchronize do
            @facts_cache_mutex.synchronize do
              @shared_module_cache.clear
              @facts_cache.clear
              @tooling_snapshot_cache.clear
              @diagnostics_cache.clear
              @last_good_facts_cache.clear
              @last_good_tooling_snapshot_cache.clear
              clear_dependency_index
            end
          end
        end

        def platform_override
          @platform_override
        end

        def strict_current_root_diagnostics_enabled=(enabled)
          normalized = !!enabled
          return if @strict_current_root_diagnostics_enabled == normalized

          @strict_current_root_diagnostics_enabled = normalized
          @facts_state_mutex.synchronize do
            @facts_cache_mutex.synchronize do
              @diagnostics_cache.clear
            end
          end
        end

        def strict_current_root_diagnostics_enabled
          @strict_current_root_diagnostics_enabled
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

          idx = [lsp_char - 1, line_str.length - 1].min

          # Walk back past the hovered identifier to its dot
          idx -= 1 while idx >= 0 && line_str[idx] =~ /[A-Za-z0-9_]/
          return nil if idx < 0 || line_str[idx] != '.'

          segments = []
          left = idx - 1
          loop do
            # Skip brackets and their contents, then collect the identifier before them
            if line_str[left] == ']'
              depth = 1
              left -= 1
              while left >= 0 && depth > 0
                depth += 1 if line_str[left] == ']'
                depth -= 1 if line_str[left] == '['
                left -= 1 if depth > 0 && left > 0
              end
              left -= 1  # skip past opening bracket
            end

            # Walk back over identifier chars
            start = left
            start -= 1 while start >= 0 && line_str[start] =~ /[A-Za-z0-9_]/
            segments.unshift(line_str[start + 1..left]) if start < left

            break unless start >= 0 && line_str[start] == '.'

            left = start - 1
          end

          segments.any? ? segments.join('.') : nil
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
                   when :let     then 'variable'
                   when :var     then 'variable'
                   when :event   then 'variable'
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

            docs << {
              line: index + 1,
              text: stripped.sub(/\A##\s?/, ''),
            }
            index -= 1
          end

          return nil if docs.empty?

          build_doc_comment_data(docs.reverse)
        end

        def build_doc_comment_data(lines)
          raw_lines = lines.map { |entry| entry[:text].to_s }
          raw_markdown = raw_lines.join("\n")

          tags = {
            params: [],
            returns: nil,
            throws: [],
            see: [],
          }
          tag_errors = []
          body_lines = []

          lines.each do |entry|
            line_text = entry[:text].to_s
            match = line_text.match(DOC_TAG_PATTERN)
            unless match
              body_lines << line_text
              next
            end

            tag_name = match[1].to_s.downcase
            payload = match[2].to_s.strip

            case tag_name
            when 'param'
              if payload.empty?
                tag_errors << {
                  line: entry[:line],
                  message: 'doc tag @param requires a parameter name',
                }
                next
              end

              name_match = payload.match(/\A([A-Za-z_][A-Za-z0-9_]*)(?:\s+(.*))?\z/)
              unless name_match
                tag_errors << {
                  line: entry[:line],
                  message: 'doc tag @param has an invalid parameter name',
                }
                next
              end

              tags[:params] << {
                name: name_match[1],
                text: name_match[2].to_s.strip,
                line: entry[:line],
              }
            when 'return', 'returns'
              tags[:returns] = {
                text: payload,
                line: entry[:line],
              }
            when 'throws', 'throw'
              tags[:throws] << {
                text: payload,
                line: entry[:line],
              }
            when 'see'
              tags[:see] << {
                text: payload,
                line: entry[:line],
              }
            else
              tag_errors << {
                line: entry[:line],
                message: "unknown doc tag @#{tag_name}",
              }
            end
          end

          body_markdown = body_lines.join("\n").strip
          summary_lines = body_markdown.split("\n").slice_before { |line| line.strip.empty? }.first || []
          summary = summary_lines.join("\n").strip
          summary = nil if summary.empty?

          {
            raw_markdown: raw_markdown,
            summary: summary,
            body_markdown: body_markdown,
            tags: tags,
            tag_errors: tag_errors,
          }
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
      end
    end
  end
end
