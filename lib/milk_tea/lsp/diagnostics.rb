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

          # Semantic analysis (check will raise on errors)
          begin
            Sema.check(ast)
          rescue SemaError => e
            diagnostics << format_error(e)
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
        when MilkTea::LexError, MilkTea::ParseError
          error.line || 1
        else
          1
        end
      end

      def self.extract_column(error)
        case error
        when MilkTea::LexError, MilkTea::ParseError
          error.column || 1
        else
          1
        end
      end
    end
  end
end
