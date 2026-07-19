## Self-hosted bindgen — generates a Milk Tea external binding module from a C
## header by running clang to dump the AST as JSON, extracting top-level
## declarations, mapping C types to MT types, and emitting the module source.

import std.str
import std.string as string
import std.vec as vec
import std.json as json
import std.process as process
import std.fs as fs

# =============================================================================
#  Utilities
# =============================================================================

function str_has_prefix(s: str, prefix: str) -> bool:
    if s.len < prefix.len:
        return false
    var i: ptr_uint = 0
    while i < prefix.len:
        if s.byte_at(i) != prefix.byte_at(i):
            return false
        i += 1
    return true

function str_strip(t: str) -> str:
    var s: ptr_uint = 0
    while s < t.len and t.byte_at(s) == ' ':
        s += 1
    var e = t.len
    while e > s and t.byte_at(e - 1) == ' ':
        e -= 1
    return t.slice(s, e - s)

function strip_cv(t: str) -> str:
    var r = t
    while str_has_prefix(r, "const "):
        r = r.slice(6, r.len - 6)
    while str_has_prefix(r, "volatile "):
        r = r.slice(9, r.len - 9)
    while str_has_prefix(r, "restrict "):
        r = r.slice(9, r.len - 9)
    return str_strip(r)

function uint_to_str(n: ptr_uint) -> str:
    var buf = string.String.create()
    if n == 0:
        buf.push_byte('0')
        return buf.as_str()
    var digits: array[ubyte, 20]
    var di: ptr_uint = 0
    var rem = n
    while rem > 0:
        digits[di] = '0' + ubyte<-(rem % 10)
        rem = rem / 10
        di += 1
    var ri = di
    while ri > 0:
        ri -= 1
        buf.push_byte(digits[ri])
    return buf.as_str()

function parse_long(s: str) -> long:
    var i: ptr_uint = 0
    var neg = false
    if s.len > 0 and s.byte_at(0) == '-':
        neg = true
        i = 1
    var v: long = 0
    while i < s.len:
        let b = s.byte_at(i)
        if b >= '0' and b <= '9':
            v = v * 10 + long<-(b - '0')
        i += 1
    if neg:
        return -v
    return v

# =============================================================================
#  JSON helpers — accept ptr[json.Value]? from Object.get(), handle null
# =============================================================================

## Extract a string from a clang JSON value.  Handles both plain JSON strings
## (the common case) and clang wrapped objects.
function jstr(vp: ptr[json.Value]?) -> str:
    if vp == null:
        return ""
    unsafe:
        # Plain JSON string — the common case for kind/name/tagUsed.
        let str_opt = read(vp).as_string()
        if str_opt.is_some():
            return str_opt.unwrap()
        # Try as a clang wrapped StringLiteral object.
        let obj = read(vp).as_object()
        if obj == null:
            return ""
        let kind_vp = read(obj).get("kind")
        let kind = jstr(kind_vp)
        if kind == "StringLiteral":
            let val_vp = read(obj).get("value")
            return jstr(val_vp)
    return ""

## Walk through an Object node to get a named string field: obj.key → value.
## `node` is the Object containing the field; `key` is the field name.
function jget_str(node: ptr[json.Object]?, key: str) -> str:
    if node == null:
        return ""
    unsafe:
        let vp = read(node).get(key)
        return jstr(vp)

## Get the qualType field from a clang Type node: {"qualType":"int"} → "int".
function jget_qualtype(vp: ptr[json.Value]?) -> str:
    if vp == null:
        return ""
    unsafe:
        let obj = read(vp).as_object()
        if obj == null:
            return ""
        return jget_str(obj, "qualType")

## Walk an Object → key → inner array via json.Value→Array chain.
function jget_inner(node: ptr[json.Object]?) -> ptr[json.Array]?:
    if node == null:
        return null
    unsafe:
        let inner_vp = read(node).get("inner")
        if inner_vp == null:
            return null
        return read(inner_vp).as_array()

# =============================================================================
#  C type → MT type mapping
# =============================================================================

