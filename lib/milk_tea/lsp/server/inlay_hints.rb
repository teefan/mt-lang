# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerInlayHints
        private

      def handle_inlay_hint(params)
        uri = params.dig('textDocument', 'uri')
        range = params['range'] || {}
        start_line = range.dig('start', 'line') || 0
        start_char = range.dig('start', 'character') || 0
        end_line = range.dig('end', 'line') || 0
        end_char = range.dig('end', 'character') || 0

        content = @workspace.get_content(uri)
        return [] if content && skip_expensive_work_reason(uri, content)

        facts = @workspace.get_facts(uri)
        tokens = @workspace.get_tokens(uri)
        return [] unless facts && tokens

        hints = []

        # Parameter-name hints at call sites
        hints.concat(collect_parameter_name_hints(tokens, facts, start_line, start_char, end_line, end_char))

        # Type annotation hints for inferred locals
        hints.concat(collect_inferred_type_hints(facts, start_line, start_char, end_line, end_char))

        # Return type hints for inferred return types
        hints.concat(collect_inferred_return_hints(facts, start_line, start_char, end_line, end_char))

        hints
      rescue StandardError => e
        warn "Error in inlayHint handler: #{e.message}"
        []
      end

      def collect_parameter_name_hints(tokens, facts, start_line, start_char, end_line, end_char)
        hints = []
        i = 0
        while i < tokens.length - 1
          callee = tokens[i]
          next_tok = tokens[i + 1]

          prev_tok = i > 0 ? tokens[i - 1] : nil

          if callee.type == :identifier && prev_tok&.type != :function && prev_tok&.type != :dot
            binding = nil
            lparen_index = nil

            if next_tok&.type == :lparen
              binding = facts.functions[callee.lexeme]
              lparen_index = i + 1
            elsif next_tok&.type == :dot
              member = tokens[i + 2]
              member_lparen = tokens[i + 3]
              if member&.type == :identifier && member_lparen&.type == :lparen
                module_binding = facts.imports[callee.lexeme]
                binding = module_binding&.functions&.[](member.lexeme)
                lparen_index = i + 3
              end
            end

            if binding && lparen_index
              arg_starts, closing_index = collect_call_argument_starts(tokens, lparen_index)
              params_list = binding.type.params

              arg_starts.each_with_index do |arg_tok, index|
                break if index >= params_list.length
                next unless position_in_range?(arg_tok.line - 1, arg_tok.column - 1, start_line, start_char, end_line, end_char)
                next if self_describing_argument_expression?(tokens, arg_tok)
                param_name = params_list[index].name
                next if arg_tok.type == :identifier && arg_tok.lexeme == param_name

                hints << {
                  position: { line: arg_tok.line - 1, character: arg_tok.column - 1 },
                  label: "#{params_list[index].name}: ",
                  kind: 2,
                  paddingRight: true
                }
              end

              i = closing_index if closing_index
            end
          end

          i += 1
        end
        hints
      end

      def collect_inferred_type_hints(facts, start_line, start_char, end_line, end_char)
        hints = []
        collect_local_decls(facts.ast).each do |decl|
          next unless decl.type.nil?
          next unless position_in_range?(decl.line - 1, decl.column - 1, start_line, start_char, end_line, end_char)

          binding = facts.values[decl.name]
          next unless binding

          display_type = describe_type_for_hint(binding.storage_type)
          next unless display_type

          hints << {
            position: { line: decl.line - 1, character: decl.column - 1 + decl.name.length },
            label: ": #{display_type}",
            kind: 1,
            paddingRight: false
          }
        end
        hints
      end

      def collect_inferred_return_hints(facts, start_line, start_char, end_line, end_char)
        hints = []
        collect_function_defs(facts.ast).each do |func|
          next unless func.return_type.nil?
          next unless position_in_range?(func.line - 1, func.column - 1, start_line, start_char, end_line, end_char)

          binding = facts.functions[func.name]
          next unless binding

          return_type = binding.type.return_type
          next unless return_type

          display_type = describe_type_for_hint(return_type)
          next unless display_type
          next if display_type == "void"

          label = "-> #{display_type}"
          hints << {
            position: { line: func.line - 1, character: func.column - 1 + func.name.length },
            label: label,
            kind: 1,
            paddingRight: false
          }
        end
        hints
      end

      def collect_local_decls(ast_node)
        results = []
        case ast_node
        when Array
          ast_node.each { |n| results.concat(collect_local_decls(n)) }
        when AST::SourceFile
          ast_node.declarations.each { |d| results.concat(collect_local_decls(d)) }
        when AST::FunctionDef
          results.concat(collect_local_decls(ast_node.body)) if ast_node.body
        when AST::MethodDef
          results.concat(collect_local_decls(ast_node.body)) if ast_node.body
        when AST::ExtendingBlock
          ast_node.methods.each { |m| results.concat(collect_local_decls(m)) }
        when AST::IfStmt
          ast_node.branches.each { |b| results.concat(collect_local_decls(b.body)) }
          results.concat(collect_local_decls(ast_node.else_body)) if ast_node.else_body
        when AST::MatchStmt
          ast_node.arms.each { |a| results.concat(collect_local_decls(a.body)) }
        when AST::ForStmt
          results.concat(collect_local_decls(ast_node.body))
        when AST::WhileStmt
          results.concat(collect_local_decls(ast_node.body))
        when AST::UnsafeStmt
          results.concat(collect_local_decls(ast_node.body))
        when AST::LocalDecl
          results << ast_node
        when AST::VariantArm
          # no body
        end
        results
      end

      def collect_function_defs(ast_node)
        results = []
        case ast_node
        when Array
          ast_node.each { |n| results.concat(collect_function_defs(n)) }
        when AST::SourceFile
          ast_node.declarations.each do |d|
            case d
            when AST::FunctionDef
              results << d
            when AST::ExtendingBlock
              results.concat(d.methods)
            end
          end
        end
        results
      end

      def describe_type_for_hint(type)
        return nil unless type

        type.to_s
      rescue StandardError
        nil
      end
      end
    end
  end
end
