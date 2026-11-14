## Compile-time evaluation — comptime introspection, const folding, and the
## compile-time statement interpreter.  Extracted from lowering/lowering.mt,
## which keeps the lowering context and the IR primitives these helpers call.

import std.vec as vec
import std.map as map_mod
import std.str
import std.string as string

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types

import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.lowering as lowering


## Recover the declared length of a const/var array referenced by `receiver` by
## resolving its declaration's type annotation.  Returns 0 when the receiver is
## not a module-level const/var array identifier.
public function const_array_length(ctx: ref[lowering.LoweringContext], receiver: ptr[ast.Expr]) -> long:
    var name: str
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                name = id.name
            _:
                return 0
    var di: ptr_uint = 0
    while di < ctx.analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(ctx.analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_const as c:
                if c.name == name:
                    return lowering.array_length_of(lowering.resolve_type_ref(ctx, c.const_type))
            _:
                pass
        di += 1
    return 0


## Compile-time integer evaluation for enum/flags member values and array-length
## constants (literals, other integer constants by name, plus the
## arithmetic/bitwise/shift operators).  A bare `expr_identifier` resolves
## through `ctx.analysis.const_values`, so a length like `WIDTH * HEIGHT` (each a
## module-level `const int`) folds to its product instead of 0.
public function const_eval_int(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> long:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return long<-lit.value
            ast.Expr.expr_char_literal as ch:
                return long<-ch.value
            ast.Expr.expr_identifier as id:
                let const_ptr = ctx.analysis.const_values.get(id.name)
                if const_ptr != null:
                    return const_eval_int(ctx, read(const_ptr))
                return 0
            ast.Expr.expr_unary_op as un:
                let v = const_eval_int(ctx, un.operand)
                if un.operator == "-":
                    return -v
                if un.operator == "~":
                    return ~v
                return v
            ast.Expr.expr_binary_op as bin:
                let l = const_eval_int(ctx, bin.left)
                let r = const_eval_int(ctx, bin.right)
                if bin.operator == "+":
                    return l + r
                if bin.operator == "-":
                    return l - r
                if bin.operator == "*":
                    return l * r
                if bin.operator == "/":
                    return l / r
                if bin.operator == "%":
                    return l % r
                if bin.operator == "<<":
                    return l << r
                if bin.operator == ">>":
                    return l >> r
                if bin.operator == "|":
                    return l | r
                if bin.operator == "&":
                    return l & r
                if bin.operator == "^":
                    return l ^ r
                return 0
            ast.Expr.expr_sizeof as sz:
                let target = lowering.resolve_type_ref(ctx, sz.target_type)
                match lowering.layout_size(ctx, target):
                    Option.some as v:
                        return v.value
                    Option.none:
                        return 0
            ast.Expr.expr_alignof as al:
                let target = lowering.resolve_type_ref(ctx, al.target_type)
                match lowering.layout_alignment(ctx, target):
                    Option.some as v:
                        return v.value
                    Option.none:
                        return 0
            ast.Expr.expr_offsetof as off:
                let target = lowering.resolve_type_ref(ctx, off.target_type)
                match lowering.layout_offset_of(ctx, target, off.field):
                    Option.some as v:
                        return v.value
                    Option.none:
                        return 0
            _:
                return 0


## A compile-time constant value: integer, boolean, string, or type.
## Extract the compile-time iterable for known comptime builtins (fields_of,
## members_of) as a span of struct-field or enum-member info pairs.
## Returns none for unrecognised expressions.

public function comptime_iterable_elements(ctx: ref[lowering.LoweringContext], iterable: ptr[ast.Expr]) -> Option[span[comptime_types.ComptimeElement]]:
    unsafe:
        match read(iterable):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name == "fields_of" and call.args.len == 1:
                            return comptime_fields_of(ctx, call.args.data + 0)
                        if id.name == "members_of" and call.args.len == 1:
                            return comptime_members_of(ctx, call.args.data + 0)
                        if id.name == "attributes_of" and call.args.len >= 1:
                            return comptime_attributes_of(ctx, call.args)
                    _:
                        pass
            _:
                pass
    return Option[span[comptime_types.ComptimeElement]].none


function comptime_fields_of(ctx: ref[lowering.LoweringContext], args_data: ptr[ast.Argument]) -> Option[span[comptime_types.ComptimeElement]]:
    let type_name: str = comptime_resolve_type_arg_name(ctx, args_data)
    if type_name.len == 0:
        return Option[span[comptime_types.ComptimeElement]].none
    let entries = comptime_lookup_struct_fields(ctx, type_name) else:
        return Option[span[comptime_types.ComptimeElement]].none
    var elements = vec.Vec[comptime_types.ComptimeElement].create()
    var ei: ptr_uint = 0
    while ei < entries.len:
        var entry: analyzer.FieldEntry
        unsafe:
            entry = read(entries.data + ei)
        elements.push(comptime_types.ComptimeElement.ce_struct_field(name = entry.name, field_type = lowering.qualify_type(ctx, entry.ty)))
        ei += 1
    return Option[span[comptime_types.ComptimeElement]].some(value = elements.as_span())


## Look up a struct's field list by name, searching the current module first and
## then every program analysis.  Cross-module search lets a generic reflective
## helper defined in one module (e.g. `std.fmt.format_value[T]`) reflect over a
## struct type defined in another module.
public function comptime_lookup_struct_fields(ctx: ref[lowering.LoweringContext], type_name: str) -> Option[span[analyzer.FieldEntry]]:
    let local = ctx.analysis.structs.get(type_name)
    if local != null:
        return Option[span[analyzer.FieldEntry]].some(value = unsafe: read(local))
    var i: ptr_uint = 0
    while i < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + i)
        let p = a.structs.get(type_name)
        if p != null:
            return Option[span[analyzer.FieldEntry]].some(value = unsafe: read(p))
        i += 1
    return Option[span[analyzer.FieldEntry]].none


function comptime_members_of(ctx: ref[lowering.LoweringContext], args_data: ptr[ast.Argument]) -> Option[span[comptime_types.ComptimeElement]]:
    let type_name: str = comptime_resolve_type_arg_name(ctx, args_data)
    if type_name.len == 0:
        return Option[span[comptime_types.ComptimeElement]].none
    let names = comptime_lookup_member_names(ctx, type_name) else:
        return Option[span[comptime_types.ComptimeElement]].none
    var elements = vec.Vec[comptime_types.ComptimeElement].create()
    var ni: ptr_uint = 0
    while ni < names.len:
        var member_name: str
        unsafe:
            member_name = read(names.data + ni)
        let mv = comptime_enum_member_value(ctx, type_name, member_name)
        elements.push(comptime_types.ComptimeElement.ce_enum_member(name = member_name, member_value = mv))
        ni += 1
    return Option[span[comptime_types.ComptimeElement]].some(value = elements.as_span())


## Look up an enum/variant's member names by type name, searching the current
## module first and then every program analysis, so `members_of(alias.Enum)`
## reflects an enum declared in another module.
function comptime_lookup_member_names(ctx: ref[lowering.LoweringContext], type_name: str) -> Option[span[str]]:
    let local = ctx.analysis.match_case_names.get(type_name)
    if local != null:
        return Option[span[str]].some(value = unsafe: read(local))
    var i: ptr_uint = 0
    while i < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + i)
        let p = a.match_case_names.get(type_name)
        if p != null:
            return Option[span[str]].some(value = unsafe: read(p))
        i += 1
    return Option[span[str]].none


