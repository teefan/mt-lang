## Control-flow graph builder — transforms a function body into a directed
## graph of basic blocks, recording per-node read/write sets for each variable
## binding.  Used by definite-assignment and nullability-flow analyses.
##
## All recursive visitor functions accept nullable ptr[T]? parameters; null
## is checked at entry with an early return.  Pointer dereference for match
## scrutinees uses the `ptr[T]<-nullable_ptr` cast inside `unsafe:`.

import std.map as map_mod
import std.mem.heap as heap
import std.str
import std.vec as vec

import mtc.parser.ast as ast


public struct CfgNode:
    id: ptr_uint
    reads: vec.Vec[ptr_uint]
    writes: vec.Vec[ptr_uint]
    successors: vec.Vec[ptr[CfgNode]]


public struct Cfg:
    nodes: vec.Vec[ptr[CfgNode]]
    entry: ptr[CfgNode]?
    exit: ptr[CfgNode]?
    binding_map: map_mod.Map[str, ptr_uint]
    next_id: ptr_uint


public function build_cfg(params: span[ast.Param], body: ptr[ast.Stmt]) -> Cfg:
    var cfg = Cfg(
        nodes = vec.Vec[ptr[CfgNode]].create(),
        entry = null,
        exit = null,
        binding_map = map_mod.Map[str, ptr_uint].create(),
        next_id = 0,
    )

    unsafe:
        var pi: ptr_uint = 0
        while pi < params.len:
            let p = read(params.data + pi)
            cfg.binding_map.set(p.name, cfg.next_id)
            cfg.next_id += 1
            pi += 1

    scan_body_decls(body, ref_of(cfg))

    var entry = must_alloc_node(ref_of(cfg))
    cfg.entry = entry
    unsafe:
        var pe: ptr_uint = 0
        while pe < params.len:
            let p = read(params.data + pe)
            let id_ptr = cfg.binding_map.get(p.name) else:
                fatal(c"cfg.builder missing param binding")
            entry.writes.push(read(id_ptr))
            pe += 1

    var exit_node = must_alloc_node(ref_of(cfg))
    cfg.exit = exit_node

    build_stmt(ref_of(cfg), body, exit_node, false)

    return cfg


## ---------------------------------------------------------------------------
##  Binding-ID pre-scan — assigns IDs to every declaration and referenced
##  identifier in the function body.
## ---------------------------------------------------------------------------

function ensure_id(cfg: ref[Cfg], name: str) -> void:
    if name.equal("_"):
        return
    if cfg.binding_map.contains(name):
        return
    cfg.binding_map.set(name, cfg.next_id)
    cfg.next_id += 1


function scan_expr_ids(ep: ptr[ast.Expr]?, cfg: ref[Cfg]) -> void:
    if ep == null:
        return
    unsafe:
        match read(ptr[ast.Expr]<-ep):
            ast.Expr.expr_identifier as id:
                ensure_id(cfg, id.name)
            ast.Expr.expr_binary_op as b:
                scan_expr_ids(b.left, cfg)
                scan_expr_ids(b.right, cfg)
            ast.Expr.expr_unary_op as u:
                scan_expr_ids(u.operand, cfg)
            ast.Expr.expr_member_access as ma:
                scan_expr_ids(ma.receiver, cfg)
            ast.Expr.expr_index_access as ix:
                scan_expr_ids(ix.receiver, cfg)
                scan_expr_ids(ix.index, cfg)
            ast.Expr.expr_call as cl:
                scan_expr_ids(cl.callee, cfg)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    let arg = read(cl.args.data + ai)
                    scan_expr_ids(arg.arg_value, cfg)
                    ai += 1
            ast.Expr.expr_prefix_cast as c:
                scan_expr_ids(c.expression, cfg)
            ast.Expr.expr_await as aw:
                scan_expr_ids(aw.expression, cfg)
            ast.Expr.expr_unsafe as us:
                scan_expr_ids(us.expression, cfg)
            ast.Expr.expr_if as ife:
                scan_expr_ids(ife.condition, cfg)
                scan_expr_ids(ife.then_expr, cfg)
                scan_expr_ids(ife.else_expr, cfg)
            ast.Expr.expr_detach as det:
                scan_expr_ids(det.expression, cfg)
            _:
                pass


