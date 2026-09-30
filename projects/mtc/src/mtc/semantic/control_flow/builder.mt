## Control-flow graph builder — the binding-ID pre-scan plus the host's
## `ControlFlow::Builder` graph: nodes carrying their statement's reads and
## writes, successor edges with the host's branch labels, break/continue
## targets, and the null-test edge refinements `NullabilityFlow` consumes.
##
## Ownership:  the caller creates a Cfg via `empty_cfg()` and a graph via
## `graph.empty_graph()`, passes both by ref to `build_graph_into`, and manages
## their lifetime.  Never return a Cfg by value from a function that stores it
## in a local variable — Vec/Map auto-release at scope exit will double-free
## when copied.
##
## Struct literals (e.g. `Cfg( ... )`) in return or initialization position are
## safe — the C backend emits them directly into the caller's storage without a
## transient local copy.

import std.map as map_mod
import std.mem.heap as heap
import std.str
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.control_flow.graph as graph_mod


## A basic-block node in the CFG.  The graph itself lives in
## `control_flow.graph` (`CfgNode` there carries the kind, the statement and the
## read/write sites); this struct stays for the linter's binding-ID callers.
public struct CfgNode:
    id: ptr_uint


## Top-level CFG container.  `binding_map` is a name→ID mapping for every local
## declaration.  Ids start at 1, so 0 reads as "not a binding of this body"
## (the host's nil); `next_id` is the next unassigned ID.  `binding_names` is
## the reverse map (id - 1 → name), so the analyzer can resolve a non-null
## binding id back to the scope name it refines.
public struct Cfg:
    nodes: vec.Vec[ptr[CfgNode]]
    binding_map: map_mod.Map[str, ptr_uint]
    next_id: ptr_uint
    binding_names: vec.Vec[str]


## Return an empty Cfg struct literal.  Safe to return by value because the
## literal is emitted directly into caller storage — no transient local to
## auto-release.
public function empty_cfg() -> Cfg:
    return Cfg(
        nodes = vec.Vec[ptr[CfgNode]].create(),
        binding_map = map_mod.Map[str, ptr_uint].create(),
        next_id = 1,
        binding_names = vec.Vec[str].create(),
    )


## Reset the Cfg to empty, keeping its allocations, so one Cfg can serve every
## function body of a module.
public function cfg_clear(cfg: ref[Cfg]) -> void:
    cfg.binding_map.clear()
    cfg.binding_names.clear()
    cfg.next_id = 1


## ---------------------------------------------------------------------------
##  Public entry points
## ---------------------------------------------------------------------------

## Fill the given Cfg with a binding-ID pre-scan of the function body.
## Parameters are registered first (IDs 0..N-1), then the body is walked to
## find `let`/`var` declarations and assignment-target identifiers.
public function build_cfg_into(cfg: ref[Cfg], params: span[ast.Param], body: ptr[ast.Stmt]) -> void:
    assign_param_ids(cfg, params)
    collect_binding_ids(body, cfg)


## Fill `cfg` with the binding IDs of the whole function body — parameters,
## locals, assignment targets, `for` and match-arm bindings and destructured
## names — and `graph` with the host's `ControlFlow::Builder` graph.
## `build_cfg_into` keeps its narrower pre-scan for the linter's callers; this
## entry point is the analyzer's.
public function build_graph_into(cfg: ref[Cfg], graph: ref[graph_mod.CfgGraph], params: span[ast.Param], body: ptr[ast.Stmt]) -> void:
    assign_param_ids(cfg, params)
    collect_binding_ids(body, cfg)
    collect_binding_ids_extra(body, cfg)
    graph_mod.graph_clear(graph)
    let exit_id = graph_mod.graph_add_node(graph, "exit", 0, 0, 0)
    graph.exit_id = exit_id
    let entry_id = build_graph_body(cfg, graph, body, exit_id, 0, 0)
    graph.entry_id = entry_id


## ---------------------------------------------------------------------------
##  Parameter registration
## ---------------------------------------------------------------------------

function assign_param_ids(cfg: ref[Cfg], params: span[ast.Param]) -> void:
    unsafe:
        var pi: ptr_uint = 0
        while pi < params.len:
            let p = read(params.data + pi)
            if not cfg.binding_map.contains(p.name):
                cfg.binding_map.set(p.name, cfg.next_id)
                cfg.binding_names.push(p.name)
                cfg.next_id += 1
            pi += 1


## ---------------------------------------------------------------------------
##  Binding-ID collection walks
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