## Look up the integer value of an enum member by scanning the source file of the
## analysis that declares the enum (searched program-wide).
function comptime_enum_member_value(ctx: ref[lowering.LoweringContext], type_name: str, member_name: str) -> long:
    var fi: ptr_uint = 0
    while fi <= ctx.program_analyses.len:
        var file: ast.SourceFile
        unsafe:
            if fi == 0:
                file = ctx.analysis.source_file
            else:
                file = read(ctx.program_analyses.data + (fi - 1)).source_file
        let found = lowering.enum_member_value_in_file(ctx, file, type_name, member_name)
        match found:
            Option.some as v:
                return v.value
            Option.none:
                pass
        fi += 1
    return 0


function comptime_attributes_of(ctx: ref[lowering.LoweringContext], args: span[ast.Argument]) -> Option[span[comptime_types.ComptimeElement]]:
    if args.len == 0:
        return Option[span[comptime_types.ComptimeElement]].none
    # `attributes_of(field_of(Type, field)[, name])` reflects the field's
    # attributes; `attributes_of(Type[, name])` the declaration's.
    unsafe:
        let first = read(args.data + 0)
        match read(first.arg_value):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as cid:
                        if cid.name == "field_of" and call.args.len == 2:
                            let type_name = comptime_type_arg_name(call.args.data + 0)
                            let field_name = comptime_arg_name(call.args.data + 1)
                            return comptime_elements_for_attribute_apps(comptime_field_attr_apps(ctx, type_name, field_name), comptime_attr_filter(args))
                    _:
                        pass
            _:
                pass
    var type_name = ""
    unsafe:
        type_name = comptime_resolve_type_arg_name(ctx, args.data + 0)
    return comptime_elements_for_attribute_apps(comptime_attr_apps(ctx, type_name), comptime_attr_filter(args))


## The attribute-name filter of `attributes_of(target, name)`, or "" when the
## call has no filter argument.
function comptime_attr_filter(args: span[ast.Argument]) -> str:
    if args.len < 2:
        return ""
    unsafe:
        return comptime_arg_name(args.data + 1)


## Build one element per attribute application matching `filter` (all of them
## when the filter is empty).
function comptime_elements_for_attribute_apps(apps: span[ast.AttributeApplication], filter: str) -> Option[span[comptime_types.ComptimeElement]]:
    var elements = vec.Vec[comptime_types.ComptimeElement].create()
    var ai: ptr_uint = 0
    while ai < apps.len:
        var app: ast.AttributeApplication
        unsafe:
            app = read(apps.data + ai)
        if filter.len == 0 or lowering.attribute_application_name_is(app, filter):
            elements.push(comptime_types.ComptimeElement.ce_attribute)
        ai += 1
    return Option[span[comptime_types.ComptimeElement]].some(value = elements.as_span())


## The attribute applications recorded for the declaration `type_name`,
## searching the current module first and then every program analysis.
function comptime_attr_apps(ctx: ref[lowering.LoweringContext], type_name: str) -> span[ast.AttributeApplication]:
    if type_name.len == 0:
        return span[ast.AttributeApplication]()
    let local = ctx.analysis.attribute_applications.get(type_name)
    if local != null:
        return unsafe: read(local)
    var i: ptr_uint = 0
    while i < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + i)
        let p = a.attribute_applications.get(type_name)
        if p != null:
            return unsafe: read(p)
        i += 1
    return span[ast.AttributeApplication]()


## The attribute applications recorded for `Type.field`, searching the current
## module first and then every program analysis.
function comptime_field_attr_apps(ctx: ref[lowering.LoweringContext], type_name: str, field_name: str) -> span[ast.AttributeApplication]:
    if type_name.len == 0 or field_name.len == 0:
        return span[ast.AttributeApplication]()
    var key_buf = string.String.create()
    key_buf.append(type_name)
    key_buf.append(".")
    key_buf.append(field_name)
    let key = key_buf.as_str()
    let local = ctx.analysis.field_attribute_applications.get(key)
    if local != null:
        return unsafe: read(local)
    var i: ptr_uint = 0
    while i < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + i)
        let p = a.field_attribute_applications.get(key)
        if p != null:
            return unsafe: read(p)
        i += 1
    return span[ast.AttributeApplication]()


## Resolve a bare identifier to a compile-time type value: an in-scope generic
## type parameter (via the active substitution) or a primitive/`str` type name.
## Returns none for ordinary value identifiers.
public function comptime_identifier_type(ctx: ref[lowering.LoweringContext], name: str) -> Option[types.Type]:
    let subst = ctx.type_substitution.get(name)
    if subst != null:
        return Option[types.Type].some(value = unsafe: read(subst))
    if name == "str":
        return Option[types.Type].some(value = types.Type.ty_str)
    if types.is_numeric_name(name) or types.is_integer_name(name) or name == "float" or name == "double" or name == "bool" or name == "char" or name == "void" or name == "cstr":
        return Option[types.Type].some(value = types.primitive(name))
    return Option[types.Type].none


