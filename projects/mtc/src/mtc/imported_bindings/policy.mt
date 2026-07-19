## Imported bindings policy parser.
##
## Loads a .binding.json file, validates identity fields, and returns a
## BindingPolicy with all sections parsed into typed structs backed by owned
## string.String values — independent of the JSON tree lifetime.

import std.json as json
import std.str
import std.string as string
import std.vec as vec
import std.fs as fs

# =============================================================================
#  JSON object accessor wrappers — dereference ptr[json.Object] safely
# =============================================================================

function obj_get(obj: ptr[json.Object], key: str) -> ptr[json.Value]?:
    return unsafe: read(obj).get(key)


function obj_contains(obj: ptr[json.Object], key: str) -> bool:
    return unsafe: read(obj).contains(key)


function obj_get_string(obj: ptr[json.Object], key: str) -> Option[str]:
    return unsafe: read(obj).get_string(key)


function obj_get_array(obj: ptr[json.Object], key: str) -> ptr[json.Array]?:
    return unsafe: read(obj).get_array(key)


function obj_get_object(obj: ptr[json.Object], key: str) -> ptr[json.Object]?:
    return unsafe: read(obj).get_object(key)


function arr_len(arr: ptr[json.Array]) -> ptr_uint:
    return unsafe: read(arr).len()


function arr_get_string(arr: ptr[json.Array], index: ptr_uint) -> Option[str]:
    return unsafe: read(arr).get_string(index)


function arr_get_object(arr: ptr[json.Array], index: ptr_uint) -> ptr[json.Object]?:
    return unsafe: read(arr).get_object(index)

# =============================================================================
#  Policy data types
# =============================================================================

public struct ImportSpec:
    module_name: string.String
    alias: string.String


public struct RenameRule:
    kind: string.String
    pattern: string.String
    replace_with: string.String


public struct TypeOverride:
    raw: string.String
    name: string.String
    mapping: string.String
    override_kind: string.String


public struct FunctionParamOverride:
    name: string.String
    param_type: string.String
    mode: string.String
    boundary_type: string.String


public struct FunctionOverride:
    raw: string.String
    name: string.String
    type_params: vec.Vec[string.String]
    params: vec.Vec[FunctionParamOverride]
    return_type: string.String
    mapping: string.String


public enum IncludeKind: ubyte
    include_all = 0
    include_list = 1


public struct AliasSpec:
    include_kind: IncludeKind
    include_list: vec.Vec[string.String]
    include_prefixes: vec.Vec[string.String]
    exclude: vec.Vec[string.String]
    overrides: vec.Vec[TypeOverride]
    rename_rules: vec.Vec[RenameRule]
    strip_prefix: string.String


public struct FunctionSpec:
    include_kind: IncludeKind
    include_list: vec.Vec[string.String]
    include_prefixes: vec.Vec[string.String]
    exclude: vec.Vec[string.String]
    overrides: vec.Vec[FunctionOverride]
    rename_rules: vec.Vec[RenameRule]
    strip_prefix: string.String


public struct MethodSpec:
    receiver_type: string.String
    receiver_types: vec.Vec[string.String]
    include_kind: IncludeKind
    include_list: vec.Vec[string.String]
    include_prefixes: vec.Vec[string.String]
    exclude: vec.Vec[string.String]
    rename_rules: vec.Vec[RenameRule]
    strip_prefix: string.String
    module_name: string.String
    module_import_alias: string.String


public struct BindingPolicy:
    module_name: string.String
    raw_module_name: string.String
    import_alias: string.String
    types: AliasSpec
    constants: AliasSpec
    functions: FunctionSpec
    methods: vec.Vec[MethodSpec]
    imports: vec.Vec[ImportSpec]


# =============================================================================
#  Release helpers
# =============================================================================

