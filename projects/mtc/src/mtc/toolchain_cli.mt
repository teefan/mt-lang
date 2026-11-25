## `mtc toolchain` — the host's ToolchainCLI
## (`lib/milk_tea/tooling/toolchain_cli.rb`):
##
##   bootstrap  clone the pinned vendored upstream sources under third_party/
##   doctor     report the local toolchain
##   tools      build the vendored tools (the Tracy profiler)
##
## `bootstrap`'s source table mirrors `UpstreamSources.default_sources`; the
## optional `config/upstream_versions.yml` overrides a source's revision and/or
## sentinel list, in the two YAML shapes the host accepts (`name: revision` and
## `name:` with an indented `revision:` / `sentinels:` block).

import std.env as env
import std.fs as fs
import std.path as path_ops
import std.process as process
import std.stdio as stdio
import std.str as str
import std.string as string
import std.terminal as terminal
import std.vec as vec

import mtc.cli_help as cli_help
import mtc.upstream_sources as upstream_sources
import mtc.toolchain_bindings as raw_bindings

## The CLI entry point; `args[0]` is the `toolchain` command name.
public function run(args: span[str]) -> int:
    var quiet = false
    var remaining = vec.Vec[str].create()
    defer: remaining.release()
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "-q" or arg == "--quiet":
            quiet = true
            ai += 1
            continue
        if arg == "--":
            ai += 1
            while ai < args.len:
                remaining.push(args[ai])
                ai += 1
            continue
        remaining.push(arg)
        ai += 1

    if remaining.len() == 0:
        eprint_line("missing toolchain subcommand")
        let _ = cli_help.print_command_help("toolchain", true)
        return 1

    let sub_ptr = remaining.get(0) else:
        return 1
    let sub = unsafe: read(sub_ptr)

    if sub == "--help" or sub == "-h":
        let _ = cli_help.print_command_help("toolchain", false)
        return 0

    if sub == "bootstrap":
        if reject_extra_options(ref_of(remaining)):
            return 1
        return bootstrap_command(quiet)
    if sub == "doctor":
        if reject_extra_options(ref_of(remaining)):
            return 1
        return doctor_command(quiet)
    if sub == "tools":
        if reject_extra_options(ref_of(remaining)):
            return 1
        return tools_command(quiet)

    var unknown_sub = string.String.create()
    defer: unknown_sub.release()
    unknown_sub.append("unknown toolchain subcommand ")
    unknown_sub.append(sub)
    eprint_line(unknown_sub.as_str())
    let _ = cli_help.print_command_help("toolchain", true)
    return 1


function reject_extra_options(remaining: ref[vec.Vec[str]]) -> bool:
    if remaining.len() <= 1:
        return false
    let extra_ptr = remaining.get(1) else:
        return false
    var message = string.String.create()
    defer: message.release()
    message.append("unknown toolchain option ")
    message.append(unsafe: read(extra_ptr))
    eprint_line(message.as_str())
    let _ = cli_help.print_command_help("toolchain", true)
    return true


function info(quiet: bool, message: str) -> void:
    if not quiet:
        stdio.print_line(message)


function eprint_line(text: str) -> void:
    let _ = terminal.write_stderr(text)
    let _ = terminal.write_stderr("\n")
    let _ = terminal.flush_stderr()


## Append `ESC[<code>m` to `target`.
function append_ansi(target: ref[string.String], code: str) -> void:
    target.push_byte(27)
    target.push_byte(91)
    target.append(code)
    target.push_byte(109)


## ── bootstrap ────────────────────────────────────────────────────────────────

