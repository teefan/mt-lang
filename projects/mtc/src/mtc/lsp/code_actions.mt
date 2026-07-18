## Code actions — map linter warnings to LSP CodeActions.
##
## For now, returns an empty list.  Full quick-fix support requires the
## linter's fix-rule logic to be exposed via a public API, which is deferred.

import std.json as json
import std.vec as vec
import mtc.lsp.protocol as proto


## Handle textDocument/codeAction.
public function handle_code_actions(uri: str, id: json.Value) -> void:
    var result = json.create_array_value()
    proto.write_response(id, result)
