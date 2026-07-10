## Module binder — projects an analyzed module's declarations into its public
## export surface (a ModuleBinding) for importers to resolve against.
##
## Mirrors Ruby's ModuleBinder (module_binder.rb): ordinary modules export only
## `public` declarations, while raw (external) modules export everything.  The
## ModuleBinding type itself lives in the analyzer to avoid an import cycle; this
## module supplies the construction/visibility-filtering logic.  Exports
## functions (call checks), structs (construction field checks), value types, and
## methods with signatures (method-call checks).

import std.map as map_mod
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types


public function bind_module(analysis: analyzer.Analysis) -> analyzer.ModuleBinding:
    var functions = map_mod.Map[str, analyzer.FnSig].create()
    var structs = map_mod.Map[str, span[analyzer.FieldEntry]].create()
    var value_types = map_mod.Map[str, types.Type].create()
    var static_member_types = map_mod.Map[str, bool].create()
    var type_aliases = map_mod.Map[str, bool].create()
    var type_alias_types = map_mod.Map[str, types.Type].create()
    var member_keys = map_mod.Map[str, bool].create()
    var method_sigs = map_mod.Map[str, analyzer.FnSig].create()
    var interfaces = map_mod.Map[str, span[ast.InterfaceMethod]].create()
    var implemented = map_mod.Map[str, span[ast.QualifiedName]].create()
    var match_case_names = map_mod.Map[str, span[str]].create()
    var private_functions = map_mod.Map[str, analyzer.FnSig].create()
    var private_structs = map_mod.Map[str, span[analyzer.FieldEntry]].create()
    var private_value_types = map_mod.Map[str, types.Type].create()
    var private_static_member_types = map_mod.Map[str, bool].create()
    var private_type_aliases = map_mod.Map[str, bool].create()
    var private_member_keys = map_mod.Map[str, bool].create()
    var private_method_sigs = map_mod.Map[str, analyzer.FnSig].create()
    var private_interfaces = map_mod.Map[str, span[ast.InterfaceMethod]].create()
    let exports_all = analysis.source_file.module_kind == ast.ModuleKind.module_raw

    var i: ptr_uint = 0
    while i < analysis.source_file.declarations.len:
        var declaration: ast.Decl
        unsafe:
            declaration = read(analysis.source_file.declarations.data + i)
        match declaration:
            ast.Decl.decl_function as fun:
                let sig_ptr = analysis.functions.get(fun.name)
                if sig_ptr != null:
                    let sig = unsafe: read(sig_ptr)
                    if exports_all or fun.visibility:
                        functions.set(fun.name, sig)
                    else:
                        private_functions.set(fun.name, sig)
            ast.Decl.decl_struct as s:
                let fields_ptr = analysis.structs.get(s.name)
                if exports_all or s.visibility:
                    if fields_ptr != null:
                        unsafe:
                            structs.set(s.name, read(fields_ptr))
                    implemented.set(s.name, s.impl_list)
                else:
                    if fields_ptr != null:
                        unsafe:
                            private_structs.set(s.name, read(fields_ptr))
            ast.Decl.decl_const as c:
                let type_ptr = analysis.value_types.get(c.name)
                if type_ptr != null:
                    let ty = unsafe: read(type_ptr)
                    if exports_all or c.visibility:
                        value_types.set(c.name, ty)
                    else:
                        private_value_types.set(c.name, ty)
            ast.Decl.decl_var as v:
                let type_ptr = analysis.value_types.get(v.name)
                if type_ptr != null:
                    let ty = unsafe: read(type_ptr)
                    if exports_all or v.visibility:
                        value_types.set(v.name, ty)
                    else:
                        private_value_types.set(v.name, ty)
            ast.Decl.decl_enum as e:
                if exports_all or e.visibility:
                    static_member_types.set(e.name, true)
                    export_member_keys(ref_of(member_keys), e.name, e.enum_members)
                    export_case_names(ref_of(match_case_names), e.name, e.enum_members)
                else:
                    private_static_member_types.set(e.name, true)
                    export_member_keys(ref_of(private_member_keys), e.name, e.enum_members)
            ast.Decl.decl_flags as fl:
                if exports_all or fl.visibility:
                    static_member_types.set(fl.name, true)
                    export_member_keys(ref_of(member_keys), fl.name, fl.flags_members)
                else:
                    private_static_member_types.set(fl.name, true)
                    export_member_keys(ref_of(private_member_keys), fl.name, fl.flags_members)
            ast.Decl.decl_variant as vr:
                if exports_all or vr.visibility:
                    static_member_types.set(vr.name, true)
                    export_arm_keys(ref_of(member_keys), vr.name, vr.variant_arms)
                    export_arm_case_names(ref_of(match_case_names), vr.name, vr.variant_arms)
                else:
                    private_static_member_types.set(vr.name, true)
                    export_arm_keys(ref_of(private_member_keys), vr.name, vr.variant_arms)
            ast.Decl.decl_type_alias as ta:
                if exports_all or ta.visibility:
                    type_aliases.set(ta.name, true)
                    let resolved_ptr = analysis.type_alias_types.get(ta.name)
                    if resolved_ptr != null:
                        unsafe:
                            type_alias_types.set(ta.name, read(resolved_ptr))
                else:
                    private_type_aliases.set(ta.name, true)
            ast.Decl.decl_extending_block as ex:
                export_methods(ref_of(member_keys), ref_of(method_sigs), ref_of(private_member_keys), ref_of(private_method_sigs), analysis.method_sigs, ex.type_name, ex.methods, exports_all)
            ast.Decl.decl_interface as iface:
                if exports_all or iface.visibility:
                    interfaces.set(iface.name, iface.interface_methods)
                else:
                    private_interfaces.set(iface.name, iface.interface_methods)
            _:
                pass
        i += 1

    return analyzer.ModuleBinding(
        functions = functions,
        structs = structs,
        value_types = value_types,
        type_aliases = type_aliases,
        type_alias_types = type_alias_types,
        static_member_types = static_member_types,
        member_keys = member_keys,
        method_sigs = method_sigs,
        interfaces = interfaces,
        implemented = implemented,
        match_case_names = match_case_names,
        private_functions = private_functions,
        private_structs = private_structs,
        private_value_types = private_value_types,
        private_type_aliases = private_type_aliases,
        private_static_member_types = private_static_member_types,
        private_member_keys = private_member_keys,
        private_method_sigs = private_method_sigs,
        private_interfaces = private_interfaces,
    )


