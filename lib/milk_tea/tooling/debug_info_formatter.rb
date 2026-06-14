# frozen_string_literal: true

module MilkTea
  module DebugInfoFormatter
    # AST node types rendered as compact single-line (no subtree expansion).
    COMPACT_AST_TYPES = %w[
      QualifiedName TypeRef TypeArgument Identifier
      IntegerLiteral FloatLiteral StringLiteral BooleanLiteral NullLiteral
      FormatString FormatTextPart FormatExprPart
    ].to_set.freeze

    module_function

    def format_all(content:, tokens:, ast:, parse_errors:, facts:, snapshot:, path:, semantic_entries: nil)
      sections = []
      sections << format_header(content, path)
      sections << format_tokens(tokens, semantic_entries:)
      sections << format_ast(ast)
      sections << format_parse_errors(parse_errors)
      sections << format_facts(facts)
      sections << format_bindings(facts)
      sections << format_diagnostics(snapshot)
      sections.join("\n\n")
    end

    # ── Header ────────────────────────────────────────────────────────────────────

    def format_header(content, path)
      lines = content.count("\n") + 1
      bytes = content.bytesize
      ["File: #{path}", "Content: #{lines} lines, #{bytes} bytes"].join("\n")
    end

    # ── Tokens ─────────────────────────────────────────────────────────────────────

    def format_tokens(tokens, semantic_entries: nil)
      return '── Tokens  0 ──' if tokens.nil? || tokens.empty?

      max_len = tokens.reject { |t| [:newline, :indent, :dedent].include?(t.type) }
                     .map { |t| t.lexeme.length }
                     .max || 0
      max_len = [max_len, 28].min

      type_counts = tokens.group_by(&:type).transform_values(&:length).sort_by { |_k, v| -v }
      summary = type_counts.map { |t, n| "#{n} #{t}" }.join(', ')

      sema_map = build_sema_map(semantic_entries)

      lines = ["── Tokens  #{tokens.length}  (#{summary}) " + '─' * 50]
      tokens.each do |tok|
        lex = tok.lexeme.inspect
        type_str = tok.type.to_s
        end_col = tok.type == :eof ? tok.column : tok.column + tok.lexeme.length - 1
        loc = "Ln #{tok.line.to_s.rjust(2)}  Col #{tok.column.to_s.rjust(3)}-#{end_col}"
        sema_col = if sema_map.any?
                     entry = sema_map[[tok.line, tok.column]]
                     entry ? "#{entry[:type]}#{entry[:modifiers].any? ? " (#{entry[:modifiers].join(',')})" : ''}" : ''
                   else
                     ''
                   end
        lines << format('  %3d:%-3d  %-*s  %-16s  %s  %-22s  %s',
                        tok.line, tok.column,
                        max_len + 2, lex,
                        type_str,
                        loc,
                        sema_col,
                        (tok.type == :eof ? '◄' : ''))
      end
      lines.join("\n")
    end

    def build_sema_map(entries)
      return {} unless entries.is_a?(Array) && !entries.empty?

      entries.each_with_object({}) do |e, map|
        key = [e[:line] + 1, e[:start_char] + 1]
        map[key] = e
      end
    end

    # ── AST ────────────────────────────────────────────────────────────────────────

    def format_ast(ast)
      return '── AST  (not available) ──' unless ast

      counts = %w[imports directives declarations].filter_map do |m|
        child = ast.public_send(m) if ast.respond_to?(m)
        "#{child.length} #{m}" if child
      end
      summary = counts.any? ? counts.join(', ') : ''
      buf = ["── AST  1 SourceFile, #{summary} " + '─' * 50]
      format_ast_node(ast, prefix: '', is_last: true, buf: buf)
      buf.join("\n")
    end

    def format_ast_node(node, prefix:, is_last:, buf:)
      return if node.nil?

      if node.is_a?(Array)
        node.each_with_index { |item, i| format_ast_node(item, prefix:, is_last: i == node.length - 1, buf:) }
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
        active -= %i[line column length module_kind visibility name]

        active.each_with_index do |member, i|
          child = node.public_send(member)
          next if skip_child_value?(child)

          child_is_last = active.drop(i + 1).none? { |m| keep_child?(node.public_send(m)) }

          if array_of_ast_nodes?(child)
            label = "#{symbol_icon(child.length)} #{member} (#{child.length})"
            label += ':' if child.length > 0
            buf << "#{prefix}#{child_prefix}#{child_is_last ? '└─ ' : '├─ '}#{label}"
            child.each_with_index do |item, j|
              format_ast_node(item, prefix: prefix + child_prefix + (child_is_last ? '   ' : '│  '),
                              is_last: j == child.length - 1, buf:)
            end
          elsif child.is_a?(Array)
            extra = simple_value_array?(child) ? "  #{compact_array_repr(child)}" : ''
            label = "#{symbol_icon(child.length)} #{member} (#{child.length})#{extra}"
            buf << "#{prefix}#{child_prefix}#{child_is_last ? '└─ ' : '├─ '}#{label}"
          elsif ast_node?(child)
            if compact_ast_node?(child)
              buf << "#{prefix}#{child_prefix}#{child_is_last ? '└─ ' : '├─ '}#{member}: #{compact_ast_repr(child)}"
            else
              format_ast_node(child, prefix: prefix + child_prefix, is_last: child_is_last, buf:)
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

    def compact_ast_repr(node)
      kind = node.class.name.split('::').last
      case kind
      when 'QualifiedName'
        path = node.parts.join('.')
        unless node.type_arguments.empty?
          args = node.type_arguments.map { |a| type_arg_str(a) }.join(', ')
          path = "#{path}<#{args}>"
        end
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

    def type_arg_str(arg)
      return value_repr(arg) unless arg.respond_to?(:value)

      val = arg.value
      ast_node?(val) && compact_ast_node?(val) ? compact_ast_repr(val) : value_repr(val)
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
      name_attr ? "#{kind} ◆ #{name_attr}#{loc}" : "#{kind}#{loc}"
    end

    def ast_node?(val)
      val.class.name.to_s.start_with?('MilkTea::AST::')
    rescue StandardError
      false
    end

    def array_of_ast_nodes?(val)
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

    def compact_array_repr(arr)
      arr.map { |e| value_repr(e) }.join(', ')
    end

    def simple_value_array?(arr)
      arr.all? { |e| e.is_a?(String) || e.is_a?(Symbol) || e.is_a?(Numeric) || e.nil? }
    end

    def value_repr(val)
      case val
      when nil then 'nil'
      when true then 'true'
      when false then 'false'
      when String then val.length < 60 ? val.inspect : "#{val[0..56].inspect}..."
      when Integer, Float then val.to_s
      when Symbol then ":#{val}"
      when Array then val.empty? ? '[]' : "[#{val.length}]"
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

    # ── Parse Errors ────────────────────────────────────────────────────────────────

    def format_parse_errors(errors)
      return '── Parse Errors  0 ──' if errors.nil? || errors.empty?

      buf = ["── Parse Errors  #{errors.length}  " + '─' * 55]
      errors.each do |e|
        line = e.respond_to?(:line) ? e.line : '?'
        col = e.respond_to?(:column) ? e.column : '?'
        buf << "  ERROR [Ln #{line}, Col #{col}]: #{e.message}"
      end
      buf.join("\n")
    end

    # ── Facts ───────────────────────────────────────────────────────────────────────

    def format_facts(facts)
      return '── Facts  (not available) ──' unless facts

      counts = []
      counts << "#{facts.types.length} types" unless facts.types.empty?
      counts << "#{facts.functions.length} functions" unless facts.functions.empty?
      counts << "#{facts.values.length} values" unless facts.values.empty?
      counts << "#{facts.methods.length} method_sets" unless facts.methods.empty?
      counts << "#{facts.interfaces.length} interfaces" unless facts.interfaces.empty?
      counts << "#{facts.imports.length} imports" unless facts.imports.empty?
      summary = counts.any? ? counts.join(', ') : 'empty'

      buf = ["── Facts  module #{facts.module_name.inspect}  #{summary}  " + '─' * 50]

      unless facts.types.empty?
        buf << ''
        buf << '  Types:'
        facts.types.each { |name, type| buf << "    #{name.ljust(20)} → #{type_repr(type)}" }
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
        facts.functions.each { |name, b| buf.concat(format_function_binding(name, b, indent: '    ')) }
      end

      unless facts.values.empty?
        buf << ''
        buf << '  Values:'
        facts.values.each { |name, b| buf << "    #{name.ljust(20)} → #{value_binding_repr(b)}" }
      end

      unless facts.methods.empty?
        buf << ''
        buf << '  Methods:'
        facts.methods.each do |receiver_type, methods|
          buf << "    on #{type_repr(receiver_type)}:"
          methods.each { |name, b| buf.concat(format_function_binding(name, b, indent: '      ')) }
        end
      end

      unless facts.imports.empty?
        buf << ''
        buf << '  Imports:'
        facts.imports.each do |import_name, module_binding|
          count = module_binding.types.length + module_binding.functions.length + module_binding.values.length
          buf << "    #{import_name.ljust(24)} → ModuleBinding (exported symbols: #{count})"
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
        binding.body_params.each { |p| buf << "#{indent}    #{value_binding_repr(p)}" }
      end
      buf << "#{indent}  return_type: #{type_repr(binding.body_return_type)}" if binding.body_return_type
      buf << "#{indent}  external: #{binding.external}"
      buf << "#{indent}  async: #{binding.async}"
      buf << "#{indent}  const: #{binding.ast.respond_to?(:const) ? binding.ast.const : false}" if binding.ast
      buf << "#{indent}  ast: #{ast_node_header(binding.ast)}" if binding.ast
      buf << "#{indent}  instances: #{binding.instances.length}" unless binding.instances.empty?
      unless binding.type_params.empty?
        buf << "#{indent}  type_params (#{binding.type_params.length}):"
        binding.type_params.each { |tp| buf << "#{indent}    #{value_repr(tp)}" }
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
      "ValueBinding[id: #{vb.id}] #{mutable} #{kind.ljust(6)} #{vb.name}: #{type_repr(type)}"
    end

    # ── Bindings ────────────────────────────────────────────────────────────────────

    def format_bindings(facts)
      return '── Bindings  (not available) ──' unless facts&.binding_resolution

      res = facts.binding_resolution
      counts = []
      counts << "#{res.identifier_binding_ids.length} ident→id" unless res.identifier_binding_ids.empty?
      counts << "#{res.declaration_binding_ids.length} decl→id" unless res.declaration_binding_ids.empty?
      counts << "#{res.binding_types.length} id→type" if res.respond_to?(:binding_types) && !res.binding_types.empty?
      summary = counts.any? ? counts.join(', ') : 'empty'

      buf = ["── Bindings  #{summary}  " + '─' * 60]

      unless res.identifier_binding_ids.empty?
        buf << "  identifier_binding_ids (#{res.identifier_binding_ids.length}):"
        res.identifier_binding_ids.take(30).each { |node_id, bid| buf << "    obj #{node_id} → binding_id: #{bid}" }
        buf << "    ... (#{res.identifier_binding_ids.length - 30} more)" if res.identifier_binding_ids.length > 30
      end

      unless res.declaration_binding_ids.empty?
        buf << "  declaration_binding_ids (#{res.declaration_binding_ids.length}):"
        res.declaration_binding_ids.take(30).each { |node_id, bid| buf << "    obj #{node_id} → binding_id: #{bid}" }
        buf << "    ... (#{res.declaration_binding_ids.length - 30} more)" if res.declaration_binding_ids.length > 30
      end

      if res.respond_to?(:binding_types) && !res.binding_types.empty?
        buf << "  binding_types (#{res.binding_types.length}):"
        res.binding_types.each { |bid, type| buf << "    binding_id: #{bid} → #{type_repr(type)}" }
      end

      buf.join("\n")
    end

    # ── Diagnostics ─────────────────────────────────────────────────────────────────

    def format_diagnostics(snapshot)
      return '── Diagnostics  (not available) ──' unless snapshot

      diags = snapshot.diagnostics
      return '── Diagnostics  0 ──' if diags.nil? || diags.empty?

      error_count = diags.count { |d| !d.respond_to?(:severity) || d.severity == :error }
      warn_count = diags.count { |d| d.respond_to?(:severity) && d.severity == :warning }
      info_count = diags.length - error_count - warn_count
      parts = []
      parts << "#{error_count} errors" if error_count > 0
      parts << "#{warn_count} warnings" if warn_count > 0
      parts << "#{info_count} info" if info_count > 0

      buf = ["── Diagnostics  #{diags.length}  (#{parts.join(', ')})  " + '─' * 50]
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
