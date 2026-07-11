## Shared lowering utilities — string builders, span helpers, allocation, type
## inspection.  Imported by lowering.mt and its extracted helper modules (dyn,
## event, async) so they stay free of circular dependencies on the main lowering
## context.
##
## Mirrors lib/milk_tea/core/lowering/utils.rb (c_name helpers) + the monotonic
## temp-counter and string builder helpers scattered in the Ruby lowerer.

import std.vec as vec
import std.string as string
import std.str
import std.mem.heap as heap_mod

import mtc.ir as ir
import mtc.semantic.types as types
import mtc.c_naming as naming


# =============================================================================
#  String concatenation
# =============================================================================

public function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()


public function j3(a: str, b: str, c: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    return buf.as_str()


public function j4(a: str, b: str, c: str, d: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    return buf.as_str()


public function j5(a: str, b: str, c: str, d: str, e: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    return buf.as_str()


public function j6(a: str, b: str, c: str, d: str, e: str, f: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    buf.append(f)
    return buf.as_str()


# =============================================================================
#  Single-element span helpers
# =============================================================================

public function sp_type(t: types.Type) -> span[types.Type]:
    var buf = vec.Vec[types.Type].create()
    buf.push(t)
    return buf.as_span()


public function sp_fields(field1: ir.AggregateField) -> span[ir.AggregateField]:
    var buf = vec.Vec[ir.AggregateField].create()
    buf.push(field1)
    return buf.as_span()


public function sp_fields2(f1: ir.AggregateField, f2: ir.AggregateField) -> span[ir.AggregateField]:
    var buf = vec.Vec[ir.AggregateField].create()
    buf.push(f1)
    buf.push(f2)
    return buf.as_span()


public function sp_type2(t1: types.Type, t2: types.Type) -> span[types.Type]:
    var buf = vec.Vec[types.Type].create()
    buf.push(t1)
    buf.push(t2)
    return buf.as_span()


public function sp_expr(expr: ptr[ir.Expr]) -> span[ir.Expr]:
    var buf = vec.Vec[ir.Expr].create()
    unsafe:
        buf.push(read(expr))
    return buf.as_span()


# =============================================================================
#  IR allocation
# =============================================================================

public function alloc_expr(value: ir.Expr) -> ptr[ir.Expr]:
    var node = unsafe: ptr[ir.Expr]<-heap_mod.must_alloc[ir.Expr](1)
    unsafe:
        read(node) = value
    return node


public function alloc_stmt(value: ir.Stmt) -> ptr[ir.Stmt]:
    var node = unsafe: ptr[ir.Stmt]<-heap_mod.must_alloc[ir.Stmt](1)
    unsafe:
        read(node) = value
    return node


# =============================================================================
#  IR expression type extraction
# =============================================================================

public function ir_expr_type(ep: ptr[ir.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as x:
                return x.ty
            ir.Expr.expr_member as x:
                return x.ty
            ir.Expr.expr_index as x:
                return x.ty
            ir.Expr.expr_checked_index as x:
                return x.ty
            ir.Expr.expr_checked_span_index as x:
                return x.ty
            ir.Expr.expr_call as x:
                return x.ty
            ir.Expr.expr_call_indirect as x:
                return x.ty
            ir.Expr.expr_unary as x:
                return x.ty
            ir.Expr.expr_binary as x:
                return x.ty
            ir.Expr.expr_conditional as x:
                return x.ty
            ir.Expr.expr_cast as x:
                return x.ty
            ir.Expr.expr_integer_literal as x:
                return x.ty
            ir.Expr.expr_boolean_literal as x:
                return x.ty
            ir.Expr.expr_string_literal as x:
                return x.ty
            ir.Expr.expr_address_of as x:
                return x.ty
            ir.Expr.expr_aggregate_literal as x:
                return x.ty
            ir.Expr.expr_variant_literal as x:
                return x.ty
            ir.Expr.expr_array_literal as x:
                return x.ty
            ir.Expr.expr_zero_init as x:
                return x.ty
            _:
                return types.Type.ty_error


# =============================================================================
#  C local variable naming
# =============================================================================

public function c_local_name(name: str) -> str:
    let identifier = naming.sanitize_identifier(name)
    if c_reserved_identifier(identifier):
        var buf = string.String.create()
        buf.append(identifier)
        buf.append("_")
        return buf.as_str()
    return identifier


function c_reserved_identifier(identifier: str) -> bool:
    let words = reserved_words()
    var i: ptr_uint = 0
    while i < words.len:
        unsafe:
            if read(words.data + i) == identifier:
                return true
        i += 1
    return false


const RESERVED_WORD_COUNT: ptr_uint = 44
const RESERVED_WORDS: array[str, 44] = array[str, 44](
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
    "int", "long", "register", "restrict", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
    "void", "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool",
    "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert",
    "_Thread_local"
)


function reserved_words() -> span[str]:
    return RESERVED_WORDS.as_span()


# =============================================================================
#  Type helpers
# =============================================================================

public function is_void_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name == "void"
        _:
            return false
