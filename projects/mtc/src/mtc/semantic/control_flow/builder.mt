## Control-flow graph builder — pre-scan pass: assigns a unique binding ID
## to every local variable declaration and assignment target in a function body.
##
## Ownership:  the caller creates a Cfg via `empty_cfg()`, passes it by ref to
## `build_cfg_into`, and manages its lifetime.  Never return a Cfg by value from
## a function that stores it in a local variable — Vec/Map auto-release at scope
## exit will double-free when copied.
##
## Struct literals (e.g. `Cfg( ... )`) in return or initialization position are
## safe — the C backend emits them directly into the caller's storage without a
## transient local copy.

import std.map as map_mod
import std.mem.heap as heap
import std.str
import std.vec as vec

import mtc.parser.ast as ast


## A basic-block node in the CFG.  Currently a placeholder; the full graph
## with edges, read/write sets, and successor links will be built in a later
## phase.  Callers only need `Cfg.binding_map` for name→ID lookup.
public struct CfgNode:
    id: ptr_uint


## Top-level CFG container.  `binding_map` is the primary output of the current
## pre-scan pass — a name→ID mapping for every local declaration.  `next_id`
## is the next unassigned ID; it doubles as the total count of bindings.
public struct Cfg:
    nodes: vec.Vec[ptr[CfgNode]]
    binding_map: map_mod.Map[str, ptr_uint]
    next_id: ptr_uint


## Return an empty Cfg struct literal.  Safe to return by value because the
## literal is emitted directly into caller storage — no transient local to
## auto-release.
public function empty_cfg() -> Cfg:
    return Cfg(
        nodes = vec.Vec[ptr[CfgNode]].create(),
        binding_map = map_mod.Map[str, ptr_uint].create(),
        next_id = 0,
    )


## ---------------------------------------------------------------------------
##  Public entry point
## ---------------------------------------------------------------------------

## Fill the given Cfg with a binding-ID pre-scan of the function body.
## Parameters are registered first (IDs 0..N-1), then the body is walked to
## find `let`/`var` declarations and assignment-target identifiers.
public function build_cfg_into(cfg: ref[Cfg], params: span[ast.Param], body: ptr[ast.Stmt]) -> void:
    assign_param_ids(cfg, params)
    collect_binding_ids(body, cfg)


## ---------------------------------------------------------------------------
##  Parameter registration
## ---------------------------------------------------------------------------

function assign_param_ids(cfg: ref[Cfg], params: span[ast.Param]) -> void:
    unsafe:
        var pi: ptr_uint = 0
        while pi < params.len:
            let p = read(params.data + pi)
            cfg.binding_map.set(p.name, cfg.next_id)
            cfg.next_id += 1
            pi += 1


## ---------------------------------------------------------------------------
##  Binding-ID collection walk
## ---------------------------------------------------------------------------

## Recursively walk a statement body and assign a unique binding ID to every
## local variable declared with `let`/`var` and every identifier that appears
## as the direct target of an assignment.
function collect_binding_ids(stmt_ptr: ptr[ast.Stmt]?, cfg: ref[Cfg]) -> void:
    if stmt_ptr == null:
        return
    unsafe:
        match read(ptr[ast.Stmt]<-stmt_ptr):
            ast.Stmt.stmt_local as l:
                ensure_binding_id(cfg, l.name)
            ast.Stmt.stmt_assignment as a:
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        ensure_binding_id(cfg, id.name)
                    _:
                        pass
            ast.Stmt.stmt_block as b:
                var i: ptr_uint = 0
                while i < b.statements.len:
                    collect_binding_ids(b.statements.data + i, cfg)
                    i += 1
            ast.Stmt.stmt_if as i:
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    let br = read(i.branches.data + bi)
                    collect_binding_ids(br.body, cfg)
                    bi += 1
                collect_binding_ids(i.else_body, cfg)
            ast.Stmt.stmt_while as w:
                collect_binding_ids(w.body, cfg)
            ast.Stmt.stmt_for as fr:
                collect_binding_ids(fr.body, cfg)
            ast.Stmt.stmt_match as m:
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    collect_binding_ids(arm.body, cfg)
                    ai += 1
            ast.Stmt.stmt_defer as d:
                collect_binding_ids(d.body, cfg)
            ast.Stmt.stmt_unsafe as u:
                collect_binding_ids(u.body, cfg)
            _:
                pass


## Register a binding ID for `name` if one has not already been assigned.
## Discard bindings (`_`) are skipped.
function ensure_binding_id(cfg: ref[Cfg], name: str) -> void:
    if name.equal("_"):
        return
    if cfg.binding_map.contains(name):
        return
    cfg.binding_map.set(name, cfg.next_id)
    cfg.next_id += 1
