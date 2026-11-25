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
import mtc.strings

# =============================================================================
#  String concatenation
# =============================================================================

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

public function alloc_expr(value: ir.Expr) -> own[ir.Expr]:
    var node = heap_mod.must_alloc[ir.Expr](1)
    read(node) = value
    return node


public function alloc_stmt(value: ir.Stmt) -> own[ir.Stmt]:
    var node = heap_mod.must_alloc[ir.Stmt](1)
    read(node) = value
    return node


public function alloc_reinterpret_expr(
    target_type: types.Type,
    source_type: types.Type,
    expression: ptr[ir.Expr],
    ty: types.Type
) -> ptr[ir.ReinterpretExpr]:
    var node = heap_mod.must_alloc[ir.ReinterpretExpr](1)
    read(node) = ir.ReinterpretExpr(
        target_type = target_type,
        source_type = source_type,
        expression = expression,
        ty = ty,
    )
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
            ir.Expr.expr_unsigned_integer_literal as x:
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
    # The host's `c_local_name` (`utils.rb:1146`): a source local name is already
    # a valid C identifier, so it is returned verbatim; only a C keyword gets a
    # trailing underscore.  Sanitizing here would strip a meaningful trailing
    # underscore (`event_`) or collapse a name's interior runs.
    if name.len == 0:
        return "value"
    if c_reserved_identifier(name):
        return strings.join_two(name, "_")
    return name


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
