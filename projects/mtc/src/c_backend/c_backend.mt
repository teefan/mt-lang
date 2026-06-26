## Self-hosted Milk Tea C backend — reads IR JSON, emits C source.

import std.string as string_mod
import std.str
import std.vec as vec_mod

import c_backend.ir_reader as ir

public function emit_c(ir_json: str) -> string_mod.String:
    var output = string_mod.String.create()

    var program = ir.IrCursor.from_json(ir_json)

    emit_includes(program, ref_of(output))
    emit_constants(program, ref_of(output))
    emit_globals(program, ref_of(output))
    emit_opaques(program, ref_of(output))
    emit_enums(program, ref_of(output))
    emit_structs(program, ref_of(output))
    emit_variants(program, ref_of(output))
    emit_functions(program, ref_of(output))
    return output

# ── top-level emission ────────────────────────────────────────────────────

function emit_includes(program: ir.IrCursor, output: ref[string_mod.String]) -> void:
    let includes = program.field_array("includes")
    var elems = vec_mod.Vec[str].create()
    split_array_elements(includes, ref_of(elems))
    var ei: ptr_uint = 0
    while ei < elems.len:
        let e = elems.at(ei) else:
            break
        let cur = ir.IrCursor.from_json(e)
        let header = cur.field_str("header")
        output.append("#include ")
        output.append(header)
        output.push_byte('\n')
        ei += 1
    elems.release()
    if ei > 0:
        output.push_byte('\n')

function emit_constants(program: ir.IrCursor, output: ref[string_mod.String]) -> void:
    let arr = program.field_array("constants")
    var elems = vec_mod.Vec[str].create()
    split_array_elements(arr, ref_of(elems))
    var ei: ptr_uint = 0
    while ei < elems.len:
        let e = elems.at(ei) else:
            break
        let cur = ir.IrCursor.from_json(e)
        output.append("static const ")
        let t_obj = cur.field_obj("type")
        var tc = type_to_c(t_obj)
        output.append(tc.as_str())
        tc.release()
        output.append(" ")
        output.append(cur.field_str("linkage_name"))
        output.append(" = ")
        let val = cur.field_obj("value")
        emit_expression(val, output, "")
        output.append(";\n")
        ei += 1
    elems.release()

function emit_globals(program: ir.IrCursor, output: ref[string_mod.String]) -> void:
    let arr = program.field_array("globals")
    var elems = vec_mod.Vec[str].create()
    split_array_elements(arr, ref_of(elems))
    var ei: ptr_uint = 0
    while ei < elems.len:
        let e = elems.at(ei) else:
            break
        let cur = ir.IrCursor.from_json(e)
        output.append("static ")
        let t_obj = cur.field_obj("type")
        var tc = type_to_c(t_obj)
        output.append(tc.as_str())
        tc.release()
        output.append(" ")
        output.append(cur.field_str("linkage_name"))
        let val_obj = cur.field_obj("value")
        if val_obj.json != "":
            output.append(" = ")
            emit_expression(val_obj, output, "")
        output.append(";\n")
        ei += 1
    elems.release()

function emit_opaques(program: ir.IrCursor, output: ref[string_mod.String]) -> void:
    let arr = program.field_array("opaques")
    var elems = vec_mod.Vec[str].create()
    split_array_elements(arr, ref_of(elems))
    var ei: ptr_uint = 0
    while ei < elems.len:
        let e = elems.at(ei) else:
            break
        let cur = ir.IrCursor.from_json(e)
        output.append("typedef struct ")
        output.append(cur.field_str("linkage_name"))
        output.append(" ")
        output.append(cur.field_str("linkage_name"))
        output.append(";\n")
        ei += 1
    elems.release()

function emit_enums(program: ir.IrCursor, output: ref[string_mod.String]) -> void:
    let arr = program.field_array("enums")
    var elems = vec_mod.Vec[str].create()
    split_array_elements(arr, ref_of(elems))
    var ei: ptr_uint = 0
    while ei < elems.len:
        let e = elems.at(ei) else:
            break
        let cur = ir.IrCursor.from_json(e)
        output.append("enum ")
        output.append(cur.field_str("linkage_name"))
        output.append(" {\n")

        let members = cur.field_array("members")
        var mems = vec_mod.Vec[str].create()
        split_array_elements(members, ref_of(mems))
        var mi: ptr_uint = 0
        while mi < mems.len:
            let m = mems.at(mi) else:
                break
            let mc = ir.IrCursor.from_json(m)
            output.append("  ")
            output.append(mc.field_str("linkage_name"))
            output.append(" = ")
            let val_obj = mc.field_obj("value")
            emit_expression(val_obj, output, "")
            output.append(",\n")
            mi += 1
        mems.release()

        output.append("};\n")
        ei += 1
    elems.release()

