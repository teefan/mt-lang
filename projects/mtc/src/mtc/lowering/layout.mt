## Compile-time layout of a type — size, alignment, field offsets, and the
## struct/aggregate shapes the constant folder needs.  Extracted from
## lowering/lowering.mt.

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types

import mtc.lowering.lowering as lowering


## Compile-time layout of a type, mirroring Ruby's `Types::Layout` for the
## shapes this compiler models.  Used to fold `size_of` / `align_of` /
## `offset_of` in constant initializers exactly where the host does.
struct LayoutInfo:
    size: long
    alignment: long


struct StructMeta:
    packed: bool
    alignment: long


function layout_align_up(value: long, alignment: long) -> long:
    if alignment <= 1:
        return value
    let remainder = value % alignment
    if remainder == 0:
        return value
    return value + alignment - remainder


## True when the host's `layout_pointer_like_nullable_base?` treats the base as
## a raw pointer for nullable layout purposes.
function layout_pointer_like(base: types.Type) -> bool:
    match base:
        types.Type.ty_function:
            return true
        types.Type.ty_opaque:
            return true
        types.Type.ty_primitive as tp:
            return tp.name == "cstr"
        types.Type.ty_generic as g:
            return g.name == "ptr" or g.name == "const_ptr" or g.name == "own" or g.name == "ref"
        _:
            return false


function layout_info(ctx: ref[lowering.LoweringContext], ty: types.Type) -> Option[LayoutInfo]:
    match ty:
        types.Type.ty_primitive as tp:
            if tp.name == "bool" or tp.name == "byte" or tp.name == "ubyte" or tp.name == "char":
                return Option[LayoutInfo].some(value = LayoutInfo(size = 1, alignment = 1))
            if tp.name == "short" or tp.name == "ushort":
                return Option[LayoutInfo].some(value = LayoutInfo(size = 2, alignment = 2))
            if tp.name == "int" or tp.name == "uint" or tp.name == "float":
                return Option[LayoutInfo].some(value = LayoutInfo(size = 4, alignment = 4))
            if tp.name == "long" or tp.name == "ulong" or tp.name == "double":
                return Option[LayoutInfo].some(value = LayoutInfo(size = 8, alignment = 8))
            if tp.name == "ptr_int" or tp.name == "ptr_uint" or tp.name == "cstr":
                return Option[LayoutInfo].some(value = LayoutInfo(size = 8, alignment = 8))
            return Option[LayoutInfo].none
        types.Type.ty_str:
            # `Types::StringView`: { ptr[char] data; ptr_uint len; }
            return Option[LayoutInfo].some(value = LayoutInfo(size = 16, alignment = 8))
        types.Type.ty_function:
            return Option[LayoutInfo].some(value = LayoutInfo(size = 8, alignment = 8))
        types.Type.ty_nullable as nl:
            let base = unsafe: read(nl.base)
            if layout_pointer_like(base):
                return Option[LayoutInfo].some(value = LayoutInfo(size = 8, alignment = 8))
            let inner = layout_info(ctx, base) else:
                return Option[LayoutInfo].none
            # struct { bool has_value; base value; }
            let value_offset = layout_align_up(1, inner.alignment)
            let overall = if inner.alignment > 1: inner.alignment else: 1
            return Option[LayoutInfo].some(value = LayoutInfo(
                size = layout_align_up(value_offset + inner.size, overall),
                alignment = overall,
            ))
        types.Type.ty_generic as g:
            if g.name == "ptr" or g.name == "const_ptr" or g.name == "own" or g.name == "ref":
                return Option[LayoutInfo].some(value = LayoutInfo(size = 8, alignment = 8))
            if g.name == "span" and g.args.len == 1:
                # `Types::Span`: { ptr[T] data; ptr_uint len; }
                return Option[LayoutInfo].some(value = LayoutInfo(size = 16, alignment = 8))
            if g.name == "array" and g.args.len == 2:
                let element = unsafe: read(g.args.data + 0)
                var count: long = 0
                match unsafe: read(g.args.data + 1):
                    types.Type.ty_literal_int as lit:
                        count = lit.value
                    _:
                        return Option[LayoutInfo].none
                let element_info = layout_info(ctx, element) else:
                    return Option[LayoutInfo].none
                return Option[LayoutInfo].some(value = LayoutInfo(
                    size = element_info.size * count,
                    alignment = element_info.alignment,
                ))
            if g.name == "str_buffer" and g.args.len == 1:
                var capacity: long = 0
                match unsafe: read(g.args.data + 0):
                    types.Type.ty_literal_int as lit:
                        capacity = lit.value + 1
                    _:
                        return Option[LayoutInfo].none
                # struct { char data[cap]; ptr_uint len; bool dirty; }
                var offset = capacity
                offset = layout_align_up(offset, 8)
                offset += 8
                offset += 1
                return Option[LayoutInfo].some(value = LayoutInfo(size = layout_align_up(offset, 8), alignment = 8))
            return Option[LayoutInfo].none
        types.Type.ty_imported as im:
            if im.args.len > 0:
                return Option[LayoutInfo].none
            match layout_struct_fields(ctx, im.module_name, im.name):
                Option.some as fields:
                    let meta = layout_struct_meta(ctx, im.module_name, im.name)
                    return layout_aggregate_info(ctx, fields.value, meta.packed, meta.alignment)
                Option.none:
                    return Option[LayoutInfo].none
        types.Type.ty_named as na:
            match layout_struct_fields(ctx, na.module_name, na.name):
                Option.some as fields:
                    let meta = layout_struct_meta(ctx, na.module_name, na.name)
                    return layout_aggregate_info(ctx, fields.value, meta.packed, meta.alignment)
                Option.none:
                    return Option[LayoutInfo].none
        _:
            return Option[LayoutInfo].none


