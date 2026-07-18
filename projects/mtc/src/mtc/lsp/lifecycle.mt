## Lifecycle handlers — initialize, initialized, shutdown, exit.

import std.json as json
import std.string as string

import mtc.lsp.protocol as proto


## Handle the `initialize` request.
public function handle_initialize(id: json.Value) -> void:
    var r = string.String.create()
    defer r.release()

    r.append("{\"jsonrpc\":\"2.0\",\"id\":")
    proto.append_json_value(ref_of(r), id)

    # capabilities
    r.append(",\"result\":{\"capabilities\":{")
    r.append("\"textDocumentSync\":{\"openClose\":true,\"change\":1,\"save\":true}")
    r.append(",\"definitionProvider\":true")
    r.append(",\"declarationProvider\":true")
    r.append(",\"typeDefinitionProvider\":true")
    r.append(",\"implementationProvider\":true")
    r.append(",\"hoverProvider\":true")
    r.append(",\"referencesProvider\":true")
    r.append(",\"documentHighlightProvider\":true")
    r.append(",\"documentSymbolProvider\":true")
    r.append(",\"workspaceSymbolProvider\":true")
    r.append(",\"documentFormattingProvider\":true")
    r.append(",\"documentOnTypeFormattingProvider\":{\"firstTriggerCharacter\":\"\\n\",\"moreTriggerCharacter\":[]}")
    r.append(",\"foldingRangeProvider\":true")
    r.append(",\"selectionRangeProvider\":true")
    r.append(",\"inlayHintProvider\":true")
    r.append(",\"completionProvider\":{\"triggerCharacters\":[\".\"],\"resolveProvider\":true}")
    # signatureHelp: trigger on open-paren and comma
    r.append(",\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"],\"retriggerCharacters\":[\",\"]}")
    r.append(",\"renameProvider\":{\"prepareProvider\":true}")
    r.append(",\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\"]}")
    r.append(",\"executeCommandProvider\":{\"commands\":[\"mtc.restartServer\"]}")
    r.append(",\"rangeFormattingProvider\":true")
    r.append(",\"linkedEditingRangeProvider\":true")
    r.append(",\"documentLinkProvider\":{}")
    r.append(",\"codeLensProvider\":{\"resolveProvider\":true}")
    r.append(",\"typeHierarchyProvider\":true")
    r.append(",\"callHierarchyProvider\":true")
    r.append(",\"diagnosticProvider\":{\"identifier\":\"mtc\",\"interFileDependencies\":true,\"workspaceDiagnostics\":true}")
    # semantic tokens: legend + full + range
    r.append(",\"semanticTokensProvider\":{\"legend\":{")
    r.append("\"tokenTypes\":[\"namespace\",\"type\",\"keyword\",\"string\",\"number\",\"comment\",\"operator\",\"variable\",\"function\",\"parameter\",\"property\",\"regexp\"]")
    r.append(",\"tokenModifiers\":[\"declaration\",\"defaultLibrary\"]")
    r.append("},\"full\":true,\"range\":true,\"delta\":true}")
    r.append("}}}")

    proto.write_framed_json(r.as_str())


## Handle the `initialized` notification (no-op).
public function handle_initialized() -> void:
    pass
