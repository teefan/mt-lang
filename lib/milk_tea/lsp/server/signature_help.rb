# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerSignatureHelp
        private

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

        binding = measure_perf_stage(stages, 'binding') { facts.functions[ctx[:name]] }
        return nil unless binding

        doc_comment = measure_perf_stage(stages, 'docs') do
          signature_help_doc_comment_for_call(uri, ctx[:name], lsp_line, lsp_char)
        end

        result = measure_perf_stage(stages, 'build') do
          params_list = binding.type.params
          params_str  = format_params(params_list)
          label       = "#{ctx[:name]}(#{params_str}) -> #{binding.type.return_type}"

          param_docs = doc_tag_param_descriptions(doc_comment)
          parameters  = params_list.map do |parameter|
            entry = { label: "#{parameter.name}: #{parameter.type}" }
            if param_docs.key?(parameter.name)
              entry[:documentation] = {
                kind: 'markdown',
                value: param_docs.fetch(parameter.name),
              }
            end
            entry
          end

          signature_entry = {
            label: label,
            parameters: parameters,
          }

          signature_docs = signature_help_markdown_for_doc_comment(doc_comment)
          unless signature_docs.empty?
            signature_entry[:documentation] = {
              kind: 'markdown',
              value: signature_docs,
            }
          end

          {
            signatures:      [signature_entry],
            activeSignature: 0,
            activeParameter: ctx[:active_parameter]
          }
        end
        result_state = 'hit'
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
