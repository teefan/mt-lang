# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerLifecycle
        private

      def handle_initialize(params)
        @root_uri = params['rootUri']
        @workspace.workspace_root_path = uri_to_path(@root_uri)
        apply_configuration_settings(params['initializationOptions'])
        apply_configuration_settings(params['settings'])
        {
          capabilities: {
            textDocumentSync: {
              openClose: true,
              change: 2,
              save: { includeText: true }
            },
            hoverProvider: true,
            definitionProvider: true,
            declarationProvider: true,
            typeDefinitionProvider: true,
            implementationProvider: true,
            referencesProvider: true,
            documentLinkProvider: {
              resolveProvider: true
            },
            documentHighlightProvider: true,
            documentSymbolProvider: true,
            documentFormattingProvider: true,
            documentRangeFormattingProvider: true,
            foldingRangeProvider: true,
            callHierarchyProvider: true,
            typeHierarchyProvider: true,
            selectionRangeProvider: true,
            documentOnTypeFormattingProvider: {
              firstTriggerCharacter: "\n",
              moreTriggerCharacter: []
            },
            signatureHelpProvider: {
              triggerCharacters: ['(', ','],
              retriggerCharacters: [',']
            },
            codeActionProvider: {
              codeActionKinds: ['quickFix', 'source.fixAll']
            },
            codeLensProvider: {
              resolveProvider: true
            },
            inlayHintProvider: true,
            semanticTokensProvider: {
              legend: {
                tokenTypes: SEMANTIC_TOKEN_TYPES,
                tokenModifiers: SEMANTIC_TOKEN_MODIFIERS
              },
              full: { delta: true },
              range: true
            },
            completionProvider: {
              triggerCharacters: ['.', '(', ' '],
              resolveProvider: true
            },
            renameProvider: { prepareProvider: true },
            workspaceSymbolProvider: true,
            diagnosticProvider: {
              interFileDependencies: true,
              workspaceDiagnostics: true
            },
            workspace: {
              workspaceFolders: {
                supported: true,
                changeNotifications: true,
              },
              fileOperations: {
                willRename: {
                  filters: [{ pattern: { glob: '**/*.mt' }, scheme: 'file' }]
                }
              }
            }
          }
        }
      end

      def handle_initialized(_params)
        progress = create_progress(title: 'Indexing workspace', message: 'Scanning source files...')
        @workspace.index_workspace(@root_uri) { |pct, msg| progress.report(percentage: pct, message: msg) } if @root_uri
        document_count = @workspace.all_documents.length
        progress.done(message: "#{document_count} document#{document_count == 1 ? '' : 's'} indexed")
        log_message(:info, "Milk Tea LSP ready — #{document_count} document#{document_count == 1 ? '' : 's'} indexed")
        nil
      end

      def handle_did_change_configuration(params)
        apply_configuration_settings(params['settings'])
        nil
      end

      def handle_cancel_request(params)
        request_id = params.is_a?(Hash) ? (params['id'] || params[:id]) : nil
        return nil if request_id.nil?

        @cancelled_requests_mutex.synchronize do
          @cancelled_request_ids << request_id
        end
        nil
      end

      def handle_did_change_workspace_folders(params)
        event = params['event'] || {}
        added = event['added'] || []
        removed = event['removed'] || []

        removed_uris = removed.filter_map { |folder| folder.is_a?(Hash) ? folder['uri'] : nil }
        added_uris = added.filter_map { |folder| folder.is_a?(Hash) ? folder['uri'] : nil }

        if removed_uris.include?(@root_uri)
          @root_uri = added_uris.first
        elsif @root_uri.nil?
          @root_uri = added_uris.first
        end

        @workspace.workspace_root_path = uri_to_path(@root_uri)
        progress = create_progress(title: 'Reindexing workspace', message: 'Scanning source files...')
        @workspace.index_workspace(@root_uri) { |pct, msg| progress.report(percentage: pct, message: msg) } if @root_uri
        doc_count = @workspace.all_documents.length
        progress.done(message: "#{doc_count} document#{doc_count == 1 ? '' : 's'} indexed")

        @workspace.open_document_uris.each do |uri|
          schedule_diagnostics(uri, force: true, lint_tier: :full) unless @workspace.background_document?(uri)
        end
        nil
      end

      def handle_will_rename_files(params)
        files = params['files'] || []
        files.each do |file|
          old_uri = file['oldUri']
          new_uri = file['newUri']
          next unless old_uri && new_uri

          @workspace.rename_indexed_file(old_uri, new_uri)
        end
        nil
      end

      def handle_shutdown(_params)
        stop_diagnostics_workers
        @workspace.shutdown
        nil
      end

      def handle_exit(_params)
        stop_diagnostics_workers
        @workspace.shutdown
        exit(0)
      end
      end
    end
  end
end
