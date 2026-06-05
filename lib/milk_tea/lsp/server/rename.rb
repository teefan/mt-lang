# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerRename
        private

      def handle_prepare_rename(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless name_like_token?(token)

        { range: token_to_range(token), placeholder: token.lexeme }
      rescue StandardError => e
        warn "Error in prepareRename handler: #{e.message}"
        nil
      end

      def name_like_token?(tok)
        return false if tok.nil?
        tok.type == :identifier || Token::KEYWORDS.value?(tok.type)
      end

      def allow_hover_last_good_fallback?(uri)
        return true unless @workspace.dependency_resolution_mode == :frozen

        path = uri_to_path(uri)
        return true unless path && File.file?(path)

        DependencyResolution.resolve(path, mode: @workspace.dependency_resolution_mode).ok?
      rescue StandardError
        true
      end

      def handle_rename(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']
        new_name = params['newName'].to_s

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless name_like_token?(token)

        import_alias_changes = import_alias_rename_changes(uri, token, lsp_line, lsp_char, nil, new_name)
        return { changes: import_alias_changes } if import_alias_changes

        enum_member_changes = enum_member_rename_changes(uri, token, lsp_line, lsp_char, nil, new_name)
        return { changes: enum_member_changes } if enum_member_changes

        if (facts = @workspace.get_facts(uri))
          scoped_changes = scoped_rename_changes(uri, token, lsp_line, lsp_char, facts, new_name)
          return { changes: scoped_changes } if scoped_changes

          enum_member_changes = enum_member_rename_changes(uri, token, lsp_line, lsp_char, facts, new_name)
          return { changes: enum_member_changes } if enum_member_changes
        end

        workspace_symbol_changes = workspace_symbol_identity_rename_changes(uri, token, lsp_line, lsp_char, new_name)
        return { changes: workspace_symbol_changes } if workspace_symbol_changes

        lexical_changes = lexical_rename_changes_in_document(uri, token.lexeme, new_name)
        return { changes: lexical_changes } if lexical_changes

        nil
      rescue StandardError => e
        warn "Error in rename handler: #{e.message}"
        nil
      end

      def lexical_rename_changes_in_document(uri, name, new_name)
        tokens = @workspace.get_tokens(uri) || []
        edits = tokens.flat_map do |tok|
          result = []

          if tok.type == :fstring && tok.literal.is_a?(Array)
            tok.literal.each do |part|
              next unless part.is_a?(Hash) && part[:kind] == :expr
              next unless part[:line] && part[:column]

              expr_tokens = MilkTea::Lexer.lex(part[:source], path: uri_to_path(uri))
              expr_tokens.each do |etok|
                next unless name_like_token?(etok) && etok.lexeme == name

                result << {
                  range: {
                    start: { line: part[:line] - 1, character: part[:column] + etok.column - 2 },
                    end:   { line: part[:line] - 1, character: part[:column] + etok.column - 2 + etok.lexeme.length },
                  },
                  newText: new_name,
                }
              end
            rescue MilkTea::LexError
              nil
            end
          end

          if name_like_token?(tok) && tok.lexeme == name
            result << { range: token_to_range(tok), newText: new_name }
          end

          result
        end

        return nil if edits.empty?

        { uri => edits }
      end

      def workspace_symbol_identity_rename_changes(uri, token, lsp_line, lsp_char, new_name)
        target_location = resolve_definition_location({
          'textDocument' => { 'uri' => uri },
          'position' => { 'line' => lsp_line, 'character' => lsp_char },
        }, stages: nil)
        return nil unless target_location

        target_identity = definition_identity_key(target_location)
        return nil unless target_identity

        related_uris = @workspace.related_open_document_uris(uri)
        return nil if related_uris.empty?

        changes = {}
        related_uris.each do |related_uri|
          tokens = @workspace.get_tokens(related_uri) || []
          next if tokens.empty?

          edits = tokens.filter_map do |candidate|
            next unless name_like_token?(candidate) && candidate.lexeme == token.lexeme

            candidate_location = resolve_definition_location({
              'textDocument' => { 'uri' => related_uri },
              'position' => { 'line' => candidate.line - 1, 'character' => candidate.column - 1 },
            }, stages: nil)
            next unless candidate_location
            next unless definition_identity_key(candidate_location) == target_identity

            {
              range: token_to_range(candidate),
              newText: new_name,
            }
          end

          changes[related_uri] = edits unless edits.empty?
        end

        return nil if changes.empty?

        changes
      end

      def definition_identity_key(location)
        uri = location[:uri] || location['uri']
        range = location[:range] || location['range']
        return nil unless uri && range

        start = range[:start] || range['start']
        return nil unless start

        line = start[:line] || start['line']
        character = start[:character] || start['character']
        return nil if line.nil? || character.nil?

        [uri, line, character]
      end

      def scoped_rename_changes(uri, token, lsp_line, lsp_char, facts, new_name)
        binding_id = rename_target_binding_id(uri, token, lsp_line, lsp_char, facts)
        unless binding_id
          return import_alias_rename_changes(uri, token, lsp_line, lsp_char, facts, new_name)
        end

        ranges = scoped_binding_occurrence_ranges(uri, token.lexeme, facts, binding_id, include_declaration: true)
        return nil if ranges.empty?

        edits = ranges.map do |range|
          {
            range: {
              start: { line: range[:line] - 1, character: range[:column] - 1 },
              end: { line: range[:line] - 1, character: range[:column] - 1 + range[:length] },
            },
            newText: new_name,
          }
        end

        { uri => edits }
      end

      def import_alias_rename_changes(uri, token, lsp_line, lsp_char, facts, new_name)
        alias_name = token.lexeme
        if facts
          return nil unless facts.imports.key?(alias_name)
        end

        ast = @workspace.get_ast(uri)
        return nil unless ast

        import_node = ast.imports.find do |imp|
          (imp.alias_name || imp.path.parts.last) == alias_name
        end
        return nil unless import_node

        # Validate the cursor is at the declaration site or a module-qualifier usage (alias followed by dot).
        tokens = @workspace.get_tokens(uri) || []

        cursor_at_declaration = token.line == import_node.line && token.column == import_node.column
        unless cursor_at_declaration
          # token was already located by find_token_at; verify it's used as a module qualifier
          tok_idx = tokens.index { |t| t.line == token.line && t.column == token.column }
          return nil unless tok_idx && tokens[tok_idx + 1]&.type == :dot
        end

        edits = []

        # Declaration site
        decl_char = import_node.column - 1
        edits << {
          range: {
            start: { line: import_node.line - 1, character: decl_char },
            end:   { line: import_node.line - 1, character: decl_char + alias_name.length },
          },
          newText: new_name,
        }

        # Usage sites: every token with this lexeme immediately followed by a dot
        tokens.each_with_index do |tok, i|
          next unless tok.type == :identifier && tok.lexeme == alias_name
          next unless tokens[i + 1]&.type == :dot

          edits << {
            range: {
              start: { line: tok.line - 1, character: tok.column - 1 },
              end:   { line: tok.line - 1, character: tok.column - 1 + alias_name.length },
            },
            newText: new_name,
          }
        end

        { uri => edits }
      end

      def enum_member_rename_changes(uri, token, lsp_line, lsp_char, facts, new_name)
        tokens = @workspace.get_tokens(uri) || []

        cursor_index = tokens.index { |t| t.line == token.line && t.column == token.column }
        return nil unless cursor_index

        cursor_is_enum_member = variant_enum_member_declaration?(tokens, cursor_index) ||
                                type_name_member_access?(tokens, cursor_index, facts)
        return nil unless cursor_is_enum_member

        edits = tokens.each_with_index.filter_map do |tok, i|
          next unless tok.type == :identifier && tok.lexeme == token.lexeme

          enum_member_decl = variant_enum_member_declaration?(tokens, i)
          enum_member_access = type_name_member_access?(tokens, i, facts)
          next unless enum_member_decl || enum_member_access

          {
            range: token_to_range(tok),
            newText: new_name,
          }
        end

        return nil if edits.empty?

        { uri => edits }
      end

      def scoped_local_reference_locations(uri, token, lsp_line, lsp_char, facts, include_declaration:)
        binding_id = rename_target_binding_id(uri, token, lsp_line, lsp_char, facts)
        return nil unless binding_id
        return nil unless local_binding_id?(uri, facts, binding_id)

        ranges = scoped_binding_occurrence_ranges(uri, token.lexeme, facts, binding_id, include_declaration: include_declaration)
        ranges.map do |range|
          {
            uri: uri,
            range: {
              start: { line: range[:line] - 1, character: range[:column] - 1 },
              end: { line: range[:line] - 1, character: range[:column] - 1 + range[:length] },
            },
          }
        end
      end

      def local_binding_id?(uri, facts, binding_id)
        ast = @workspace.get_ast(uri)
        return false unless ast

        resolution = facts.binding_resolution
        return false unless resolution

        each_ast_node(ast) do |node|
          next unless local_binding_declaration_node?(node)
          next unless resolution.declaration_binding_ids[node.object_id] == binding_id

          return true
        end

        false
      end

      def local_binding_declaration_node?(node)
        node.is_a?(AST::LocalDecl) ||
          node.is_a?(AST::Param) ||
          node.is_a?(AST::ForBinding) ||
          node.is_a?(AST::MatchArm) ||
          node.is_a?(AST::MatchExprArm)
      end

      def rename_target_binding_id(uri, token, lsp_line, lsp_char, facts)
        resolution = facts.binding_resolution
        return nil unless resolution

        line = lsp_line + 1
        char = lsp_char + 1
        ast = @workspace.get_ast(uri)
        return nil unless ast

        identifier_node = find_identifier_ast_node_at(ast, token.lexeme, line, char)
        if identifier_node && (id = resolution.identifier_binding_ids[identifier_node.object_id])
          return id
        end

        declaration_node = find_declaration_ast_node_at(ast, token.lexeme, line, char)
        if declaration_node && (id = resolution.declaration_binding_ids[declaration_node.object_id])
          return id
        end

        resolve_local_hover_binding(facts, token.lexeme, line, char)&.id
      end

      def scoped_binding_occurrence_ranges(uri, name, facts, binding_id, include_declaration:)
        ast = @workspace.get_ast(uri)
        return [] unless ast

        resolution = facts.binding_resolution
        return [] unless resolution

        ranges = []
        seen = Set.new

        each_ast_node(ast) do |node|
          range = nil

          if node.is_a?(AST::Identifier) && node.name == name && resolution.identifier_binding_ids[node.object_id] == binding_id
            range = ast_name_range(node.name, node.line, node.column)
          elsif include_declaration && resolution.declaration_binding_ids[node.object_id] == binding_id
            range = declaration_name_range(node)
          end

          next unless range

          key = [range[:line], range[:column], range[:length]]
          next if seen.include?(key)

          seen << key
          ranges << range
        end

        ranges
      end

      def find_identifier_ast_node_at(ast, name, line, char)
        each_ast_node(ast) do |node|
          next unless node.is_a?(AST::Identifier)
          next unless node.name == name
          next unless node.line == line
          next unless char >= node.column && char < node.column + name.length

          return node
        end

        nil
      end

      def find_declaration_ast_node_at(ast, name, line, char)
        each_ast_node(ast) do |node|
          range = declaration_name_range(node)
          next unless range
          next unless range[:name] == name
          next unless range[:line] == line
          next unless char >= range[:column] && char < range[:column] + range[:length]

          return node
        end

        nil
      end

      def declaration_name_range(node)
        if node.is_a?(AST::MatchArm) || node.is_a?(AST::MatchExprArm)
          return nil unless node.binding_name && node.binding_line && node.binding_column

          return {
            name: node.binding_name,
            line: node.binding_line,
            column: node.binding_column,
            length: node.binding_name.length,
          }
        end

        return nil unless node.respond_to?(:name) && node.respond_to?(:line) && node.respond_to?(:column)
        return nil unless node.name.is_a?(String) && node.line && node.column

        ast_name_range(node.name, node.line, node.column)
      end

      def ast_name_range(name, line, column)
        { name: name, line: line, column: column, length: name.length }
      end

      def each_ast_node(node, &block)
        return if node.nil?

        if node.is_a?(Array)
          node.each { |item| each_ast_node(item, &block) }
          return
        end

        class_name = node.class.name
        return unless class_name && class_name.start_with?('MilkTea::AST::')

        yield node

        if node.respond_to?(:members)
          node.members.each do |member|
            each_ast_node(node.public_send(member), &block)
          end
        end
      end
      end
    end
  end
end