function bootstrap_command(quiet: bool) -> int:
    let root_opt = upstream_sources.compiler_root()
    var data_root = upstream_sources.data_root_dir(root_opt)
    defer: data_root.release()

    var overrides = upstream_sources.load_overrides(data_root.as_str())
    defer: upstream_sources.release_overrides(ref_of(overrides))

    let total = upstream_sources.source_count()
    var header = string.String.create()
    defer: header.release()
    header.append("Bootstrapping ")
    header.append_format(f"#{total}")
    header.append(" vendored libraries...")
    info(quiet, header.as_str())
    info(quiet, "")

    var ok: ptr_uint = 0
    var skipped: ptr_uint = 0
    var failed: ptr_uint = 0

    var i: ptr_uint = 0
    while i < total:
        let src = upstream_sources.source_at(i)
        var checkout = path_ops.join(data_root.as_str(), src.dir)
        defer: checkout.release()
        let pinned = upstream_sources.revision_for(src, ref_of(overrides))
        let complete = upstream_sources.checkout_is_current(checkout.as_str(), src, pinned, ref_of(overrides))
        if complete:
            var present = string.String.create()
            defer: present.release()
            present.append("  ")
            present.append(src.name)
            present.append(" (already present)")
            info(quiet, present.as_str())
            skipped += 1
            i += 1
            continue

        var cloning = string.String.create()
        defer: cloning.release()
        cloning.append("  ")
        cloning.append(src.name)
        cloning.push_byte(32)
        append_ansi(ref_of(cloning), "2")
        cloning.append("cloning...")
        append_ansi(ref_of(cloning), "0")
        info(quiet, cloning.as_str())
        let _ = terminal.flush_stdout()

        let revision = upstream_sources.revision_for(src, ref_of(overrides))
        var failure_message = string.String.create()
        let bootstrapped = upstream_sources.bootstrap_source(
            checkout.as_str(), src.url, revision, src, ref_of(overrides), ref_of(failure_message)
        )

        var result_line = string.String.create()
        defer: result_line.release()
        result_line.push_byte(13)
        result_line.append("  ")
        result_line.append(src.name)
        result_line.push_byte(32)
        if bootstrapped:
            append_ansi(ref_of(result_line), "32")
            result_line.append("bootstrapped")
            append_ansi(ref_of(result_line), "0")
            info(quiet, result_line.as_str())
            ok += 1
        else:
            append_ansi(ref_of(result_line), "31")
            result_line.append("failed")
            append_ansi(ref_of(result_line), "0")
            info(quiet, result_line.as_str())
            var details = string.String.create()
            defer: details.release()
            details.append("    ")
            details.append(failure_message.as_str())
            eprint_line(details.as_str())
            failed += 1
        failure_message.release()
        i += 1

    info(quiet, "")
    var summary = string.String.create()
    defer: summary.release()
    summary.append_format(f"#{ok + skipped + failed}")
    summary.append(" source(s): ")
    summary.append_format(f"#{ok}")
    summary.append(" bootstrapped, ")
    summary.append_format(f"#{skipped}")
    summary.append(" skipped, ")
    summary.append_format(f"#{failed}")
    summary.append(" failed")
    info(quiet, summary.as_str())
    if failed > 0:
        return 1
    return 0


## The file a checkout records its own revision in.  Sentinels alone cannot
## detect a *version* change: every box2d release ships `include/box2d/box2d.h`,
## so a cached 3.1.1 tree satisfied the 3.2.0 pin's sentinel and was silently
## reused (the CI failure this guards).  The stamp makes a pin change visible.
const REVISION_STAMP: str = ".mt-source-revision"


## True when `checkout` records exactly `revision` in its stamp.
## ── tools ───────────────────────────────────────────────────────────────────

