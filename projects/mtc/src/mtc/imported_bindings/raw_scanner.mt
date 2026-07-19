## Minimal scanner for raw external binding modules.
##
## External files have a constrained syntax — this scanner extracts the
## essential declaration metadata (names, types, mappings) without needing
## the full compiler parser.  It returns indexed vectors of type names,
## constant names, and function signatures in declaration order.

import std.str as text
import std.string as string
import std.vec as vec

# =============================================================================
#  Data types
# =============================================================================

public enum RawDeclKind: ubyte
    raw_type_alias = 0
    raw_struct     = 1
    raw_union      = 2
    raw_enum       = 3
    raw_flags      = 4
    raw_opaque     = 5

public struct RawTypeInfo:
    kind: RawDeclKind
    name: string.String
    c_name: string.String

public struct RawConstInfo:
    name: string.String
    const_type: string.String

public struct RawFuncInfo:
    name: string.String
    signature: string.String
    variadic: bool

public struct RawImportInfo:
    module_name: string.String
    alias: string.String

public struct RawModuleInfo:
    types: vec.Vec[RawTypeInfo]
    type_order: vec.Vec[string.String]
    consts: vec.Vec[RawConstInfo]
    const_order: vec.Vec[string.String]
    functions: vec.Vec[RawFuncInfo]
    func_order: vec.Vec[string.String]
    imports: vec.Vec[RawImportInfo]
    is_external: bool


# =============================================================================
#  Release helpers
# =============================================================================

extending RawTypeInfo:
    public editable function release() -> void:
        this.name.release()
        this.c_name.release()


extending RawConstInfo:
    public editable function release() -> void:
        this.name.release()
        this.const_type.release()


extending RawFuncInfo:
    public editable function release() -> void:
        this.name.release()
        this.signature.release()


extending RawImportInfo:
    public editable function release() -> void:
        this.module_name.release()
        this.alias.release()


extending RawModuleInfo:
    public editable function release() -> void:
        release_type_infos(ref_of(this.types))
        release_string_vec(ref_of(this.type_order))
        release_const_infos(ref_of(this.consts))
        release_string_vec(ref_of(this.const_order))
        release_func_infos(ref_of(this.functions))
        release_string_vec(ref_of(this.func_order))
        release_import_infos(ref_of(this.imports))


