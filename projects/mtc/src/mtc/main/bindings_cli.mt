## Binding-module commands — `mtc bindgen` and `mtc imported-bindings`.
## Extracted from main.mt.

import std.fs as fs
import std.json as json_mod
import std.map as map_mod
import std.path as path_ops
import std.str as str
import std.string as string
import std.stdio as stdio
import std.vec as vec

import mtc.loader.module_loader as loader
import mtc.bindgen as bindgen
import mtc.bindgen.nullable_policy as nullable_policy
import mtc.bindgen.options_json as options_json
import mtc.imported_bindings.registry as ib_registry
import mtc.imported_bindings.main as ib_main
import mtc.cli_help as cli_help
import mtc.main as main
import mtc.main.std_cli as std_cli

struct BindgenCliArgs:
    output: Option[str]
    nullable_report: Option[str]
    nullable_policy_path: Option[str]
    options_json_path: Option[str]
    link_libs: vec.Vec[str]
    includes: vec.Vec[str]
    clang_args: vec.Vec[str]
    clang_str: str

struct BindgenCliError:
    message: string.String
    show_help: bool


## Generate a binding module from a C header.
## Usage: mtc bindgen MODULE HEADER [-o OUTPUT] [--link LIB] [--include HEADER] [--clang PATH]
public function bindgen_command(args: span[str]) -> int:
    # The host consumes the first two operands as MODULE and HEADER before it
    # parses any option (`BindgenCLI#start`), so options must follow them.
    if args.len < 3:
        main.eprint_line("missing module name or header path")
        let _ = cli_help.print_command_help("bindgen", true)
        return 1
    let mod_name = args[1]
    let header_path = args[2]

    var parsed: BindgenCliArgs
    match parse_bindgen_args(args):
        Result.failure as parse_failure:
            var parse_error = parse_failure.error
            main.eprint_line(parse_error.message.as_str())
            parse_error.message.release()
            if parse_error.show_help:
                let _ = cli_help.print_command_help("bindgen", true)
            return 1
        Result.success as parse_payload:
            parsed = parse_payload.value

    var policy: nullable_policy.NullablePolicy
    match load_bindgen_policy(parsed.nullable_policy_path):
        Result.failure as load_failure:
            main.eprint_line(load_failure.error.as_str())
            load_failure.error.release()
            parsed.link_libs.release()
            parsed.includes.release()
            parsed.clang_args.release()
            return 1
        Result.success as policy_payload:
            policy = policy_payload.value
    defer: policy.release()

    var header_abs = loader.absolute_path(header_path)
    defer: header_abs.release()

    var opts = bindgen.BindgenOptions(
        module_name = string.String.from_str(mod_name),
        header_path = string.String.from_str(header_abs.as_str()),
        output_path = parsed.output,
        link_libs = parsed.link_libs,
        include_headers = parsed.includes,
        clang_bin = parsed.clang_str,
        clang_args = parsed.clang_args,
        return_overrides = policy.return_overrides,
        param_overrides = policy.param_overrides,
        report_header_path = header_abs.as_str(),
        bindgen_defines = vec.Vec[str].create(),
        bindgen_include_directives = vec.Vec[str].create(),
        module_imports = vec.Vec[bindgen.ModuleImport].create(),
        tracked_header_paths = vec.Vec[str].create(),
        tracked_header_prefixes = vec.Vec[str].create(),
        declaration_name_prefixes = vec.Vec[str].create(),
        excluded_declaration_names = vec.Vec[str].create(),
        type_name_overrides = map_mod.Map[str, str].create(),
        type_overrides = map_mod.Map[str, str].create(),
        function_param_type_overrides = map_mod.Map[str, map_mod.Map[str, str]].create(),
        function_return_type_overrides = map_mod.Map[str, str].create(),
        field_type_overrides = map_mod.Map[str, map_mod.Map[str, str]].create(),
        allow_static_inline_functions = false,
        strip_leading_underscores = false,
    )
    defer: opts.module_name.release()
    defer: opts.header_path.release()
    var options_root: ptr[json_mod.Value]? = null
    defer: release_options_root(options_root)
    match parsed.options_json_path:
        Option.some as options_path:
            match options_json.load_options_json(options_path.value, ref_of(opts)):
                Result.success as loaded_root:
                    options_root = loaded_root.value
                Result.failure as load_failure:
                    let message = load_failure.error.as_str()
                    main.eprint_line(message)
                    load_failure.error.release()
                    return 1
        Option.none:
            pass

    if parsed.nullable_report.is_some():
        let report_arg = parsed.nullable_report.unwrap()
        var report_path = loader.absolute_path(report_arg)
        defer: report_path.release()
        return run_bindgen_with_report(ref_of(opts), header_path, parsed.output, report_path.as_str())
    return run_bindgen_with_output(ref_of(opts), header_path, parsed.output)


