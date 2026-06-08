# frozen_string_literal: true

require_relative "../core"
require_relative "cst_formatter"

module MilkTea
  class FormatterError < StandardError; end

  class Formatter
    CheckResult = Data.define(:changed, :formatted_source)
    MODES = %i[safe canonical preserve tidy].freeze
    DEFAULT_MAX_LINE_LENGTH = 120

    def self.format_source(source, path: nil, mode: :safe, max_line_length: nil, profile: nil)
      validate_mode!(mode)

      case mode
      when :safe, :canonical
        canonical_format(source, path:, profile:)
      when :preserve
        preserve_format(source, path:, profile:)
      when :tidy
        tidy_format(source, path:, max_line_length: resolve_max_line_length(path, explicit: max_line_length), profile:)
      end
    end

    def self.check_source(source, path: nil, mode: :canonical, max_line_length: nil, profile: nil)
      profile_phase(profile, "format") do
        formatted = format_source(source, path:, mode:, max_line_length:, profile:)
        CheckResult.new(changed: source != formatted, formatted_source: formatted)
      end
    end

    def self.build_cst(source, path: nil)
      CSTBuilder.build(source, path:)
    end

    def self.profile_phase(profile, name)
      return yield unless profile

      profile.measure(name) { yield }
    end

    def self.canonical_format(source, path:, profile: nil)
      lexed = profile_phase(profile, "format.lex") { Lexer.lex_with_trivia(source, path:) }
      ast = profile_phase(profile, "format.parse") { Parser.parse(source, path:) }
      profile_phase(profile, "format.ast") { PrettyPrinter.format_ast(ast, trivia: lexed.trivia) }
    end

    def self.preserve_format(source, path:, profile: nil)
      cst = profile_phase(profile, "format.cst") { build_cst(source, path:) }
      profile_phase(profile, "format.cst_fmt") { CSTFormatter.format(cst) }
    end

    def self.tidy_format(source, path:, max_line_length: DEFAULT_MAX_LINE_LENGTH, profile: nil)
      cst = profile_phase(profile, "format.cst") { build_cst(source, path:) }
      normalized = profile_phase(profile, "format.normalize") { CSTFormatter.format_normalized(cst) }
      wrapped = profile_phase(profile, "format.wrap") { wrap_long_argument_lists(normalized, max_line_length:, path:) }
      profile_phase(profile, "format.blank_lines") { normalize_blank_lines(wrapped, path:) }
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
        tokens = Lexer.lex(current, path:)
        tokens_by_line = non_trivia_tokens_by_line(tokens)
        fix = nil

        lines.each_index do |line_index|
          next unless lines[line_index].delete_suffix("\n").length > max_line_length

          fix = build_long_line_wrap_fix(current, line_index, max_line_length:, path:, tokens:, tokens_by_line:)
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

    def self.build_long_line_wrap_fix(source, line_index, max_line_length: DEFAULT_MAX_LINE_LENGTH, path: nil, tokens: nil, tokens_by_line: nil, validate: true)
      return nil unless max_line_length.to_i.positive?

      lines = source.lines
      return nil unless line_index >= 0 && line_index < lines.length
      return nil if line_inside_external_or_foreign_function_header?(lines, line_index)
      return nil if line_inside_fn_type_signature?(lines, line_index)

      original_line = lines[line_index]
      line = original_line.delete_suffix("\n")
      return nil if line.length <= max_line_length
      return nil unless wrappable_long_line_candidate_text?(line)

      tokens ||= Lexer.lex(source, path:)
      line_tokens = tokens_by_line ? tokens_by_line.fetch(line_index + 1, []) : non_trivia_tokens_on_line(tokens, line_index + 1)
      candidates = long_line_wrap_candidates(line_tokens, line)

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
            Parser.parse(updated_lines.join, path:) if validate

            return {
              start_line_idx: line_index,
              end_line_idx: line_index,
              new_text:,
            }
          rescue StandardError
            next if validate
          end
      end

      logical_chain_fix = build_wrapped_logical_chain_fix(
        lines,
        line_index,
        line,
        line_tokens,
        line_terminator:,
        path:,
        validate:,
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

    def self.build_wrapped_logical_chain_fix(lines, line_index, line, line_tokens, line_terminator:, path:, validate: true)
      candidate = logical_chain_wrap_candidate(line_tokens, line)
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
      Parser.parse(updated_lines.join, path:) if validate

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
      previous_content_index = nil
      previous_top_level_declaration_group = nil
      previous_content_was_bodyful_function = false
      previous_content_was_comment = false

      lines.each_with_index do |line, line_index|
        if blank_line?(line)
          blank_run += 1
        else
          if emitted_content
            current_top_level_group = top_level_declaration_group(line)
            decorated_function_index = top_level_function_attached_to_attribute_start(lines, line_index)
            needed = if decorated_function_index
              if bodyless_function_header_at?(lines, decorated_function_index)
                1
              else
                2
              end
            elsif previous_content_index && line_inside_attribute_application?(lines, previous_content_index)
              0
            elsif extending_block_header_line?(line)
              2 # exactly 2 blank lines before extending blocks
            elsif function_line?(line)
               current_bodyless_function_header = bodyless_function_header_at?(lines, line_index)
               if current_bodyless_function_header
                 if previous_content_index && line_inside_bodyless_function_header?(lines, previous_content_index)
                   0 # Keep consecutive declaration-style functions tightly packed.
                 elsif previous_content_line && interface_block_header_line?(previous_content_line)
                   0 # First interface method should not have leading blank lines.
                 else
                   1 # Separate declaration-style functions from preceding non-function content.
                 end
               elsif previous_content_line && extending_block_header_line?(previous_content_line)
                 0 # First method in an extending block should not have leading blank lines.
               elsif previous_content_was_comment
                 1 # 1 blank line between a comment block and a function
               elsif previous_content_was_bodyful_function
                 2 # 2 blank lines between consecutive function definitions
               else
                 2 # 2 blank lines before first function in a scope (after const/struct/enum/import etc.)
               end
            elsif current_top_level_group
              if current_top_level_group == :struct && previous_top_level_declaration_group == :struct
                1
              elsif current_top_level_group == :enum && previous_top_level_declaration_group == :enum
                1
              elsif current_top_level_group == :union && previous_top_level_declaration_group == :union
                1
              elsif previous_top_level_declaration_group && current_top_level_group != previous_top_level_declaration_group
                1
              else
                [blank_run, 1].min
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
          previous_content_index = line_index
          current_top_level_group = top_level_declaration_group(line)
          previous_top_level_declaration_group = current_top_level_group if current_top_level_group
          if decorated_function_index
            unless bodyless_function_header_at?(lines, decorated_function_index)
              previous_content_was_bodyful_function = true
            end
          elsif function_line?(line) && !bodyless_function_header_at?(lines, line_index)
            previous_content_was_bodyful_function = true
          elsif current_top_level_group || extending_block_header_line?(line) || interface_block_header_line?(line) || line_is_import?(line) || line_is_comment?(line)
            previous_content_was_bodyful_function = false
           end
           previous_content_was_comment = line_is_comment?(line)
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

    def self.bodyless_function_header_at?(lines, line_index)
      line = lines[line_index]
      return false unless function_line?(line)

      return false unless bodyless_function_line?(line)

      function_indent = leading_indent_width(line)
      cursor = line_index + 1

      while cursor < lines.length
        candidate = lines[cursor]
        if blank_line?(candidate)
          cursor += 1
          next
        end

        candidate_indent = leading_indent_width(candidate)
        if candidate_indent < function_indent
          break
        elsif candidate_indent == function_indent && !function_header_continuation_line?(candidate)
          break
        end

        return false unless bodyless_function_line?(candidate)

        cursor += 1
      end

      true
    end

    def self.leading_indent_width(line)
      bytes = line.bytes
      i = 0
      i += 1 while i < bytes.length && (bytes[i] == 32 || bytes[i] == 9)
      i
    end

    def self.function_header_continuation_line?(line)
      stripped = line.strip
      return false if stripped.empty?

      stripped.start_with?(")", "]", ",", "->")
    end

    def self.line_inside_bodyless_function_header?(lines, line_index)
      start_index = line_index
      while start_index >= 0
        if function_line?(lines[start_index])
          return bodyless_function_header_at?(lines, start_index) && line_in_function_header_span?(lines, start_index, line_index)
        end

        start_index -= 1
      end

      false
    end

    def self.line_in_function_header_span?(lines, start_index, target_index)
      return false if target_index < start_index

      function_indent = leading_indent_width(lines[start_index])
      header_end = start_index
      cursor = start_index + 1

      while cursor < lines.length
        candidate = lines[cursor]
        if blank_line?(candidate)
          cursor += 1
          next
        end

        candidate_indent = leading_indent_width(candidate)
        if candidate_indent < function_indent
          break
        elsif candidate_indent == function_indent && !function_header_continuation_line?(candidate)
          break
        end

        header_end = cursor
        cursor += 1
      end

      target_index <= header_end
    end

    def self.line_inside_external_or_foreign_function_header?(lines, line_index)
      start_index = line_index
      while start_index >= 0
        if external_or_foreign_function_header_line?(lines[start_index])
          return line_in_function_header_span?(lines, start_index, line_index)
        end

        break if function_line?(lines[start_index])
        start_index -= 1
      end

      false
    end

    def self.external_or_foreign_function_header_line?(line)
      line.strip.match?(/\A(?:[A-Za-z_]\w*\s+)*(?:external|foreign)\s+function\b/)
    end

    def self.line_inside_fn_type_signature?(lines, line_index)
      start_index = line_index
      while start_index >= 0
        if fn_type_signature_start_line?(lines[start_index])
          return line_in_function_header_span?(lines, start_index, line_index)
        end

        break if function_line?(lines[start_index]) || external_or_foreign_function_header_line?(lines[start_index])
        start_index -= 1
      end

      false
    end

    def self.fn_type_signature_start_line?(line)
      stripped = line.strip
      return true if stripped.match?(/\Atype\s+[A-Za-z_]\w*\s*=\s*fn\s*\(/)

      stripped.match?(/\A[A-Za-z_]\w*\s*:\s*fn\s*\(/)
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

    def self.line_is_import?(line)
      line.strip.start_with?("import ")
    end

    def self.line_is_comment?(line)
      line.strip.start_with?("#")
    end

    def self.attribute_application_line?(line)
      line.strip.start_with?("@[")
    end

    def self.attribute_application_end_line(lines, start_index)
      return nil unless start_index >= 0 && start_index < lines.length
      return nil unless attribute_application_line?(lines[start_index])

      depth = 0
      open_seen = false
      index = start_index

      while index < lines.length
        bytes = lines[index].bytes
        char_index = 0
        while char_index < bytes.length
          byte = bytes[char_index]
          if byte == 91
            depth += 1
            open_seen = true
          elsif byte == 93 && depth.positive?
            depth -= 1
            return index if open_seen && depth.zero?
          end

          char_index += 1
        end

        index += 1
      end

      nil
    end

    def self.line_inside_attribute_application?(lines, line_index)
      start_index = line_index
      while start_index >= 0
        if attribute_application_line?(lines[start_index])
          end_index = attribute_application_end_line(lines, start_index)
          return false unless end_index

          return line_index <= end_index
        end

        break if function_line?(lines[start_index])
        start_index -= 1
      end

      false
    end

    def self.top_level_function_attached_to_attribute_start(lines, line_index)
      return nil unless leading_indent_width(lines[line_index]).zero?
      return nil unless attribute_application_line?(lines[line_index])
      return nil if line_index.positive? && line_inside_attribute_application?(lines, line_index - 1)

      cursor = line_index
      loop do
        end_index = attribute_application_end_line(lines, cursor)
        return nil unless end_index

        cursor = end_index + 1
        cursor += 1 while cursor < lines.length && blank_line?(lines[cursor])
        return nil if cursor >= lines.length

        if attribute_application_line?(lines[cursor]) && leading_indent_width(lines[cursor]).zero?
          next
        end

        return cursor if function_line?(lines[cursor]) && leading_indent_width(lines[cursor]).zero?

        return nil
      end
    end

    def self.top_level_declaration_group(line)
      stripped = line.strip
      return nil if stripped.empty?
      return nil unless leading_indent_width(line).zero?

      first_token = stripped[/\A[A-Za-z_][A-Za-z0-9_]*/]
      return nil unless first_token

      case first_token
      when "link", "include", "compiler_flag"
        :directive
      when "opaque"
        :opaque
      when "type"
        :type
      when "struct"
        :struct
      when "union"
        :union
      when "variant"
        :variant
      when "enum"
        :enum
      when "flags"
        :flags
      when "const"
        :const
      when "var"
        :var
      when "external"
        stripped.match?(/\Aexternal\s+function\b/) ? :external_function : :external
      else
        nil
      end
    end

    def self.long_line_wrap_candidates(line_tokens, line)
      stack = []
      candidates = []

      line_tokens.each_with_index do |token, index|
        case token.type
        when :lparen, :lbracket
          stack << { token:, index:, depth: stack.length }
        when :rparen, :rbracket
          opening = stack.pop
          next unless opening
          next unless matching_delimiter_pair?(opening[:token].type, token.type)

          candidate = build_long_line_wrap_candidate(
            line,
            line_tokens,
            opening[:index],
            index,
            opening[:depth],
          )
          candidates << candidate if candidate
        end
      end

      candidates
    end

    def self.logical_chain_wrap_candidate(line_tokens, line)
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

    def self.build_long_line_wrap_candidate(line, line_tokens, open_index, close_index, depth)
      open_token = line_tokens[open_index]
      close_token = line_tokens[close_index]
      nested_group_depth = 0
      comma_tokens = []

      (open_index + 1...close_index).each do |index|
        token = line_tokens[index]
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

    def self.wrappable_long_line_candidate_text?(line)
      return true if line.include?("(") || line.include?("[")
      return true if line.include?(" and ") || line.include?(" or ")

      false
    end

    def self.non_trivia_tokens_on_line(tokens, line_number)
      tokens.select { |token| token.line == line_number && !%i[newline indent dedent eof].include?(token.type) }
    end

    def self.non_trivia_tokens_by_line(tokens)
      tokens.each_with_object(Hash.new { |hash, line| hash[line] = [] }) do |token, by_line|
        next if %i[newline indent dedent eof].include?(token.type)

        by_line[token.line] << token
      end
    end

    def self.validate_mode!(mode)
      return if MODES.include?(mode)

      raise FormatterError, "unknown formatter mode #{mode.inspect}"
    end
  end
end