function release_type_infos(v: ref[vec.Vec[RawTypeInfo]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_const_infos(v: ref[vec.Vec[RawConstInfo]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_func_infos(v: ref[vec.Vec[RawFuncInfo]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_import_infos(v: ref[vec.Vec[RawImportInfo]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_string_vec(v: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


# =============================================================================
#  Line-level scanning
# =============================================================================

function strip_indent(line: str) -> str:
    var i: ptr_uint = 0
    while i < line.len and (line.byte_at(i) == ' ' or line.byte_at(i) == '\t'):
        i += 1
    return line.slice(i, line.len - i)


function starts_with_keyword(line: str, kw: str) -> bool:
    let trimmed = strip_indent(line)
    return trimmed.starts_with(kw)


function extract_c_name(line: str) -> str:
    # Extract content between c" and " or between = c" and "
    var start = line.find_substring("c\"")
    let start_pos = start else:
        return ""
    let quote_pos = start_pos + 2
    var end = quote_pos
    while end < line.len and line.byte_at(end) != '"':
        end += 1
    if end <= quote_pos:
        return ""
    return line.slice(quote_pos, end - quote_pos)


function extract_identifier_after(line: str, keyword: str) -> string.String:
    let trimmed = strip_indent(line)
    if not trimmed.starts_with(keyword):
        return string.String.create()
    let rest = trimmed.slice(keyword.len, trimmed.len - keyword.len)
    var i: ptr_uint = 0
    while i < rest.len and rest.byte_at(i) == ' ':
        i += 1
    if i >= rest.len:
        return string.String.create()
    let name_start = i
    while i < rest.len:
        let ch = rest.byte_at(i)
        if ch == ' ' or ch == ':' or ch == '<' or ch == '(' or ch == '\n':
            break
        i += 1
    return string.String.from_str(rest.slice(name_start, i - name_start))


# =============================================================================
#  Main scanner
# =============================================================================

## Scan a raw external .mt file and extract declaration metadata.
public function scan_raw_module(source: str) -> RawModuleInfo:
    var types = vec.Vec[RawTypeInfo].create()
    var type_order = vec.Vec[string.String].create()
    var consts = vec.Vec[RawConstInfo].create()
    var const_order = vec.Vec[string.String].create()
    var functions = vec.Vec[RawFuncInfo].create()
    var func_order = vec.Vec[string.String].create()
    var imports = vec.Vec[RawImportInfo].create()
    var is_external: bool = false

    # Split into lines and scan
    var pos: ptr_uint = 0
    var line_start: ptr_uint = 0
    while pos < source.len:
        if source.byte_at(pos) == '\n':
            let line = source.slice(line_start, pos - line_start)
            scan_line(line, ref_of(types), ref_of(type_order), ref_of(consts), ref_of(const_order), ref_of(functions), ref_of(func_order), ref_of(imports), ref_of(is_external))
            line_start = pos + 1
        pos += 1

    # Handle last line if no trailing newline
    if line_start < source.len:
        let line = source.slice(line_start, source.len - line_start)
        scan_line(line, ref_of(types), ref_of(type_order), ref_of(consts), ref_of(const_order), ref_of(functions), ref_of(func_order), ref_of(imports), ref_of(is_external))

    return RawModuleInfo(
        types = types,
        type_order = type_order,
        consts = consts,
        const_order = const_order,
        functions = functions,
        func_order = func_order,
        imports = imports,
        is_external = is_external,
    )


function scan_line(
    line: str,
    types: ref[vec.Vec[RawTypeInfo]],
    type_order: ref[vec.Vec[string.String]],
    consts: ref[vec.Vec[RawConstInfo]],
    const_order: ref[vec.Vec[string.String]],
    functions: ref[vec.Vec[RawFuncInfo]],
    func_order: ref[vec.Vec[string.String]],
    imports: ref[vec.Vec[RawImportInfo]],
    is_external: ref[bool],
) -> void:
    let trimmed = strip_indent(line)
    if trimmed.len == 0:
        return

    # Check for external keyword
    if trimmed.equal("external"):
        read(is_external) = true
        return

    # Import declarations
    if starts_with_keyword(line, "import "):
        # Extract module path and alias
        var rest = trimmed.slice(7, trimmed.len - 7)
        var i: ptr_uint = 0
        while i < rest.len and rest.byte_at(i) == ' ':
            i += 1
        if i >= rest.len:
            return
        let path_start = i
        while i < rest.len and rest.byte_at(i) != ' ':
            i += 1
        let path = rest.slice(path_start, i - path_start)
        var alias_name: str = ""
        while i < rest.len and rest.byte_at(i) == ' ':
            i += 1
        if i + 3 < rest.len and rest.slice(i, rest.len - i).starts_with("as "):
            let alias_rest = rest.slice(i + 3, rest.len - i - 3)
            var j: ptr_uint = 0
            while j < alias_rest.len and alias_rest.byte_at(j) != ' ':
                j += 1
            alias_name = alias_rest.slice(0, j)
        if path.len > 0:
            imports.push(RawImportInfo(
                module_name = string.String.from_str(path),
                alias = string.String.from_str(alias_name),
            ))
        return

    # Type alias: public type Name = c.X
    if starts_with_keyword(line, "public type ") or starts_with_keyword(line, "type "):
        var name = extract_identifier_after(line, if starts_with_keyword(line, "public type "): "public type " else: "type ")
        if name.len() > 0:
            let name_str = name.as_str()
            types.push(RawTypeInfo(kind = RawDeclKind.raw_type_alias, name = string.String.from_str(name_str), c_name = string.String.create()))
            type_order.push(string.String.from_str(name_str))
        name.release()
        return

    # Opaque: public opaque Name = c"RawName"
    if starts_with_keyword(line, "public opaque ") or starts_with_keyword(line, "opaque "):
        var name = extract_identifier_after(line, if starts_with_keyword(line, "public opaque "): "public opaque " else: "opaque ")
        if name.len() > 0:
            let c_name = extract_c_name(line)
            types.push(RawTypeInfo(kind = RawDeclKind.raw_opaque, name = string.String.from_str(name.as_str()), c_name = string.String.from_str(c_name)))
            type_order.push(string.String.from_str(name.as_str()))
        name.release()
        return

    # Struct/union/enum/flags declarations
    if starts_with_keyword(line, "public struct ") or starts_with_keyword(line, "struct "):
        let kw = if starts_with_keyword(line, "public struct "): "public struct " else: "struct "
        var name = extract_identifier_after(line, kw)
        if name.len() > 0:
            types.push(RawTypeInfo(kind = RawDeclKind.raw_struct, name = string.String.from_str(name.as_str()), c_name = string.String.create()))
            type_order.push(string.String.from_str(name.as_str()))
        name.release()
        return

    if starts_with_keyword(line, "public union ") or starts_with_keyword(line, "union "):
        let kw = if starts_with_keyword(line, "public union "): "public union " else: "union "
        var name = extract_identifier_after(line, kw)
        if name.len() > 0:
            types.push(RawTypeInfo(kind = RawDeclKind.raw_union, name = string.String.from_str(name.as_str()), c_name = string.String.create()))
            type_order.push(string.String.from_str(name.as_str()))
        name.release()
        return

    if starts_with_keyword(line, "public enum ") or starts_with_keyword(line, "enum "):
        let kw = if starts_with_keyword(line, "public enum "): "public enum " else: "enum "
        var name = extract_identifier_after(line, kw)
        if name.len() > 0:
            types.push(RawTypeInfo(kind = RawDeclKind.raw_enum, name = string.String.from_str(name.as_str()), c_name = string.String.create()))
            type_order.push(string.String.from_str(name.as_str()))
        name.release()
        return

    if starts_with_keyword(line, "public flags ") or starts_with_keyword(line, "flags "):
        let kw = if starts_with_keyword(line, "public flags "): "public flags " else: "flags "
        var name = extract_identifier_after(line, kw)
        if name.len() > 0:
            types.push(RawTypeInfo(kind = RawDeclKind.raw_flags, name = string.String.from_str(name.as_str()), c_name = string.String.create()))
            type_order.push(string.String.from_str(name.as_str()))
        name.release()
        return

    # Constants
    if starts_with_keyword(line, "public const ") or starts_with_keyword(line, "const "):
        let kw = if starts_with_keyword(line, "public const "): "public const " else: "const "
        var name = extract_identifier_after(line, kw)
        if name.len() > 0:
            consts.push(RawConstInfo(name = string.String.from_str(name.as_str()), const_type = string.String.create()))
            const_order.push(string.String.from_str(name.as_str()))
        name.release()
        return

    # External functions
    if starts_with_keyword(line, "public external function ") or starts_with_keyword(line, "external function "):
        let kw = if starts_with_keyword(line, "public external function "): "public external function " else: "external function "
        var name = extract_identifier_after(line, kw)
        if name.len() > 0:
            functions.push(RawFuncInfo(
                name = string.String.from_str(name.as_str()),
                signature = string.String.from_str(trimmed),
                variadic = line.find_substring("...").is_some(),
            ))
            func_order.push(string.String.from_str(name.as_str()))
        name.release()
        return
