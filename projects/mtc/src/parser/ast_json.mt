## AST JSON output builder — emits the Ruby mtc AST JSON format.
##
## Nodes use $mt_type markers. Symbols use $sym wrappers. Primitives pass through.

import std.string as string_mod
import std.fmt as fmt
import std.vec as vec_mod
import std.str

public struct AstBuf:
    buf: string_mod.String
    first_field: bool

# ── node framing ──────────────────────────────────────────────────────────

public function ast_open(buf: ref[AstBuf], node_type: str) -> void:
    buf.buf.push_byte('{')
    buf.buf.append("\"$mt_type\":\"AST:")
    buf.buf.append(node_type)
    buf.buf.push_byte('"')
    buf.first_field = false

public function ast_close(buf: ref[AstBuf]) -> void:
    buf.buf.push_byte('}')
    buf.first_field = false

# ── field emitters ────────────────────────────────────────────────────────

public function ast_comma(buf: ref[AstBuf]) -> void:
    buf.buf.push_byte(',')
    buf.first_field = false

public function ast_key(buf: ref[AstBuf], key: str) -> void:
    if not buf.first_field:
        buf.buf.push_byte(',')

    buf.buf.push_byte('"')
    buf.buf.append(key)
    buf.buf.append("\":")
    buf.first_field = false

# ── typed field helpers ───────────────────────────────────────────────────

public function ast_str(buf: ref[AstBuf], key: str, value: str) -> void:
    ast_key(buf, key)
    var esc = json_escaped_str(value)
    buf.buf.append(esc.as_str())
    esc.release()

public function ast_null(buf: ref[AstBuf], key: str) -> void:
    ast_key(buf, key)
    buf.buf.append("null")

public function ast_bool(buf: ref[AstBuf], key: str, value: bool) -> void:
    ast_key(buf, key)
    if value:
        buf.buf.append("true")
    else:
        buf.buf.append("false")

public function ast_int(buf: ref[AstBuf], key: str, value: int) -> void:
    ast_key(buf, key)
    fmt.append_int(ref_of(buf.buf), value)

public function ast_uint(buf: ref[AstBuf], key: str, value: ptr_uint) -> void:
    ast_key(buf, key)
    fmt.append_ptr_uint(ref_of(buf.buf), value)

public function ast_sym(buf: ref[AstBuf], key: str, sym_name: str) -> void:
    ast_key(buf, key)
    buf.buf.append("{\"$sym\":\"")
    buf.buf.append(sym_name)
    buf.buf.append("\"}")

public function ast_sym_nullable(buf: ref[AstBuf], key: str, sym_val: str) -> void:
    ast_key(buf, key)
    if sym_val == "" or sym_val == "null":
        buf.buf.append("null")
    else:
        buf.buf.append("{\"$sym\":\"")
        buf.buf.append(sym_val)
        buf.buf.append("\"}")

# ── array framing ─────────────────────────────────────────────────────────

public function ast_array_start(buf: ref[AstBuf], key: str) -> void:
    ast_key(buf, key)
    buf.buf.push_byte('[')

public function ast_array_end(buf: ref[AstBuf]) -> void:
    buf.buf.push_byte(']')

# ── raw JSON injection (for pre-built sub-nodes) ──────────────────────────

public function ast_raw(buf: ref[AstBuf], key: str, json_frag: str) -> void:
    ast_key(buf, key)
    buf.buf.append(json_frag)

# ── name serialization ────────────────────────────────────────────────────

public function name_json(name_parts: vec_mod.Vec[str]) -> string_mod.String:
    var result = string_mod.String.create()
    result.append("{\"$mt_type\":\"AST:QualifiedName\",\"parts\":[")
    var first = true
    var i: ptr_uint = 0
    while i < name_parts.len:
        let part = name_parts.at(i) else:
            break
        if not first:
            result.push_byte(',')
        var esc = json_escaped_str(part)
        result.append(esc.as_str())
        esc.release()
        first = false
        i += 1
    result.append("],\"type_arguments\":[],\"line\":null,\"column\":null}")
    return result

# ── tiny JSON string escape ───────────────────────────────────────────────

public function json_escaped_str(src: str) -> string_mod.String:
    var buf = string_mod.String.create()
    buf.push_byte('"')
    var i: ptr_uint = 0
    while i < src.len:
        let ch = src.byte_at(i)
        if ch == '"':
            buf.append("\\\"")
        else if ch == '\\':
            buf.append("\\\\")
        else if ch == '\n':
            buf.append("\\n")
        else if ch == '\r':
            buf.append("\\r")
        else if ch == '\t':
            buf.append("\\t")
        else:
            buf.push_byte(ch)
        i += 1
    buf.push_byte('"')
    return buf
