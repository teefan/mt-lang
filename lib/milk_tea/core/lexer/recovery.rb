# frozen_string_literal: true

module MilkTea
  class Lexer
    # Error-recovery heuristics: detecting a top-level declaration line to
    # resynchronize on after an unterminated grouping or heredoc.
    module Recovery
      private

      def top_level_resync_line?(line)
        return false if line.strip.empty?
        return false if leading_space_count(line).positive?

        first_word = line.strip.split(/\s+/, 3)[0]
        second_word = line.strip.split(/\s+/, 3)[1]

        case first_word
        when *TOP_LEVEL_RESYNC_PREFIXES
          true
        when "async"
          second_word == "function"
        when "public"
          %w[function struct union enum flags variant type const var opaque interface extending attribute event].include?(second_word)
        when "foreign", "external"
          second_word == "function"
        else
          false
        end
      end
    end
  end
end
