import std.str
import std.stdio
import std.fs as fs
import std.vec as vec

import mtc.ast.nodes
import mtc.lexer.token
import mtc.lexer.lexer
import mtc.parser.parser
import mtc.sema.symbol
import mtc.sema.checker
import mtc.sema.loader


function lex_file(file_path: str, use_json: bool) -> int:
    match fs.read_text(file_path):
        Result.failure as err:
            stdio.print_line(f"error: cannot read '#{file_path}'")
            return 1
        Result.success as ok:
            var source = ok.value
            var lex = lexer.Lexer.create(source.as_str())
            var tokens = lex.lex()
            if use_json:
                print_tokens_json(ref_of(tokens))
            else:
                print_tokens_text(ref_of(tokens))
            return 0


function parse_file(file_path: str, use_json: bool) -> int:
    match fs.read_text(file_path):
        Result.failure as err:
            stdio.print_line(f"error: cannot read '#{file_path}'")
            return 1
        Result.success as ok:
            var source = ok.value
            var lex = lexer.Lexer.create(source.as_str())
            var tokens = lex.lex()
            var p = parser.Parser.create(tokens)
            var ast = p.parse()
            if use_json:
                print_parse_json(ref_of(ast))
            else:
                print_parse_text(ref_of(ast))
            return 0


function check_file(file_path: str) -> int:
    match fs.read_text(file_path):
        Result.failure as err:
            stdio.print_line(f"error: cannot read '#{file_path}'")
            return 1
        Result.success as ok:
            var source = ok.value
            var lex = lexer.Lexer.create(source.as_str())
            var tokens = lex.lex()
            var p = parser.Parser.create(tokens)
            var ast = p.parse()

            var source_root = dirname_of(file_path)
            var stdlib_root = find_stdlib_root()

            var c = checker.Checker.create(stdlib_root, source_root)
            var ctx = c.check(ast)

            var type_count: ptr_uint = 0
            var fn_count: ptr_uint = 0
            var val_count: ptr_uint = 0
            var i: ptr_uint = 0
            while i < ctx.symbols.len():
                let s = ctx.symbols.get(i) else:
                    break
                let sym = unsafe: read(s)
                if sym.kind == symbol.SymbolKind.type_symbol:
                    type_count += 1
                else if sym.kind == symbol.SymbolKind.function_symbol:
                    fn_count += 1
                else if sym.kind == symbol.SymbolKind.const_symbol or sym.kind == symbol.SymbolKind.var_symbol:
                    val_count += 1
                i += 1

            stdio.print_line(f"types: #{type_count}  functions: #{fn_count}  values: #{val_count}  symbols: #{ctx.symbols.len()}")

            if ctx.errors.len() == 0:
                stdio.print_line("OK")
            else:
                stdio.print_line("")
                i = 0
                while i < ctx.errors.len():
                    let e = ctx.errors.get(i) else:
                        break
                    let err = unsafe: read(e)
                    stdio.print_line(f"  error: #{err.message} at #{err.line}:#{err.column}")
                    i += 1

            return if ctx.errors.len() == 0: 0 else: 1


function print_tokens_text(tokens: ref[vec.Vec[token.Token]]) -> void:
    var i: ptr_uint = 0
    while i < tokens.len():
        let t = tokens.get(i) else:
            break
        unsafe:
            let tok = read(t)
            stdio.print_line(f"#{tok.kind} #{tok.lexeme} #{tok.line}:#{tok.column}")
        i += 1


function print_tokens_json(tokens: ref[vec.Vec[token.Token]]) -> void:
    stdio.print_line("[")
    var i: ptr_uint = 0
    var count = tokens.len()
    while i < count:
        let t = tokens.get(i) else:
            break
        unsafe:
            let tok = read(t)
            var comma = if i + 1 < count: "," else: ""
            stdio.print_line(f"  {\"kind\":#{tok.kind},\"lexeme\":\"#{tok.lexeme}\",\"line\":#{tok.line},\"column\":#{tok.column}}#{comma}")
        i += 1
    stdio.print_line("]")


function print_parse_text(ast: ref[nodes.SourceFile]) -> void:
    var i: ptr_uint = 0
    while i < ast.imports.len():
        let imp_ptr = ast.imports.get(i) else:
            break
        let imp = unsafe: read(imp_ptr)
        stdio.print_line(f"import #{imp.path}")
        i += 1
    i = 0
    while i < ast.decls.len():
        let d = ast.decls.get(i) else:
            break
        let decl = unsafe: read(d)
        stdio.print_line(f"#{decl_kind_name(decl.kind)} #{decl.name} stmts=#{decl.stmt_count} params=#{decl.params.len()}")
        i += 1


