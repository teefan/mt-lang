# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerDiagnosticsScheduling
        private

      def schedule_diagnostics(uri, force: false, lint_tier: :full)
        content = @workspace.get_content(uri)
        content_digest = Digest::SHA256.hexdigest(content)
        normalized_lint_tier = Linter.normalize_lint_tier(lint_tier)
        enqueue = false

        @diagnostics_mutex.synchronize do
          previous = @diagnostics_last_scheduled_hash[uri]
          if !force && previous && previous[:digest] == content_digest && lint_tier_rank(previous[:lint_tier]) >= lint_tier_rank(normalized_lint_tier)
            @diagnostics_perf[:skipped_unchanged] += 1 if perf_logging?
            return
          end

          @diagnostics_generation[uri] += 1
          @diagnostics_last_scheduled_hash[uri] = {
            digest: content_digest,
            lint_tier: normalized_lint_tier,
          }
          @diagnostics_perf[:scheduled] += 1 if perf_logging?

          pending = @diagnostics_pending[uri]
          pending_lint_tier = pending ? pending[:lint_tier] : normalized_lint_tier
          merged_lint_tier = if pending && pending[:content] == content
                               more_strict_lint_tier(pending_lint_tier, normalized_lint_tier)
                             else
                               normalized_lint_tier
                             end

          @diagnostics_pending[uri] = {
            generation: @diagnostics_generation[uri],
            content: content,
            lint_tier: merged_lint_tier,
          }

          unless @diagnostics_enqueued.include?(uri)
            @diagnostics_enqueued << uri
            enqueue = true
          end
        end

        if enqueue
          @diagnostics_queue << uri
          if perf_logging?
            @diagnostics_perf[:queue_peak] = [@diagnostics_perf[:queue_peak], @diagnostics_queue.length].max
          end
        end
      end

      def cancel_diagnostics(uri)
        @diagnostics_mutex.synchronize do
          @diagnostics_generation[uri] += 1
          @diagnostics_pending.delete(uri)
          @diagnostics_last_scheduled_hash.delete(uri)
          @diagnostics_perf[:cancelled] += 1 if perf_logging?
        end
      end

      def start_diagnostics_workers
        return if @diagnostics_workers.any?(&:alive?)

        DIAGNOSTICS_WORKER_COUNT.times do |index|
          @diagnostics_workers << Thread.new do
            if Thread.current.respond_to?(:name=)
              Thread.current.name = "mt-lsp-diagnostics-#{index + 1}"
            end

            loop do
              uri = @diagnostics_queue.pop
              break if uri == :__stop__

              process_diagnostics_for_uri(uri)
            end
          rescue StandardError => e
            warn "LSP diagnostics worker error: #{e.message}"
            warn "  #{e.backtrace.first(8).join("\n  ")}" if e.backtrace
          end
        end
      end

      def stop_diagnostics_workers
        workers = @diagnostics_workers
        return if workers.empty?

        workers.length.times { @diagnostics_queue << :__stop__ }
        workers.each do |worker|
          worker.join(1.0)
          next unless worker.alive?

          worker.kill
          worker.join
        end
        @diagnostics_workers = []
      rescue StandardError => e
        warn "LSP diagnostics worker shutdown error: #{e.message}"
      end

      def drain_diagnostics_queue
        @diagnostics_queue.clear
        nil
      end

      def process_diagnostics_for_uri(uri)
        loop do
          snapshot = nil
          @diagnostics_mutex.synchronize do
            snapshot = @diagnostics_pending.delete(uri)
          end
          break unless snapshot

          @diagnostics_perf[:dequeued] += 1 if perf_logging?

          diagnostics = collect_diagnostics_for_content(uri, snapshot[:content], lint_tier: snapshot[:lint_tier])
          publish = false
          @diagnostics_mutex.synchronize do
            publish = snapshot[:generation] == @diagnostics_generation[uri]
          end

          if publish
            if defined?(@pull_diagnostics_active) && @pull_diagnostics_active
              @diagnostics_perf[:collected_for_pull] += 1 if perf_logging?
            else
              @diagnostics_perf[:published] += 1 if perf_logging?
              @protocol.write_notification('textDocument/publishDiagnostics', {
                uri: uri,
                diagnostics: diagnostics
              })
              notify_diagnostic_errors(uri, diagnostics)

              cross = @workspace.cross_file_diagnostics
              if cross&.any?
                cross.each do |target_uri, items|
                  @protocol.write_notification('textDocument/publishDiagnostics', {
                    uri: target_uri,
                    diagnostics: items
                  })
                end
              end
            end
          elsif perf_logging?
            @diagnostics_perf[:dropped_stale] += 1
          end
        end
      ensure
        requeue = false
        @diagnostics_mutex.synchronize do
          @diagnostics_enqueued.delete(uri)
          if @diagnostics_pending.key?(uri)
            @diagnostics_enqueued << uri
            requeue = true
          end
        end

        if requeue
          @diagnostics_perf[:requeued] += 1 if perf_logging?
          @diagnostics_queue << uri
          if perf_logging?
            @diagnostics_perf[:queue_peak] = [@diagnostics_perf[:queue_peak], @diagnostics_queue.length].max
          end
        end
      end

      def collect_diagnostics_for_content(uri, _content, lint_tier: :full)
        @workspace.collect_diagnostics(uri, lint_tier: lint_tier)
      rescue StandardError => e
        warn "LSP diagnostics error #{uri}: #{e.message}"
        warn "  #{e.backtrace.first(6).join("\n  ")}" if e.backtrace
        []
      end

      def lint_tier_rank(lint_tier)
        case Linter.normalize_lint_tier(lint_tier)
        when :full
          2
        when :fast
          1
        else
          0
        end
      end

      def more_strict_lint_tier(a, b)
        lint_tier_rank(a) >= lint_tier_rank(b) ? Linter.normalize_lint_tier(a) : Linter.normalize_lint_tier(b)
      end

      def dependency_import_fingerprint(content)
        content.to_s.each_line.filter_map do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?('#')
          next unless stripped.start_with?('import ')

          stripped
        end.join("\n")
      end

      def dependency_export_surface_fingerprint(content)
        content.to_s.each_line.filter_map do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?('#')

          if stripped.match?(/\A(?:public\s+)?(?:type|struct|union|enum|flags|variant|interface|event|function|const|var)\b/)
            stripped
          elsif stripped.match?(/\Aextending\b/)
            stripped
          elsif stripped.match?(/\Apublic\s+(?:function|const|var|type)\b/)
            stripped
          end
        end.join("\n")
      end

      def dependency_refresh_required_for_edit?(changed_uri, previous_content, current_content)
        return false if previous_content == current_content
        return true if dependency_import_fingerprint(previous_content) != dependency_import_fingerprint(current_content)

        related_uris = @workspace.related_open_document_uris(changed_uri)
        return false unless related_uris.length > 1

        dependency_export_surface_fingerprint(previous_content) != dependency_export_surface_fingerprint(current_content)
      end

      def semantic_tokens_allow_last_good_fallback?(uri)
        @diagnostics_mutex.synchronize do
          @diagnostics_pending.key?(uri) || @diagnostics_enqueued.include?(uri)
        end
      end

      def notify_diagnostic_errors(uri, diagnostics)
        errors = diagnostics.select { |d| d.is_a?(Hash) && (d["severity"] || d[:severity]) == 1 }
        return if errors.empty?

        @notified_error_uris ||= Set.new
        return if @notified_error_uris.include?(uri)

        @notified_error_uris.add(uri)
        path = uri_to_path(uri) || uri
        short_path = path.split("/").last(1).join
        show_message(:warning, "#{short_path}: #{errors.length} error#{errors.length == 1 ? '' : 's'}")
      end
      end
    end
  end
end
