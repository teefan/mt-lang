# frozen_string_literal: true

module MilkTea
  module CST
    TokenNode = Data.define(:token)

    SourceFile = Data.define(:source, :tokens, :trivia, :nodes) do
      def reconstruct
        reconstruct_from_tokens
      end

      def reconstruct_from_tokens
        return "" if tokens.empty?

        tokens.each_with_object(+"") do |token, result|
          token.leading_trivia.each { |entry| result << segment_text(entry.start_offset, entry.end_offset, entry.text) }
          result << segment_text(token.start_offset, token.end_offset, token.lexeme) unless token.eof?
          token.trailing_trivia.each { |entry| result << segment_text(entry.start_offset, entry.end_offset, entry.text) }
        end
      end

      def segment_text(start_offset, end_offset, fallback)
        return fallback unless source
        return "" if end_offset <= start_offset

        source.byteslice(start_offset, end_offset - start_offset) || fallback
      end
    end
  end
end
