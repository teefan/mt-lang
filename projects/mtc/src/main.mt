import compiler.codegen.c_backend as cg
import compiler.context as ctx_mod
import compiler.lexer.lexer as lexer_mod
import compiler.lowering.lowerer as lowerer_mod
import compiler.parser.ast as ast
import compiler.parser.parser as parser_mod
import compiler.sema.checker as checker_mod
import compiler.source as source_mod
import std.fs
import std.intern
import std.map
import std.str
import std.stdio
import std.vec


function build_file(path: str) -> int:
    let file_result = fs.read_bytes(path)
    let file_bytes_obj = file_result else:
        stdio.print_line("error: cannot read file")
        return 1
    let file_bytes = file_bytes_obj.as_span()
    if file_bytes.len == ptr_uint<-0:
        stdio.print_line("error: empty file")
        return 1

    let source = source_mod.from_str("", path)
    var ctx = ctx_mod.create(source)

    var all_decls = vec.Vec[ptr[ast.Decl]].create()
    let base_dir = extract_dir(path)
    flatten_file(file_bytes, base_dir, ref_of(ctx.interner), ref_of(all_decls), 0)
    if all_decls.len == 0:
        stdio.print_line("error: no declarations")
        return 1

    var imports = vec.Vec[ptr[ast.Decl]].create()
    var merged = ast.SourceFile(
        name = "",
        imports = imports,
        decls = all_decls,
    )

    var checker = checker_mod.create(ctx.registry, ref_of(ctx.interner))
    let ok = checker.check(ptr_of(merged))
    if not ok:
        return 1

    let ir = lowerer_mod.lower(ptr_of(merged), ptr_of(ctx.interner), ctx.registry)
    let c_source = cg.write_program(ir, ctx.registry)
    stdio.print_line(c_source)
    return 0


function flatten_file(
    file_bytes: span[ubyte],
    base_dir: str,
    interner_ref: ref[intern.Interner],
    all_decls: ref[vec.Vec[ptr[ast.Decl]]],
    depth: ptr_uint,
) -> void:
    if depth > 16:
        return
    var tokens = lexer_mod.lex(file_bytes, interner_ref)
    let tokens_span = tokens.as_span()
    let ast_file = parser_mod.parse(file_bytes, tokens_span, ptr_of(interner_ref))
    var decls_span: span[ptr[ast.Decl]]
    var imports_span: span[ptr[ast.Decl]]
    unsafe:
        decls_span = read(ast_file).decls.as_span()
        imports_span = read(ast_file).imports.as_span()
    var ii: ptr_uint = 0
    while ii < imports_span.len:
        let imp = unsafe: read(imports_span.data + ii)
        try_load_import(imp, base_dir, interner_ref, all_decls, depth)
        ii += 1
    var i: ptr_uint = 0
    while i < decls_span.len:
        let decl = unsafe: read(decls_span.data + i)
        all_decls.push(decl)
        i += 1


function try_load_import(
    decl: ptr[ast.Decl],
    base_dir: str,
    interner_ref: ref[intern.Interner],
    all_decls: ref[vec.Vec[ptr[ast.Decl]]],
    depth: ptr_uint,
) -> void:
    unsafe:
        match read(decl):
            ast.Decl.import_decl(path, _, _):
                if path.len == 0:
                    return
                var fp: str_buffer[1024]
                fp.append(base_dir)
                var si: ptr_uint = 0
                while si < path.len:
                    var seg_id: ast.IdentId
                    unsafe:
                        seg_id = read(path.data + si)
                    let seg_str = interner_ref.lookup(seg_id) else:
                        return
                    if si > 0:
                        fp.append("/")
                    fp.append(seg_str)
                    si += 1
                fp.append(".mt")
                let fp_str = fp.as_str()
                let fr = fs.read_bytes(fp_str)
                let fb = fr else:
                    return
                let fbytes = fb.as_span()
                let sub_dir = extract_dir(fp_str)
                flatten_file(fbytes, sub_dir, interner_ref, all_decls, depth + 1)
            _:
                return


function extract_dir(path: str) -> str:
    var i: ptr_uint
    i = path.len
    while i > 0:
        i -= 1
        unsafe:
            let ch = read(path.data + i)
            if ch == 47:
                return str(data = path.data, len = i + 1)
    return ""


## ── check with imports ────────────────────────────────────────────