function map_type(qual_type: str) -> string.String:
    var t = str_strip(qual_type)

    if t == "va_list" or t == "struct __va_list_tag *":
        return string.String.from_str("va_list")

    # Array: type[N]
    if t.len > 0 and t.byte_at(t.len - 1) == ']':
        var br = t.len
        while br > 0:
            br -= 1
            if t.byte_at(br) == '[':
                break
        if br < t.len:
            let elem = t.slice(0, br)
            let sz_str = t.slice(br + 1, t.len - br - 2)
            var sz: ptr_uint = 0
            var si: ptr_uint = 0
            while si < sz_str.len:
                let b = sz_str.byte_at(si)
                if b >= '0' and b <= '9':
                    sz = sz * 10 + (b - '0')
                si += 1
            var r = string.String.from_str("array[")
            var e = map_type(elem)
            r.append(e.as_str())
            r.append(", ")
            r.append(uint_to_str(sz))
            r.append("]")
            return r

    # Pointer
    if t.len > 0 and t.byte_at(t.len - 1) == '*':
        var end = t.len - 1
        while end > 0 and t.byte_at(end - 1) == ' ':
            end -= 1
        let pointee = t.slice(0, end)
        let cleaned = strip_cv(str_strip(pointee))
        if cleaned == "char":
            return string.String.from_str("cstr")
        if str_has_prefix(str_strip(pointee), "const"):
            let base = strip_cv(pointee)
            var r = string.String.from_str("const_ptr[")
            var e = map_type(base)
            r.append(e.as_str())
            r.append("]")
            return r
        var r = string.String.from_str("ptr[")
        var e = map_type(str_strip(pointee))
        r.append(e.as_str())
        r.append("]")
        return r

    # Function pointer: ret (*)(params) — has closing paren near end
    if t.len > 2 and t.byte_at(t.len - 1) == ')':
        var open: ptr_uint = 0
        var depth = 0
        var i: ptr_uint = 0
        while i < t.len:
            let b = t.byte_at(i)
            if b == '(' and depth == 0:
                open = i
                depth = 1
            else if b == '(':
                depth += 1
            else if b == ')':
                depth -= 1
            i += 1
        if open > 0:
            return emit_fn_ptr(t, open)

    let bare = strip_cv(t)

    if bare == "void": return string.String.from_str("void")
    if bare == "_Bool" or bare == "bool": return string.String.from_str("bool")
    if bare == "char": return string.String.from_str("char")
    if bare == "signed char": return string.String.from_str("byte")
    if bare == "unsigned char": return string.String.from_str("ubyte")
    if bare == "short" or bare == "short int": return string.String.from_str("short")
    if bare == "unsigned short" or bare == "unsigned short int": return string.String.from_str("ushort")
    if bare == "int": return string.String.from_str("int")
    if bare == "unsigned int": return string.String.from_str("uint")
    if bare == "long" or bare == "long int": return string.String.from_str("ptr_int")
    if bare == "unsigned long" or bare == "unsigned long int": return string.String.from_str("ptr_uint")
    if bare == "long long" or bare == "long long int": return string.String.from_str("long")
    if bare == "unsigned long long" or bare == "unsigned long long int": return string.String.from_str("ulong")
    if bare == "float": return string.String.from_str("float")
    if bare == "double": return string.String.from_str("double")
    if bare == "size_t": return string.String.from_str("ptr_uint")
    if bare == "ssize_t" or bare == "ptrdiff_t": return string.String.from_str("ptr_int")
    if bare == "wchar_t": return string.String.from_str("int")
    if bare == "int8_t": return string.String.from_str("byte")
    if bare == "uint8_t": return string.String.from_str("ubyte")
    if bare == "int16_t": return string.String.from_str("short")
    if bare == "uint16_t": return string.String.from_str("ushort")
    if bare == "int32_t": return string.String.from_str("int")
    if bare == "uint32_t": return string.String.from_str("uint")
    if bare == "int64_t": return string.String.from_str("long")
    if bare == "uint64_t": return string.String.from_str("ulong")

    if str_has_prefix(bare, "struct "): return string.String.from_str(bare.slice(7, bare.len - 7))
    if str_has_prefix(bare, "union "): return string.String.from_str(bare.slice(6, bare.len - 6))
    if str_has_prefix(bare, "enum "): return string.String.from_str(bare.slice(5, bare.len - 5))

    return string.String.from_str(bare)


