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
            if str_has_prefix(str_strip(pointee), "const"):
                return string.String.from_str("cstr")
            return string.String.from_str("ptr[char]")
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

    # Function pointer: either ret (params) or ret (*)(params)
    if t.len > 2 and t.byte_at(t.len - 1) == ')':
        # Scan for (*) to distinguish fn-pointer from plain function.
        var star_idx: ptr_uint = 0
        var found_fp = false
        while star_idx < t.len:
            if t.byte_at(star_idx) == '(' and star_idx + 2 < t.len and t.byte_at(star_idx + 1) == '*' and t.byte_at(star_idx + 2) == ')':
                found_fp = true
                break
            star_idx += 1
        if found_fp:
            # ret (*)(params) — split on (*)
            let ret_t = str_strip(t.slice(0, star_idx))
            let rest = t.slice(star_idx + 3, t.len - star_idx - 3)
            let ps = strip_surrounding_parens(str_strip(rest))
            return emit_fn_ptr_from_parts(ret_t, ps)
        else:
            # ret (params) — regular function
            var open: ptr_uint = 0
            var depth = 0
            var pi: ptr_uint = 0
            while pi < t.len:
                let b = t.byte_at(pi)
                if b == '(' and depth == 0:
                    open = pi
                    depth = 1
                else if b == '(':
                    depth += 1
                else if b == ')':
                    depth -= 1
                pi += 1
            if open > 0:
                return emit_fn_ptr_from_parts(str_strip(t.slice(0, open)), t.slice(open + 1, t.len - open - 2))

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


function emit_fn_ptr_from_parts(ret_type: str, params: str) -> string.String:
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
                if params.byte_at(j) == '(': pd += 1
                if params.byte_at(j) == ')': pd -= 1
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
    kind: string.String
    c_name: string.String
    mt_name: string.String
    tag: string.String
    qual_type: string.String
    is_complete: bool
    fields: vec.Vec[CField]
    members: vec.Vec[CMember]
    param_names: vec.Vec[string.String]

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
        var loc_obj: ptr[json.Object]? = null
        if loc_vp != null:
            loc_obj = read(loc_vp).as_object()
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
                        # Extract parameter names from ParmVarDecl children.
                        extract_param_names(node_obj, ref_of(d))
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
                if sc != "static" and sc != "extern":
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
        param_names = vec.Vec[string.String].create(),
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


## Guard against reserved-word parameter names (e.g. 'in', 'out').
function safe_param_name(n: string.String) -> string.String:
    if is_keyword(n.as_str()):
        var r = string.String.from_str(n.as_str())
        r.append("_")
        return r
    return string.String.from_str(n.as_str())

## Extract function parameter names from ParmVarDecl inner children.
function extract_param_names(fn_node: ptr[json.Object], decl: ref[CDecl]) -> void:
    unsafe:
        let children = jget_inner(fn_node)
        if children == null:
            return
        var i: ptr_uint = 0
        while true:
            let cvp = read(children).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null:
                let k = jget_str(co, "kind")
                if k == "ParmVarDecl":
                    let pname = jget_str(co, "name")
                    if pname != "":
                        decl.param_names.push(safe_param_name(string.String.from_str(pname)))
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

function emit_module(decls: vec.Vec[CDecl], header_path: str, link_libs: vec.Vec[str], incs: vec.Vec[str], opts: ref[BindgenOptions]) -> string.String:
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
        unsafe: emit_decl(ref_of(buf), read(dp), opts)
        i += 1
    return buf


