# frozen_string_literal: true

module MilkTea
  module CST
    SourceFile = Data.define(:source, :tokens, :trivia) do
      def reconstruct
        reconstruct_from_tokens
      end

      def reconstruct_normalized
        reconstruct_from_tokens(normalize_spaces: true)
      end

      def reconstruct_from_tokens(normalize_spaces: false)
        return "" if tokens.empty?

        tokens.each_with_object(+"") do |token, result|
          append_trivia(result, token.leading_trivia, normalize_spaces:, leading: true)
          result << segment_text(token.start_offset, token.end_offset, token.lexeme) unless token.eof?
          append_trivia(result, token.trailing_trivia, normalize_spaces:, leading: false)
        end
      end

      def append_trivia(result, entries, normalize_spaces:, leading:)
        entries.each do |entry|
          if normalize_spaces && entry.kind == :space && (!leading || entry.column > 1)
            result << " "
          else
            result << segment_text(entry.start_offset, entry.end_offset, entry.text)
          end
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
