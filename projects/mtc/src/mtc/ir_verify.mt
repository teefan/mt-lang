## Structural verification for lowered IR (Wave 4.1).
##
## This is deliberately independent of the C backend: it catches a lowering
## result that is internally inconsistent before code generation can turn it
## into malformed C.  It returns the first violation with the owning declaration
## in the message; callers release the returned String.
##
## Checked invariants:
##   - unique linkage names across functions/constants/globals/types;
##   - no `ty_error`/`ty_var` in concrete declaration types;
##   - non-empty source-module owners when present;
##   - unique field/parameter/member/arm names;
##   - one entry point, linked as `main`, returning `int`;
##   - one default per switch, and values only on non-default cases;
##   - unique labels per function and every `goto` targeting a defined label.

import std.map as map_mod
import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.semantic.types as types


function verification_error(context: str, detail: str) -> Option[string.String]:
    var message = string.String.create()
    message.append("IR verification failed: ")
    message.append(context)
    message.append(": ")
    message.append(detail)
    return Option[string.String].some(value = message)


function register_linkage(
    seen: ref[map_mod.Map[str, bool]],
    name: str,
    kind: str,
) -> Option[string.String]:
    if name.len == 0:
        return verification_error(kind, "empty linkage name")
    if seen.contains(name):
        return verification_error(name, "duplicate linkage name")
    seen.set(name, true)
    return Option[string.String].none


function check_owner(owner: Option[str], name: str) -> Option[string.String]:
    match owner:
        Option.some as owner_value:
            if owner_value.value.len == 0:
                return verification_error(name, "empty source module")
        Option.none:
            pass
    return Option[string.String].none


function check_concrete_type(ty: types.Type, name: str) -> Option[string.String]:
    if types.contains_error(ty):
        return verification_error(name, "type contains ty_error")
    if types.contains_type_var(ty):
        return verification_error(name, "type contains ty_var")
    return Option[string.String].none


function check_fields(
    fields: span[ir.Field],
    owner: str,
    seen: ref[map_mod.Map[str, bool]],
) -> Option[string.String]:
    var i: ptr_uint = 0
    while i < fields.len:
        let field = unsafe: read(fields.data + i)
        if field.name.len == 0:
            return verification_error(owner, "empty field name")
        if seen.contains(field.name):
            return verification_error(owner, "duplicate field name")
        seen.set(field.name, true)
        match check_concrete_type(field.ty, owner):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        i += 1
    return Option[string.String].none


function labels_of_stmts(
    body: span[ir.Stmt],
    labels: ref[map_mod.Map[str, bool]],
) -> Option[string.String]:
    var i: ptr_uint = 0
    while i < body.len:
        match labels_of_stmt(unsafe: read(body.data + i), labels):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        i += 1
    return Option[string.String].none


function labels_of_stmt(
    statement: ir.Stmt,
    labels: ref[map_mod.Map[str, bool]],
) -> Option[string.String]:
    match statement:
        ir.Stmt.stmt_label as label:
            if label.name.len == 0:
                return verification_error("<label>", "empty label name")
            if labels.contains(label.name):
                return verification_error(label.name, "duplicate label")
            labels.set(label.name, true)
        ir.Stmt.stmt_block as block:
            return labels_of_stmts(block.body, labels)
        ir.Stmt.stmt_if as iff:
            match labels_of_stmts(iff.then_body, labels):
                Option.some as error:
                    return Option[string.String].some(value = error.value)
                Option.none:
                    pass
            match iff.else_body:
                Option.some as else_body:
                    return labels_of_stmts(else_body.value, labels)
                Option.none:
                    pass
        ir.Stmt.stmt_switch as sw:
            var defaults: ptr_uint = 0
            var ci: ptr_uint = 0
            while ci < sw.cases.len:
                let switch_case = unsafe: read(sw.cases.data + ci)
                if switch_case.is_default:
                    defaults += 1
                    if defaults > 1:
                        return verification_error("<switch>", "multiple default cases")
                    if switch_case.value != null:
                        return verification_error("<switch>", "default case carries a value")
                else:
                    if switch_case.value == null:
                        return verification_error("<switch>", "non-default case has no value")
                match labels_of_stmts(switch_case.body, labels):
                    Option.some as error:
                        return Option[string.String].some(value = error.value)
                    Option.none:
                        pass
                ci += 1
        ir.Stmt.stmt_while as while_stmt:
            return labels_of_stmts(while_stmt.body, labels)
        ir.Stmt.stmt_for as for_stmt:
            match labels_of_stmt(unsafe: read(for_stmt.init), labels):
                Option.some as error:
                    return Option[string.String].some(value = error.value)
                Option.none:
                    pass
            match labels_of_stmt(unsafe: read(for_stmt.post), labels):
                Option.some as error:
                    return Option[string.String].some(value = error.value)
                Option.none:
                    pass
            return labels_of_stmts(for_stmt.body, labels)
        _:
            pass
    return Option[string.String].none