function tools_command(quiet: bool) -> int:
    let root_opt = upstream_sources.compiler_root()
    var data_root = upstream_sources.data_root_dir(root_opt)
    defer: data_root.release()

    var source_dir = path_ops.join(data_root.as_str(), "third_party/tracy-upstream/profiler")
    defer: source_dir.release()
    var build_dir = path_ops.join(data_root.as_str(), "tmp/tracy-profiler-build")
    defer: build_dir.release()
    var binary = path_ops.join(build_dir.as_str(), "tracy-profiler")
    defer: binary.release()
    var install = path_ops.join(data_root.as_str(), "bin/tracy-profiler")
    defer: install.release()

    var header = string.String.create()
    defer: header.release()
    header.append("Building 1 vendored tool(s)...")
    info(quiet, header.as_str())
    info(quiet, "")

    if not is_executable(binary.as_str()):
        match fs.create_directories(build_dir.as_str()):
            Result.failure as dir_failure:
                var dir_error = dir_failure.error
                eprint_line(dir_error.message.as_str())
                dir_error.release()
                return 1
            Result.success:
                pass

        var configure = vec.Vec[str].create()
        defer: configure.release()
        configure.push("cmake")
        configure.push("-S")
        configure.push(source_dir.as_str())
        configure.push("-B")
        configure.push(build_dir.as_str())
        configure.push("-DCMAKE_BUILD_TYPE=Release")
        configure.push("-DLEGACY=ON")
        match upstream_sources.run_command(configure.as_span()):
            Result.failure as failure:
                var error = failure.error
                var message = string.String.create()
                defer: message.release()
                message.append("cmake configure failed for tracy-profiler:\n")
                message.append(error.as_str())
                eprint_line(message.as_str())
                error.release()
                return 1
            Result.success:
                pass

        var build_cmd = vec.Vec[str].create()
        defer: build_cmd.release()
        build_cmd.push("cmake")
        build_cmd.push("--build")
        build_cmd.push(build_dir.as_str())
        var jobs = cpu_count()
        var jobs_flag = string.String.create()
        defer: jobs_flag.release()
        jobs_flag.append("-j")
        jobs_flag.append_format(f"#{jobs}")
        build_cmd.push(jobs_flag.as_str())
        match upstream_sources.run_command(build_cmd.as_span()):
            Result.failure as failure:
                var error = failure.error
                var message = string.String.create()
                defer: message.release()
                message.append("build failed for tracy-profiler:\n")
                message.append(error.as_str())
                eprint_line(message.as_str())
                error.release()
                return 1
            Result.success:
                pass

        if not is_executable(binary.as_str()):
            var missing = string.String.create()
            defer: missing.release()
            missing.append("tool tracy-profiler built but binary not found at ")
            missing.append(binary.as_str())
            eprint_line(missing.as_str())
            return 1

    var install_dir = path_ops.dirname(install.as_str())
    match fs.create_directories(install_dir):
        Result.failure as install_dir_failure:
            var install_dir_error = install_dir_failure.error
            eprint_line(install_dir_error.message.as_str())
            install_dir_error.release()
            return 1
        Result.success:
            pass
    match fs.copy_entry(binary.as_str(), install.as_str()):
        Result.failure as copy_failure:
            var copy_error = copy_failure.error
            eprint_line(copy_error.message.as_str())
            copy_error.release()
            return 1
        Result.success:
            pass
    match fs.set_permissions(install.as_str(), 493):
        Result.failure as permission_failure:
            var permission_error = permission_failure.error
            eprint_line(permission_error.message.as_str())
            permission_error.release()
            return 1
        Result.success:
            pass

    var line = string.String.create()
    defer: line.release()
    line.append("  tracy-profiler ")
    append_ansi(ref_of(line), "32")
    line.append("built")
    append_ansi(ref_of(line), "0")
    line.append(" -> ")
    line.append(install.as_str())
    info(quiet, line.as_str())
    return 0