function parse_bindgen_args(args: span[str]) -> Result[BindgenCliArgs, BindgenCliError]:
    var output: Option[str] = Option[str].none
    var nullable_report: Option[str] = Option[str].none
    var nullable_policy_path: Option[str] = Option[str].none
    var options_json_path: Option[str] = Option[str].none
    var link_libs = vec.Vec[str].create()
    var includes = vec.Vec[str].create()
    var clang_args = vec.Vec[str].create()
    var clang_str: str = ""

    var ai: ptr_uint = 3
    while ai < args.len:
        let arg = args[ai]
        if arg == "-o" or arg == "--output":
            ai += 1
            if ai >= args.len:
                return bindgen_cli_failure(
                    ref_of(link_libs),
                    ref_of(includes),
                    ref_of(clang_args),
                    "missing value for -o",
                    true
                )
            output = Option[str].some(value = args[ai])
        else if arg == "--link":
            ai += 1
            if ai >= args.len:
                return bindgen_cli_failure(
                    ref_of(link_libs),
                    ref_of(includes),
                    ref_of(clang_args),
                    "missing value for --link",
                    true
                )
            link_libs.push(args[ai])
        else if arg == "--include":
            ai += 1
            if ai >= args.len:
                return bindgen_cli_failure(
                    ref_of(link_libs),
                    ref_of(includes),
                    ref_of(clang_args),
                    "missing value for --include",
                    true
                )
            includes.push(args[ai])
        else if arg == "--clang":
            ai += 1
            if ai >= args.len:
                return bindgen_cli_failure(
                    ref_of(link_libs),
                    ref_of(includes),
                    ref_of(clang_args),
                    "missing value for --clang",
                    true
                )
            clang_str = args[ai]
        else if arg == "--clang-arg":
            ai += 1
            if ai >= args.len:
                return bindgen_cli_failure(
                    ref_of(link_libs),
                    ref_of(includes),
                    ref_of(clang_args),
                    "missing value for --clang-arg",
                    true
                )
            clang_args.push(args[ai])
        else if arg == "--nullable-report":
            ai += 1
            if ai >= args.len:
                return bindgen_cli_failure(
                    ref_of(link_libs),
                    ref_of(includes),
                    ref_of(clang_args),
                    "missing value for --nullable-report",
                    true
                )
            nullable_report = Option[str].some(value = args[ai])
        else if arg == "--nullable-policy":
            ai += 1
            if ai >= args.len:
                return bindgen_cli_failure(
                    ref_of(link_libs),
                    ref_of(includes),
                    ref_of(clang_args),
                    "missing value for --nullable-policy",
                    true
                )
            nullable_policy_path = Option[str].some(value = args[ai])
        else if arg == "--options-json":
            ai += 1
            if ai >= args.len:
                return bindgen_cli_failure(
                    ref_of(link_libs),
                    ref_of(includes),
                    ref_of(clang_args),
                    "bindgen: --options-json requires a path",
                    false
                )
            options_json_path = Option[str].some(value = args[ai])
        else:
            var unknown_opt = string.String.create()
            defer: unknown_opt.release()
            unknown_opt.append("unknown bindgen option ")
            unknown_opt.append(arg)
            return bindgen_cli_failure(
                ref_of(link_libs),
                ref_of(includes),
                ref_of(clang_args),
                unknown_opt.as_str(),
                true
            )
        ai += 1

    return Result[BindgenCliArgs, BindgenCliError].success(
        value = BindgenCliArgs(
            output = output,
            nullable_report = nullable_report,
            nullable_policy_path = nullable_policy_path,
            options_json_path = options_json_path,
            link_libs = link_libs,
            includes = includes,
            clang_args = clang_args,
            clang_str = clang_str,
        )
    )


