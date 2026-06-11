# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerTextDocuments
        private

      def handle_did_open(params)
        total_start = monotonic_time
        uri     = params['textDocument']['uri']
        content = params['textDocument']['text']
        source = @workspace.document_source(uri) || 'unknown'
        open_start = monotonic_time
        open_stats = @workspace.open_document(uri, content)
        open_ms = elapsed_ms(open_start)
        @semantic_tokens_cache.delete(uri)
        @semantic_tokens_delta_cache.delete(uri)
        @fixall_cache.delete(uri)
        diagnostics_start = monotonic_time
        schedule_diagnostics(uri, lint_tier: :full) unless @workspace.background_document?(uri)

        elapsed = elapsed_ms(total_start)
        short_uri = shorten_uri(uri) || uri
        facts_detail = if open_stats[:eager_facts]
                            "on(#{open_stats[:facts_mode] || :unknown})"
                          else
                            "off(#{open_stats[:skip_reason] || :unknown})"
                          end
        log_perf_breakdown(
          'textDocument/didOpen',
          elapsed,
          "uri=#{short_uri} source=#{source} bytes=#{open_stats[:bytes]} lines=#{open_stats[:lines]} imports=#{open_stats[:import_count]} shared_modules=#{open_stats[:shared_module_cache_size]} eager_facts=#{facts_detail} stages_ms=open:#{open_ms},facts:#{open_stats[:facts_ms] || 0.0},diagnostics_enqueue:#{elapsed_ms(diagnostics_start)}"
        )
        nil
      end

      def handle_did_change(params)
        uri     = params['textDocument']['uri']
        changes = params['contentChanges'] || []
        previous_content = @workspace.get_content(uri)

        @workspace.apply_incremental_changes(uri, changes)

        invalidate_document_caches(uri)
        current_content = @workspace.get_content(uri)
        refresh_open_document_dependency_state(uri, previous_content: previous_content, current_content: current_content)
        schedule_diagnostics(uri, lint_tier: :fast) unless @workspace.background_document?(uri)
        nil
      end

      def handle_document_context(params)
        uri = params.dig('textDocument', 'uri') || params['uri']
        source = params['source']
        return nil unless uri && source

        previous_source = @workspace.set_document_source(uri, source)
        if previous_source == 'background-document' && source != 'background-document' && !@workspace.get_content(uri).empty?
          @semantic_tokens_cache.delete(uri)
          @semantic_tokens_delta_cache.delete(uri)
          @fixall_cache.delete(uri)
          schedule_diagnostics(uri, force: true, lint_tier: :full)
        end

        nil
      end

      def handle_did_close(params)
        uri = params['textDocument']['uri']
        cancel_diagnostics(uri)
        @workspace.close_document(uri)
        invalidate_document_caches(uri)
        @diagnostic_report_cache.delete(uri)
        @workspace_diagnostic_cache.delete(uri)
        refresh_open_document_dependency_state(uri)
        @protocol.write_notification('textDocument/publishDiagnostics', {
          uri: uri,
          diagnostics: []
        })
        nil
      end

      def handle_did_save(params)
        uri = params.dig('textDocument', 'uri')
        return nil unless uri

        text = params['text']
        @workspace.update_document(uri, text) if text
        invalidate_document_caches(uri)
        refresh_open_document_dependency_state(uri)
        schedule_diagnostics(uri, force: true, lint_tier: :full) unless @workspace.background_document?(uri)
        nil
      end
      end
    end
  end
end
