# frozen_string_literal: true

module MilkTea
  module Parse
    module Blocks
      private

      def parse_block
        consume(:colon, "expected ':' before block")
        consume(:newline, "expected newline before block")
        consume(:indent, "expected indented block")

        parse_and_dedent_block_body
      end

      def parse_and_dedent_block_body
        statements = parse_statement_block_body
        consume(:dedent, "expected end of block")
        statements
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        []
      end

      def parse_statement_block_body
        statements = []
        skip_newlines
        until check(:dedent) || eof?
          if @recovery_errors
            begin
              raise error(unexpected_statement_block_indent_token, "unexpected indentation in statement block") if check(:indent)

              statements << parse_statement
            rescue ParseError => e
              @recovery_errors << e
              header_type = recovery_statement_header_type(e)
              recovered_body = synchronize_to_statement_boundary
              statements << if recovered_body
                              recovery_error_block_stmt(e, recovered_body, header_type:)
                            else
                              recovery_error_stmt(e)
                            end
            end
          else
            raise error(unexpected_statement_block_indent_token, "unexpected indentation in statement block") if check(:indent)

            statements << parse_statement
          end
          skip_newlines
        end
        statements
      end

      def parse_named_block(&block)
        consume(:colon, "expected ':' before block")
        consume(:newline, "expected newline before block")
        consume(:indent, "expected indented block")

        parse_block_body(&block)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        match(:newline)
        if match(:indent)
          begin
            parse_block_body(&block)
          rescue ParseError => e2
            @recovery_errors << e2
            []
          end
        else
          []
        end
      end

      def parse_block_body(&block)
        items = []
        skip_newlines
        until check(:dedent) || eof?
          items << block.call
          skip_newlines
        end

        consume(:dedent, "expected end of block")
        items
      end

      def parse_declaration_block
        consume(:colon, "expected ':' before block")
        consume(:newline, "expected newline before block")
        consume(:indent, "expected indented block")

        declarations = []
        skip_newlines
        until check(:dedent) || eof?
          declarations << parse_declaration
          skip_newlines
        end

        consume(:dedent, "expected end of block")
        declarations
      end

      def unexpected_statement_block_indent_token
        token = peek
        return token unless token&.type == :indent

        candidate = @tokens[@current + 1]
        return token unless candidate
        return token if %i[newline dedent eof].include?(candidate.type)

        candidate
      end
    end
  end
end
