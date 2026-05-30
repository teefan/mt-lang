# frozen_string_literal: true

require_relative "../core"
require_relative "cst_formatter"

module MilkTea
  class FormatterError < StandardError; end

  class Formatter
    CheckResult = Data.define(:changed, :formatted_source)
    MODES = %i[safe canonical preserve tidy].freeze
    DEFAULT_MAX_LINE_LENGTH = 120

    def self.format_source(source, path: nil, mode: :safe, max_line_length: nil)
      validate_mode!(mode)

      case mode
      when :safe, :canonical
        canonical_format(source, path:)
      when :preserve
        preserve_format(source, path:)
      when :tidy
        tidy_format(source, path:, max_line_length: resolve_max_line_length(path, explicit: max_line_length))
      end
    end

    def self.check_source(source, path: nil, mode: :canonical, max_line_length: nil)
      formatted = format_source(source, path:, mode:, max_line_length:)
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

    def self.tidy_format(source, path:, max_line_length: DEFAULT_MAX_LINE_LENGTH)
      cst = build_cst(source, path:)
      normalized = CSTFormatter.format_normalized(cst)
      wrapped = wrap_long_argument_lists(normalized, max_line_length:, path:)
      normalize_blank_lines(wrapped, path:)
    end

    def self.resolve_max_line_length(path = nil, explicit: nil)
      value = explicit
      if (!value || value.to_i <= 0) && defined?(Linter) && Linter.respond_to?(:load_config)
        value = Linter.load_config(path)&.fetch(:max_line_length, nil)
      end

      value = value.to_i if value
      value&.positive? ? value : DEFAULT_MAX_LINE_LENGTH
    end

    def self.wrap_long_argument_lists(source, max_line_length: DEFAULT_MAX_LINE_LENGTH, path: nil)
      return source unless max_line_length.to_i.positive?

      current = source
      100.times do
        lines = current.lines
        fix = nil

        lines.each_index do |line_index|
          next unless lines[line_index].delete_suffix("\n").length > max_line_length

          fix = build_long_line_wrap_fix(current, line_index, max_line_length:, path:)
          break if fix
        end

        break unless fix

        updated_lines = current.lines
        updated_lines[fix[:start_line_idx]..fix[:end_line_idx]] = [fix[:new_text]]
        updated = updated_lines.join
        break if updated == current

        current = updated
      end

      return current if current == source

      Parser.parse(current, path:)
      current
    rescue StandardError
      source
    end

    def self.build_long_line_wrap_fix(source, line_index, max_line_length: DEFAULT_MAX_LINE_LENGTH, path: nil)
      return nil unless max_line_length.to_i.positive?

      lines = source.lines
      return nil unless line_index >= 0 && line_index < lines.length

      original_line = lines[line_index]
      line = original_line.delete_suffix("\n")
      return nil if line.length <= max_line_length

      tokens = Lexer.lex(source)
      candidates = long_line_wrap_candidates(tokens, line_index + 1, line)

      indent = line[/\A\s*/] || ""
      arg_indent = indent + "    "
      line_terminator = original_line.end_with?("\n") ? "\n" : ""

      unless candidates.empty?
        candidates
          .sort_by { |entry| [-(entry[:end_char] - entry[:start_char]), entry[:depth]] }
          .each do |candidate|
            new_text = build_wrapped_delimited_group_text(
              line,
              candidate,
              indent:,
              item_indent: arg_indent,
              line_terminator:,
            )
            next if new_text == original_line

            updated_lines = lines.dup
            updated_lines[line_index..line_index] = [new_text]
            Parser.parse(updated_lines.join, path:)

            return {
              start_line_idx: line_index,
              end_line_idx: line_index,
              new_text:,
            }
          rescue StandardError
            next
          end
      end

      logical_chain_fix = build_wrapped_logical_chain_fix(
        lines,
        line_index,
        line,
        tokens,
        line_terminator:,
        path:,
      )
      return logical_chain_fix if logical_chain_fix

      nil
    rescue StandardError
      nil
    end

    def self.build_wrapped_delimited_group_text(line, candidate, indent:, item_indent:, line_terminator:)
      new_text = +"#{line[0...candidate[:start_char]]}#{candidate[:opening_delimiter]}\n"
      candidate[:arguments].each_with_index do |argument, index|
        suffix = index < candidate[:arguments].length - 1 ? "," : ""
        new_text << "#{item_indent}#{argument}#{suffix}\n"
      end
      new_text << "#{indent}#{candidate[:closing_delimiter]}#{line[candidate[:end_char]..].to_s}#{line_terminator}"
      new_text
    end

    def self.build_wrapped_logical_chain_fix(lines, line_index, line, tokens, line_terminator:, path:)
      candidate = logical_chain_wrap_candidate(tokens, line_index + 1, line)
      return nil unless candidate

      indent = line[/\A\s*/] || ""
      item_indent = indent + "    "
      new_text = build_wrapped_logical_chain_text(
        line,
        candidate,
        indent:,
        item_indent:,
        line_terminator:,
      )
      return nil if new_text == lines[line_index]

      updated_lines = lines.dup
      updated_lines[line_index..line_index] = [new_text]
      Parser.parse(updated_lines.join, path:)

      {
        start_line_idx: line_index,
        end_line_idx: line_index,
        new_text:,
      }
    rescue StandardError
      nil
    end

    def self.build_wrapped_logical_chain_text(line, candidate, indent:, item_indent:, line_terminator:)
      new_text = +"#{line[0...candidate[:start_char]]}(\n"
      new_text << "#{item_indent}#{candidate[:segments].first}\n"
      candidate[:operators].each_with_index do |operator, index|
        new_text << "#{item_indent}#{operator} #{candidate[:segments][index + 1]}\n"
      end
      new_text << "#{indent})#{line[candidate[:end_char]..].to_s}#{line_terminator}"
      new_text
    end

    # Enforce blank-line rules:
    #   - exactly 2 blank lines before top-level function definitions with a body
    #   - exactly 2 blank lines before top-level extending blocks
    #   - bodyless function declarations: 1 blank line before the first declaration,
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
            needed = if previous_content_line && attribute_application_line?(previous_content_line)
              0
            elsif extending_block_header_line?(line)
              2 # exactly 2 blank lines before extending blocks
            elsif function_line?(line)
              if bodyless_function_line?(line)
                if previous_content_line && function_line?(previous_content_line) && bodyless_function_line?(previous_content_line)
                  0 # Keep consecutive declaration-style functions tightly packed.
                elsif previous_content_line && interface_block_header_line?(previous_content_line)
                  0 # First interface method should not have leading blank lines.
                else
                  1 # Separate declaration-style functions from preceding non-function content.
                end
              elsif previous_content_line && extending_block_header_line?(previous_content_line)
                0 # First method in an extending block should not have leading blank lines.
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

    def self.function_line?(line)
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

        if word == "function"
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

    def self.bodyless_function_line?(line)
      bytes = line.bytes
      i = bytes.length - 1
      i -= 1 while i >= 0 && (bytes[i] == 32 || bytes[i] == 9)
      return false if i < 0

      bytes[i] != 58 # ':'
    end

    def self.extending_block_header_line?(line)
      stripped = line.strip
      return false unless stripped.end_with?(":")

      stripped.start_with?("extending ")
    end

    def self.interface_block_header_line?(line)
      stripped = line.strip
      return false unless stripped.end_with?(":")

      stripped.start_with?("interface ")
    end

    def self.attribute_application_line?(line)
      line.strip.start_with?("@[")
    end

    def self.long_line_wrap_candidates(tokens, target_line_number, line)
      stack = []
      candidates = []

      tokens.each_with_index do |token, index|
        case token.type
        when :lparen, :lbracket
          stack << { token:, index:, depth: stack.length }
        when :rparen, :rbracket
          opening = stack.pop
          next unless opening
          next unless matching_delimiter_pair?(opening[:token].type, token.type)
          next unless opening[:token].line == target_line_number && token.line == target_line_number

          candidate = build_long_line_wrap_candidate(
            line,
            tokens,
            opening[:token],
            opening[:index],
            token,
            index,
            opening[:depth],
          )
          candidates << candidate if candidate
        end
      end

      candidates
    end

    def self.logical_chain_wrap_candidate(tokens, target_line_number, line)
      line_tokens = tokens.select do |token|
        token.line == target_line_number && !%i[newline indent dedent eof].include?(token.type)
      end
      return nil if line_tokens.length < 4

      header_length = case line_tokens.first.type
                      when :if, :while
                        1
                      when :else
                        line_tokens[1]&.type == :if ? 2 : 0
                      else
                        0
                      end
      return nil if header_length.zero?

      colon_token = line_tokens.reverse.find { |token| token.type == :colon }
      return nil unless colon_token

      expression_start_token = line_tokens[header_length]
      return nil unless expression_start_token

      start_char = expression_start_token.column - 1
      return nil if line[start_char] == "("

      nested_group_depth = 0
      operators = []
      segments = []
      current_start = start_char

      line_tokens[header_length...line_tokens.index(colon_token)].each do |token|
        case token.type
        when :lparen, :lbracket
          nested_group_depth += 1
        when :rparen, :rbracket
          nested_group_depth -= 1 if nested_group_depth.positive?
        when :and, :or
          next unless nested_group_depth.zero?

          segment = line[current_start...(token.column - 1)].to_s.strip
          return nil if segment.empty?

          segments << segment
          operators << token.lexeme
          current_start = token.column - 1 + token.lexeme.length
        end
      end

      return nil if operators.empty?

      final_segment = line[current_start...(colon_token.column - 1)].to_s.strip
      return nil if final_segment.empty?

      segments << final_segment
      {
        start_char:,
        end_char: colon_token.column - 1,
        operators:,
        segments:,
      }
    end

    def self.matching_delimiter_pair?(opening_type, closing_type)
      (opening_type == :lparen && closing_type == :rparen) ||
        (opening_type == :lbracket && closing_type == :rbracket)
    end

    def self.build_long_line_wrap_candidate(line, tokens, open_token, open_index, close_token, close_index, depth)
      nested_group_depth = 0
      comma_tokens = []

      (open_index + 1...close_index).each do |index|
        token = tokens[index]
        case token.type
        when :lparen, :lbracket
          nested_group_depth += 1
        when :rparen, :rbracket
          nested_group_depth -= 1 if nested_group_depth.positive?
        when :comma
          comma_tokens << token if nested_group_depth.zero? && token.line == open_token.line
        end
      end

      return nil if comma_tokens.empty?

      start_char = open_token.column - 1
      end_char = close_token.column
      current_start = start_char + 1
      arguments = []

      comma_tokens.each do |comma|
        argument = line[current_start...(comma.column - 1)].to_s.strip
        return nil if argument.empty?

        arguments << argument
        current_start = comma.column
      end

      final_argument = line[current_start...(close_token.column - 1)].to_s.strip
      return nil if final_argument.empty?

      arguments << final_argument
      {
        depth:,
        start_char:,
        end_char:,
        opening_delimiter: open_token.lexeme,
        closing_delimiter: close_token.lexeme,
        arguments:,
      }
    end

    def self.validate_mode!(mode)
      return if MODES.include?(mode)

      raise FormatterError, "unknown formatter mode #{mode.inspect}"
    end
  end
end