function print_parse_json(ast: ref[nodes.SourceFile]) -> void:
    stdio.print_line("{\"imports\":[")
    var i: ptr_uint = 0
    while i < ast.imports.len():
        let imp_ptr = ast.imports.get(i) else:
            break
        let imp = unsafe: read(imp_ptr)
        var comma = if i + 1 < ast.imports.len(): "," else: ""
        stdio.print_line(f"    {\"path\":\"#{imp.path}\",\"alias\":\"#{imp.alias}\"}#{comma}")
        i += 1
    stdio.print_line("  ],\"decls\":[")
    i = 0
    while i < ast.decls.len():
        let d = ast.decls.get(i) else:
            break
        let decl = unsafe: read(d)
        var comma = if i + 1 < ast.decls.len(): "," else: ""
        stdio.print_line(f"    {\"kind\":\"#{decl_kind_name(decl.kind)}\",\"name\":\"#{decl.name}\",\"stmts\":#{decl.stmt_count},\"params\":#{decl.params.len()}}#{comma}")
        i += 1
    stdio.print_line("  ]}")


function decl_kind_name(kind: nodes.DeclKind) -> str:
    if kind == nodes.DeclKind.const_decl:
        return "const"
    if kind == nodes.DeclKind.var_decl:
        return "var"
    if kind == nodes.DeclKind.event_decl:
        return "event"
    if kind == nodes.DeclKind.type_alias:
        return "type"
    if kind == nodes.DeclKind.struct_decl:
        return "struct"
    if kind == nodes.DeclKind.enum_decl:
        return "enum"
    if kind == nodes.DeclKind.flags_decl:
        return "flags"
    if kind == nodes.DeclKind.variant_decl:
        return "variant"
    if kind == nodes.DeclKind.interface_decl:
        return "interface"
    if kind == nodes.DeclKind.function_def:
        return "function"
    if kind == nodes.DeclKind.extern_function:
        return "external function"
    if kind == nodes.DeclKind.foreign_function:
        return "foreign function"
    if kind == nodes.DeclKind.extending_block:
        return "extending"
    if kind == nodes.DeclKind.opaque_decl:
        return "opaque"
    if kind == nodes.DeclKind.union_decl:
        return "union"
    return "?"


function find_stdlib_root() -> str:
    return "std"


function dirname_of(path: str) -> str:
    var i: ptr_uint = path.len
    while i > 0:
        i -= 1
        if path.byte_at(i) == '/':
            return path.slice(0, i)
    return ""


function print_usage() -> void:
    stdio.print_line("Milk Tea Compiler (self-hosting)")
    stdio.print_line("")
    stdio.print_line("Usage: mtc <command> [options]")
    stdio.print_line("")
    stdio.print_line("Commands:")
    stdio.print_line("  lex <file>          Lex a source file and print the token stream")
    stdio.print_line("  parse <file>        Parse a source file and print the AST (IR)")
    stdio.print_line("  check <file>        Run semantic analysis on a source file")
    stdio.print_line("")
    stdio.print_line("Options:")
    stdio.print_line("  --json, -j          Output as JSON (for lex and parse commands)")
    stdio.print_line("  --help, -h          Show this help")


function has_flag(args: span[str], flag: str) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        let arg = unsafe: read(args.data + i)
        if arg == flag:
            return true
        i += 1
    return false


function positional_after_command(args: span[str]) -> Option[str]:
    var i: ptr_uint = 1
    while i < args.len:
        let arg = unsafe: read(args.data + i)
        if not arg.starts_with("-"):
            return Option[str].some(value = arg)
        i += 1
    return Option[str].none


function main(args: span[str]) -> int:
    if args.len == 0 or has_flag(args, "--help") or has_flag(args, "-h"):
        print_usage()
        return 0

    let cmd = unsafe: read(args.data)

    if cmd == "lex":
        let file_arg = positional_after_command(args)
        match file_arg:
            Option.some as file_path:
                let use_json = has_flag(args, "--json") or has_flag(args, "-j")
                return lex_file(file_path.value, use_json)
            Option.none:
                stdio.print_line("error: no file specified")
                return 1

    if cmd == "parse":
        let file_arg = positional_after_command(args)
        match file_arg:
            Option.some as file_path:
                let use_json = has_flag(args, "--json") or has_flag(args, "-j")
                return parse_file(file_path.value, use_json)
            Option.none:
                stdio.print_line("error: no file specified")
                return 1

    if cmd == "check":
        let file_arg = positional_after_command(args)
        match file_arg:
            Option.some as file_path:
                return check_file(file_path.value)
            Option.none:
                stdio.print_line("error: no file specified")
                return 1

    stdio.print_line(f"error: unknown command '#{cmd}'")
    return 1