function scan_stmt_decls(stmt_ptr: ptr[ast.Stmt]?, cfg: ref[Cfg]) -> void:
    if stmt_ptr == null:
        return
    unsafe:
        match read(ptr[ast.Stmt]<-stmt_ptr):
            ast.Stmt.stmt_local as l:
                ensure_id(cfg, l.name)
                scan_expr_ids(l.value, cfg)
            ast.Stmt.stmt_assignment as a:
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        ensure_id(cfg, id.name)
                    _:
                        pass
                scan_expr_ids(a.target, cfg)
                scan_expr_ids(a.value, cfg)
            ast.Stmt.stmt_block as b:
                var i: ptr_uint = 0
                while i < b.statements.len:
                    scan_stmt_decls(b.statements.data + i, cfg)
                    i += 1
            ast.Stmt.stmt_if as i:
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    let br = read(i.branches.data + bi)
                    scan_expr_ids(br.condition, cfg)
                    scan_stmt_decls(br.body, cfg)
                    bi += 1
                scan_stmt_decls(i.else_body, cfg)
            ast.Stmt.stmt_while as w:
                scan_expr_ids(w.condition, cfg)
                scan_stmt_decls(w.body, cfg)
            ast.Stmt.stmt_for as fr:
                var fi: ptr_uint = 0
                while fi < fr.iterables.len:
                    scan_expr_ids(fr.iterables.data + fi, cfg)
                    fi += 1
                scan_stmt_decls(fr.body, cfg)
            ast.Stmt.stmt_match as m:
                scan_expr_ids(m.scrutinee, cfg)
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    scan_stmt_decls(arm.body, cfg)
                    ai += 1
            ast.Stmt.stmt_ret as r:
                scan_expr_ids(r.value, cfg)
            ast.Stmt.stmt_defer as d:
                scan_expr_ids(d.expression, cfg)
                scan_stmt_decls(d.body, cfg)
            ast.Stmt.stmt_expression as e:
                scan_expr_ids(e.expression, cfg)
            ast.Stmt.stmt_unsafe as u:
                scan_stmt_decls(u.body, cfg)
            _:
                pass


function scan_body_decls(stmt_ptr: ptr[ast.Stmt], cfg: ref[Cfg]) -> void:
    unsafe:
        match read(stmt_ptr):
            ast.Stmt.stmt_block as b:
                var i: ptr_uint = 0
                while i < b.statements.len:
                    scan_body_decls(b.statements.data + i, cfg)
                    i += 1
            _:
                scan_stmt_decls(stmt_ptr, cfg)


## ---------------------------------------------------------------------------
##  Node allocation
## ---------------------------------------------------------------------------

function must_alloc_node(cfg: ref[Cfg]) -> ptr[CfgNode]:
    var node = heap.must_alloc[CfgNode](1)
    unsafe:
        read(node) = CfgNode(
            id = cfg.nodes.len(),
            reads = vec.Vec[ptr_uint].create(),
            writes = vec.Vec[ptr_uint].create(),
            successors = vec.Vec[ptr[CfgNode]].create(),
        )
    cfg.nodes.push(node)
    return node


## ---------------------------------------------------------------------------
##  Expression read collection — records binding IDs read in an expression.
## ---------------------------------------------------------------------------

function collect_expr_reads(ep: ptr[ast.Expr]?, reads: ref[vec.Vec[ptr_uint]], binding_map: ref[map_mod.Map[str, ptr_uint]]) -> void:
    if ep == null:
        return
    unsafe:
        match read(ptr[ast.Expr]<-ep):
            ast.Expr.expr_identifier as id:
                if not id.name.equal("_"):
                    let existing = binding_map.get(id.name)
                    if existing != null:
                        reads.push(read(existing))
            ast.Expr.expr_binary_op as b:
                collect_expr_reads(b.left, reads, binding_map)
                collect_expr_reads(b.right, reads, binding_map)
            ast.Expr.expr_unary_op as u:
                collect_expr_reads(u.operand, reads, binding_map)
            ast.Expr.expr_member_access as ma:
                collect_expr_reads(ma.receiver, reads, binding_map)
            ast.Expr.expr_index_access as ix:
                collect_expr_reads(ix.receiver, reads, binding_map)
                collect_expr_reads(ix.index, reads, binding_map)
            ast.Expr.expr_call as cl:
                collect_expr_reads(cl.callee, reads, binding_map)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    let arg = read(cl.args.data + ai)
                    collect_expr_reads(arg.arg_value, reads, binding_map)
                    ai += 1
            ast.Expr.expr_prefix_cast as c:
                collect_expr_reads(c.expression, reads, binding_map)
            ast.Expr.expr_await as aw:
                collect_expr_reads(aw.expression, reads, binding_map)
            ast.Expr.expr_unsafe as us:
                collect_expr_reads(us.expression, reads, binding_map)
            ast.Expr.expr_if as ife:
                collect_expr_reads(ife.condition, reads, binding_map)
                collect_expr_reads(ife.then_expr, reads, binding_map)
                collect_expr_reads(ife.else_expr, reads, binding_map)
            ast.Expr.expr_detach as det:
                collect_expr_reads(det.expression, reads, binding_map)
            _:
                pass