function emit_structs(program: ir.IrCursor, output: ref[string_mod.String]) -> void:
    let arr = program.field_array("structs")
    var elems = vec_mod.Vec[str].create()
    split_array_elements(arr, ref_of(elems))
    var ei: ptr_uint = 0
    while ei < elems.len:
        let e = elems.at(ei) else:
            break
        let cur = ir.IrCursor.from_json(e)
        output.append("struct ")
        output.append(cur.field_str("linkage_name"))
        output.append(" {\n")

        let fields = cur.field_array("fields")
        var flds = vec_mod.Vec[str].create()
        split_array_elements(fields, ref_of(flds))
        var fi: ptr_uint = 0
        while fi < flds.len:
            let f = flds.at(fi) else:
                break
            let fc = ir.IrCursor.from_json(f)
            let ft_obj = fc.field_obj("type")
            output.append("  ")
            var _ct = c_type(ft_obj.field_str("name"))
            output.append(_ct.as_str())
            _ct.release()
            output.append(" ")
            output.append(fc.field_str("name"))
            output.append(";\n")
            fi += 1
        flds.release()

        output.append("};\n")
        ei += 1
    elems.release()

function emit_variants(program: ir.IrCursor, output: ref[string_mod.String]) -> void:
    let arr = program.field_array("variants")
    pass

# ── function emission ─────────────────────────────────────────────────────

function emit_functions(program: ir.IrCursor, output: ref[string_mod.String]) -> void:
    let fn_array = program.field_array("functions")
    var elements = vec_mod.Vec[str].create()
    split_array_elements(fn_array, ref_of(elements))

    var fwd = string_mod.String.create()
    var defs = string_mod.String.create()
    var ei: ptr_uint = 0
    while ei < elements.len:
        let elem = elements.at(ei) else:
            break
        let fn_cur = ir.IrCursor.from_json(elem)
        let kind = fn_cur.field_str("$mt_type")
        if kind != "IR:Function":
            ei += 1
            continue

        let link_name = fn_cur.field_str("linkage_name")
        let ret_obj = fn_cur.field_obj("return_type")
        var rtype = type_to_c(ret_obj)
        let rtype_str = rtype.as_str()
        let ep = fn_cur.field_bool("entry_point")
        let storage = if ep: "" else: "static "

        var fn_params = string_mod.String.create()
        let params_arr = fn_cur.field_array("params")
        var params = vec_mod.Vec[str].create()
        split_array_elements(params_arr, ref_of(params))
        var pi: ptr_uint = 0
        var first_param = true
        while pi < params.len:
            let p = params.at(pi) else:
                break
            if not first_param:
                fn_params.append(", ")
            first_param = false
            let pc = ir.IrCursor.from_json(p)
            let pt = pc.field_obj("type")
            var ctype = c_struct_type(pt)
            fn_params.append(ctype.as_str())
            ctype.release()
            fn_params.push_byte(' ')
            fn_params.append(pc.field_str("linkage_name"))
            pi += 1
        params.release()

        fwd.append(storage)
        fwd.append(rtype_str)
        fwd.append(" ")
        fwd.append(link_name)
        fwd.push_byte('(')
        if first_param:
            fwd.append("void")
        else:
            fwd.append(fn_params.as_str())
        fwd.append(");\n")

        defs.append(storage)
        defs.append(rtype_str)
        defs.append(" ")
        defs.append(link_name)
        defs.push_byte('(')
        if first_param:
            defs.append("void")
        else:
            defs.append(fn_params.as_str())
        defs.append(") {\n")

        let body_arr = fn_cur.field_array("body")
        emit_body(body_arr, ref_of(defs), "  ")

        defs.append("}\n\n")
        fn_params.release()
        rtype.release()
        ei += 1

    output.append(fwd.as_str())
    output.append(defs.as_str())
    fwd.release()
    defs.release()
    elements.release()

# ── array element splitting ───────────────────────────────────────────────