function emit_fn_ptr(t: str, open: ptr_uint) -> string.String:
    var ret_type = str_strip(t.slice(0, open))
    if ret_type.len > 0 and ret_type.byte_at(ret_type.len - 1) == '*':
        ret_type = str_strip(ret_type.slice(0, ret_type.len - 1))

    var params = t.slice(open + 1, t.len - open - 2)
    var r = string.String.from_str("fn(")
    if params != "void" and params != "":
        var comma: ptr_uint = 0
        var pd: ptr_uint = 0
        var an: ptr_uint = 0
        var j: ptr_uint = 0
        while j <= params.len:
            if j == params.len or (params.byte_at(j) == ',' and pd == 0):
                let arg = str_strip(params.slice(comma, j - comma))
                if an > 0:
                    r.append(", ")
                r.append("arg")
                r.append(uint_to_str(an))
                r.append(": ")
                var mapped = map_type(arg)
                r.append(mapped.as_str())
                comma = j + 1
                an += 1
            else if j < params.len:
                if params.byte_at(j) == '(':
                    pd += 1
                if params.byte_at(j) == ')':
                    pd -= 1
            j += 1
    r.append(") -> ")
    var mr = map_type(ret_type)
    r.append(mr.as_str())
    return r

# =============================================================================
#  Keyword escaping
# =============================================================================

function is_keyword(name: str) -> bool:
    return name == "in" or name == "out" or name == "inout" or name == "async" or name == "function" or name == "external" or name == "foreign" or name == "struct" or name == "union" or name == "enum" or name == "flags" or name == "variant" or name == "interface" or name == "opaque" or name == "let" or name == "var" or name == "const" or name == "type" or name == "public" or name == "static" or name == "and" or name == "or" or name == "not" or name == "is" or name == "if" or name == "else" or name == "while" or name == "for" or name == "match" or name == "return" or name == "break" or name == "continue" or name == "defer" or name == "unsafe" or name == "when" or name == "pass" or name == "true" or name == "false" or name == "null" or name == "void"


## True when a typedef's qualType resolves to the same name (self-alias).
## e.g. `typedef struct Vec2 { ... } Vec2;` has name="Vec2", qualType="struct Vec2".
function is_self_alias(name: str, qt: str) -> bool:
    let t = str_strip(qt)
    if str_has_prefix(t, "struct "):
        return t.slice(7, t.len - 7) == name
    if str_has_prefix(t, "union "):
        return t.slice(6, t.len - 6) == name
    if str_has_prefix(t, "enum "):
        return t.slice(5, t.len - 5) == name
    return t == name

function safe_name(s: string.String) -> string.String:
    if is_keyword(s.as_str()):
        var r = string.String.from_str(s.as_str())
        r.append("_")
        return r
    return string.String.from_str(s.as_str())

# =============================================================================
#  Declaration types
# =============================================================================

struct CDecl:
    kind: string.String     # "record", "enum", "function", "typedef", "variable"
    c_name: string.String
    mt_name: string.String
    tag: string.String      # "struct"/"union"/""
    qual_type: string.String
    is_complete: bool
    fields: vec.Vec[CField]
    members: vec.Vec[CMember]

struct CField:
    f_name: str
    f_type: string.String

struct CMember:
    ename: str
    evalue: string.String

# =============================================================================
#  AST traversal — extracts declarations from clang JSON
# =============================================================================

