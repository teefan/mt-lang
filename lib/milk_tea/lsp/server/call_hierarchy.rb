# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerCallHierarchy
        private

        def handle_prepare_call_hierarchy(params)
          text_document = params["textDocument"]
          position = params["position"]
          uri = text_document["uri"]
          lsp_line = position["line"]
          lsp_char = position["character"]

          facts = @workspace.get_facts(uri)
          return nil unless facts

          token = @workspace.find_token_at(uri, lsp_line, lsp_char)
          return nil unless token
          return nil unless token.type == :identifier

          func_name = token.lexeme

          func_binding = facts.functions[func_name]
          if func_binding
            return [build_call_hierarchy_item(func_name, uri, func_binding, facts)]
          end

          dot_recv = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          if dot_recv
            if (module_binding = facts.imports[dot_recv])
              if module_binding.functions.key?(func_name)
                return [build_call_hierarchy_item(func_name, uri, module_binding.functions[func_name], facts)]
              end
            end
          end

          if facts.methods
            facts.methods.each_value do |method_map|
              if method_map.key?(func_name)
                return [build_call_hierarchy_item(func_name, uri, method_map[func_name], facts)]
              end
            end
          end

          nil
        end

        def handle_incoming_calls(params)
          item = params["item"] || params[:item]
          data = item["data"] || item[:data]
          return [] unless data.is_a?(Hash) || data.respond_to?(:[])

          target_name = data["name"] || data[:name]
          return [] if target_name.to_s.empty?

          target_uri = data["uri"] || data[:uri]
          candidate_uris = nil
          if target_uri
            target_facts = @workspace.get_facts(target_uri)
            if target_facts&.module_name
              importing = @workspace.reverse_import_dependents_for(target_facts.module_name)
              if importing && !importing.empty?
                candidate_uris = importing.to_a + [target_uri]
              end
            end
          end

          refs = if candidate_uris
                   @workspace.find_all_references_in(target_name, candidate_uris)
                 else
                   @workspace.find_all_references(target_name)
                 end
          return [] if refs.empty?

          caller_map = {}
          refs.each do |ref|
            call_uri = ref[:uri]
            ref_line = ref[:range][:start][:line] + 1

            caller_func = find_enclosing_function(call_uri, ref_line)
            next unless caller_func
            next if caller_func[:name] == target_name && call_uri == data["uri"]

            key = [call_uri, caller_func[:name]]
            caller_map[key] ||= { uri: call_uri, name: caller_func[:name], ranges: [], kind: caller_func[:kind] }
            caller_map[key][:ranges] << ref[:range]
          end

          caller_map.map do |_, caller|
            {
              from: {
                name: caller[:name],
                kind: caller[:kind],
                uri: caller[:uri],
                range: caller[:ranges].first,
                selectionRange: caller[:ranges].first,
                data: { name: caller[:name], uri: caller[:uri], kind: caller[:kind] },
              },
              fromRanges: caller[:ranges],
            }
          end
        end

        def handle_outgoing_calls(params)
          item = params["item"] || params[:item]
          data = item["data"] || item[:data]
          return [] unless data.is_a?(Hash) || data.respond_to?(:[])

          target_name = data["name"] || data[:name]
          target_uri = data["uri"] || data[:uri]
          return [] if target_name.to_s.empty?

          facts = @workspace.get_facts(target_uri)
          return [] unless facts

          func_binding = facts.functions[target_name]
          unless func_binding
            facts.methods&.each_value do |method_map|
              func_binding = method_map[target_name]
              break if func_binding
            end
          end
          return [] unless func_binding
          return [] unless func_binding.ast.respond_to?(:body)

          callees = collect_call_callees(func_binding.ast.body, facts)
          return [] if callees.empty?

          result = []
          callees.each do |callee_name, ranges|
            def_entry = @workspace.find_definition_token_global(callee_name, preferred_uri: target_uri)
            def_uri = def_entry ? def_entry[:uri].to_s : target_uri
            def_range = def_entry ? token_range(def_entry[:token]) : ranges.first

            result << {
              to: {
                name: callee_name,
                kind: 12,
                uri: def_uri,
                range: def_range,
                selectionRange: def_range,
                data: { name: callee_name, uri: def_uri, kind: 12 },
              },
              fromRanges: ranges,
            }
          end

          result.take(50)
        end

        private

        def build_call_hierarchy_item(name, uri, binding, facts)
          range = binding_range(binding)
          selection_range = selection_range_from_binding(binding)

          receiver = nil
          if binding.respond_to?(:receiver_type) && binding.receiver_type
            receiver = binding.receiver_type.to_s
          end

          {
            name: name,
            kind: receiver ? 6 : 12,
            uri: uri,
            range: range,
            selectionRange: selection_range,
            data: {
              name: name,
              uri: uri,
              receiver_type: receiver,
            },
          }
        end

        def binding_range(binding)
          line = binding.ast.respond_to?(:line) ? binding.ast.line - 1 : 0
          col = binding.ast.respond_to?(:column) ? binding.ast.column - 1 : 0
          length = binding.name.length
          {
            start: { line: line, character: col },
            end: { line: line, character: col + length },
          }
        end

        def selection_range_from_binding(binding)
          name_len = binding.name.length
          ast = binding.ast
          line = ast.respond_to?(:line) ? ast.line - 1 : 0
          col = ast.respond_to?(:column) ? ast.column - 1 : 0

          if ast.respond_to?(:name)
            name_ast = ast.name
            if name_ast.respond_to?(:parts)
              line = name_ast.line - 1
              col = name_ast.column - 1
            end
          end

          {
            start: { line: line, character: col },
            end: { line: line, character: col + name_len },
          }
        end

        def find_enclosing_function(uri, line)
          symbols = @workspace.get_symbols(uri)
          enclosing = symbols
            .select { |s| [:function, :method].include?(s[:kind]) && s[:line] }
            .select { |s| s[:line] <= line }
            .max_by { |s| s[:line] }

          return nil unless enclosing

          kind = enclosing[:kind] == :method ? 6 : 12
          { name: enclosing[:name], kind: kind }
        end

        def collect_call_callees(body, facts)
          callees = {}
          each_ast_node(body) do |node|
            next unless node.is_a?(AST::Call)

            callee_name = extract_callee_name(node.callee, facts)
            next unless callee_name

            range = {
              start: { line: node.callee.respond_to?(:line) ? node.callee.line - 1 : 0,
                       character: node.callee.respond_to?(:column) ? node.callee.column - 1 : 0 },
              end: { line: node.callee.respond_to?(:line) ? node.callee.line - 1 : 0,
                     character: (node.callee.respond_to?(:column) ? node.callee.column - 1 : 0) + callee_name.length },
            }

            callees[callee_name] ||= []
            callees[callee_name] << range
          end

          callees
        end

        def extract_callee_name(callee, facts)
          case callee
          when AST::Identifier
            callee.name
          when AST::MemberAccess
            if callee.receiver.is_a?(AST::Identifier)
              mod_alias = callee.receiver.name
              member = callee.member
              if facts.imports.key?(mod_alias)
                member
              else
                "#{mod_alias}.#{member}"
              end
            end
          when AST::Specialization
            extract_callee_name(callee.callee, facts) if callee.callee
          end
        end

        def token_range(token)
          line = token.respond_to?(:line) ? token.line - 1 : 0
          col = token.respond_to?(:column) ? token.column - 1 : 0
          len = token.respond_to?(:lexeme) ? token.lexeme.length : 0
          {
            start: { line: line, character: col },
            end: { line: line, character: col + len },
          }
        end
      end
    end
  end
end
