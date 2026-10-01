## Constant propagation for the constant-condition rule — the host's
## `ControlFlow::ConstantPropagation` over F1's graph, plus the expression
## folder it calls (`CompileTime.evaluate` with identifier resolution only;
## member access and calls fold to "not a constant").
##
## The host's lattice is `undef` (no path wrote the binding yet), a constant
## value, or `nac` (not constant); joining two different constants yields
## `nac`.  Values are integers, floats, booleans, strings, `..` ranges (the
## host materializes `(left...right).to_a`; the rule only indexes, slices and
## compares them) and expression lists (tuple literals).

import std.str
import std.string as string
import std.vec as vec
import std.mem.heap as heap

import mtc.parser.ast as ast
import mtc.semantic.control_flow.builder as flow_builder
import mtc.semantic.control_flow.graph as flow_graph


const TAG_UNDEF: ptr_uint = 0
const TAG_NAC: ptr_uint = 1
const TAG_INT: ptr_uint = 2
const TAG_FLOAT: ptr_uint = 3
const TAG_BOOL: ptr_uint = 4
const TAG_STR: ptr_uint = 5
const TAG_RANGE: ptr_uint = 6
const TAG_EXPRS: ptr_uint = 7


## One lattice value.  `i`/`d`/`b`/`s` carry the payload; `lo`/`hi` a range's
## half-open bounds; `exprs` an expression list's elements (evaluated on
## demand by index).
public struct Cell:
    tag: ptr_uint
    i: long
    d: double
    b: bool
    s: str
    lo: long
    hi: long
    exprs: span[ast.Expr]


## The solved per-node in-states (the host's `Result#in_states`): a dense
## `node × key` table, `cells[node * key_count + key]`.  A zeroed cell is
## `undef`, so a key no path has written reads as undef — the answer the
## host's absent-hash-key lookup gives.  The table is dense because bindings
## and nodes are numbered from 1 in both models; the flat `(node, key)` vector
## this replaces made every per-node operation scan the whole table (its
## `state_same` compared two tables with a linear scan inside the loop), so a
## 243-node body's solve cost minutes.
public struct FlowStates:
    cells: ptr[Cell]?
    key_count: ptr_uint


public function states_empty() -> FlowStates:
    return FlowStates(cells = null, key_count = 0)


public function states_release(states: ref[FlowStates]) -> void:
    heap.release(read(states).cells)
    read(states).cells = null
    read(states).key_count = 0


## The in-state base of one node.
function state_base(states: ref[FlowStates], node: ptr_uint) -> ptr[Cell]?:
    let cells = read(states).cells else:
        return null
    return unsafe: cells + node * read(states).key_count


public function undef_cell() -> Cell:
    return Cell(tag = TAG_UNDEF, i = 0, d = 0.0, b = false, s = "", lo = 0, hi = 0, exprs = span[ast.Expr]())


public function nac_cell() -> Cell:
    return Cell(tag = TAG_NAC, i = 0, d = 0.0, b = false, s = "", lo = 0, hi = 0, exprs = span[ast.Expr]())


public function int_cell(value: long) -> Cell:
    return Cell(tag = TAG_INT, i = value, d = 0.0, b = false, s = "", lo = 0, hi = 0, exprs = span[ast.Expr]())


public function float_cell(value: double) -> Cell:
    return Cell(tag = TAG_FLOAT, i = 0, d = value, b = false, s = "", lo = 0, hi = 0, exprs = span[ast.Expr]())


public function bool_cell(value: bool) -> Cell:
    return Cell(tag = TAG_BOOL, i = 0, d = 0.0, b = value, s = "", lo = 0, hi = 0, exprs = span[ast.Expr]())


public function str_cell(value: str) -> Cell:
    return Cell(tag = TAG_STR, i = 0, d = 0.0, b = false, s = value, lo = 0, hi = 0, exprs = span[ast.Expr]())


# =============================================================================
#  State tables
# =============================================================================