## Recursively walk the JSON node tree.  `node_obj` is the Object for the
## current node (or null).  Declarations with a source location are collected.
function walk(node_obj: ptr[json.Object]?, decls: ref[vec.Vec[CDecl]]) -> void:
    if node_obj == null:
        return
    unsafe:
        let kind = jget_str(node_obj, "kind")

        # Only collect declarations with a source location (non-builtin).
        # Builtin/implicit nodes have loc: {}; header decls have offset/line/col.
        let loc_vp = read(node_obj).get("loc")
        let loc_obj = if loc_vp == null: null else: read(loc_vp).as_object()
        var has_loc = false
        if loc_obj != null:
            # Check for an offset or line field (empty loc {} has none).
            let off_vp = read(loc_obj).get("offset")
            if off_vp == null:
                let ln_vp = read(loc_obj).get("line")
                has_loc = ln_vp != null
            else:
                has_loc = true

        if has_loc and kind != "":
            if kind == "RecordDecl":
                let name = jget_str(node_obj, "name")
                let tag = jget_str(node_obj, "tagUsed")
                var comp = read(node_obj).get("completeDefinition") != null
                if name != "":
                    var d = mk_decl("record", name, tag)
                    d.is_complete = comp
                    if comp:
                        extract_fields(node_obj, ref_of(d))
                    decls.push(d)
            else if kind == "EnumDecl":
                let name = jget_str(node_obj, "name")
                if name != "":
                    var d = mk_decl("enum", name, "")
                    extract_members(node_obj, ref_of(d))
                    decls.push(d)
                else:
                    # Anonymous enum (e.g. typedef enum { ... } Name) — queue
                    # its members to be paired with the following TypedefDecl.
                    var d = mk_decl("enum", "", "")
                    extract_members(node_obj, ref_of(d))
                    decls.push(d)
            else if kind == "FunctionDecl":
                let sc = jget_str(node_obj, "storageClass")
                if sc != "static":
                    let name = jget_str(node_obj, "name")
                    if name != "":
                        let qtp = read(node_obj).get("type")
                        let qt = jget_qualtype(qtp)
                        var d = mk_decl("function", name, "")
                        d.qual_type = string.String.from_str(qt)
                        decls.push(d)
            else if kind == "TypedefDecl":
                let name = jget_str(node_obj, "name")
                if name != "":
                    let qtp = read(node_obj).get("type")
                    let qt = jget_qualtype(qtp)
                    # For struct/union self-aliases, skip (RecordDecl handles it).
                    # For enum self-aliases where an anonymous EnumDecl was just
                    # collected, steal the anonymous enum's members.
                    if not is_self_alias(name, qt):
                        var d = mk_decl("typedef", name, "")
                        d.qual_type = string.String.from_str(qt)
                        decls.push(d)
                    else if str_has_prefix(str_strip(qt), "enum "):
                        # Pair this typedef with the preceding anonymous EnumDecl.
                        var anon_idx = decls.len()
                        while anon_idx > 0:
                            anon_idx -= 1
                            let adp = decls.get(anon_idx) else:
                                break
                            if read(adp).kind.as_str() == "enum" and read(adp).c_name.as_str() == "":
                                read(adp).c_name = string.String.from_str(name)
                                read(adp).mt_name = safe_name(string.String.from_str(name))
                                break
            else if kind == "VarDecl":
                let sc = jget_str(node_obj, "storageClass")
                if sc != "static":
                    let name = jget_str(node_obj, "name")
                    if name != "":
                        let qtp = read(node_obj).get("type")
                        let qt = jget_qualtype(qtp)
                        var d = mk_decl("variable", name, "")
                        d.qual_type = string.String.from_str(qt)
                        decls.push(d)

        # Recurse into children
        let children = jget_inner(node_obj)
        if children != null:
            var i: ptr_uint = 0
            while true:
                let c_vp = read(children).get(i) else:
                    break
                walk(read(c_vp).as_object(), decls)
                i += 1


function mk_decl(kind: str, c_name: str, tag: str) -> CDecl:
    var kn = string.String.from_str(kind)
    var cn = string.String.from_str(c_name)
    var mn = safe_name(string.String.from_str(c_name))
    var tn = string.String.from_str(tag)
    return CDecl(
        kind = kn, c_name = cn, mt_name = mn, tag = tn,
        qual_type = string.String.create(), is_complete = true,
        fields = vec.Vec[CField].create(),
        members = vec.Vec[CMember].create(),
    )


function extract_fields(node: ptr[json.Object], decl: ref[CDecl]) -> void:
    unsafe:
        let children = jget_inner(node)
        if children == null:
            return
        var i: ptr_uint = 0
        while true:
            let cvp = read(children).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null:
                let k = jget_str(co, "kind")
                if k == "FieldDecl":
                    let fname = jget_str(co, "name")
                    let ftp = read(co).get("type")
                    let ft = jget_qualtype(ftp)
                    if fname != "" and ft != "":
                        decl.fields.push(CField(f_name = fname, f_type = map_type(ft)))
            i += 1


