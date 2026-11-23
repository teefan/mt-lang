## Workspace refresh requests.  A change in one document can invalidate
## results other documents derive from it (diagnostics, reference counts,
## semantic classifications, signature-derived hints).  Each client capability
## is optional; a refresh is sent only when the client advertised support.

import mtc.lsp.protocol as proto
import mtc.lsp.workspace as workspace


## Ask the client to refresh every workspace-derived result it supports.
public function request_after_change(ws: ref[workspace.Workspace]) -> void:
    if ws.pull_diagnostics_active and ws.client_diagnostic_refresh_support:
        proto.send_request("workspace/diagnostic/refresh", "null")
    if ws.client_code_lens_refresh_support:
        proto.send_request("workspace/codeLens/refresh", "null")
    if ws.client_semantic_tokens_refresh_support:
        proto.send_request("workspace/semanticTokens/refresh", "null")
    if ws.client_inlay_hint_refresh_support:
        proto.send_request("workspace/inlayHint/refresh", "null")