function clear_cells(base: ptr[Cell], count: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < count:
        unsafe:
            read(base + i) = undef_cell()
        i += 1


function copy_cells(dst: ptr[Cell], src: ptr[Cell], count: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < count:
        unsafe:
            read(dst + i) = read(src + i)
        i += 1


function cells_same(left: ptr[Cell], right: ptr[Cell], count: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < count:
        if not cells_equal(unsafe: read(left + i), unsafe: read(right + i)):
            return false
        i += 1
    return true


## `work = join(work, base)` element-wise (the host's `join_lattice`).
function join_into_cells(work: ptr[Cell], base: ptr[Cell], count: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < count:
        unsafe:
            let other = read(base + i)
            if other.tag != TAG_UNDEF:
                let current = read(work + i)
                if current.tag == TAG_UNDEF:
                    read(work + i) = other
                else if not cells_equal(current, other):
                    read(work + i) = nac_cell()
        i += 1


function cells_equal(a: Cell, b: Cell) -> bool:
    if a.tag == TAG_UNDEF or b.tag == TAG_UNDEF:
        return a.tag == b.tag
    if a.tag == TAG_NAC or b.tag == TAG_NAC:
        return a.tag == b.tag
    if a.tag == TAG_INT and b.tag == TAG_FLOAT:
        return double<-a.i == b.d
    if a.tag == TAG_FLOAT and b.tag == TAG_INT:
        return a.d == double<-b.i
    if a.tag != b.tag:
        return false
    if a.tag == TAG_INT:
        return a.i == b.i
    if a.tag == TAG_FLOAT:
        return a.d == b.d
    if a.tag == TAG_BOOL:
        return a.b == b.b
    if a.tag == TAG_STR:
        return a.s.equal(b.s)
    if a.tag == TAG_RANGE:
        return a.lo == b.lo and a.hi == b.hi
    if a.tag == TAG_EXPRS:
        return a.exprs.data == b.exprs.data and a.exprs.len == b.exprs.len
    return false


function identifier_key(cfg: ref[flow_builder.Cfg], name: str) -> ptr_uint:
    let key = cfg.binding_map.get(name)
    if key == null:
        return 0
    return unsafe: read(key)


function state_lookup(cfg: ref[flow_builder.Cfg], in_base: ptr[Cell], name: str) -> Cell:
    let key = identifier_key(cfg, name)
    if key == 0:
        return nac_cell()
    let cell = unsafe: read(in_base + key)
    if cell.tag == TAG_UNDEF:
        return nac_cell()
    return cell


# =============================================================================
#  The value folder (the host's `CompileTime.evaluate`)
# =============================================================================

function numeric(cell: Cell) -> bool:
    return cell.tag == TAG_INT or cell.tag == TAG_FLOAT


function numeric_is_zero(cell: Cell) -> bool:
    if cell.tag == TAG_INT:
        return cell.i == 0
    return cell.d == 0.0


function as_float(cell: Cell) -> double:
    if cell.tag == TAG_FLOAT:
        return cell.d
    return double<-cell.i


function integer_of(cell: Cell) -> Option[long]:
    if cell.tag == TAG_INT:
        return Option[long].some(value = cell.i)
    if cell.tag == TAG_FLOAT:
        if cell.d == double<-long<-cell.d:
            return Option[long].some(value = long<-cell.d)
    return Option[long].none


## The host's `equality_result`: numeric, string and boolean comparisons are
## decided; everything else is not constant.
function equality_result(left: Cell, right: Cell) -> Option[bool]:
    if numeric(left) and numeric(right):
        if left.tag == TAG_INT and right.tag == TAG_INT:
            return Option[bool].some(value = left.i == right.i)
        return Option[bool].some(value = as_float(left) == as_float(right))
    if left.tag == TAG_STR and right.tag == TAG_STR:
        return Option[bool].some(value = left.s.equal(right.s))
    if left.tag == TAG_BOOL and right.tag == TAG_BOOL:
        return Option[bool].some(value = left.b == right.b)
    return Option[bool].none


function eval_unary(op: str, operand: Cell) -> Cell:
    if op.equal("+"):
        if numeric(operand):
            return operand
        return nac_cell()
    if op.equal("-"):
        if operand.tag == TAG_INT:
            return int_cell(-operand.i)
        if operand.tag == TAG_FLOAT:
            return float_cell(-operand.d)
        return nac_cell()
    if op.equal("~"):
        if operand.tag == TAG_INT:
            return int_cell(~operand.i)
        return nac_cell()
    if op.equal("not"):
        if operand.tag == TAG_BOOL:
            return bool_cell(not operand.b)
        return nac_cell()
    return nac_cell()


function eval_binary(cfg: ref[flow_builder.Cfg], in_base: ptr[Cell], operator: str, left_expr: ptr[ast.Expr], right_expr: ptr[ast.Expr]) -> Cell:
    let left = eval_expr(cfg, in_base, left_expr)
    if operator.equal("and"):
        if left.tag != TAG_BOOL:
            return nac_cell()
        if not left.b:
            return bool_cell(false)
        let right = eval_expr(cfg, in_base, right_expr)
        if right.tag == TAG_BOOL:
            return right
        return nac_cell()
    if operator.equal("or"):
        if left.tag != TAG_BOOL:
            return nac_cell()
        if left.b:
            return bool_cell(true)
        let right = eval_expr(cfg, in_base, right_expr)
        if right.tag == TAG_BOOL:
            return right
        return nac_cell()
    let right = eval_expr(cfg, in_base, right_expr)
    if operator.equal(".."):
        if left.tag == TAG_INT and right.tag == TAG_INT:
            return Cell(tag = TAG_RANGE, i = 0, d = 0.0, b = false, s = "", lo = left.i, hi = right.i, exprs = span[ast.Expr]())
        return nac_cell()
    if operator.equal("==") or operator.equal("!="):
        match equality_result(left, right):
            Option.some as eq:
                if operator.equal("=="):
                    return bool_cell(eq.value)
                return bool_cell(not eq.value)
            Option.none:
                return nac_cell()
    if operator.equal("+"):
        if left.tag == TAG_STR and right.tag == TAG_STR:
            var buf = string.String.create()
            buf.append(left.s)
            buf.append(right.s)
            return str_cell(buf.as_str())
        if numeric(left) and numeric(right):
            if left.tag == TAG_INT and right.tag == TAG_INT:
                return int_cell(left.i + right.i)
            return float_cell(as_float(left) + as_float(right))
        return nac_cell()
    if operator.equal("-") or operator.equal("*"):
        if not (numeric(left) and numeric(right)):
            return nac_cell()
        if left.tag == TAG_INT and right.tag == TAG_INT:
            if operator.equal("-"):
                return int_cell(left.i - right.i)
            return int_cell(left.i * right.i)
        let l = as_float(left)
        let r = as_float(right)
        if operator.equal("-"):
            return float_cell(l - r)
        return float_cell(l * r)
    if operator.equal("/"):
        if not (numeric(left) and numeric(right)):
            return nac_cell()
        if numeric_is_zero(right):
            return nac_cell()
        if left.tag == TAG_INT and right.tag == TAG_INT:
            return int_cell(left.i / right.i)
        return float_cell(as_float(left) / as_float(right))
    if operator.equal("%"):
        if left.tag == TAG_INT and right.tag == TAG_INT:
            if right.i == 0:
                return nac_cell()
            return int_cell(left.i % right.i)
        return nac_cell()
    if operator.equal("<<") or operator.equal(">>") or operator.equal("&") or operator.equal("|") or operator.equal("^"):
        if left.tag == TAG_INT and right.tag == TAG_INT:
            if operator.equal("<<"):
                return int_cell(left.i << right.i)
            if operator.equal(">>"):
                return int_cell(left.i >> right.i)
            if operator.equal("&"):
                return int_cell(left.i & right.i)
            if operator.equal("|"):
                return int_cell(left.i | right.i)
            return int_cell(left.i ^ right.i)
        return nac_cell()
    if operator.equal("<") or operator.equal("<=") or operator.equal(">") or operator.equal(">="):
        if not (numeric(left) and numeric(right)):
            return nac_cell()
        let l = as_float(left)
        let r = as_float(right)
        if operator.equal("<"):
            return bool_cell(l < r)
        if operator.equal("<="):
            return bool_cell(l <= r)
        if operator.equal(">"):
            return bool_cell(l > r)
        return bool_cell(l >= r)
    return nac_cell()


## A prefix cast of a numeric operand (the host's `evaluate_prefix_cast`).
## The target's width/signedness come from the type name; a 32-bit float
## narrowing is not modelled (no corpus case folds one).
function eval_prefix_cast(target_type: ptr[ast.TypeRef], operand: Cell) -> Cell:
    var value = operand
    if operand.tag == TAG_BOOL:
        value = int_cell(if operand.b: 1 else: 0)
    if not numeric(value):
        return nac_cell()
    let name = type_last_name(target_type)
    if name.len == 0:
        return nac_cell()
    if name.equal("bool"):
        return bool_cell(not numeric_is_zero(value))
    if name.equal("int") or name.equal("uint"):
        return int_cell(wrap_int(value, 32, name.equal("int")))
    if name.equal("byte") or name.equal("ubyte"):
        return int_cell(wrap_int(value, 8, name.equal("byte")))
    if name.equal("short") or name.equal("ushort"):
        return int_cell(wrap_int(value, 16, name.equal("short")))
    if name.equal("long") or name.equal("ulong") or name.equal("ptr_int") or name.equal("ptr_uint"):
        return int_cell(wrap_int(value, 64, name.equal("long") or name.equal("ptr_int")))
    if name.equal("float") or name.equal("double"):
        return float_cell(as_float(value))
    return nac_cell()


function wrap_int(value: Cell, width: ptr_uint, signed: bool) -> long:
    var v: long = 0
    if value.tag == TAG_INT:
        v = value.i
    else:
        v = long<-value.d
    let mask: long = (long<-1 << width) - 1
    var wrapped = v & mask
    if signed:
        let half: long = long<-1 << (width - 1)
        if wrapped >= half:
            wrapped = wrapped - (long<-1 << width)
    return wrapped


function type_last_name(type_ref: ptr[ast.TypeRef]) -> str:
    unsafe:
        let r = read(type_ref)
        if r.name.parts.len == 0:
            return ""
        return read(r.name.parts.data + r.name.parts.len - 1)


## Index access (the host's `evaluate_index_access`): an integer index into a
## string is its byte, into a range its element; a range index slices a string
## or the range.
function eval_index_access(receiver: Cell, index: ptr[ast.Expr], cfg: ref[flow_builder.Cfg], in_base: ptr[Cell]) -> Cell:
    unsafe:
        match read(index):
            ast.Expr.expr_range as rg:
                let start_cell = eval_expr(cfg, in_base, rg.start_expr)
                let end_cell = eval_expr(cfg, in_base, rg.end_expr)
                let start_i = integer_of(start_cell) else:
                    return nac_cell()
                let end_i = integer_of(end_cell) else:
                    return nac_cell()
                if receiver.tag == TAG_STR:
                    return str_slice(receiver.s, start_i, end_i)
                if receiver.tag == TAG_RANGE:
                    let lo = start_i
                    let hi = end_i
                    if lo < 0 or hi < lo or hi > receiver.hi - receiver.lo:
                        return nac_cell()
                    return Cell(tag = TAG_RANGE, i = 0, d = 0.0, b = false, s = "", lo = receiver.lo + lo, hi = receiver.lo + hi, exprs = span[ast.Expr]())
                if receiver.tag == TAG_EXPRS:
                    let lo = start_i
                    let hi = end_i
                    if lo < 0 or hi < lo or hi > long<-receiver.exprs.len:
                        return nac_cell()
                    return exprs_slice(receiver.exprs, lo, hi)
                return nac_cell()
            _:
                let index_cell = eval_expr(cfg, in_base, index)
                let idx = integer_of(index_cell) else:
                    return nac_cell()
                if idx < 0:
                    return nac_cell()
                if receiver.tag == TAG_STR:
                    if idx >= long<-receiver.s.len:
                        return nac_cell()
                    return int_cell(long<-receiver.s.byte_at(ptr_uint<-idx))
                if receiver.tag == TAG_RANGE:
                    if idx >= receiver.hi - receiver.lo:
                        return nac_cell()
                    return int_cell(receiver.lo + idx)
                if receiver.tag == TAG_EXPRS:
                    if idx >= long<-receiver.exprs.len:
                        return nac_cell()
                    return eval_expr(cfg, in_base, receiver.exprs.data + ptr_uint<-idx)
                return nac_cell()


function str_slice(s: str, start: long, end: long) -> Cell:
    if start < 0 or start > long<-s.len:
        return nac_cell()
    var hi = end
    if hi > long<-s.len:
        hi = long<-s.len
    if hi < start:
        hi = start
    return str_cell(s.slice(ptr_uint<-start, ptr_uint<-(hi - start)))


function exprs_slice(elems: span[ast.Expr], start: long, end: long) -> Cell:
    var sub: span[ast.Expr] = span[ast.Expr]()
    sub.data = unsafe: elems.data + ptr_uint<-start
    sub.len = ptr_uint<-(end - start)
    return Cell(tag = TAG_EXPRS, i = 0, d = 0.0, b = false, s = "", lo = 0, hi = 0, exprs = sub)


## Fold one expression in a node's in-state (the host's `eval_expr_const`).
public function eval_expr(cfg: ref[flow_builder.Cfg], in_base: ptr[Cell], ep: ptr[ast.Expr]?) -> Cell:
    let e = ep else:
        return nac_cell()
    unsafe:
        match read(e):
            ast.Expr.expr_integer_literal as lit:
                return int_cell(lit.value)
            ast.Expr.expr_float_literal as lit:
                return float_cell(lit.value)
            ast.Expr.expr_bool_literal as lit:
                return bool_cell(lit.value)
            ast.Expr.expr_char_literal as lit:
                return int_cell(long<-lit.value)
            ast.Expr.expr_string_literal as lit:
                return str_cell(lit.value)
            ast.Expr.expr_identifier as id:
                return state_lookup(cfg, in_base, id.name)
            ast.Expr.expr_unary_op as u:
                return eval_unary(u.operator, eval_expr(cfg, in_base, u.operand))
            ast.Expr.expr_binary_op as b:
                return eval_binary(cfg, in_base, b.operator, b.left, b.right)
            ast.Expr.expr_if as iff:
                let cond = eval_expr(cfg, in_base, iff.condition)
                if cond.tag != TAG_BOOL:
                    return nac_cell()
                if cond.b:
                    return eval_expr(cfg, in_base, iff.then_expr)
                return eval_expr(cfg, in_base, iff.else_expr)
            ast.Expr.expr_index_access as ix:
                return eval_index_access(eval_expr(cfg, in_base, ix.receiver), ix.index, cfg, in_base)
            ast.Expr.expr_prefix_cast as pc:
                return eval_prefix_cast(pc.target_type, eval_expr(cfg, in_base, pc.expression))
            ast.Expr.expr_range as rg:
                let start_cell = eval_expr(cfg, in_base, rg.start_expr)
                let end_cell = eval_expr(cfg, in_base, rg.end_expr)
                if start_cell.tag == TAG_INT and end_cell.tag == TAG_INT:
                    return Cell(tag = TAG_RANGE, i = 0, d = 0.0, b = false, s = "", lo = start_cell.i, hi = end_cell.i, exprs = span[ast.Expr]())
                return nac_cell()
            ast.Expr.expr_expression_list as el:
                return Cell(tag = TAG_EXPRS, i = 0, d = 0.0, b = false, s = "", lo = 0, hi = 0, exprs = el.elements)
            _:
                return nac_cell()


# =============================================================================
#  The solver
# =============================================================================

## Solve constant propagation over one body's graph.  `states` receives the
## per-node in-states the rule reads.  The host's `Dataflow.solve` shape:
## forward, rounds over the RPO until no state changes, the entry node's
## in-state empty (`boundary_in`), each node's in-state the join of its
## predecessors' out-states, and its out-state the in-state plus its writes.
public function solve_into(
    cfg: ref[flow_builder.Cfg],
    graph: ref[flow_graph.CfgGraph],
    states: ref[FlowStates],
) -> void:
    states_release(states)
    let keys = read(cfg).next_id
    let nodes = read(graph).next_id
    if keys == 0 or nodes == 0:
        return
    let in_raw = heap.must_alloc_zeroed[Cell](keys * nodes)
    let out_raw = heap.must_alloc_zeroed[Cell](keys * nodes)
    let ins = unsafe: ptr[Cell]<-in_raw
    let outs = unsafe: ptr[Cell]<-out_raw
    read(states).cells = ins
    read(states).key_count = keys
    defer: heap.release(outs)

    let in_work_raw = heap.must_alloc_zeroed[Cell](keys)
    let in_work = unsafe: ptr[Cell]<-in_work_raw
    defer: heap.release(in_work)
    let out_work_raw = heap.must_alloc_zeroed[Cell](keys)
    let out_work = unsafe: ptr[Cell]<-out_work_raw
    defer: heap.release(out_work)

    var ids = vec.Vec[ptr_uint].create()
    defer: ids.release()
    flow_graph.graph_rpo_ids(graph, ref_of(ids))

    let entry_id = read(graph).entry_id
    var changed = true
    while changed:
        changed = false
        var ii: ptr_uint = 0
        while ii < ids.len():
            let idp = ids.get(ii) else:
                break
            let id = unsafe: read(idp)
            unsafe:
                if id == entry_id:
                    clear_cells(in_work, keys)
                else:
                    join_pred_state(graph, outs, id, in_work, keys)
                if not cells_same(ins + id * keys, in_work, keys):
                    copy_cells(ins + id * keys, in_work, keys)
                    changed = true
                copy_cells(out_work, ins + id * keys, keys)
                apply_write_sites(cfg, graph, ins + id * keys, id, out_work)
                if not cells_same(outs + id * keys, out_work, keys):
                    copy_cells(outs + id * keys, out_work, keys)
                    changed = true
            ii += 1


## `work` = the join of the predecessors' out-states (no predecessors — and the
## entry node, handled by the caller — leaves it empty).
function join_pred_state(
    graph: ref[flow_graph.CfgGraph],
    outs: ptr[Cell],
    node_id: ptr_uint,
    work: ptr[Cell],
    keys: ptr_uint,
) -> void:
    clear_cells(work, keys)
    let np = flow_graph.graph_node(graph, node_id) else:
        return
    unsafe:
        var pi: ptr_uint = 0
        while pi < read(np).preds.len():
            let predp = read(np).preds.get(pi) else:
                break
            join_into_cells(work, outs + read(predp) * keys, keys)
            pi += 1


function apply_write_sites(
    cfg: ref[flow_builder.Cfg],
    graph: ref[flow_graph.CfgGraph],
    in_base: ptr[Cell],
    node_id: ptr_uint,
    out_work: ptr[Cell],
) -> void:
    let np = flow_graph.graph_node(graph, node_id) else:
        return
    unsafe:
        var wi: ptr_uint = 0
        while wi < read(np).write_sites.len():
            let wp = read(np).write_sites.get(wi) else:
                break
            let write = read(wp)
            read(out_work + write.key) = eval_write(cfg, in_base, np, write)
            wi += 1


## The host's `eval_const`: a local declaration's initializer, or an
## assignment's value (with the compound operators) — everything else is nac.
function eval_write(
    cfg: ref[flow_builder.Cfg],
    in_base: ptr[Cell],
    node: ptr[flow_graph.CfgNode],
    write: flow_graph.WriteSite,
) -> Cell:
    let stmt = node_statement(node) else:
        return nac_cell()
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as l:
                return eval_expr(cfg, in_base, l.value)
            ast.Stmt.stmt_assignment as a:
                let rhs = eval_expr(cfg, in_base, a.value)
                if a.operator.equal("="):
                    return rhs
                if rhs.tag == TAG_NAC:
                    return nac_cell()
                let lhs = eval_expr(cfg, in_base, a.target)
                if lhs.tag == TAG_NAC:
                    return nac_cell()
                if not (numeric(lhs) and numeric(rhs)):
                    return nac_cell()
                return apply_compound(a.operator, lhs, rhs)
            _:
                return nac_cell()


function apply_compound(op: str, lhs: Cell, rhs: Cell) -> Cell:
    let both_int = lhs.tag == TAG_INT and rhs.tag == TAG_INT
    if op.equal("+="):
        if both_int:
            return int_cell(lhs.i + rhs.i)
        return float_cell(as_float(lhs) + as_float(rhs))
    if op.equal("-="):
        if both_int:
            return int_cell(lhs.i - rhs.i)
        return float_cell(as_float(lhs) - as_float(rhs))
    if op.equal("*="):
        if both_int:
            return int_cell(lhs.i * rhs.i)
        return float_cell(as_float(lhs) * as_float(rhs))
    if op.equal("/="):
        if numeric_is_zero(rhs):
            return nac_cell()
        if both_int:
            return int_cell(lhs.i / rhs.i)
        return float_cell(as_float(lhs) / as_float(rhs))
    if op.equal("%="):
        if both_int:
            if rhs.i == 0:
                return nac_cell()
            return int_cell(lhs.i % rhs.i)
        return nac_cell()
    if op.equal("&=") and both_int:
        return int_cell(lhs.i & rhs.i)
    if op.equal("|=") and both_int:
        return int_cell(lhs.i | rhs.i)
    if op.equal("^=") and both_int:
        return int_cell(lhs.i ^ rhs.i)
    if op.equal("<<=") and both_int:
        return int_cell(lhs.i << rhs.i)
    if op.equal(">>=") and both_int:
        return int_cell(lhs.i >> rhs.i)
    return nac_cell()


function node_statement(node: ptr[flow_graph.CfgNode]) -> ptr[ast.Stmt]?:
    let key = unsafe: read(node).statement
    if key == 0:
        return null
    return unsafe: reinterpret[ptr[ast.Stmt]](key)


# =============================================================================
#  The rule's query
# =============================================================================

## The condition expression of an if-condition / while-condition node: the
## if-branch or the while statement the builder keyed the node with.
public function node_condition(node: ptr[flow_graph.CfgNode]) -> ptr[ast.Expr]?:
    let key = unsafe: read(node).statement
    if key == 0:
        return null
    let kind = unsafe: read(node).kind
    if kind.equal("if_condition"):
        let bp = unsafe: reinterpret[ptr[ast.IfBranch]](key)
        return unsafe: read(bp).condition
    if kind.equal("while_condition"):
        let sp = unsafe: reinterpret[ptr[ast.Stmt]](key)
        unsafe:
            match read(sp):
                ast.Stmt.stmt_while as w:
                    return w.condition
                _:
                    return null
    return null


## True/False when the node's condition folds to a constant boolean (the
## host's `constant_value_of` returning true/false).
public function condition_value_of(cfg: ref[flow_builder.Cfg], states: ref[FlowStates], node: ptr[flow_graph.CfgNode]) -> Option[bool]:
    let cond = node_condition(node) else:
        return Option[bool].none
    let id = unsafe: read(node).id
    let base = state_base(states, id) else:
        return Option[bool].none
    let cell = eval_expr(cfg, base, cond)
    if cell.tag == TAG_BOOL:
        return Option[bool].some(value = cell.b)
    return Option[bool].none


# =============================================================================
#  The loop-body skip (the host's `compute_loop_body_nodes`)
# =============================================================================

## The host's `compute_loop_body_nodes`: for every successor of every node that
## can reach the node again (a back edge), mark every node reachable from that
## successor — deliberately over-approximating, which is why an if-condition
## after a loop is skipped too.
public function loop_body_nodes(graph: ref[flow_graph.CfgGraph], sink: ref[vec.Vec[ptr_uint]]) -> void:
    var id: ptr_uint = 1
    while id < read(graph).next_id:
        let node = flow_graph.graph_node(graph, id) else:
            id += 1
            continue
        unsafe:
            var si: ptr_uint = 0
            while si < read(node).succs.len():
                let spp = read(node).succs.get(si) else:
                    break
                let succ = read(spp)
                if flow_graph.graph_reaches(graph, succ, id):
                    mark_reachable(graph, succ, sink)
                si += 1
        id += 1


function mark_reachable(graph: ref[flow_graph.CfgGraph], start: ptr_uint, sink: ref[vec.Vec[ptr_uint]]) -> void:
    var seen = vec.Vec[ptr_uint].create()
    defer: seen.release()
    var work = vec.Vec[ptr_uint].create()
    defer: work.release()
    work.push(start)
    while work.len() > 0:
        let popped = work.pop() else:
            break
        let current = popped
        if not id_in(ref_of(seen), current):
            seen.push(current)
            let node = flow_graph.graph_node(graph, current) else:
                continue
            unsafe:
                var si: ptr_uint = 0
                while si < read(node).succs.len():
                    let spp = read(node).succs.get(si) else:
                        break
                    work.push(read(spp))
                    si += 1
        if not id_in(sink, current):
            sink.push(current)


public function id_in(ids: ref[vec.Vec[ptr_uint]], value: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < ids.len():
        let ep = ids.get(i) else:
            break
        if unsafe: read(ep) == value:
            return true
        i += 1
    return false


## `while true` is an idiomatic infinite loop — the host skips it.
public function while_is_true(node: ptr[flow_graph.CfgNode]) -> bool:
    let cond = node_condition(node) else:
        return false
    unsafe:
        match read(cond):
            ast.Expr.expr_bool_literal as b:
                return b.value
            _:
                return false
