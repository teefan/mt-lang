import std.str as text
import std.stdio as stdio
import std.vec as vec
import ast
import lexer


public function emit_sexpr(source: ref[ast.SourceFile]) -> void:
    emit_source_file(source)


function print_s(s: str) -> void:
    var k: ptr_uint = 0
    while k < s.len:
        stdio.print_char(int<-(s.byte_at(k)))
        k += 1


function print_open(tag: str) -> void:
    print_s("(")
    print_s(tag)


function print_close() -> void:
    print_s(")")


function print_space() -> void:
    stdio.print_char(int<-(' '))


function print_int(val: int) -> void:
    stdio.print_format("%d", val)


function print_int_l(val: ptr_uint) -> void:
    stdio.print_format("%lu", val)


# ── quoted string ──────────────────────────────────────────────────

function print_qstr(s: str) -> void:
    stdio.print_char(int<-('\"'))
    var k: ptr_uint = 0
    while k < s.len:
        let b = s.byte_at(k)
        if b == '\n':
            stdio.print_char(int<-('\\'))
            stdio.print_char(int<-('n'))
        else if b == '\r':
            stdio.print_char(int<-('\\'))
            stdio.print_char(int<-('r'))
        else if b == '\t':
            stdio.print_char(int<-('\\'))
            stdio.print_char(int<-('t'))
        else if b == '\\':
            stdio.print_char(int<-('\\'))
            stdio.print_char(int<-('\\'))
        else if b == '\"':
            stdio.print_char(int<-('\\'))
            stdio.print_char(int<-('\"'))
        else:
            stdio.print_char(int<-(b))
        k += 1
    stdio.print_char(int<-('\"'))


# ── expressions ─────────────────────────────────────────────────────

function emit_expr(exprs: ref[vec.Vec[ast.Expression]], idx: ptr_uint) -> void:
    if idx == 0 or idx > exprs.len():
        print_s("nil")
        return
    let e_ptr = exprs.get(idx) else:
        return
    var e = unsafe: read(ptr[ast.Expression]<-e_ptr)

    if e.kind == ast.EXPR_INTEGER:
        print_s(e.str_value)
    else if e.kind == ast.EXPR_FLOAT:
        print_s(e.str_value)
    else if e.kind == ast.EXPR_STRING:
        print_qstr(e.str_value)
    else if e.kind == ast.EXPR_BOOLEAN:
        if e.bool_value:
            print_s("true")
        else:
            print_s("false")
    else if e.kind == ast.EXPR_NULL:
        print_s("nil")
    else if e.kind == ast.EXPR_IDENTIFIER:
        print_open("a:identifier")
        print_space()
        print_qstr(e.ident)
        print_close()
    else if e.kind == ast.EXPR_BINARY:
        print_open("a:binary_op")
        print_space()
        emit_expr(exprs, e.lhs_idx)
        print_space()
        print_s(lexer.kind_name(e.op_kind))
        print_space()
        emit_expr(exprs, e.rhs_idx)
        print_close()
    else if e.kind == ast.EXPR_UNARY:
        print_open("a:unary_op")
        print_space()
        print_s(lexer.kind_name(e.op_kind))
        print_space()
        emit_expr(exprs, e.lhs_idx)
        print_close()
    else if e.kind == ast.EXPR_CALL:
        print_open("a:call")
        print_space()
        emit_expr(exprs, e.lhs_idx)
        print_space()
        print_s("[")
        var ai: ptr_uint = 0
        while ai < e.args.len():
            if ai > 0:
                print_space()
            let ap = e.args.get(ai) else:
                break
            let a_idx = unsafe: read(ptr[ptr_uint]<-ap)
            emit_expr(exprs, a_idx)
            ai += 1
        print_s("]")
        print_close()
    else if e.kind == ast.EXPR_MEMBER:
        print_open("a:member")
        print_space()
        emit_expr(exprs, e.lhs_idx)
        print_space()
        print_qstr(e.str_value)
        print_close()
    else if e.kind == ast.EXPR_ERROR:
        print_s("nil")


# ── types ────────────────────────────────────────────────────────────

