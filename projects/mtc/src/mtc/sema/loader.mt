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


    public function already_loaded(import_path: str) -> bool:
        var i: ptr_uint = 0
        while i < this.loaded.len():
            let p = this.loaded.get(i) else:
                break
            if unsafe: read(p) == import_path:
                return true
            i += 1
        return false


    public function load_module(import_path: str) -> nodes.SourceFile:
        var pi: ptr_uint = 0
        while pi < this.search_paths.len():
            let root = this.search_paths.get(pi) else:
                break
            let r = unsafe: read(root)

            var path_buf = self_build_module_path(r, import_path, "mt")
            if fs.exists(path_buf.as_str()):
                match fs.read_text(path_buf.as_str()):
                    Result.failure:
                        pass
                    Result.success as ok:
                        var source = ok.value
                        var source_str = source.as_str()
                        var lex = lexer.Lexer.create(source_str)
                        var tokens = lex.lex()
                        var p = parser.Parser.create(source_str, tokens)
                        return p.parse()

            var linux_buf = self_build_module_path(r, import_path, "linux.mt")
            if fs.exists(linux_buf.as_str()):
                match fs.read_text(linux_buf.as_str()):
                    Result.failure:
                        pass
                    Result.success as ok:
                        var source = ok.value
                        var source_str = source.as_str()
                        var lex = lexer.Lexer.create(source_str)
                        var tokens = lex.lex()
                        var p = parser.Parser.create(source_str, tokens)
                        return p.parse()
            pi += 1
        return empty_source()

function self_build_module_path(search_root: str, dotted_path: str, extension: str) -> str_buffer[256]:
    var buf: str_buffer[256]
    buf.append(search_root)
    buf.append("/")
    var i: ptr_uint = 0
    while i < dotted_path.len:
        let ch = dotted_path.byte_at(i)
        if ch == '.':
            buf.append("/")
        else:
            buf.append(dotted_path.slice(i, 1))
        i += 1
    buf.append(".")
    buf.append(extension)
    return buf


function self_is_type_decl(kind: nodes.DeclKind) -> bool:
    return kind == nodes.DeclKind.type_alias or kind == nodes.DeclKind.struct_decl or kind == nodes.DeclKind.enum_decl or kind == nodes.DeclKind.flags_decl or kind == nodes.DeclKind.variant_decl or kind == nodes.DeclKind.interface_decl or kind == nodes.DeclKind.opaque_decl or kind == nodes.DeclKind.union_decl


function self_is_function_decl(kind: nodes.DeclKind) -> bool:
    return kind == nodes.DeclKind.function_def or kind == nodes.DeclKind.extern_function or kind == nodes.DeclKind.foreign_function


function empty_source() -> nodes.SourceFile:
    return nodes.SourceFile(module_name = "", imports = vec.Vec[nodes.Import].create(), decls = vec.Vec[nodes.Decl].create(), is_external = false, line = 0)