function extract_members(node: ptr[json.Object], decl: ref[CDecl]) -> void:
    unsafe:
        let children = jget_inner(node)
        if children == null:
            return
        var i: ptr_uint = 0
        var counter: long = 0
        while true:
            let cvp = read(children).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null:
                let k = jget_str(co, "kind")
                if k == "EnumConstantDecl":
                    let en = jget_str(co, "name")
                    if en != "":
                        var vt = find_enum_value(co, en)
                        if vt != "":
                            counter = parse_long(vt)
                        var val_str = long_to_str(counter)
                        decl.members.push(CMember(ename = en, evalue = string.String.from_str(val_str)))
                        counter += 1
            i += 1


function long_to_str(n: long) -> str:
    if n < 0:
        var u = uint_to_str(ptr_uint<-(-n))
        var r = string.String.from_str("-")
        r.append(u)
        return r.as_str()
    return uint_to_str(ptr_uint<-n)


## Find the value of an enum constant by looking inside its inner
## ConstantExpr child node.
function find_enum_value(ec_node: ptr[json.Object], name: str) -> str:
    unsafe:
        # First try the node's own "value" field (some clang versions).
        let direct_vp = read(ec_node).get("value")
        let direct = jstr(direct_vp)
        if direct != "":
            return direct
        # Search inner children for a ConstantExpr with a "value" field.
        let inner = jget_inner(ec_node)
        if inner == null:
            return ""
        var i: ptr_uint = 0
        while true:
            let cvp = read(inner).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null:
                let k = jget_str(co, "kind")
                if k == "ConstantExpr":
                    let vp = read(co).get("value")
                    let v = jstr(vp)
                    if v != "":
                        return v
            i += 1
    return ""

# =============================================================================
#  Emitter — generates the .mt external module source
# =============================================================================

function emit_module(decls: vec.Vec[CDecl], header_path: str, link_libs: vec.Vec[str], incs: vec.Vec[str]) -> string.String:
    var buf = string.String.create()
    buf.append("# generated by mtc bindgen from ")
    buf.append(header_path)
    buf.append("\nexternal\n")

    var i: ptr_uint = 0
    while i < link_libs.len():
        let l = link_libs.get(i) else:
            break
        buf.append("\nlink \"")
        unsafe: buf.append(read(l))
        buf.append("\"")
        i += 1
    i = 0
    while i < incs.len():
        let inc = incs.get(i) else:
            break
        buf.append("\ninclude \"")
        unsafe: buf.append(read(inc))
        buf.append("\"")
        i += 1
    if link_libs.len() > 0 or incs.len() > 0:
        buf.append("\n")

    i = 0
    while i < decls.len():
        let dp = decls.get(i) else:
            break
        unsafe: emit_decl(ref_of(buf), read(dp))
        i += 1
    return buf