function bindgen_cli_failure(
    link_libs: ref[vec.Vec[str]],
    includes: ref[vec.Vec[str]],
    clang_args: ref[vec.Vec[str]],
    message: str,
    show_help: bool,
) -> Result[BindgenCliArgs, BindgenCliError]:
    var owned = string.String.from_str(message)
    link_libs.release()
    includes.release()
    clang_args.release()
    return Result[BindgenCliArgs, BindgenCliError].failure(
        error = BindgenCliError(message = owned, show_help = show_help)
    )


function load_bindgen_policy(policy_path: Option[str]) -> Result[nullable_policy.NullablePolicy, string.String]:
    match policy_path:
        Option.some as path_payload:
            return nullable_policy.load_nullable_policy(path_payload.value)
        Option.none:
            return Result[nullable_policy.NullablePolicy, string.String].success(
                value = nullable_policy.NullablePolicy(
                    return_overrides = vec.Vec[bindgen.TypeOverride].create(),
                    param_overrides = vec.Vec[bindgen.ParamOverride].create(),
                )
            )


function run_bindgen_with_report(
    opts: ref[bindgen.BindgenOptions],
    header_path: str,
    output: Option[str],
    report_path: str,
) -> int:
    match bindgen.generate_with_report(opts):
        Result.success as generated:
            var generated_output = generated.value
            defer: generated_output.source.release()
            defer: generated_output.report.release()
            if not write_nullable_report(report_path, generated_output.report.as_str()):
                return 1
            match output:
                Option.some as out_file:
                    if not write_generated_source(out_file.value, generated_output.source.as_str()):
                        return 1
                    print_generated(header_path, out_file.value)
                    stdio.print_format(c"nullable report %.*s -> %.*s\n",
                        int<-(header_path.len), header_path.data,
                        int<-(report_path.len), report_path.data)
                Option.none:
                    let st = generated_output.source.as_str()
                    stdio.print_format(c"%.*s", int<-(st.len), st.data)
                    var wrote = string.String.create()
                    defer: wrote.release()
                    wrote.append("wrote nullable report ")
                    wrote.append(report_path)
                    main.eprint_line(wrote.as_str())
            return 0
        Result.failure as failure:
            let mt = failure.error.as_str()
            main.eprint_line(mt)
            failure.error.release()
            return 1


function run_bindgen_with_output(
    opts: ref[bindgen.BindgenOptions],
    header_path: str,
    output: Option[str],
) -> int:
    match bindgen.generate(opts):
        Result.success as generated:
            var source = generated.value
            defer: source.release()
            match output:
                Option.some as out_file:
                    if not write_generated_source(out_file.value, source.as_str()):
                        return 1
                    print_generated(header_path, out_file.value)
                Option.none:
                    let st = source.as_str()
                    stdio.print_format(c"%.*s", int<-(st.len), st.data)
            return 0
        Result.failure as failure:
            let mt = failure.error.as_str()
            main.eprint_line(mt)
            failure.error.release()
            return 1


function write_generated_source(path: str, source: str) -> bool:
    match fs.write_text(path, source):
        Result.success:
            return true
        Result.failure:
            stdio.print_line("bindgen: could not write output file")
            return false