public function comptime_expr_to_type(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                if types.is_numeric_name(id.name) or types.is_integer_name(id.name) or id.name == "float" or id.name == "double":
                    return types.primitive(id.name)
            _:
                pass
    return types.Type.ty_error


function comptime_element_type(ctx: ref[lowering.LoweringContext], elem: comptime_types.ComptimeElement) -> types.Type:
    match elem:
        comptime_types.ComptimeElement.ce_struct_field:
            return types.Type.ty_error  # field_handle — opaque
        comptime_types.ComptimeElement.ce_enum_member:
            return types.Type.ty_error  # member_handle — opaque
        comptime_types.ComptimeElement.ce_attribute:
            return types.Type.ty_error  # attribute_handle — opaque


## Extract the type name from a comptime argument like `Particle`, `Labeled`, or a
## module-qualified `types.EntityKind` (the analyzer keys its type tables by the
## bare name, so the qualifier is dropped).
function comptime_type_arg_name(arg_ptr: ptr[ast.Argument]) -> str:
    unsafe:
        let arg = read(arg_ptr)
        match read(arg.arg_value):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as ma:
                return ma.member_name
            _:
                pass
    return ""


## Like `comptime_type_arg_name`, but resolves an in-scope generic type
## parameter (e.g. `fields_of(T)` inside `count_fields[T]()`) through the active
## substitution to the concrete struct/enum name.  Without this, `T` would be
## looked up literally and reflection over a type parameter would find nothing.
function comptime_resolve_type_arg_name(ctx: ref[lowering.LoweringContext], arg_ptr: ptr[ast.Argument]) -> str:
    let raw = comptime_type_arg_name(arg_ptr)
    if raw.len == 0:
        return raw
    let subst = ctx.type_substitution.get(raw)
    if subst != null:
        return lowering.type_simple_name(unsafe: read(subst))
    return raw


## Extract a string argument value from a comptime argument.
public function comptime_arg_name(arg_ptr: ptr[ast.Argument]) -> str:
    unsafe:
        let arg = read(arg_ptr)
        match read(arg.arg_value):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_string_literal as s:
                return s.value
            _:
                pass
    return ""


## Compare two compile-time values for equality.  Integer values are compared
## with each other; booleans with booleans; strings with strings; types with types.
public function const_values_equal(l: comptime_types.ConstValue, r: comptime_types.ConstValue) -> bool:
    match l:
        comptime_types.ConstValue.cv_int as li:
            match r:
                comptime_types.ConstValue.cv_int as ri:
                    return li.value == ri.value
                _:
                    return false
        comptime_types.ConstValue.cv_bool as lb:
            match r:
                comptime_types.ConstValue.cv_bool as rb:
                    return lb.value == rb.value
                _:
                    return false
        comptime_types.ConstValue.cv_str as ls:
            match r:
                comptime_types.ConstValue.cv_str as rs:
                    return ls.value == rs.value
                _:
                    return false
        comptime_types.ConstValue.cv_type as lt:
            match r:
                comptime_types.ConstValue.cv_type as rt:
                    return lowering.types_are_equal(lt.ty, rt.ty)
                _:
                    return false


## Integer width used when folding a prefix cast: the fixed-width primitives
## plus the pointer-sized integers (host `POINTER_INTEGER_WIDTH`).
public function const_integer_width(name: str) -> int:
    if name == "ptr_int" or name == "ptr_uint":
        return 64
    return types.integer_width(name)


## True when a folded constant value can be represented by
## `lower_compile_time_literal` for `ty` — the host returns nil (falling back to
## the AST initializer) when an integer stands for a non-integer primitive such
## as `char`, or a value's shape does not fit.  Unknown shapes are accepted so
## the folding path is only abandoned where the host would abandon it.
public function const_value_ir_representable(ctx: ref[lowering.LoweringContext], v: ir.Expr, ty: types.Type) -> bool:
    match ty:
        types.Type.ty_primitive as p:
            match v:
                ir.Expr.expr_boolean_literal:
                    return p.name == "bool"
                ir.Expr.expr_integer_literal:
                    return types.is_integer_type(ty) or types.is_float_type(ty)
                ir.Expr.expr_unsigned_integer_literal:
                    return types.is_integer_type(ty) or types.is_float_type(ty)
                ir.Expr.expr_float_literal:
                    return types.is_float_type(ty)
                ir.Expr.expr_string_literal:
                    return p.name == "cstr"
                _:
                    return false
        types.Type.ty_str:
            match v:
                ir.Expr.expr_string_literal:
                    return true
                _:
                    return false
        types.Type.ty_generic as g:
            if g.name == "array" and g.args.len == 2:
                let element_ty = unsafe: read(g.args.data + 0)
                match v:
                    ir.Expr.expr_array_literal as al:
                        var i: ptr_uint = 0
                        while i < al.elements.len:
                            if not const_value_ir_representable(ctx, unsafe: read(al.elements.data + i), element_ty):
                                return false
                            i += 1
                        return true
                    _:
                        return false
            return true
        types.Type.ty_named:
            pass
        types.Type.ty_imported:
            pass
        _:
            return true
    match v:
        ir.Expr.expr_aggregate_literal as ag:
            var i: ptr_uint = 0
            while i < ag.fields.len:
                let field = unsafe: read(ag.fields.data + i)
                match lowering.concrete_field_type(ctx, ty, field.name):
                    Option.some as ft:
                        if not const_value_ir_representable(ctx, unsafe: read(field.value), ft.value):
                            return false
                    Option.none:
                        pass
                i += 1
            return true
        _:
            return true


## The host's `lower_const_value_literal` path for a constant whose value is an
## expression list or a call/specialization: when the declared type is a tuple
## the folded aggregate is emitted as an `IR::ArrayLiteral` whose element
## literals are all typed `int` — the host's fallback element type, since its
## `Types::Tuple` has no `arguments` to pick an element type from.
public function const_tuple_array_literal(value: ir.Expr, ty: types.Type) -> Option[ir.Expr]:
    match ty:
        types.Type.ty_tuple:
            pass
        _:
            return Option[ir.Expr].none
    match value:
        ir.Expr.expr_aggregate_literal as ag:
            var elements = vec.Vec[ir.Expr].create()
            var i: ptr_uint = 0
            while i < ag.fields.len:
                let field = unsafe: read(ag.fields.data + i)
                match lowering.retype_int_element_literal(unsafe: read(field.value)):
                    Option.some as lit:
                        elements.push(lit.value)
                    Option.none:
                        return Option[ir.Expr].none
                i += 1
            return Option[ir.Expr].some(value = ir.Expr.expr_array_literal(ty = ty, elements = elements.as_span()))
        _:
            return Option[ir.Expr].none


## The declared type of a module-level constant, used to give expression-list
## initializers their declared array type when folding a reference to it.
public function const_decl_type(ctx: ref[lowering.LoweringContext], name: str) -> Option[types.Type]:
    let decls = ctx.analysis.source_file.declarations
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_const as c:
                    if c.name == name:
                        return Option[types.Type].some(value = lowering.resolve_type_ref(ctx, c.const_type))
                _:
                    pass
        i += 1
    return Option[types.Type].none


public function const_fold_binary_ir(ctx: ref[lowering.LoweringContext], op: str, l: ptr[ir.Expr], r: ptr[ir.Expr]) -> Option[ptr[ir.Expr]]:
    let int_ty = types.primitive("int")
    let float_ty = types.primitive("float")
    unsafe:
        match read(l):
            ir.Expr.expr_integer_literal as li:
                match read(r):
                    ir.Expr.expr_integer_literal as ri:
                        let result = lowering.apply_int_op(op, li.value, ri.value)
                        if lowering.is_comparison_operator(op):
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = result != 0, ty = ctx.bool_ty)))
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = result, ty = int_ty)))
                    ir.Expr.expr_float_literal as rf:
                        return const_fold_float_ir(ctx, op, double<-li.value, rf.value)
                    _:
                        return Option[ptr[ir.Expr]].none
            ir.Expr.expr_float_literal as lf:
                match read(r):
                    ir.Expr.expr_float_literal as rf:
                        return const_fold_float_ir(ctx, op, lf.value, rf.value)
                    ir.Expr.expr_integer_literal as ri:
                        return const_fold_float_ir(ctx, op, lf.value, double<-ri.value)
                    _:
                        return Option[ptr[ir.Expr]].none
            ir.Expr.expr_string_literal as ls:
                match read(r):
                    ir.Expr.expr_string_literal as rs:
                        if op == "+":
                            var buf = string.String.create()
                            buf.append(ls.value)
                            buf.append(rs.value)
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_string_literal(value = buf.as_str(), ty = types.Type.ty_str, cstring = false)))
                        if op == "==":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = ls.value == rs.value, ty = ctx.bool_ty)))
                        if op == "!=":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = ls.value != rs.value, ty = ctx.bool_ty)))
                    _:
                        return Option[ptr[ir.Expr]].none
            ir.Expr.expr_boolean_literal as lb:
                match read(r):
                    ir.Expr.expr_boolean_literal as rb:
                        if op == "and":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = lb.value and rb.value, ty = ctx.bool_ty)))
                        if op == "or":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = lb.value or rb.value, ty = ctx.bool_ty)))
                        if op == "==":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = lb.value == rb.value, ty = ctx.bool_ty)))
                        if op == "!=":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = lb.value != rb.value, ty = ctx.bool_ty)))
                    _:
                        return Option[ptr[ir.Expr]].none
            _:
                return Option[ptr[ir.Expr]].none
    return Option[ptr[ir.Expr]].none


