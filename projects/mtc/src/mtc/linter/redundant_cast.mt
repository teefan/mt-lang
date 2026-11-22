## redundant-cast — sema-backed cast checks, mirroring the host
## (`lib/milk_tea/tooling/linter/visitors.rb:1079-1364` and the boundary call
## sites):
##
##   * cast to same type / `own` -> ptr coercion      (any `Target<-expr`)
##   * redundant parentheses around a cast expression (source-line based)
##   * implicit widening at a coercion slot           (typed let/var, `return`,
##     plain `=` assignment — the host's `flag_redundant_widening_cast`)
##   * integer-literal coercion at a slot             (`flag_redundant_literal_cast`)
##   * implicit float widening inside a binary op     (`check_redundant_binary_operand_cast`)
##   * integer-literal coercion inside a comparison   (`check_redundant_literal_operand_cast`)
##
## With no analysis (or an unresolved operand) only the literal-name fallback
## and the parentheses check run, exactly like the host.

import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types


public struct Diag:
    line: ptr_uint
    column: ptr_uint
    message: str


# =============================================================================
#  Primitive classification (the host's `Types::Primitive` flag methods)
# =============================================================================

## The names in the host's `INTEGER_TYPE_RANGES`.
function integer_type_name(name: str) -> bool:
    return (
        name == "byte" or name == "short" or name == "int" or name == "long"
        or name == "ubyte" or name == "ushort" or name == "uint" or name == "ulong"
        or name == "char"
    )


function literal_fits(target_name: str, value: long) -> bool:
    if target_name == "byte":
        return value >= -128 and value <= 127
    if target_name == "short":
        return value >= -32768 and value <= 32767
    if target_name == "int":
        return value >= -2147483648 and value <= 2147483647
    if target_name == "long":
        return true
    if target_name == "ubyte" or target_name == "char":
        return value >= 0 and value <= 255
    if target_name == "ushort":
        return value >= 0 and value <= 65535
    if target_name == "uint":
        return value >= 0 and value <= 4294967295
    if target_name == "ulong":
        return value >= 0
    return false


## Fixed-width integers, including the pointer-sized `ptr_int`/`ptr_uint`
## (the host's `Primitive#fixed_width_integer?` treats them as pointer-width
## fixed integers).
function fixed_width_integer(name: str) -> bool:
    return (
        name == "byte" or name == "short" or name == "int" or name == "long"
        or name == "ubyte" or name == "ushort" or name == "uint" or name == "ulong"
        or name == "ptr_int" or name == "ptr_uint"
    )


function float_name(name: str) -> bool:
    return name == "float" or name == "double"


function signed_integer(name: str) -> bool:
    return name == "byte" or name == "short" or name == "int" or name == "long" or name == "ptr_int"


function integer_width(name: str) -> ptr_uint:
    if name == "byte" or name == "ubyte":
        return 1
    if name == "short" or name == "ushort":
        return 2
    if name == "int" or name == "uint":
        return 4
    if name == "long" or name == "ulong" or name == "ptr_int" or name == "ptr_uint":
        return 8
    return 0


## Host `implicit_cast_allowed?`: can `inner` coerce to `target` implicitly?
function implicit_cast_allowed(inner_name: str, target_name: str) -> bool:
    if inner_name.equal(target_name):
        return true
    if not fixed_width_integer(inner_name):
        return false
    if float_name(target_name):
        return true
    if not fixed_width_integer(target_name):
        return false
    if signed_integer(inner_name) == signed_integer(target_name):
        return integer_width(target_name) >= integer_width(inner_name)
    if signed_integer(inner_name):
        return false
    return signed_integer(target_name) and integer_width(target_name) > integer_width(inner_name)


function arithmetic_or_comparison_op(op: str) -> bool:
    return (
        op.equal("+") or op.equal("-") or op.equal("*") or op.equal("/") or op.equal("%")
        or op.equal("==") or op.equal("!=") or op.equal("<") or op.equal("<=")
        or op.equal(">") or op.equal(">=")
    )