function emit_type_ref(t: ref[ast.TypeRef]) -> void:
    var self = unsafe: read(ptr[ast.TypeRef]<-t)
    if self.name_parts.len() == 0:
        print_s("nil")
        return
    print_open("t:primitive")
    print_space()
    print_s(":name")
    print_space()
    let first_ptr = self.name_parts.get(0) else:
        fatal("parser_sexpr: empty type name")
    print_qstr(unsafe: read(ptr[str]<-first_ptr))

    if self.name_parts.len() > 1:
        print_space()
        print_s(":subtype")
        print_space()
        var sub = vec.Vec[str].create()
        var i: ptr_uint = 1
        while i < self.name_parts.len():
            let sp = self.name_parts.get(i) else:
                break
            sub.push(unsafe: read(ptr[str]<-sp))
            i += 1
        var qn_parts = vec.Vec[str].create()
        print_s("[")
        var j: ptr_uint = 0
        while j < sub.len():
            if j > 0:
                print_space()
            let pp = sub.get(j) else:
                break
            print_qstr(unsafe: read(ptr[str]<-pp))
            j += 1
        print_s("]")
        sub.release()
        qn_parts.release()

    if self.nullable:
        print_space()
        print_s(":nullable true")
    if self.is_function_type:
        print_space()
        print_s(":is_fn true")
    print_close()


# ── statements / declarations ────────────────────────────────────────

function emit_source_file(sf: ref[ast.SourceFile]) -> void:
    print_open("a:source_file")
    print_space()
    print_qstr(sf.module_name)
    print_space()
    print_s(":$module")
    print_space()
    print_s("[")
    var ii: ptr_uint = 0
    while ii < sf.imports.len():
        if ii > 0:
            print_space()
        emit_import(ref_of(sf.imports), ii)
        ii += 1
    print_s("]")
    print_space()
    print_s("[]")
    print_space()
    print_s("[")
    var di: ptr_uint = 0
    while di < sf.declarations.len():
        if di > 0:
            print_space()
        emit_stmt(ref_of(sf.declarations), di, ref_of(sf.exprs.exprs))
        di += 1
    print_s("]")
    print_space()
    print_s("nil")
    print_close()
    stdio.print_char(int<-('\n'))


function emit_import(imports: ref[vec.Vec[ast.Import]], index: ptr_uint) -> void:
    let ip = imports.get(index) else:
        return
    var imp = unsafe: read(ptr[ast.Import]<-ip)
    print_open("a:import")
    print_space()
    emit_qualified_name(ref_of(imp.path))
    print_space()
    if imp.alias_name.len > 0:
        print_qstr(imp.alias_name)
    else:
        print_s("nil")
    print_space()
    print_int(imp.line)
    print_space()
    print_int(imp.column)
    print_close()


function emit_qualified_name(qn: ref[ast.QualifiedName]) -> void:
    print_open("a:qualified_name")
    print_space()
    print_s("[")
    var i: ptr_uint = 0
    while i < qn.parts.len():
        if i > 0:
            print_space()
        let pp = qn.parts.get(i) else:
            break
        print_qstr(unsafe: read(ptr[str]<-pp))
        i += 1
    print_s("]")
    print_close()


function emit_stmt(decls: ref[vec.Vec[ast.Statement]], index: ptr_uint,
                    exprs: ref[vec.Vec[ast.Expression]]) -> void:
    let dp = decls.get(index) else:
        return
    var s = unsafe: read(ptr[ast.Statement]<-dp)

    if s.kind == ast.STMT_FUNCTION:
        emit_function(ref_of(s), exprs)
    else if s.kind == ast.STMT_STRUCT:
        emit_struct(ref_of(s), exprs)
    else if s.kind == ast.STMT_CONST:
        emit_const(ref_of(s), exprs)
    else if s.kind == ast.STMT_ENUM:
        emit_enum(ref_of(s), exprs)
    else if s.kind == ast.STMT_VARIANT:
        emit_variant(ref_of(s), exprs)
    else if s.kind == ast.STMT_OPAQUE:
        emit_opaque(ref_of(s), exprs)
    else if s.kind == ast.STMT_INTERFACE:
        emit_interface(ref_of(s), exprs)
    else if s.kind == ast.STMT_TYPE_ALIAS:
        emit_type_alias(ref_of(s), exprs)
    else if s.kind == ast.STMT_VAR:
        emit_var(ref_of(s), exprs)
    else:
        print_s("nil")


