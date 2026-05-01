# frozen_string_literal: true

module MilkTea
  class FormatterError < StandardError; end

  class Formatter
    CheckResult = Data.define(:changed, :formatted_source)
    MODES = %i[safe canonical preserve].freeze

    def self.format_source(source, path: nil, mode: :safe)
      validate_mode!(mode)

      case mode
      when :safe
        contains_comment_trivia?(source, path:) ? preserve_format(source, path:) : canonical_format(source, path:)
      when :canonical
        ensure_canonical_safe!(source, path:)
        canonical_format(source, path:)
      when :preserve
        preserve_format(source, path:)
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
      ast = Parser.parse(source, path:)
      PrettyPrinter.format_ast(ast)
    end

    def self.preserve_format(source, path:)
      cst = build_cst(source, path:)
      CSTFormatter.format(cst)
    end

    def self.validate_mode!(mode)
      return if MODES.include?(mode)

      raise FormatterError, "unknown formatter mode #{mode.inspect}"
    end

    def self.ensure_canonical_safe!(source, path:)
      return unless contains_comment_trivia?(source, path:)

      raise FormatterError, "canonical formatting does not preserve comments; use --preserve"
    end

    def self.contains_comment_trivia?(source, path:)
      lexed = Lexer.lex_with_trivia(source, path:)
      lexed.trivia.any? { |entry| entry.kind == :comment }
    end
  end
end
