## C backend — transforms an `ir.Program` into C source text.  This is the
## decoupled back-end: it reads only `ir`, never the analyzer or lowering
## internals.
##
## Mirrors the Ruby CBackend entry (lib/milk_tea/core/c_backend.rb
## `CBackend.generate_c`).
##
## PHASE 0: this is a stub.  It returns a placeholder translation unit so the
## `mtc emit-c` command is wired end-to-end.  Real emission (types, helpers,
## functions) arrives in Phase 1+.

import std.string as string

import mtc.ir as ir


## A backend-stage error.  Placeholder for Phase 1+.
public struct CBackendError:
    message: str
    line: ptr_uint
    column: ptr_uint
    path: str


public function generate_c(program: ir.Program) -> string.String:
    var buf = string.String.create()
    buf.append("/* mtc C backend: Phase 0 stub — code generation not yet implemented */\n")
    buf.append("/* module: ")
    buf.append(program.module_name)
    buf.append(" */\n")
    return buf