function comparison_op(op: str) -> bool:
    return (
        op.equal("==") or op.equal("!=") or op.equal("<") or op.equal("<=")
        or op.equal(">") or op.equal(">=")
    )


# =============================================================================
#  Analysis lookups
# =============================================================================

function resolve_expr_type(ctx: ref[Context], ep: ptr[ast.Expr]) -> ptr[types.Type]?:
    # Inside a generic body the host's analyzer records no expression types, so
    # its rules fall back to the literal-only paths; the self's analyzer does
    # record them, so the generic-body flag suppresses them here to match.
    if read(ctx).generic_body:
        return null
    let analysis = ctx.analysis else:
        return null
    let key = unsafe: reinterpret[ptr_uint](ep)
    return unsafe: read(analysis).resolved_expr_types.get(key)


## The resolved primitive name of an expression, or "" when it is not a
## primitive (mirrors the host's `resolve_expr_type` + `Primitive` checks).
function primitive_name_of(ctx: ref[Context], ep: ptr[ast.Expr]) -> str:
    let tp = resolve_expr_type(ctx, ep) else:
        return ""
    match unsafe: read(tp):
        types.Type.ty_primitive as p:
            return p.name
        _:
            return ""


function type_name_of(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_str:
            return "str"
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        types.Type.ty_opaque as o:
            let o_bp = unsafe: read(o.payload)
            return o_bp.name
        _:
            return ""


## Host `same_resolved_type?` (`left.equal?(right) || left.to_s == right.to_s`)
## as a structural comparison over the self-host's type model.  A qualified
## `ty_named` and a `ty_imported` naming the same module/type are the same
## nominal type (`ptr[Expr]` arrived at through a local alias vs an import) —
## the host's `to_s` renders both identically.
function same_type(left: types.Type, right: types.Type) -> bool:
    match left:
        types.Type.ty_named as named:
            let named_np = unsafe: read(named.payload)
            match right:
                types.Type.ty_imported as imported:
                    let imported_bp = unsafe: read(imported.payload)
                    if named_np.module_name.len > 0:
                        return named_np.name.equal(imported_bp.name) and named_np.module_name.equal(imported_bp.module_name)
                _:
                    pass
        types.Type.ty_imported as imported:
            let imported_bp = unsafe: read(imported.payload)
            match right:
                types.Type.ty_named as named:
                    let named_np = unsafe: read(named.payload)
                    if named_np.module_name.len > 0:
                        return named_np.name.equal(imported_bp.name) and named_np.module_name.equal(imported_bp.module_name)
                _:
                    pass
        _:
            pass
    match left:
        types.Type.ty_primitive as lp:
            match right:
                types.Type.ty_primitive as rp:
                    return lp.name.equal(rp.name)
                _:
                    return false
        types.Type.ty_str:
            match right:
                types.Type.ty_str:
                    return true
                _:
                    return false
        types.Type.ty_nullable as ln:
            match right:
                types.Type.ty_nullable as rn:
                    return same_type(unsafe: read(ln.base), unsafe: read(rn.base))
                _:
                    return false
        types.Type.ty_generic as lg:
            let lg_bp = unsafe: read(lg.payload)
            match right:
                types.Type.ty_generic as rg:
                    let rg_bp = unsafe: read(rg.payload)
                    if not lg_bp.name.equal(rg_bp.name):
                        return false
                    return same_type_span(lg_bp.args, rg_bp.args)
                _:
                    return false
        types.Type.ty_imported as li:
            let li_bp = unsafe: read(li.payload)
            match right:
                types.Type.ty_imported as ri:
                    let ri_bp = unsafe: read(ri.payload)
                    if not li_bp.name.equal(ri_bp.name) or not li_bp.module_name.equal(ri_bp.module_name):
                        return false
                    return same_type_span(li_bp.args, ri_bp.args)
                _:
                    return false
        types.Type.ty_named as lna:
            let lna_np = unsafe: read(lna.payload)
            match right:
                types.Type.ty_named as rna:
                    let rna_np = unsafe: read(rna.payload)
                    return lna_np.name.equal(rna_np.name)
                _:
                    return false
        types.Type.ty_opaque as lo:
            let lo_bp = unsafe: read(lo.payload)
            match right:
                types.Type.ty_opaque as ro:
                    let ro_bp = unsafe: read(ro.payload)
                    return lo_bp.name.equal(ro_bp.name)
                _:
                    return false
        types.Type.ty_dyn as ld:
            let ld_bp = unsafe: read(ld.payload)
            match right:
                types.Type.ty_dyn as rd:
                    let rd_bp = unsafe: read(rd.payload)
                    return ld_bp.iface.equal(rd_bp.iface)
                _:
                    return false
        _:
            return false


function same_type_span(left: span[types.Type], right: span[types.Type]) -> bool:
    if left.len != right.len:
        return false
    var i: ptr_uint = 0
    while i < left.len:
        unsafe:
            if not same_type(read(left.data + i), read(right.data + i)):
                return false
        i += 1
    return true


## Host `own_to_pointer_cast_redundant?`: `ptr[T]<-own[T]` adds nothing.
function own_to_pointer_redundant(inner: types.Type, cast: types.Type) -> bool:
    match inner:
        types.Type.ty_generic as ig:
            let ig_bp = unsafe: read(ig.payload)
            if not ig_bp.name.equal("own") or ig_bp.args.len != 1:
                return false
            match cast:
                types.Type.ty_generic as cg:
                    let cg_bp = unsafe: read(cg.payload)
                    if not cg_bp.name.equal("ptr") and not cg_bp.name.equal("const_ptr"):
                        return false
                    if cg_bp.args.len != 1:
                        return false
                    return same_type(unsafe: read(ig_bp.args.data), unsafe: read(cg_bp.args.data))
                _:
                    return false
        _:
            return false


# =============================================================================
#  Traversal
# =============================================================================

## The check context: the source's lines (for the parenthesis scan) and the
## analysis (the cast flags return early without it).  The linter owns one for
## a lint pass and calls the hooks below from its walk, so the diagnostics
## interleave with the other rules in the host's order; `diags` holds what the
## hooks produced (the caller drains it in order).
public struct Context:
    diags: vec.Vec[Diag]
    lines: vec.Vec[str]
    analysis: ptr[analyzer.Analysis]?
    ## True while the walk is inside a generic function/extending-method body.
    ## The host's analyzer does not check those bodies, so its linter has no
    ## expression types there and the sema-backed checks fall back to the
    ## literal-only paths; the self sets this to match (its analyzer does check
    ## them, which would otherwise over-report).
    generic_body: bool


public function ctx_create(source: str, analysis: ptr[analyzer.Analysis]?) -> Context:
    return Context(diags = vec.Vec[Diag].create(), lines = split_lines(source), analysis = analysis, generic_body = false)


## The linter's walk marks the generic-body state before draining a hook's
## diagnostics (its `lint_generic_depth`).
public function set_generic_body(ctx: ref[Context], generic: bool) -> void:
    read(ctx).generic_body = generic


public function ctx_release(ctx: ref[Context]) -> void:
    read(ctx).diags.release()
    read(ctx).lines.release()


## A typed local's initializer (the host's `LocalDecl` arm).
public function check_local(ctx: ref[Context], stmt_type: ptr[ast.TypeRef]?, value: ptr[ast.Expr]?) -> void:
    if stmt_type == null:
        return
    flag_widening(ctx, value)
    flag_literal(ctx, value)


## A plain `=` assignment's value (the host's `Assignment` arm).
public function check_assignment(ctx: ref[Context], value: ptr[ast.Expr]) -> void:
    flag_widening(ctx, value)
    flag_literal(ctx, value)


## A `return`'s value (the host's `ReturnStmt` arm).
public function check_return(ctx: ref[Context], value: ptr[ast.Expr]?) -> void:
    flag_widening(ctx, value)
    flag_literal(ctx, value)


## A prefix cast expression: the cast's own redundancy and the parenthesis
## check (the host's `PrefixCast` arm).
public function check_prefix_cast(ctx: ref[Context], ep: ptr[ast.Expr]) -> void:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                check_cast(ctx, ep, c.target_type, c.expression, c.line, c.column)
                check_parens(ctx, c.line, c.column, type_last_name(c.target_type))
            _:
                pass


## A binary expression's operands (the host's `BinaryOp` arm).
public function check_binary_operands(ctx: ref[Context], op: str, left: ptr[ast.Expr], right: ptr[ast.Expr]) -> void:
    check_binary_operand(ctx, op, left, right)
    check_binary_operand(ctx, op, right, left)
    check_literal_operand(ctx, op, left, right)
    check_literal_operand(ctx, op, right, left)


function split_lines(source: str) -> vec.Vec[str]:
    var lines = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len or source.byte_at(i) == 10:
            lines.push(source.slice(start, i - start))
            start = i + 1
        i += 1
    return lines


function emit_diag(ctx: ref[Context], line: ptr_uint, column: ptr_uint, reason: str, target_name: str) -> void:
    var message = string.String.create()
    message.append(reason)
    message.append(": ")
    message.append(target_name)
    message.append("<-")
    ctx.diags.push(Diag(line = line, column = column, message = message.as_str()))














# =============================================================================
#  Checks
# =============================================================================

function check_cast(ctx: ref[Context], cast_ptr: ptr[ast.Expr], target_type: ptr[ast.TypeRef], inner: ptr[ast.Expr], line: ptr_uint, column: ptr_uint) -> void:
    let target_name = type_last_name(target_type)
    if target_name.len == 0:
        return

    if ctx.analysis != null:
        let cast_ty = resolve_expr_type(ctx, cast_ptr)
        let inner_ty = resolve_expr_type(ctx, inner)
        if cast_ty != null and inner_ty != null:
            if same_type(unsafe: read(cast_ty), unsafe: read(inner_ty)):
                emit_diag(ctx, line, column, "cast to same type is redundant", target_name)
            else if own_to_pointer_redundant(unsafe: read(inner_ty), unsafe: read(cast_ty)):
                emit_diag(ctx, line, column, "implicit own->ptr coercion makes this cast redundant", target_name)
            return

    # Fallback when the inner type cannot be resolved: a value literal whose
    # type is known by name.
    let literal_name = expression_literal_type_name(inner)
    if literal_name.len > 0 and literal_name.equal(target_name):
        emit_diag(ctx, line, column, "cast to same type is redundant", target_name)


function expression_literal_type_name(ep: ptr[ast.Expr]) -> str:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return "int"
            ast.Expr.expr_string_literal as s:
                if s.is_cstring:
                    return "cstr"
                return "str"
            ast.Expr.expr_float_literal:
                return "float"
            ast.Expr.expr_bool_literal:
                return "bool"
            _:
                return ""


## `T<-(x)` when `T<-x` needs no precedence protection: the parens are
## redundant unless the inner text has a top-level operator (host
## `check_redundant_cast_parens`).
function check_parens(ctx: ref[Context], line: ptr_uint, column: ptr_uint, target_name: str) -> void:
    if line == 0:
        return
    let line_index = line - 1
    if line_index >= ctx.lines.len():
        return
    let text_ptr = ctx.lines.get(line_index) else:
        return
    let text = unsafe: read(text_ptr)
    var col: ptr_uint = 0
    if column > 0:
        col = column - 1
    let arrow = find_from(text, "<-", col) else:
        return
    let arrow_end = arrow + 2
    if arrow_end >= text.len or text.byte_at(arrow_end) != '(':
        return
    let close = match_paren(text, arrow_end) else:
        return
    let inner = text.slice(arrow_end + 1, close - (arrow_end + 1)).trim_ascii_whitespace()
    if inner.len == 0:
        return
    if inner_has_top_level_operators(inner):
        return
    emit_diag(ctx, line, column, "parentheses around cast expression are redundant", target_name)


## A widening cast directly at a coercion slot (typed local, `return`, plain
## `=`), where the slot type pins the result.
function flag_widening(ctx: ref[Context], ep: ptr[ast.Expr]?) -> void:
    if ctx.analysis == null:
        return
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_prefix_cast as c:
                let target_name = type_last_name(c.target_type)
                if target_name.len == 0:
                    return
                let inner_name = primitive_name_of(ctx, c.expression)
                if inner_name.len == 0 or inner_name.equal(target_name):
                    return
                if implicit_cast_allowed(inner_name, target_name):
                    emit_diag(ctx, c.line, c.column, "implicit widening makes this cast redundant", target_name)
            _:
                pass


## An integer-literal cast at a coercion slot whose literal fits the target.
function flag_literal(ctx: ref[Context], ep: ptr[ast.Expr]?) -> void:
    if ctx.analysis == null:
        return
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_prefix_cast as c:
                let target_name = type_last_name(c.target_type)
                if not integer_type_name(target_name):
                    return
                match read(c.expression):
                    ast.Expr.expr_integer_literal as lit:
                        if not literal_fits(target_name, lit.value):
                            return
                        let inner_name = primitive_name_of(ctx, c.expression)
                        if inner_name.len == 0 or inner_name.equal(target_name):
                            return
                        if implicit_cast_allowed(inner_name, target_name):
                            return
                        emit_diag(ctx, c.line, c.column, "integer literal coercion makes this cast redundant", target_name)
                    _:
                        pass
            _:
                pass


## `float_y + double<-i` style redundancy: an int->float cast as an operand of
## an arithmetic/comparison op whose sibling is already float.
function check_binary_operand(ctx: ref[Context], op: str, operand: ptr[ast.Expr], sibling: ptr[ast.Expr]) -> void:
    if ctx.analysis == null:
        return
    if not arithmetic_or_comparison_op(op):
        return
    if not is_prefix_cast(operand) or is_prefix_cast(sibling):
        return
    let target_name = primitive_name_of(ctx, operand)
    if target_name.len == 0 or not float_name(target_name):
        return
    let inner = cast_inner(operand) else:
        return
    let inner_name = primitive_name_of(ctx, inner)
    if not fixed_width_integer(inner_name):
        return
    let sibling_name = primitive_name_of(ctx, sibling)
    if not float_name(sibling_name):
        return
    if target_name.equal("double") and sibling_name.equal("float"):
        return
    let type_ref_name = cast_type_last_name(operand)
    if type_ref_name.len == 0:
        return
    emit_diag(ctx, cast_line(operand), cast_column(operand), "implicit float widening makes this cast redundant", type_ref_name)


## `State.idle == ubyte<-0`: a fitting integer literal cast as a comparison
## operand against an enum / float / wider integer sibling.
function check_literal_operand(ctx: ref[Context], op: str, operand: ptr[ast.Expr], sibling: ptr[ast.Expr]) -> void:
    if ctx.analysis == null:
        return
    if not comparison_op(op):
        return
    if not is_prefix_cast(operand):
        return
    let inner = cast_inner(operand) else:
        return
    let target_name = cast_type_last_name(operand)
    if not integer_type_name(target_name):
        return
    unsafe:
        match read(inner):
            ast.Expr.expr_integer_literal as lit:
                if not literal_fits(target_name, lit.value):
                    return
                let inner_name = primitive_name_of(ctx, inner)
                if inner_name.len > 0 and inner_name.equal(target_name):
                    return
                let sibling_ty = resolve_expr_type(ctx, sibling) else:
                    return
                match read(sibling_ty):
                    types.Type.ty_primitive as sp:
                        if float_name(sp.name):
                            pass
                        else if integer_type_name(sp.name):
                            if not literal_fits(sp.name, lit.value):
                                return
                        else:
                            return
                    types.Type.ty_named as n:
                        let n_np = unsafe: read(n.payload)
                        let analysis = ctx.analysis else:
                            return
                        var is_enum = unsafe: read(analysis).static_member_types.contains(n_np.name)
                        if not is_enum and n_np.module_name.len > 0:
                            var key = string.String.create()
                            key.append(n_np.module_name)
                            key.append(".")
                            key.append(n_np.name)
                            is_enum = unsafe: read(analysis).static_member_types.contains(key.as_str())
                            key.release()
                        if not is_enum:
                            return
                    types.Type.ty_imported as im:
                        let im_bp = unsafe: read(im.payload)
                        # Unlike the host's `EnumBase`, the self's imported
                        # types do not carry their declaration kind; only an
                        # imported enum has static members.
                        let analysis = ctx.analysis else:
                            return
                        var is_enum = unsafe: read(analysis).static_member_types.contains(im_bp.name)
                        if not is_enum and im_bp.module_name.len > 0:
                            var key = string.String.create()
                            key.append(im_bp.module_name)
                            key.append(".")
                            key.append(im_bp.name)
                            is_enum = unsafe: read(analysis).static_member_types.contains(key.as_str())
                            key.release()
                        if not is_enum:
                            return
                    _:
                        return
                emit_diag(ctx, cast_line(operand), cast_column(operand), "integer literal coercion makes this cast redundant", target_name)
            _:
                pass


# =============================================================================
#  Node helpers
# =============================================================================

function is_prefix_cast(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast:
                return true
            _:
                return false


function cast_inner(ep: ptr[ast.Expr]) -> ptr[ast.Expr]?:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                return c.expression
            _:
                return null


function cast_type_last_name(ep: ptr[ast.Expr]) -> str:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                return type_last_name(c.target_type)
            _:
                return ""


function cast_line(ep: ptr[ast.Expr]) -> ptr_uint:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                return c.line
            _:
                return 0


function cast_column(ep: ptr[ast.Expr]) -> ptr_uint:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                return c.column
            _:
                return 0


function type_last_name(type_ref: ptr[ast.TypeRef]) -> str:
    unsafe:
        let tr = read(type_ref)
        if tr.name.parts.len == 0:
            return ""
        return read(tr.name.parts.data + tr.name.parts.len - 1)


function find_from(text: str, needle: str, from: ptr_uint) -> Option[ptr_uint]:
    if needle.len == 0 or text.len < needle.len:
        return Option[ptr_uint].none
    var i = from
    let last = text.len - needle.len
    while i <= last:
        var matched = true
        var j: ptr_uint = 0
        while j < needle.len:
            if text.byte_at(i + j) != needle.byte_at(j):
                matched = false
                break
            j += 1
        if matched:
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function match_paren(line: str, open_pos: ptr_uint) -> Option[ptr_uint]:
    var depth: int = 0
    var i = open_pos
    while i < line.len:
        let b = line.byte_at(i)
        if b == '(':
            depth += 1
        else if b == ')':
            depth -= 1
            if depth == 0:
                return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function is_binary_op_char(b: ubyte) -> bool:
    return (
        b == '+' or b == '-' or b == '*' or b == '/' or b == '%'
        or b == '&' or b == '|' or b == '^' or b == '<' or b == '>'
        or b == '=' or b == '!' or b == '?' or b == ':'
    )


function inner_has_top_level_operators(inner: str) -> bool:
    var depth: int = 0
    var i: ptr_uint = 0
    while i < inner.len:
        let b = inner.byte_at(i)
        if b == '(' or b == '[' or b == '{':
            depth += 1
        else if b == ')' or b == ']' or b == '}':
            if depth > 0:
                depth -= 1
        else if is_binary_op_char(b):
            if depth == 0:
                return true
        i += 1
    return false