function const_fold_float_ir(ctx: ref[lowering.LoweringContext], op: str, l: double, r: double) -> Option[ptr[ir.Expr]]:
    var result: double = 0.0
    if op == "+":
        result = l + r
    else if op == "-":
        result = l - r
    else if op == "*":
        result = l * r
    else if op == "/":
        result = l / r
    else if op == "==":
        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = l == r, ty = ctx.bool_ty)))
    else if op == "!=":
        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = l != r, ty = ctx.bool_ty)))
    else if op == "<":
        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = l < r, ty = ctx.bool_ty)))
    else if op == "<=":
        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = l <= r, ty = ctx.bool_ty)))
    else if op == ">":
        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = l > r, ty = ctx.bool_ty)))
    else if op == ">=":
        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = l >= r, ty = ctx.bool_ty)))
    else:
        return Option[ptr[ir.Expr]].none
    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_float_literal(value = result, ty = types.primitive("float"))))


public function const_fold_unary_ir(ctx: ref[lowering.LoweringContext], op: str, operand: ptr[ir.Expr]) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(operand):
            ir.Expr.expr_integer_literal as li:
                if op == "-":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = -li.value, ty = li.ty)))
                if op == "~":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = ~li.value, ty = li.ty)))
                return Option[ptr[ir.Expr]].none
            ir.Expr.expr_float_literal as lf:
                if op == "-":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_float_literal(value = -lf.value, ty = lf.ty)))
                return Option[ptr[ir.Expr]].none
            ir.Expr.expr_boolean_literal as lb:
                if op == "not":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = not lb.value, ty = ctx.bool_ty)))
                return Option[ptr[ir.Expr]].none
            _:
                return Option[ptr[ir.Expr]].none
    return Option[ptr[ir.Expr]].none


## The struct name of a compile-time receiver value (its IR type's simple name).
public function const_receiver_struct_name(value: ptr[ir.Expr]) -> Option[str]:
    match lowering.ir_expr_type(value):
        types.Type.ty_named as n:
            return Option[str].some(value = n.name)
        types.Type.ty_imported as im:
            return Option[str].some(value = im.name)
        _:
            return Option[str].none
    return Option[str].none


## The name of argument `index` of a call expression `callee_name(...)`, or "".
## The argument's value must be an identifier or string literal.
public function comptime_inner_arg_name(ep: ptr[ast.Expr], callee_name: str, index: ptr_uint) -> str:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as ac:
                match read(ac.callee):
                    ast.Expr.expr_identifier as acid:
                        if acid.name == callee_name and ac.args.len > index:
                            let val = read(ac.args.data + index).arg_value
                            match read(val):
                                ast.Expr.expr_identifier as v:
                                    return v.name
                                ast.Expr.expr_string_literal as s:
                                    return s.value
                                _:
                                    pass
                    _:
                        pass
            _:
                pass
    return ""


## The expression of argument `index` of a call `callee_name(...)`, or null.
public function comptime_inner_arg_expr(ep: ptr[ast.Expr], callee_name: str, index: ptr_uint) -> ptr[ast.Expr]?:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as ac:
                match read(ac.callee):
                    ast.Expr.expr_identifier as acid:
                        if acid.name == callee_name and ac.args.len > index:
                            return read(ac.args.data + index).arg_value
                    _:
                        pass
            _:
                pass
    return null


## Resolve the struct a constant aggregate constructor names, following the same
## alias routing the runtime construction path uses
## (`lower_aggregate_literal_impl`): `rl.Color(r = 1)` with
## `type Color = c.Color` in std.raylib constructs std.c.raylib's struct Color,
## so the folded literal carries that type and its field types come from it.
public function const_aggregate_target_type(ctx: ref[lowering.LoweringContext], owner_module: str, name: str) -> Option[types.Type]:
    match lowering.find_imported_analysis(ctx, owner_module):
        Option.some as owner:
            if owner.value.structs.contains(name):
                if owner_module == ctx.module_name:
                    return Option[types.Type].some(value = types.Type.ty_named(linkage_name = Option[str].none, module_name = ctx.module_name, name = name))
                return Option[types.Type].some(value = types.Type.ty_imported(module_name = owner_module, name = name, args = span[types.Type]()))
            let alias_ptr = owner.value.type_alias_types.get(name)
            if alias_ptr != null:
                var base = unsafe: read(alias_ptr)
                if types.is_nullable_type(base):
                    base = types.unwrap_nullable(base)
                match const_struct_alias_target(ctx, base):
                    Option.some as target:
                        return Option[types.Type].some(value = target.value)
                    Option.none:
                        pass
        Option.none:
            pass
    return Option[types.Type].none


## The struct a type alias re-exports (`type Color = c.Color` names std.c.raylib's
## struct Color).  Only a struct target is an aggregate constructor; an alias of
## an enum/flags/opaque is not folded.
function const_struct_alias_target(ctx: ref[lowering.LoweringContext], t: types.Type) -> Option[types.Type]:
    match t:
        types.Type.ty_named as nm:
            if nm.module_name.len == 0 or nm.module_name == ctx.module_name:
                if ctx.analysis.structs.contains(nm.name):
                    return Option[types.Type].some(value = t)
                return Option[types.Type].none
            match lowering.find_imported_analysis(ctx, nm.module_name):
                Option.some as owner:
                    if owner.value.structs.contains(nm.name):
                        return Option[types.Type].some(value = t)
                Option.none:
                    pass
            return Option[types.Type].none
        types.Type.ty_imported as im:
            match lowering.find_imported_analysis(ctx, im.module_name):
                Option.some as owner:
                    if owner.value.structs.contains(im.name):
                        return Option[types.Type].some(value = t)
                Option.none:
                    pass
            return Option[types.Type].none
        _:
            return Option[types.Type].none
    return Option[types.Type].none


## Re-type a folded constant value by the type of the aggregate field it
## initializes, mirroring the host's `lower_compile_time_literal`
## (`lowering/utils.rb:361-395`): the interpreted value carries no type of its
## own, so the field decides the literal's kind — `hex_digit(c) * 16 +
## hex_digit(c)` folds to a `ubyte` literal in a `ubyte` field, and an integer
## value in a `float` field becomes a float literal.
public function const_value_to_field_type(value: ptr[ir.Expr], field_ty: types.Type) -> ptr[ir.Expr]:
    var target = field_ty
    if types.is_nullable_type(target):
        target = types.unwrap_nullable(target)
    # The host recurses into an array target (`lower_compile_time_literal`'s
    # Array case): each element takes the *element* type, so a zeroed
    # `array[ubyte, 4](0, 0, 0, 0)` field keeps ubyte elements.
    match target:
        types.Type.ty_generic as ag:
            if ag.name == "array" and ag.args.len == 2:
                let element_ty = unsafe: read(ag.args.data + 0)
                unsafe:
                    match read(value):
                        ir.Expr.expr_array_literal as al:
                            var elements = vec.Vec[ir.Expr].create()
                            var ei: ptr_uint = 0
                            while ei < al.elements.len:
                                let retyped = const_value_to_field_type(lowering.alloc_expr(read(al.elements.data + ei)), element_ty)
                                elements.push(unsafe: read(retyped))
                                ei += 1
                            return lowering.alloc_expr(ir.Expr.expr_array_literal(ty = target, elements = elements.as_span()))
                        _:
                            pass
        _:
            pass
    var target_is_str = false
    var target_is_cstr = false
    match target:
        types.Type.ty_str:
            target_is_str = true
        types.Type.ty_primitive as p:
            if p.name == "str" or p.name == "cstr":
                target_is_str = true
            target_is_cstr = p.name == "cstr"
        _:
            pass
    unsafe:
        match read(value):
            ir.Expr.expr_integer_literal as lit:
                if types.is_integer_type(target):
                    return lowering.alloc_expr(ir.Expr.expr_integer_literal(value = lit.value, ty = target))
                if types.is_float_type(target):
                    return lowering.alloc_expr(ir.Expr.expr_float_literal(value = double<-lit.value, ty = target))
            ir.Expr.expr_float_literal as fl:
                if types.is_float_type(target):
                    return lowering.alloc_expr(ir.Expr.expr_float_literal(value = fl.value, ty = target))
            ir.Expr.expr_boolean_literal as b:
                if types.is_bool(target):
                    return lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = b.value, ty = target))
            ir.Expr.expr_string_literal as s:
                if target_is_str:
                    return lowering.alloc_expr(ir.Expr.expr_string_literal(value = s.value, ty = target, cstring = target_is_cstr))
            _:
                pass
    return value


