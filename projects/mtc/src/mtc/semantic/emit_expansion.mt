## Emit-macro expansion — walks top-level `const function` bodies and collects
## declarations produced by `emit` statements, appending them to the source file.
##
## Extracted from the semantic analyzer: all functions work purely with AST
## types (`ast.SourceFile`, `ast.Decl`, `ast.Stmt`) and have no dependency on
## the analyzer's `Context` / `Scope` or the type system.

import std.vec as vec

import mtc.parser.ast as ast


## Expand a source file: walk its top-level `const function` bodies collecting
## declarations from `emit` statements and append them to the file.  Returns
## `file` unchanged when no emit statements are present.
public function expand_emit_declarations(file: ast.SourceFile) -> ast.SourceFile:
    var emitted = vec.Vec[ast.Decl].create()
    collect_emit_declarations(file.declarations, ref_of(emitted))
    if emitted.len() == 0:
        emitted.release()
        return file

    var all_decls = vec.Vec[ast.Decl].create()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            all_decls.push(read(file.declarations.data + i))
        i += 1
    var j: ptr_uint = 0
    while j < emitted.len():
        let ep = emitted.get(j) else:
            break
        unsafe:
            all_decls.push(read(ep))
        j += 1
    emitted.release()

    return ast.SourceFile(
        module_kind = file.module_kind,
        imports = file.imports,
        directives = file.directives,
        declarations = all_decls.as_span(),
        line = file.line,
    )


function collect_emit_declarations(decls: span[ast.Decl], emitted: ref[vec.Vec[ast.Decl]]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_function as f:
                if f.is_const:
                    collect_emit_from_body(f.body, emitted)
            _:
                pass
        i += 1


function collect_emit_from_body(body: ptr[ast.Stmt]?, emitted: ref[vec.Vec[ast.Decl]]) -> void:
    let b = body else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                collect_emit_from_stmts(blk.statements, emitted)
            _:
                collect_emit_from_stmt(b, emitted)


function collect_emit_from_stmts(stmts: span[ast.Stmt], emitted: ref[vec.Vec[ast.Decl]]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            collect_emit_from_stmt(stmts.data + i, emitted)
        i += 1


function collect_emit_from_stmt(sp: ptr[ast.Stmt], emitted: ref[vec.Vec[ast.Decl]]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_emit as em:
                let decl_ptr = em.declaration else:
                    return
                emitted.push(read(decl_ptr))
            ast.Stmt.stmt_for as f:
                if f.is_inline:
                    collect_emit_from_body(f.body, emitted)
            ast.Stmt.stmt_while as w:
                if w.is_inline:
                    collect_emit_from_body(w.body, emitted)
            ast.Stmt.stmt_if as iff:
                if iff.is_inline:
                    var bi: ptr_uint = 0
                    while bi < iff.branches.len:
                        collect_emit_from_body(ptr[ast.Stmt]<-read(iff.branches.data + bi).body, emitted)
                        bi += 1
                    if iff.else_body != null:
                        collect_emit_from_body(iff.else_body, emitted)
            ast.Stmt.stmt_match as m:
                if m.is_inline:
                    var ai: ptr_uint = 0
                    while ai < m.arms.len:
                        collect_emit_from_body(read(m.arms.data + ai).body, emitted)
                        ai += 1
            _:
                pass
