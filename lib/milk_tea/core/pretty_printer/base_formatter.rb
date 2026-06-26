# frozen_string_literal: true

module MilkTea
  module PrettyPrinter
    class BaseFormatter
      INDENT = "    "

      def initialize
        @lines = []
        @indent = 0
      end

      private

      def finish
        @lines.join("\n") + "\n"
      end

      def line(text = "")
        content = "#{INDENT * @indent}#{text}"
        @lines << content.rstrip
      end

      def blank_line
        @lines << "" unless @lines.empty? || @lines.last.empty?
      end

      def with_indent
        @indent += 1
        yield
      ensure
        @indent -= 1
      end

      # Renders into the line buffer via the given block, then extracts and
      # returns those lines (removing them from the buffer). Used to embed a
      # multi-line block (e.g. a proc body) inside an expression string while
      # keeping correct absolute indentation.
      def capture_lines
        start = @lines.length
        yield
        captured = @lines[start..] || []
        @lines.slice!(start..)
        captured
      end

      def binding_name(name, linkage_name)
        return linkage_name if name.nil? || name.empty? || name == linkage_name

        "#{name} as #{linkage_name}"
      end

      def precedence(operator)
        case operator
        when "or"
          10
        when "and"
          20
        when "|"
          30
        when "^"
          35
        when "&"
          40
        when "==", "!="
          50
        when "<", "<=", ">", ">="
          55
        when "<<", ">>"
          60
        when "+", "-"
          65
        when "*", "/", "%"
          70
        else
          0
        end
      end

      def wrap(text, parent_precedence, current_precedence)
        return text if current_precedence >= parent_precedence

        "(#{text})"
      end
    end
  end
end
