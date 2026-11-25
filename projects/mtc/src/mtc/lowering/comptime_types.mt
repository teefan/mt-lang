## Compile-time evaluation values shared by `lowering.mt` and `comptime.mt`.
## Kept in an acyclic module: a variant's arms are not resolvable across a
## mutual import cycle, while cyclic function/type references are supported.

import mtc.ir as ir
import mtc.semantic.types as types

public variant ConstValue:
    cv_int(value: long)
    cv_bool(value: bool)
    cv_str(value: str)
    cv_type(ty: types.Type)

public variant ComptimeElement:
    ce_struct_field(name: str, field_type: types.Type)
    ce_enum_member(name: str, member_value: long)
    ce_attribute

public variant ConstFlow:
    cf_value(value: ptr[ir.Expr])
    cf_break
    cf_continue
    cf_fallthrough
    cf_stuck
