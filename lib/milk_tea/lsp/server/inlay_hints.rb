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
        i = 0
        while i < tokens.length - 1
          callee = tokens[i]
          next_tok = tokens[i + 1]

          # Skip function definitions — `function foo(` has the same identifier+lparen
          # shape as a call site but must not get parameter-name inlay hints.
          prev_tok = i > 0 ? tokens[i - 1] : nil

          # Also support module-qualified call sites (`mod.fn(...)`).
          # Ignore identifiers immediately after `.` to avoid treating member names
          # as unqualified local calls.
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
                # Suppress hint when the argument is a bare identifier whose name
                # already matches the parameter — `foo(x: x)` hints are just noise.
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
      rescue StandardError => e
        warn "Error in inlayHint handler: #{e.message}"
        []
      end
      end
    end
  end
end