function split_array_elements(arr_json: str, output: ref[vec_mod.Vec[str]]) -> void:
    var i: ptr_uint = 1
    while i < arr_json.len:
        i = skip_ws_static(arr_json, i)
        if i >= arr_json.len or arr_json.byte_at(i) == ']':
            break
        let elem_end = find_json_value_end(arr_json, i)
        let elem = arr_json.slice(i, elem_end - i)
        output.push(elem)
        i = elem_end
        i = skip_ws_static(arr_json, i)
        if i < arr_json.len and arr_json.byte_at(i) == ',':
            i += 1

function find_json_value_end(s: str, start: ptr_uint) -> ptr_uint:
    var i = start
    if i >= s.len:
        return i
    let ch = s.byte_at(i)
    if ch == '{':
        return find_matching(s, i, '{', '}')
    else if ch == '[':
        return find_matching(s, i, '[', ']')
    else if ch == '"':
        i += 1
        while i < s.len:
            if s.byte_at(i) == '"':
                i += 1
                break
            else if s.byte_at(i) == '\\':
                i += 1
            i += 1
        return i
    else:
        while i < s.len:
            let c = s.byte_at(i)
            if c == ',' or c == '}' or c == ']' or c == ' ' or c == '\n' or c == '\r' or c == '\t':
                break
            i += 1
        return i

function skip_ws_static(s: str, start: ptr_uint) -> ptr_uint:
    var i = start
    while i < s.len and (s.byte_at(i) == ' ' or s.byte_at(i) == '\n' or s.byte_at(i) == '\r' or s.byte_at(i) == '\t'):
        i += 1
    return i

# ── body emission ─────────────────────────────────────────────────────────

function emit_body(body_json: str, output: ref[string_mod.String], indent: str) -> void:
    var elements = vec_mod.Vec[str].create()
    split_array_elements(body_json, ref_of(elements))
    var ei: ptr_uint = 0
    while ei < elements.len:
        let elem = elements.at(ei) else:
            break
        let stmt_cur = ir.IrCursor.from_json(elem)
        let kind = stmt_cur.field_str("$mt_type")
        output.append(indent)

        if kind == "IR:ReturnStmt":
            output.append("return")
            if not stmt_cur.field_is_null("value"):
                output.push_byte(' ')
                let val_obj = stmt_cur.field_obj("value")
                emit_expression(val_obj, output, indent)
            output.append(";\n")
        else if kind == "IR:ExpressionStmt":
            let expr_obj = stmt_cur.field_obj("expression")
            emit_expression(expr_obj, output, indent)
            output.append(";\n")
        else if kind == "IR:LocalDecl":
            let loc_name = stmt_cur.field_str("name")
            let loc_type_obj = stmt_cur.field_obj("type")
            var tc = type_to_c(loc_type_obj)
            output.append(tc.as_str())
            tc.release()
            output.append(" ")
            output.append(loc_name)
            if not stmt_cur.field_is_null("value"):
                output.append(" = ")
                let val_obj = stmt_cur.field_obj("value")
                emit_expression(val_obj, output, indent)
            output.append(";\n")
        else if kind == "IR:Assignment":
            let target_obj = stmt_cur.field_obj("target")
            emit_expression(target_obj, output, indent)
            output.push_byte(' ')
            output.append(stmt_cur.field_str("operator"))
            output.push_byte(' ')
            let val = stmt_cur.field_obj("value")
            emit_expression(val, output, indent)
            output.append(";\n")
        else if kind == "IR:IfStmt":
            output.append("if (")
            emit_expression(stmt_cur.field_obj("condition"), output, indent)
            output.append(") {\n")
            var nested = indent_more(indent)
            emit_body(stmt_cur.field_array("then_body"), output, nested.as_str())
            output.append(indent)
            output.append("}")
            if not stmt_cur.field_is_null("else_body"):
                output.append(" else {\n")
                emit_body(stmt_cur.field_array("else_body"), output, nested.as_str())
                output.append(indent)
                output.append("}")
            nested.release()
            output.push_byte('\n')
        else if kind == "IR:WhileStmt":
            output.append("while (")
            emit_expression(stmt_cur.field_obj("condition"), output, indent)
            output.append(") {\n")
            var nested = indent_more(indent)
            emit_body(stmt_cur.field_array("body"), output, nested.as_str())
            output.append(indent)
            output.append("}\n")
            nested.release()
        else if kind == "IR:BlockStmt":
            emit_body(stmt_cur.field_array("body"), output, indent)
        else if kind == "IR:SwitchStmt":
            emit_switch(stmt_cur, output, indent)
        else if kind == "IR:ForStmt":
            output.append("for (")
            emit_for_head_expr(stmt_cur.field_obj("init"), output, indent)
            output.append("; ")
            emit_expression(stmt_cur.field_obj("condition"), output, indent)
            output.append("; ")
            emit_for_head_expr(stmt_cur.field_obj("post"), output, indent)
            output.append(") {\n")
            var nested = indent_more(indent)
            emit_body(stmt_cur.field_array("body"), output, nested.as_str())
            output.append(indent)
            output.append("}\n")
            nested.release()
        else if kind == "IR:BreakStmt":
            output.append("break;\n")
        else if kind == "IR:ContinueStmt":
            output.append("continue;\n")
        else if kind == "IR:StaticAssert":
            output.append("_Static_assert(")
            emit_expression(stmt_cur.field_obj("condition"), output, indent)
            output.append(", \"")
            output.append(stmt_cur.field_str("message"))
            output.append("\");\n")
        else if kind == "IR:LabelStmt":
            output.append(stmt_cur.field_str("name"))
            output.append(":;\n")
        else if kind == "IR:GotoStmt":
            output.append("goto ")
            output.append(stmt_cur.field_str("label"))
            output.append(";\n")
        else:
            output.append("/* stmt:")
            output.append(kind)
            output.append(" */\n")

        ei += 1
    elements.release()