## ---------------------------------------------------------------------------
##  Statement graph building
## ---------------------------------------------------------------------------

function build_stmt(cfg: ref[Cfg], stmt_ptr: ptr[ast.Stmt]?, exit_node: ptr[CfgNode], in_loop: bool) -> bool:
    if stmt_ptr == null:
        return false
    var terminates = false
    unsafe:
        match read(ptr[ast.Stmt]<-stmt_ptr):
            ast.Stmt.stmt_block as b:
                var i: ptr_uint = 0
                while i < b.statements.len:
                    terminates = build_stmt(cfg, b.statements.data + i, exit_node, in_loop)
                    i += 1
                return terminates
            ast.Stmt.stmt_if as i:
                var all_term = true
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    let br = read(i.branches.data + bi)
                    var cond_node = must_alloc_node(cfg)
                    collect_expr_reads(br.condition, ref_of(cond_node.reads), ref_of(cfg.binding_map))
                    var term = build_stmt(cfg, br.body, exit_node, in_loop)
                    if not term:
                        all_term = false
                    bi += 1
                if not build_stmt(cfg, i.else_body, exit_node, in_loop):
                    all_term = false
                return all_term
            ast.Stmt.stmt_while as w:
                var cond_node = must_alloc_node(cfg)
                collect_expr_reads(w.condition, ref_of(cond_node.reads), ref_of(cfg.binding_map))
                var _ignored = build_stmt(cfg, w.body, exit_node, true)
                return false
            ast.Stmt.stmt_for as fr:
                var cond_node = must_alloc_node(cfg)
                var fi: ptr_uint = 0
                while fi < fr.iterables.len:
                    collect_expr_reads(fr.iterables.data + fi, ref_of(cond_node.reads), ref_of(cfg.binding_map))
                    fi += 1
                var _ignored = build_stmt(cfg, fr.body, exit_node, true)
                return false
            ast.Stmt.stmt_match as m:
                var scrut_node = must_alloc_node(cfg)
                collect_expr_reads(m.scrutinee, ref_of(scrut_node.reads), ref_of(cfg.binding_map))
                var all_term = true
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    if not build_stmt(cfg, arm.body, exit_node, in_loop):
                        all_term = false
                    ai += 1
                return all_term
            ast.Stmt.stmt_ret as r:
                var node = must_alloc_node(cfg)
                collect_expr_reads(r.value, ref_of(node.reads), ref_of(cfg.binding_map))
                node.successors.push(exit_node)
                return true
            ast.Stmt.stmt_local as l:
                var node = must_alloc_node(cfg)
                if not l.name.equal("_"):
                    let id_ptr = cfg.binding_map.get(l.name) else:
                        fatal(c"cfg.builder missing local binding")
                    node.writes.push(read(id_ptr))
                collect_expr_reads(l.value, ref_of(node.reads), ref_of(cfg.binding_map))
                return false
            ast.Stmt.stmt_assignment as a:
                var node = must_alloc_node(cfg)
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        let id_ptr = cfg.binding_map.get(id.name)
                        if id_ptr != null:
                            node.writes.push(read(id_ptr))
                    _:
                        pass
                collect_expr_reads(a.target, ref_of(node.reads), ref_of(cfg.binding_map))
                collect_expr_reads(a.value, ref_of(node.reads), ref_of(cfg.binding_map))
                return false
            ast.Stmt.stmt_expression as e:
                var node = must_alloc_node(cfg)
                collect_expr_reads(e.expression, ref_of(node.reads), ref_of(cfg.binding_map))
                return false
            ast.Stmt.stmt_unsafe as u:
                return build_stmt(cfg, u.body, exit_node, in_loop)
            ast.Stmt.stmt_defer as d:
                collect_expr_reads(d.expression, ref_of(exit_node.reads), ref_of(cfg.binding_map))
                var _ignored = build_stmt(cfg, d.body, exit_node, in_loop)
                return false
            ast.Stmt.stmt_break:
                var node = must_alloc_node(cfg)
                node.successors.push(exit_node)
                return true
            ast.Stmt.stmt_continue:
                var node = must_alloc_node(cfg)
                node.successors.push(exit_node)
                return true
            ast.Stmt.stmt_pass:
                return false
            _:
                return false


## ---------------------------------------------------------------------------
##  Cfg lifecycle
## ---------------------------------------------------------------------------

extending Cfg:
    public editable function release() -> void:
        var i: ptr_uint = 0
        while i < this.nodes.len():
            let node_ptr = this.nodes.get(i) else:
                break
            unsafe:
                let node = read(node_ptr)
                node.reads.release()
                node.writes.release()
                node.successors.release()
                heap.release(node_ptr)
            i += 1
        this.nodes.release()
        this.binding_map.release()
        this.entry = null
        this.exit = null
        this.next_id = 0
