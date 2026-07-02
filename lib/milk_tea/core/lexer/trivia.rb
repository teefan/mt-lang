# frozen_string_literal: true

module MilkTea
  class Lexer
    # Trivia collection (comments, blank lines, whitespace) used only when
    # lexing in :with_trivia mode for the concrete syntax tree / formatter.
    module Trivia
      private

      def with_trivia?
        @mode == :with_trivia
      end

      def register_detached_line_trivia(kind, line, line_number, line_offset, has_newline:)
        return unless with_trivia?

        text = has_newline ? (line + "\n") : line
        trivia = TriviaToken.new(
          kind:,
          text:,
          line: line_number,
          column: 1,
          start_offset: line_offset,
          end_offset: line_offset + text.bytesize,
        )
        push_pending_leading_trivia(trivia)
      end

      def push_pending_leading_trivia(trivia)
        return unless with_trivia?

        @trivia << trivia
        @pending_leading_trivia << trivia
      end

      def append_trailing_or_pending(trivia)
        return unless with_trivia?

        @trivia << trivia
        if @tokens.empty?
          @pending_leading_trivia << trivia
        else
          trailing = @pending_leading_trivia
          @pending_leading_trivia = []
          token = @tokens[-1]
          trailing.each { |entry| token = token.with_appended_trailing_trivia(entry) }
          token = token.with_appended_trailing_trivia(trivia)
          @tokens[-1] = token
        end
      end
    end
  end
end
