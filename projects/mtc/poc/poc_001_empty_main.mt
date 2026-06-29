# POC 001 — Empty main
# The simplest possible Milk Tea program: an empty main returning 0.
# Only tests: lexer (keywords function/return, identifiers, literals, colons,
# INDENT/DEDENT/NEWLINE), parser (function_decl, return_stmt), sema (int type),
# lowering (entrypoint wrapper), C codegen (runtime helpers, actual main).
function main() -> int:
    return 0
