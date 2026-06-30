import std.str as text
import std.stdio as stdio
import std.vec as vec
import stdio_ext
import ast
import lexer


public function emit_sexpr(source: ref[ast.SourceFile]) -> void:
    emit_source(source)
    stdio.print_char(int<-('\n'))


function pr(s: str) -> void:
    var k: ptr_uint = 0
    while k < s.len:
        stdio.print_char(int<-(s.byte_at(k)))
        k += 1


function sp() -> void:
    stdio.print_char(int<-(' '))


function pq(s: str) -> void:
    stdio_ext.print_quoted_str(s)


function pn() -> void:
    pr("nil")


function pf() -> void:
    pr("false")


function pt() -> void:
    pr("true")


function pl() -> void:
    pr("[]")


function tir(p: ref[vec.Vec[str]], n: bool) -> void:
    pr("(a:type_ref (a:qualified_name [")
    var i: ptr_uint = 0
    while i < p.len():
        if i > 0:
            sp()
        let pp = p.get(i) else:
            break
        pq(unsafe: read(ptr[str]<-pp))
        i += 1
    pr("] nil nil nil) [] ")
    if n:
        pr("true")
    else:
        pr("false")
    pr(" nil 0 0 0)")


function tir_empty() -> void:
    pr("(a:type_ref (a:qualified_name [] nil nil nil) [] false nil 0 0 0)")


function emit_e(exprs: ref[vec.Vec[ast.Expression]], idx: ptr_uint) -> void:
    if idx >= exprs.len():
        pn()
        return
    let e_ptr = exprs.get(idx) else:
        pn()
        return
    var e = unsafe: read(ptr[ast.Expression]<-e_ptr)
    if e.kind == ast.EXPR_INTEGER:
        pr("(a:integer_literal ")
        pq(e.str_value)
        sp()
        pr(e.str_value)
        pr(")")
    else if e.kind == ast.EXPR_FLOAT:
        pr("(a:float_literal ")
        pq(e.str_value)
        sp()
        pr(e.str_value)
        pr(")")
    else if e.kind == ast.EXPR_STRING:
        pr("(a:string_literal ")
        pq(e.str_value)
        pr(" nil false)")
    else if e.kind == ast.EXPR_BOOLEAN:
        pr("(a:boolean_literal ")
        if e.bool_value:
            pt()
        else:
            pf()
        pr(")")
    else if e.kind == ast.EXPR_NULL:
        pn()
    else if e.kind == ast.EXPR_IDENTIFIER:
        pr("(a:identifier ")
        pq(e.ident)
        pr(" 0 0)")
    else if e.kind == ast.EXPR_BINARY:
        pr("(a:binary_op ")
        pq(lexer.op_lexeme(e.op_kind))
        sp()
        emit_e(exprs, e.lhs_idx)
        sp()
        emit_e(exprs, e.rhs_idx)
        pr(")")
    else if e.kind == ast.EXPR_UNARY:
        pr("(a:unary_op ")
        pq(lexer.op_lexeme(e.op_kind))
        sp()
        emit_e(exprs, e.lhs_idx)
        pr(")")
    else if e.kind == ast.EXPR_CALL:
        pr("(a:call ")
        emit_e(exprs, e.lhs_idx)
        pr(" [")
        var ai: ptr_uint = 0
        while ai < e.args.len():
            if ai > 0:
                sp()
            let ap = e.args.get(ai) else:
                break
            emit_e(exprs, unsafe: read(ptr[ptr_uint]<-ap))
            ai += 1
        pr("])")
    else if e.kind == ast.EXPR_MEMBER:
        pr("(a:member_access ")
        emit_e(exprs, e.lhs_idx)
        sp()
        pq(e.str_value)
        pr(" 0 0)")
    else:
        pn()


function emit_source(sf: ref[ast.SourceFile]) -> void:
    var exprs = ref_of(sf.exprs.exprs)

    pr("(a:source_file (a:qualified_name [] nil nil nil) :$module [")
    var ii: ptr_uint = 0
    while ii < sf.imports.len():
        if ii > 0:
            sp()
        let ip = sf.imports.get(ii) else:
            break
        var imp = unsafe: read(ptr[ast.Import]<-ip)
        pr("(a:import (a:qualified_name [")
        var pi: ptr_uint = 0
        while pi < imp.path.parts.len():
            if pi > 0:
                sp()
            let pp = imp.path.parts.get(pi) else:
                break
            pq(unsafe: read(ptr[str]<-pp))
            pi += 1
        pr("] nil nil nil) ")
        if imp.alias_name.len > 0:
            pq(imp.alias_name)
        else:
            pn()
        sp()
        stdio.print_format("%d %d %d", imp.line, imp.column, imp.alias_name.len)
        pr(")")
        ii += 1
    pr("] [] [")
    var di: ptr_uint = 0
    while di < sf.declarations.len():
        if di > 0:
            sp()
        emit_s(ref_of(sf.declarations), di, exprs)
        di += 1
    pr("] nil)")


