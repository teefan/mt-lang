import std.str
import std.fs as fs
import std.vec as vec

import mtc.ast.nodes
import mtc.lexer.lexer
import mtc.parser.parser
import mtc.sema.symbol


public struct ModuleLoader:
    search_paths: vec.Vec[str]
    loaded: vec.Vec[str]


extending ModuleLoader:
    public static function create(stdlib_root: str, source_root: str) -> ModuleLoader:
        var paths = vec.Vec[str].create()
        paths.push(source_root)
        paths.push(stdlib_root)
        var loaded = vec.Vec[str].create()
        return ModuleLoader(search_paths = paths, loaded = loaded)


    public function resolve_module(import_path: str) -> Option[str]:
        var pi: ptr_uint = 0
        while pi < this.search_paths.len():
            let root = this.search_paths.get(pi) else:
                break
            let r = unsafe: read(root)
            var base = self_to_path(f"#{r}/#{import_path}")

            var dotted = f"#{r}/#{import_path}"
            var platform_path = ""
            var j: ptr_uint = 0
            while j < dotted.len:
                let dc = dotted.byte_at(j)
                if dc == '.':
                    platform_path = f"#{platform_path}/"
                else:
                    platform_path = f"#{platform_path}#"
                j += 1

            var linux_path = f"#{platform_path}.linux.mt"
            if fs.exists(linux_path):
                return Option[str].some(value = linux_path)

            if fs.exists(base):
                return Option[str].some(value = base)
            pi += 1
        return Option[str].none


    function already_loaded(import_path: str) -> bool:
        var i: ptr_uint = 0
        while i < this.loaded.len():
            let p = this.loaded.get(i) else:
                break
            if unsafe: read(p) == import_path:
                return true
            i += 1
        return false


    public function load_module(import_path: str) -> nodes.SourceFile:
        let file_path = this.resolve_module(import_path)
        match file_path:
            Option.none:
                return empty_source()
            Option.some as resolved:
                match fs.read_text(resolved.value):
                    Result.failure:
                        return empty_source()
                    Result.success as ok:
                        var source = ok.value
                        var lex = lexer.Lexer.create(source.as_str())
                        var tokens = lex.lex()
                        var p = parser.Parser.create(tokens)
                        return p.parse()


    public editable function load_and_register(ctx: ref[symbol.SemaContext], import_path: str) -> bool:
        if this.already_loaded(import_path):
            return true
        this.loaded.push(import_path)

        var ast = this.load_module(import_path)
        if ast.decls.len() == 0 and ast.imports.len() == 0:
            return false

        var ii: ptr_uint = 0
        while ii < ast.imports.len():
            let imp_ptr = ast.imports.get(ii) else:
                break
            let imp = unsafe: read(imp_ptr)
            this.load_and_register(ctx, imp.path)
            ii += 1

        var i: ptr_uint = 0
        while i < ast.decls.len():
            let d = ast.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            if decl.is_public and decl.name != "":
                if self_is_type_decl(decl.kind):
                    ctx.register_type(decl.name, decl.line, decl.column)
                else if self_is_function_decl(decl.kind):
                    ctx.register_function(decl.name, decl.return_text, true, decl.line, decl.column)
                else if decl.kind == nodes.DeclKind.const_decl:
                    ctx.register_const_or_var(decl.name, symbol.SymbolKind.const_symbol, decl.type_name, decl.line, decl.column)
            i += 1
        return true


function self_to_path(dotted: str) -> str:
    var result = ""
    var i: ptr_uint = 0
    while i < dotted.len:
        let ch = dotted.byte_at(i)
        if ch == '.':
            result = f"#{result}/"
        else:
            result = f"#{result}#"
        i += 1
    result = f"#{result}.mt"
    return result


function self_is_type_decl(kind: nodes.DeclKind) -> bool:
    return kind == nodes.DeclKind.type_alias or kind == nodes.DeclKind.struct_decl or kind == nodes.DeclKind.enum_decl or kind == nodes.DeclKind.flags_decl or kind == nodes.DeclKind.variant_decl or kind == nodes.DeclKind.interface_decl or kind == nodes.DeclKind.opaque_decl or kind == nodes.DeclKind.union_decl


function self_is_function_decl(kind: nodes.DeclKind) -> bool:
    return kind == nodes.DeclKind.function_def or kind == nodes.DeclKind.extern_function or kind == nodes.DeclKind.foreign_function


function empty_source() -> nodes.SourceFile:
    return nodes.SourceFile(module_name = "", imports = vec.Vec[nodes.Import].create(), decls = vec.Vec[nodes.Decl].create(), line = 0)
