# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerFormatting
        private

      def handle_document_symbols(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri = params['textDocument']['uri']
        symbols = measure_perf_stage(stages, 'symbols') { @workspace.get_symbols(uri) }
        result = measure_perf_stage(stages, 'format') { symbols.map { |sym| format_symbol(sym, uri) } }

        # Enrich with hierarchical children from AST
        ast = @workspace.get_ast(uri)
        if ast && result
          enrich_with_children(result, ast)
        end

        result
      rescue StandardError => e
        warn "Error in documentSymbol handler: #{e.message}"
        []
      ensure
        symbol_count = defined?(result) && result ? result.length : 0
        log_request_stage_breakdown('textDocument/documentSymbol', total_start, uri: uri, stages: stages, summary: "symbols=#{symbol_count}")
      end

      def enrich_with_children(symbols, ast)
        ast.declarations&.each do |decl|
          children = child_symbols_for(decl)
          next unless children&.any?

          parent_name = child_parent_name(decl)
          parent = symbols.find { |s| s["name"] == parent_name }
          next unless parent

          parent["children"] ||= []
          parent_children = parent["children"]
          children.each { |c| parent_children << c unless parent_children.any? { |pc| pc["name"] == c["name"] } }
        end
        symbols
      end

      def child_parent_name(decl)
        case decl
        when AST::StructDecl then decl.name
        when AST::UnionDecl then decl.name
        when AST::EnumDecl then decl.name
        when AST::FlagsDecl then decl.name
        when AST::VariantDecl then decl.name
        when AST::InterfaceDecl then decl.name
        when AST::ExtendingBlock then decl.type_name
        else nil
        end
      end

      def child_symbols_for(decl)
        case decl
        when AST::StructDecl
          (decl.fields&.map { |f| child_field_symbol(f) } || []).compact
        when AST::UnionDecl
          (decl.fields&.map { |f| child_field_symbol(f) } || []).compact
        when AST::EnumDecl, AST::FlagsDecl
          (decl.members&.map { |m| child_member_symbol(m) } || []).compact
        when AST::VariantDecl
          (decl.members&.map { |m| child_member_symbol(m) } || []).compact
        when AST::InterfaceDecl
          (decl.methods&.map { |m| child_method_symbol(m) } || []).compact
        when AST::ExtendingBlock
          (decl.methods&.map { |m| child_method_symbol(m) } || []).compact
        else nil
        end
      end

      def child_field_symbol(f)
        return nil unless f.respond_to?(:name) && f.respond_to?(:line)
        {
          "name" => f.name, "kind" => 8,
          "range" => { "start" => { "line" => f.line - 1, "character" => 0 }, "end" => { "line" => f.line, "character" => 0 } },
          "selectionRange" => {
            "start" => { "line" => f.line - 1, "character" => (f.respond_to?(:column) ? f.column - 1 : 0) },
            "end" => { "line" => f.line - 1, "character" => (f.respond_to?(:column) ? f.column - 1 + f.name.length : 0) },
          },
        }
      end

      def child_member_symbol(m)
        return nil unless m.respond_to?(:name) && m.respond_to?(:line)
        {
          "name" => m.name, "kind" => 21,
          "range" => { "start" => { "line" => m.line - 1, "character" => 0 }, "end" => { "line" => m.line, "character" => 0 } },
          "selectionRange" => {
            "start" => { "line" => m.line - 1, "character" => (m.respond_to?(:column) ? m.column - 1 : 0) },
            "end" => { "line" => m.line - 1, "character" => (m.respond_to?(:column) ? m.column - 1 + m.name.length : 0) },
          },
        }
      end

      def child_method_symbol(m)
        return nil unless m.respond_to?(:name) && m.respond_to?(:line)
        detail = m.respond_to?(:return_type) && m.return_type ? "-> #{m.return_type.name.parts.join('.')}" : nil
        {
          "name" => m.name, "kind" => 6,
          "range" => { "start" => { "line" => m.line - 1, "character" => 0 }, "end" => { "line" => (m.respond_to?(:end_line) ? m.end_line || m.line : m.line), "character" => 0 } },
          "selectionRange" => {
            "start" => { "line" => m.line - 1, "character" => (m.respond_to?(:column) ? m.column - 1 : 0) },
            "end" => { "line" => m.line - 1, "character" => (m.respond_to?(:column) ? m.column - 1 + m.name.length : 0) },
          },
          "detail" => detail,
        }.compact
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
