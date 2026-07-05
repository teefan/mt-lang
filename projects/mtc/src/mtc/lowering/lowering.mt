## Lowering stage — transforms the semantically-checked `Program` into an
## `ir.Program`.  This is the decoupled middle-end: it reads only the loader's
## retained per-module `Analysis` values (plus their bindings) and emits `ir`,
## never reaching into the C backend.
##
## Mirrors the Ruby Lowering entry (lib/milk_tea/core/lowering.rb `Lowering.lower`).
##
## PHASE 0: this is a stub.  It threads the pipeline end-to-end and produces an
## empty `ir.Program` carrying the root module's name so `mtc lower` / `mtc emit-c`
## wiring can be verified.  Real declaration/function lowering arrives in Phase 1+.

import std.vec as vec

import mtc.ir as ir
import mtc.loader.module_loader as loader
import mtc.semantic.analyzer as analyzer


## A lowering-stage error.  Placeholder for Phase 1+, where lowering will fail
## loudly on unresolved (`ty_error`) nodes rather than emit a guessed type.
public struct LoweringError:
    message: str
    line: ptr_uint
    column: ptr_uint
    path: str


## Lower a checked program to IR.  In dependency-first order the root module is
## the last retained analysis; its name becomes the assembled program's name.
public function lower(program: loader.Program) -> ir.Program:
    match root_analysis(program):
        Option.some as root:
            return ir.empty_program(root.value.module_name, "")
        Option.none:
            return ir.empty_program("(anonymous)", "")


function root_analysis(program: loader.Program) -> Option[analyzer.Analysis]:
    let count = program.analyses.len()
    if count == 0:
        return Option[analyzer.Analysis].none
    let root_ptr = program.analyses.get(count - 1) else:
        return Option[analyzer.Analysis].none
    unsafe:
        return Option[analyzer.Analysis].some(value = read(root_ptr))
