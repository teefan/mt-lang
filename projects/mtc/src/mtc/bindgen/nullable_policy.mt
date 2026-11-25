## Nullable policy overrides — signature/parameter parsing, override lookup,
## target validation, policy file loading, and the policy type.  Extracted from
## bindgen.mt.

import std.str
import std.string as string
import std.vec as vec
import std.json as json
import std.fs as fs

import mtc.bindgen as bindgen

## A clang `qualType` function signature split into its return-type text and the
## parameter-list text (without the surrounding parentheses).

public struct FunctionSigText:
    return_text: str
    params_text: str


public function function_sig_text(qual_type: str) -> Option[FunctionSigText]:
    if qual_type.len == 0 or qual_type.byte_at(qual_type.len - 1) != ')':
        return Option[FunctionSigText].none
    var open: ptr_uint = 0
    var depth = 0
    var found = false
    var close: ptr_uint = 0
    var i: ptr_uint = 0
    while i < qual_type.len:
        let b = qual_type.byte_at(i)
        if b == '(' and depth == 0 and not found:
            open = i
            depth = 1
            found = true
        else if b == '(':
            depth += 1
        else if b == ')':
            depth -= 1
            if found and depth == 0:
                close = i
                break
        i += 1
    if not found:
        return Option[FunctionSigText].none
    return Option[FunctionSigText].some(value = FunctionSigText(
        return_text = bindgen.str_strip(qual_type.slice(0, open)),
        params_text = qual_type.slice(open + 1, close - open - 1),
    ))

## The type text of the `index`-th top-level parameter in a parameter-list text.

public function param_type_text_at(params: str, index: ptr_uint) -> str:
    if params == "void" or params == "":
        return ""
    var comma: ptr_uint = 0
    var pd: ptr_uint = 0
    var an: ptr_uint = 0
    var j: ptr_uint = 0
    while j <= params.len:
        if j == params.len or (params.byte_at(j) == ',' and pd == 0):
            if an == index:
                return bindgen.str_strip(params.slice(comma, j - comma))
            comma = j + 1
            an += 1
        else if j < params.len:
            if params.byte_at(j) == '(':
                pd += 1
            if params.byte_at(j) == ')':
                pd -= 1
        j += 1
    return ""