# ── expression emission ───────────────────────────────────────────────────

function emit_expression(expr: ir.IrCursor, output: ref[string_mod.String], indent: str) -> void:
    let kind = expr.field_str("$mt_type")

    if kind == "IR:IntegerLiteral":
        output.append(expr.field_str("value"))
    else if kind == "IR:FloatLiteral":
        output.append(expr.field_str("value"))
    else if kind == "IR:StringLiteral":
        output.push_byte('"')
        output.append(expr.field_str("value"))
        output.push_byte('"')
    else if kind == "IR:BooleanLiteral":
        output.append(expr.field_str("value"))
    else if kind == "IR:Name":
        output.append(expr.field_str("name"))
    else if kind == "IR:Member":
        emit_expression(expr.field_obj("receiver"), output, indent)
        output.push_byte('.')
        output.append(expr.field_str("member"))
    else if kind == "IR:Index":
        emit_expression(expr.field_obj("receiver"), output, indent)
        output.push_byte('[')
        emit_expression(expr.field_obj("index"), output, indent)
        output.push_byte(']')
    else if kind == "IR:CheckedIndex":
        emit_expression(expr.field_obj("receiver"), output, indent)
        output.push_byte('[')
        emit_expression(expr.field_obj("index"), output, indent)
        output.push_byte(']')
    else if kind == "IR:CheckedSpanIndex":
        emit_expression(expr.field_obj("receiver"), output, indent)
        output.push_byte('[')
        emit_expression(expr.field_obj("index"), output, indent)
        output.push_byte(']')
    else if kind == "IR:NullableIndex":
        emit_expression(expr.field_obj("receiver"), output, indent)
        output.push_byte('[')
        emit_expression(expr.field_obj("index"), output, indent)
        output.push_byte(']')
    else if kind == "IR:NullableSpanIndex":
        emit_expression(expr.field_obj("receiver"), output, indent)
        output.push_byte('[')
        emit_expression(expr.field_obj("index"), output, indent)
        output.push_byte(']')
    else if kind == "IR:Binary":
        let op = expr.field_str("operator")
        emit_expression(expr.field_obj("left"), output, indent)
        output.append(c_op(op))
        emit_expression(expr.field_obj("right"), output, indent)
    else if kind == "IR:Unary":
        output.append(expr.field_str("operator"))
        emit_expression(expr.field_obj("operand"), output, indent)
    else if kind == "IR:Call":
        emit_call(expr, output, indent)
    else if kind == "IR:Conditional":
        output.push_byte('(')
        emit_expression(expr.field_obj("condition"), output, indent)
        output.append(" ? ")
        emit_expression(expr.field_obj("then_expression"), output, indent)
        output.append(" : ")
        emit_expression(expr.field_obj("else_expression"), output, indent)
        output.push_byte(')')
    else if kind == "IR:ZeroInit":
        output.append("{0}")
    else if kind == "IR:NullLiteral":
        output.append("NULL")
    else if kind == "IR:AddressOf":
        output.push_byte('&')
        emit_expression(expr.field_obj("expression"), output, indent)
    else if kind == "IR:Cast":
        let target = expr.field_obj("target_type")
        output.push_byte('(')
        var _ct = c_type(target.field_str("name"))
        output.append(_ct.as_str())
        _ct.release()
        output.push_byte(')')
        emit_expression(expr.field_obj("expression"), output, indent)
    else if kind == "IR:AggregateLiteral":
        emit_aggregate(expr, output, indent)
    else if kind == "IR:ArrayLiteral":
        emit_aggregate(expr, output, indent)
    else if kind == "IR:VariantLiteral":
        output.append("{0}")
    else if kind == "IR:ReinterpretExpr":
        output.append("mt_reinterpret(")
        emit_expression(expr.field_obj("expression"), output, indent)
        output.append(")")
    else if kind == "IR:SizeofExpr":
        let t = expr.field_obj("target_type")
        output.append("sizeof(")
        var _ct = c_type(t.field_str("name"))
        output.append(_ct.as_str())
        _ct.release()
        output.append(")")
    else if kind == "IR:AlignofExpr":
        let t = expr.field_obj("target_type")
        output.append("_Alignof(")
        var _ct = c_type(t.field_str("name"))
        output.append(_ct.as_str())
        _ct.release()
        output.append(")")
    else if kind == "IR:OffsetofExpr":
        let t = expr.field_obj("target_type")
        let field = expr.field_str("field")
        output.append("offsetof(")
        var _ct = c_type(t.field_str("name"))
        output.append(_ct.as_str())
        _ct.release()
        output.append(", ")
        output.append(field)
        output.append(")")
    else:
        output.append("/* expr:")
        output.append(kind)
        output.append(" */")

