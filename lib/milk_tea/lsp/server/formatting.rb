# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerFormatting
        private

      def handle_document_symbols(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri     = params['textDocument']['uri']
        symbols = measure_perf_stage(stages, 'symbols') { @workspace.get_symbols(uri) }
        result = measure_perf_stage(stages, 'format') { symbols.map { |sym| format_symbol(sym, uri) } }
        result
      rescue StandardError => e
        warn "Error in documentSymbol handler: #{e.message}"
        []
      ensure
        symbol_count = defined?(result) && result ? result.length : 0
        log_request_stage_breakdown('textDocument/documentSymbol', total_start, uri: uri, stages: stages, summary: "symbols=#{symbol_count}")
      end

      def handle_formatting(params)
        uri     = params['textDocument']['uri']
        content = @workspace.get_content(uri)

        formatted = Formatter.format_source(content, path: uri, mode: @format_mode)
        line_count = content.count("\n")

        [
          {
            range: {
              start: { line: 0, character: 0 },
              end:   { line: line_count + 1, character: 0 }
            },
            newText: formatted
          }
        ]
      rescue StandardError => e
        warn "Error in formatting handler: #{e.message}"
        []
      end

      def handle_range_formatting(params)
        uri = params['textDocument']['uri']
        content = @workspace.get_content(uri)
        range = params['range'] || {}
        start_pos = range['start'] || { 'line' => 0, 'character' => 0 }
        end_pos = range['end'] || { 'line' => 0, 'character' => 0 }

        start_off = @workspace.position_to_offset(uri, start_pos['line'], start_pos['character'])
        end_off = @workspace.position_to_offset(uri, end_pos['line'], end_pos['character'])
        return [] if end_off < start_off

        segment = content.byteslice(start_off...end_off).to_s
        formatted_segment = Formatter.format_source(segment, path: uri, mode: @format_mode)

        [
          {
            range: {
              start: { line: start_pos['line'], character: start_pos['character'] },
              end: { line: end_pos['line'], character: end_pos['character'] }
            },
            newText: formatted_segment
          }
        ]
      rescue StandardError => e
        warn "Error in rangeFormatting handler: #{e.message}"
        []
      end
      end
    end
  end
end