function gotos_of_stmts(
    body: span[ir.Stmt],
    labels: ref[map_mod.Map[str, bool]],
) -> Option[string.String]:
    var i: ptr_uint = 0
    while i < body.len:
        match gotos_of_stmt(unsafe: read(body.data + i), labels):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        i += 1
    return Option[string.String].none


function gotos_of_stmt(
    statement: ir.Stmt,
    labels: ref[map_mod.Map[str, bool]],
) -> Option[string.String]:
    match statement:
        ir.Stmt.stmt_goto as jump:
            if not labels.contains(jump.label):
                return verification_error(jump.label, "goto target is not defined")
        ir.Stmt.stmt_block as block:
            return gotos_of_stmts(block.body, labels)
        ir.Stmt.stmt_if as iff:
            match gotos_of_stmts(iff.then_body, labels):
                Option.some as error:
                    return Option[string.String].some(value = error.value)
                Option.none:
                    pass
            match iff.else_body:
                Option.some as else_body:
                    return gotos_of_stmts(else_body.value, labels)
                Option.none:
                    pass
        ir.Stmt.stmt_switch as sw:
            var ci: ptr_uint = 0
            while ci < sw.cases.len:
                let switch_case = unsafe: read(sw.cases.data + ci)
                match gotos_of_stmts(switch_case.body, labels):
                    Option.some as error:
                        return Option[string.String].some(value = error.value)
                    Option.none:
                        pass
                ci += 1
        ir.Stmt.stmt_while as while_stmt:
            return gotos_of_stmts(while_stmt.body, labels)
        ir.Stmt.stmt_for as for_stmt:
            match gotos_of_stmt(unsafe: read(for_stmt.init), labels):
                Option.some as error:
                    return Option[string.String].some(value = error.value)
                Option.none:
                    pass
            match gotos_of_stmt(unsafe: read(for_stmt.post), labels):
                Option.some as error:
                    return Option[string.String].some(value = error.value)
                Option.none:
                    pass
            return gotos_of_stmts(for_stmt.body, labels)
        _:
            pass
    return Option[string.String].none