## Register the binding IDs `collect_binding_ids` does not: `for` bindings,
## match-arm `as` bindings, destructured names and a guarded decl's else
## binding.  They are declarations the dataflow passes track as writes.
function collect_binding_ids_extra(stmt_ptr: ptr[ast.Stmt]?, cfg: ref[Cfg]) -> void:
    if stmt_ptr == null:
        return
    unsafe:
        match read(ptr[ast.Stmt]<-stmt_ptr):
            ast.Stmt.stmt_local as l:
                match l.destructure_bindings:
                    Option.some as names:
                        var di: ptr_uint = 0
                        while di < names.value.len:
                            ensure_binding_id(cfg, read(names.value.data + di))
                            di += 1
                    Option.none:
                        pass
                match l.else_binding:
                    Option.some as else_name:
                        ensure_binding_id(cfg, else_name.value)
                    Option.none:
                        pass
                collect_binding_ids_extra(l.else_body, cfg)
            ast.Stmt.stmt_block as b:
                var i: ptr_uint = 0
                while i < b.statements.len:
                    collect_binding_ids_extra(b.statements.data + i, cfg)
                    i += 1
            ast.Stmt.stmt_if as i:
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    collect_binding_ids_extra(read(i.branches.data + bi).body, cfg)
                    bi += 1
                collect_binding_ids_extra(i.else_body, cfg)
            ast.Stmt.stmt_while as w:
                collect_binding_ids_extra(w.body, cfg)
            ast.Stmt.stmt_for as fr:
                var fi: ptr_uint = 0
                while fi < fr.bindings.len:
                    ensure_binding_id(cfg, read(fr.bindings.data + fi).name)
                    fi += 1
                collect_binding_ids_extra(fr.body, cfg)
            ast.Stmt.stmt_match as m:
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    match arm.binding_name:
                        Option.some as bound:
                            ensure_binding_id(cfg, bound.value)
                        Option.none:
                            pass
                    collect_binding_ids_extra(arm.body, cfg)
                    ai += 1
            ast.Stmt.stmt_defer as d:
                collect_binding_ids_extra(d.body, cfg)
            ast.Stmt.stmt_unsafe as u:
                collect_binding_ids_extra(u.body, cfg)
            ast.Stmt.stmt_when as w:
                var wi: ptr_uint = 0
                while wi < w.branches.len:
                    let br = read(w.branches.data + wi)
                    match br.binding_name:
                        Option.some as bound:
                            ensure_binding_id(cfg, bound.value)
                        Option.none:
                            pass
                    var si: ptr_uint = 0
                    while si < br.body.len:
                        collect_binding_ids_extra(br.body.data + si, cfg)
                        si += 1
                    wi += 1
                collect_binding_ids_extra(w.else_body, cfg)
            ast.Stmt.stmt_parallel_block as pb:
                var pri: ptr_uint = 0
                while pri < pb.bodies.len:
                    collect_binding_ids_extra(pb.bodies.data + pri, cfg)
                    pri += 1
            _:
                pass


## Register a binding ID for `name` if one has not already been assigned.
## Discard bindings (`_`) are skipped.
function ensure_binding_id(cfg: ref[Cfg], name: str) -> void:
    if name == "_":
        return
    if name.len == 0:
        return
    if cfg.binding_map.contains(name):
        return
    cfg.binding_map.set(name, cfg.next_id)
    cfg.binding_names.push(name)
    cfg.next_id += 1


## The binding name registered for `id` (`""` for 0 or an unknown id).
public function cfg_binding_name(cfg: ref[Cfg], id: ptr_uint) -> str:
    if id == 0 or id > cfg.binding_names.len():
        return ""
    let name = cfg.binding_names.get(id - 1) else:
        return ""
    return unsafe: read(name)


## The binding-ID lookup for the graph walk: 0 when `name` is not a binding of
## this function body (the host's `identifier_binding_key` returning nil).
function binding_id_of(cfg: ref[Cfg], name: str) -> ptr_uint:
    if name == "_" or name.len == 0:
        return 0
    let found = cfg.binding_map.get(name) else:
        return 0
    return unsafe: read(found)


# =============================================================================
#  The graph — the host's `ControlFlow::Builder`
# =============================================================================

## Build a statement body's nodes, threading the continuation `next_id` the way
## the host does (statements are walked backwards, so each one knows the node
## control flows into).
function build_graph_block(cfg: ref[Cfg], g: ref[graph_mod.CfgGraph], stmts: span[ast.Stmt], next_id: ptr_uint, break_target: ptr_uint, continue_target: ptr_uint) -> ptr_uint:
    var current_next = next_id
    var i = stmts.len
    unsafe:
        while i > 0:
            i -= 1
            current_next = build_graph_statement(cfg, g, stmts.data + i, current_next, break_target, continue_target)
    return current_next


