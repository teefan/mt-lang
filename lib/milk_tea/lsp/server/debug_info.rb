# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerDebugInfo
        private

        # AST node types rendered as compact single-line (no subtree expansion).
        COMPACT_AST_TYPES = %w[
          QualifiedName TypeRef TypeArgument Identifier
          IntegerLiteral FloatLiteral StringLiteral BooleanLiteral NullLiteral
          FormatString FormatTextPart FormatExprPart
        ].to_set.freeze

        def handle_debug_info(params)
          uri = params.dig('textDocument', 'uri')
          return { text: 'error: no textDocument.uri' } unless uri

          sections = []
          sections << format_header(uri)
          sections << format_tokens(uri)
          sections << format_ast(uri)
          sections << format_parse_errors(uri)
          sections << format_facts(uri)
          sections << format_bindings(uri)
          sections << format_diagnostics(uri)

          { text: sections.join("\n\n") }
        rescue StandardError => e
          { text: "error generating debug info: #{e.message}\n#{e.backtrace.first(5).join("\n")}" }
        end

        def format_header(uri)
          content = @workspace.get_content(uri)
          path = uri_to_path(uri) || uri
          lines = content.count("\n") + 1
          bytes = content.bytesize
          ["File: #{path}", "Content: #{lines} lines, #{bytes} bytes"].join("\n")
        end

        # ── Tokens ─────────────────────────────────────────────────────────────────

        def format_tokens(uri)
          toks = @workspace.get_tokens(uri)
          return '── Tokens (0) ──' unless toks

          lines = ["── Tokens (#{toks.length}) " + '─' * 50]

          max_len = toks.reject { |t| [:newline, :indent, :dedent].include?(t.type) }
                       .map { |t| t.lexeme.length }
                       .max || 0
          max_len = [max_len, 28].min

          toks.each do |tok|
            lex = tok.lexeme.inspect
            type_str = tok.type.to_s
            end_col = tok.type == :eof ? tok.column : tok.column + tok.lexeme.length - 1
            loc = "Ln #{tok.line.to_s.rjust(2)}  Col #{tok.column.to_s.rjust(3)}-#{end_col}"
            lines << format('  %3d:%-3d  %-*s  %-16s  %s  %s',
                            tok.line, tok.column,
                            max_len + 2, lex,
                            type_str,
                            loc,
                            (tok.type == :eof ? '◄' : ''))
          end

          lines.join("\n")
        end

        # ── AST ─────────────────────────────────────────────────────────────────────

        def format_ast(uri)
          ast = @workspace.get_ast(uri)
          return '── AST ── (not available)' unless ast

          buf = ['── AST ── ' + '─' * 70]
          format_ast_node(ast, prefix: '', is_last: true, buf: buf)
          buf.join("\n")
        end

        def format_ast_node(node, prefix:, is_last:, buf:)
          return if node.nil?

          if node.is_a?(Array)
            node.each_with_index do |item, i|
              format_ast_node(item, prefix: prefix, is_last: i == node.length - 1, buf: buf)
            end
            return
          end

          unless ast_node?(node)
            buf << "#{prefix}#{is_last ? '└─ ' : '├─ '}#{value_repr(node)}"
            return
          end

          if compact_ast_node?(node)
            buf << "#{prefix}#{is_last ? '└─ ' : '├─ '}#{compact_ast_repr(node)}"
            return
          end

          connector = is_last ? '└─ ' : '├─ '
          header = ast_node_header(node)
          buf << "#{prefix}#{connector}#{header}"

          child_prefix = is_last ? '   ' : '│  '

          if node.respond_to?(:members)
            active = node.members.select { |m| m.is_a?(Symbol) }
            active -= %i[line column length module_kind visibility name] # omit noise

            active.each_with_index do |member, i|
              child = node.public_send(member)
              next if skip_child_value?(child)

              child_is_last = active.drop(i + 1).none? { |m| keep_child?(node.public_send(m)) }

              if is_array_of_ast_nodes?(child)
                label = "#{symbol_icon(child.length)} #{member} (#{child.length})"
                label += ':' if child.length > 0
                buf << "#{prefix}#{child_prefix}#{child_is_last ? '└─ ' : '├─ '}#{label}"
                child.each_with_index do |item, j|
                  format_ast_node(item, prefix: prefix + child_prefix + (child_is_last ? '   ' : '│  '),
                                  is_last: j == child.length - 1, buf: buf)
                end
              elsif child.is_a?(Array)
                label = "#{symbol_icon(child.length)} #{member} (#{child.length})"
                label += "  #{compact_array_repr(child)}" if simple_value_array?(child)
                buf << "#{prefix}#{child_prefix}#{child_is_last ? '└─ ' : '├─ '}#{label}"
              elsif ast_node?(child)
                if compact_ast_node?(child)
                  buf << "#{prefix}#{child_prefix}#{child_is_last ? '└─ ' : '├─ '}#{member}: #{compact_ast_repr(child)}"
                else
                  format_ast_node(child, prefix: prefix + child_prefix, is_last: child_is_last, buf: buf)
                end
              else
                buf << "#{prefix}#{child_prefix}#{child_is_last ? '└─ ' : '├─ '}#{member}: #{value_repr(child)}"
              end
            end
          end
        end

        def compact_ast_node?(node)
          COMPACT_AST_TYPES.include?(node.class.name.split('::').last)
        end

        def type_arg_str(arg)
          return value_repr(arg) unless arg.respond_to?(:value)

          val = arg.value
          if ast_node?(val) && compact_ast_node?(val)
            compact_ast_repr(val)
          else
            value_repr(val)
          end
        end

        def compact_ast_repr(node)
          kind = node.class.name.split('::').last
          case kind
          when 'QualifiedName'
            path = node.parts.join('.')
            path = "#{path}<#{node.type_arguments.map { |a| compact_ast_repr(a.value) }.join(', ')}>" unless node.type_arguments.empty?
            "QualifiedName(#{path})"
          when 'TypeRef'
            name = node.name
            args = node.arguments.map { |a| type_arg_str(a) }.join(', ')
            name = "#{name}[#{args}]" unless args.empty?
            name = "?#{name}" if node.nullable
            name
          when 'TypeArgument'
            "TypeArg(#{compact_ast_repr(node.value)})"
          when 'Identifier'
            "id:#{node.name}"
          when 'StringLiteral'
            node.value.inspect
          when 'IntegerLiteral'
            node.value.to_s
          when 'FloatLiteral'
            node.value.to_s
          when 'BooleanLiteral'
            node.value.to_s
          when 'NullLiteral'
            'null'
          when 'FormatString'
            "f#{node.parts.map { |p| value_repr(p) }.join}"
          when 'FormatTextPart'
            node.value.inspect
          when 'FormatExprPart'
            "{#{node.expression.respond_to?(:name) ? node.expression.name : 'expr'}}"
          else
            kind
          end
        end

        def compact_array_repr(arr)
          arr.map { |e| value_repr(e) }.join(', ')
        end

        def simple_value_array?(arr)
          arr.all? { |e| e.is_a?(String) || e.is_a?(Symbol) || e.is_a?(Numeric) || e.nil? }
        end

        def ast_node_header(node)
          name_attr = node.respond_to?(:name) ? node.name : nil
          loc = if node.respond_to?(:line) && node.line
                  col = node.respond_to?(:column) && node.column ? ", Col #{node.column}" : ''
                  " [Ln #{node.line}#{col}]"
                else
                  ''
                end
          kind = node.class.name.split('::').last
          if name_attr
            "#{kind} ◆ #{name_attr}#{loc}"
          else
            "#{kind}#{loc}"
          end
        end

        def ast_node?(val)
          val.class.name.to_s.start_with?('MilkTea::AST::')
        rescue StandardError
          false
        end

        def is_array_of_ast_nodes?(val)
          val.is_a?(Array) && val.any? { |e| ast_node?(e) }
        end

        def skip_child_value?(val)
          val.nil? || val == false || val == [] || val == {} || val == :private
        end

        def keep_child?(val)
          return false if skip_child_value?(val)
          return true if val.is_a?(Array) && val.any?
          return true if ast_node?(val) || val.class.name.to_s.start_with?('MilkTea::')

          true
        end

        def symbol_icon(count)
          count > 0 ? '◆' : '◇'
        end

        def value_repr(val)
          case val
          when nil then 'nil'
          when true then 'true'
          when false then 'false'
          when String then val.length < 60 ? val.inspect : "#{val[0..56].inspect}..."
          when Integer, Float then val.to_s
          when Symbol then ":#{val}"
          when Array
            if val.empty?
              '[]'
            else
              "[#{val.length}]"
            end
          when Hash then "{#{val.length} entries}"
          else
            klass = val.class.name&.split('::')&.last || val.class.to_s
            if val.respond_to?(:name) && val.name
              "#{klass}(#{value_repr(val.name)})"
            elsif val.respond_to?(:to_s) && val.method(:to_s).owner != Object
              s = val.to_s
              s.length < 60 ? s : "#{s[0..56]}..."
            else
              klass
            end
          end
        end

        # ── Parse Errors ─────────────────────────────────────────────────────────────

        def format_parse_errors(uri)
          content = @workspace.get_content(uri)
          return '── Parse Errors ── (no content)' if content.empty?

          result = MilkTea::Parser.parse_collecting_errors(content, path: uri)
          errors = result.errors
          return '── Parse Errors (0) ──' if errors.nil? || errors.empty?

          buf = ["── Parse Errors (#{errors.length}) ── " + '─' * 55]
          errors.each do |e|
            line = e.respond_to?(:line) ? e.line : '?'
            col = e.respond_to?(:column) ? e.column : '?'
            buf << "  ERROR [Ln #{line}, Col #{col}]: #{e.message}"
          end
          buf.join("\n")
        rescue StandardError => e
          "── Parse Errors ── (error: #{e.message})"
        end

        # ── Facts ────────────────────────────────────────────────────────────────────

        def format_facts(uri)
          facts = @workspace.get_facts(uri)
          return '── Facts ── (not available)' unless facts

          buf = ['── Facts ── ' + '─' * 70]
          buf << "  module_name: #{facts.module_name.inspect}    module_kind: #{facts.module_kind.inspect}"

          unless facts.types.empty?
            buf << ''
            buf << '  Types:'
            facts.types.each do |name, type|
              buf << "    #{name.ljust(20)} → #{type_repr(type)}"
            end
          end

          unless facts.interfaces.empty?
            buf << ''
            buf << '  Interfaces:'
            facts.interfaces.each do |name, iface|
              methods = iface.respond_to?(:methods) ? iface.methods.keys.join(', ') : '?'
              buf << "    #{name}  [methods: #{methods}]"
            end
          end

          unless facts.functions.empty?
            buf << ''
            buf << '  Functions:'
            facts.functions.each do |name, binding|
              buf.concat(format_function_binding(name, binding, indent: '    '))
            end
          end

          unless facts.values.empty?
            buf << ''
            buf << '  Values:'
            facts.values.each do |name, binding|
              buf << "    #{name.ljust(20)} → #{value_binding_repr(binding)}"
            end
          end

          unless facts.methods.empty?
            buf << ''
            buf << '  Methods:'
            facts.methods.each do |receiver_type, methods|
              buf << "    on #{type_repr(receiver_type)}:"
              methods.each do |name, binding|
                buf.concat(format_function_binding(name, binding, indent: '      '))
              end
            end
          end

          unless facts.imports.empty?
            buf << ''
            buf << '  Imports:'
            facts.imports.each do |import_name, module_binding|
              symbol_count = (module_binding.types.length +
                              module_binding.functions.length +
                              module_binding.values.length)
              buf << "    #{import_name.ljust(24)} → ModuleBinding (exported symbols: #{symbol_count})"
            end
          end

          buf << ''
          buf << "  local_completion_frames: #{facts.local_completion_frames.length}"
          buf << "  callable_value_identifier_sites: #{facts.callable_value_identifier_sites.length}"
          buf << "  callable_value_member_access_sites: #{facts.callable_value_member_access_sites.length}"
          buf << "  required_unsafe_lines: #{facts.required_unsafe_lines.inspect}"

          buf.join("\n")
        end

        def format_function_binding(name, binding, indent:)
          buf = []
          buf << "#{indent}#{name}"
          buf << "#{indent}  type: #{type_repr(binding.type)}"
          unless binding.body_params.empty?
            buf << "#{indent}  params (#{binding.body_params.length}):"
            binding.body_params.each do |param|
              buf << "#{indent}    #{value_binding_repr(param)}"
            end
          end
          buf << "#{indent}  return_type: #{type_repr(binding.body_return_type)}" if binding.body_return_type
          buf << "#{indent}  external: #{binding.external}"
          buf << "#{indent}  async: #{binding.async}"
          buf << "#{indent}  const: #{binding.ast.respond_to?(:const) ? binding.ast.const : false}" if binding.ast
          buf << "#{indent}  ast: #{ast_node_header(binding.ast)}" if binding.ast
          buf << "#{indent}  instances: #{binding.instances.length}" unless binding.instances.empty?
          unless binding.type_params.empty?
            buf << "#{indent}  type_params (#{binding.type_params.length}):"
            binding.type_params.each do |tp|
              buf << "#{indent}    #{value_repr(tp)}"
            end
          end
          buf
        end

        def type_repr(type)
          return 'nil' unless type
          return type.to_s if type.respond_to?(:to_s)

          type.class.name&.split('::')&.last || type.class.to_s
        end

        def value_binding_repr(vb)
          mutable = vb.mutable ? 'mut' : '  '
          kind = vb.kind.to_s
          type = vb.flow_type || vb.storage_type
          type_str = type_repr(type)
          "ValueBinding[id: #{vb.id}] #{mutable} #{kind.ljust(6)} #{vb.name}: #{type_str}"
        end

        # ── Bindings ─────────────────────────────────────────────────────────────────

        def format_bindings(uri)
          facts = @workspace.get_facts(uri)
          return '── Binding Resolution ── (not available)' unless facts&.binding_resolution

          res = facts.binding_resolution
          buf = ['── Binding Resolution ── ' + '─' * 60]

          unless res.identifier_binding_ids.empty?
            buf << "  identifier_binding_ids (#{res.identifier_binding_ids.length}):"
            res.identifier_binding_ids.take(30).each do |node_id, binding_id|
              buf << "    obj #{node_id} → binding_id: #{binding_id}"
            end
            if res.identifier_binding_ids.length > 30
              buf << "    ... (#{res.identifier_binding_ids.length - 30} more)"
            end
          end

          unless res.declaration_binding_ids.empty?
            buf << "  declaration_binding_ids (#{res.declaration_binding_ids.length}):"
            res.declaration_binding_ids.take(30).each do |node_id, binding_id|
              buf << "    obj #{node_id} → binding_id: #{binding_id}"
            end
            if res.declaration_binding_ids.length > 30
              buf << "    ... (#{res.declaration_binding_ids.length - 30} more)"
            end
          end

          if res.respond_to?(:binding_types) && !res.binding_types.empty?
            buf << "  binding_types (#{res.binding_types.length}):"
            res.binding_types.each do |binding_id, type|
              buf << "    binding_id: #{binding_id} → #{type_repr(type)}"
            end
          end

          buf.join("\n")
        end

        # ── Diagnostics ──────────────────────────────────────────────────────────────

        def format_diagnostics(uri)
          snapshot = @workspace.get_tooling_snapshot(uri)
          return '── Diagnostics ── (not available)' unless snapshot

          diags = snapshot.diagnostics
          return '── Diagnostics (0) ──' if diags.nil? || diags.empty?

          buf = ["── Diagnostics (#{diags.length}) ── " + '─' * 55]
          diags.each do |d|
            severity = d.respond_to?(:severity) ? d.severity.to_s.upcase : '?'
            code = d.respond_to?(:code) ? d.code : '?'
            line = d.respond_to?(:line) ? d.line : '?'
            col = d.respond_to?(:column) ? d.column : '?'
            msg = d.respond_to?(:message) ? d.message : d.to_s
            buf << "  #{severity[0]} #{severity.ljust(7)} #{code} [Ln #{line}, Col #{col}]: #{msg}"
          end
          buf.join("\n")
        end
      end
    end
  end
end
