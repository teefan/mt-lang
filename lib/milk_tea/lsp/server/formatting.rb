# frozen_string_literal: true

require "set"

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
        result = measure_perf_stage(stages, 'format') { symbols.map { |sym| format_document_symbol(sym) } }

        # Enrich with hierarchical children from AST
        ast = @workspace.get_ast(uri)
        if ast && result
          enrich_with_children(result, ast)
        end

        module_name = resolve_outline_module_name(uri)
        result = wrap_in_module_hierarchy(result, module_name, uri) if module_name && result&.any?

        result
      rescue StandardError => e
        warn "Error in documentSymbol handler: #{e.message}"
        []
      ensure
        symbol_count = defined?(result) && result ? result.length : 0
        log_request_stage_breakdown('textDocument/documentSymbol', total_start, uri: uri, stages: stages, summary: "symbols=#{symbol_count}")
      end

      def resolve_outline_module_name(uri)
        module_name = @workspace.module_name_for_uri(uri) || @workspace.get_facts(uri)&.module_name
        return nil unless module_name && !module_name.empty?

        segments = module_name.split('.')
        return nil if segments.length <= 1

        # Only wrap files that live under a real source root: either a
        # package.toml directory or the std/ library hierarchy.
        path = @workspace.send(:uri_to_path, uri)
        if path && !MilkTea::ModuleRoots.package_root_for_path(path) && !path.split('/').include?('std')
          return nil
        end

        module_name
      end

      def wrap_in_module_hierarchy(symbols, module_name, uri)
        return symbols unless module_name && !module_name.empty?

        segments = module_name.split('.')
        return symbols if segments.length <= 1

        content = @workspace.get_content(uri)
        total_lines = content ? content.count("\n") : 0
        file_range = {
          start: { line: 0, character: 0 },
          end: { line: total_lines, character: 0 },
        }

        children = symbols
        segments.reverse.each do |seg|
          children = [{
            name: seg,
            kind: 2,
            range: file_range,
            selectionRange: file_range,
            children: children,
          }]
        end
        children
      end

      def enrich_with_children(symbols, ast)
        removed_local_names = []
        removed_method_names = []
        removed_nested_type_names = []
        name_index = symbols.each_with_object(Hash.new { |h, k| h[k] = [] }) { |s, h| h[s[:name]] << s }

        ast.declarations&.each do |decl|
          removed_nested_type_names.concat(collect_nested_type_names(decl)) if decl.is_a?(AST::StructDecl)

          case decl
          when AST::FunctionDef
            parent = name_index[decl.name]&.find { |s| symbol_line(s) == (decl.line || 0) }
            next unless parent

            if (detail = type_detail_string(decl.return_type))
              parent[:detail] = "-> #{detail}"
            end

            locals = collect_local_decls(decl.body)
            next unless locals&.any?

            parent[:children] ||= []
            parent_children = parent[:children]
            locals.each do |local|
              next unless local.name

              child = local_decl_symbol(local)
              next unless child

              parent_children << child unless parent_children.any? { |pc| pc[:name] == child[:name] }
              removed_local_names << local.name
            end
          when AST::ExtendingBlock
            type_name_str = decl.type_name.name.parts.join('.')

            # Find the extending block's own flat token symbol by name + line,
            # enrich it in-place with the implementation detail and methods.
            parent = name_index[type_name_str]&.find { |s| s[:kind] == 23 && symbol_line(s) == (decl.line || 0) }
            unless parent
              line = decl.line || 0
              parent = {
                name: type_name_str,
                kind: 23,
                detail: 'implementation',
                range: { start: { line: line - 1, character: 0 }, end: { line: line, character: 0 } },
                selectionRange: { start: { line: line - 1, character: 0 }, end: { line: line - 1, character: type_name_str.length } },
                children: [],
              }
              symbols << parent
              name_index[type_name_str] << parent
            end
            parent[:detail] = 'implementation'

            (decl.methods || []).each do |method|
              next unless method.respond_to?(:name) && method.name

              child = child_method_symbol(method)
              next unless child

              parent[:children] ||= []
              parent_children = parent[:children]
              parent_children << child unless parent_children.any? { |pc| pc[:name] == child[:name] }
              removed_method_names << child[:name] if child[:kind] == 6

              locals = collect_local_decls(method.respond_to?(:body) ? method.body : nil)
              next unless locals&.any?

              child[:children] ||= []
              child_children = child[:children]
              locals.each do |local|
                next unless local.name

                local_child = local_decl_symbol(local)
                next unless local_child

                child_children << local_child unless child_children.any? { |pc| pc[:name] == local_child[:name] }
                removed_local_names << local.name
              end
            end
          when AST::ConstDecl
            parent = name_index[decl.name]&.find { |s| symbol_line(s) == (decl.line || 0) }
            next unless parent

            if decl.respond_to?(:type) && (detail = type_detail_string(decl.type))
              parent[:detail] = detail
            end

            next unless decl.block_body

            locals = collect_local_decls(decl.block_body)
            next unless locals&.any?

            parent[:children] ||= []
            parent_children = parent[:children]
            locals.each do |local|
              next unless local.name

              child = local_decl_symbol(local)
              next unless child

              parent_children << child unless parent_children.any? { |pc| pc[:name] == child[:name] }
              removed_local_names << local.name
            end
          else
            parent_name = child_parent_name(decl)
            parent = parent_name ? name_index[parent_name]&.find { |s| symbol_line(s) == (decl.line || 0) } : nil
            next unless parent

            if decl.is_a?(AST::StructDecl) && decl.implements&.any?
              ifaces = decl.implements.map { |i|
                base = i.respond_to?(:parts) ? i.parts.join('.') : i.name.parts.join('.')
                type_args = i.respond_to?(:type_arguments) ? i.type_arguments : i.respond_to?(:arguments) ? i.arguments : []
                args = if type_args&.any?
                         arg_strs = type_args.map { |a| a.respond_to?(:name) ? a.name.parts.join('.') : a.respond_to?(:parts) ? a.parts.join('.') : a.to_s }
                         "[#{arg_strs.join(', ')}]"
                       else
                         ""
                       end
                "#{base}#{args}"
              }.join(', ')
              parent[:detail] = "(#{ifaces})"
            end

            children = child_symbols_for(decl)
            next unless children&.any?

            parent[:children] ||= []
            parent_children = parent[:children]
            children.each do |c|
              next if parent_children.any? { |pc| pc[:name] == c[:name] }

              parent_children << c
              case c[:kind]
              when 6 then removed_method_names << c[:name]
              when 23 then removed_nested_type_names << c[:name]
              end
            end
          end
        end

        if removed_local_names.any?
          removed_set = removed_local_names.to_set
          symbols.reject! { |s| s[:kind] == 13 && removed_set.include?(s[:name]) }
        end
        if removed_method_names.any?
          removed_set = removed_method_names.to_set
          symbols.reject! { |s| (s[:kind] == 6 || s[:kind] == 12) && removed_set.include?(s[:name]) }
        end
        if removed_nested_type_names.any?
          removed_set = removed_nested_type_names.to_set
          symbols.reject! { |s| s[:kind] == 23 && removed_set.include?(s[:name]) && (!s[:children] || s[:children].empty?) }
        end

        symbols
      end

      def symbol_line(symbol)
        symbol.dig(:range, :start, :line)&.+ 1 || 0
      end

      def child_parent_name(decl)
        case decl
        when AST::StructDecl then decl.name
        when AST::UnionDecl then decl.name
        when AST::EnumDecl then decl.name
        when AST::FlagsDecl then decl.name
        when AST::VariantDecl then decl.name
        when AST::InterfaceDecl then decl.name
        when AST::ExtendingBlock then decl.type_name.name.parts.join('.')
        else nil
        end
      end

      def child_symbols_for(decl)
        case decl
        when AST::StructDecl
          field_children = (decl.fields&.map { |f| child_field_symbol(f) } || []).compact
          nested_children = (decl.nested_types&.map { |n| child_nested_struct_symbol(n) } || []).compact
          field_children + nested_children
        when AST::UnionDecl
          (decl.fields&.map { |f| child_field_symbol(f) } || []).compact
        when AST::EnumDecl, AST::FlagsDecl
          (decl.members&.map { |m| child_member_symbol(m, default_line: decl.line) } || []).compact
        when AST::VariantDecl
          (decl.arms&.map { |a| child_variant_arm_symbol(a, default_line: decl.line) } || []).compact
        when AST::InterfaceDecl
          (decl.methods&.map { |m| child_method_symbol(m) } || []).compact
        when AST::ExtendingBlock
          (decl.methods&.map { |m| child_method_symbol(m) } || []).compact
        else nil
        end
      end

      def child_nested_struct_symbol(nested)
        return nil unless nested.respond_to?(:name) && nested.name && nested.respond_to?(:line) && nested.line

        grandchildren = child_symbols_for(nested)
        {
          name: nested.name, kind: 23,
          range: { start: { line: nested.line - 1, character: 0 }, end: { line: nested.line, character: 0 } },
          selectionRange: {
            start: { line: nested.line - 1, character: (nested.respond_to?(:column) && nested.column ? nested.column - 1 : 0) },
            end: { line: nested.line - 1, character: (nested.respond_to?(:column) && nested.column ? nested.column - 1 + nested.name.length : 0) },
          },
        }.tap { |s| s[:children] = grandchildren if grandchildren&.any? }
      end

      def collect_nested_type_names(decl)
        names = []
        decl.nested_types.each do |nested|
          names << nested.name
          names.concat(collect_nested_type_names(nested))
        end
        names
      end

      def child_field_symbol(f)
        return nil unless f.respond_to?(:name) && f.name && f.respond_to?(:line) && f.line
        detail = f.respond_to?(:type) ? type_detail_string(f.type) : nil
        {
          name: f.name, kind: 8,
          detail: detail,
          range: { start: { line: f.line - 1, character: 0 }, end: { line: f.line, character: 0 } },
          selectionRange: {
            start: { line: f.line - 1, character: (f.respond_to?(:column) && f.column ? f.column - 1 : 0) },
            end: { line: f.line - 1, character: (f.respond_to?(:column) && f.column ? f.column - 1 + f.name.length : 0) },
          },
        }.compact
      end

      def child_member_symbol(m, default_line: nil)
        line = (m.respond_to?(:line) && m.line) ? m.line : default_line
        return nil unless m.respond_to?(:name) && m.name && line

        col = m.respond_to?(:column) && m.column ? m.column : 1
        {
          name: m.name, kind: 22,
          range: { start: { line: line - 1, character: 0 }, end: { line: line, character: 0 } },
          selectionRange: {
            start: { line: line - 1, character: col - 1 },
            end: { line: line - 1, character: col - 1 + m.name.length },
          },
        }
      end

      def child_variant_arm_symbol(a, default_line: nil)
        line = (a.respond_to?(:line) && a.line) ? a.line : default_line
        return nil unless a.respond_to?(:name) && a.name && line
        {
          name: a.name, kind: 22,
          range: { start: { line: line - 1, character: 0 }, end: { line: line, character: 0 } },
          selectionRange: {
            start: { line: line - 1, character: 0 },
            end: { line: line - 1, character: a.name.length },
          },
        }
      end

      def collect_local_decls(body)
        return [] unless body

        case body
        when Array
          body.flat_map { |stmt| collect_local_decls(stmt) }.compact
        when AST::LocalDecl
          [body]
        when AST::IfStmt
          (body.branches || []).flat_map { |b| collect_local_decls(b.body) } +
            collect_local_decls(body.else_body)
        when AST::WhileStmt
          collect_local_decls(body.body)
        when AST::ForStmt
          collect_local_decls(body.body)
        when AST::MatchStmt
          (body.arms || []).flat_map { |a| collect_local_decls(a.body) }
        when AST::DeferStmt
          collect_local_decls(body.body)
        when AST::UnsafeStmt
          collect_local_decls(body.body)
        when AST::WhenStmt
          (body.branches || []).flat_map { |b| collect_local_decls(b.body) } +
            collect_local_decls(body.else_body)
        when AST::ErrorBlockStmt
          collect_local_decls(body.body)
        else
          []
        end
      end

      def local_decl_symbol(decl)
        return nil unless decl.name

        line = decl.line || 0
        col = decl.column || 1
        detail = decl.respond_to?(:type) ? type_detail_string(decl.type) : nil
        {
          name: decl.name, kind: 13,
          detail: detail,
          range: { start: { line: line - 1, character: col - 1 }, end: { line: line - 1, character: col - 1 + decl.name.length } },
          selectionRange: { start: { line: line - 1, character: col - 1 }, end: { line: line - 1, character: col - 1 + decl.name.length } },
        }.compact
      end

      def child_method_symbol(m)
        return nil unless m.respond_to?(:name) && m.name && m.respond_to?(:line) && m.line
        detail = type_detail_string(m.return_type) ? "-> #{type_detail_string(m.return_type)}" : nil
        {
          name: m.name, kind: 6,
          range: { start: { line: m.line - 1, character: 0 }, end: { line: (m.respond_to?(:end_line) && m.end_line ? m.end_line : m.line), character: 0 } },
          selectionRange: {
            start: { line: m.line - 1, character: (m.respond_to?(:column) && m.column ? m.column - 1 : 0) },
            end: { line: m.line - 1, character: (m.respond_to?(:column) && m.column ? m.column - 1 + m.name.length : 0) },
          },
          detail: detail,
        }.compact
      end

      def type_detail_string(type)
        return nil unless type

        case type
        when AST::TypeRef
          type.name.parts.join('.')
        when AST::ProcType
          params = (type.params || []).map { |p| type_detail_string(p.type) }.join(', ')
          ret = type_detail_string(type.return_type) || 'void'
          "proc(#{params}) -> #{ret}"
        when AST::TupleType
          "(#{(type.element_types || []).map { |t| type_detail_string(t) }.join(', ')})"
        when AST::DynType
          "dyn[#{type.interface}]"
        end
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