## Control-flow outcome of executing compile-time statements.
public function const_flow_body(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], body: ptr[ast.Stmt]?) -> comptime_types.ConstFlow:
    let b = body else:
        return comptime_types.ConstFlow.cf_fallthrough
    return const_flow_stmt(ctx, env, b)


function const_flow_stmts(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], stmts: span[ast.Stmt]) -> comptime_types.ConstFlow:
    var i: ptr_uint = 0
    while i < stmts.len:
        match const_flow_stmt(ctx, env, unsafe: ptr[ast.Stmt]<-(stmts.data + i)):
            comptime_types.ConstFlow.cf_fallthrough:
                pass
            comptime_types.ConstFlow.cf_stuck:
                return comptime_types.ConstFlow.cf_stuck
            comptime_types.ConstFlow.cf_break:
                return comptime_types.ConstFlow.cf_break
            comptime_types.ConstFlow.cf_continue:
                return comptime_types.ConstFlow.cf_continue
            comptime_types.ConstFlow.cf_value as v:
                return comptime_types.ConstFlow.cf_value(value = v.value)
        i += 1
    return comptime_types.ConstFlow.cf_fallthrough


function const_flow_stmt(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], sp: ptr[ast.Stmt]) -> comptime_types.ConstFlow:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_block as blk:
                return const_flow_stmts(ctx, env, blk.statements)
            ast.Stmt.stmt_ret as r:
                let val_ptr = r.value else:
                    return comptime_types.ConstFlow.cf_value(value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ctx.void_ty)))
                match lowering.try_const_value_ir(ctx, val_ptr, env):
                    Option.some as v:
                        return comptime_types.ConstFlow.cf_value(value = v.value)
                    Option.none:
                        return comptime_types.ConstFlow.cf_stuck
            ast.Stmt.stmt_break:
                return comptime_types.ConstFlow.cf_break
            ast.Stmt.stmt_continue:
                return comptime_types.ConstFlow.cf_continue
            ast.Stmt.stmt_pass:
                return comptime_types.ConstFlow.cf_fallthrough
            ast.Stmt.stmt_local as loc:
                let init_ptr = loc.value else:
                    return comptime_types.ConstFlow.cf_fallthrough
                match lowering.try_const_value_ir(ctx, init_ptr, env):
                    Option.some as lv:
                        return const_bind_local(ctx, env, loc.name, loc.destructure_bindings, loc.else_binding, loc.else_body, lv.value)
                    Option.none:
                        return comptime_types.ConstFlow.cf_stuck
            ast.Stmt.stmt_assignment as asg:
                match lowering.try_const_value_ir(ctx, asg.value, env):
                    Option.some as rv:
                        match const_assign_target(ctx, env, asg.target, asg.operator, rv.value):
                            Option.some:
                                return comptime_types.ConstFlow.cf_fallthrough
                            Option.none:
                                return comptime_types.ConstFlow.cf_stuck
                    Option.none:
                        return comptime_types.ConstFlow.cf_stuck
            ast.Stmt.stmt_expression as ex:
                match lowering.try_const_value_ir(ctx, ex.expression, env):
                    Option.some:
                        return comptime_types.ConstFlow.cf_fallthrough
                    Option.none:
                        return comptime_types.ConstFlow.cf_stuck
            ast.Stmt.stmt_if as ifs:
                return const_flow_if(ctx, env, ifs.branches, ifs.else_body)
            ast.Stmt.stmt_while as ws:
                return const_flow_while(ctx, env, ws.condition, ws.body)
            ast.Stmt.stmt_for as fs:
                return const_flow_for(ctx, env, fs.bindings, fs.iterables, fs.body)
            ast.Stmt.stmt_match as ms:
                return const_flow_match_stmt(ctx, env, ms.scrutinee, ms.arms)
            ast.Stmt.stmt_unsafe as us:
                return const_flow_body(ctx, env, us.body)
            _:
                return comptime_types.ConstFlow.cf_stuck
    return comptime_types.ConstFlow.cf_stuck


function const_bind_local(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], name: str, destructure_bindings: Option[span[str]], else_binding: Option[str], else_body: ptr[ast.Stmt]?, value: ptr[ir.Expr]) -> comptime_types.ConstFlow:
    match destructure_bindings:
        Option.some as names:
            match const_bind_destructure(env, names.value, value):
                Option.some:
                    return comptime_types.ConstFlow.cf_fallthrough
                Option.none:
                    return comptime_types.ConstFlow.cf_stuck
        Option.none:
            pass
    # `let x = present else: ...` unwraps the payload; a `none`/`failure` arm
    # (or a plain nullable value) takes the else branch, binding `else as e`
    # to the failure error when present.
    if else_body != null:
        var failed = false
        var payload: ptr[ir.Expr]? = null
        unsafe:
            match read(value):
                ir.Expr.expr_variant_literal as vl:
                    if vl.arm_name == "none" or vl.arm_name == "failure":
                        failed = true
                        match else_binding:
                            Option.some as eb:
                                match const_field_value(vl.fields, "error"):
                                    Option.some as ef:
                                        env.set(eb.value, ef.value)
                                    Option.none:
                                        pass
                            Option.none:
                                pass
                    else:
                        match const_field_value(vl.fields, "value"):
                            Option.some as vf:
                                payload = vf.value
                            Option.none:
                                pass
                _:
                    payload = value
        if failed:
            return const_flow_body(ctx, env, else_body)
        let pv = payload else:
            return comptime_types.ConstFlow.cf_stuck
        if name != "_":
            env.set(name, pv)
        return comptime_types.ConstFlow.cf_fallthrough
    if name != "_":
        env.set(name, value)
    return comptime_types.ConstFlow.cf_fallthrough


