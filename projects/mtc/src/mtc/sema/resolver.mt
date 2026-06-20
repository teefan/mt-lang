# Name and type resolution for the self-hosting compiler.
# Mirrors resolve_type_ref / lookup logic from Ruby sema.
# Takes ref[ModuleContext] for editable arena access.

import std.vec
import mtc.types
import mtc.ast
import mtc.scope
import mtc.sema.context

public function resolve_type_ref(
    ctx: ref[context.ModuleContext],
    type_ref: ast.TypeRef,
    type_params: vec.Vec[str],
) -> types.TypeId:
    let parts_len = type_ref.name.parts.len
    if parts_len == 0z:
        return read(ctx).error_type_id

    if parts_len == 1z:
        let name = type_ref.name.parts.at(0) else:
            return read(ctx).error_type_id
        let base_id = resolve_single_name(ctx, name, type_params)
        if types.is_error_type(read(ctx).arena, base_id):
            return base_id
        if type_ref.arguments.len == 0z:
            if type_ref.nullable:
                return read(ctx).arena.alloc(types.Type.nullable(base = base_id))
            return base_id
        return resolve_generic_type(ctx, base_id, type_ref)
    else:
        return resolve_qualified_type(ctx, type_ref)

function resolve_single_name(
    ctx: ref[context.ModuleContext],
    name: str,
    type_params: vec.Vec[str],
) -> types.TypeId:
    # Check type parameters first
    var i: ptr_uint = 0
    while i < type_params.len:
        let tp = type_params.at(i) else:
            break
        if tp == name:
            return read(ctx).arena.alloc(types.Type.type_var(name = name))
        i += 1

    # Check built-in primitives
    if types.is_reserved_type_name(name):
        return read(ctx).arena.ensure_primitive(name)

    # Check module types
    let local_type = read(ctx).types.get(name) else:
        return read(ctx).error_type_id
    return unsafe: read(local_type)

function resolve_qualified_type(
    ctx: ref[context.ModuleContext],
    type_ref: ast.TypeRef,
) -> types.TypeId:
    return read(ctx).error_type_id

function resolve_generic_type(
    ctx: ref[context.ModuleContext],
    base_type_id: types.TypeId,
    type_ref: ast.TypeRef,
) -> types.TypeId:
    let base = read(ctx).arena.get(base_type_id)
    match base:
        types.Type.generic_struct_def:
            return instantiate_generic_struct(ctx, base_type_id, type_ref)
        types.Type.generic_variant_def:
            return instantiate_generic_variant(ctx, base_type_id, type_ref)
        types.Type.generic_interface_def:
            return instantiate_generic_interface(ctx, base_type_id, type_ref)
        _:
            pass
    return read(ctx).error_type_id

function instantiate_generic_struct(
    ctx: ref[context.ModuleContext],
    _def_id: types.TypeId,
    type_ref: ast.TypeRef,
) -> types.TypeId:
    var arg_ids = vec.Vec[types.TypeId].create()
    var empty_params = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < type_ref.arguments.len:
        let arg = type_ref.arguments.at(i) else:
            break
        let resolved = resolve_single_name(ctx, arg.value, empty_params)
        arg_ids.push(resolved)
        i += 1
    let args_start = read(ctx).arena.store_type_id_list(arg_ids)
    return read(ctx).arena.alloc(types.Type.struct_instance(
        definition_id = _def_id,
        arguments_start = args_start,
        arguments_len = arg_ids.len,
    ))

function instantiate_generic_variant(
    ctx: ref[context.ModuleContext],
    _def_id: types.TypeId,
    type_ref: ast.TypeRef,
) -> types.TypeId:
    var arg_ids = vec.Vec[types.TypeId].create()
    var empty_params = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < type_ref.arguments.len:
        let arg = type_ref.arguments.at(i) else:
            break
        let resolved = resolve_single_name(ctx, arg.value, empty_params)
        arg_ids.push(resolved)
        i += 1
    let args_start = read(ctx).arena.store_type_id_list(arg_ids)
    return read(ctx).arena.alloc(types.Type.variant_instance(
        definition_id = _def_id,
        arguments_start = args_start,
        arguments_len = arg_ids.len,
    ))

function instantiate_generic_interface(
    ctx: ref[context.ModuleContext],
    _def_id: types.TypeId,
    type_ref: ast.TypeRef,
) -> types.TypeId:
    var arg_ids = vec.Vec[types.TypeId].create()
    var empty_params = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < type_ref.arguments.len:
        let arg = type_ref.arguments.at(i) else:
            break
        let resolved = resolve_single_name(ctx, arg.value, empty_params)
        arg_ids.push(resolved)
        i += 1
    let args_start = read(ctx).arena.store_type_id_list(arg_ids)
    return read(ctx).arena.alloc(types.Type.interface_instance(
        definition_id = _def_id,
        arguments_start = args_start,
        arguments_len = arg_ids.len,
    ))

public function lookup_value(
    scopes: ref[scope.ScopeStack],
    name: str,
) -> Option[scope.ValueBinding]:
    return read(scopes).lookup(name)

# ── Type expression resolution (from AST Expr nodes) ──

public function resolve_type_expr(
    ctx: ref[context.ModuleContext],
    file: ref[ast.SourceFile],
    node_id: ast.NodeId,
    type_params: vec.Vec[str],
) -> types.TypeId:
    if node_id == 0z:
        return read(ctx).error_type_id

    let expr = read(file).exprs.at(node_id) else:
        return read(ctx).error_type_id

    match expr:
        ast.Expr.identifier(name, _, _):
            return resolve_single_name(ctx, name, type_params)

        ast.Expr.member_access(receiver, member, _, _):
            return resolve_qualified_name(ctx, file, receiver, member, type_params)

        ast.Expr.index_access(receiver, _, args_start, args_len):
            return resolve_index_or_specialization(ctx, file, receiver, args_start, args_len, type_params)

        _:
            pass

    return read(ctx).error_type_id

