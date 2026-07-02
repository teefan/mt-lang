# frozen_string_literal: true

module MilkTea
  class Lexer
    # Heredoc lexing (`<<-TAG`, `c<<-TAG`, `f<<-TAG`) including content
    # dedenting, terminator detection, and recovery.
    module Heredocs
      private

      def lex_heredoc(lines, line_index, index, line_number, line_offset, cstring:, format: false)
        line = lines.fetch(line_index).delete_suffix("\n").b
        prefix_length = heredoc_prefix(cstring:, format:).length
        tag_start = index + prefix_length
        tag_end = tag_start
        tag_end += 1 while tag_end < line.length && identifier_part?(line[tag_end])
        tag = line[tag_start...tag_end]
        remainder = line[tag_end..] || ""

        unless heredoc_context_allowed?
          return lex_symbol(line, index, line_number, line_offset:)
        end

        unless remainder.strip.empty?
          raise LexError.new("unexpected characters after heredoc tag", line: line_number, column: tag_end + 1, path: @path)
        end

        content_lines = []
        terminator_line = nil
        terminator_line_number = nil
        terminator_line_offset = nil
        terminator_has_newline = false
        last_line = line
        last_line_number = line_number
        last_line_offset = line_offset
        last_line_has_newline = lines.fetch(line_index).end_with?("\n")
        resync_line_offset = nil
        resync_line_number = nil
        scan_line_number = line_number + 1
        scan_line_offset = line_offset + lines.fetch(line_index).bytesize
        scan_line_index = line_index + 1

        content_min_indent = nil

        while scan_line_index < lines.length
          raw_line = lines.fetch(scan_line_index)
          raw_text = raw_line.delete_suffix("\n")
          if heredoc_terminator?(raw_text, tag)
            terminator_line = raw_text
            terminator_line_number = scan_line_number
            terminator_line_offset = scan_line_offset
            terminator_has_newline = raw_line.end_with?("\n")
            break
          end

          if @recovery_errors && content_min_indent&.positive? && top_level_resync_line?(raw_text)
            resync_line_offset = scan_line_offset
            resync_line_number = scan_line_number
            break
          end

          content_lines << raw_line
          last_line = raw_text
          last_line_number = scan_line_number
          last_line_offset = scan_line_offset
          last_line_has_newline = raw_line.end_with?("\n")
          scan_line_offset += raw_line.bytesize
          scan_line_number += 1
          scan_line_index += 1

          unless raw_text.strip.empty?
            line_indent = leading_space_count(raw_text)
            content_min_indent = line_indent if content_min_indent.nil? || line_indent < content_min_indent
          end
        end

        if terminator_line.nil? && @recovery_errors && resync_line_number.nil? && scan_line_index < lines.length
          trailing_text = lines.fetch(scan_line_index).delete_suffix("\n")
          if top_level_resync_line?(trailing_text)
            resync_line_offset = scan_line_offset
            resync_line_number = scan_line_number
          end
        end

        if terminator_line.nil?
          if @recovery_errors
            @recovery_errors << LexError.new("unterminated heredoc literal", line: line_number, column: index + 1, path: @path)
            start_offset = line_offset + index
            end_offset = resync_line_offset || scan_line_offset
            lexeme = @source.byteslice(start_offset, end_offset - start_offset)
            value = dedent_heredoc_content(content_lines)
            content_margin = heredoc_content_margin(content_lines)

            literal = if format
                         parse_format_heredoc_parts(value, start_line: line_number + 1, start_column: content_margin + 1)
                       else
                         value
                       end
            token_type = if format
                           :fstring
                         elsif cstring
                           :cstring
                         else
                           :string
                         end

            @tokens << token(token_type, lexeme, literal, line_number, index + 1, start_offset:, end_offset:)
            emit_line_newline(last_line, last_line_number, last_line_offset, last_line_has_newline)
            return resync_line_number ? (resync_line_number - line_number) : (scan_line_index - line_index)
          end

          raise LexError.new("unterminated heredoc literal", line: line_number, column: index + 1, path: @path)
        end

        start_offset = line_offset + index
        end_offset = terminator_line_offset + terminator_line.bytesize
        lexeme = @source.byteslice(start_offset, end_offset - start_offset)
        value = dedent_heredoc_content(content_lines)
        content_margin = heredoc_content_margin(content_lines)

        literal = if format
                     parse_format_heredoc_parts(value, start_line: line_number + 1, start_column: content_margin + 1)
                   else
                     value
                   end
        token_type = if format
                       :fstring
                     elsif cstring
                       :cstring
                     else
                       :string
                     end

        @tokens << token(token_type, lexeme, literal, line_number, index + 1, start_offset:, end_offset:)
        emit_line_newline(terminator_line, terminator_line_number, terminator_line_offset, terminator_has_newline)

        (scan_line_index - line_index) + 1
      end

      def heredoc_start?(line, index, cstring: false, format: false)
        prefix = heredoc_prefix(cstring:, format:)
        line[index, prefix.length] == prefix && identifier_start?(line[index + prefix.length])
      end

      def heredoc_prefix(cstring: false, format: false)
        operator = "<<-"
        if cstring
          "c#{operator}"
        elsif format
          "f#{operator}"
        else
          operator
        end
      end

      def heredoc_context_allowed?
        allowed = %i[
          newline indent dedent
          equal plus_equal minus_equal star_equal slash_equal percent_equal
          amp_equal pipe_equal caret_equal shift_left_equal shift_right_equal
          lparen lbracket comma colon
          return defer if else while match in
          or and not out inout
          plus minus star slash percent amp pipe caret shift_left shift_right
          less less_equal greater greater_equal equal_equal bang_equal
        ]
        previous_type = @tokens.last&.type
        previous_type.nil? || allowed.include?(previous_type)
      end

      def heredoc_terminator?(line, tag)
        line.match?(Regexp.new("\\A *#{Regexp.escape(tag)} *\\z"))
      end

      def heredoc_content_margin(raw_lines)
        raw_lines
          .map { |raw_line| raw_line.delete_suffix("\n") }
          .reject { |text| text.strip.empty? }
          .map { |text| leading_space_count(text) }
          .min || 0
      end

      def dedent_heredoc_content(raw_lines)
        dedent_heredoc_lines(raw_lines).each_with_index.map do |text, index|
          text + (raw_lines[index].end_with?("\n") ? "\n" : "")
        end.join
      end

      def dedent_heredoc_lines(raw_lines)
        margin = heredoc_content_margin(raw_lines)

        raw_lines.map do |raw_line|
          text = raw_line.delete_suffix("\n")
          text = text.strip.empty? ? "" : text[margin..]
          text || ""
        end
      end
    end
  end
end
