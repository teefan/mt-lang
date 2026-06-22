# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerSignatureHelp
        private

      def signature_help_bindings_for_name(facts, uri, lsp_line, lsp_char, name)
        # 1. Top-level functions
        if (binding = facts.functions[name])
          return [binding, name]
        end

        # 2. Imported module functions (e.g. mod.func(...))
        facts.imports.each_value do |mod|
          if (binding = mod.functions[name])
            return [binding, name]
          end
        end

        # 3. Methods — find via dot-receiver resolution
        dot_recv = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
        if dot_recv && name
          if (mod_binding = facts.imports[dot_recv])
            if (binding = mod_binding.functions[name])
              return [binding, name]
            end
          end

          if (receiver_type = resolve_dot_receiver_value_type(facts, dot_recv, lsp_line + 1, lsp_char + 1))
            methods = methods_for_receiver_type(facts, receiver_type)
            if (binding = methods[name] || methods["static:#{name}"])
              return [binding, name]
            end
          end

          if (type_receiver = resolve_type_receiver_info(facts, dot_recv, nil))
            methods = methods_for_receiver_type(facts, type_receiver[:type])
            if (binding = methods[name] || methods["static:#{name}"])
              return [binding, name]
            end
          end
        end

        # 4. Method name directly (e.g. method(...) on `this` in extending block)
        receiver_type = resolve_this_receiver_type(facts, uri, lsp_line)
        if receiver_type
          methods = methods_for_receiver_type(facts, receiver_type)
          if (binding = methods[name] || methods["static:#{name}"])
            return [binding, name]
          end
        end

        # 5. Value with callable type (fn/proc)
        if (val_binding = facts.values[name])
          if val_binding.type.is_a?(Types::Function)
            return [val_binding, name]
          end
        end

        # 6. Type constructor (struct constructor)
        if (type = facts.types[name])
          if type.respond_to?(:fields) && !type.fields.empty?
            return [type, name]
          end
        end

        # Resolve module-qualified type constructor (mod.Type(...))
        if name.include?('.')
          parts = name.split('.', 2)
          if (mod_binding = facts.imports[parts[0]])
            if (type = mod_binding.types[parts[1]])
              if type.respond_to?(:fields) && !type.fields.empty?
                return [type, name]
              end
            end
          end
        end

        # 7. Builtin callables
        if BUILTIN_CALL_HOVER_INFO.key?(name)
          return [{ builtin: name }, name]
        end

        nil
      end

      def resolve_this_receiver_type(facts, uri, lsp_line)
        ast = @workspace.get_ast(uri)
        return nil unless ast

        extending = nil
        each_ast_node(ast) do |node|
          next unless node.is_a?(AST::ExtendingBlock)
          if node.line && node.end_line && lsp_line + 1 >= node.line && lsp_line + 1 <= node.end_line
            extending = node
          end
        end

        return nil unless extending
        facts.types[extending.type_name]
      end

      def build_signature_from_binding(binding, name, ctx)
        if binding.is_a?(Types::Struct) || binding.is_a?(Types::StructInstance)
          fields = binding.fields
          params_list = fields.map { |fname, ftype| Types::Registry.parameter(fname, ftype) }
          return_type_label = binding.is_a?(Types::StructInstance) ? binding.to_s : binding.name
        elsif binding.respond_to?(:[])
          builtin_name = binding[:builtin]
          info = BUILTIN_CALL_HOVER_INFO[builtin_name]
          return nil unless info

          label = info[:signature].sub(/^builtin /, '')
          parameters = []
          return {
            signatures:      [{ label: label, parameters: parameters }],
            activeSignature: 0,
            activeParameter: ctx[:active_parameter],
          }
        else
          params_list = binding.type.params
          return_type_label = binding.type.return_type
        end

        params_str = format_params(params_list)
        label = "#{name}(#{params_str}) -> #{return_type_label}"

        parameters = params_list.map do |parameter|
          { label: "#{parameter.name}: #{parameter.type}" }
        end

        {
          signatures:      [{ label: label, parameters: parameters }],
          activeSignature: 0,
          activeParameter: ctx[:active_parameter],
        }
      end

      def handle_signature_help(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']
        result_state = 'miss'

        ctx = measure_perf_stage(stages, 'call_context') { @workspace.find_call_context(uri, lsp_line, lsp_char) }
        return nil unless ctx

        facts = measure_perf_stage(stages, 'facts') do
          @workspace.get_facts(uri, allow_last_good_fallback: allow_hover_last_good_fallback?(uri))
        end
        return nil unless facts

        binding_info = measure_perf_stage(stages, 'binding') do
          signature_help_bindings_for_name(facts, uri, lsp_line, lsp_char, ctx[:name])
        end
        return nil unless binding_info

        binding, display_name = binding_info

        doc_comment = measure_perf_stage(stages, 'docs') do
          signature_help_doc_comment_for_call(uri, ctx[:name], lsp_line, lsp_char)
        end

        result = measure_perf_stage(stages, 'build') do
          sig = build_signature_from_binding(binding, display_name, ctx)

          if sig && sig[:signatures] && (sig_entry = sig[:signatures].first)
            param_docs = doc_tag_param_descriptions(doc_comment)
            sig_entry[:parameters]&.each do |param|
              param_name = param[:label].to_s.split(':').first&.strip
              if param_name && param_docs.key?(param_name)
                param[:documentation] = { kind: 'markdown', value: param_docs[param_name] }
              end
            end

            signature_docs = signature_help_markdown_for_doc_comment(doc_comment)
            unless signature_docs.empty?
              sig_entry[:documentation] = { kind: 'markdown', value: signature_docs }
            end
          end

          sig
        end
        result_state = 'hit' if result
        result
      rescue StandardError => e
        result_state = 'error'
        warn "Error in signatureHelp handler: #{e.message}"
        nil
      ensure
        log_request_stage_breakdown('textDocument/signatureHelp', total_start, uri: uri, stages: stages, summary: "result=#{result_state}")
      end
      end
    end
  end
end
