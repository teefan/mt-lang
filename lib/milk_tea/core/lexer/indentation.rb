# frozen_string_literal: true

module MilkTea
  class Lexer
    # Indentation-to-INDENT/DEDENT token conversion and error recovery.
    module Indentation
      private

      def emit_indentation(indent, line_number, line_offset)
        if (indent % 4) != 0
          raise LexError.new("indentation must use multiples of 4 spaces", line: line_number, column: indent + 1, path: @path)
        end

        current_indent = @indent_stack.last
        if indent == current_indent
          return
        end

        if indent > current_indent
          if indent != current_indent + 4
            raise LexError.new("indentation may only increase by 4 spaces at a time", line: line_number, column: 1, path: @path)
          end

          @indent_stack << indent
          @tokens << token(:indent, "", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
          return
        end

        while @indent_stack.last > indent
          @indent_stack.pop
          @tokens << token(:dedent, "", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
        end

        return if @indent_stack.last == indent

        raise LexError.new("indentation does not match any open block", line: line_number, column: 1, path: @path)
      end

      def recover_indentation(indent, line_number, line_offset)
        recovered_indent = indent - (indent % 4)
        current_indent = @indent_stack.last

        if recovered_indent > current_indent + 4
          recovered_indent = current_indent + 4
        end

        if recovered_indent > current_indent
          @indent_stack << recovered_indent
          @tokens << token(:indent, "", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
          return
        end

        while @indent_stack.last > recovered_indent
          @indent_stack.pop
          @tokens << token(:dedent, "", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
        end

        return if @indent_stack.last == recovered_indent
      end
    end
  end
end
