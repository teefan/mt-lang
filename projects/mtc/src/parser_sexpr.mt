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


function emit_expr(exprs: ref[vec.Vec[ast.Expression]], idx: ptr_uint) -> void:
    if idx >= exprs.len():
        print_s("nil")
        return
    let e_ptr = exprs.get(idx) else:
        return
    var e = unsafe: read(ptr[ast.Expression]<-e_ptr)
    if e.kind == ast.EXPR_INTEGER:
        print_s(e.str_value)
    else if e.kind == ast.EXPR_FLOAT:
        print_s(e.str_value)
    else if e.kind == ast.EXPR_BOOLEAN:
        if e.bool_value:
            print_s("true")
        else:
            print_s("false")
    else if e.kind == ast.EXPR_NULL:
        print_s("nil")
    else if e.kind == ast.EXPR_IDENTIFIER:
        print_qstr(e.ident)
    else if e.kind == ast.EXPR_BINARY:
        print_open("a:binary")
        print_space()
        emit_expr(exprs, e.lhs_idx)
        print_space()
        print_s(lexer.kind_name(e.op_kind))
        print_space()
        emit_expr(exprs, e.rhs_idx)
        print_close()
    else if e.kind == ast.EXPR_UNARY:
        print_open("a:unary")
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
            emit_expr(exprs, unsafe: read(ptr[ptr_uint]<-ap))
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
    else:
        print_s("nil")


function emit_type_ref(t: ref[ast.TypeRef]) -> void:
    var self = unsafe: read(ptr[ast.TypeRef]<-t)
    if self.name_parts.len() == 0:
        print_s("nil")
        return
    let fp = self.name_parts.get(0) else:
        return
    print_qstr(unsafe: read(ptr[str]<-fp))


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
    print_s("] [] [")
    var di: ptr_uint = 0
    while di < sf.declarations.len():
        if di > 0:
            print_space()
        emit_stmt(ref_of(sf.declarations), di, ref_of(sf.exprs.exprs))
        di += 1
    print_s("] nil")
    print_close()
    stdio.print_char(int<-('\n'))


function emit_import(imports: ref[vec.Vec[ast.Import]], index: ptr_uint) -> void:
    let ip = imports.get(index) else:
        return
    var imp = unsafe: read(ptr[ast.Import]<-ip)
    print_open("a:import")
    print_space()
    emit_qn(ref_of(imp.path))
    print_space()
    if imp.alias_name.len > 0:
        print_qstr(imp.alias_name)
    else:
        print_s("nil")
    print_space()
    stdio.print_format("%d %d", imp.line, imp.column)
    print_close()