function print_generated(header_path: str, out_path: str) -> void:
    stdio.print_format(c"generated %.*s -> %.*s\n",
        int<-(header_path.len), header_path.data,
        int<-(out_path.len), out_path.data)


function release_options_root(root: ptr[json_mod.Value]?) -> void:
    let r = root else:
        return
    options_json.release_options_json(r)


## Write the nullable-policy report, creating its parent directory.  Reports a
## write failure on stderr (the host raises through the CLI error formatter).
function write_nullable_report(path: str, report: str) -> bool:
    let parent = path_ops.dirname(path)
    match fs.create_directories(parent):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            main.eprint_line(dir_error.message.as_str())
            dir_error.release()
            return false
        Result.success:
            pass
    match fs.write_text(path, report):
        Result.failure as write_failure:
            var write_error = write_failure.error
            main.eprint_line(write_error.message.as_str())
            write_error.release()
            return false
        Result.success:
            return true

const IB_MODE_WRITE: int = 0
const IB_MODE_CHECK: int = 1
const IB_MODE_STDOUT: int = 2

const IB_OK: int = 0
const IB_FAILED: int = 1
const IB_CHANGED: int = 2
const IB_NEW: int = 3


## Outcome of generating one imported binding.  `first_diff_*` are meaningful
## only for a check-mode status of `IB_CHANGED`.
struct IbOutcome:
    status: int
    first_diff_offset: ptr_uint
    first_diff_line: ptr_uint