## Field entries for a named struct: the current module first, then the
## declaring module of an imported type.
function layout_struct_fields(ctx: ref[lowering.LoweringContext], module_name: str, name: str) -> Option[span[analyzer.FieldEntry]]:
    if module_name.len == 0 or module_name == ctx.module_name:
        let local = ctx.analysis.structs.get(name)
        if local != null:
            return Option[span[analyzer.FieldEntry]].some(value = unsafe: read(local))
    match lowering.find_imported_analysis(ctx, module_name):
        Option.some as ia:
            let imported = ia.value.structs.get(name)
            if imported != null:
                return Option[span[analyzer.FieldEntry]].some(value = unsafe: read(imported))
        Option.none:
            pass
    return Option[span[analyzer.FieldEntry]].none


## `packed` / `alignment` of a named struct's declaration (defaults when the
## declaration is not found in the module's source file).
function layout_struct_meta(ctx: ref[lowering.LoweringContext], module_name: str, name: str) -> StructMeta:
    if module_name.len == 0 or module_name == ctx.module_name:
        return layout_struct_meta_of(ctx.analysis.source_file, name)
    match lowering.find_imported_analysis(ctx, module_name):
        Option.some as ia:
            return layout_struct_meta_of(ia.value.source_file, name)
        Option.none:
            return StructMeta(packed = false, alignment = 0)


function layout_struct_meta_of(sf: ast.SourceFile, name: str) -> StructMeta:
    var i: ptr_uint = 0
    while i < sf.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(sf.declarations.data + i)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == name:
                    return StructMeta(packed = s.packed, alignment = s.alignment)
            _:
                pass
        i += 1
    return StructMeta(packed = false, alignment = 0)


## C struct layout for an ordered field list (host `struct_layout_from_infos`).
function layout_aggregate_info(ctx: ref[lowering.LoweringContext], fields: span[analyzer.FieldEntry], packed: bool, explicit_alignment: long) -> Option[LayoutInfo]:
    var offset: long = 0
    var natural_alignment: long = 1
    var i: ptr_uint = 0
    while i < fields.len:
        var f: analyzer.FieldEntry
        unsafe:
            f = read(fields.data + i)
        let info = layout_info(ctx, f.ty) else:
            return Option[LayoutInfo].none
        let effective = if packed: 1 else: info.alignment
        if effective > natural_alignment:
            natural_alignment = effective
        if not packed:
            offset = layout_align_up(offset, effective)
        offset += info.size
        i += 1
    let overall = if natural_alignment > explicit_alignment: natural_alignment else: explicit_alignment
    return Option[LayoutInfo].some(value = LayoutInfo(
        size = layout_align_up(offset, overall),
        alignment = overall,
    ))


public function layout_size(ctx: ref[lowering.LoweringContext], ty: types.Type) -> Option[long]:
    match layout_info(ctx, ty):
        Option.some as info:
            return Option[long].some(value = info.value.size)
        Option.none:
            return Option[long].none


public function layout_alignment(ctx: ref[lowering.LoweringContext], ty: types.Type) -> Option[long]:
    match layout_info(ctx, ty):
        Option.some as info:
            return Option[long].some(value = info.value.alignment)
        Option.none:
            return Option[long].none


## Byte offset of a field (host `Layout.offset_of`) for structs, spans, and
## str_buffers; unions and other shapes are not modelled.
public function layout_offset_of(ctx: ref[lowering.LoweringContext], ty: types.Type, field: str) -> Option[long]:
    match ty:
        types.Type.ty_generic as g:
            if g.name == "span" and g.args.len == 1:
                if field == "data":
                    return Option[long].some(value = 0)
                if field == "len":
                    return Option[long].some(value = 8)
                return Option[long].none
            if g.name == "str_buffer" and g.args.len == 1:
                var capacity: long = 0
                match unsafe: read(g.args.data + 0):
                    types.Type.ty_literal_int as lit:
                        capacity = lit.value + 1
                    _:
                        return Option[long].none
                if field == "data":
                    return Option[long].some(value = 0)
                let len_offset = layout_align_up(capacity, 8)
                if field == "len":
                    return Option[long].some(value = len_offset)
                if field == "dirty":
                    return Option[long].some(value = len_offset + 8)
                return Option[long].none
            return Option[long].none
        types.Type.ty_imported as im:
            if im.args.len > 0:
                return Option[long].none
            match layout_struct_fields(ctx, im.module_name, im.name):
                Option.some as fields:
                    let meta = layout_struct_meta(ctx, im.module_name, im.name)
                    return layout_struct_field_offset(ctx, fields.value, meta.packed, field)
                Option.none:
                    return Option[long].none
        types.Type.ty_named as na:
            match layout_struct_fields(ctx, na.module_name, na.name):
                Option.some as fields:
                    let meta = layout_struct_meta(ctx, na.module_name, na.name)
                    return layout_struct_field_offset(ctx, fields.value, meta.packed, field)
                Option.none:
                    return Option[long].none
        _:
            return Option[long].none


function layout_struct_field_offset(ctx: ref[lowering.LoweringContext], fields: span[analyzer.FieldEntry], packed: bool, field: str) -> Option[long]:
    var offset: long = 0
    var i: ptr_uint = 0
    while i < fields.len:
        var f: analyzer.FieldEntry
        unsafe:
            f = read(fields.data + i)
        let info = layout_info(ctx, f.ty) else:
            return Option[long].none
        let effective = if packed: 1 else: info.alignment
        if not packed:
            offset = layout_align_up(offset, effective)
        if f.name == field:
            return Option[long].some(value = offset)
        offset += info.size
        i += 1
    return Option[long].none
