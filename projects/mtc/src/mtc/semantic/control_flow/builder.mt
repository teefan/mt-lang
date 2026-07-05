## Control-flow graph builder — transforms a function body into a directed
## graph of basic blocks.  Ownership: caller creates a local Cfg, passes it
## by ref to build_cfg_into, and is responsible for managing lifetime.
##
## The Cfg value must be a local `var` in the caller's scope (not returned
## by value) to avoid auto-release double-frees on embedded Vec/Map types.

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


public function build_cfg_into(cfg: ref[Cfg], params: span[ast.Param], body: ptr[ast.Stmt]) -> void:
    unsafe:
        var pi: ptr_uint = 0
        while pi < params.len:
            let p = read(params.data + pi)
            cfg.binding_map.set(p.name, cfg.next_id)
            cfg.next_id += 1
            pi += 1

    scan_body_decls(body, cfg)

    var exit_node = must_alloc_node(cfg)
    var _unused = exit_node
    var _b = build_stmt(cfg, body, null, false)


## ---------------------------------------------------------------------------
##  Binding-ID pre-scan
## ---------------------------------------------------------------------------

function ensure_id(cfg: ref[Cfg], name: str) -> void:
    if name.equal("_"):
        return
    if cfg.binding_map.contains(name):
        return
    cfg.binding_map.set(name, cfg.next_id)
    cfg.next_id += 1


function scan_stmt_decls(stmt_ptr: ptr[ast.Stmt]?, cfg: ref[Cfg]) -> void:
    if stmt_ptr == null:
        return
    unsafe:
        match read(ptr[ast.Stmt]<-stmt_ptr):
            ast.Stmt.stmt_local as l:
                ensure_id(cfg, l.name)
            ast.Stmt.stmt_assignment as a:
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        ensure_id(cfg, id.name)
                    _:
                        pass
            ast.Stmt.stmt_block as b:
                var i: ptr_uint = 0
                while i < b.statements.len:
                    scan_stmt_decls(b.statements.data + i, cfg)
                    i += 1
            ast.Stmt.stmt_if as i:
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    let br = read(i.branches.data + bi)
                    scan_stmt_decls(br.body, cfg)
                    bi += 1
                scan_stmt_decls(i.else_body, cfg)
            ast.Stmt.stmt_while as w:
                scan_stmt_decls(w.body, cfg)
            ast.Stmt.stmt_for as fr:
                scan_stmt_decls(fr.body, cfg)
            ast.Stmt.stmt_match as m:
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    scan_stmt_decls(arm.body, cfg)
                    ai += 1
            ast.Stmt.stmt_defer as d:
                scan_stmt_decls(d.body, cfg)
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
##  Expression read collection
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
##  Statement graph building (stub — full CFG with edges pending)
## ---------------------------------------------------------------------------

function build_stmt(cfg: ref[Cfg], stmt_ptr: ptr[ast.Stmt]?, exit_node: ptr[CfgNode]?, in_loop: bool) -> bool:
    if stmt_ptr == null:
        return false
    unsafe:
        match read(ptr[ast.Stmt]<-stmt_ptr):
            _:
                return false