## A body pointer: a block is its statement list, anything else is one
## statement.  Transparent wrappers (`unsafe:`) have no node of their own.
function build_graph_body(cfg: ref[Cfg], g: ref[graph_mod.CfgGraph], body: ptr[ast.Stmt]?, next_id: ptr_uint, break_target: ptr_uint, continue_target: ptr_uint) -> ptr_uint:
    let b = body else:
        return next_id
    unsafe:
        match read(ptr[ast.Stmt]<-b):
            ast.Stmt.stmt_block as blk:
                return build_graph_block(cfg, g, blk.statements, next_id, break_target, continue_target)
            _:
                return build_graph_statement(cfg, g, b, next_id, break_target, continue_target)


function build_graph_statement(cfg: ref[Cfg], g: ref[graph_mod.CfgGraph], stmt: ptr[ast.Stmt], next_id: ptr_uint, break_target: ptr_uint, continue_target: ptr_uint) -> ptr_uint:
    let stmt_key = unsafe: reinterpret[ptr_uint](stmt)
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as l:
                if l.else_body != null:
                    let cond_id = graph_mod.graph_add_node(g, "local_decl_condition", stmt_key, l.line, l.column)
                    let cond = graph_mod.graph_node(g, cond_id) else:
                        return next_id
                    collect_read_sites(cfg, cond, l.value)
                    let success_id = graph_mod.graph_add_node(g, "local_decl", stmt_key, l.line, l.column)
                    let success = graph_mod.graph_node(g, success_id) else:
                        return next_id
                    collect_local_decl_writes(cfg, success, l.name, l.line, l.column)
                    graph_mod.graph_add_edge(g, cond_id, success_id)
                    graph_mod.graph_set_edge_label(g, cond_id, success_id, "non_null")
                    let null_entry = build_graph_body(cfg, g, l.else_body, next_id, break_target, continue_target)
                    graph_mod.graph_add_edge(g, cond_id, null_entry)
                    graph_mod.graph_set_edge_label(g, cond_id, null_entry, "null")
                    return cond_id
                let node_id = graph_mod.graph_add_node(g, "local_decl", stmt_key, l.line, l.column)
                let node = graph_mod.graph_node(g, node_id) else:
                    return next_id
                collect_read_sites(cfg, node, l.value)
                collect_local_decl_writes(cfg, node, l.name, l.line, l.column)
                match l.destructure_bindings:
                    Option.some as names:
                        var di: ptr_uint = 0
                        while di < names.value.len:
                            push_write_site(cfg, node, read(names.value.data + di), l.line, l.column, "declaration")
                            di += 1
                    Option.none:
                        pass
                match l.else_binding:
                    Option.some as else_name:
                        push_write_site(cfg, node, else_name.value, l.else_binding_line, l.else_binding_column, "declaration")
                    Option.none:
                        pass
                graph_mod.graph_add_edge(g, node_id, next_id)
                return node_id
            ast.Stmt.stmt_assignment as a:
                let node_id = graph_mod.graph_add_node(g, "assignment", stmt_key, a.line, a.column)
                let node = graph_mod.graph_node(g, node_id) else:
                    return next_id
                collect_read_sites(cfg, node, a.value)
                if not a.operator.equal("="):
                    collect_assignment_target_reads(cfg, node, a.target)
                collect_target_side_effect_reads(cfg, node, a.target)
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        push_write_site(cfg, node, id.name, a.line, id.column, "assignment")
                    _:
                        pass
                collect_write_sites_from_expression(cfg, node, a.value, a.line)
                graph_mod.graph_add_edge(g, node_id, next_id)
                return node_id
            ast.Stmt.stmt_if as sif:
                var fallback_entry = next_id
                if sif.else_body != null:
                    fallback_entry = build_graph_body(cfg, g, sif.else_body, next_id, break_target, continue_target)
                var bi = sif.branches.len
                while bi > 0:
                    bi -= 1
                    let branch = read(sif.branches.data + bi)
                    let branch_key = reinterpret[ptr_uint](sif.branches.data + bi)
                    let then_entry = build_graph_body(cfg, g, branch.body, next_id, break_target, continue_target)
                    graph_mod.graph_set_body_target(g, branch.body, next_id)
                    let line = if branch.line > 0: branch.line else: sif.line
                    let cond_id = graph_mod.graph_add_node(g, "if_condition", branch_key, line, branch.column)
                    let cond = graph_mod.graph_node(g, cond_id) else:
                        return next_id
                    collect_read_sites(cfg, cond, branch.condition)
                    graph_mod.graph_add_edge(g, cond_id, then_entry)
                    graph_mod.graph_set_edge_label(g, cond_id, then_entry, "true_branch")
                    graph_mod.graph_add_edge(g, cond_id, fallback_entry)
                    graph_mod.graph_set_edge_label(g, cond_id, fallback_entry, "false_branch")
                    add_null_test_refinements(cfg, g, cond_id, then_entry, fallback_entry, branch.condition)
                    fallback_entry = cond_id
                return fallback_entry
            ast.Stmt.stmt_match as m:
                let match_id = graph_mod.graph_add_node(g, "match_condition", stmt_key, m.line, m.column)
                let match_node = graph_mod.graph_node(g, match_id) else:
                    return next_id
                collect_read_sites(cfg, match_node, m.scrutinee)
                if m.arms.len == 0:
                    graph_mod.graph_add_edge(g, match_id, next_id)
                else:
                    var ai: ptr_uint = 0
                    while ai < m.arms.len:
                        let arm = read(m.arms.data + ai)
                        let arm_key = reinterpret[ptr_uint](m.arms.data + ai)
                        var arm_entry = build_graph_body(cfg, g, arm.body, next_id, break_target, continue_target)
                        match arm.binding_name:
                            Option.some as bound:
                                let bind_line = if arm.binding_line > 0: arm.binding_line else: m.line
                                let bind_id = graph_mod.graph_add_node(g, "match_binding", arm_key, bind_line, arm.binding_column)
                                let bind_node = graph_mod.graph_node(g, bind_id) else:
                                    return next_id
                                push_write_site(cfg, bind_node, bound.value, bind_line, arm.binding_column, "match_binding")
                                graph_mod.graph_add_edge(g, bind_id, arm_entry)
                                arm_entry = bind_id
                            Option.none:
                                pass
                        graph_mod.graph_add_edge(g, match_id, arm_entry)
                        ai += 1
                return match_id
            ast.Stmt.stmt_while as w:
                let cond_id = graph_mod.graph_add_node(g, "while_condition", stmt_key, w.line, w.column)
                let cond = graph_mod.graph_node(g, cond_id) else:
                    return next_id
                collect_read_sites(cfg, cond, w.condition)
                let body_entry = build_graph_body(cfg, g, w.body, cond_id, next_id, cond_id)
                graph_mod.graph_set_body_target(g, w.body, next_id)
                graph_mod.graph_add_edge(g, cond_id, body_entry)
                graph_mod.graph_set_edge_label(g, cond_id, body_entry, "true_branch")
                graph_mod.graph_add_edge(g, cond_id, next_id)
                graph_mod.graph_set_edge_label(g, cond_id, next_id, "false_branch")
                add_null_test_refinements(cfg, g, cond_id, body_entry, next_id, w.condition)
                return cond_id
            ast.Stmt.stmt_for as fr:
                let header_id = graph_mod.graph_add_node(g, "for_header", stmt_key, fr.line, fr.column)
                let header = graph_mod.graph_node(g, header_id) else:
                    return next_id
                var fi: ptr_uint = 0
                while fi < fr.iterables.len:
                    collect_read_sites(cfg, header, fr.iterables.data + fi)
                    fi += 1
                var bi: ptr_uint = 0
                while bi < fr.bindings.len:
                    let binding = read(fr.bindings.data + bi)
                    push_write_site(cfg, header, binding.name, fr.line, fr.column, "for_binding")
                    bi += 1
                let body_entry = build_graph_body(cfg, g, fr.body, header_id, next_id, header_id)
                graph_mod.graph_set_body_target(g, fr.body, next_id)
                graph_mod.graph_add_edge(g, header_id, body_entry)
                graph_mod.graph_add_edge(g, header_id, next_id)
                return header_id
            ast.Stmt.stmt_unsafe as u:
                return build_graph_body(cfg, g, u.body, next_id, break_target, continue_target)
            ast.Stmt.stmt_error_block as eb:
                return build_graph_body(cfg, g, eb.body, next_id, break_target, continue_target)
            ast.Stmt.stmt_defer as d:
                let body_entry = build_graph_body(cfg, g, d.body, next_id, break_target, continue_target)
                let defer_id = graph_mod.graph_add_node(g, "defer", stmt_key, d.line, d.column)
                graph_mod.graph_add_edge(g, defer_id, body_entry)
                return defer_id
            ast.Stmt.stmt_ret as r:
                let node_id = graph_mod.graph_add_node(g, "return", stmt_key, r.line, r.column)
                let node = graph_mod.graph_node(g, node_id) else:
                    return next_id
                collect_read_sites(cfg, node, r.value)
                return node_id
            ast.Stmt.stmt_expression as e:
                let fatal = is_fatal_expression(e.expression)
                let kind = if fatal: "fatal" else: "expression"
                let node_id = graph_mod.graph_add_node(g, kind, stmt_key, e.line, 0)
                let node = graph_mod.graph_node(g, node_id) else:
                    return next_id
                collect_read_sites(cfg, node, e.expression)
                collect_write_sites_from_expression(cfg, node, e.expression, e.line)
                if not fatal:
                    graph_mod.graph_add_edge(g, node_id, next_id)
                return node_id
            ast.Stmt.stmt_static_assert as sa:
                let node_id = graph_mod.graph_add_node(g, "static_assert", stmt_key, sa.line, 0)
                let node = graph_mod.graph_node(g, node_id) else:
                    return next_id
                collect_read_sites(cfg, node, sa.condition)
                graph_mod.graph_add_edge(g, node_id, next_id)
                return node_id
            ast.Stmt.stmt_pass as p:
                return add_plain_node(g, "pass", stmt_key, p.line, p.column, next_id)
            ast.Stmt.stmt_break as br:
                let target = if break_target != 0: break_target else: next_id
                return add_plain_node(g, "break", stmt_key, br.line, br.column, target)
            ast.Stmt.stmt_continue as cont:
                let target = if continue_target != 0: continue_target else: next_id
                return add_plain_node(g, "continue", stmt_key, cont.line, cont.column, target)
            _:
                return add_plain_node(g, "other", stmt_key, 0, 0, next_id)


