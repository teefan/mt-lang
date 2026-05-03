# frozen_string_literal: true

module MilkTea
  class FormatterError < StandardError; end

  class Formatter
    CheckResult = Data.define(:changed, :formatted_source)
    MODES = %i[safe canonical preserve tidy].freeze

    def self.format_source(source, path: nil, mode: :safe)
      validate_mode!(mode)

      case mode
      when :safe, :canonical
        canonical_format(source, path:)
      when :preserve
        preserve_format(source, path:)
      when :tidy
        tidy_format(source, path:)
      end
    end

    def self.check_source(source, path: nil, mode: :canonical)
      formatted = format_source(source, path:, mode:)
      CheckResult.new(changed: source != formatted, formatted_source: formatted)
    end

    def self.build_cst(source, path: nil)
      CSTBuilder.build(source, path:)
    end

    def self.canonical_format(source, path:)
      lexed = Lexer.lex_with_trivia(source, path:)
      ast = Parser.parse(source, path:)
      PrettyPrinter.format_ast(ast, trivia: lexed.trivia)
    end

    def self.preserve_format(source, path:)
      cst = build_cst(source, path:)
      CSTFormatter.format(cst)
    end

    def self.tidy_format(source, path:)
      cst = build_cst(source, path:)
      normalized = CSTFormatter.format_normalized(cst)
      normalize_blank_lines(normalized)
    end

    # Enforce blank-line rules (Python PEP 8 / black style):
    #   - exactly 2 blank lines before any function definition (`def` / `pub def` / etc.)
    #   - at most 1 blank line everywhere else (constants, variable declarations, expressions)
    #   - exactly 1 trailing newline at EOF
    def self.normalize_blank_lines(source)
      lines = source.lines(chomp: true)
      result = []
      blank_run = 0
      emitted_content = false

      lines.each do |line|
        if line.strip.empty?
          blank_run += 1
        else
          if emitted_content
            needed = if def_line?(line)
              2  # exactly 2 blank lines before function definitions
            else
              [blank_run, 1].min  # max 1 blank line elsewhere
            end
            needed.times { result << "" }
          end
          result << line
          blank_run = 0
          emitted_content = true
        end
      end

      return "" if result.empty?

      "#{result.join("\n")}\n"
    end

    def self.def_line?(line)
      line.match?(/\A\s*(pub\s+)?(foreign\s+)?def\s/)
    end

    def self.validate_mode!(mode)
      return if MODES.include?(mode)

      raise FormatterError, "unknown formatter mode #{mode.inspect}"
    end
  end
end