## Bind a destructuring pattern (`let (a, b) = ...`, `let Pt(x, y) = ...`) by
## positional order of the value's fields/elements.
function const_bind_destructure(env: ref[map_mod.Map[str, ptr[ir.Expr]]], names: span[str], value: ptr[ir.Expr]) -> Option[bool]:
    unsafe:
        match read(value):
            ir.Expr.expr_aggregate_literal as ag:
                if ag.fields.len != names.len:
                    return Option[bool].none
                var i: ptr_uint = 0
                while i < names.len:
                    env.set(read(names.data + i), read(ag.fields.data + i).value)
                    i += 1
                return Option[bool].some(value = true)
            ir.Expr.expr_array_literal as al:
                if al.elements.len != names.len:
                    return Option[bool].none
                var ai: ptr_uint = 0
                while ai < names.len:
                    env.set(read(names.data + ai), al.elements.data + ai)
                    ai += 1
                return Option[bool].some(value = true)
            _:
                return Option[bool].none
    return Option[bool].none


public function const_field_value(fields: span[ir.AggregateField], name: str) -> Option[ptr[ir.Expr]]:
    var i: ptr_uint = 0
    while i < fields.len:
        var f: ir.AggregateField
        unsafe:
            f = read(fields.data + i)
        if f.name == name:
            return Option[ptr[ir.Expr]].some(value = f.value)
        i += 1
    return Option[ptr[ir.Expr]].none


function const_assign_target(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], target: ptr[ast.Expr], operator: str, new_value: ptr[ir.Expr]) -> Option[bool]:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                if operator == "=":
                    env.set(id.name, new_value)
                    return Option[bool].some(value = true)
                let old_ptr = env.get(id.name) else:
                    return Option[bool].none
                match const_apply_binop(ctx, operator, read(old_ptr), new_value):
                    Option.some as folded:
                        env.set(id.name, folded.value)
                        return Option[bool].some(value = true)
                    Option.none:
                        return Option[bool].none
            ast.Expr.expr_member_access as ma:
                return const_assign_member(ctx, env, ma.receiver, ma.member_name, operator, new_value)
            ast.Expr.expr_index_access as ia:
                return const_assign_index(ctx, env, ia.receiver, ia.index, operator, new_value)
            _:
                return Option[bool].none
    return Option[bool].none


## Apply a compound assignment (`+=`) or plain `=` to a compile-time value.
function const_apply_binop(ctx: ref[lowering.LoweringContext], operator: str, old: ptr[ir.Expr], new_value: ptr[ir.Expr]) -> Option[ptr[ir.Expr]]:
    if operator == "=":
        return Option[ptr[ir.Expr]].some(value = new_value)
    if operator.len < 2:
        return Option[ptr[ir.Expr]].none
    let op = operator.slice(0, operator.len - 1)
    return const_fold_binary_ir(ctx, op, old, new_value)


function const_assign_member(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], receiver: ptr[ast.Expr], member: str, operator: str, new_value: ptr[ir.Expr]) -> Option[bool]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as rid:
                let old_ptr = env.get(rid.name) else:
                    return Option[bool].none
                match read(read(old_ptr)):
                    ir.Expr.expr_aggregate_literal as ag:
                        var fields = vec.Vec[ir.AggregateField].create()
                        var i: ptr_uint = 0
                        var replaced = false
                        while i < ag.fields.len:
                            var f: ir.AggregateField
                            f = read(ag.fields.data + i)
                            if f.name == member:
                                match const_apply_binop(ctx, operator, f.value, new_value):
                                    Option.some as folded:
                                        fields.push(ir.AggregateField(name = f.name, value = folded.value))
                                        replaced = true
                                    Option.none:
                                        return Option[bool].none
                            else:
                                fields.push(f)
                            i += 1
                        if not replaced:
                            return Option[bool].none
                        env.set(rid.name, lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = ag.ty, fields = fields.as_span())))
                        return Option[bool].some(value = true)
                    _:
                        return Option[bool].none
            _:
                return Option[bool].none
    return Option[bool].none


function const_assign_index(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], receiver: ptr[ast.Expr], index: ptr[ast.Expr], operator: str, new_value: ptr[ir.Expr]) -> Option[bool]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as rid:
                let idx_opt = const_env_eval_int(ctx, env, index) else:
                    return Option[bool].none
                let old_ptr = env.get(rid.name) else:
                    return Option[bool].none
                match read(read(old_ptr)):
                    ir.Expr.expr_array_literal as al:
                        if idx_opt < 0 or idx_opt >= long<-al.elements.len:
                            return Option[bool].none
                        var elements = vec.Vec[ir.Expr].create()
                        var i: ptr_uint = 0
                        while i < al.elements.len:
                            if long<-i == idx_opt:
                                match const_apply_binop(ctx, operator, al.elements.data + i, new_value):
                                    Option.some as folded:
                                        elements.push(read(folded.value))
                                    Option.none:
                                        return Option[bool].none
                            else:
                                elements.push(read(al.elements.data + i))
                            i += 1
                        env.set(rid.name, lowering.alloc_expr(ir.Expr.expr_array_literal(ty = al.ty, elements = elements.as_span())))
                        return Option[bool].some(value = true)
                    _:
                        return Option[bool].none
            _:
                return Option[bool].none
    return Option[bool].none


function const_flow_if(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], branches: span[ast.IfBranch], else_body: ptr[ast.Stmt]?) -> comptime_types.ConstFlow:
    var bi: ptr_uint = 0
    while bi < branches.len:
        var br: ast.IfBranch
        unsafe:
            br = read(branches.data + bi)
        match const_env_eval_bool(ctx, env, br.condition):
            Option.some as cv:
                if cv.value:
                    return const_flow_body(ctx, env, br.body)
            Option.none:
                return comptime_types.ConstFlow.cf_stuck
        bi += 1
    if else_body != null:
        return const_flow_body(ctx, env, else_body)
    return comptime_types.ConstFlow.cf_fallthrough


function const_flow_while(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], condition: ptr[ast.Expr], body: ptr[ast.Stmt]?) -> comptime_types.ConstFlow:
    var iteration: ptr_uint = 0
    while iteration < 100000:
        match const_env_eval_bool(ctx, env, condition):
            Option.some as cv:
                if not cv.value:
                    return comptime_types.ConstFlow.cf_fallthrough
            Option.none:
                return comptime_types.ConstFlow.cf_stuck
        match const_flow_body(ctx, env, body):
            comptime_types.ConstFlow.cf_fallthrough:
                pass
            comptime_types.ConstFlow.cf_continue:
                pass
            comptime_types.ConstFlow.cf_break:
                return comptime_types.ConstFlow.cf_fallthrough
            comptime_types.ConstFlow.cf_value as v:
                return comptime_types.ConstFlow.cf_value(value = v.value)
            comptime_types.ConstFlow.cf_stuck:
                return comptime_types.ConstFlow.cf_stuck
        iteration += 1
    return comptime_types.ConstFlow.cf_stuck