## A node with no reads or writes, flowing into `next_id`.
function add_plain_node(g: ref[graph_mod.CfgGraph], kind: str, stmt_key: ptr_uint, line: ptr_uint, column: ptr_uint, next_id: ptr_uint) -> ptr_uint:
    let node_id = graph_mod.graph_add_node(g, kind, stmt_key, line, column)
    graph_mod.graph_add_edge(g, node_id, next_id)
    return node_id


# =============================================================================
#  Read and write collection
# =============================================================================

function push_read_site(cfg: ref[Cfg], node: ptr[graph_mod.CfgNode], name: str, line: ptr_uint, column: ptr_uint, length: ptr_uint) -> void:
    let key = binding_id_of(cfg, name)
    if key == 0:
        return
    unsafe:
        read(node).read_sites.push(graph_mod.ReadSite(key = key, line = line, column = column, length = length))


function push_write_site(cfg: ref[Cfg], node: ptr[graph_mod.CfgNode], name: str, line: ptr_uint, column: ptr_uint, origin: str) -> void:
    let key = binding_id_of(cfg, name)
    if key == 0:
        return
    unsafe:
        read(node).write_sites.push(graph_mod.WriteSite(key = key, name = name, line = line, column = column, origin = origin))


## The host's `read_identifiers`: every identifier an expression reads, in
## source order, keyed to its binding.
function collect_read_sites(cfg: ref[Cfg], node: ptr[graph_mod.CfgNode], expr: ptr[ast.Expr]?) -> void:
    let e = expr else:
        return
    unsafe:
        match read(ptr[ast.Expr]<-e):
            ast.Expr.expr_identifier as id:
                push_read_site(cfg, node, id.name, id.line, id.column, id.name.len)
            ast.Expr.expr_member_access as ma:
                collect_read_sites(cfg, node, ma.receiver)
            ast.Expr.expr_index_access as ix:
                collect_read_sites(cfg, node, ix.receiver)
                collect_read_sites(cfg, node, ix.index)
            ast.Expr.expr_specialization as sp:
                collect_read_sites(cfg, node, sp.callee)
            ast.Expr.expr_call as cl:
                collect_read_sites(cfg, node, cl.callee)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    collect_read_sites(cfg, node, read(cl.args.data + ai).arg_value)
                    ai += 1
            ast.Expr.expr_unary_op as u:
                collect_read_sites(cfg, node, u.operand)
            ast.Expr.expr_binary_op as b:
                collect_read_sites(cfg, node, b.left)
                collect_read_sites(cfg, node, b.right)
            ast.Expr.expr_range as r:
                collect_read_sites(cfg, node, r.start_expr)
                collect_read_sites(cfg, node, r.end_expr)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    collect_read_sites(cfg, node, el.elements.data + ei)
                    ei += 1
            ast.Expr.expr_if as ife:
                collect_read_sites(cfg, node, ife.condition)
                collect_read_sites(cfg, node, ife.then_expr)
                collect_read_sites(cfg, node, ife.else_expr)
            ast.Expr.expr_match as me:
                collect_read_sites(cfg, node, me.scrutinee)
                var ai: ptr_uint = 0
                while ai < me.arms.len:
                    let arm = read(me.arms.data + ai)
                    collect_read_sites(cfg, node, arm.pattern)
                    collect_read_sites(cfg, node, arm.value)
                    ai += 1
            ast.Expr.expr_unsafe as us:
                collect_read_sites(cfg, node, us.expression)
            ast.Expr.expr_prefix_cast as pc:
                collect_read_sites(cfg, node, pc.expression)
            ast.Expr.expr_await as aw:
                collect_read_sites(cfg, node, aw.expression)
            ast.Expr.expr_detach as det:
                collect_read_sites(cfg, node, det.expression)
            ast.Expr.expr_named as nm:
                collect_read_sites(cfg, node, nm.value)
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as fe:
                            collect_read_sites(cfg, node, fe.expression)
                        _:
                            pass
                    pi += 1
            _:
                pass