function emit_decl(buf: ref[string.String], d: CDecl, opts: ref[BindgenOptions]) -> void:
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
                var escaped = safe_name(string.String.from_str(fp.f_name))
                buf.append("    ")
                buf.append(escaped.as_str())
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
        match function_sig_text(d.qual_type.as_str()):
            Option.none:
                return
            Option.some as sig_payload:
                let sig = sig_payload.value
                let ps = sig.params_text
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
                            var override: Option[str] = Option[str].none
                            # Use stored param name if available, otherwise synthetic.
                            var pn = d.param_names.get(an)
                            if pn == null:
                                buf.append("arg")
                                buf.append(uint_to_str(an))
                            else:
                                unsafe:
                                    let param_name = read(pn).as_str()
                                    buf.append(param_name)
                                    override = find_param_override(
                                        opts.param_overrides.as_span(), d.c_name.as_str(), param_name
                                    )
                            buf.append(": ")
                            match override:
                                Option.some as override_type:
                                    buf.append(override_type.value)
                                Option.none:
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
                match find_type_override(opts.return_overrides.as_span(), d.c_name.as_str()):
                    Option.some as override_type:
                        buf.append(override_type.value)
                    Option.none:
                        var ret = map_type(sig.return_text)
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
        buf.append("const ")
        buf.append(d.mt_name.as_str())
        buf.append(": ")
        buf.append(mt.as_str())
        buf.append("\n")