function release_strings(v: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_imports(v: ref[vec.Vec[ImportSpec]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_rename_rules(v: ref[vec.Vec[RenameRule]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_type_overrides(v: ref[vec.Vec[TypeOverride]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_function_overrides(v: ref[vec.Vec[FunctionOverride]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_method_specs(v: ref[vec.Vec[MethodSpec]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


extending ImportSpec:
    public editable function release() -> void:
        this.module_name.release()
        this.alias.release()


extending RenameRule:
    public editable function release() -> void:
        this.kind.release()
        this.pattern.release()
        this.replace_with.release()


extending TypeOverride:
    public editable function release() -> void:
        this.raw.release()
        this.name.release()
        this.mapping.release()
        this.override_kind.release()


extending FunctionParamOverride:
    public editable function release() -> void:
        this.name.release()
        this.param_type.release()
        this.mode.release()
        this.boundary_type.release()


extending FunctionOverride:
    public editable function release() -> void:
        this.raw.release()
        this.name.release()
        release_strings(ref_of(this.type_params))
        var i: ptr_uint = 0
        while i < this.params.len():
            let p = this.params.get(i)
            if p != null:
                unsafe: read(p).release()
            i += 1
        this.params.release()
        this.return_type.release()
        this.mapping.release()


extending AliasSpec:
    public editable function release() -> void:
        release_strings(ref_of(this.include_list))
        release_strings(ref_of(this.include_prefixes))
        release_strings(ref_of(this.exclude))
        release_type_overrides(ref_of(this.overrides))
        release_rename_rules(ref_of(this.rename_rules))
        this.strip_prefix.release()


extending FunctionSpec:
    public editable function release() -> void:
        release_strings(ref_of(this.include_list))
        release_strings(ref_of(this.include_prefixes))
        release_strings(ref_of(this.exclude))
        release_function_overrides(ref_of(this.overrides))
        release_rename_rules(ref_of(this.rename_rules))
        this.strip_prefix.release()


extending MethodSpec:
    public editable function release() -> void:
        this.receiver_type.release()
        release_strings(ref_of(this.receiver_types))
        release_strings(ref_of(this.include_list))
        release_strings(ref_of(this.include_prefixes))
        release_strings(ref_of(this.exclude))
        release_rename_rules(ref_of(this.rename_rules))
        this.strip_prefix.release()
        this.module_name.release()
        this.module_import_alias.release()


extending BindingPolicy:
    public editable function release() -> void:
        this.module_name.release()
        this.raw_module_name.release()
        this.import_alias.release()
        this.types.release()
        this.constants.release()
        this.functions.release()
        release_method_specs(ref_of(this.methods))
        release_imports(ref_of(this.imports))


# =============================================================================
#  JSON helpers
# =============================================================================

function obj_str(obj: ptr[json.Object], key: str, default: str) -> string.String:
    let result = obj_get_string(obj, key).unwrap_or(default)
    return string.String.from_str(result)


function obj_str_empty(obj: ptr[json.Object], key: str) -> string.String:
    return obj_str(obj, key, "")


function parse_str_list(obj: ptr[json.Object], key: str) -> vec.Vec[string.String]:
    var r = vec.Vec[string.String].create()
    let arr = obj_get_array(obj, key) else:
        return r
    var i: ptr_uint = 0
    while i < arr_len(arr):
        let str_opt = arr_get_string(arr, i)
        if str_opt.is_some():
            r.push(string.String.from_str(str_opt.unwrap()))
        i += 1
    return r


function parse_obj_list(obj: ptr[json.Object], key: str) -> vec.Vec[ptr[json.Object]]:
    var r = vec.Vec[ptr[json.Object]].create()
    let arr = obj_get_array(obj, key) else:
        return r
    var i: ptr_uint = 0
    while i < arr_len(arr):
        let objp = arr_get_object(arr, i)
        if objp != null:
            r.push(objp)
        i += 1
    return r


# =============================================================================
#  Section parsers
# =============================================================================

function parse_rename_rule(entry: ptr[json.Object]) -> RenameRule:
    return RenameRule(
        kind = obj_str_empty(entry, "kind"),
        pattern = obj_str_empty(entry, "match"),
        replace_with = obj_str_empty(entry, "replace_with"),
    )


function parse_rename_rules(obj: ptr[json.Object], key: str) -> vec.Vec[RenameRule]:
    var r = vec.Vec[RenameRule].create()
    var objs = parse_obj_list(obj, key)
    var i: ptr_uint = 0
    while i < objs.len():
        let ep = objs.get(i)
        if ep != null:
            unsafe: r.push(parse_rename_rule(read(ep)))
        i += 1
    objs.release()
    return r


function parse_type_override(entry: ptr[json.Object]) -> TypeOverride:
    return TypeOverride(
        raw = obj_str_empty(entry, "raw"),
        name = obj_str_empty(entry, "name"),
        mapping = obj_str_empty(entry, "mapping"),
        override_kind = obj_str_empty(entry, "kind"),
    )


function parse_type_overrides(obj: ptr[json.Object], key: str) -> vec.Vec[TypeOverride]:
    var r = vec.Vec[TypeOverride].create()
    var objs = parse_obj_list(obj, key)
    var i: ptr_uint = 0
    while i < objs.len():
        let ep = objs.get(i)
        if ep != null:
            unsafe: r.push(parse_type_override(read(ep)))
        i += 1
    objs.release()
    return r


function parse_function_param(entry: ptr[json.Object]) -> FunctionParamOverride:
    return FunctionParamOverride(
        name = obj_str_empty(entry, "name"),
        param_type = obj_str_empty(entry, "type"),
        mode = obj_str_empty(entry, "mode"),
        boundary_type = obj_str_empty(entry, "boundary_type"),
    )


function parse_function_params(obj: ptr[json.Object], key: str) -> vec.Vec[FunctionParamOverride]:
    var r = vec.Vec[FunctionParamOverride].create()
    var objs = parse_obj_list(obj, key)
    var i: ptr_uint = 0
    while i < objs.len():
        let ep = objs.get(i)
        if ep != null:
            unsafe: r.push(parse_function_param(read(ep)))
        i += 1
    objs.release()
    return r


function parse_function_override(entry: ptr[json.Object]) -> FunctionOverride:
    return FunctionOverride(
        raw = obj_str_empty(entry, "raw"),
        name = obj_str_empty(entry, "name"),
        type_params = parse_str_list(entry, "type_params"),
        params = parse_function_params(entry, "params"),
        return_type = obj_str_empty(entry, "return_type"),
        mapping = obj_str_empty(entry, "mapping"),
    )


function parse_function_overrides(obj: ptr[json.Object], key: str) -> vec.Vec[FunctionOverride]:
    var r = vec.Vec[FunctionOverride].create()
    var objs = parse_obj_list(obj, key)
    var i: ptr_uint = 0
    while i < objs.len():
        let ep = objs.get(i)
        if ep != null:
            unsafe: r.push(parse_function_override(read(ep)))
        i += 1
    objs.release()
    return r


function resolve_include(obj: ptr[json.Object], section_key: str, has_prefixes: bool, out_kind: ref[IncludeKind], out_list: ref[vec.Vec[string.String]]) -> void:
    let value_ptr = obj_get(obj, "include") else:
        if has_prefixes:
            read(out_kind) = IncludeKind.include_list
            return
        read(out_kind) = IncludeKind.include_all
        return

    let str_opt = unsafe: read(value_ptr).as_string()
    if str_opt.is_some():
        let s = str_opt.unwrap()
        if s.equal("all"):
            read(out_kind) = IncludeKind.include_all
            return
        read(out_kind) = IncludeKind.include_list
        read(out_list).push(string.String.from_str(s))
        return

    var l = parse_str_list(obj, "include")
    read(out_kind) = IncludeKind.include_list
    read(out_list) = l


function parse_alias_spec(root_obj: ptr[json.Object], key: str) -> AliasSpec:
    let section = obj_get_object(root_obj, key) else:
        return AliasSpec(
            include_kind = IncludeKind.include_all,
            include_list = vec.Vec[string.String].create(),
            include_prefixes = vec.Vec[string.String].create(),
            exclude = vec.Vec[string.String].create(),
            overrides = vec.Vec[TypeOverride].create(),
            rename_rules = vec.Vec[RenameRule].create(),
            strip_prefix = string.String.create(),
        )
    let prefixes = parse_str_list(section, "include_prefixes")
    var kind: IncludeKind = IncludeKind.include_all
    var list = vec.Vec[string.String].create()
    resolve_include(section, key, prefixes.len() != 0, ref_of(kind), ref_of(list))
    return AliasSpec(
        include_kind = kind,
        include_list = list,
        include_prefixes = prefixes,
        exclude = parse_str_list(section, "exclude"),
        overrides = parse_type_overrides(section, "overrides"),
        rename_rules = parse_rename_rules(section, "rename_rules"),
        strip_prefix = obj_str_empty(section, "strip_prefix"),
    )


function parse_function_spec(root_obj: ptr[json.Object], key: str) -> FunctionSpec:
    let section = obj_get_object(root_obj, key) else:
        return FunctionSpec(
            include_kind = IncludeKind.include_all,
            include_list = vec.Vec[string.String].create(),
            include_prefixes = vec.Vec[string.String].create(),
            exclude = vec.Vec[string.String].create(),
            overrides = vec.Vec[FunctionOverride].create(),
            rename_rules = vec.Vec[RenameRule].create(),
            strip_prefix = string.String.create(),
        )
    let prefixes = parse_str_list(section, "include_prefixes")
    var fkind: IncludeKind = IncludeKind.include_all
    var flist = vec.Vec[string.String].create()
    resolve_include(section, key, prefixes.len() != 0, ref_of(fkind), ref_of(flist))
    return FunctionSpec(
        include_kind = fkind,
        include_list = flist,
        include_prefixes = prefixes,
        exclude = parse_str_list(section, "exclude"),
        overrides = parse_function_overrides(section, "overrides"),
        rename_rules = parse_rename_rules(section, "rename_rules"),
        strip_prefix = obj_str_empty(section, "strip_prefix"),
    )


function parse_method_spec(entry: ptr[json.Object]) -> MethodSpec:
    var rtypes = parse_str_list(entry, "receiver_types")
    let rtype = obj_str_empty(entry, "type")
    if rtypes.len() == 0:
        rtypes.push(string.String.from_str(rtype.as_str()))

    let prefixes = parse_str_list(entry, "include_prefixes")
    var mkind: IncludeKind = IncludeKind.include_all
    var mlist = vec.Vec[string.String].create()
    resolve_include(entry, "method", prefixes.len() != 0, ref_of(mkind), ref_of(mlist))

    return MethodSpec(
        receiver_type = rtype,
        receiver_types = rtypes,
        include_kind = mkind,
        include_list = mlist,
        include_prefixes = prefixes,
        exclude = parse_str_list(entry, "exclude"),
        rename_rules = parse_rename_rules(entry, "rename_rules"),
        strip_prefix = obj_str_empty(entry, "strip_prefix"),
        module_name = obj_str_empty(entry, "module_name"),
        module_import_alias = obj_str_empty(entry, "module_import_alias"),
    )


function parse_method_specs(root_obj: ptr[json.Object], key: str) -> vec.Vec[MethodSpec]:
    var r = vec.Vec[MethodSpec].create()
    var objs = parse_obj_list(root_obj, key)
    var i: ptr_uint = 0
    while i < objs.len():
        let ep = objs.get(i)
        if ep != null:
            unsafe: r.push(parse_method_spec(read(ep)))
        i += 1
    objs.release()
    return r


function parse_import_spec(entry: ptr[json.Object]) -> ImportSpec:
    return ImportSpec(
        module_name = obj_str_empty(entry, "module_name"),
        alias = obj_str_empty(entry, "alias"),
    )


function parse_import_specs(root_obj: ptr[json.Object], key: str) -> vec.Vec[ImportSpec]:
    var r = vec.Vec[ImportSpec].create()
    var objs = parse_obj_list(root_obj, key)
    var i: ptr_uint = 0
    while i < objs.len():
        let ep = objs.get(i)
        if ep != null:
            unsafe: r.push(parse_import_spec(read(ep)))
        i += 1
    objs.release()
    return r


# =============================================================================
#  Public API
# =============================================================================

public function parse_policy(policy_path: str) -> Result[BindingPolicy, string.String]:
    match fs.read_text(policy_path):
        Result.failure as p:
            return Result[BindingPolicy, string.String].failure(
                error = string.String.from_str("policy: read failed")
            )
        Result.success as p:
            var content = p.value
            defer content.release()

            match json.parse(content.as_str()):
                Result.failure as jp:
                    return Result[BindingPolicy, string.String].failure(
                        error = string.String.from_str("policy: json parse failed")
                    )
                Result.success as jp:
                    let root = jp.value
                    defer json.release_value(root)

                    let obj_ptr = root.as_object()
                    if obj_ptr == null:
                        return Result[BindingPolicy, string.String].failure(
                            error = string.String.from_str("policy: root must be an object")
                        )

                    let policy_module_name = obj_str(obj_ptr, "module_name", "")
                    let policy_raw_module = obj_str(obj_ptr, "raw_module_name", "")
                    let import_alias = obj_str(obj_ptr, "raw_import_alias", "c")

                    # Validate identity
                    let mod_name_str = obj_str(obj_ptr, "module_name", "")
                    if mod_name_str.len() == 0:
                        return Result[BindingPolicy, string.String].failure(
                            error = string.String.from_str("policy: module_name is required")
                        )

                    return Result[BindingPolicy, string.String].success(value = BindingPolicy(
                        module_name = obj_str(obj_ptr, "module_name", ""),
                        raw_module_name = obj_str(obj_ptr, "raw_module_name", ""),
                        import_alias = obj_str(obj_ptr, "raw_import_alias", "c"),
                        types = parse_alias_spec(obj_ptr, "types"),
                        constants = parse_alias_spec(obj_ptr, "constants"),
                        functions = parse_function_spec(obj_ptr, "functions"),
                        methods = parse_method_specs(obj_ptr, "methods"),
                        imports = parse_import_specs(obj_ptr, "imports"),
                    ))