function emit_s(decls: ref[vec.Vec[ast.Statement]], index: ptr_uint,
                exprs: ref[vec.Vec[ast.Expression]]) -> void:
    let dp = decls.get(index) else:
        return
    var s = unsafe: read(ptr[ast.Statement]<-dp)

    match s:
        ast.Statement.function_decl as fd:
            pr("(a:function_def ")
            pq(fd.name)
            pr(" [] ")
            # params
            pr("[")
            var pi: ptr_uint = 0
            while pi < fd.params.len():
                if pi > 0:
                    sp()
                let pp = fd.params.get(pi) else:
                    break
                var pv = unsafe: read(ptr[ast.Param]<-pp)
                pr("(a:param ")
                pq(pv.name)
                pr(" ")
                tir(ref_of(pv.param_type.name_parts), pv.param_type.nullable)
                pr(" 0 0)")
                pi += 1
            pr("] ")
            if fd.ret.name_parts.len() > 0:
                tir(ref_of(fd.ret.name_parts), fd.ret.nullable)
            else:
                tir_empty()
            pr(" [")
            var i: ptr_uint = 0
            while i < fd.body.len():
                if i > 0:
                    sp()
                emit_s(ref_of(fd.body), i, exprs)
                i += 1
            pr("] :$private false false [] 0 0)")
        ast.Statement.struct_decl as sd:
            pr("(a:struct_decl ")
            pq(sd.name)
            pr(" [] [] nil [")
            var i: ptr_uint = 0
            while i < sd.fields.len():
                if i > 0:
                    sp()
                let fp = sd.fields.get(i) else:
                    break
                match unsafe: read(ptr[ast.Statement]<-fp):
                    ast.Statement.struct_field as f2:
                        pr("(a:field ")
                        pq(f2.name)
                        pr(" ")
                        tir(ref_of(f2.ftype.name_parts), f2.ftype.nullable)
                        pr(" [] 0 0)")
                    else:
                        pn()
                i += 1
            pr("] [] [] false nil :$private [] 0 0)")
        ast.Statement.const_decl as cd:
            pr("(a:const_decl ")
            pq(cd.name)
            pr(" ")
            tir(ref_of(cd.ctype.name_parts), cd.ctype.nullable)
            pr(" ")
            emit_e(exprs, cd.value_idx)
            pr(" nil :$private [] 0 0)")
        ast.Statement.let_decl as ld:
            pr("(a:local_decl :$let ")
            pq(ld.name)
            pr(" ")
            if ld.ltype.name_parts.len() > 0:
                tir(ref_of(ld.ltype.name_parts), ld.ltype.nullable)
            else:
                tir_empty()
            pr(" ")
            emit_e(exprs, ld.value_idx)
            pr(" nil nil [] 0 0)")
        ast.Statement.return_stmt as rs:
            pr("(a:return_stmt ")
            emit_e(exprs, rs.value_idx)
            pr(" 0 0 0)")
        ast.Statement.if_stmt as ist:
            pr("(a:if_stmt [(a:if_branch ")
            emit_e(exprs, ist.cond_idx)
            pr(" [")
            var i: ptr_uint = 0
            while i < ist.body.len():
                if i > 0:
                    sp()
                emit_s(ref_of(ist.body), i, exprs)
                i += 1
            pr("] 0 0)] [")
            var j: ptr_uint = 0
            while j < ist.else_body.len():
                if j > 0:
                    sp()
                emit_s(ref_of(ist.else_body), j, exprs)
                j += 1
            pr("] false 0 0 0)")
        ast.Statement.while_stmt as ws2:
            pr("(a:while_stmt ")
            emit_e(exprs, ws2.cond_idx)
            pr(" [")
            var i: ptr_uint = 0
            while i < ws2.body.len():
                if i > 0:
                    sp()
                emit_s(ref_of(ws2.body), i, exprs)
                i += 1
            pr("] false 0 0 0)")
        ast.Statement.for_stmt as fs:
            pr("(a:for_stmt [")
            pq(fs.binding)
            pr("] [] [")
            var i: ptr_uint = 0
            while i < fs.body.len():
                if i > 0:
                    sp()
                emit_s(ref_of(fs.body), i, exprs)
                i += 1
            pr("] false false 0 0)")
        ast.Statement.assign_stmt as as2:
            pr("(a:assignment ")
            emit_e(exprs, as2.target_idx)
            pr(" ")
            pq(lexer.op_lexeme(as2.op_kind))
            pr(" ")
            emit_e(exprs, as2.value_idx)
            pr(" 0 0)")
        ast.Statement.expr_stmt as es:
            pr("(a:expression_stmt ")
            emit_e(exprs, es.value_idx)
            pr(" 0)")
        ast.Statement.defer_stmt as ds:
            pr("(a:defer_stmt nil [")
            var i: ptr_uint = 0
            while i < ds.body.len():
                if i > 0:
                    sp()
                emit_s(ref_of(ds.body), i, exprs)
                i += 1
            pr("] 0 0 0)")
        ast.Statement.enum_decl as ed:
            pr("(a:enum_decl ")
            pq(ed.name)
            pr(" ")
            tir(ref_of(ed.backing.name_parts), ed.backing.nullable)
            pr(" [")
            var i: ptr_uint = 0
            while i < ed.members.len():
                if i > 0:
                    sp()
                let mp = ed.members.get(i) else:
                    break
                match unsafe: read(ptr[ast.Statement]<-mp):
                    ast.Statement.const_decl as md:
                        pr("(a:enum_member ")
                        pq(md.name)
                        pr(" ")
                        emit_e(exprs, md.value_idx)
                        pr(" 0 0)")
                    else:
                        pn()
                i += 1
            pr("] :$private [] 0 0)")
        ast.Statement.variant_decl as vd:
            pr("(a:variant_decl ")
            pq(vd.name)
            pr(" [] [] :$private [] 0 0)")
        ast.Statement.opaque_decl as od:
            pr("(a:opaque_decl ")
            pq(od.name)
            pr(" [] nil :$private 0 0)")
        ast.Statement.interface_decl as id:
            pr("(a:interface_decl ")
            pq(id.name)
            pr(" [] [] :$private 0 0)")
        ast.Statement.type_alias_decl as ta:
            pr("(a:type_alias_decl ")
            pq(ta.name)
            pr(" ")
            tir(ref_of(ta.target.name_parts), ta.target.nullable)
            pr(" :$private 0 0)")
        ast.Statement.var_decl as vd2:
            pr("(a:var_decl ")
            pq(vd2.name)
            pr(" ")
            tir(ref_of(vd2.vtype.name_parts), vd2.vtype.nullable)
            pr(" ")
            emit_e(exprs, vd2.value_idx)
            pr(" :$private 0 0)")
        ast.Statement.union_decl as ud:
            pr("(a:union_decl ")
            pq(ud.name)
            pr(" nil [] :$private [] 0 0)")
        ast.Statement.extending_block as eb:
            pr("(a:extending_block (a:identifier ")
            pq(eb.name)
            pr(" 0 0) [] 0 0)")
        ast.Statement.static_assert_stmt as sa:
            pr("(a:static_assert ")
            emit_e(exprs, sa.cond_idx)
            pr(" ")
            if sa.message.len > 0:
                pq(sa.message)
            else:
                pr("\"\"")
            pr(" 0)")
        ast.Statement.attribute_decl as ad:
            pr("(a:attribute_decl ")
            pq(ad.name)
            pr(" [] [] :$private 0 0)")
        ast.Statement.event_decl as ed2:
            pr("(a:event_decl ")
            pq(ed2.name)
            pr(" ")
            stdio.print_format("%lu", ed2.capacity)
            pr(" nil :$public [] 0 0)")
        ast.Statement.when_stmt as ws:
            pr("(a:when_stmt nil [] [] 0 0 0)")
        ast.Statement.extern_function_decl as ef:
            pr("(a:extern_function_decl ")
            pq(ef.name)
            pr(" [] [] ")
            tir(ref_of(ef.ret.name_parts), ef.ret.nullable)
            pr(" false [] 0)")
        else:
            pn()