## Number of online CPUs (`Etc.nprocessors` in the host), defaulting to 1.
function cpu_count() -> ptr_uint:
    var cmd = vec.Vec[str].create()
    defer: cmd.release()
    cmd.push("nproc")
    match process.capture(cmd.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.release()
            if result.status.success():
                match result.stdout_text():
                    Option.some as text:
                        let trimmed = text.value.trim_ascii_whitespace()
                        if trimmed.len > 0:
                            var value: ptr_uint = 0
                            var i: ptr_uint = 0
                            while i < trimmed.len:
                                let b = trimmed.byte_at(i)
                                if b < '0' or b > '9':
                                    break
                                value = value * 10 + ptr_uint<-(b - '0')
                                i += 1
                            if value > 0:
                                return value
                    Option.none:
                        pass
            return 1
        Result.failure:
            return 1


function is_executable(path: str) -> bool:
    # `fs.metadata` is lstat-based; use the stat-based `fs.is_file` so a
    # symlinked tool (`/usr/bin/cc` -> gcc) is accepted like Ruby's File.file?.
    if not fs.is_file(path):
        return false
    match fs.metadata(path):
        Result.success as meta:
            return (meta.value.mode & 73) != 0
        Result.failure:
            return false


## ── doctor ──────────────────────────────────────────────────────────────────

## One accumulated `ok`/`fail` row (the host's `checks` tuples).
struct CheckRow:
    name: string.String
    detail: string.String
    ok: bool


extending CheckRow:
    public editable function release() -> void:
        this.name.release()
        this.detail.release()


## The host's doctor output shape (`toolchain_cli.rb:112-182`): three preambles,
## the system tools, the vendored-source sentinels, and the raw-binding headers,
## then one `ok name: detail` / `fail name: detail` row per check.
function doctor_command(quiet: bool) -> int:
    let root_opt = upstream_sources.compiler_root()
    var data_root = upstream_sources.data_root_dir(root_opt)
    defer: data_root.release()

    var overrides = upstream_sources.load_overrides(data_root.as_str())
    defer: upstream_sources.release_overrides(ref_of(overrides))

    var checks = vec.Vec[CheckRow].create()
    defer: release_checks(ref_of(checks))

    info(quiet, "Checking system tools...")
    let cc = env_or_default("CC", "cc")
    let cc_ok = executable_available(cc)
    push_check(ref_of(checks), "cc", cc_ok, cc)

    let ar = env_or_default("AR", "ar")
    push_check(ref_of(checks), "ar", executable_available(ar), ar)
    push_check(ref_of(checks), "git", executable_available("git"), "git")

    let clang = env_or_default("CLANG", "clang")
    push_check(ref_of(checks), "clang", executable_available(clang), clang)

    let cmake = env_or_default("CMAKE", "cmake")
    push_check(ref_of(checks), "cmake", executable_available(cmake), cmake)
    push_check(ref_of(checks), "ninja", executable_available("ninja"), "ninja")

    info(quiet, "Checking vendored libraries...")
    var source_index: ptr_uint = 0
    while source_index < upstream_sources.source_count():
        let src = upstream_sources.source_at(source_index)
        var checkout = path_ops.join(data_root.as_str(), src.dir)
        var row_name = string.String.create()
        row_name.append("source/")
        row_name.append(src.name)
        let missing = upstream_sources.first_missing_sentinel(checkout.as_str(), src, ref_of(overrides))
        if missing.is_none():
            push_check(ref_of(checks), row_name.as_str(), true, checkout.as_str())
        else:
            var detail = string.String.create()
            match missing:
                Option.some as relative:
                    detail.append("missing ")
                    detail.append(relative.value)
                    detail.append(" under ")
                    detail.append(checkout.as_str())
                Option.none:
                    pass
            push_check(ref_of(checks), row_name.as_str(), false, detail.as_str())
            detail.release()
        row_name.release()
        checkout.release()
        source_index += 1

    info(quiet, "Checking bindings...")
    let binding_start = checks.len()
    var binding_index: ptr_uint = 0
    while binding_index < raw_bindings.binding_count():
        let binding = raw_bindings.binding_at(binding_index)
        var row_name = string.String.create()
        row_name.append("binding/")
        row_name.append(binding.name)

        var ok = false
        var detail = string.String.create()
        match resolve_binding_header(binding, data_root.as_str()):
            Option.some as found:
                var header_path = found.value
                ok = true
                detail.append(binding.module_name)
                detail.append(" -> ")
                detail.append(header_path.as_str())
                header_path.release()
            Option.none:
                if not cc_ok:
                    detail.append("skipped (missing C compiler)")
                else:
                    var prepared = false
                    if binding.prepare_source >= 0:
                        prepared = prepare_binding_source(
                            binding, data_root.as_str(), ref_of(overrides)
                        )
                    if prepared:
                        match resolve_binding_header(binding, data_root.as_str()):
                            Option.some as retried:
                                var header_path = retried.value
                                ok = true
                                detail.append(binding.module_name)
                                detail.append(" -> ")
                                detail.append(header_path.as_str())
                                header_path.release()
                            Option.none:
                                append_header_missing_message(ref_of(detail), binding)
                    else:
                        append_header_missing_message(ref_of(detail), binding)

        insert_binding_check(ref_of(checks), binding_start, row_name.as_str(), ok, detail)
        row_name.release()
        binding_index += 1

    info(quiet, "")
    var all_ok = true
    var check_index: ptr_uint = 0
    while check_index < checks.len():
        let row_ptr = checks.get(check_index) else:
            break
        unsafe:
            let row = read(row_ptr)
            var line = string.String.create()
            if row.ok:
                line.append("ok ")
            else:
                line.append("fail ")
            line.append(row.name.as_str())
            line.append(": ")
            line.append(row.detail.as_str())
            stdio.print_line(line.as_str())
            line.release()
            if not row.ok:
                all_ok = false
        check_index += 1

    if all_ok:
        return 0
    return 1


function push_check(checks: ref[vec.Vec[CheckRow]], name: str, ok: bool, detail: str) -> void:
    checks.push(CheckRow(
        name = string.String.from_str(name),
        detail = string.String.from_str(detail),
        ok = ok,
    ))




## Append a binding row to the binding block, keeping it sorted by name (the
## host's `sort_by(&:name)`; the system and source rows precede the block).
function insert_binding_check(
    checks: ref[vec.Vec[CheckRow]],
    start: ptr_uint,
    name: str,
    ok: bool,
    detail: string.String,
) -> void:
    var index = checks.len()
    while index > start:
        let previous = checks.get(index - 1) else:
            break
        unsafe:
            if read(previous).name.as_str().compare(name) <= 0:
                break
        index -= 1
    if not checks.insert(index, CheckRow(name = string.String.from_str(name), detail = detail, ok = ok)):
        fatal(c"toolchain doctor: check insert failed")


function release_checks(checks: ref[vec.Vec[CheckRow]]) -> void:
    var index: ptr_uint = 0
    while index < checks.len():
        let row = checks.get(index) else:
            break
        unsafe:
            read(row).release()
        index += 1
    checks.release()


function env_or_default(name: str, fallback: str) -> str:
    match env.get(name):
        Option.some as value:
            if value.value.len > 0:
                return value.value
        Option.none:
            pass
    return fallback


## The host's `executable_available?`: an absolute/relative path is checked
## directly; a bare name is searched on `$PATH`.
function executable_available(name: str) -> bool:
    if name.len == 0:
        return false

    var index: ptr_uint = 0
    while index < name.len:
        if name.byte_at(index) == 47:
            return is_executable(name)
        index += 1

    match env.get("PATH"):
        Option.some as path:
            let value = path.value
            var start: ptr_uint = 0
            var position: ptr_uint = 0
            while position <= value.len:
                if position == value.len or value.byte_at(position) == 58:
                    let segment = value.slice(start, position - start)
                    var candidate = path_ops.join(segment, name)
                    let found = is_executable(candidate.as_str())
                    candidate.release()
                    if found:
                        return true
                    start = position + 1
                position += 1
            return false
        Option.none:
            return false


function resolve_binding_header(
    binding: raw_bindings.RawBinding,
    data_root: str,
) -> Option[string.String]:
    if binding.env_var.len > 0:
        match env.get(binding.env_var):
            Option.some as value:
                if value.value.len > 0 and fs.is_file(value.value):
                    return Option[string.String].some(value = string.String.from_str(value.value))
            Option.none:
                pass

    var index: ptr_uint = 0
    while index < binding.candidate_count:
        var candidate = binding_candidate(binding, index, data_root)
        if fs.is_file(candidate.as_str()):
            return Option[string.String].some(value = candidate)
        candidate.release()
        index += 1
    return Option[string.String].none


function binding_candidate(
    binding: raw_bindings.RawBinding,
    index: ptr_uint,
    data_root: str,
) -> string.String:
    let candidate = binding.candidates[index]
    if binding.candidates_from_root:
        return path_ops.join(data_root, candidate)
    return string.String.from_str(candidate)


function append_header_missing_message(
    detail: ref[string.String],
    binding: raw_bindings.RawBinding,
) -> void:
    detail.append(binding.header_label)
    detail.append(" header not found")
    if binding.env_var.len > 0:
        detail.append("; set ")
        detail.append(binding.env_var)
        detail.append(" or install ")
        detail.append(binding.header_label)
        detail.append(" headers")


## Best-effort `prepare!` for a missing vendored header: bootstrap the source
## the host's prepare lambda/vendored library would materialize.
function prepare_binding_source(
    binding: raw_bindings.RawBinding,
    data_root: str,
    overrides: ref[vec.Vec[upstream_sources.SourceOverride]],
) -> bool:
    let src = upstream_sources.source_at(ptr_uint<-binding.prepare_source)
    var checkout = path_ops.join(data_root, src.dir)
    defer: checkout.release()

    let revision = upstream_sources.revision_for(src, overrides)
    if upstream_sources.checkout_is_current(checkout.as_str(), src, revision, overrides):
        return true

    var failure_message = string.String.create()
    defer: failure_message.release()
    return upstream_sources.bootstrap_source(
        checkout.as_str(), src.url, revision, src, overrides, ref_of(failure_message)
    )
