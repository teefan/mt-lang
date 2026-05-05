# frozen_string_literal: true

module MilkTea
  module CST
    SourceFile = Data.define(:source, :tokens, :trivia) do
      def reconstruct
        reconstruct_from_tokens
      end

      def reconstruct_normalized
        return "" if tokens.empty?

        tokens.each_with_object(+"") do |token, result|
          token.leading_trivia.each do |entry|
            if entry.kind == :space && entry.column > 1
              result << " "
            else
              result << segment_text(entry.start_offset, entry.end_offset, entry.text)
            end
          end
          result << segment_text(token.start_offset, token.end_offset, token.lexeme) unless token.eof?
          token.trailing_trivia.each do |entry|
            if entry.kind == :space
              result << " "
            else
              result << segment_text(entry.start_offset, entry.end_offset, entry.text)
            end
          end
        end
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

        fallback_text = fallback.dup.force_encoding(source.encoding)
        segment = source.byteslice(start_offset, end_offset - start_offset)
        return fallback_text unless segment
        segment = segment.dup.force_encoding(source.encoding)
        return fallback_text if segment != fallback_text

        segment
      end
    end
  end
end
