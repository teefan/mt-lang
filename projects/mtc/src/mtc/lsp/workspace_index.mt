## Workspace symbol index — scans all .mt files under the workspace roots,
## extracts every top-level declaration, and stores them for fast lookup.
## Replaces the per-query on-demand file scan in workspace_symbols.mt and
## also enables empty-query "list all symbols" requests.

import std.fmt
import std.fs as fs_mod
import std.path as path_ops
import std.str
import std.string as string_mod
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate


public struct Entry:
    name: string_mod.String
    kind: int
    path: string_mod.String
    line: ptr_uint
    column: ptr_uint


public struct Index:
    entries: vec.Vec[Entry]


## Scan all .mt files and build a fresh index.
public function build_index(module_roots: ref[vec.Vec[string_mod.String]]) -> Index:
    var index = Index(entries = vec.Vec[Entry].create())

    var ri: ptr_uint = 0
    while ri < module_roots.len():
        let root_ptr = module_roots.get(ri) else:
            break
        unsafe:
            collect_directory(read(root_ptr).as_str(), ref_of(index.entries))
        ri += 1

    return index


## Query the index for symbols whose name contains `query` (case-insensitive
## substring).  Truncates at `max_results`.  An empty query returns all
## symbols in file order.
public function query_index(index: ref[Index], query: str, max_results: ptr_uint) -> vec.Vec[ptr_uint]:
    var results = vec.Vec[ptr_uint].create()
    let empty_query = query.len == 0

    var ei: ptr_uint = 0
    while ei < index.entries.len() and results.len() < max_results:
        let ep = index.entries.get(ei) else:
            break
        let entry = unsafe: read(ep)
        if empty_query or contains_case_insensitive(entry.name.as_str(), query):
            results.push(ei)
        ei += 1

    return results


## Read a single entry by index from the index.  Fatal on out-of-bounds.
public function read_entry(index: ref[Index], idx_val: ptr_uint) -> ptr[Entry]:
    let ep = index.entries.get(idx_val) else:
        fatal(c"workspace_index.read_entry index out of bounds")
    return ep


public function release_index(index: ref[Index]) -> void:
    var ei: ptr_uint = 0
    while ei < index.entries.len():
        let ep = index.entries.get(ei) else:
            break
        unsafe:
            read(ep).name.release()
            read(ep).path.release()
        ei += 1
    index.entries.release()


function collect_directory(dir: str, output: ref[vec.Vec[Entry]]) -> void:
    match fs_mod.list_entries(dir):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return
        Result.success as payload:
            var entries = payload.value
            defer entries.release()

            var i: ptr_uint = 0
            while i < entries.len():
                match entries.get(i):
                    Option.none:
                        break
                    Option.some as entry_payload:
                        let name = entry_payload.value
                        if not skip_entry(name):
                            var child = path_ops.join(dir, name)
                            if fs_mod.is_directory(child.as_str()):
                                collect_directory(child.as_str(), output)
                                child.release()
                            else if name.ends_with(".mt"):
                                collect_file_symbols(child.as_str(), output)
                                child.release()
                            else:
                                child.release()
                i += 1


function collect_file_symbols(path: str, output: ref[vec.Vec[Entry]]) -> void:
    match fs_mod.canonicalize(path):
        Result.success as canonical:
            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer parse_diags.release()
            var ast_file = parser.parse_source(read_file(canonical.value.as_str()), ref_of(parse_diags))

            var di: ptr_uint = 0
            while di < ast_file.declarations.len:
                var decl: ast.Decl
                unsafe:
                    decl = read(ast_file.declarations.data + di)
                let sym_kind = decl_symbol_kind(decl)
                if sym_kind >= 0:
                    let info = decl_name_and_line(decl)
                    if info.name.len > 0:
                        output.push(Entry(
                            name = string_mod.String.from_str(info.name),
                            kind = sym_kind,
                            path = string_mod.String.from_str(canonical.value.as_str()),
                            line = info.line,
                            column = 0,
                        ))
                di += 1
            canonical.value.release()
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()


function read_file(path: str) -> str:
    match fs_mod.read_text(path):
        Result.success as payload:
            return payload.value.as_str()
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return ""


function decl_symbol_kind(d: ast.Decl) -> int:
    match d:
        ast.Decl.decl_function:
            return 12
        ast.Decl.decl_struct:
            return 23
        ast.Decl.decl_union:
            return 23
        ast.Decl.decl_enum:
            return 10
        ast.Decl.decl_flags:
            return 10
        ast.Decl.decl_variant:
            return 10
        ast.Decl.decl_interface:
            return 11
        ast.Decl.decl_type_alias:
            return 5
        ast.Decl.decl_opaque:
            return 5
        ast.Decl.decl_const:
            return 14
        ast.Decl.decl_var:
            return 13
        _:
            return -1


struct DeclInfo:
    name: str
    line: ptr_uint


function decl_name_and_line(d: ast.Decl) -> DeclInfo:
    match d:
        ast.Decl.decl_function as fun:
            return DeclInfo(name = fun.name, line = fun.line)
        ast.Decl.decl_struct as s:
            return DeclInfo(name = s.name, line = s.line)
        ast.Decl.decl_union as u:
            return DeclInfo(name = u.name, line = u.line)
        ast.Decl.decl_enum as e:
            return DeclInfo(name = e.name, line = e.line)
        ast.Decl.decl_flags as fl:
            return DeclInfo(name = fl.name, line = fl.line)
        ast.Decl.decl_variant as vr:
            return DeclInfo(name = vr.name, line = vr.line)
        ast.Decl.decl_interface as ifc:
            return DeclInfo(name = ifc.name, line = ifc.line)
        ast.Decl.decl_type_alias as ta:
            return DeclInfo(name = ta.name, line = ta.line)
        ast.Decl.decl_opaque as op:
            return DeclInfo(name = op.name, line = op.line)
        ast.Decl.decl_const as c:
            return DeclInfo(name = c.name, line = c.line)
        ast.Decl.decl_var as v:
            return DeclInfo(name = v.name, line = v.line)
        _:
            return DeclInfo(name = "", line = 0)


function skip_entry(name: str) -> bool:
    return name.starts_with(".") or name.equal("build") or name.equal("tmp") or
        name.equal("third_party") or name.equal("node_modules") or name.equal("coverage") or
        name.equal("target")


function contains_case_insensitive(text: str, needle: str) -> bool:
    if needle.len == 0:
        return true
    if needle.len > text.len:
        return false
    let limit = text.len - needle.len
    var n: ptr_uint = 0
    while n <= limit:
        var matched = true
        var mi: ptr_uint = 0
        while mi < needle.len:
            if ascii_fold(text.byte_at(n + mi)) != ascii_fold(needle.byte_at(mi)):
                matched = false
                break
            mi += 1
        if matched:
            return true
        n += 1
    return false


function ascii_fold(value: ubyte) -> ubyte:
    if value >= 'A' and value <= 'Z':
        return value + ('a' - 'A')
    return value
