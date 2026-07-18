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
    r.append(",\"hoverProvider\":true")
    r.append(",\"referencesProvider\":true")
    r.append(",\"documentSymbolProvider\":true")
    r.append(",\"documentFormattingProvider\":true")
    r.append(",\"completionProvider\":{\"triggerCharacters\":[\".\"],\"resolveProvider\":false}")
    # signatureHelp: trigger on open-paren and comma
    r.append(",\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"],\"retriggerCharacters\":[\",\"]}")
    r.append(",\"renameProvider\":{\"prepareProvider\":false}")
    r.append(",\"codeActionProvider\":{\"codeActionKinds\":[]}")
    # semantic tokens: legend + full
    r.append(",\"semanticTokensProvider\":{\"legend\":{")
    r.append("\"tokenTypes\":[\"namespace\",\"type\",\"keyword\",\"string\",\"number\",\"comment\",\"operator\",\"variable\",\"function\",\"parameter\",\"property\",\"regexp\"]")
    r.append(",\"tokenModifiers\":[\"declaration\",\"defaultLibrary\"]")
    r.append("},\"full\":true}")
    r.append("}}}")

    proto.write_framed_json(r.as_str())


## Handle the `initialized` notification (no-op).
public function handle_initialized() -> void:
    pass