function emit_function(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:function_def")
    print_space()
    print_qstr(s.name)
    print_space()
    print_s("[]")
    print_space()
    print_s("[]")
    print_space()
    emit_type_ref(ref_of(s.stmt_type))
    print_space()
    print_s("[")
    var i: ptr_uint = 0
    while i < s.children.len():
        if i > 0:
            print_space()
        emit_stmt(ref_of(s.children), i, exprs)
        i += 1
    print_s("]")
    print_space()
    print_s(":$private")
    print_space()
    print_s("false")
    print_space()
    print_s("false")
    print_space()
    print_s("[]")
    print_space()
    print_int(s.line)
    print_space()
    print_int(s.column)
    print_close()


function emit_struct(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:struct_decl")
    print_space()
    print_qstr(s.name)
    print_space()
    print_s("[]")
    print_space()
    print_s("[]")
    print_space()
    print_s("[")
    var i: ptr_uint = 0
    while i < s.children.len():
        if i > 0:
            print_space()
        let fp = s.children.get(i) else:
            break
        var f = unsafe: read(ptr[ast.Statement]<-fp)
        print_open("a:struct_field")
        print_space()
        print_qstr(f.name)
        print_space()
        emit_type_ref(ref_of(f.stmt_type))
        print_space()
        print_s(":$private")
        print_space()
        print_int(f.line)
        print_close()
        i += 1
    print_s("]")
    print_space()
    print_s("nil")
    print_space()
    print_s(":$private")
    print_space()
    print_s("[]")
    print_space()
    print_int(s.line)
    print_close()


function emit_const(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:const_decl")
    print_space()
    print_qstr(s.name)
    print_space()
    emit_type_ref(ref_of(s.stmt_type))
    print_space()
    emit_expr(exprs, ptr_uint<-(s.expr))
    print_space()
    print_s(":$private")
    print_space()
    print_int(s.line)
    print_space()
    print_int(s.column)
    print_close()


function emit_enum(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:enum_decl")
    print_space()
    print_qstr(s.name)
    print_space()
    emit_type_ref(ref_of(s.stmt_type))
    print_space()
    print_s("[")
    var i: ptr_uint = 0
    while i < s.children.len():
        if i > 0:
            print_space()
        let mp = s.children.get(i) else:
            break
        var m = unsafe: read(ptr[ast.Statement]<-mp)
        print_open("a:enum_member")
        print_space()
        print_qstr(m.name)
        print_space()
        emit_expr(exprs, ptr_uint<-(m.expr))
        print_space()
        print_int(m.line)
        print_close()
        i += 1
    print_s("]")
    print_space()
    print_s(":$private")
    print_space()
    print_int(s.line)
    print_close()


function emit_variant(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:variant_decl")
    print_space()
    print_qstr(s.name)
    print_space()
    print_s("[]")
    print_space()
    print_s("[]")
    print_space()
    print_s(":$private")
    print_space()
    print_s("[]")
    print_space()
    print_int(s.line)
    print_close()


function emit_opaque(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:opaque_decl")
    print_space()
    print_qstr(s.name)
    print_space()
    print_s("[]")
    print_space()
    print_s("nil")
    print_space()
    print_s(":$private")
    print_space()
    print_int(s.line)
    print_close()


function emit_interface(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:interface_decl")
    print_space()
    print_qstr(s.name)
    print_space()
    print_s("[]")
    print_space()
    print_s("[]")
    print_space()
    print_s(":$private")
    print_space()
    print_s("[]")
    print_space()
    print_int(s.line)
    print_close()


function emit_type_alias(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:type_alias_decl")
    print_space()
    print_qstr(s.name)
    print_space()
    emit_type_ref(ref_of(s.stmt_type))
    print_space()
    print_s(":$private")
    print_space()
    print_int(s.line)
    print_close()


function emit_var(s: ref[ast.Statement], exprs: ref[vec.Vec[ast.Expression]]) -> void:
    print_open("a:var_decl")
    print_space()
    print_qstr(s.name)
    print_space()
    emit_type_ref(ref_of(s.stmt_type))
    print_space()
    emit_expr(exprs, ptr_uint<-(s.expr))
    print_space()
    print_s(":$private")
    print_space()
    print_int(s.line)
    print_space()
    print_int(s.column)
    print_close()