## Regenerate imported binding modules from raw C bindings and JSON policies.
public function imported_bindings_command(args: span[str]) -> int:
    var do_all = false
    var do_check = false
    var do_soft = false
    var do_stdout = false
    var json_path: str = ""
    var lib_name: str = ""

    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--all":
            do_all = true
        else if arg == "--check":
            do_check = true
        else if arg == "--soft":
            do_soft = true
        else if arg == "--stdout":
            do_stdout = true
        else if arg == "--json":
            if ai + 1 >= args.len:
                stdio.print_line("imported-bindings: missing value for --json")
                return 1
            ai += 1
            json_path = args[ai]
        else if arg == "--help" or arg == "-h":
            stdio.print_line("usage: mtc imported-bindings <name>|--all [--check|--stdout] [--json PATH] [--soft]")
            return 0
        else if lib_name.len == 0:
            lib_name = arg
        else:
            stdio.print_format(c"imported-bindings: unexpected argument '%.*s'\n", int<-(arg.len), arg.data)
            return 1
        ai += 1

    if do_soft and not do_check:
        stdio.print_line("imported-bindings: --soft requires --check")
        return 1
    if do_stdout and do_all:
        stdio.print_line("imported-bindings: --stdout requires a single library name")
        return 1
    if do_stdout and do_check:
        stdio.print_line("imported-bindings: --stdout and --check are mutually exclusive")
        return 1

    var mode = IB_MODE_WRITE
    if do_check:
        mode = IB_MODE_CHECK
    else if do_stdout:
        mode = IB_MODE_STDOUT

    var total: ptr_uint = 0
    var verified: ptr_uint = 0
    var changed: ptr_uint = 0
    var created: ptr_uint = 0
    var failed: ptr_uint = 0
    var json_entries = string.String.create()
    var json_first = true

    if do_all:
        var i: ptr_uint = 0
        while i < ib_registry.ALL_COUNT:
            let entry_ptr = get(ib_registry.ALL, i) else:
                break
            let entry = unsafe: read(entry_ptr)
            let outcome = regenerate_one(entry.policy_path, entry.binding_path, entry.raw_module_name, mode)
            total += 1
            if outcome.status == IB_OK:
                verified += 1
            else if outcome.status == IB_CHANGED:
                changed += 1
            else if outcome.status == IB_NEW:
                created += 1
            else:
                failed += 1
            if json_path.len > 0:
                append_ib_json_entry(ref_of(json_entries), ref_of(json_first),
                    entry.name, entry.binding_path, outcome, mode)
            i += 1
    else:
        if lib_name.len == 0:
            stdio.print_line("imported-bindings: missing library name or --all")
            json_entries.release()
            return 1

        let entry = find_ib_entry(lib_name) else:
            stdio.print_format(c"imported-bindings: unknown library '%.*s'\n", int<-(lib_name.len), lib_name.data)
            json_entries.release()
            return 1

        let outcome = regenerate_one(entry.policy_path, entry.binding_path, entry.raw_module_name, mode)
        total = 1
        if outcome.status == IB_OK:
            verified = 1
        else if outcome.status == IB_CHANGED:
            changed = 1
        else if outcome.status == IB_NEW:
            created = 1
        else:
            failed = 1
        if json_path.len > 0:
            append_ib_json_entry(ref_of(json_entries), ref_of(json_first),
                entry.name, entry.binding_path, outcome, mode)

    if json_path.len > 0:
        var json = string.String.create()
        json.append("{\"bindings\":[")
        json.append(json_entries.as_str())
        json.append("],\"summary\":{\"total\":")
        json.append(main.ptr_uint_to_str(total))
        json.append(",\"verified\":")
        json.append(main.ptr_uint_to_str(verified))
        json.append(",\"changed\":")
        json.append(main.ptr_uint_to_str(changed))
        json.append(",\"new\":")
        json.append(main.ptr_uint_to_str(created))
        json.append(",\"failed\":")
        json.append(main.ptr_uint_to_str(failed))
        json.append("}}\n")
        match fs.write_text(json_path, json.as_str()):
            Result.failure as write_failure:
                var write_error = write_failure.error
                stdio.print_format(c"imported-bindings: could not write %.*s\n", int<-(json_path.len), json_path.data)
                write_error.release()
                json.release()
                json_entries.release()
                return 1
            Result.success:
                pass
        json.release()
    json_entries.release()

    if do_all:
        if mode == IB_MODE_CHECK:
            stdio.print_format(c"verified %d / changed %d / new %d of %d\n",
                int<-verified, int<-changed, int<-created, int<-total)
        else:
            stdio.print_format(c"generated %d imported bindings\n", int<-total)
    if failed > 0:
        stdio.print_format(c"%d binding(s) failed\n", int<-failed)
        return 1
    if mode == IB_MODE_CHECK and (changed + created) > 0 and not do_soft:
        return 1
    return 0


function append_ib_json_entry(
    buf: ref[string.String],
    first: ref[bool],
    name: str,
    path: str,
    outcome: IbOutcome,
    mode: int,
) -> void:
    if not read(first):
        buf.push_byte(',')
    read(first) = false
    buf.append("{\"name\":")
    std_cli.append_json_string(buf, name)
    buf.append(",\"path\":")
    std_cli.append_json_string(buf, path)
    buf.append(",\"status\":")
    std_cli.append_json_string(buf, ib_status_label(outcome.status, mode))
    buf.append(",\"first_diff_offset\":")
    buf.append(main.ptr_uint_to_str(outcome.first_diff_offset))
    buf.append(",\"first_diff_line\":")
    buf.append(main.ptr_uint_to_str(outcome.first_diff_line))
    buf.push_byte('}')


function ib_status_label(status: int, mode: int) -> str:
    if status == IB_CHANGED:
        return "changed"
    if status == IB_NEW:
        return "new"
    if status == IB_FAILED:
        return "failed"
    if mode == IB_MODE_CHECK:
        return "verified"
    return "generated"


function first_diff_offset(new_src: str, old_src: str) -> ptr_uint:
    var limit = new_src.len
    if old_src.len < limit:
        limit = old_src.len
    var i: ptr_uint = 0
    while i < limit:
        if new_src.byte_at(i) != old_src.byte_at(i):
            return i
        i += 1
    return limit