function emit_aggregate(expr: ir.IrCursor, output: ref[string_mod.String], indent: str) -> void:
    output.push_byte('{')
    let fields = expr.field_array("fields")
    var flds = vec_mod.Vec[str].create()
    split_array_elements(fields, ref_of(flds))
    var fi: ptr_uint = 0
    var first = true
    while fi < flds.len:
        let f = flds.at(fi) else:
            break
        if not first:
            output.append(", ")
        first = false
        let fc = ir.IrCursor.from_json(f)
        output.push_byte('.')
        output.append(fc.field_str("name"))
        output.append(" = ")
        let fv = fc.field_obj("value")
        emit_expression(fv, output, indent)
        fi += 1
    flds.release()
    output.push_byte('}')

function emit_call(expr: ir.IrCursor, output: ref[string_mod.String], indent: str) -> void:
    let callee_raw = expr.field_str("callee")
    if callee_raw == "":
        emit_expression(expr.field_obj("callee"), output, indent)
    else:
        output.append(callee_raw)

    output.push_byte('(')
    let args = expr.field_array("arguments")
    var elems = vec_mod.Vec[str].create()
    split_array_elements(args, ref_of(elems))
    var ei: ptr_uint = 0
    var first = true
    while ei < elems.len:
        let elem = elems.at(ei) else:
            break
        if not first:
            output.append(", ")
        first = false
        emit_expression(ir.IrCursor.from_json(elem), output, indent)
        ei += 1
    elems.release()
    output.push_byte(')')

function emit_switch(stmt: ir.IrCursor, output: ref[string_mod.String], indent: str) -> void:
    output.append("switch (")
    emit_expression(stmt.field_obj("expression"), output, indent)
    output.append(") {\n")
    let cases_json = stmt.field_array("cases")
    var cases = vec_mod.Vec[str].create()
    split_array_elements(cases_json, ref_of(cases))
    var ci: ptr_uint = 0
    while ci < cases.len:
        let case_elem = cases.at(ci) else:
            break
        let case_cur = ir.IrCursor.from_json(case_elem)
        let case_kind = case_cur.field_str("$mt_type")
        if case_kind == "IR:SwitchDefaultCase":
            output.append(indent)
            output.append("  default:\n")
        else:
            output.append(indent)
            output.append("  case ")
            emit_expression(case_cur.field_obj("value"), output, indent)
            output.append(":\n")
        var case_indent = string_mod.String.create()
        case_indent.append(indent)
        case_indent.append("    ")
        emit_body(case_cur.field_array("body"), output, case_indent.as_str())
        case_indent.release()
        ci += 1
    cases.release()
    output.append(indent)
    output.append("}\n")