function emit_decl(buf: ref[string.String], d: CDecl) -> void:
    let k = d.kind.as_str()

    if k == "record":
        let t = d.tag.as_str()
        if not d.is_complete:
            buf.append("\nopaque ")
            buf.append(d.mt_name.as_str())
            buf.append("\n")
            return
        if t == "union":
            buf.append("\nunion ")
        else:
            buf.append("\nstruct ")
        buf.append(d.mt_name.as_str())
        buf.append(":\n")
        var fi: ptr_uint = 0
        while fi < d.fields.len():
            let fp = d.fields.get(fi) else:
                break
            unsafe:
                buf.append("    ")
                buf.append(fp.f_name)
                buf.append(": ")
                buf.append(fp.f_type.as_str())
                buf.append("\n")
            fi += 1
        return

    if k == "enum":
        var is_flags = true
        var mi: ptr_uint = 0
        while mi < d.members.len():
            let mp = d.members.get(mi) else:
                break
            unsafe:
                let v = parse_long(mp.evalue.as_str())
                if v != 0 and (v & (v - 1)) != 0:
                    is_flags = false
            mi += 1
        if is_flags:
            buf.append("\nflags ")
        else:
            buf.append("\nenum ")
        buf.append(d.mt_name.as_str())
        buf.append(": int\n")
        mi = 0
        while mi < d.members.len():
            let mp = d.members.get(mi) else:
                break
            unsafe:
                buf.append("    ")
                buf.append(mp.ename)
                buf.append(" = ")
                buf.append(mp.evalue.as_str())
                buf.append("\n")
            mi += 1
        return

    if k == "function":
        let qt = d.qual_type.as_str()
        if qt == "":
            return
        # Parse "ret (params)" signature
        var open: ptr_uint = 0
        var depth = 0
        var pi: ptr_uint = 0
        while pi < qt.len:
            let b = qt.byte_at(pi)
            if b == '(' and depth == 0:
                open = pi
                depth = 1
            else if b == '(':
                depth += 1
            else if b == ')':
                depth -= 1
            pi += 1
        if open == 0:
            return
        var ret = map_type(str_strip(qt.slice(0, open)))
        let ps = qt.slice(open + 1, qt.len - open - 2)
        buf.append("\nexternal function ")
        buf.append(d.mt_name.as_str())
        buf.append("(")
        var an: ptr_uint = 0
        if ps != "void" and ps != "":
            var comma: ptr_uint = 0
            var pd: ptr_uint = 0
            var j: ptr_uint = 0
            while j <= ps.len:
                if j == ps.len or (ps.byte_at(j) == ',' and pd == 0):
                    let arg = str_strip(ps.slice(comma, j - comma))
                    if an > 0:
                        buf.append(", ")
                    buf.append("arg")
                    buf.append(uint_to_str(an))
                    buf.append(": ")
                    var mapped = map_type(arg)
                    buf.append(mapped.as_str())
                    comma = j + 1
                    an += 1
                else if j < ps.len:
                    if ps.byte_at(j) == '(':
                        pd += 1
                    if ps.byte_at(j) == ')':
                        pd -= 1
                j += 1
        buf.append(") -> ")
        buf.append(ret.as_str())
        buf.append("\n")
        return

    if k == "typedef":
        let mt = map_type(d.qual_type.as_str())
        buf.append("\ntype ")
        buf.append(d.mt_name.as_str())
        buf.append(" = ")
        buf.append(mt.as_str())
        buf.append("\n")
        return

    if k == "variable":
        let mt = map_type(d.qual_type.as_str())
        buf.append("\nconst ")
        buf.append(d.mt_name.as_str())
        buf.append(": ")
        buf.append(mt.as_str())
        buf.append("\n")

# =============================================================================
#  Main entry point
# =============================================================================

public struct BindgenOptions:
    module_name: string.String
    header_path: string.String
    output_path: Option[str]
    link_libs: vec.Vec[str]
    include_headers: vec.Vec[str]
    clang_bin: str


public function generate(opts: ref[BindgenOptions]) -> Result[string.String, string.String]:
    let header = opts.header_path.as_str()
    if not fs.is_file(header):
        return Result[string.String, string.String].failure(error = string.String.from_str("header not found"))

    var clang = "clang"
    let cb = opts.clang_bin
    if cb != "":
        clang = cb

    var args = vec.Vec[str].create()
    defer args.release()
    args.push(clang)
    args.push("-Xclang")
    args.push("-ast-dump=json")
    args.push("-fsyntax-only")
    args.push("-x")
    args.push("c")
    args.push(header)

    match process.capture(args.as_span()):
        Result.success as captured:
            var result = captured.value
            defer result.stdout.release()
            defer result.stderr.release()

            if result.status.exit_code != 0:
                let et = result.stderr.as_str()
                var m = string.String.from_str("clang failed: ")
                m.append(et)
                return Result[string.String, string.String].failure(error = m)

            let js = result.stdout.as_str()
            if js.len == 0:
                return Result[string.String, string.String].failure(error = string.String.from_str("clang produced no output"))

            match json.parse(js):
                Result.success as parsed_val:
                    var parsed = parsed_val.value
                    defer json.release_value(parsed)

                    var decls = vec.Vec[CDecl].create()
                    defer decls.release()
                    walk(parsed.as_object(), ref_of(decls))

                    var src = emit_module(decls, header, opts.link_libs, opts.include_headers)
                    return Result[string.String, string.String].success(value = src)
                Result.failure as parse_err:
                    var m = string.String.from_str("json parse error: ")
                    m.append(parse_err.error.message.as_str())
                    parse_err.error.release()
                    return Result[string.String, string.String].failure(error = m)

        Result.failure as fail:
            var err = fail.error
            var m = string.String.from_str("clang: ")
            m.append(err.message.as_str())
            err.message.release()
            return Result[string.String, string.String].failure(error = m)
