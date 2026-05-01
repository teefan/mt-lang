# frozen_string_literal: true

module MilkTea
  module LSP
    # Collects parse and semantic errors and formats them as LSP Diagnostics
    class Diagnostics
      def self.collect(uri, content)
        diagnostics = []

        # Parse
        begin
          ast = Parser.parse(content, path: uri)

          # Semantic analysis — collect errors from all functions, not just first.
          begin
            result = Sema.check_collecting_errors(ast)
            result[:errors].each { |e| diagnostics << format_error(e) }
          rescue StandardError => e
            warn "Error collecting diagnostics: #{e.message}"
          end
        rescue MilkTea::LexError => e
          diagnostics << format_error(e)
        rescue MilkTea::ParseError => e
          diagnostics << format_error(e)
        rescue StandardError => e
          warn "Error collecting diagnostics: #{e.message}"
        end

        diagnostics
      end

      private

      def self.format_error(error)
        line = extract_line(error)
        column = extract_column(error)

        {
          range: {
            start: {
              line: (line.to_i - 1),
              character: (column.to_i - 1)
            },
            end: {
              line: (line.to_i - 1),
              character: (column.to_i)
            }
          },
          severity: 1,  # Error
          message: error.message.to_s,
          source: 'milk-tea'
        }
      end

      def self.extract_line(error)
        case error
        when MilkTea::LexError
          error.line || 1
        when MilkTea::ParseError
          error.token&.line || 1
        when MilkTea::SemaError
          error.line || 1
        else
          1
        end
      end

      def self.extract_column(error)
        case error
        when MilkTea::LexError
          error.column || 1
        when MilkTea::ParseError
          error.token&.column || 1
        when MilkTea::SemaError
          error.column || 1
        else
          1
        end
      end
    end
  end
end