function const_flow_for(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], bindings: span[ast.ForBinding], iterables: span[ast.Expr], body: ptr[ast.Stmt]?) -> comptime_types.ConstFlow:
    if bindings.len != 1 or iterables.len != 1:
        return comptime_types.ConstFlow.cf_stuck
    var binding: ast.ForBinding
    var iterable: ast.Expr
    unsafe:
        binding = read(bindings.data + 0)
        iterable = read(iterables.data + 0)
    match const_iterable_values(ctx, env, ptr_of(iterable)):
        Option.some as vals:
            var vi: ptr_uint = 0
            while vi < vals.value.len:
                unsafe:
                    env.set(binding.name, read(vals.value.data + vi))
                match const_flow_body(ctx, env, body):
                    comptime_types.ConstFlow.cf_fallthrough:
                        pass
                    comptime_types.ConstFlow.cf_continue:
                        pass
                    comptime_types.ConstFlow.cf_break:
                        return comptime_types.ConstFlow.cf_fallthrough
                    comptime_types.ConstFlow.cf_value as v:
                        return comptime_types.ConstFlow.cf_value(value = v.value)
                    comptime_types.ConstFlow.cf_stuck:
                        return comptime_types.ConstFlow.cf_stuck
                vi += 1
            return comptime_types.ConstFlow.cf_fallthrough
        Option.none:
            return comptime_types.ConstFlow.cf_stuck
    return comptime_types.ConstFlow.cf_stuck


## The element values of a compile-time iterable: an integer range, an array or
## string value, or a slice `arr[a..b]` / `str[a..b]`.
function const_iterable_values(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], ep: ptr[ast.Expr]) -> Option[span[ptr[ir.Expr]]]:
    unsafe:
        match read(ep):
            ast.Expr.expr_range as r:
                let s_opt = const_env_eval_int(ctx, env, r.start_expr) else:
                    return Option[span[ptr[ir.Expr]]].none
                let e_opt = const_env_eval_int(ctx, env, r.end_expr) else:
                    return Option[span[ptr[ir.Expr]]].none
                var range_vals = vec.Vec[ptr[ir.Expr]].create()
                var v = s_opt
                while v < e_opt:
                    range_vals.push(lowering.alloc_expr(ir.Expr.expr_integer_literal(value = v, ty = types.primitive("int"))))
                    v += 1
                    if range_vals.len() > 100000:
                        return Option[span[ptr[ir.Expr]]].none
                return Option[span[ptr[ir.Expr]]].some(value = range_vals.as_span())
            ast.Expr.expr_index_access:
                pass
            _:
                pass
    match lowering.try_const_value_ir(ctx, ep, env):
        Option.some as v:
            unsafe:
                match read(v.value):
                    ir.Expr.expr_array_literal as al:
                        var elems = vec.Vec[ptr[ir.Expr]].create()
                        var i: ptr_uint = 0
                        while i < al.elements.len:
                            elems.push(al.elements.data + i)
                            i += 1
                        return Option[span[ptr[ir.Expr]]].some(value = elems.as_span())
                    ir.Expr.expr_string_literal as sl:
                        var chars = vec.Vec[ptr[ir.Expr]].create()
                        var ci: ptr_uint = 0
                        while ci < sl.value.len:
                            chars.push(lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-sl.value.byte_at(ci), ty = types.primitive("ubyte"))))
                            ci += 1
                        return Option[span[ptr[ir.Expr]]].some(value = chars.as_span())
                    _:
                        return Option[span[ptr[ir.Expr]]].none
        Option.none:
            return Option[span[ptr[ir.Expr]]].none
    return Option[span[ptr[ir.Expr]]].none


function const_flow_match_stmt(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm]) -> comptime_types.ConstFlow:
    match lowering.try_const_value_ir(ctx, scrutinee, env):
        Option.some as sv:
            var ai: ptr_uint = 0
            while ai < arms.len:
                var arm: ast.MatchArm
                unsafe:
                    arm = read(arms.data + ai)
                match const_match_pattern(ctx, env, arm.pattern, sv.value):
                    Option.some as matched:
                        if matched.value:
                            return const_flow_body(ctx, env, arm.body)
                    Option.none:
                        return comptime_types.ConstFlow.cf_stuck
                ai += 1
            return comptime_types.ConstFlow.cf_stuck
        Option.none:
            return comptime_types.ConstFlow.cf_stuck
    return comptime_types.ConstFlow.cf_stuck


## True when a match pattern matches the scrutinee value: literals compare by
## value and `_` (or a missing pattern) is the wildcard.
public function const_match_pattern(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], pattern: ptr[ast.Expr]?, value: ptr[ir.Expr]) -> Option[bool]:
    let pp = pattern else:
        return Option[bool].some(value = true)
    unsafe:
        match read(pp):
            ast.Expr.expr_identifier as pid:
                if pid.name == "_":
                    return Option[bool].some(value = true)
            _:
                pass
    match lowering.try_const_value_ir(ctx, pp, env):
        Option.some as pv:
            return const_value_eq_ir(pv.value, value)
        Option.none:
            return Option[bool].none
    return Option[bool].none


function const_value_eq_ir(a: ptr[ir.Expr], b: ptr[ir.Expr]) -> Option[bool]:
    unsafe:
        match read(a):
            ir.Expr.expr_integer_literal as ai:
                match read(b):
                    ir.Expr.expr_integer_literal as bi:
                        return Option[bool].some(value = ai.value == bi.value)
                    _:
                        return Option[bool].none
            ir.Expr.expr_string_literal as as_:
                match read(b):
                    ir.Expr.expr_string_literal as bs:
                        return Option[bool].some(value = as_.value == bs.value)
                    _:
                        return Option[bool].none
            ir.Expr.expr_boolean_literal as ab:
                match read(b):
                    ir.Expr.expr_boolean_literal as bb:
                        return Option[bool].some(value = ab.value == bb.value)
                    _:
                        return Option[bool].none
            _:
                return Option[bool].none
    return Option[bool].none


public function const_env_eval_int(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], ep: ptr[ast.Expr]) -> Option[long]:
    match lowering.try_const_value_ir(ctx, ep, env):
        Option.some as v:
            unsafe:
                match read(v.value):
                    ir.Expr.expr_integer_literal as il:
                        return Option[long].some(value = il.value)
                    ir.Expr.expr_boolean_literal as bl:
                        if bl.value:
                            return Option[long].some(value = 1)
                        return Option[long].some(value = 0)
                    _:
                        return Option[long].none
        Option.none:
            return Option[long].none
    return Option[long].none


public function const_env_eval_bool(ctx: ref[lowering.LoweringContext], env: ref[map_mod.Map[str, ptr[ir.Expr]]], ep: ptr[ast.Expr]) -> Option[bool]:
    match lowering.try_const_value_ir(ctx, ep, env):
        Option.some as v:
            unsafe:
                match read(v.value):
                    ir.Expr.expr_boolean_literal as bl:
                        return Option[bool].some(value = bl.value)
                    ir.Expr.expr_integer_literal as il:
                        return Option[bool].some(value = il.value != 0)
                    _:
                        return Option[bool].none
        Option.none:
            return Option[bool].none
    return Option[bool].none