## Run clang -E -dM to extract #define macro constants.
function extract_macros(header: str, clang_bin: str, clang_args: span[str], decls: ref[vec.Vec[CDecl]]) -> void:
    var args = vec.Vec[str].create()
    defer: args.release()
    args.push(clang_bin)
    args.push("-E")
    args.push("-dM")
    args.push("-x")
    args.push("c")
    var cai: ptr_uint = 0
    while cai < clang_args.len:
        args.push(unsafe: read(clang_args.data + cai))
        cai += 1
    args.push(header)

    match process.capture(args.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.stdout.release()
            defer: result.stderr.release()
            if result.status.exit_code != 0:
                return
            let text = result.stdout.as_str()
            var pos: ptr_uint = 0
            while pos < text.len:
                var line_start = pos
                var line_end = pos
                while line_end < text.len and text.byte_at(line_end) != '\n':
                    line_end += 1
                let line = text.slice(line_start, line_end - line_start)
                pos = line_end + 1
                if line.len < 9:
                    continue
                if line.byte_at(0) != '#' or line.byte_at(1) != 'd':
                    continue
                var si: ptr_uint = 8
                while si < line.len and line.byte_at(si) == ' ':
                    si += 1
                if si >= line.len:
                    continue
                var name_start = si
                while si < line.len and is_ident_byte(line.byte_at(si)):
                    si += 1
                let name = line.slice(name_start, si - name_start)
                if name == "":
                    continue
                # Skip compiler builtins and system macros.
                if str_has_prefix(name, "__"):
                    continue
                if str_has_prefix(name, "_"):
                    continue
                if name == "linux" or name == "unix":
                    continue
                if si < line.len and line.byte_at(si) == '(':
                    continue
                while si < line.len and line.byte_at(si) == ' ':
                    si += 1
                if si >= line.len:
                    continue
                let value = line.slice(si, line.len - si)
                if not is_integer_string(value):
                    continue
                var d = mk_decl("variable", name, "")
                d.qual_type.append("int = ")
                d.qual_type.append(value)
                decls.push(d)
        Result.failure:
            pass


function is_ident_byte(b: ubyte) -> bool:
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_'


function is_integer_string(v: str) -> bool:
    if v.len == 0:
        return false
    var i: ptr_uint = 0
    if v.byte_at(0) == '-':
        i = 1
    if i >= v.len:
        return false
    while i < v.len:
        let b = v.byte_at(i)
        if b < '0' or b > '9':
            return false
        i += 1
    return true

# =============================================================================
#  Main entry point
# =============================================================================

## A `--nullable-policy` return-type override: the C symbol and its Milk Tea
## type (the host's `function_return_type_overrides` entry).
public struct TypeOverride:
    function: string.String
    ty: string.String


## A `--nullable-policy` parameter-type override (`<function>.<parameter>`).
public struct ParamOverride:
    function: string.String
    parameter: string.String
    ty: string.String


## A generated module plus its optional nullable-policy report (the wire
## shape `Bindgen.generate_with_report` returns).
public struct BindgenOutput:
    source: string.String
    report: string.String


public struct BindgenOptions:
    module_name: string.String
    header_path: string.String
    output_path: Option[str]
    link_libs: vec.Vec[str]
    include_headers: vec.Vec[str]
    clang_bin: str
    ## Extra clang flags (`--clang-arg`), in command-line order.
    clang_args: vec.Vec[str]
    return_overrides: vec.Vec[TypeOverride]
    param_overrides: vec.Vec[ParamOverride]
    ## The absolute header path the nullable report records (the host's
    ## `File.expand_path`); empty falls back to `header_path`.
    report_header_path: str


public function generate(opts: ref[BindgenOptions]) -> Result[string.String, string.String]:
    match generate_internal(opts, false):
        Result.success as payload:
            var output = payload.value
            output.report.release()
            return Result[string.String, string.String].success(value = output.source)
        Result.failure as failure:
            return Result[string.String, string.String].failure(error = failure.error)


public function generate_with_report(opts: ref[BindgenOptions]) -> Result[BindgenOutput, string.String]:
    return generate_internal(opts, true)


function generate_internal(opts: ref[BindgenOptions], want_report: bool) -> Result[BindgenOutput, string.String]:
    let header = opts.header_path.as_str()
    if not fs.is_file(header):
        return Result[BindgenOutput, string.String].failure(error = string.String.from_str("header not found"))

    var clang = "clang"
    let cb = opts.clang_bin
    if cb != "":
        clang = cb

    var args = vec.Vec[str].create()
    defer: args.release()
    args.push(clang)
    args.push("-Xclang")
    args.push("-ast-dump=json")
    args.push("-fsyntax-only")
    args.push("-x")
    args.push("c")
    var cai: ptr_uint = 0
    while cai < opts.clang_args.len():
        let arg_ptr = opts.clang_args.get(cai) else:
            break
        args.push(unsafe: read(arg_ptr))
        cai += 1
    args.push(header)

    match process.capture(args.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.stdout.release()
            defer: result.stderr.release()

            if result.status.exit_code != 0:
                let et = result.stderr.as_str()
                var m = string.String.from_str("clang failed: ")
                m.append(et)
                return Result[BindgenOutput, string.String].failure(error = m)

            let js = result.stdout.as_str()
            if js.len == 0:
                return Result[BindgenOutput, string.String].failure(error = string.String.from_str("clang produced no output"))

            match json.parse(js):
                Result.success as parsed_val:
                    var parsed = parsed_val.value
                    defer: json.release_value(parsed)

                    var decls = vec.Vec[CDecl].create()
                    defer: decls.release()
                    walk(parsed.as_object(), ref_of(decls))

                    # Extract #define macros via clang -E -dM.
                    extract_macros(header, clang, opts.clang_args.as_span(), ref_of(decls))

                    match validate_override_targets(ref_of(decls), opts):
                        Option.some as error_message:
                            return Result[BindgenOutput, string.String].failure(error = error_message.value)
                        Option.none:
                            pass

                    var src = emit_module(decls, header, opts.link_libs, opts.include_headers, opts)
                    var report = string.String.create()
                    if want_report:
                        build_nullable_report(ref_of(report), opts, ref_of(decls))
                    return Result[BindgenOutput, string.String].success(value = BindgenOutput(source = src, report = report))
                Result.failure as parse_err:
                    var m = string.String.from_str("json parse error: ")
                    m.append(parse_err.error.message.as_str())
                    parse_err.error.release()
                    return Result[BindgenOutput, string.String].failure(error = m)

        Result.failure as fail:
            var err = fail.error
            var m = string.String.from_str("clang: ")
            m.append(err.message.as_str())
            err.message.release()
            return Result[BindgenOutput, string.String].failure(error = m)

function strip_surrounding_parens(s: str) -> str:
    var result = s
    if result.len > 0 and result.byte_at(0) == '(':
        result = result.slice(1, result.len - 1)
    if result.len > 0 and result.byte_at(result.len - 1) == ')':
        result = result.slice(0, result.len - 1)
    return result


# =============================================================================
#  Nullable policy overrides and report
# =============================================================================

## A clang `qualType` function signature split into its return-type text and the
## parameter-list text (without the surrounding parentheses).
struct FunctionSigText:
    return_text: str
    params_text: str


function function_sig_text(qual_type: str) -> Option[FunctionSigText]:
    if qual_type.len == 0:
        return Option[FunctionSigText].none
    var open: ptr_uint = 0
    var depth = 0
    var found = false
    var i: ptr_uint = 0
    while i < qual_type.len:
        let b = qual_type.byte_at(i)
        if b == '(' and depth == 0:
            open = i
            depth = 1
            found = true
        else if b == '(':
            depth += 1
        else if b == ')':
            depth -= 1
        i += 1
    if not found:
        return Option[FunctionSigText].none
    return Option[FunctionSigText].some(value = FunctionSigText(
        return_text = str_strip(qual_type.slice(0, open)),
        params_text = qual_type.slice(open + 1, qual_type.len - open - 2),
    ))


## The type text of the `index`-th top-level parameter in a parameter-list text.
function param_type_text_at(params: str, index: ptr_uint) -> str:
    if params == "void" or params == "":
        return ""
    var comma: ptr_uint = 0
    var pd: ptr_uint = 0
    var an: ptr_uint = 0
    var j: ptr_uint = 0
    while j <= params.len:
        if j == params.len or (params.byte_at(j) == ',' and pd == 0):
            if an == index:
                return str_strip(params.slice(comma, j - comma))
            comma = j + 1
            an += 1
        else if j < params.len:
            if params.byte_at(j) == '(':
                pd += 1
            if params.byte_at(j) == ')':
                pd -= 1
        j += 1
    return ""


function find_type_override(overrides: span[TypeOverride], function_name: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < overrides.len:
        let entry = unsafe: read(overrides.data + i)
        if entry.function.as_str().equal(function_name):
            return Option[str].some(value = entry.ty.as_str())
        i += 1
    return Option[str].none


function find_param_override(overrides: span[ParamOverride], function_name: str, parameter: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < overrides.len:
        let entry = unsafe: read(overrides.data + i)
        if entry.function.as_str().equal(function_name) and entry.parameter.as_str().equal(parameter):
            return Option[str].some(value = entry.ty.as_str())
        i += 1
    return Option[str].none


function find_function_decl(decls: ref[vec.Vec[CDecl]], function_name: str) -> Option[ptr[CDecl]]:
    var i: ptr_uint = 0
    while i < decls.len():
        let decl_ptr = decls.get(i) else:
            break
        let d = unsafe: read(decl_ptr)
        if d.kind.as_str().equal("function") and d.c_name.as_str().equal(function_name):
            return Option[ptr[CDecl]].some(value = decl_ptr)
        i += 1
    return Option[ptr[CDecl]].none


function param_index_of(names: vec.Vec[string.String], parameter: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < names.len():
        let name_ptr = names.get(i) else:
            break
        if unsafe: read(name_ptr).as_str().equal(parameter):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


## The host's override-target validation (`validate_function_param_type_overrides!`
## and `validate_function_return_type_overrides!`), with its exact messages.
function validate_override_targets(decls: ref[vec.Vec[CDecl]], opts: ref[BindgenOptions]) -> Option[string.String]:
    let header = opts.header_path.as_str()
    var pi: ptr_uint = 0
    while pi < opts.param_overrides.len():
        let entry_ptr = opts.param_overrides.get(pi) else:
            break
        let entry = unsafe: read(entry_ptr)
        match find_function_decl(decls, entry.function.as_str()):
            Option.none:
                var m = string.String.from_str("function_param_type_overrides references unknown function ")
                m.append(entry.function.as_str())
                m.append(" for ")
                m.append(header)
                return Option[string.String].some(value = m)
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match param_index_of(d.param_names, entry.parameter.as_str()):
                    Option.none:
                        var m = string.String.from_str("function_param_type_overrides references unknown parameter ")
                        m.append(entry.function.as_str())
                        m.append(".")
                        m.append(entry.parameter.as_str())
                        m.append(" for ")
                        m.append(header)
                        return Option[string.String].some(value = m)
                    Option.some:
                        pass
        pi += 1

    var ri: ptr_uint = 0
    while ri < opts.return_overrides.len():
        let entry_ptr = opts.return_overrides.get(ri) else:
            break
        let entry = unsafe: read(entry_ptr)
        match find_function_decl(decls, entry.function.as_str()):
            Option.none:
                var m = string.String.from_str("function_return_type_overrides references unknown function ")
                m.append(entry.function.as_str())
                m.append(" for ")
                m.append(header)
                return Option[string.String].some(value = m)
            Option.some:
                pass
        ri += 1
    return Option[string.String].none


# =============================================================================
#  Nullable policy file
# =============================================================================

public struct NullablePolicy:
    return_overrides: vec.Vec[TypeOverride]
    param_overrides: vec.Vec[ParamOverride]


extending NullablePolicy:
    public editable function release() -> void:
        release_type_overrides(ref_of(this.return_overrides))
        release_param_overrides(ref_of(this.param_overrides))


public function release_type_overrides(overrides: ref[vec.Vec[TypeOverride]]) -> void:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            var entry = read(entry_ptr)
            entry.function.release()
            entry.ty.release()
        i += 1
    overrides.release()


public function release_param_overrides(overrides: ref[vec.Vec[ParamOverride]]) -> void:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            var entry = read(entry_ptr)
            entry.function.release()
            entry.parameter.release()
            entry.ty.release()
        i += 1
    overrides.release()


## Load and validate a `--nullable-policy` JSON file, mirroring the host's
## `BindgenCLI#load_nullable_policy` messages.
public function load_nullable_policy(path: str) -> Result[NullablePolicy, string.String]:
    var text: string.String
    match fs.read_text(path):
        Result.failure:
            var m = string.String.from_str("nullable policy file not found: ")
            m.append(path)
            return Result[NullablePolicy, string.String].failure(error = m)
        Result.success as payload:
            text = payload.value
    defer: text.release()

    var parsed: json.Value
    match json.parse(text.as_str()):
        Result.failure as parse_failure:
            var error = parse_failure.error
            var m = string.String.from_str("nullable policy is not valid JSON: ")
            m.append(error.message.as_str())
            error.release()
            return Result[NullablePolicy, string.String].failure(error = m)
        Result.success as parsed_payload:
            parsed = parsed_payload.value
    defer: json.release_value(parsed)

    let object_ptr = parsed.as_object() else:
        return Result[NullablePolicy, string.String].failure(
            error = string.String.from_str("nullable policy must be a JSON object")
        )

    let root = unsafe: read(object_ptr)
    var unknown = string.String.create()
    defer: unknown.release()
    var unknown_count: ptr_uint = 0
    var ei: ptr_uint = 0
    while ei < root.entries.len():
        let entry_ptr = root.entries.get(ei) else:
            break
        let key = unsafe: read(entry_ptr).key.as_str()
        if not (key == "return_types" or key == "parameters"):
            if unknown_count > 0:
                unknown.append(", ")
            unknown.append(key)
            unknown_count += 1
        ei += 1
    if unknown_count > 0:
        var m = string.String.from_str("nullable policy has unknown keys: ")
        m.append(unknown.as_str())
        m.append(" (expected return_types, parameters)")
        return Result[NullablePolicy, string.String].failure(error = m)

    var return_overrides = vec.Vec[TypeOverride].create()
    var param_overrides = vec.Vec[ParamOverride].create()
    var shape_ok = true

    let return_types_ptr = root.get_object("return_types")
    if return_types_ptr != null:
        let return_types = unsafe: read(return_types_ptr)
        var ri: ptr_uint = 0
        while ri < return_types.entries.len():
            let entry_ptr = return_types.entries.get(ri) else:
                break
            let entry = unsafe: read(entry_ptr)
            if entry.value.kind != json.ValueKind.string_:
                shape_ok = false
                break
            return_overrides.push(TypeOverride(
                function = string.String.from_str(entry.key.as_str()),
                ty = string.String.from_str(entry.value.string_value.as_str()),
            ))
            ri += 1
    else if root.get("return_types") != null:
        shape_ok = false

    let parameters_ptr = root.get_object("parameters")
    if parameters_ptr != null:
        let parameters = unsafe: read(parameters_ptr)
        var pi: ptr_uint = 0
        while pi < parameters.entries.len() and shape_ok:
            let entry_ptr = parameters.entries.get(pi) else:
                break
            let entry = unsafe: read(entry_ptr)
            let inner_ptr = entry.value.object_value
            if inner_ptr == null:
                shape_ok = false
                break
            let inner = unsafe: read(inner_ptr)
            var ii: ptr_uint = 0
            while ii < inner.entries.len():
                let inner_entry_ptr = inner.entries.get(ii) else:
                    break
                let inner_entry = unsafe: read(inner_entry_ptr)
                if inner_entry.value.kind != json.ValueKind.string_:
                    shape_ok = false
                    break
                param_overrides.push(ParamOverride(
                    function = string.String.from_str(entry.key.as_str()),
                    parameter = string.String.from_str(inner_entry.key.as_str()),
                    ty = string.String.from_str(inner_entry.value.string_value.as_str()),
                ))
                ii += 1
            pi += 1
    else if root.get("parameters") != null:
        shape_ok = false

    if not shape_ok:
        release_type_overrides(ref_of(return_overrides))
        release_param_overrides(ref_of(param_overrides))
        return Result[NullablePolicy, string.String].failure(error = string.String.from_str(
            "nullable policy must map {\"return_types\": {symbol: \"type?\"}, \"parameters\": {symbol: {param: \"type?\"}}}"
        ))

    return Result[NullablePolicy, string.String].success(value = NullablePolicy(
        return_overrides = return_overrides,
        param_overrides = param_overrides,
    ))


# =============================================================================
#  Nullable policy report
# =============================================================================

struct ReportParamEntry:
    function: str
    parameter: str
    override_type: str
    auto_type: string.String
    c_type: str


struct ReportReturnEntry:
    function: str
    override_type: str
    auto_type: string.String
    c_type: str


function report_param_compare(left: ptr[ReportParamEntry], right: ptr[ReportParamEntry]) -> int:
    let l = unsafe: read(left)
    let r = unsafe: read(right)
    let by_function = l.function.compare(r.function)
    if by_function != 0:
        return by_function
    return l.parameter.compare(r.parameter)


function report_return_compare(left: ptr[ReportReturnEntry], right: ptr[ReportReturnEntry]) -> int:
    return unsafe: read(left).function.compare(unsafe: read(right).function)


function release_param_entries(entries: ref[vec.Vec[ReportParamEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        unsafe:
            read(entry_ptr).auto_type.release()
        i += 1
    entries.release()


function release_return_entries(entries: ref[vec.Vec[ReportReturnEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        unsafe:
            read(entry_ptr).auto_type.release()
        i += 1
    entries.release()


## The host's `nullable_policy_report`: manually overridden entries whose type
## actually differs from the automatic mapping, sorted for stable output.
function build_nullable_report(target: ref[string.String], opts: ref[BindgenOptions], decls: ref[vec.Vec[CDecl]]) -> void:
    var param_entries = vec.Vec[ReportParamEntry].create()
    defer: release_param_entries(ref_of(param_entries))
    var return_entries = vec.Vec[ReportReturnEntry].create()
    defer: release_return_entries(ref_of(return_entries))

    var pi: ptr_uint = 0
    while pi < opts.param_overrides.len():
        let entry_ptr = opts.param_overrides.get(pi) else:
            break
        let entry = unsafe: read(entry_ptr)
        let override_type = entry.ty.as_str()
        if not override_type.contains_substring("?"):
            pi += 1
            continue
        match find_function_decl(decls, entry.function.as_str()):
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match param_index_of(d.param_names, entry.parameter.as_str()):
                    Option.some as index:
                        match function_sig_text(d.qual_type.as_str()):
                            Option.some as sig_payload:
                                let c_type = param_type_text_at(sig_payload.value.params_text, index.value)
                                var auto_type = map_type(c_type)
                                if auto_type.as_str().equal(override_type):
                                    auto_type.release()
                                else:
                                    param_entries.push(ReportParamEntry(
                                        function = entry.function.as_str(),
                                        parameter = entry.parameter.as_str(),
                                        override_type = override_type,
                                        auto_type = auto_type,
                                        c_type = c_type,
                                    ))
                            Option.none:
                                pass
                    Option.none:
                        pass
            Option.none:
                pass
        pi += 1

    var ri: ptr_uint = 0
    while ri < opts.return_overrides.len():
        let entry_ptr = opts.return_overrides.get(ri) else:
            break
        let entry = unsafe: read(entry_ptr)
        let override_type = entry.ty.as_str()
        if not override_type.contains_substring("?"):
            ri += 1
            continue
        match find_function_decl(decls, entry.function.as_str()):
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match function_sig_text(d.qual_type.as_str()):
                    Option.some as sig_payload:
                        let c_type = sig_payload.value.return_text
                        var auto_type = map_type(c_type)
                        if auto_type.as_str().equal(override_type):
                            auto_type.release()
                        else:
                            return_entries.push(ReportReturnEntry(
                                function = entry.function.as_str(),
                                override_type = override_type,
                                auto_type = auto_type,
                                c_type = c_type,
                            ))
                    Option.none:
                        pass
            Option.none:
                pass
        ri += 1

    param_entries.sort_by(report_param_compare)
    return_entries.sort_by(report_return_compare)

    let report_header = if opts.report_header_path.len > 0: opts.report_header_path else: opts.header_path.as_str()
    target.append("{\n  \"module_name\": ")
    append_json_string(target, opts.module_name.as_str())
    target.append(",\n  \"header_path\": ")
    append_json_string(target, report_header)
    target.append(",\n  \"summary\": {\n    \"parameters\": ")
    target.append(uint_to_str(param_entries.len()))
    target.append(",\n    \"return_types\": ")
    target.append(uint_to_str(return_entries.len()))
    target.append(",\n    \"total\": ")
    target.append(uint_to_str(param_entries.len() + return_entries.len()))
    target.append("\n  },\n  \"manual_nullable_policy\": {\n    \"parameters\": ")
    append_param_entries_json(target, ref_of(param_entries))
    target.append(",\n    \"return_types\": ")
    append_return_entries_json(target, ref_of(return_entries))
    target.append("\n  }\n}")


function append_param_entries_json(target: ref[string.String], entries: ref[vec.Vec[ReportParamEntry]]) -> void:
    if entries.len() == 0:
        target.append("[]")
        return
    target.append("[\n")
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if i > 0:
            target.append(",\n")
        target.append("      {\n        \"function\": ")
        append_json_string(target, entry.function)
        target.append(",\n        \"parameter\": ")
        append_json_string(target, entry.parameter)
        target.append(",\n        \"override_type\": ")
        append_json_string(target, entry.override_type)
        target.append(",\n        \"auto_type\": ")
        append_json_string(target, entry.auto_type.as_str())
        target.append(",\n        \"c_type\": ")
        append_json_string(target, entry.c_type)
        target.append("\n      }")
        i += 1
    target.append("\n    ]")


function append_return_entries_json(target: ref[string.String], entries: ref[vec.Vec[ReportReturnEntry]]) -> void:
    if entries.len() == 0:
        target.append("[]")
        return
    target.append("[\n")
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if i > 0:
            target.append(",\n")
        target.append("      {\n        \"function\": ")
        append_json_string(target, entry.function)
        target.append(",\n        \"override_type\": ")
        append_json_string(target, entry.override_type)
        target.append(",\n        \"auto_type\": ")
        append_json_string(target, entry.auto_type.as_str())
        target.append(",\n        \"c_type\": ")
        append_json_string(target, entry.c_type)
        target.append("\n      }")
        i += 1
    target.append("\n    ]")


function hex_digit(value: ubyte) -> ubyte:
    if value < 10:
        return value + '0'
    return value - 10 + 'a'


function append_json_string(target: ref[string.String], value: str) -> void:
    target.push_byte(34)
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b == 34:
            target.append("\\\"")
        else if b == 92:
            target.append("\\\\")
        else if b == 10:
            target.append("\\n")
        else if b == 13:
            target.append("\\r")
        else if b == 9:
            target.append("\\t")
        else if b < 32:
            target.append("\\u00")
            target.push_byte(hex_digit(b / 16))
            target.push_byte(hex_digit(b % 16))
        else:
            target.push_byte(b)
        i += 1
    target.push_byte(34)