## A `let`/`var` declaration's own write (the host's `local_decl_write_targets`):
## the declared name when the declaration has an initializer, plus whatever the
## initializer itself writes through.
function collect_local_decl_writes(cfg: ref[Cfg], node: ptr[graph_mod.CfgNode], name: str, line: ptr_uint, column: ptr_uint) -> void:
    push_write_site(cfg, node, name, line, column, "declaration")


## The host's `assignment_target_reads`: a compound assignment reads its target.
function collect_assignment_target_reads(cfg: ref[Cfg], node: ptr[graph_mod.CfgNode], target: ptr[ast.Expr]) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                push_read_site(cfg, node, id.name, id.line, id.column, id.name.len)
            _:
                collect_target_side_effect_reads(cfg, node, target)


## The host's `assignment_target_side_effect_reads`: the receiver/index reads a
## member or index target performs before it is written.
function collect_target_side_effect_reads(cfg: ref[Cfg], node: ptr[graph_mod.CfgNode], target: ptr[ast.Expr]) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_member_access as ma:
                collect_read_sites(cfg, node, ma.receiver)
            ast.Expr.expr_index_access as ix:
                collect_read_sites(cfg, node, ix.receiver)
                collect_read_sites(cfg, node, ix.index)
            _:
                pass


## The host's `write_targets_from_expression`: the bindings an expression
## writes through (`out`/`inout` arguments and the `ref_of`/`ptr_of` family).
function collect_write_sites_from_expression(cfg: ref[Cfg], node: ptr[graph_mod.CfgNode], expr: ptr[ast.Expr]?, line: ptr_uint) -> void:
    let e = expr else:
        return
    unsafe:
        match read(ptr[ast.Expr]<-e):
            ast.Expr.expr_call as cl:
                collect_write_sites_from_expression(cfg, node, cl.callee, line)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    let value = read(cl.args.data + ai).arg_value
                    match read(value):
                        ast.Expr.expr_unary_op as u:
                            if u.operator.equal("out") or u.operator.equal("inout"):
                                match read(u.operand):
                                    ast.Expr.expr_identifier as oid:
                                        push_write_site(cfg, node, oid.name, line, 0, "call_argument")
                                    _:
                                        pass
                        _:
                            pass
                    match call_argument_mutation_target(value):
                        Option.some as target:
                            match read(target.value):
                                ast.Expr.expr_identifier as tid:
                                    push_write_site(cfg, node, tid.name, line, 0, "call_argument")
                                _:
                                    pass
                        Option.none:
                            pass
                    collect_write_sites_from_expression(cfg, node, value, line)
                    ai += 1
            ast.Expr.expr_member_access as ma:
                collect_write_sites_from_expression(cfg, node, ma.receiver, line)
            ast.Expr.expr_index_access as ix:
                collect_write_sites_from_expression(cfg, node, ix.receiver, line)
                collect_write_sites_from_expression(cfg, node, ix.index, line)
            ast.Expr.expr_specialization as sp:
                collect_write_sites_from_expression(cfg, node, sp.callee, line)
            ast.Expr.expr_unary_op as u:
                collect_write_sites_from_expression(cfg, node, u.operand, line)
            ast.Expr.expr_binary_op as b:
                collect_write_sites_from_expression(cfg, node, b.left, line)
                collect_write_sites_from_expression(cfg, node, b.right, line)
            ast.Expr.expr_range as r:
                collect_write_sites_from_expression(cfg, node, r.start_expr, line)
                collect_write_sites_from_expression(cfg, node, r.end_expr, line)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    collect_write_sites_from_expression(cfg, node, el.elements.data + ei, line)
                    ei += 1
            ast.Expr.expr_if as ife:
                collect_write_sites_from_expression(cfg, node, ife.condition, line)
                collect_write_sites_from_expression(cfg, node, ife.then_expr, line)
                collect_write_sites_from_expression(cfg, node, ife.else_expr, line)
            ast.Expr.expr_match as me:
                collect_write_sites_from_expression(cfg, node, me.scrutinee, line)
                var ai: ptr_uint = 0
                while ai < me.arms.len:
                    let arm = read(me.arms.data + ai)
                    collect_write_sites_from_expression(cfg, node, arm.pattern, line)
                    collect_write_sites_from_expression(cfg, node, arm.value, line)
                    ai += 1
            ast.Expr.expr_unsafe as us:
                collect_write_sites_from_expression(cfg, node, us.expression, line)
            ast.Expr.expr_prefix_cast as pc:
                collect_write_sites_from_expression(cfg, node, pc.expression, line)
            ast.Expr.expr_await as aw:
                collect_write_sites_from_expression(cfg, node, aw.expression, line)
            ast.Expr.expr_detach as det:
                collect_write_sites_from_expression(cfg, node, det.expression, line)
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as fe:
                            collect_write_sites_from_expression(cfg, node, fe.expression, line)
                        _:
                            pass
                    pi += 1
            _:
                pass