function line_at_offset(text: str, offset: ptr_uint) -> ptr_uint:
    var line: ptr_uint = 1
    var i: ptr_uint = 0
    while i < offset and i < text.len:
        if text.byte_at(i) == 10:
            line += 1
        i += 1
    return line


function find_ib_entry(name: str) -> Option[ib_registry.BindingEntry]:
    var i: ptr_uint = 0
    while i < ib_registry.ALL_COUNT:
        let entry_ptr = get(ib_registry.ALL, i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if entry.name.equal(name):
            return Option[ib_registry.BindingEntry].some(value = entry)
        i += 1
    return Option[ib_registry.BindingEntry].none


function regenerate_one(policy_path: str, output_path: str, raw_module_name: str, mode: int) -> IbOutcome:
    # Resolve raw module path: std.c.raymath -> std/c/raymath.mt
    var raw_buf = string.String.with_capacity(raw_module_name.len + 3)
    var ri: ptr_uint = 0
    while ri < raw_module_name.len:
        let ch = raw_module_name.byte_at(ri)
        if ch == '.':
            raw_buf.push_byte('/')
        else:
            raw_buf.push_byte(ch)
        ri += 1
    raw_buf.append(".mt")
    let raw_path = raw_buf.as_str()

    match ib_main.generate(policy_path, raw_path):
        Result.failure as p:
            if mode == IB_MODE_STDOUT:
                var message = string.String.create()
                message.append("imported-bindings: ")
                message.append(p.error.as_str())
                main.eprint_line(message.as_str())
                message.release()
            else:
                stdio.print_format(c"imported-bindings: %.*s\n", int<-(p.error.as_str().len), p.error.as_str().data)
            p.error.release()
            raw_buf.release()
            return IbOutcome(status = IB_FAILED, first_diff_offset = 0, first_diff_line = 0)
        Result.success as p:
            if mode == IB_MODE_STDOUT:
                stdio.print_format(c"%.*s", int<-(p.value.as_str().len), p.value.as_str().data)
                p.value.release()
                raw_buf.release()
                return IbOutcome(status = IB_OK, first_diff_offset = 0, first_diff_line = 0)

            if mode == IB_MODE_CHECK:
                var status = IB_OK
                var diff_offset: ptr_uint = 0
                var diff_line: ptr_uint = 0
                match fs.read_text(output_path):
                    Result.failure:
                        stdio.print_format(c"(new) %.*s would be generated\n", int<-(output_path.len), output_path.data)
                        status = IB_NEW
                    Result.success as existing:
                        let new_src = p.value.as_str()
                        let old_src = existing.value.as_str()
                        if new_src.equal(old_src):
                            stdio.print_format(c"verified %.*s\n", int<-(output_path.len), output_path.data)
                        else:
                            diff_offset = first_diff_offset(new_src, old_src)
                            diff_line = line_at_offset(new_src, diff_offset)
                            stdio.print_format(c"changed %.*s\n", int<-(output_path.len), output_path.data)
                            status = IB_CHANGED
                        existing.value.release()
                p.value.release()
                raw_buf.release()
                return IbOutcome(status = status, first_diff_offset = diff_offset, first_diff_line = diff_line)

            match fs.write_text(output_path, p.value.as_str()):
                Result.failure:
                    stdio.print_format(
                        c"imported-bindings: could not write %.*s\n",
                        int<-(output_path.len),
                        output_path.data
                    )
                    p.value.release()
                    raw_buf.release()
                    return IbOutcome(status = IB_FAILED, first_diff_offset = 0, first_diff_line = 0)
                Result.success:
                    stdio.print_format(c"generated %.*s + %.*s -> %.*s\n",
                        int<-(raw_module_name.len), raw_module_name.data,
                        int<-(policy_path.len), policy_path.data,
                        int<-(output_path.len), output_path.data)
            p.value.release()
            raw_buf.release()
            return IbOutcome(status = IB_OK, first_diff_offset = 0, first_diff_line = 0)
