## Nullable policy report — the JSON summary of parameter/return overrides and
## their automatically inferred types.  Extracted from bindgen.mt.

import std.str
import std.string as string
import std.vec as vec

import mtc.bindgen as bindgen
import mtc.bindgen.nullable_policy as nullable_policy


struct ReportParamEntry:
    function: str
    parameter: str
    override_type: str
    auto_type: string.String
    c_type: str

struct ReportReturnEntry:
    function: str
    override_type: str
    auto_type: string.String
    c_type: str


function report_param_compare(left: ptr[ReportParamEntry], right: ptr[ReportParamEntry]) -> int:
    let l = unsafe: read(left)
    let r = unsafe: read(right)
    let by_function = l.function.compare(r.function)
    if by_function != 0:
        return by_function
    return l.parameter.compare(r.parameter)


function report_return_compare(left: ptr[ReportReturnEntry], right: ptr[ReportReturnEntry]) -> int:
    return unsafe: read(left).function.compare(unsafe: read(right).function)


function release_param_entries(entries: ref[vec.Vec[ReportParamEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        unsafe:
            read(entry_ptr).auto_type.release()
        i += 1
    entries.release()


function release_return_entries(entries: ref[vec.Vec[ReportReturnEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        unsafe:
            read(entry_ptr).auto_type.release()
        i += 1
    entries.release()

## The host's `nullable_policy_report`: manually overridden entries whose type
## actually differs from the automatic mapping, sorted for stable output.

public function build_nullable_report(
    target: ref[string.String],
    opts: ref[bindgen.BindgenOptions],
    decls: ref[vec.Vec[bindgen.CDecl]]
) -> void:
    var param_entries = vec.Vec[ReportParamEntry].create()
    defer: release_param_entries(ref_of(param_entries))
    var return_entries = vec.Vec[ReportReturnEntry].create()
    defer: release_return_entries(ref_of(return_entries))

    var pi: ptr_uint = 0
    while pi < opts.param_overrides.len():
        let entry_ptr = opts.param_overrides.get(pi) else:
            break
        let entry = unsafe: read(entry_ptr)
        let override_type = entry.ty.as_str()
        if not override_type.contains_substring("?"):
            pi += 1
            continue
        match nullable_policy.find_function_decl(decls, entry.function.as_str()):
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match nullable_policy.param_index_of(d.param_names, entry.parameter.as_str()):
                    Option.some as index:
                        match nullable_policy.function_sig_text(d.qual_type.as_str()):
                            Option.some as sig_payload:
                                let c_type = nullable_policy.param_type_text_at(sig_payload.value.params_text, index.value)
                                var auto_type = bindgen.map_type(c_type, opts)
                                if auto_type.as_str().equal(override_type):
                                    auto_type.release()
                                else:
                                    param_entries.push(ReportParamEntry(

                                        function = entry.function.as_str(),
                                        parameter = entry.parameter.as_str(),
                                        override_type = override_type,
                                        auto_type = auto_type,
                                        c_type = c_type,
                                    ))
                            Option.none:
                                pass
                    Option.none:
                        pass
            Option.none:
                pass
        pi += 1

    var ri: ptr_uint = 0
    while ri < opts.return_overrides.len():
        let entry_ptr = opts.return_overrides.get(ri) else:
            break
        let entry = unsafe: read(entry_ptr)
        let override_type = entry.ty.as_str()
        if not override_type.contains_substring("?"):
            ri += 1
            continue
        match nullable_policy.find_function_decl(decls, entry.function.as_str()):
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match nullable_policy.function_sig_text(d.qual_type.as_str()):
                    Option.some as sig_payload:
                        let c_type = sig_payload.value.return_text
                        var auto_type = bindgen.map_type(c_type, opts)
                        if auto_type.as_str().equal(override_type):
                            auto_type.release()
                        else:
                            return_entries.push(ReportReturnEntry(

                                function = entry.function.as_str(),
                                override_type = override_type,
                                auto_type = auto_type,
                                c_type = c_type,
                            ))
                    Option.none:
                        pass
            Option.none:
                pass
        ri += 1

    param_entries.sort_by(report_param_compare)
    return_entries.sort_by(report_return_compare)

    let report_header = if opts.report_header_path.len > 0: opts.report_header_path else: opts.header_path.as_str()
    target.append("{\n  \"module_name\": ")
    append_json_string(target, opts.module_name.as_str())
    target.append(",\n  \"header_path\": ")
    append_json_string(target, report_header)
    target.append(",\n  \"summary\": {\n    \"parameters\": ")
    target.append(bindgen.uint_to_str(param_entries.len()))
    target.append(",\n    \"return_types\": ")
    target.append(bindgen.uint_to_str(return_entries.len()))
    target.append(",\n    \"total\": ")
    target.append(bindgen.uint_to_str(param_entries.len() + return_entries.len()))
    target.append("\n  },\n  \"manual_nullable_policy\": {\n    \"parameters\": ")
    append_param_entries_json(target, ref_of(param_entries))
    target.append(",\n    \"return_types\": ")
    append_return_entries_json(target, ref_of(return_entries))
    target.append("\n  }\n}")


function append_param_entries_json(target: ref[string.String], entries: ref[vec.Vec[ReportParamEntry]]) -> void:
    if entries.len() == 0:
        target.append("[]")
        return
    target.append("[\n")
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if i > 0:
            target.append(",\n")
        target.append("      {\n        \"function\": ")
        append_json_string(target, entry.function)
        target.append(",\n        \"parameter\": ")
        append_json_string(target, entry.parameter)
        target.append(",\n        \"override_type\": ")
        append_json_string(target, entry.override_type)
        target.append(",\n        \"auto_type\": ")
        append_json_string(target, entry.auto_type.as_str())
        target.append(",\n        \"c_type\": ")
        append_json_string(target, entry.c_type)
        target.append("\n      }")
        i += 1
    target.append("\n    ]")


function append_return_entries_json(target: ref[string.String], entries: ref[vec.Vec[ReportReturnEntry]]) -> void:
    if entries.len() == 0:
        target.append("[]")
        return
    target.append("[\n")
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if i > 0:
            target.append(",\n")
        target.append("      {\n        \"function\": ")
        append_json_string(target, entry.function)
        target.append(",\n        \"override_type\": ")
        append_json_string(target, entry.override_type)
        target.append(",\n        \"auto_type\": ")
        append_json_string(target, entry.auto_type.as_str())
        target.append(",\n        \"c_type\": ")
        append_json_string(target, entry.c_type)
        target.append("\n      }")
        i += 1
    target.append("\n    ]")


function hex_digit(value: ubyte) -> ubyte:
    if value < 10:
        return value + '0'
    return value - 10 + 'a'


function append_json_string(target: ref[string.String], value: str) -> void:
    target.push_byte(34)
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b == 34:
            target.append("\\\"")
        else if b == 92:
            target.append("\\\\")
        else if b == 10:
            target.append("\\n")
        else if b == 13:
            target.append("\\r")
        else if b == 9:
            target.append("\\t")
        else if b < 32:
            target.append("\\u00")
            target.push_byte(hex_digit(b / 16))
            target.push_byte(hex_digit(b % 16))
        else:
            target.push_byte(b)
        i += 1
    target.push_byte(34)
