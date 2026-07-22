## Forward constant propagation for constant-condition lint detection.
##
## Walks function bodies forward, tracking integer-literal values of
## let-bindings and simple assignments. When an if/while condition
## evaluates to a constant true/false, emits a hint.

import std.vec as vec
import std.map as map_mod
import std.str

import mtc.parser.ast as ast


struct ConstWrite:
    value: str
    line: ptr_uint
    kind: str


public function collect_constant_conditions(file: ast.SourceFile) -> vec.Vec[ConstWrite]:
    var result = vec.Vec[ConstWrite].create()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    walk_body_const(fun.body, ref_of(result))
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        walk_body_const(read(ex.methods.data + j).body, ref_of(result))
                        j += 1
                _:
                    pass
        i += 1
    return result


function walk_body_const(body_ptr: ptr[ast.Stmt]?, result: ref[vec.Vec[ConstWrite]]) -> void:
    if body_ptr == null:
        return
    unsafe:
        match read(body_ptr):
            ast.Stmt.stmt_block as blk:
                var values = map_mod.Map[str, int].create()
                defer values.release()
                walk_stmts_const(blk.statements, ref_of(values), result)
            _:
                pass


function walk_stmts_const(stmts: span[ast.Stmt], values: ref[map_mod.Map[str, int]], result: ref[vec.Vec[ConstWrite]]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe: walk_stmt_const(stmts.data + si, values, result)
        si += 1


function walk_stmt_const(sp: ptr[ast.Stmt], values: ref[map_mod.Map[str, int]], result: ref[vec.Vec[ConstWrite]]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as loc:
                match const_eval_expr(loc.value, values):
                    Option.some as sval:
                        values.set(loc.name, sval.value)
                    Option.none:
                        if loc.value != null:
                            values.remove(loc.name)
            ast.Stmt.stmt_assignment as a:
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        if a.operator == "=":
                            match const_eval_expr(a.value, values):
                                Option.some as val:
                                    values.set(id.name, val.value)
                                Option.none:
                                    values.remove(id.name)
                        else:
                            values.remove(id.name)
                    _:
                        pass
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    match const_eval_expr(br.condition, values):
                        Option.some as sval:
                            if sval.value != 0:
                                result.push(ConstWrite(value = "true", line = iff.line, kind = "if"))
                            else:
                                result.push(ConstWrite(value = "false", line = iff.line, kind = "if"))
                        Option.none:
                            pass
                    walk_body_const(br.body, result)
                    bi += 1
                walk_body_const(iff.else_body, result)
            ast.Stmt.stmt_while as wh:
                match const_eval_expr(wh.condition, values):
                    Option.some as sval:
                        if sval.value == 0:
                            result.push(ConstWrite(value = "false", line = wh.line, kind = "while"))
                    Option.none:
                        pass
                walk_body_const(wh.body, result)
            _:
                pass


## Evaluate an expression to a constant integer value, or none.
## Resolves identifier lookups from the tracked values map.
function const_eval_expr(ep: ptr[ast.Expr]?, values: ref[map_mod.Map[str, int]]) -> Option[int]:
    let p = ep else:
        return Option[int].none
    unsafe:
        match read(p):
            ast.Expr.expr_integer_literal as il:
                return Option[int].some(value = cast_to_int(il.value))
            ast.Expr.expr_bool_literal as bl:
                if bl.value:
                    return Option[int].some(value = 1)
                return Option[int].some(value = 0)
            ast.Expr.expr_identifier as id:
                if id.name == "_":
                    return Option[int].none
                let vp = values.get(id.name)
                if vp != null:
                    return Option[int].some(value = unsafe: read(vp))
                return Option[int].none
            ast.Expr.expr_binary_op as b:
                match const_eval_expr(b.left, values):
                    Option.some as li:
                        match const_eval_expr(b.right, values):
                            Option.some as ri:
                                let lv = li.value
                                let rv = ri.value
                                if b.operator == "+":
                                    return Option[int].some(value = lv + rv)
                                else if b.operator == "-":
                                    return Option[int].some(value = lv - rv)
                                else if b.operator == "*":
                                    return Option[int].some(value = lv * rv)
                                else if b.operator == "/":
                                    if rv == 0:
                                        return Option[int].none
                                    return Option[int].some(value = lv / rv)
                                else if b.operator == "%":
                                    if rv == 0:
                                        return Option[int].none
                                    return Option[int].some(value = lv % rv)
                                else if b.operator == ">":
                                    if lv > rv:
                                        return Option[int].some(value = 1)
                                    return Option[int].some(value = 0)
                                else if b.operator == "<":
                                    if lv < rv:
                                        return Option[int].some(value = 1)
                                    return Option[int].some(value = 0)
                                else if b.operator == ">=":
                                    if lv >= rv:
                                        return Option[int].some(value = 1)
                                    return Option[int].some(value = 0)
                                else if b.operator == "<=":
                                    if lv <= rv:
                                        return Option[int].some(value = 1)
                                    return Option[int].some(value = 0)
                                else if b.operator == "==":
                                    if lv == rv:
                                        return Option[int].some(value = 1)
                                    return Option[int].some(value = 0)
                                else if b.operator == "!=":
                                    if lv != rv:
                                        return Option[int].some(value = 1)
                                    return Option[int].some(value = 0)
                                else if b.operator == "and":
                                    if lv != 0 and rv != 0:
                                        return Option[int].some(value = 1)
                                    return Option[int].some(value = 0)
                                else if b.operator == "or":
                                    if lv != 0 or rv != 0:
                                        return Option[int].some(value = 1)
                                    return Option[int].some(value = 0)
                                return Option[int].none
                            Option.none:
                                return Option[int].none
                    Option.none:
                        return Option[int].none
            ast.Expr.expr_unary_op as u:
                match const_eval_expr(u.operand, values):
                    Option.some as oi:
                        let ov = oi.value
                        if u.operator == "-":
                            return Option[int].some(value = (0 - ov))
                        else if u.operator == "not":
                            if ov == 0:
                                return Option[int].some(value = 1)
                            return Option[int].some(value = 0)
                        return Option[int].none
                    Option.none:
                        return Option[int].none
            _:
                return Option[int].none


## Cast a long literal value to int (the only type we track in constant propagation).
function cast_to_int(val: long) -> int:
    return unsafe: int<-(val)