function resolve_qualified_name(
    ctx: ref[context.ModuleContext],
    file: ref[ast.SourceFile],
    receiver_id: ast.NodeId,
    member: str,
    type_params: vec.Vec[str],
) -> types.TypeId:
    if receiver_id == 0z:
        return read(ctx).error_type_id

    let recv_expr = read(file).exprs.at(receiver_id) else:
        return read(ctx).error_type_id

    match recv_expr:
        ast.Expr.identifier(name, _, _):
            return resolve_imported_type(ctx, name, member, type_params)
        _:
            pass

    return read(ctx).error_type_id

function resolve_imported_type(
    ctx: ref[context.ModuleContext],
    module_alias: str,
    type_name: str,
    _type_params: vec.Vec[str],
) -> types.TypeId:
    # Currently only resolves local types; imports not yet wired
    return resolve_single_name(ctx, type_name, vec.Vec[str].create())

function resolve_index_or_specialization(
    ctx: ref[context.ModuleContext],
    file: ref[ast.SourceFile],
    receiver_id: ast.NodeId,
    args_start: ast.NodeId,
    args_len: ast.NodeId,
    type_params: vec.Vec[str],
) -> types.TypeId:
    let base_type = resolve_type_expr(ctx, file, receiver_id, type_params)
    if types.is_error_type(read(ctx).arena, base_type):
        return base_type

    let base = read(ctx).arena.get(base_type)
    # Check for pointer-like builtin generics: ptr, const_ptr, ref, array, span
    match base:
        types.Type.primitive(name):
            if name == "ptr":
                return resolve_single_arg_construct(ctx, file, args_start, args_len, type_params, "ptr_type")
            else if name == "const_ptr":
                return resolve_single_arg_construct(ctx, file, args_start, args_len, type_params, "const_ptr_type")
            else if name == "ref":
                return resolve_single_arg_construct(ctx, file, args_start, args_len, type_params, "ref_type")
            else if name == "span":
                return resolve_single_arg_construct(ctx, file, args_start, args_len, type_params, "span_type")
            else if name == "array":
                return resolve_array_type(ctx, file, args_start, args_len, type_params)
            else:
                pass
        types.Type.generic_struct_def:
            return instantiate_from_expr_args(ctx, file, base_type, "struct", args_start, args_len, type_params)
        types.Type.generic_variant_def:
            return instantiate_from_expr_args(ctx, file, base_type, "variant", args_start, args_len, type_params)
        types.Type.generic_interface_def:
            return instantiate_from_expr_args(ctx, file, base_type, "interface", args_start, args_len, type_params)
        _:
            pass

    return base_type

function resolve_single_arg_construct(
    ctx: ref[context.ModuleContext],
    file: ref[ast.SourceFile],
    args_start: ast.NodeId,
    args_len: ast.NodeId,
    type_params: vec.Vec[str],
    _construct_kind: str,
) -> types.TypeId:
    if args_len != 1z:
        return read(ctx).error_type_id
    let arg_id = args_start
    let inner = resolve_type_expr(ctx, file, arg_id, type_params)
    if types.is_error_type(read(ctx).arena, inner):
        return inner
    # For now return the pointee type wrapped appropriately
    return inner

function resolve_array_type(
    ctx: ref[context.ModuleContext],
    file: ref[ast.SourceFile],
    args_start: ast.NodeId,
    args_len: ast.NodeId,
    type_params: vec.Vec[str],
) -> types.TypeId:
    if args_len != 2z:
        return read(ctx).error_type_id
    let elem_id = args_start
    let count_id = args_start + 1
    let elem_type = resolve_type_expr(ctx, file, elem_id, type_params)
    let count_type = resolve_type_expr(ctx, file, count_id, type_params)
    return read(ctx).arena.alloc(types.Type.array_type(element = elem_type, count = count_type))

function instantiate_from_expr_args(
    ctx: ref[context.ModuleContext],
    file: ref[ast.SourceFile],
    base_type_id: types.TypeId,
    _kind: str,
    args_start: ast.NodeId,
    args_len: ast.NodeId,
    type_params: vec.Vec[str],
) -> types.TypeId:
    var arg_ids = vec.Vec[types.TypeId].create()
    var i: ast.NodeId = 0z
    while i < args_len:
        let arg_id = args_start + i
        let resolved = resolve_type_expr(ctx, file, arg_id, type_params)
        arg_ids.push(resolved)
        i += 1
    let start = read(ctx).arena.store_type_id_list(arg_ids)

    let base = read(ctx).arena.get(base_type_id)
    match base:
        types.Type.generic_struct_def:
            return read(ctx).arena.alloc(types.Type.struct_instance(
                definition_id = base_type_id,
                arguments_start = start,
                arguments_len = arg_ids.len,
            ))
        types.Type.generic_variant_def:
            return read(ctx).arena.alloc(types.Type.variant_instance(
                definition_id = base_type_id,
                arguments_start = start,
                arguments_len = arg_ids.len,
            ))
        types.Type.generic_interface_def:
            return read(ctx).arena.alloc(types.Type.interface_instance(
                definition_id = base_type_id,
                arguments_start = start,
                arguments_len = arg_ids.len,
            ))
        _:
            pass
    return base_type_id