function check_function(func: ir.Function) -> Option[string.String]:
    var parameter_names = map_mod.Map[str, bool].create()
    defer: parameter_names.release()
    var pi: ptr_uint = 0
    while pi < func.params.len:
        let parameter = unsafe: read(func.params.data + pi)
        if parameter.name.len > 0:
            if parameter_names.contains(parameter.name):
                return verification_error(func.linkage_name, "duplicate parameter name")
            parameter_names.set(parameter.name, true)
        match check_concrete_type(parameter.ty, func.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        pi += 1
    match check_concrete_type(func.return_type, func.linkage_name):
        Option.some as error:
            return Option[string.String].some(value = error.value)
        Option.none:
            pass
    match check_owner(func.source_module, func.linkage_name):
        Option.some as error:
            return Option[string.String].some(value = error.value)
        Option.none:
            pass

    var labels = map_mod.Map[str, bool].create()
    defer: labels.release()
    match labels_of_stmts(func.body, ref_of(labels)):
        Option.some as error:
            return Option[string.String].some(value = error.value)
        Option.none:
            pass
    return gotos_of_stmts(func.body, ref_of(labels))


function check_struct(struct_decl: ir.StructDecl) -> Option[string.String]:
    var fields = map_mod.Map[str, bool].create()
    defer: fields.release()
    return check_fields(struct_decl.fields, struct_decl.linkage_name, ref_of(fields))


function check_union(union_decl: ir.UnionDecl) -> Option[string.String]:
    var fields = map_mod.Map[str, bool].create()
    defer: fields.release()
    return check_fields(union_decl.fields, union_decl.linkage_name, ref_of(fields))


function check_variant(variant_decl: ir.VariantDecl) -> Option[string.String]:
    var arms = map_mod.Map[str, bool].create()
    defer: arms.release()
    var ai: ptr_uint = 0
    while ai < variant_decl.arms.len:
        let arm = unsafe: read(variant_decl.arms.data + ai)
        if arm.name.len == 0:
            return verification_error(variant_decl.linkage_name, "empty variant arm name")
        if arms.contains(arm.name):
            return verification_error(variant_decl.linkage_name, "duplicate variant arm")
        arms.set(arm.name, true)
        var fields = map_mod.Map[str, bool].create()
        defer: fields.release()
        match check_fields(arm.fields, arm.linkage_name, ref_of(fields)):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        ai += 1
    return Option[string.String].none


function check_enum(enum_decl: ir.EnumDecl) -> Option[string.String]:
    match check_concrete_type(enum_decl.backing_type, enum_decl.linkage_name):
        Option.some as error:
            return Option[string.String].some(value = error.value)
        Option.none:
            pass
    var members = map_mod.Map[str, bool].create()
    defer: members.release()
    var mi: ptr_uint = 0
    while mi < enum_decl.members.len:
        let member = unsafe: read(enum_decl.members.data + mi)
        if member.name.len == 0:
            return verification_error(enum_decl.linkage_name, "empty enum member name")
        if members.contains(member.name):
            return verification_error(enum_decl.linkage_name, "duplicate enum member")
        members.set(member.name, true)
        mi += 1
    return Option[string.String].none


function verify_functions(program: ir.Program, seen: ref[map_mod.Map[str, bool]]) -> Option[string.String]:
    var fi: ptr_uint = 0
    while fi < program.functions.len:
        let func = unsafe: read(program.functions.data + fi)
        match register_linkage(ref_of(seen), func.linkage_name, "function"):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_function(func):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        fi += 1

    var entry_points: ptr_uint = 0
    fi = 0
    while fi < program.functions.len:
        let func = unsafe: read(program.functions.data + fi)
        if func.entry_point:
            entry_points += 1
            if entry_points > 1:
                return verification_error("<program>", "multiple entry points")
            if func.linkage_name != "main":
                return verification_error(func.linkage_name, "entry point is not linked as main")
            match func.return_type:
                types.Type.ty_primitive as primitive:
                    if primitive.name != "int":
                        return verification_error(func.linkage_name, "entry point does not return int")
                _:
                    return verification_error(func.linkage_name, "entry point does not return int")
        fi += 1

    return Option[string.String].none


function verify_values(program: ir.Program, seen: ref[map_mod.Map[str, bool]]) -> Option[string.String]:
    var ci: ptr_uint = 0
    while ci < program.constants.len:
        let constant = unsafe: read(program.constants.data + ci)
        match register_linkage(ref_of(seen), constant.linkage_name, "constant"):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_concrete_type(constant.ty, constant.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_owner(constant.source_module, constant.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        ci += 1

    var gi: ptr_uint = 0
    while gi < program.globals.len:
        let global = unsafe: read(program.globals.data + gi)
        match register_linkage(ref_of(seen), global.linkage_name, "global"):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_concrete_type(global.ty, global.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_owner(global.source_module, global.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        gi += 1

    return Option[string.String].none


function verify_types(program: ir.Program, seen: ref[map_mod.Map[str, bool]]) -> Option[string.String]:
    var si: ptr_uint = 0
    while si < program.structs.len:
        let struct_decl = unsafe: read(program.structs.data + si)
        match register_linkage(ref_of(seen), struct_decl.linkage_name, "struct"):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_owner(struct_decl.source_module, struct_decl.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_struct(struct_decl):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        si += 1

    var ui: ptr_uint = 0
    while ui < program.unions.len:
        let union_decl = unsafe: read(program.unions.data + ui)
        match register_linkage(ref_of(seen), union_decl.linkage_name, "union"):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_owner(union_decl.source_module, union_decl.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_union(union_decl):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        ui += 1

    var ei: ptr_uint = 0
    while ei < program.enums.len:
        let enum_decl = unsafe: read(program.enums.data + ei)
        match register_linkage(ref_of(seen), enum_decl.linkage_name, "enum"):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_enum(enum_decl):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        ei += 1

    var vi: ptr_uint = 0
    while vi < program.variants.len:
        let variant_decl = unsafe: read(program.variants.data + vi)
        match register_linkage(ref_of(seen), variant_decl.linkage_name, "variant"):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_owner(variant_decl.source_module, variant_decl.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_variant(variant_decl):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        vi += 1

    var oi: ptr_uint = 0
    while oi < program.opaques.len:
        let opaque_decl = unsafe: read(program.opaques.data + oi)
        match register_linkage(ref_of(seen), opaque_decl.linkage_name, "opaque"):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_owner(opaque_decl.source_module, opaque_decl.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        oi += 1

    var ti: ptr_uint = 0
    while ti < program.type_aliases.len:
        let alias = unsafe: read(program.type_aliases.data + ti)
        if alias.qualified_name.len == 0:
            return verification_error("<type alias>", "empty qualified name")
        if seen.contains(alias.qualified_name):
            return verification_error(alias.qualified_name, "duplicate linkage name")
        seen.set(alias.qualified_name, true)
        match check_concrete_type(alias.target_type, alias.qualified_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        ti += 1

    return Option[string.String].none


function verify_auxiliary(program: ir.Program) -> Option[string.String]:
    var mi: ptr_uint = 0
    while mi < program.monomorphized_structs.len:
        let struct_decl = unsafe: read(program.monomorphized_structs.data + mi)
        match check_struct(struct_decl):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        mi += 1

    mi = 0
    while mi < program.monomorphized_variants.len:
        let variant_decl = unsafe: read(program.monomorphized_variants.data + mi)
        match check_variant(variant_decl):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        mi += 1

    mi = 0
    while mi < program.external_structs.len:
        let external_layout = unsafe: read(program.external_structs.data + mi)
        var fields = map_mod.Map[str, bool].create()
        defer: fields.release()
        match check_fields(external_layout.fields, external_layout.key, ref_of(fields)):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        mi += 1

    mi = 0
    while mi < program.str_buffer_structs.len:
        let struct_decl = unsafe: read(program.str_buffer_structs.data + mi)
        match check_owner(struct_decl.source_module, struct_decl.linkage_name):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        match check_struct(struct_decl):
            Option.some as error:
                return Option[string.String].some(value = error.value)
            Option.none:
                pass
        mi += 1

    return Option[string.String].none


## Verify a lowered program.  Returns the first violation, or none.
public function verify(program: ir.Program) -> Option[string.String]:
    var seen = map_mod.Map[str, bool].create()
    defer: seen.release()
    match verify_functions(program, ref_of(seen)):
        Option.some as error:
            return Option[string.String].some(value = error.value)
        Option.none:
            pass
    match verify_values(program, ref_of(seen)):
        Option.some as error:
            return Option[string.String].some(value = error.value)
        Option.none:
            pass
    match verify_types(program, ref_of(seen)):
        Option.some as error:
            return Option[string.String].some(value = error.value)
        Option.none:
            pass
    return verify_auxiliary(program)
