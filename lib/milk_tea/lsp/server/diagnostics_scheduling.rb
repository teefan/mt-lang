# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerDiagnosticsScheduling
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
              # Fresh facts just landed for this document; let the editor
              # re-fetch semantic tokens so analyzed highlighting replaces the
              # lexical fallback that was served while facts were unavailable.
              refresh_client_semantic_tokens
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

        # Declaration-prefix regex. Unlike the old form, it also covers the
        # `const function` compound, async/foreign/external/editable/static
        # modifiers, and `attribute` declarations. `static_assert` is not
        # matched: `static` requires whitespace before the keyword, and a bare
        # module-level statement cannot be a declaration.
        SURFACE_DECL_LINE = %r{\A(?:(?:public|foreign|external|async|editable|static|const)\s+)*(?:function|struct|union|enum|flags|variant|interface|event|type|const|var|extending|opaque|attribute)\b}

        # A bare `name: Type` line. Only struct/union fields (and continuation
        # parameter lines) take this shape; local declarations use `let`/`var`,
        # named arguments use `=`, and match-arm labels start with a keyword or
        # pattern. Requires a type-like token after the colon so `_:` arm labels
        # are not treated as surface.
        SURFACE_FIELD_LINE = /\A[A-Za-z_][A-Za-z0-9_]*\s*:\s*[A-Za-z_\[\]]/

        # Over-approximation of the module's externally-observable surface. It
        # must never MISS a surface change (a miss leaves shared-cache analyses
        # of dependents stale); false positives only trigger a harmless
        # re-analysis. In addition to declaration lines it captures:
        #   - `@[...]` attributes (packed/align/deprecated change layout/docs)
        #   - multi-line declaration headers, so parameter/signature edits on
        #     continuation lines are detected
        #   - struct/union field lines (`name: Type`)
        def dependency_export_surface_fingerprint(content)
          lines = content.to_s.lines.map(&:strip)
          surface = []
          i = 0
          while i < lines.length
            line = lines[i]
            if line.empty? || line.start_with?('#')
              i += 1
              next
            end

            if line.start_with?('@[') || line.match?(SURFACE_DECL_LINE) || line.match?(SURFACE_FIELD_LINE)
              surface << line
              # Multi-line header: absorb continuation lines until the
              # terminating ':' so edits inside the header are surfaced too.
              unless line.end_with?(':')
                i += 1
                while i < lines.length
                  cont = lines[i]
                  break if cont.empty?
                  surface << cont
                  i += 1
                  break if cont.end_with?(':')
                end
                next
              end
            end
            i += 1
          end
          surface.join("\n")
        end

        def dependency_refresh_required_for_edit?(changed_uri, previous_content, current_content)
          return false if previous_content == current_content
          return true if dependency_import_fingerprint(previous_content) != dependency_import_fingerprint(current_content)

          # Keep the open-document dependency index fresh (related_open_document_uris
          # updates it as a side effect) so dependent tracking stays accurate.
          @workspace.related_open_document_uris(changed_uri)

          # A surface edit can invalidate shared-cache analyses of NON-open
          # dependents (their cached entries are recomputed against this module
          # on their next pull), so clearing must not be gated on there being
          # open dependents to refresh.
          dependency_export_surface_fingerprint(previous_content) != dependency_export_surface_fingerprint(current_content)
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