## Structural equality of two constant operand expressions.
public function const_operand_eq(ctx: ref[lowering.LoweringContext], left: ptr[ast.Expr], right: ptr[ast.Expr]) -> Option[bool]:
    let lp = lowering.resolve_const_operand(ctx, left, 0) else:
        return Option[bool].none
    let rp = lowering.resolve_const_operand(ctx, right, 0) else:
        return Option[bool].none
    unsafe:
        match read(lp):
            ast.Expr.expr_integer_literal as li:
                match read(rp):
                    ast.Expr.expr_integer_literal as ri:
                        return Option[bool].some(value = li.value == ri.value)
                    _:
                        return Option[bool].none
            ast.Expr.expr_float_literal as lf:
                match read(rp):
                    ast.Expr.expr_float_literal as rf:
                        return Option[bool].some(value = lf.value == rf.value)
                    _:
                        return Option[bool].none
            ast.Expr.expr_bool_literal as lb:
                match read(rp):
                    ast.Expr.expr_bool_literal as rb:
                        return Option[bool].some(value = lb.value == rb.value)
                    _:
                        return Option[bool].none
            ast.Expr.expr_char_literal as lc:
                match read(rp):
                    ast.Expr.expr_char_literal as rc:
                        return Option[bool].some(value = lc.value == rc.value)
                    _:
                        return Option[bool].none
            ast.Expr.expr_string_literal as ls:
                match read(rp):
                    ast.Expr.expr_string_literal as rs:
                        return Option[bool].some(value = ls.value == rs.value)
                    _:
                        return Option[bool].none
            ast.Expr.expr_null_literal:
                match read(rp):
                    ast.Expr.expr_null_literal:
                        return Option[bool].some(value = true)
                    _:
                        return Option[bool].none
            ast.Expr.expr_call as lcall:
                match read(rp):
                    ast.Expr.expr_call as rcall:
                        return const_call_eq(ctx, lcall.callee, lcall.args, rcall.callee, rcall.args)
                    _:
                        return Option[bool].none
            _:
                return Option[bool].none
    return Option[bool].none


## Compare two aggregate/literal constructor calls.  Struct and variant
## literals compare named fields (order-independent); array constructors
## compare positional elements.
function const_call_eq(ctx: ref[lowering.LoweringContext], lcallee: ptr[ast.Expr], largs: span[ast.Argument], rcallee: ptr[ast.Expr], rargs: span[ast.Argument]) -> Option[bool]:
    unsafe:
        match read(lcallee):
            ast.Expr.expr_identifier as lid:
                match read(rcallee):
                    ast.Expr.expr_identifier as rid:
                        if lid.name != rid.name:
                            return Option[bool].none
                        return const_fields_eq(ctx, largs, rargs)
                    _:
                        return Option[bool].none
            ast.Expr.expr_member_access as lma:
                match read(rcallee):
                    ast.Expr.expr_member_access as rma:
                        if lma.member_name != rma.member_name:
                            return Option[bool].none
                        if not const_expr_names_equal(lma.receiver, rma.receiver):
                            return Option[bool].none
                        return const_fields_eq(ctx, largs, rargs)
                    _:
                        return Option[bool].none
            ast.Expr.expr_specialization as lspec:
                match read(rcallee):
                    ast.Expr.expr_specialization as rspec:
                        if not const_expr_names_equal(lspec.callee, rspec.callee):
                            return Option[bool].none
                        return const_positional_eq(ctx, largs, rargs)
                    _:
                        return Option[bool].none
            _:
                return Option[bool].none
    return Option[bool].none


function const_expr_names_equal(a: ptr[ast.Expr], b: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(a):
            ast.Expr.expr_identifier as aid:
                match read(b):
                    ast.Expr.expr_identifier as bid:
                        return aid.name == bid.name
                    _:
                        return false
            _:
                return false


function const_fields_eq(ctx: ref[lowering.LoweringContext], largs: span[ast.Argument], rargs: span[ast.Argument]) -> Option[bool]:
    if largs.len != rargs.len:
        return Option[bool].none
    var right_by_name = map_mod.Map[str, ptr[ast.Expr]].create()
    var ri: ptr_uint = 0
    while ri < rargs.len:
        var ra: ast.Argument
        unsafe:
            ra = read(rargs.data + ri)
        match ra.arg_name:
            Option.some as nm:
                right_by_name.set(nm.value, ra.arg_value)
            Option.none:
                return Option[bool].none
        ri += 1
    var li: ptr_uint = 0
    while li < largs.len:
        var la: ast.Argument
        unsafe:
            la = read(largs.data + li)
        let lname = la.arg_name else:
            return Option[bool].none
        let rvp = right_by_name.get(lname) else:
            return Option[bool].none
        match const_operand_eq(ctx, la.arg_value, unsafe: read(rvp)):
            Option.some as eq:
                if not eq.value:
                    return Option[bool].some(value = false)
            Option.none:
                return Option[bool].none
        li += 1
    return Option[bool].some(value = true)


function const_positional_eq(ctx: ref[lowering.LoweringContext], largs: span[ast.Argument], rargs: span[ast.Argument]) -> Option[bool]:
    if largs.len != rargs.len:
        return Option[bool].none
    var i: ptr_uint = 0
    while i < largs.len:
        var la: ast.Argument
        var ra: ast.Argument
        unsafe:
            la = read(largs.data + i)
            ra = read(rargs.data + i)
        match const_operand_eq(ctx, la.arg_value, ra.arg_value):
            Option.some as eq:
                if not eq.value:
                    return Option[bool].some(value = false)
            Option.none:
                return Option[bool].none
        i += 1
    return Option[bool].some(value = true)


public function const_binary_op(op: str, left_val: comptime_types.ConstValue, right_val: comptime_types.ConstValue) -> Option[comptime_types.ConstValue]:
    match left_val:
        comptime_types.ConstValue.cv_int as li:
            match right_val:
                comptime_types.ConstValue.cv_int as ri:
                    # Comparison operators yield a bool; arithmetic/bitwise yield
                    # an int.  Without this split, `SELECTOR == 2` would evaluate
                    # to `cv_int(1)` and an `inline if` (which only accepts
                    # `cv_bool`) would drop both branches.
                    if lowering.is_const_comparison_op(op):
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = lowering.apply_int_op(op, li.value, ri.value) != 0))
                    return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = lowering.apply_int_op(op, li.value, ri.value)))
                _:
                    return Option[comptime_types.ConstValue].none
        comptime_types.ConstValue.cv_bool as lb:
            match right_val:
                comptime_types.ConstValue.cv_bool as rb:
                    if op == "and":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = lb.value and rb.value))
                    if op == "or":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = lb.value or rb.value))
                    if op == "==":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = lb.value == rb.value))
                    if op == "!=":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = lb.value != rb.value))
                    return Option[comptime_types.ConstValue].none
                _:
                    return Option[comptime_types.ConstValue].none
        comptime_types.ConstValue.cv_str as ls:
            match right_val:
                comptime_types.ConstValue.cv_str as rs:
                    if op == "==":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = ls.value == rs.value))
                    if op == "!=":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = not ls.value == rs.value))
                    return Option[comptime_types.ConstValue].none
                _:
                    return Option[comptime_types.ConstValue].none
        comptime_types.ConstValue.cv_type as lt:
            match right_val:
                comptime_types.ConstValue.cv_type as rt:
                    if op == "==":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = lowering.types_are_equal(lt.ty, rt.ty)))
                    if op == "!=":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = not lowering.types_are_equal(lt.ty, rt.ty)))
                    return Option[comptime_types.ConstValue].none
                _:
                    return Option[comptime_types.ConstValue].none


public function const_values_eq(a: comptime_types.ConstValue, b: comptime_types.ConstValue) -> bool:
    match a:
        comptime_types.ConstValue.cv_int as ai:
            match b:
                comptime_types.ConstValue.cv_int as bi:
                    return ai.value == bi.value
                _:
                    return false
        comptime_types.ConstValue.cv_str as as_:
            match b:
                comptime_types.ConstValue.cv_str as bs:
                    return as_.value == bs.value
                _:
                    return false
        _:
            return false