## The host's `call_argument_mutation_target`: `ref_of(x)` writes through `x`,
## `ptr_of`/`const_ptr_of` through whatever they wrap.
function call_argument_mutation_target(expression: ptr[ast.Expr]) -> Option[ptr[ast.Expr]]:
    unsafe:
        match read(expression):
            ast.Expr.expr_call as cl:
                if cl.args.len == 1:
                    match read(cl.callee):
                        ast.Expr.expr_identifier as id:
                            let value = read(cl.args.data + 0).arg_value
                            if id.name.equal("ref_of"):
                                match read(value):
                                    ast.Expr.expr_identifier:
                                        return Option[ptr[ast.Expr]].some(value = value)
                                    _:
                                        return Option[ptr[ast.Expr]].none
                            if id.name.equal("ptr_of"):
                                match read(value):
                                    ast.Expr.expr_identifier:
                                        return Option[ptr[ast.Expr]].some(value = value)
                                    _:
                                        return call_argument_mutation_target(value)
                            if id.name.equal("const_ptr_of"):
                                return call_argument_mutation_target(value)
                        _:
                            pass
            _:
                pass
    return Option[ptr[ast.Expr]].none


## The host's `fatal_expression?`: a `fatal(...)` call, or an `assert`/`expect`
## whose first argument is the literal `false`, terminates the flow.
function is_fatal_expression(expr: ptr[ast.Expr]?) -> bool:
    let e = expr else:
        return false
    unsafe:
        match read(ptr[ast.Expr]<-e):
            ast.Expr.expr_call as cl:
                match read(cl.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name.equal("fatal"):
                            return true
                        if id.name.equal("assert") or id.name.equal("expect"):
                            if cl.args.len > 0:
                                match read(read(cl.args.data + 0).arg_value):
                                    ast.Expr.expr_bool_literal as b:
                                        return not b.value
                                    _:
                                        pass
                    _:
                        pass
            _:
                pass
    return false


# =============================================================================
#  Null-test edge refinements — the host's `add_null_test_refinements`
# =============================================================================

## One `x == null` / `x != null` fact: `null_on_true` distinguishes the host's
## `:null_if_true` direction from `:non_null_if_true` for the given binding.
struct NullPair:
    key: ptr_uint
    null_on_true: bool


## Record the host's `add_null_test_refinements`: for every null test in the
## condition, label the true and false edges so the dataflow knows which
## binding is known non-null on which path.
function add_null_test_refinements(cfg: ref[Cfg], g: ref[graph_mod.CfgGraph], cond_id: ptr_uint, true_succ: ptr_uint, false_succ: ptr_uint, condition: ptr[ast.Expr]) -> void:
    var pairs = vec.Vec[NullPair].create()
    defer: pairs.release()
    null_check_pairs(cfg, condition, true, ref_of(pairs))
    var pi: ptr_uint = 0
    while pi < pairs.len():
        let pair = pairs.get(pi) else:
            break
        unsafe:
            if read(pair).null_on_true:
                graph_mod.graph_set_edge_refinement(g, cond_id, true_succ, read(pair).key, false)
                graph_mod.graph_set_edge_refinement(g, cond_id, false_succ, read(pair).key, true)
            else:
                graph_mod.graph_set_edge_refinement(g, cond_id, true_succ, read(pair).key, true)
                graph_mod.graph_set_edge_refinement(g, cond_id, false_succ, read(pair).key, false)
        pi += 1


## The host's `null_check_pairs`: `not` flips the polarity, `and` merges its
## operands when true (and the *left* only when false), `or` the mirror image.
function null_check_pairs(cfg: ref[Cfg], expr: ptr[ast.Expr]?, positive: bool, pairs_out: ref[vec.Vec[NullPair]]) -> void:
    let e = expr else:
        return
    unsafe:
        match read(ptr[ast.Expr]<-e):
            ast.Expr.expr_unary_op as u:
                if u.operator.equal("not"):
                    null_check_pairs(cfg, u.operand, not positive, pairs_out)
            ast.Expr.expr_binary_op as b:
                if b.operator.equal("and"):
                    if positive:
                        merge_operand_pairs(cfg, b.left, b.right, true, pairs_out)
                else if b.operator.equal("or"):
                    if not positive:
                        merge_operand_pairs(cfg, b.left, b.right, false, pairs_out)
                else if b.operator.equal("==") or b.operator.equal("!="):
                    single_null_pair(cfg, b.left, b.right, positive, b.operator.equal("=="), pairs_out)
            _:
                pass


function merge_operand_pairs(cfg: ref[Cfg], left: ptr[ast.Expr], right: ptr[ast.Expr], positive: bool, pairs_out: ref[vec.Vec[NullPair]]) -> void:
    var left_pairs = vec.Vec[NullPair].create()
    defer: left_pairs.release()
    null_check_pairs(cfg, left, positive, ref_of(left_pairs))
    var right_pairs = vec.Vec[NullPair].create()
    defer: right_pairs.release()
    null_check_pairs(cfg, right, positive, ref_of(right_pairs))
    merge_null_pairs(ref_of(left_pairs), ref_of(right_pairs), pairs_out)


## The host's `single_null_pair`: the identifier side of `x == null` /
## `x != null`, taking the polarity into account.
function single_null_pair(cfg: ref[Cfg], left: ptr[ast.Expr], right: ptr[ast.Expr], positive: bool, null_on_true: bool, pairs_out: ref[vec.Vec[NullPair]]) -> void:
    var name: str = ""
    var found = false
    unsafe:
        match read(left):
            ast.Expr.expr_identifier as id:
                match read(right):
                    ast.Expr.expr_null_literal:
                        name = id.name
                        found = true
                    _:
                        pass
            _:
                pass
        match read(right):
            ast.Expr.expr_identifier as id:
                match read(left):
                    ast.Expr.expr_null_literal:
                        name = id.name
                        found = true
                    _:
                        pass
            _:
                pass
    if not found:
        return
    let key = binding_id_of(cfg, name)
    if key == 0:
        return
    let direction_null_on_true = null_on_true == positive
    pairs_out.push(NullPair(key = key, null_on_true = direction_null_on_true))


## The host's `merge_null_pairs`: union, dropping any key the two sides
## disagree about.
function merge_null_pairs(left: ref[vec.Vec[NullPair]], right: ref[vec.Vec[NullPair]], pairs_out: ref[vec.Vec[NullPair]]) -> void:
    var i: ptr_uint = 0
    while i < left.len():
        let pair = left.get(i) else:
            break
        push_null_pair(pairs_out, unsafe: read(pair))
        i += 1
    var ri: ptr_uint = 0
    while ri < right.len():
        let pair = right.get(ri) else:
            break
        push_null_pair(pairs_out, unsafe: read(pair))
        ri += 1


function push_null_pair(pairs_out: ref[vec.Vec[NullPair]], pair: NullPair) -> void:
    var i: ptr_uint = 0
    while i < pairs_out.len():
        let existing = pairs_out.get(i) else:
            break
        unsafe:
            if read(existing).key == pair.key:
                if read(existing).null_on_true != pair.null_on_true:
                    let _removed = pairs_out.swap_remove(i)
                return
        i += 1
    pairs_out.push(pair)
