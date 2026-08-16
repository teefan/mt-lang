# frozen_string_literal: true

require "set"

module MilkTea
  module LSP
    class Server
      module ServerFormatting
        def handle_document_symbols(params)
          stages = new_perf_stages
          total_start = stages ? monotonic_time : nil
          uri = params['textDocument']['uri']
          symbols = measure_perf_stage(stages, 'symbols') { @workspace.get_symbols(uri) }
          result = measure_perf_stage(stages, 'format') { symbols.map { |sym| format_document_symbol(sym) } }

          # Enrich with hierarchical children from AST
          ast = @workspace.get_ast(uri)
          if ast && result
            facts = @workspace.get_facts(uri)
            enrich_with_children(result, ast, facts)
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

        def enrich_with_children(symbols, ast, facts)
          removed_local_names = []
          removed_method_names = []
          removed_nested_type_names = []
          removed_event_names = []
          name_index = symbols.each_with_object(Hash.new { |h, k| h[k] = [] }) { |s, h| h[s[:name]] << s }

          flatten_module_declarations(ast.declarations).each do |decl|
            removed_nested_type_names.concat(collect_nested_type_names(decl)) if decl.is_a?(AST::StructDecl)

            case decl
            when AST::VarDecl
              parent = name_index[decl.name]&.find { |s| symbol_line(s) == (decl.line || 0) }
              next unless parent

              detail = decl.type ? type_detail_string(decl.type) : nil
              detail ||= resolved_local_type_detail(decl, facts)
              parent[:detail] = detail if detail

            when AST::TypeAliasDecl
              parent = name_index[decl.name]&.find { |s| symbol_line(s) == (decl.line || 0) }
              next unless parent

              if (detail = type_detail_string(decl.target))
                parent[:detail] = "= #{detail}"
              end

            when AST::ExternFunctionDecl, AST::ForeignFunctionDecl
              parent = name_index[decl.name]&.find { |s| symbol_line(s) == (decl.line || 0) }
              next unless parent

              detail_parts = []
              detail_parts << 'async' if decl.respond_to?(:async) && decl.async
              detail_parts << "-> #{type_detail_string(decl.return_type) || 'void'}"
              parent[:detail] = detail_parts.join(' ')

            when AST::EventDecl
              parent = name_index[decl.name]&.find { |s| symbol_line(s) == (decl.line || 0) }
              next unless parent

              parts = ["event[#{decl.capacity}]"]
              parts << "(#{type_detail_string(decl.payload_type)})" if decl.payload_type
              parent[:detail] = parts.join

            when AST::FunctionDef
              parent = name_index[decl.name]&.find { |s| symbol_line(s) == (decl.line || 0) }
              next unless parent

              detail_parts = []
              detail_parts << 'const' if decl.respond_to?(:const) && decl.const
              detail_parts << 'async' if decl.respond_to?(:async) && decl.async
              detail_parts << "-> #{type_detail_string(decl.return_type) || 'void'}"
              parent[:detail] = detail_parts.join(' ')

              locals = collect_local_decls(decl.body)
              append_local_children(parent, locals, facts, removed_local_names)
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
                append_local_children(child, locals, facts, removed_local_names)
              end
            when AST::ConstDecl
              parent = name_index[decl.name]&.find { |s| symbol_line(s) == (decl.line || 0) }
              next unless parent

              if decl.respond_to?(:type) && (detail = type_detail_string(decl.type))
                parent[:detail] = detail
              end

              next unless decl.block_body

              locals = collect_local_decls(decl.block_body)
              append_local_children(parent, locals, facts, removed_local_names)
            else
              parent_name = child_parent_name(decl)
              parent = parent_name ? name_index[parent_name]&.find { |s| symbol_line(s) == (decl.line || 0) } : nil
              next unless parent

              detail_parts = []
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
                detail_parts << "(#{ifaces})"
              end

              if decl.respond_to?(:backing_type) && decl.backing_type && (bt = type_detail_string(decl.backing_type))
                detail_parts << ": #{bt}"
              end

              if (generic = generic_signature_detail(decl))
                detail_parts << generic
              end

              parent[:detail] = detail_parts.join(' ') unless detail_parts.empty?

              type_params = expand_generic_type_params(decl)
              if type_params&.any?
                parent[:children] ||= []
                parent_children = parent[:children]
                type_params.each do |tp|
                  child = type_param_child_symbol(tp)
                  next unless child
                  parent_children << child unless parent_children.any? { |pc| pc[:name] == child[:name] }
                end
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
                when 24 then removed_event_names << c[:name]
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
          if removed_event_names.any?
            removed_set = removed_event_names.to_set
            symbols.reject! { |s| s[:kind] == 24 && removed_set.include?(s[:name]) && (!s[:children] || s[:children].empty?) }
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
          when AST::OpaqueDecl then decl.name
          when AST::ExtendingBlock then decl.type_name.name.parts.join('.')
          else nil
          end
        end

        def child_symbols_for(decl)
          case decl
          when AST::StructDecl
            field_children = (decl.fields&.map { |f| child_field_symbol(f) } || []).compact
            nested_children = (decl.nested_types&.map { |n| child_nested_struct_symbol(n) } || []).compact
            event_children = (decl.events&.map { |e| child_event_symbol(e) } || []).compact
            field_children + nested_children + event_children
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
          return nil unless nested.respond_to?(:name) && nested.name && nested.line

          grandchildren = child_symbols_for(nested)
          {
            name: nested.name, kind: 23,
            range: { start: { line: nested.line - 1, character: 0 }, end: { line: nested.line, character: 0 } },
            selectionRange: {
              start: { line: nested.line - 1, character: (nested.column ? nested.column - 1 : 0) },
              end: { line: nested.line - 1, character: (nested.column ? nested.column - 1 + nested.name.length : 0) },
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
          return nil unless f.respond_to?(:name) && f.name && f.line
          detail = f.respond_to?(:type) ? type_detail_string(f.type) : nil
          {
            name: f.name, kind: 8,
            detail: detail,
            range: { start: { line: f.line - 1, character: 0 }, end: { line: f.line, character: 0 } },
            selectionRange: {
              start: { line: f.line - 1, character: (f.column ? f.column - 1 : 0) },
              end: { line: f.line - 1, character: (f.column ? f.column - 1 + f.name.length : 0) },
            },
          }.compact
        end

        def child_event_symbol(e)
          return nil unless e.respond_to?(:name) && e.name && e.line

          parts = ["event[#{e.capacity}]"]
          parts << "(#{type_detail_string(e.payload_type)})" if e.respond_to?(:payload_type) && e.payload_type

          {
            name: e.name, kind: 24,
            detail: parts.join,
            range: { start: { line: e.line - 1, character: 0 }, end: { line: e.line, character: 0 } },
            selectionRange: {
              start: { line: e.line - 1, character: (e.column ? e.column - 1 : 0) },
              end: { line: e.line - 1, character: (e.column ? e.column - 1 + e.name.length : 0) },
            },
          }
        end

        def child_member_symbol(m, default_line: nil)
          line = (m.line) ? m.line : default_line
          return nil unless m.respond_to?(:name) && m.name && line

          col = m.column ? m.column : 1
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
          line = (a.line) ? a.line : default_line
          return nil unless a.respond_to?(:name) && a.name && line
          col = a.column ? a.column : 1

          detail = nil
          if a.respond_to?(:fields) && a.fields&.any?
            fields = a.fields.map { |f| "#{f.name}: #{type_detail_string(f.type)}" }.join(', ')
            detail = "(#{fields})"
          end

          {
            name: a.name, kind: 22,
            detail: detail,
            range: { start: { line: line - 1, character: 0 }, end: { line: line, character: 0 } },
            selectionRange: {
              start: { line: line - 1, character: col - 1 },
              end: { line: line - 1, character: col - 1 + a.name.length },
            },
          }.compact
        end

        # Renders the generic parameter clause of a type declaration, e.g.
        # `[A, B]` for `struct Pair[A, B]` or `[@a]` for `struct Buffer[@a]`.
        def generic_signature_detail(decl)
          parts = []
          if decl.respond_to?(:lifetime_params) && decl.lifetime_params&.any?
            parts.concat(decl.lifetime_params.map(&:to_s))
          end
          if decl.respond_to?(:type_params) && decl.type_params&.any?
            parts.concat(decl.type_params.map { |tp| tp.respond_to?(:name) ? tp.name : tp.to_s })
          end
          parts.empty? ? nil : "[#{parts.join(', ')}]"
        end

        # Module-level `when` branches are compile-time conditionals; the token
        # symbol scan lists their declarations, so flatten the branch bodies so
        # the enrichment below can type them like ordinary top-level decls.
        def flatten_module_declarations(declarations)
          (declarations || []).flat_map do |decl|
            if decl.is_a?(AST::WhenStmt)
              (decl.branches || []).flat_map { |b| flatten_module_declarations(b.body) } +
                flatten_module_declarations(decl.else_body)
            else
              [decl]
            end
          end
        end

        # Adds local declaration children to an outline symbol. Destructure
        # locals (`let Vec2(x, y) = ...`) introduce a spurious flat variable
        # symbol named after the destructure type; that symbol is collected for
        # removal instead of being shown as a typed child.
        def append_local_children(container, locals, facts, removed_local_names)
          return unless locals&.any?

          container[:children] ||= []
          children = container[:children]
          locals.each do |local|
            if local.respond_to?(:destructure_bindings) && local.destructure_bindings
              type_name = local.destructure_type_name
              if type_name
                name = type_name.is_a?(Array) ? type_name.join('.') : type_name.to_s
                removed_local_names << name unless removed_local_names.include?(name)
              end
              next
            end
            next unless local.name

            child = local_decl_symbol(local, facts:)
            next unless child

            children << child unless children.any? { |pc| pc[:name] == child[:name] }
            removed_local_names << local.name
            removed_local_names.concat(descendant_names(child))
          end
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
            collect_local_decls(body.body) + body.bindings
          when AST::MatchStmt
            (body.arms || []).flat_map { |arm| collect_local_decls(arm.body) }
          when AST::ParallelBlockStmt
            (body.bodies || []).flat_map { |b| collect_local_decls(b) }
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

        def local_decl_symbol(decl, facts: nil)
          return nil unless decl.name
          return nil if decl.name == '_'

          line = decl.line || 0
          col = decl.column || 1
          detail = decl.respond_to?(:type) ? type_detail_string(decl.type) : nil

          children = []
          if decl.respond_to?(:value) && decl.value.is_a?(AST::ProcExpr)
            detail ||= proc_signature_detail(decl.value)
            proc_locals = collect_local_decls(decl.value.body)
            children = proc_locals.filter_map { |l| local_decl_symbol(l, facts:) }
          end
          detail ||= resolved_local_type_detail(decl, facts)

          {
            name: decl.name, kind: 13,
            detail: detail,
            range: { start: { line: line - 1, character: col - 1 }, end: { line: line - 1, character: col - 1 + decl.name.length } },
            selectionRange: { start: { line: line - 1, character: col - 1 }, end: { line: line - 1, character: col - 1 + decl.name.length } },
            children: children.any? ? children : nil,
          }.compact
        end

        # Resolves the declared type of an inferred local from semantic facts.
        # Prefers the sema binding type (which reflects let/var ... else: and
        # other flow refinement), falling back to the initializer expression
        # type recorded during checking. Returns nil when facts are unavailable
        # or the binding is missing.
        def resolved_local_type_detail(decl, facts)
          return nil unless facts
          return nil unless facts.respond_to?(:binding_resolution) && facts.binding_resolution

          binding_id = facts.binding_resolution.declaration_binding_ids[decl.object_id]
          if binding_id
            type = facts.binding_resolution.binding_types[binding_id]
            return nil if type.is_a?(Types::Error)
            return short_type_detail(type) if type
          end

          return nil unless decl.respond_to?(:value) && decl.value
          return nil unless facts.respond_to?(:resolved_expr_types)

          node_id = facts.respond_to?(:ast) && facts.ast ? facts.ast.node_ids[decl.value.object_id] : nil
          return nil unless node_id

          type = facts.resolved_expr_types[node_id]
          return nil if type.is_a?(Types::Error)

          short_type_detail(type)
        end

        # Renders a resolved semantic type for outline display without module
        # qualifiers (e.g. std.deque.Deque[int] as Deque[int]). Falls back to
        # the canonical #to_s when a type has no usable short form.
        def short_type_detail(type)
          return nil unless type

          case type
          when Types::Nullable
            "#{short_type_detail(type.base)}?"
          when Types::Span
            "span[#{short_type_detail(type.element_type)}]"
          when Types::SoA
            "SoA[#{short_type_detail(type.element_type)}, #{type.count}]"
          when Types::StructInstance, Types::VariantInstance, Types::GenericInstance
            args = type.arguments.map { |arg| short_type_arg(arg) }.join(', ')
            args.empty? ? type.name : "#{type.name}[#{args}]"
          else
            name = type.respond_to?(:name) ? type.name.to_s : ''
            name.empty? ? type.to_s : name
          end
        end

        def short_type_arg(arg)
          arg.is_a?(Types::LiteralTypeArg) ? arg.value.to_s : short_type_detail(arg)
        end

        def descendant_names(symbol)
          return [] unless symbol[:children]

          symbol[:children].flat_map { |c| [c[:name]] + descendant_names(c) }
        end

        def expand_generic_type_params(decl)
          return [] unless decl.respond_to?(:type_params) && decl.type_params

          decl.type_params.flat_map do |tp|
            if tp.respond_to?(:type_params) && tp.type_params&.any?
              expand_generic_type_params(tp)
            else
              [tp]
            end
          end
        end

        def type_param_child_symbol(tp)
          return nil unless tp.respond_to?(:name) && tp.name
          return nil unless tp.line

          col = tp.column ? tp.column : 1
          {
            name: tp.name, kind: 26,
            range: { start: { line: tp.line - 1, character: col - 1 }, end: { line: tp.line - 1, character: col - 1 + tp.name.length } },
            selectionRange: {
              start: { line: tp.line - 1, character: col - 1 },
              end: { line: tp.line - 1, character: col - 1 + tp.name.length },
            },
          }
        end

        def proc_signature_detail(proc_expr)
          params = proc_expr.params&.map { |p| "#{p.name}: #{type_detail_string(p.type)}" }&.join(', ') || ''
          ret = type_detail_string(proc_expr.return_type) || 'void'
          "proc(#{params}) -> #{ret}"
        end

        def child_method_symbol(m)
          return nil unless m.respond_to?(:name) && m.name && m.line

          detail_parts = []
          detail_parts << 'mut' if m.respond_to?(:kind) && m.kind == :editable_function
          detail_parts << 'static' if m.respond_to?(:kind) && m.kind == :static_function
          detail_parts << 'async' if m.respond_to?(:async) && m.async
          detail_parts << "-> #{type_detail_string(m.return_type) || 'void'}"
          {
            name: m.name, kind: 6,
            range: { start: { line: m.line - 1, character: 0 }, end: { line: (m.respond_to?(:end_line) && m.end_line ? m.end_line : m.line), character: 0 } },
            selectionRange: {
              start: { line: m.line - 1, character: (m.column ? m.column - 1 : 0) },
              end: { line: m.line - 1, character: (m.column ? m.column - 1 + m.name.length : 0) },
            },
            detail: detail_parts.empty? ? nil : detail_parts.join(' '),
          }.compact
        end

        def type_detail_string(type)
          return nil unless type

          case type
          when AST::TypeRef
            type.to_s
          when AST::FunctionType, AST::ProcType
            params = (type.params || []).map { |p| type_detail_string(p.type) }.join(', ')
            ret = type_detail_string(type.return_type) || 'void'
            keyword = type.is_a?(AST::FunctionType) ? 'fn' : 'proc'
            "#{keyword}(#{params}) -> #{ret}"
          when AST::TupleType
            base = "(#{(type.element_types || []).map { |t| type_detail_string(t) }.join(', ')})"
            type.nullable ? "#{base}?" : base
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
