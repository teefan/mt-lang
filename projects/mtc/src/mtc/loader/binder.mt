## Module binder — projects an analyzed module's declarations into its public
## export surface (a ModuleBinding) for importers to resolve against.
##
## Mirrors Ruby's ModuleBinder (module_binder.rb): ordinary modules export only
## `public` declarations, while raw (external) modules export everything.  The
## ModuleBinding type itself lives in the analyzer to avoid an import cycle; this
## module supplies the construction/visibility-filtering logic.  Exports
## functions (call checks), structs (construction field checks), and value types.

import std.map as map_mod

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types


public function bind_module(analysis: analyzer.Analysis) -> analyzer.ModuleBinding:
    var functions = map_mod.Map[str, analyzer.FnSig].create()
    var structs = map_mod.Map[str, span[analyzer.FieldEntry]].create()
    var value_types = map_mod.Map[str, types.Type].create()
    var static_member_types = map_mod.Map[str, bool].create()
    var member_keys = map_mod.Map[str, bool].create()
    let exports_all = analysis.source_file.module_kind == ast.ModuleKind.module_raw

    var i: ptr_uint = 0
    while i < analysis.source_file.declarations.len:
        var declaration: ast.Decl
        unsafe:
            declaration = read(analysis.source_file.declarations.data + i)
        match declaration:
            ast.Decl.decl_function as fun:
                if exports_all or fun.visibility:
                    let sig_ptr = analysis.functions.get(fun.name)
                    if sig_ptr != null:
                        unsafe:
                            functions.set(fun.name, read(sig_ptr))
            ast.Decl.decl_struct as s:
                if exports_all or s.visibility:
                    let fields_ptr = analysis.structs.get(s.name)
                    if fields_ptr != null:
                        unsafe:
                            structs.set(s.name, read(fields_ptr))
            ast.Decl.decl_const as c:
                if exports_all or c.visibility:
                    let type_ptr = analysis.value_types.get(c.name)
                    if type_ptr != null:
                        unsafe:
                            value_types.set(c.name, read(type_ptr))
            ast.Decl.decl_var as v:
                if exports_all or v.visibility:
                    let type_ptr = analysis.value_types.get(v.name)
                    if type_ptr != null:
                        unsafe:
                            value_types.set(v.name, read(type_ptr))
            ast.Decl.decl_enum as e:
                if exports_all or e.visibility:
                    static_member_types.set(e.name, true)
                    export_member_keys(ref_of(member_keys), e.name, e.enum_members)
            ast.Decl.decl_flags as fl:
                if exports_all or fl.visibility:
                    static_member_types.set(fl.name, true)
                    export_member_keys(ref_of(member_keys), fl.name, fl.flags_members)
            ast.Decl.decl_variant as vr:
                if exports_all or vr.visibility:
                    static_member_types.set(vr.name, true)
                    export_arm_keys(ref_of(member_keys), vr.name, vr.variant_arms)
            ast.Decl.decl_extending_block as ex:
                export_method_keys(ref_of(member_keys), ex.type_name, ex.methods, exports_all)
            _:
                pass
        i += 1

    return analyzer.ModuleBinding(
        functions = functions,
        structs = structs,
        value_types = value_types,
        static_member_types = static_member_types,
        member_keys = member_keys,
    )


function export_member_keys(member_keys: ref[map_mod.Map[str, bool]], type_name: str, members: span[ast.EnumMember]) -> void:
    var i: ptr_uint = 0
    while i < members.len:
        unsafe:
            member_keys.set(analyzer.method_key(type_name, read(members.data + i).name), true)
        i += 1


function export_arm_keys(member_keys: ref[map_mod.Map[str, bool]], type_name: str, arms: span[ast.VariantArm]) -> void:
    var i: ptr_uint = 0
    while i < arms.len:
        unsafe:
            member_keys.set(analyzer.method_key(type_name, read(arms.data + i).name), true)
        i += 1


## Export the public methods of an extending block, keyed by the extended type
## name, so `value.method()` calls on imported-typed values resolve.  A method on
## a non-exported struct produces harmless dead keys (no importer can hold such a
## value), so only method visibility is gated.
function export_method_keys(member_keys: ref[map_mod.Map[str, bool]], type_ref: ptr[ast.TypeRef], methods: span[ast.Method], exports_all: bool) -> void:
    let type_name = unsafe: analyzer.qname_to_str(read(type_ref).name)
    var i: ptr_uint = 0
    while i < methods.len:
        var method: ast.Method
        unsafe:
            method = read(methods.data + i)
        if exports_all or method.visibility:
            member_keys.set(analyzer.method_key(type_name, method.name), true)
        i += 1