public function find_type_override(overrides: span[bindgen.TypeOverride], function_name: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < overrides.len:
        let entry = unsafe: read(overrides.data + i)
        if entry.function.as_str().equal(function_name):
            return Option[str].some(value = entry.ty.as_str())
        i += 1
    return Option[str].none


public function find_param_override(
    overrides: span[bindgen.ParamOverride],
    function_name: str,
    parameter: str
) -> Option[str]:
    var i: ptr_uint = 0
    while i < overrides.len:
        let entry = unsafe: read(overrides.data + i)
        if entry.function.as_str().equal(function_name) and entry.parameter.as_str().equal(parameter):
            return Option[str].some(value = entry.ty.as_str())
        i += 1
    return Option[str].none


public function find_function_decl(
    decls: ref[vec.Vec[bindgen.CDecl]],
    function_name: str
) -> Option[ptr[bindgen.CDecl]]:
    var i: ptr_uint = 0
    while i < decls.len():
        let decl_ptr = decls.get(i) else:
            break
        let d = unsafe: read(decl_ptr)
        if d.kind.as_str().equal("function") and d.c_name.as_str().equal(function_name):
            return Option[ptr[bindgen.CDecl]].some(value = decl_ptr)
        i += 1
    return Option[ptr[bindgen.CDecl]].none


public function param_index_of(names: vec.Vec[string.String], parameter: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < names.len():
        let name_ptr = names.get(i) else:
            break
        if unsafe: read(name_ptr).as_str().equal(parameter):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none

## The host's override-target validation (`validate_function_param_type_overrides!`
## and `validate_function_return_type_overrides!`), with its exact messages.

public function validate_override_targets(
    decls: ref[vec.Vec[bindgen.CDecl]],
    opts: ref[bindgen.BindgenOptions]
) -> Option[string.String]:
    let header = opts.header_path.as_str()
    var pi: ptr_uint = 0
    while pi < opts.param_overrides.len():
        let entry_ptr = opts.param_overrides.get(pi) else:
            break
        let entry = unsafe: read(entry_ptr)
        match find_function_decl(decls, entry.function.as_str()):
            Option.none:
                var m = string.String.from_str("function_param_type_overrides references unknown function ")
                m.append(entry.function.as_str())
                m.append(" for ")
                m.append(header)
                return Option[string.String].some(value = m)
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match param_index_of(d.param_names, entry.parameter.as_str()):
                    Option.none:
                        var m = string.String.from_str("function_param_type_overrides references unknown parameter ")
                        m.append(entry.function.as_str())
                        m.append(".")
                        m.append(entry.parameter.as_str())
                        m.append(" for ")
                        m.append(header)
                        return Option[string.String].some(value = m)
                    Option.some:
                        pass
        pi += 1

    var ri: ptr_uint = 0
    while ri < opts.return_overrides.len():
        let entry_ptr = opts.return_overrides.get(ri) else:
            break
        let entry = unsafe: read(entry_ptr)
        match find_function_decl(decls, entry.function.as_str()):
            Option.none:
                var m = string.String.from_str("function_return_type_overrides references unknown function ")
                m.append(entry.function.as_str())
                m.append(" for ")
                m.append(header)
                return Option[string.String].some(value = m)
            Option.some:
                pass
        ri += 1
    return Option[string.String].none

# =============================================================================
#  Nullable policy file
# =============================================================================

public struct NullablePolicy:
    return_overrides: vec.Vec[bindgen.TypeOverride]
    param_overrides: vec.Vec[bindgen.ParamOverride]


extending NullablePolicy:
    public editable function release() -> void:
        release_type_overrides(ref_of(this.return_overrides))
        release_param_overrides(ref_of(this.param_overrides))


public function release_type_overrides(overrides: ref[vec.Vec[bindgen.TypeOverride]]) -> void:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            var entry = read(entry_ptr)
            entry.function.release()
            entry.ty.release()
        i += 1
    overrides.release()


public function release_param_overrides(overrides: ref[vec.Vec[bindgen.ParamOverride]]) -> void:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            var entry = read(entry_ptr)
            entry.function.release()
            entry.parameter.release()
            entry.ty.release()
        i += 1
    overrides.release()

## Load and validate a `--nullable-policy` JSON file, mirroring the host's
## `BindgenCLI#load_nullable_policy` messages.

public function load_nullable_policy(path: str) -> Result[NullablePolicy, string.String]:
    var text: string.String
    match fs.read_text(path):
        Result.failure:
            var m = string.String.from_str("nullable policy file not found: ")
            m.append(path)
            return Result[NullablePolicy, string.String].failure(error = m)
        Result.success as payload:
            text = payload.value
    defer: text.release()

    var parsed: json.Value
    match json.parse(text.as_str()):
        Result.failure as parse_failure:
            var error = parse_failure.error
            var m = string.String.from_str("nullable policy is not valid JSON: ")
            m.append(error.message.as_str())
            error.release()
            return Result[NullablePolicy, string.String].failure(error = m)
        Result.success as parsed_payload:
            parsed = parsed_payload.value
    defer: json.release_value(parsed)

    let object_ptr = parsed.as_object() else:
        return Result[NullablePolicy, string.String].failure(
            error = string.String.from_str("nullable policy must be a JSON object")
        )

    let root = unsafe: read(object_ptr)
    var unknown = string.String.create()
    defer: unknown.release()
    var unknown_count: ptr_uint = 0
    var ei: ptr_uint = 0
    while ei < root.entries.len():
        let entry_ptr = root.entries.get(ei) else:
            break
        let key = unsafe: read(entry_ptr).key.as_str()
        if not (key == "return_types" or key == "parameters"):
            if unknown_count > 0:
                unknown.append(", ")
            unknown.append(key)
            unknown_count += 1
        ei += 1
    if unknown_count > 0:
        var m = string.String.from_str("nullable policy has unknown keys: ")
        m.append(unknown.as_str())
        m.append(" (expected return_types, parameters)")
        return Result[NullablePolicy, string.String].failure(error = m)

    var return_overrides = vec.Vec[bindgen.TypeOverride].create()
    var param_overrides = vec.Vec[bindgen.ParamOverride].create()
    var shape_ok = true

    let return_types_ptr = root.get_object("return_types")
    if return_types_ptr != null:
        let return_types = unsafe: read(return_types_ptr)
        var ri: ptr_uint = 0
        while ri < return_types.entries.len():
            let entry_ptr = return_types.entries.get(ri) else:
                break
            let entry = unsafe: read(entry_ptr)
            if entry.value.kind != json.ValueKind.string_:
                shape_ok = false
                break
            return_overrides.push(bindgen.TypeOverride(

                function = string.String.from_str(entry.key.as_str()),
                ty = string.String.from_str(entry.value.string_value.as_str()),
            ))
            ri += 1
    else if root.get("return_types") != null:
        shape_ok = false

    let parameters_ptr = root.get_object("parameters")
    if parameters_ptr != null:
        let parameters = unsafe: read(parameters_ptr)
        var pi: ptr_uint = 0
        while pi < parameters.entries.len() and shape_ok:
            let entry_ptr = parameters.entries.get(pi) else:
                break
            let entry = unsafe: read(entry_ptr)
            let inner_ptr = entry.value.object_value
            if inner_ptr == null:
                shape_ok = false
                break
            let inner = unsafe: read(inner_ptr)
            var ii: ptr_uint = 0
            while ii < inner.entries.len():
                let inner_entry_ptr = inner.entries.get(ii) else:
                    break
                let inner_entry = unsafe: read(inner_entry_ptr)
                if inner_entry.value.kind != json.ValueKind.string_:
                    shape_ok = false
                    break
                param_overrides.push(bindgen.ParamOverride(

                    function = string.String.from_str(entry.key.as_str()),
                    parameter = string.String.from_str(inner_entry.key.as_str()),
                    ty = string.String.from_str(inner_entry.value.string_value.as_str()),
                ))
                ii += 1
            pi += 1
    else if root.get("parameters") != null:
        shape_ok = false

    if not shape_ok:
        release_type_overrides(ref_of(return_overrides))
        release_param_overrides(ref_of(param_overrides))
        return Result[NullablePolicy, string.String].failure(error = string.String.from_str(
            "nullable policy must map {\"return_types\": {symbol: \"type?\"}, \"parameters\": {symbol: {param: \"type?\"}}}"
        ))

    return Result[NullablePolicy, string.String].success(value = NullablePolicy(
        return_overrides = return_overrides,
        param_overrides = param_overrides,
    ))