function check_with_imports(
    file: ptr[ast.SourceFile],
    base_dir: str,
    ctx: ptr[ctx_mod.Context],
    chk: ref[checker_mod.Checker],
    interner_ref: ref[intern.Interner],
) -> void:
    var loaded = vec.Vec[ast.IdentId].create()
    load_imports(file, base_dir, ctx, chk, interner_ref, ref_of(loaded), 0)


function load_imports(
    file: ptr[ast.SourceFile],
    base_dir: str,
    ctx: ptr[ctx_mod.Context],
    chk: ref[checker_mod.Checker],
    interner_ref: ref[intern.Interner],
    loaded: ref[vec.Vec[ast.IdentId]],
    depth: ptr_uint,
) -> void:
    if depth > 3:
        return
    var imports_span: span[ptr[ast.Decl]]
    unsafe: imports_span = read(file).imports.as_span()
    var ii: ptr_uint = 0
    while ii < imports_span.len:
        let decl = unsafe: read(imports_span.data + ii)
        ii += 1
        load_one_import(decl, base_dir, ctx, chk, interner_ref, loaded, depth)


function load_one_import(
    decl: ptr[ast.Decl],
    base_dir: str,
    ctx: ptr[ctx_mod.Context],
    chk: ref[checker_mod.Checker],
    interner_ref: ref[intern.Interner],
    loaded: ref[vec.Vec[ast.IdentId]],
    depth: ptr_uint,
) -> void:
    var import_path: span[ast.IdentId]
    import_path.len = 0
    import_path.data = zero[ptr[ast.IdentId]]
    unsafe:
        match read(decl):
            ast.Decl.import_decl(path, _, _):
                if path.len == 0:
                    return
                let first_seg = read(path.data + 0)
                let seg_str = interner_ref.lookup(first_seg) else:
                    return
                if seg_str == "std":
                    return
                import_path = path
            _:
                return

    var sfp: str_buffer[1024]
    sfp.append("src")
    var si: ptr_uint = 0
    while si < import_path.len:
        let seg_id = unsafe: read(import_path.data + si)
        sfp.append("/")
        let seg_str = interner_ref.lookup(seg_id) else:
            return
        sfp.append(seg_str)
        si += 1
    sfp.append(".mt")
    let fp_str = sfp.as_str()
    let fr = fs.read_bytes(fp_str)
    let fb = fr else:
        return
    let fbytes = fb.as_span()
    if fbytes.len == ptr_uint<-0:
        return

    let path_id = interner_ref.intern(fp_str)
    var di: ptr_uint = 0
    while di < loaded.len:
        let p = loaded.at(di) else:
            break
        if p == path_id:
            return
        di += 1
    loaded.push(path_id)

    var toks = lexer_mod.lex(fbytes, interner_ref)
    let ts = toks.as_span()
    let ast_imp = parser_mod.parse(fbytes, ts, ptr_of(interner_ref))

    let sub_dir = extract_dir(fp_str)
    load_imports(ast_imp, sub_dir, ctx, chk, interner_ref, loaded, depth + 1)

    chk.register_types(ast_imp)


function main(args: span[str]) -> int:
    ## args[0] = subcommand, args[1] = file path (program name stripped)
    if args.len < ptr_uint<-2:
        stdio.print_line("usage: mtc <build|check|lex|parse> <file.mt>")
        return 1

    unsafe:
        let cmd = read(args.data + 0)
        let path = read(args.data + 1)

        if cmd.equal("check"):
            let file_result = fs.read_bytes(path)
            let fb = file_result else:
                stdio.print_line("error: cannot read file")
                return 1
            let fbytes = fb.as_span()
            if fbytes.len == ptr_uint<-0:
                stdio.print_line("error: empty file")
                return 1

            let source = source_mod.from_str("", "<input>")
            var ctx = ctx_mod.create(source)
            var toks = lexer_mod.lex(fbytes, ref_of(ctx.interner))
            let toks_span = toks.as_span()
            let ast = parser_mod.parse(fbytes, toks_span, ptr_of(ctx.interner))
            var chk = checker_mod.create(ctx.registry, ref_of(ctx.interner))

            let base_dir = extract_dir(path)
            check_with_imports(ast, base_dir, ptr_of(ctx), ref_of(chk), ref_of(ctx.interner))

            let ok = chk.check(ast)
            if ok:
                stdio.print_line("check ok")
                return 0
            var ei: ptr_uint = 0
            let errs = chk.error_texts()
            while ei < errs.len:
                let msg = unsafe: read(errs.data + ei)
                stdio.print_line(msg)
                ei += 1
            stdio.print_line("check failed")
            return 1

        return build_file(path)