function export_member_keys(member_keys: ref[map_mod.Map[str, bool]], type_name: str, members: span[ast.EnumMember]) -> void:
    var i: ptr_uint = 0
    while i < members.len:
        unsafe:
            member_keys.set(analyzer.method_key(type_name, read(members.data + i).name), true)
        i += 1


function export_case_names(match_case_names: ref[map_mod.Map[str, span[str]]], type_name: str, members: span[ast.EnumMember]) -> void:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < members.len:
        unsafe:
            names.push(read(members.data + i).name)
        i += 1
    match_case_names.set(type_name, names.as_span())


function export_arm_case_names(match_case_names: ref[map_mod.Map[str, span[str]]], type_name: str, arms: span[ast.VariantArm]) -> void:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < arms.len:
        unsafe:
            names.push(read(arms.data + i).name)
        i += 1
    match_case_names.set(type_name, names.as_span())


function export_arm_keys(member_keys: ref[map_mod.Map[str, bool]], type_name: str, arms: span[ast.VariantArm]) -> void:
    var i: ptr_uint = 0
    while i < arms.len:
        unsafe:
            member_keys.set(analyzer.method_key(type_name, read(arms.data + i).name), true)
        i += 1


## Export the public methods of an extending block: their names into member_keys
## (existence, for member access) and their signatures into method_sigs (for
## method-call argument checks), keyed by the extended type name.  A method on a
## non-exported struct produces harmless dead keys (no importer can hold such a
## value), so only method visibility is gated.
function export_methods(member_keys: ref[map_mod.Map[str, bool]], method_sigs: ref[map_mod.Map[str, analyzer.FnSig]], private_member_keys: ref[map_mod.Map[str, bool]], private_method_sigs: ref[map_mod.Map[str, analyzer.FnSig]], source_sigs: map_mod.Map[str, analyzer.FnSig], type_ref: ptr[ast.TypeRef], methods: span[ast.Method], exports_all: bool) -> void:
    let type_name = unsafe: analyzer.qname_to_str(read(type_ref).name)
    var i: ptr_uint = 0
    while i < methods.len:
        var method: ast.Method
        unsafe:
            method = read(methods.data + i)
        if exports_all or method.visibility:
            let key = analyzer.method_key(type_name, method.name)
            member_keys.set(key, true)
            private_member_keys.set(key, true)
            let sig_ptr = source_sigs.get(key)
            if sig_ptr != null:
                unsafe:
                    method_sigs.set(key, read(sig_ptr))
                    private_method_sigs.set(key, read(sig_ptr))
        i += 1