function emit_for_head_expr(node: ir.IrCursor, output: ref[string_mod.String], indent: str) -> void:
    let json = node.json
    if json == "":
        return

    let kind = node.field_str("$mt_type")
    if kind == "IR:LocalDecl":
        let loc_type_obj = node.field_obj("type")
        var tc = type_to_c(loc_type_obj)
        output.append(tc.as_str())
        tc.release()
        output.append(" ")
        output.append(node.field_str("name"))
        if not node.field_is_null("value"):
            output.append(" = ")
            emit_expression(node.field_obj("value"), output, indent)
    else if kind == "IR:Assignment":
        emit_expression(node.field_obj("target"), output, indent)
        output.append(" ")
        output.append(node.field_str("operator"))
        output.append(" ")
        emit_expression(node.field_obj("value"), output, indent)
    else:
        emit_expression(node, output, indent)

# ── helpers ───────────────────────────────────────────────────────────────

function find_matching(s: str, start: ptr_uint, open_ch: ubyte, close_ch: ubyte) -> ptr_uint:
    var i = start
    if i >= s.len or s.byte_at(i) != open_ch:
        return start + 1
    var depth: ptr_uint = 1
    i += 1
    while i < s.len and depth > 0:
        let ch = s.byte_at(i)
        if ch == '"':
            i += 1
            while i < s.len:
                if s.byte_at(i) == '"':
                    i += 1
                    break
                else if s.byte_at(i) == '\\':
                    i += 1
                i += 1
        else:
            if ch == open_ch:
                depth += 1
            else if ch == close_ch:
                depth -= 1
            i += 1
    return i

function c_op(op: str) -> str:
    if op == "+": return " + "
    if op == "-": return " - "
    if op == "*": return " * "
    if op == "/": return " / "
    if op == "%": return " % "
    if op == "==": return " == "
    if op == "!=": return " != "
    if op == "<": return " < "
    if op == "<=": return " <= "
    if op == ">": return " > "
    if op == ">=": return " >= "
    if op == "<<": return " << "
    if op == ">>": return " >> "
    if op == "&": return " & "
    if op == "|": return " | "
    if op == "^": return " ^ "
    if op == "and": return " && "
    if op == "or": return " || "
    return op

function type_to_c(type_obj: ir.IrCursor) -> string_mod.String:
    let tref = type_obj.field_str("$type_ref")
    if tref == "Struct" or tref == "Union":
        return c_struct_type(type_obj)

    return c_type_str(type_obj.field_str("name"))

function c_type_str(tref: str) -> string_mod.String:
    var result = string_mod.String.create()
    if tref == "int32_t" or tref == "int":
        result.append("int32_t")
    else if tref == "uint32_t" or tref == "uint":
        result.append("uint32_t")
    else if tref == "int8_t" or tref == "byte":
        result.append("int8_t")
    else if tref == "int64_t" or tref == "long":
        result.append("int64_t")
    else if tref == "bool":
        result.append("bool")
    else if tref == "float":
        result.append("float")
    else if tref == "double":
        result.append("double")
    else if tref == "void":
        result.append("void")
    else if tref == "char":
        result.append("char")
    else if tref == "str" or tref == "StringView":
        result.append("mt_str")
    else if tref == "cstr":
        result.append("const char*")
    else:
        result.append(tref)
    return result

function c_type(tref: str) -> string_mod.String:
    return c_type_str(tref)

function c_struct_type(type_obj: ir.IrCursor) -> string_mod.String:
    var result = string_mod.String.create()
    let name = type_obj.field_str("name")
    var lname = type_obj.field_str("linkage_name")
    if lname == "" or lname == "null":
        let mod_name = type_obj.field_str("module_name")
        var generated = string_mod.String.create()
        generated.append(mod_name)
        generated.push_byte('_')
        generated.append(name)
        result.append("struct ")
        result.append(generated.as_str())
        generated.release()
    else:
        result.append("struct ")
        result.append(lname)
    return result

function indent_more(indent: str) -> string_mod.String:
    var result = string_mod.String.create()
    result.append(indent)
    result.append("  ")
    return result
