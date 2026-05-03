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
      normalize_blank_lines(normalized, path:)
    end

    # Enforce blank-line rules:
    #   - exactly 2 blank lines before function definitions with a body
    #   - bodyless def declarations: 1 blank line before the first declaration,
    #     then 0 blank lines between consecutive declarations
    #   - at most 1 blank line everywhere else (constants, variable declarations, expressions)
    #   - exactly 1 trailing newline at EOF
    def self.normalize_blank_lines(source, path: nil)
      lines = source.lines(chomp: true)
      result = []
      blank_run = 0
      emitted_content = false
      previous_content_line = nil

      lines.each do |line|
        if blank_line?(line)
          blank_run += 1
        else
          if emitted_content
            needed = if def_line?(line)
              if bodyless_def_line?(line)
                if previous_content_line && def_line?(previous_content_line) && bodyless_def_line?(previous_content_line)
                  0 # Keep consecutive declaration-style defs tightly packed.
                else
                  1 # Separate declaration-style defs from preceding non-def content.
                end
              else
                2 # exactly 2 blank lines before function definitions
              end
            else
              [blank_run, 1].min  # max 1 blank line elsewhere
            end
            needed.times { result << "" }
          end
          result << line
          blank_run = 0
          emitted_content = true
          previous_content_line = line
        end
      end

      return "" if result.empty?

      "#{result.join("\n")}\n"
    end

    def self.def_line?(line)
      bytes = line.bytes
      i = 0

      i += 1 while i < bytes.length && (bytes[i] == 32 || bytes[i] == 9)
      return false if i >= bytes.length

      loop do
        word_start = i
        return false unless identifier_head_byte?(bytes[i])

        i += 1
        i += 1 while i < bytes.length && identifier_tail_byte?(bytes[i])
        word = bytes[word_start...i].pack("C*")

        if word == "def"
          return i < bytes.length && (bytes[i] == 32 || bytes[i] == 9)
        end

        return false unless i < bytes.length && (bytes[i] == 32 || bytes[i] == 9)

        i += 1 while i < bytes.length && (bytes[i] == 32 || bytes[i] == 9)
        return false if i >= bytes.length
      end
    end

    def self.blank_line?(line)
      line.empty? || line.bytes.all? { |b| b == 32 || b == 9 }
    end

    def self.identifier_head_byte?(byte)
      (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
    end

    def self.identifier_tail_byte?(byte)
      identifier_head_byte?(byte) || (byte >= 48 && byte <= 57)
    end

    def self.bodyless_def_line?(line)
      bytes = line.bytes
      i = bytes.length - 1
      i -= 1 while i >= 0 && (bytes[i] == 32 || bytes[i] == 9)
      return false if i < 0

      bytes[i] != 58 # ':'
    end

    def self.validate_mode!(mode)
      return if MODES.include?(mode)

      raise FormatterError, "unknown formatter mode #{mode.inspect}"
    end
  end
end