function emit_qn(qn: ref[ast.QualifiedName]) -> void:
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

    match s:
        ast.Statement.function_decl as fd:
            print_open("a:function_def")
            print_space()
            print_qstr(fd.name)
            print_space()
            print_s("[] [] ")
            emit_type_ref(ref_of(fd.ret))
            print_space()
            print_s("[")
            var i: ptr_uint = 0
            while i < fd.body.len():
                if i > 0:
                    print_space()
                emit_stmt(ref_of(fd.body), i, exprs)
                i += 1
            print_s("] :$private false false [] 0 0")
            print_close()
        ast.Statement.struct_decl as sd:
            print_open("a:struct_decl")
            print_space()
            print_qstr(sd.name)
            print_space()
            print_s("[] [] nil [")
            var i: ptr_uint = 0
            while i < sd.fields.len():
                if i > 0:
                    print_space()
                let fp = sd.fields.get(i) else:
                    break
                match unsafe: read(ptr[ast.Statement]<-fp):
                    ast.Statement.struct_decl as f2:
                        print_open("a:struct_field")
                        print_space()
                        print_qstr(f2.name)
                        print_space()
                        print_s("nil :$private 0")
                        print_close()
                    else:
                        print_s("nil")
                i += 1
            print_s("] nil :$private [] 0")
            print_close()
        ast.Statement.const_decl as cd:
            print_open("a:const_decl")
            print_space()
            print_qstr(cd.name)
            print_space()
            emit_type_ref(ref_of(cd.ctype))
            print_space()
            emit_expr(exprs, cd.value_idx)
            print_space()
            print_s(":$private 0 0")
            print_close()
        ast.Statement.enum_decl as ed:
            print_open("a:enum_decl")
            print_space()
            print_qstr(ed.name)
            print_space()
            emit_type_ref(ref_of(ed.backing))
            print_space()
            print_s("[")
            var i: ptr_uint = 0
            while i < ed.members.len():
                if i > 0:
                    print_space()
                let mp = ed.members.get(i) else:
                    break
                match unsafe: read(ptr[ast.Statement]<-mp):
                    ast.Statement.const_decl as md:
                        print_open("a:enum_member")
                        print_space()
                        print_qstr(md.name)
                        print_space()
                        emit_expr(exprs, md.value_idx)
                        print_space()
                        print_s("0")
                        print_close()
                    else:
                        print_s("nil")
                i += 1
            print_s("] :$private 0")
            print_close()
        ast.Statement.variant_decl as vd:
            print_open("a:variant_decl")
            print_space()
            print_qstr(vd.name)
            print_space()
            print_s("[] [] :$private [] 0")
            print_close()
        ast.Statement.opaque_decl as od:
            print_open("a:opaque_decl")
            print_space()
            print_qstr(od.name)
            print_space()
            print_s("[] nil :$private 0")
            print_close()
        ast.Statement.interface_decl as id:
            print_open("a:interface_decl")
            print_space()
            print_qstr(id.name)
            print_space()
            print_s("[] [] :$private [] 0")
            print_close()
        ast.Statement.type_alias_decl as ta:
            print_open("a:type_alias_decl")
            print_space()
            print_qstr(ta.name)
            print_space()
            emit_type_ref(ref_of(ta.target))
            print_space()
            print_s(":$private 0")
            print_close()
        ast.Statement.var_decl as vd2:
            print_open("a:var_decl")
            print_space()
            print_qstr(vd2.name)
            print_space()
            emit_type_ref(ref_of(vd2.vtype))
            print_space()
            emit_expr(exprs, vd2.value_idx)
            print_space()
            print_s(":$private 0 0")
            print_close()
        ast.Statement.union_decl as ud:
            print_open("a:union_decl")
            print_space()
            print_qstr(ud.name)
            print_space()
            print_s("[] :$private 0")
            print_close()
        ast.Statement.extending_block as eb:
            print_open("a:extending_block")
            print_space()
            print_qstr(eb.name)
            print_space()
            print_s("[] :$private [] 0")
            print_close()
        ast.Statement.static_assert_stmt as sa:
            print_open("a:static_assert")
            print_space()
            emit_expr(exprs, sa.cond_idx)
            print_space()
            if sa.message.len > 0:
                print_qstr(sa.message)
            else:
                print_s("nil")
            print_close()
        ast.Statement.attribute_decl as ad:
            print_open("a:attribute_decl")
            print_space()
            print_qstr(ad.name)
            print_space()
            print_s("[] nil :$private [] 0")
            print_close()
        ast.Statement.event_decl as ed2:
            print_open("a:event_decl")
            print_space()
            print_qstr(ed2.name)
            print_space()
            print_s("0 nil :$private 0")
            print_close()
        ast.Statement.when_stmt as ws:
            print_open("a:when_stmt")
            print_space()
            print_s("nil [] 0")
            print_close()
        ast.Statement.extern_function_decl as ef:
            print_open("a:extern_function_decl")
            print_space()
            print_qstr(ef.name)
            print_space()
            print_s("[] ")
            emit_type_ref(ref_of(ef.ret))
            print_space()
            print_s("[] 0")
            print_close()
        ast.Statement.let_decl as ld:
            print_open("a:let_decl")
            print_space()
            print_qstr(ld.name)
            print_space()
            emit_type_ref(ref_of(ld.ltype))
            print_space()
            emit_expr(exprs, ld.value_idx)
            print_close()
        ast.Statement.return_stmt as rs:
            print_open("a:return_stmt")
            print_space()
            emit_expr(exprs, rs.value_idx)
            print_close()
        ast.Statement.if_stmt as ist:
            print_open("a:if_stmt")
            print_space()
            emit_expr(exprs, ist.cond_idx)
            print_space()
            print_s("[")
            var bi: ptr_uint = 0
            while bi < ist.body.len():
                if bi > 0: print_space()
                emit_stmt(ref_of(ist.body), bi, exprs)
                bi += 1
            print_s("] [")
            var bj: ptr_uint = 0
            while bj < ist.else_body.len():
                if bj > 0: print_space()
                emit_stmt(ref_of(ist.else_body), bj, exprs)
                bj += 1
            print_s("]")
            print_close()
        ast.Statement.while_stmt as ws2:
            print_open("a:while_stmt")
            print_space()
            emit_expr(exprs, ws2.cond_idx)
            print_space()
            print_s("[")
            var wi: ptr_uint = 0
            while wi < ws2.body.len():
                if wi > 0: print_space()
                emit_stmt(ref_of(ws2.body), wi, exprs)
                wi += 1
            print_s("]")
            print_close()
        ast.Statement.for_stmt as fs:
            print_open("a:for_stmt")
            print_space()
            print_qstr(fs.binding)
            print_space()
            print_s("[")
            var fi: ptr_uint = 0
            while fi < fs.body.len():
                if fi > 0: print_space()
                emit_stmt(ref_of(fs.body), fi, exprs)
                fi += 1
            print_s("]")
            print_close()
        ast.Statement.assign_stmt as as2:
            print_open("a:assign_stmt")
            print_space()
            emit_expr(exprs, as2.target_idx)
            print_space()
            print_s(lexer.kind_name(as2.op_kind))
            print_space()
            emit_expr(exprs, as2.value_idx)
            print_close()
        ast.Statement.expr_stmt as es:
            print_open("a:expr_stmt")
            print_space()
            emit_expr(exprs, es.value_idx)
            print_close()
        ast.Statement.defer_stmt as ds:
            print_open("a:defer_stmt")
            print_space()
            print_s("[")
            var di: ptr_uint = 0
            while di < ds.body.len():
                if di > 0: print_space()
                emit_stmt(ref_of(ds.body), di, exprs)
                di += 1
            print_s("]")
            print_close()
        else:
            print_s("nil")