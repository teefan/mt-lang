## Build driver — lower the checked program to IR, generate C, write it to a
## temporary file, compile it, and link it against any required vendored static
## libraries.  Mirrors the Ruby Build orchestration (lib/milk_tea/tooling/build.rb).
## Build-cache checks and package-graph resolution are handled by the CLI layer
## (main.mt).

import std.env as env
import std.fs as fs
import std.fmt as fmt
import std.log as log
import std.path as path_ops
import std.process as process
import std.string as string
import std.str
import std.time as time
import std.vec as vec

import mtc.debug_map as debug_map
import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.ir as ir
import mtc.c_backend.c_backend as c_backend
import mtc.parser.ast as ast
import mtc.strings
import mtc.wasm_shell as wasm_shell


## What the build produces: an executable (the default), a static archive
## (`ar rcs`), or a shared object (`cc -shared`).  Mirrors the host's
## `Build` kind option; the host's own static/shared paths call a missing
## `generate_header`, so the self implements the rest of that flow.
public enum BuildKind: ubyte
    executable = 0
    kind_static = 1
    kind_shared = 2


## Build a checked program to `output_path` using `c_compiler`.  `roots` are the
## module search roots (as passed on the CLI): the one containing `std/c` supplies
## the C ABI header include path.  `ir_program` is the caller-lowered IR (the CLI
## lowers once, so the entrypoint check and the build share a single lowering).
## When `sanitize` is true, the binary is compiled with AddressSanitizer and UBSan.
## On success the success value is the output path; on failure the error is a
## human-readable message.
public function build(
    program: loader.Program,
    ir_program: ir.Program,
    output_path: str,
    c_compiler: str,
    roots: span[str],
    sanitize: bool,
    profile: str,
    debug_guards: Option[bool],
    kind: BuildKind,
    platform: resolver.Platform,
    html_template: Option[str],
    assets: span[string.String],
    keep_c_path: Option[str],
) -> Result[string.String, string.String]:
    let is_wasm = platform == resolver.Platform.wasm
    let toolchain = prepare_build_toolchain(program, roots, c_compiler, output_path, platform, kind)
    var compiler: str = ""
    match toolchain:
        Result.success as prepared:
            compiler = prepared.value
        Result.failure as failure:
            return Result[string.String, string.String].failure(error = failure.error)

    # Debug profile: `-g -O0`, `#line` directives, and per-loop iteration
    # guards; release: `-O3 -DNDEBUG`.  `--debug-guards`/`--no-debug-guards`
    # override the guard default (mirrors Ruby's Build#profile_compiler_flags /
    # #debug_guards_enabled?).
    let is_debug = profile == "debug"
    var guards = is_debug
    match debug_guards:
        Option.some as override:
            guards = override.value
        Option.none:
            pass

    var c_source = string.String.create()
    defer: c_source.release()
    match generate_build_c_source(ir_program, is_debug, guards, kind, keep_c_path):
        Result.success as generated:
            c_source.release()
            c_source = generated.value
        Result.failure as failure:
            return Result[string.String, string.String].failure(error = failure.error)

    var c_path = string.String.create()
    defer: c_path.release()
    match write_temp_c_source(output_path, c_source.as_str()):
        Result.success as written:
            c_path.release()
            c_path = written.value
        Result.failure as failure:
            return Result[string.String, string.String].failure(error = failure.error)

    var shell_path = string.String.create()
    defer: remove_shell_file(ref_of(shell_path))
    match prepare_wasm_shell(html_template, output_path, is_wasm):
        Result.success as prepared_shell:
            shell_path.release()
            shell_path = prepared_shell.value
        Result.failure as failure:
            return Result[string.String, string.String].failure(error = failure.error)

    var command = vec.Vec[str].create()
    defer: command.release()

    # C ABI struct definitions (`fs_support.h`, etc.) live under `<root>/std/c`;
    # add the include path from whichever root contains that directory.
    var include_flag = std_c_include_flag(roots)
    defer: include_flag.release()

    # Binding build flags (include paths and implementation defines) that the
    # raw std.c.* modules require but do not express as source directives — e.g.
    # raygui needs its header include path plus -DRAYGUI_IMPLEMENTATION.  These
    # mirror the Ruby raw-binding registry entries.  They are needed to compile
    # the generated C, so they precede the input in every kind.
    var binding_flags = collect_binding_flags(program, roots)
    defer: release_owned_strings(ref_of(binding_flags))

    # Link libraries declared via `link "..."` directives in external modules
    # (e.g. `link "uv"` in std.c.fs → `-luv`) and the vendored static-library
    # search paths plus their system dependencies.  Collected once for both the
    # wasm and native command shapes; released after the compiler runs.  The
    # vendored `-L` flags must precede the `-l` flags so a vendored static
    # archive wins over a same-named system shared library.
    var link_flags = collect_link_flags(program)
    defer: release_owned_strings(ref_of(link_flags))
    var vendored_flags = collect_vendored_link_flags(program, roots)
    defer: release_owned_strings(ref_of(vendored_flags))

    var owned_args = vec.Vec[string.String].create()
    defer: release_owned_strings(ref_of(owned_args))

    let is_static = kind == BuildKind.kind_static
    var object_path = string.String.create()
    defer: object_path.release()

    push_compile_arguments(
        ref_of(command), compiler, is_wasm, is_debug, sanitize, is_static, kind, include_flag.as_str(),
        ref_of(binding_flags), ref_of(link_flags), ref_of(vendored_flags), ref_of(owned_args), assets,
        c_path.as_str(), output_path, shell_path.as_str(), ref_of(object_path)
    )

    match process.capture(command.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.stdout.release()
            defer: result.stderr.release()
            if result.status.exit_code != 0:
                var details = string.String.from_str(result.stdout.as_str())
                details.append(result.stderr.as_str())
                if details.len() == 0:
                    details.release()
                    return Result[string.String, string.String].failure(
                        error = string.String.from_str("C compiler failed")
                    )
                var message = string.String.from_str("C compiler failed:\n")
                message.append(details.as_str())
                details.release()
                return Result[string.String, string.String].failure(error = message)

            if is_static:
                # `ar rcs` replaces a member of the same name but keeps stale
                # members from earlier objects; the generated object's name is
                # build-unique, so start from a clean archive.
                if fs.exists(output_path):
                    match fs.remove(output_path):
                        Result.success:
                            pass
                        Result.failure as stale_failure:
                            var stale_error = stale_failure.error
                            var message = string.String.create()
                            message.append("archiver failed:\n")
                            message.append(stale_error.message.as_str())
                            stale_error.release()
                            return Result[string.String, string.String].failure(error = message)
                var archive_cmd = vec.Vec[str].create()
                defer: archive_cmd.release()
                archive_cmd.push("ar")
                archive_cmd.push("rcs")
                archive_cmd.push(output_path)
                archive_cmd.push(object_path.as_str())
                match process.capture(archive_cmd.as_span()):
                    Result.success as archived:
                        var archive_result = archived.value
                        defer: archive_result.stdout.release()
                        defer: archive_result.stderr.release()
                        if archive_result.status.exit_code != 0:
                            var message = string.String.from_str("archiver failed:\n")
                            message.append(archive_result.stdout.as_str())
                            message.append(archive_result.stderr.as_str())
                            return Result[string.String, string.String].failure(error = message)
                    Result.failure as archive_failure:
                        var archive_error = archive_failure.error
                        archive_error.release()
                        return Result[string.String, string.String].failure(
                            error = string.String.from_str("could not launch archiver 'ar'")
                        )
                match fs.remove(object_path.as_str()):
                    Result.success:
                        pass
                    Result.failure as rm_failure:
                        var rm_err = rm_failure.error
                        rm_err.release()

            # The generated C is no longer needed; a failed compile keeps it on
            # disk so the reported path stays inspectable.
            match fs.remove(c_path.as_str()):
                Result.success:
                    pass
                Result.failure as rm_failure:
                    var rm_err = rm_failure.error
                    rm_err.release()
            if kind == BuildKind.executable:
                write_debug_map(ir_program, output_path)
            return Result[string.String, string.String].success(value = string.String.from_str(output_path))
        Result.failure as failure:
            var err = failure.error
            err.release()
            var message = string.String.from_str("C compiler not found: ")
            message.append(compiler)
            return Result[string.String, string.String].failure(error = message)


## Validate the target, resolve the C compiler, and prepare the vendored
## libraries.  Returns the compiler binary on success.
function prepare_build_toolchain(
    program: loader.Program,
    roots: span[str],
    c_compiler: str,
    output_path: str,
    platform: resolver.Platform,
    kind: BuildKind,
) -> Result[str, string.String]:
    let is_wasm = platform == resolver.Platform.wasm
    if is_wasm and not output_path.ends_with(".html"):
        var message = string.String.from_str("wasm output path must end with .html or omit the extension: ")
        message.append(output_path)
        return Result[str, string.String].failure(error = message)
    if is_wasm and kind != BuildKind.executable:
        return Result[str, string.String].failure(
            error = string.String.from_str("wasm target supports executable builds only")
        )

    let compiler = resolve_compiler(c_compiler, is_wasm)
    if not compiler_available(compiler):
        var message = string.String.from_str("C compiler not found: ")
        message.append(compiler)
        return Result[str, string.String].failure(error = message)
    if is_wasm and not is_emscripten_compiler(compiler):
        var message = string.String.from_str("unsupported C compiler backend for wasm target: ")
        message.append(compiler)
        message.append("; use Emscripten emcc")
        return Result[str, string.String].failure(error = message)

    # Vendored static libraries (GLFW, the Tracy client) must exist before the
    # link step; build them on demand for raw bindings that require them.
    match prepare_vendored_libraries(program, roots):
        Result.failure as prep_failure:
            return Result[str, string.String].failure(error = prep_failure.error)
        Result.success:
            pass
    return Result[str, string.String].success(value = compiler)


## Generate the compiled C source and, for `--keep-c`, the inspectable
## rendering.  Returns the owned compiled source.
function generate_build_c_source(
    ir_program: ir.Program,
    is_debug: bool,
    guards: bool,
    kind: BuildKind,
    keep_c_path: Option[str],
) -> Result[string.String, string.String]:
    var c_source = c_backend.generate_c(ir_program, is_debug, guards, kind != BuildKind.executable)

    # `--keep-c` saves the host's inspectable rendering: no `#line` directives
    # and no debug loop guards, while the compiled source is the profile's
    # source (the host's `CBackend.emit(..., emit_line_directives: false,
    # debug_guards: false)`).
    if keep_c_path.is_some():
        let keep_path = keep_c_path.unwrap()
        var saved_source = c_backend.generate_c(ir_program, false, false, false)
        defer: saved_source.release()
        let keep_dir = path_ops.dirname(keep_path)
        match fs.create_directories(keep_dir):
            Result.failure as dir_failure:
                var dir_error = dir_failure.error
                var message = string.String.from_str("could not write C to ")
                message.append(keep_path)
                message.append(": ")
                message.append(dir_error.message.as_str())
                dir_error.release()
                c_source.release()
                return Result[string.String, string.String].failure(error = message)
            Result.success:
                pass
        match fs.write_text(keep_path, saved_source.as_str()):
            Result.failure as write_failure:
                var write_error = write_failure.error
                var message = string.String.from_str("could not write C to ")
                message.append(keep_path)
                message.append(": ")
                message.append(write_error.message.as_str())
                write_error.release()
                c_source.release()
                return Result[string.String, string.String].failure(error = message)
            Result.success:
                pass
    return Result[string.String, string.String].success(value = c_source)


## Write the compiled source to a unique temporary path.  A unique path keeps
## concurrent builds (e.g. a parallel example sweep) from clobbering each
## other; a fixed `/tmp/mtc_build.c` made one process compile another's C.
function write_temp_c_source(output_path: str, c_source: str) -> Result[string.String, string.String]:
    var c_path = string.String.from_str("/tmp/mtc_build_")
    c_path.append(path_ops.basename(output_path))
    c_path.push_byte('_')
    fmt.append_long(ref_of(c_path), long<-time.now())
    c_path.append(".c")
    match fs.write_text(c_path.as_str(), c_source):
        Result.success:
            return Result[string.String, string.String].success(value = c_path)
        Result.failure as failure:
            var err = failure.error
            err.release()
            c_path.release()
            return Result[string.String, string.String].failure(
                error = string.String.from_str("could not write generated C source")
            )


## Render and materialize the wasm shell (empty for native targets) and clear
## stale wasm sidecars.
function prepare_wasm_shell(
    html_template: Option[str],
    output_path: str,
    is_wasm: bool,
) -> Result[string.String, string.String]:
    var shell_path = string.String.create()
    if not is_wasm:
        return Result[string.String, string.String].success(value = shell_path)

    var template_owner = string.String.create()
    defer: template_owner.release()
    var template_path: str = "<embedded wasm shell>"
    match html_template:
        Option.some as declared:
            template_path = declared.value
            match fs.read_text(declared.value):
                Result.success as payload:
                    template_owner.release()
                    template_owner = payload.value
                Result.failure as read_failure:
                    var read_error = read_failure.error
                    var message = string.String.from_str("could not read wasm HTML template: ")
                    message.append(declared.value)
                    read_error.release()
                    shell_path.release()
                    return Result[string.String, string.String].failure(error = message)
        Option.none:
            template_owner.assign(wasm_shell.DEFAULT_TEMPLATE)

    match wasm_shell.render(template_owner.as_str(), template_path):
        Result.failure as render_failure:
            shell_path.release()
            return Result[string.String, string.String].failure(error = render_failure.error)
        Result.success as rendered:
            var shell_source = rendered.value
            defer: shell_source.release()
            match fs.create_temporary_file_in_system_temp("milk-tea-shell", ".html"):
                Result.success as created:
                    shell_path.release()
                    shell_path = created.value
                Result.failure as create_failure:
                    var create_error = create_failure.error
                    var message = string.String.from_str("could not create wasm shell file: ")
                    message.append(create_error.message.as_str())
                    create_error.release()
                    shell_path.release()
                    return Result[string.String, string.String].failure(error = message)
            match fs.write_text(shell_path.as_str(), shell_source.as_str()):
                Result.failure as write_failure:
                    var write_error = write_failure.error
                    var message = string.String.from_str("could not write wasm shell file: ")
                    message.append(write_error.message.as_str())
                    write_error.release()
                    shell_path.release()
                    return Result[string.String, string.String].failure(error = message)
                Result.success:
                    pass
    clean_wasm_artifacts(output_path)
    return Result[string.String, string.String].success(value = shell_path)


## Build the compiler command line for the selected target and artifact kind.
function push_compile_arguments(
    command: ref[vec.Vec[str]],
    compiler: str,
    is_wasm: bool,
    is_debug: bool,
    sanitize: bool,
    is_static: bool,
    kind: BuildKind,
    include_flag: str,
    binding_flags: ref[vec.Vec[string.String]],
    link_flags: ref[vec.Vec[string.String]],
    vendored_flags: ref[vec.Vec[string.String]],
    owned_args: ref[vec.Vec[string.String]],
    assets: span[string.String],
    c_path: str,
    output_path: str,
    shell_path: str,
    object_path: ref[string.String],
) -> void:
    read(command).push(compiler)
    read(command).push("-std=c11")

    if is_wasm:
        if is_debug:
            read(command).push("-g")
            read(command).push("-O0")
        else:
            read(command).push("-O3")
            read(command).push("-DNDEBUG")
        if include_flag.len > 0:
            read(command).push(include_flag)
        push_owned_flags(command, binding_flags)
        read(command).push(c_path)
        read(command).push("-o")
        read(command).push(output_path)
        read(command).push("--shell-file")
        read(command).push(shell_path)
        read(command).push("-sINCOMING_MODULE_JS_API=canvas,print,printErr")
        push_wasm_preloads(command, owned_args, assets)
        push_owned_flags(command, vendored_flags)
        push_owned_flags(command, link_flags)
    else:
        read(command).push("-D_GNU_SOURCE")
        if sanitize:
            read(command).push("-fsanitize=address,undefined")
            read(command).push("-fno-sanitize-recover=all")
            read(command).push("-fno-omit-frame-pointer")
        if is_debug:
            read(command).push("-g")
            read(command).push("-O0")
        else:
            read(command).push("-O3")
            read(command).push("-DNDEBUG")

        if include_flag.len > 0:
            read(command).push(include_flag)
        push_owned_flags(command, binding_flags)

        if is_static:
            read(object_path).append(c_path.slice(0, c_path.len - 2))
            read(object_path).append(".o")
            read(command).push("-c")
            read(command).push("-o")
            read(command).push(read(object_path).as_str())
            read(command).push(c_path)
        else:
            if kind == BuildKind.kind_shared:
                read(command).push("-fPIC")
                read(command).push("-shared")
            read(command).push("-o")
            read(command).push(output_path)
            read(command).push(c_path)
            push_owned_flags(command, vendored_flags)
            push_owned_flags(command, link_flags)


function env_or_default(name: str, fallback: str) -> str:
    match env.get(name):
        Option.some as value:
            if value.value.len > 0:
                return value.value
        Option.none:
            pass
    return fallback


## The host's `Build#resolve_compiler`: a wasm build with the default C
## compiler uses `$EMCC` (default `emcc`); an explicit `--cc` is honoured.
function resolve_compiler(requested: str, is_wasm: bool) -> str:
    if not is_wasm:
        return requested
    let default_cc = env_or_default("CC", "cc")
    if requested.equal("cc") or requested.equal(default_cc):
        return env_or_default("EMCC", "emcc")
    return requested


function is_executable_file(path: str) -> bool:
    if not fs.is_file(path):
        return false
    match fs.metadata(path):
        Result.success as metadata:
            return (metadata.value.mode & 73) != 0
        Result.failure:
            return false


## The host's `compiler_available?`: a path is checked directly; a bare name is
## searched on `$PATH`.
function compiler_available(compiler: str) -> bool:
    if compiler.len == 0:
        return false

    var index: ptr_uint = 0
    while index < compiler.len:
        if compiler.byte_at(index) == 47:
            return is_executable_file(compiler)
        index += 1

    match env.get("PATH"):
        Option.some as path:
            let value = path.value
            var start: ptr_uint = 0
            var position: ptr_uint = 0
            while position <= value.len:
                if position == value.len or value.byte_at(position) == 58:
                    let segment = value.slice(start, position - start)
                    var candidate = path_ops.join(segment, compiler)
                    let found = is_executable_file(candidate.as_str())
                    candidate.release()
                    if found:
                        return true
                    start = position + 1
                position += 1
            return false
        Option.none:
            return false


function ascii_lower_byte(value: ubyte) -> ubyte:
    if value >= 65 and value <= 90:
        return value + 32
    return value


function is_compiler_separator(value: ubyte) -> bool:
    return value == 45 or value == 95 or value == 46


## The host's `emscripten_backend?`: the basename (without a known executable
## suffix) split on `-_.` must contain an `emcc` token.
function is_emscripten_compiler(compiler: str) -> bool:
    let base = path_ops.basename(compiler)
    var end = base.len

    var dot = base.len
    var index: ptr_uint = 0
    while index < base.len:
        if base.byte_at(index) == 46:
            dot = index
        index += 1
    if dot < base.len:
        let suffix = base.slice(dot, base.len - dot)
        if (
            suffix.equal(".exe")
            or suffix.equal(".bat")
            or suffix.equal(".cmd")
            or suffix.equal(".com")
            or suffix.equal(".sh")
            or suffix.equal(".py")
        ):
            end = dot

    var start: ptr_uint = 0
    index = 0
    while index <= end:
        if index == end or is_compiler_separator(base.byte_at(index)):
            let token = base.slice(start, index - start)
            if token.len == 4:
                if (
                    ascii_lower_byte(token.byte_at(0)) == 101
                    and ascii_lower_byte(token.byte_at(1)) == 109
                    and ascii_lower_byte(token.byte_at(2)) == 99
                    and ascii_lower_byte(token.byte_at(3)) == 99
                ):
                    return true
            start = index + 1
        index += 1
    return false


function push_owned_flags(command: ref[vec.Vec[str]], values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value = values.get(index) else:
            break
        unsafe:
            command.push(read(value).as_str())
        index += 1


## `--preload-file <abs>@/<basename>` per `build.assets` entry (the host's
## `wasm_asset_flags`).  The mapping strings are owned by `owned` so the `str`
## views in `command` stay valid until the compiler runs.
function push_wasm_preloads(
    command: ref[vec.Vec[str]],
    owned: ref[vec.Vec[string.String]],
    assets: span[string.String],
) -> void:
    var index: ptr_uint = 0
    while index < assets.len:
        let asset = assets[index]
        let asset_path = asset.as_str()
        var mapping = string.String.with_capacity(asset_path.len + 2)
        mapping.append(asset_path)
        mapping.push_byte(64)
        mapping.push_byte(47)
        mapping.append(path_ops.basename(asset_path))
        command.push("--preload-file")
        command.push(mapping.as_str())
        owned.push(mapping)
        index += 1


function release_owned_strings(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value = values.get(index) else:
            break
        unsafe:
            read(value).release()
        index += 1
    values.release()


function remove_shell_file(path: ref[string.String]) -> void:
    if read(path).len > 0:
        match fs.remove(read(path).as_str()):
            Result.failure as failure:
                var error = failure.error
                error.release()
            Result.success:
                pass
    read(path).release()


## The host's `clean_output_artifacts`: remove the target and the sidecars an
## earlier emcc run may have left beside it.
function clean_wasm_artifacts(output_path: str) -> void:
    match fs.remove(output_path):
        Result.failure as failure:
            var error = failure.error
            error.release()
        Result.success:
            pass

    let base = output_path.slice(0, output_path.len - 5)
    var extensions: array[str, 6] = array[str, 6](
        ".js", ".wasm", ".data", ".worker.js", ".symbols", ".wasm.map"
    )
    var index: ptr_uint = 0
    while index < 6:
        var sidecar = string.String.from_str(base)
        sidecar.append(extensions[index])
        match fs.remove(sidecar.as_str()):
            Result.failure as failure:
                var error = failure.error
                error.release()
            Result.success:
                pass
        sidecar.release()
        index += 1


## Write the `<output>.mtdbg.json` sidecar from the lowered IR.  A sidecar
## write failure must not fail the build: the binary is the deliverable, and
## the DAP bridge merely loses frame-name mapping without the map.
function write_debug_map(ir_program: ir.Program, output_path: str) -> void:
    var program_copy = ir_program
    var sidecar = debug_map.sidecar_path_for(output_path)
    defer: sidecar.release()
    var map = debug_map.from_ir(ref_of(program_copy), output_path)
    defer: debug_map.release(ref_of(map))
    match debug_map.write(ref_of(map), sidecar.as_str()):
        Result.success:
            pass
        Result.failure as failure:
            var message = failure.error
            log.warn(message.as_str())
            message.release()


## The `-I<root>/std/c` flag for the first root that contains a `std/c` directory,
## or an empty string when none do.  Mirrors Ruby's `std_c_include_flag`.
function std_c_include_flag(roots: span[str]) -> string.String:
    var i: ptr_uint = 0
    while i < roots.len:
        var root: str
        unsafe:
            root = read(roots.data + i)
        var candidate = path_ops.join(root, "std/c")
        if fs.is_directory(candidate.as_str()):
            var flag = string.String.from_str("-I")
            flag.append(candidate.as_str())
            candidate.release()
            return flag
        candidate.release()
        i += 1
    return string.String.create()


## Collect `-l<lib>` flags from every `link "<lib>"` directive in the program's
## raw external modules.  Mirrors Ruby's link-library collection.  Also adds
## `-luv` when any module uses parallel-for (libuv thread pool).
function collect_link_flags(program: loader.Program) -> vec.Vec[string.String]:
    var link_libs = vec.Vec[string.String].create()
    var uses_parallel = false
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            break
        var analysis = unsafe: read(a_ptr)
        if analysis.uses_parallel_for:
            uses_parallel = true
        var di: ptr_uint = 0
        while di < analysis.directives.len:
            var directive: ast.Decl
            unsafe:
                directive = read(analysis.directives.data + di)
            match directive:
                ast.Decl.decl_link as link_decl:
                    var flag = string.String.from_str("-l")
                    flag.append(link_decl.value)
                    if not link_lib_seen(ref_of(link_libs), flag.as_str()):
                        link_libs.push(flag)
                    else:
                        flag.release()
                _:
                    pass
            di += 1
        mi += 1
    if uses_parallel:
        var uv_flag = string.String.from_str("-luv")
        if not link_lib_seen(ref_of(link_libs), uv_flag.as_str()):
            link_libs.push(uv_flag)
        else:
            uv_flag.release()
    return link_libs


## True when a `-l<lib>` flag is already collected (dedup).
function link_lib_seen(link_libs: ref[vec.Vec[string.String]], flag: str) -> bool:
    var i: ptr_uint = 0
    while i < link_libs.len():
        let f_ptr = link_libs.get(i) else:
            break
        unsafe:
            if read(f_ptr).as_str() == flag:
                return true
        i += 1
    return false


## Collect binding-specific C build flags (include paths and implementation
## defines) required by raw `std.c.*` modules that do not carry them as source
## directives.  These mirror the essential entries of the Ruby raw-binding
## registry: raylib-family modules compile against the vendored raylib headers
## with the vendored archive's build defines (`-DPLATFORM_DESKTOP_GLFW
## -DGRAPHICS_API_OPENGL_43`, matching how tmp/vendored-raylib-opengl43 is
## built), raygui needs its vendored header include path plus
## `-DRAYGUI_IMPLEMENTATION -DGRAPHICS_API_OPENGL_43`, rlgl-facing modules
## need `-DGRAPHICS_API_OPENGL_43 -DMT_LANG_GL_REGISTRY_HAVE_RAYLIB`, glfw needs
## the vendored GLFW headers (the pinned tree defines constants such as
## `GLFW_UNLIMITED_MOUSE_BUTTONS` that system headers may lack), and tracy needs
## the vendored TracyC.h include paths plus `-DTRACY_ENABLE`.  Header paths are
## resolved relative to whichever module root contains the vendored tree, so no
## absolute machine path is baked in.
function collect_binding_flags(program: loader.Program, roots: span[str]) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()
    var uses_raylib = false
    var uses_raymath = false
    var uses_raygui = false
    var uses_rlgl = false
    var uses_gl = false
    var uses_glfw = false
    var uses_tracy = false
    var uses_cjson = false
    var uses_box2d = false
    var uses_box3d = false
    var uses_sdl3 = false
    var uses_flecs = false
    var uses_pcre2 = false
    var uses_steamworks = false
    var uses_libuv = false
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            break
        var analysis = unsafe: read(a_ptr)
        if analysis.module_name == "std.c.raylib":
            uses_raylib = true
        if analysis.module_name == "std.c.raymath":
            uses_raymath = true
        if analysis.module_name == "std.c.raygui":
            uses_raygui = true
        if analysis.module_name == "std.c.rlgl":
            uses_rlgl = true
        if analysis.module_name == "std.c.gl":
            uses_gl = true
        if analysis.module_name == "std.c.glfw":
            uses_glfw = true
        if analysis.module_name == "std.c.tracy":
            uses_tracy = true
        if analysis.module_name == "std.cjson":
            uses_cjson = true
        if analysis.module_name == "std.c.box2d":
            uses_box2d = true
        if analysis.module_name == "std.c.box3d":
            uses_box3d = true
        if analysis.module_name == "std.c.sdl3":
            uses_sdl3 = true
        if analysis.module_name == "std.c.flecs":
            uses_flecs = true
        if analysis.module_name == "std.c.pcre2":
            uses_pcre2 = true
        if analysis.module_name == "std.c.steamworks":
            uses_steamworks = true
        if analysis.module_name == "std.c.libuv":
            uses_libuv = true
        mi += 1

    # Any raylib-family binding compiles against the vendored raylib headers
    # (the source the bindings were generated from) with the same defines the
    # vendored archive is built with, so the TU and the linked libraylib.a
    # agree on platform (GLFW) and GL version (4.3).
    if uses_raylib or uses_raygui or uses_rlgl:
        var raylib_src = vendored_raylib_include(roots, "src")
        defer: raylib_src.release()
        if raylib_src.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", raylib_src.as_str())))
        result.push(string.String.from_str("-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB"))
        result.push(string.String.from_str("-DPLATFORM_DESKTOP_GLFW"))
        result.push(string.String.from_str("-DGRAPHICS_API_OPENGL_43"))

    if uses_raymath:
        result.push(string.String.from_str("-DRAYMATH_STATIC_INLINE"))

    if uses_raygui:
        var include_dir = vendored_raylib_include(roots, "examples/shapes")
        defer: include_dir.release()
        if include_dir.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", include_dir.as_str())))
        result.push(string.String.from_str("-DRAYGUI_IMPLEMENTATION"))
        result.push(string.String.from_str("-DGRAPHICS_API_OPENGL_43"))

    if uses_rlgl:
        result.push(string.String.from_str("-DGRAPHICS_API_OPENGL_43"))
        result.push(string.String.from_str("-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB"))

    # `std.c.gl` includes the header-only OpenGL registry helpers; the
    # `..._IMPLEMENTATION` define compiles the loader/wrapper bodies (GL entry
    # points are resolved dynamically through raylib's loader, so no `-lGL` is
    # needed), matching the Ruby gl binding's implementation_define.
    if uses_gl:
        result.push(string.String.from_str("-DMT_LANG_GL_REGISTRY_HELPERS_IMPLEMENTATION"))
        result.push(string.String.from_str("-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB"))

    if uses_glfw:
        var glfw_include = vendored_tree_path(roots, "glfw-upstream/include")
        defer: glfw_include.release()
        if glfw_include.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", glfw_include.as_str())))
        result.push(string.String.from_str("-DMT_LANG_GL_REGISTRY_HAVE_GLFW"))

    if uses_tracy:
        var tracy_inner = vendored_tree_path(roots, "tracy-upstream/public/tracy")
        defer: tracy_inner.release()
        if tracy_inner.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", tracy_inner.as_str())))
        var tracy_public = vendored_tree_path(roots, "tracy-upstream/public")
        defer: tracy_public.release()
        if tracy_public.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", tracy_public.as_str())))
        result.push(string.String.from_str("-DTRACY_ENABLE"))

    if uses_cjson:
        var cjson_include = vendored_tree_path(roots, "cjson-upstream")
        defer: cjson_include.release()
        if cjson_include.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", cjson_include.as_str())))

    if uses_box2d:
        var box2d_include = vendored_tree_path(roots, "box2d-upstream/include")
        defer: box2d_include.release()
        if box2d_include.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", box2d_include.as_str())))

    if uses_box3d:
        var box3d_include = vendored_tree_path(roots, "box3d-upstream/include")
        defer: box3d_include.release()
        if box3d_include.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", box3d_include.as_str())))

    if uses_sdl3:
        var sdl3_include = vendored_tree_path(roots, "sdl3-upstream/include")
        defer: sdl3_include.release()
        if sdl3_include.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", sdl3_include.as_str())))
        result.push(string.String.from_str("-DSDL_MAIN_HANDLED"))

    if uses_flecs:
        var flecs_include = vendored_tree_path(roots, "flecs-upstream/distr")
        defer: flecs_include.release()
        if flecs_include.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", flecs_include.as_str())))

    if uses_pcre2:
        match vendored_source_root(roots, "pcre2-upstream"):
            Option.some as pcre2_root:
                var pcre2_include = path_ops.join(pcre2_root.value, "tmp/vendored-pcre2-prefix/include")
                var include_flag = string.String.from_str("-I")
                include_flag.append(pcre2_include.as_str())
                pcre2_include.release()
                result.push(include_flag)
                result.push(string.String.from_str("-DPCRE2_CODE_UNIT_WIDTH=8"))
            Option.none:
                pass

    if uses_steamworks:
        var sw_include = vendored_tree_path(roots, "steamworks-sdk-upstream/public")
        defer: sw_include.release()
        if sw_include.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", sw_include.as_str())))

    if uses_libuv:
        var uv_include = vendored_tree_path(roots, "libuv-upstream/include")
        defer: uv_include.release()
        if uv_include.len() > 0:
            result.push(string.String.from_str(strings.join_two("-I", uv_include.as_str())))

    return result


## Absolute path to a subdirectory of the vendored raylib tree
## (`third_party/raylib-upstream/<sub>`), searched under each module root.
## Returns an empty string when no root contains the vendored tree.
function vendored_raylib_include(roots: span[str], sub: str) -> string.String:
    return vendored_tree_path(roots, strings.join_two("raylib-upstream/", sub))


## Absolute path to `third_party/<sub>` under whichever module root contains it,
## or an empty string when none do.
function vendored_tree_path(roots: span[str], sub: str) -> string.String:
    var i: ptr_uint = 0
    while i < roots.len:
        var root: str
        unsafe:
            root = read(roots.data + i)
        var relative = string.String.from_str("third_party/")
        relative.append(sub)
        var candidate = path_ops.join(root, relative.as_str())
        relative.release()
        if fs.is_directory(candidate.as_str()):
            return candidate
        candidate.release()
        i += 1
    return string.String.create()


## The module root that contains `third_party/<sub>`, or none.  Vendored builds
## write their artifacts under `<that root>/tmp/`, sharing the layout (and any
## already-built archives) with the Ruby compiler's vendored-library flow.
function vendored_source_root(roots: span[str], sub: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < roots.len:
        var root: str
        unsafe:
            root = read(roots.data + i)
        var relative = string.String.from_str("third_party/")
        relative.append(sub)
        var candidate = path_ops.join(root, relative.as_str())
        relative.release()
        let found = fs.is_directory(candidate.as_str())
        candidate.release()
        if found:
            return Option[str].some(value = root)
        i += 1
    return Option[str].none


## True when the program's module closure includes the named raw binding module.
function uses_binding_module(program: loader.Program, name: str) -> bool:
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            break
        unsafe:
            if read(a_ptr).module_name == name:
                return true
        mi += 1
    return false


## Build the vendored static libraries required by the program's raw bindings
## when their archives are not already present.  The vendored sources are pinned
## trees, so an existing archive is reused as-is.  Supported libraries:
##   - raylib family, glfw, tracy, cjson, box2d, sdl3, flecs, pcre2, steamworks,
##     libuv.
## Mirrors Ruby's VendoredCLibrary CMake/Archive `prepare!` flow in minimal form.
function prepare_vendored_libraries(program: loader.Program, roots: span[str]) -> Result[bool, string.String]:
    if uses_vendored_raylib(program):
        match prepare_vendored_raylib(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.glfw"):
        match prepare_vendored_glfw(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.tracy"):
        match prepare_vendored_tracy(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.cjson"):
        match prepare_vendored_cjson(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.box2d"):
        match prepare_vendored_box2d(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.box3d"):
        match prepare_vendored_box3d(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.sdl3"):
        match prepare_vendored_sdl3(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.flecs"):
        match prepare_vendored_flecs(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.pcre2"):
        match prepare_vendored_pcre2(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.steamworks"):
        match prepare_vendored_steamworks(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    if uses_binding_module(program, "std.c.libuv"):
        match prepare_vendored_libuv(roots):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

    return Result[bool, string.String].success(value = true)


## True when the program uses a binding backed by the vendored raylib archive
## (the raylib, raygui, and rlgl bindings in Ruby's registry all set
## `vendored_library: vendored_raylib_library`).
function uses_vendored_raylib(program: loader.Program) -> bool:
    if uses_binding_module(program, "std.c.raylib"):
        return true
    if uses_binding_module(program, "std.c.raygui"):
        return true
    return uses_binding_module(program, "std.c.rlgl")


function prepare_vendored_raylib(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "raylib-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored raylib source not found: the raylib binding needs third_party/raylib-upstream to build libraylib"
        ))

    var build_dir = path_ops.join(root, "tmp/vendored-raylib-opengl43")
    defer: build_dir.release()
    var archive = path_ops.join(build_dir.as_str(), "libraylib.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    match fs.create_directories(build_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            return Result[bool, string.String].failure(error = string.String.from_str(
                "could not create tmp/vendored-raylib-opengl43 for the vendored raylib build"
            ))
        Result.success:
            pass

    var src_dir = path_ops.join(root, "third_party/raylib-upstream/src")
    defer: src_dir.release()
    var include_flag = string.String.from_str("-I")
    include_flag.append(src_dir.as_str())
    defer: include_flag.release()

    let sources = array[str, 6]("rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "rmodels.c", "raudio.c")

    var ar_cmd = vec.Vec[str].create()
    defer: ar_cmd.release()
    ar_cmd.push("ar")
    ar_cmd.push("rcs")
    ar_cmd.push(archive.as_str())

    var si: ptr_uint = 0
    while si < 6:
        let source_name = sources[si]
        let source_file = strings.join_two(src_dir.as_str(), strings.join_two("/", source_name))
        let object_file = strings.join_two(build_dir.as_str(), strings.join_two("/", strings.join_two(source_name, ".o")))

        var compile = vec.Vec[str].create()
        defer: compile.release()
        compile.push("cc")
        compile.push("-c")
        compile.push(source_file)
        compile.push(include_flag.as_str())
        compile.push("-DPLATFORM_DESKTOP_GLFW")
        compile.push("-DGRAPHICS_API_OPENGL_43")
        compile.push("-o")
        compile.push(object_file)
        match run_build_tool(compile.as_span(), "vendored raylib compile"):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success:
                pass

        ar_cmd.push(object_file)
        si += 1

    match run_build_tool(ar_cmd.as_span(), "vendored raylib archive"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored raylib build did not produce libraylib.a"
        ))

    return Result[bool, string.String].success(value = true)


function prepare_vendored_glfw(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "glfw-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored GLFW source not found: the glfw binding needs third_party/glfw-upstream to build libglfw3"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-glfw-prefix")
    defer: prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libglfw3.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/glfw-upstream")
    defer: source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-glfw")
    defer: build_dir.release()
    var prefix_define = string.String.from_str("-DCMAKE_INSTALL_PREFIX=")
    prefix_define.append(prefix.as_str())
    defer: prefix_define.release()

    var configure = vec.Vec[str].create()
    defer: configure.release()
    configure.push("cmake")
    configure.push("-S")
    configure.push(source_dir.as_str())
    configure.push("-B")
    configure.push(build_dir.as_str())
    configure.push("-G")
    configure.push("Ninja")
    configure.push(prefix_define.as_str())
    configure.push("-DCMAKE_BUILD_TYPE=Release")
    configure.push("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
    configure.push("-DBUILD_SHARED_LIBS=OFF")
    configure.push("-DGLFW_BUILD_EXAMPLES=OFF")
    configure.push("-DGLFW_BUILD_TESTS=OFF")
    configure.push("-DGLFW_BUILD_DOCS=OFF")
    match run_build_tool(configure.as_span(), "vendored GLFW cmake configure"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var build_cmd = vec.Vec[str].create()
    defer: build_cmd.release()
    build_cmd.push("cmake")
    build_cmd.push("--build")
    build_cmd.push(build_dir.as_str())
    build_cmd.push("--target")
    build_cmd.push("install")
    match run_build_tool(build_cmd.as_span(), "vendored GLFW build"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored GLFW build did not produce lib/libglfw3.a"
        ))

    return Result[bool, string.String].success(value = true)


function prepare_vendored_tracy(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "tracy-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Tracy source not found: the tracy binding needs third_party/tracy-upstream to build libtracyclient"
        ))

    var lib_dir = path_ops.join(root, "tmp/tracy-lib")
    defer: lib_dir.release()
    var archive = path_ops.join(lib_dir.as_str(), "libtracyclient.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    match fs.create_directories(lib_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            return Result[bool, string.String].failure(error = string.String.from_str(
                "could not create tmp/tracy-lib for the vendored Tracy client"
            ))
        Result.success:
            pass

    var public_dir = path_ops.join(root, "third_party/tracy-upstream/public")
    defer: public_dir.release()
    var source_file = path_ops.join(public_dir.as_str(), "TracyClient.cpp")
    defer: source_file.release()
    var object_file = path_ops.join(lib_dir.as_str(), "TracyClient.o")
    defer: object_file.release()
    var include_flag = string.String.from_str("-I")
    include_flag.append(public_dir.as_str())
    defer: include_flag.release()

    var compile = vec.Vec[str].create()
    defer: compile.release()
    compile.push("c++")
    compile.push("-c")
    compile.push(source_file.as_str())
    compile.push(include_flag.as_str())
    compile.push("-DTRACY_ENABLE")
    compile.push("-o")
    compile.push(object_file.as_str())
    match run_build_tool(compile.as_span(), "vendored Tracy client compile"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var ar_cmd = vec.Vec[str].create()
    defer: ar_cmd.release()
    ar_cmd.push("ar")
    ar_cmd.push("rcs")
    ar_cmd.push(archive.as_str())
    ar_cmd.push(object_file.as_str())
    match run_build_tool(ar_cmd.as_span(), "vendored Tracy client archive"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Tracy build did not produce libtracyclient.a"
        ))

    return Result[bool, string.String].success(value = true)


## Build the vendored cJSON static library from third_party/cjson-upstream when
## the program imports `std.cjson`.  cJSON is a single-source C library; we
## compile cJSON.c and archive it as libcjson.a.
function prepare_vendored_cjson(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "cjson-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored cJSON source not found: std.json needs third_party/cjson-upstream to build libcjson"
        ))

    var lib_dir = path_ops.join(root, "tmp/vendored-cjson")
    defer: lib_dir.release()
    var archive = path_ops.join(lib_dir.as_str(), "libcjson.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    match fs.create_directories(lib_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            return Result[bool, string.String].failure(error = string.String.from_str(
                "could not create tmp/vendored-cjson for the vendored cJSON build"
            ))
        Result.success:
            pass

    var src_dir = path_ops.join(root, "third_party/cjson-upstream")
    defer: src_dir.release()
    var include_flag = string.String.from_str("-I")
    include_flag.append(src_dir.as_str())
    defer: include_flag.release()

    var source_file = path_ops.join(src_dir.as_str(), "cJSON.c")
    defer: source_file.release()
    var object_file = path_ops.join(lib_dir.as_str(), "cJSON.o")
    defer: object_file.release()

    var compile = vec.Vec[str].create()
    defer: compile.release()
    compile.push("cc")
    compile.push("-c")
    compile.push(source_file.as_str())
    compile.push(include_flag.as_str())
    compile.push("-o")
    compile.push(object_file.as_str())
    match run_build_tool(compile.as_span(), "vendored cJSON compile"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var ar_cmd = vec.Vec[str].create()
    defer: ar_cmd.release()
    ar_cmd.push("ar")
    ar_cmd.push("rcs")
    ar_cmd.push(archive.as_str())
    ar_cmd.push(object_file.as_str())
    match run_build_tool(ar_cmd.as_span(), "vendored cJSON archive"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored cJSON build did not produce libcjson.a"
        ))

    return Result[bool, string.String].success(value = true)


## Build the vendored Box2D static library from third_party/box2d-upstream via
## CMake + Ninja.  Produces tmp/vendored-box2d-prefix/lib/libbox2d.a.
function prepare_vendored_box2d(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "box2d-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Box2D source not found: the box2d binding needs third_party/box2d-upstream to build libbox2d"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-box2d-prefix")
    defer: prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libbox2d.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/box2d-upstream")
    defer: source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-box2d")
    defer: build_dir.release()
    var prefix_define = string.String.from_str("-DCMAKE_INSTALL_PREFIX=")
    prefix_define.append(prefix.as_str())
    defer: prefix_define.release()

    var configure = vec.Vec[str].create()
    defer: configure.release()
    configure.push("cmake")
    configure.push("-S")
    configure.push(source_dir.as_str())
    configure.push("-B")
    configure.push(build_dir.as_str())
    configure.push("-G")
    configure.push("Ninja")
    configure.push(prefix_define.as_str())
    configure.push("-DCMAKE_BUILD_TYPE=Release")
    configure.push("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
    configure.push("-DBUILD_SHARED_LIBS=OFF")
    configure.push("-DBOX2D_SAMPLES=OFF")
    configure.push("-DBOX2D_BENCHMARKS=OFF")
    configure.push("-DBOX2D_DOCS=OFF")
    configure.push("-DBOX2D_PROFILE=OFF")
    configure.push("-DBOX2D_VALIDATE=OFF")
    configure.push("-DBOX2D_UNIT_TESTS=OFF")
    match run_build_tool(configure.as_span(), "vendored Box2D cmake configure"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var build_cmd = vec.Vec[str].create()
    defer: build_cmd.release()
    build_cmd.push("cmake")
    build_cmd.push("--build")
    build_cmd.push(build_dir.as_str())
    build_cmd.push("--target")
    build_cmd.push("install")
    match run_build_tool(build_cmd.as_span(), "vendored Box2D build"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Box2D build did not produce lib/libbox2d.a"
        ))

    return Result[bool, string.String].success(value = true)


## Build the vendored Box3D static library from third_party/box3d-upstream via
## CMake + Ninja.  Produces tmp/vendored-box3d-prefix/lib/libbox3d.a.
function prepare_vendored_box3d(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "box3d-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Box3D source not found: the box3d binding needs third_party/box3d-upstream to build libbox3d"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-box3d-prefix")
    defer: prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libbox3d.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/box3d-upstream")
    defer: source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-box3d")
    defer: build_dir.release()
    var prefix_define = string.String.from_str("-DCMAKE_INSTALL_PREFIX=")
    prefix_define.append(prefix.as_str())
    defer: prefix_define.release()

    var configure = vec.Vec[str].create()
    defer: configure.release()
    configure.push("cmake")
    configure.push("-S")
    configure.push(source_dir.as_str())
    configure.push("-B")
    configure.push(build_dir.as_str())
    configure.push("-G")
    configure.push("Ninja")
    configure.push(prefix_define.as_str())
    configure.push("-DCMAKE_BUILD_TYPE=Release")
    configure.push("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
    configure.push("-DBUILD_SHARED_LIBS=OFF")
    configure.push("-DBOX3D_SAMPLES=OFF")
    configure.push("-DBOX3D_BENCHMARKS=OFF")
    configure.push("-DBOX3D_DOCS=OFF")
    configure.push("-DBOX3D_PROFILE=OFF")
    configure.push("-DBOX3D_VALIDATE=OFF")
    configure.push("-DBOX3D_UNIT_TESTS=OFF")
    match run_build_tool(configure.as_span(), "vendored Box3D cmake configure"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var build_cmd = vec.Vec[str].create()
    defer: build_cmd.release()
    build_cmd.push("cmake")
    build_cmd.push("--build")
    build_cmd.push(build_dir.as_str())
    build_cmd.push("--target")
    build_cmd.push("install")
    match run_build_tool(build_cmd.as_span(), "vendored Box3D build"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Box3D build did not produce lib/libbox3d.a"
        ))

    return Result[bool, string.String].success(value = true)


## Build the vendored SDL3 static library from third_party/sdl3-upstream via
## CMake + Ninja.  Produces tmp/vendored-sdl3-prefix/lib/libSDL3.a.
function prepare_vendored_sdl3(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "sdl3-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored SDL3 source not found: the sdl3 binding needs third_party/sdl3-upstream to build libSDL3"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-sdl3-prefix")
    defer: prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libSDL3.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/sdl3-upstream")
    defer: source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-sdl3")
    defer: build_dir.release()
    var prefix_define = string.String.from_str("-DCMAKE_INSTALL_PREFIX=")
    prefix_define.append(prefix.as_str())
    defer: prefix_define.release()

    var configure = vec.Vec[str].create()
    defer: configure.release()
    configure.push("cmake")
    configure.push("-S")
    configure.push(source_dir.as_str())
    configure.push("-B")
    configure.push(build_dir.as_str())
    configure.push("-G")
    configure.push("Ninja")
    configure.push(prefix_define.as_str())
    configure.push("-DCMAKE_BUILD_TYPE=Release")
    configure.push("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
    configure.push("-DSDL_SHARED=OFF")
    configure.push("-DSDL_STATIC=ON")
    configure.push("-DSDL_TEST_LIBRARY=OFF")
    configure.push("-DSDL_TESTS=OFF")
    configure.push("-DSDL_EXAMPLES=OFF")
    match run_build_tool(configure.as_span(), "vendored SDL3 cmake configure"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var build_cmd = vec.Vec[str].create()
    defer: build_cmd.release()
    build_cmd.push("cmake")
    build_cmd.push("--build")
    build_cmd.push(build_dir.as_str())
    build_cmd.push("--target")
    build_cmd.push("install")
    match run_build_tool(build_cmd.as_span(), "vendored SDL3 build"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored SDL3 build did not produce lib/libSDL3.a"
        ))

    return Result[bool, string.String].success(value = true)


## Build the vendored Flecs static library from third_party/flecs-upstream.
## Flecs ships a single-source amalgamation in distr/flecs.c.  Produces
## tmp/vendored-flecs/libflecs.a.
function prepare_vendored_flecs(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "flecs-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Flecs source not found: the flecs binding needs third_party/flecs-upstream to build libflecs"
        ))

    var lib_dir = path_ops.join(root, "tmp/vendored-flecs")
    defer: lib_dir.release()
    var archive = path_ops.join(lib_dir.as_str(), "libflecs.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    match fs.create_directories(lib_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            return Result[bool, string.String].failure(error = string.String.from_str(
                "could not create tmp/vendored-flecs for the vendored Flecs build"
            ))
        Result.success:
            pass

    var src_dir = path_ops.join(root, "third_party/flecs-upstream/distr")
    defer: src_dir.release()
    var include_flag = string.String.from_str("-I")
    include_flag.append(src_dir.as_str())
    defer: include_flag.release()

    var source_file = path_ops.join(src_dir.as_str(), "flecs.c")
    defer: source_file.release()
    var object_file = path_ops.join(lib_dir.as_str(), "flecs.o")
    defer: object_file.release()

    var compile = vec.Vec[str].create()
    defer: compile.release()
    compile.push("cc")
    compile.push("-c")
    compile.push(source_file.as_str())
    compile.push(include_flag.as_str())
    compile.push("-std=gnu99")
    compile.push("-o")
    compile.push(object_file.as_str())
    match run_build_tool(compile.as_span(), "vendored Flecs compile"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var ar_cmd = vec.Vec[str].create()
    defer: ar_cmd.release()
    ar_cmd.push("ar")
    ar_cmd.push("rcs")
    ar_cmd.push(archive.as_str())
    ar_cmd.push(object_file.as_str())
    match run_build_tool(ar_cmd.as_span(), "vendored Flecs archive"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Flecs build did not produce libflecs.a"
        ))

    return Result[bool, string.String].success(value = true)


## Build the vendored PCRE2 static library from third_party/pcre2-upstream via
## CMake + Ninja.  Produces tmp/vendored-pcre2-prefix/lib/libpcre2-8.a.
function prepare_vendored_pcre2(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "pcre2-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored PCRE2 source not found: the pcre2 binding needs third_party/pcre2-upstream to build libpcre2-8"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-pcre2-prefix")
    defer: prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libpcre2-8.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/pcre2-upstream")
    defer: source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-pcre2")
    defer: build_dir.release()
    var prefix_define = string.String.from_str("-DCMAKE_INSTALL_PREFIX=")
    prefix_define.append(prefix.as_str())
    defer: prefix_define.release()

    var configure = vec.Vec[str].create()
    defer: configure.release()
    configure.push("cmake")
    configure.push("-S")
    configure.push(source_dir.as_str())
    configure.push("-B")
    configure.push(build_dir.as_str())
    configure.push("-G")
    configure.push("Ninja")
    configure.push(prefix_define.as_str())
    configure.push("-DCMAKE_BUILD_TYPE=Release")
    configure.push("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
    configure.push("-DBUILD_SHARED_LIBS=OFF")
    configure.push("-DPCRE2_BUILD_PCRE2_8=ON")
    configure.push("-DPCRE2_BUILD_PCRE2_16=OFF")
    configure.push("-DPCRE2_BUILD_PCRE2_32=OFF")
    configure.push("-DPCRE2_BUILD_PCRE2GREP=OFF")
    configure.push("-DPCRE2_BUILD_PCRE2TEST=OFF")
    configure.push("-DPCRE2_BUILD_TESTS=OFF")
    match run_build_tool(configure.as_span(), "vendored PCRE2 cmake configure"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var build_cmd = vec.Vec[str].create()
    defer: build_cmd.release()
    build_cmd.push("cmake")
    build_cmd.push("--build")
    build_cmd.push(build_dir.as_str())
    build_cmd.push("--target")
    build_cmd.push("install")
    match run_build_tool(build_cmd.as_span(), "vendored PCRE2 build"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored PCRE2 build did not produce lib/libpcre2-8.a"
        ))

    return Result[bool, string.String].success(value = true)


## Stage the vendored Steamworks SDK shared library for linking.  Copies
## libsteam_api.so from third_party/steamworks-sdk-upstream into
## tmp/vendored-steamworks/.
function prepare_vendored_steamworks(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "steamworks-sdk-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Steamworks SDK not found: the steamworks binding needs third_party/steamworks-sdk-upstream"
        ))

    var lib_dir = path_ops.join(root, "tmp/vendored-steamworks")
    defer: lib_dir.release()
    var archive = path_ops.join(lib_dir.as_str(), "libsteam_api.so")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    match fs.create_directories(lib_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            return Result[bool, string.String].failure(error = string.String.from_str(
                "could not create tmp/vendored-steamworks for the vendored Steamworks SDK"
            ))
        Result.success:
            pass

    var sdk_dir = path_ops.join(root, "third_party/steamworks-sdk-upstream/redistributable_bin/linux64")
    defer: sdk_dir.release()
    var source_file = path_ops.join(sdk_dir.as_str(), "libsteam_api.so")
    defer: source_file.release()

    if not fs.is_file(source_file.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "Steamworks SDK libsteam_api.so not found in third_party/steamworks-sdk-upstream/redistributable_bin/linux64"
        ))

    var copy_cmd = vec.Vec[str].create()
    defer: copy_cmd.release()
    copy_cmd.push("cp")
    copy_cmd.push(source_file.as_str())
    copy_cmd.push(archive.as_str())
    match run_build_tool(copy_cmd.as_span(), "vendored Steamworks SDK copy"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored Steamworks staging did not produce libsteam_api.so"
        ))

    return Result[bool, string.String].success(value = true)


## A shared libuv left in the prefix by an older build shadows the static
## archive on the `-L` search path and silently restores the runtime dependency
## on a system `libuv.so`.  The vendored contract is a static archive, so remove
## any such leftovers.
function remove_stale_shared_libuv(prefix: str) -> void:
    var lib_dir = path_ops.join(prefix, "lib")
    defer: lib_dir.release()
    match fs.list_entries(lib_dir.as_str()):
        Result.failure as failure:
            var err = failure.error
            err.release()
        Result.success as entries_payload:
            var entries = entries_payload.value
            defer: entries.release()
            var i: ptr_uint = 0
            while i < entries.len():
                let entry = entries.get(i) else:
                    break
                if entry.starts_with("libuv.so"):
                    var path = path_ops.join(lib_dir.as_str(), entry)
                    match fs.remove(path.as_str()):
                        Result.failure as failure:
                            var err = failure.error
                            err.release()
                        Result.success:
                            pass
                    path.release()
                i += 1


## Build the vendored libuv static library from third_party/libuv-upstream via
## CMake + Ninja.  Produces tmp/vendored-libuv-prefix/lib/libuv.a.
function prepare_vendored_libuv(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "libuv-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored libuv source not found: the libuv binding needs third_party/libuv-upstream to build libuv"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-libuv-prefix")
    defer: prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libuv.a")
    defer: archive.release()
    if fs.is_file(archive.as_str()):
        remove_stale_shared_libuv(prefix.as_str())
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/libuv-upstream")
    defer: source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-libuv")
    defer: build_dir.release()
    var prefix_define = string.String.from_str("-DCMAKE_INSTALL_PREFIX=")
    prefix_define.append(prefix.as_str())
    defer: prefix_define.release()

    var configure = vec.Vec[str].create()
    defer: configure.release()
    configure.push("cmake")
    configure.push("-S")
    configure.push(source_dir.as_str())
    configure.push("-B")
    configure.push(build_dir.as_str())
    configure.push("-G")
    configure.push("Ninja")
    configure.push(prefix_define.as_str())
    configure.push("-DCMAKE_BUILD_TYPE=Release")
    configure.push("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
    configure.push("-DBUILD_SHARED_LIBS=OFF")
    configure.push("-DLIBUV_BUILD_TESTS=OFF")
    configure.push("-DLIBUV_BUILD_BENCH=OFF")
    match run_build_tool(configure.as_span(), "vendored libuv cmake configure"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    var build_cmd = vec.Vec[str].create()
    defer: build_cmd.release()
    build_cmd.push("cmake")
    build_cmd.push("--build")
    build_cmd.push(build_dir.as_str())
    build_cmd.push("--target")
    build_cmd.push("install")
    match run_build_tool(build_cmd.as_span(), "vendored libuv build"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored libuv build did not produce lib/libuv.a"
        ))

    remove_stale_shared_libuv(prefix.as_str())
    return Result[bool, string.String].success(value = true)


## Vendored library link flags: the `-L` search path for each vendored archive
## the program's raw bindings need, plus the static-link system dependencies the
## vendored pkg-config metadata declares (GLFW's `Libs.private: -lrt -lm -ldl`).
## The `-l<lib>` flags themselves come from the bindings' `link "..."` directives
## (`glfw3`, `tracyclient`, `stdc++`); GNU ld applies `-L` to all `-l` options
## regardless of command-line order.
function collect_vendored_link_flags(program: loader.Program, roots: span[str]) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()

    # `-lraylib` (from the bindings' `link "raylib"` directive) must resolve to
    # the vendored static archive, not the system libraylib.so: the system
    # package embeds an X11-only GLFW whose GLX context creation fails on
    # Wayland sessions, while the vendored build links the system libglfw.so
    # (Wayland-capable).  These are the DESKTOP_SYSTEM_LINK_FLAGS of Ruby's
    # VendoredRaylib.
    if uses_vendored_raylib(program):
        match vendored_source_root(roots, "raylib-upstream"):
            Option.some as raylib_root:
                var lib_dir = path_ops.join(raylib_root.value, "tmp/vendored-raylib-opengl43")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
                result.push(string.String.from_str("-lglfw"))
                result.push(string.String.from_str("-lm"))
                result.push(string.String.from_str("-ldl"))
                result.push(string.String.from_str("-lpthread"))
                result.push(string.String.from_str("-lrt"))
                result.push(string.String.from_str("-lX11"))
            Option.none:
                pass

    if uses_binding_module(program, "std.c.glfw"):
        match vendored_source_root(roots, "glfw-upstream"):
            Option.some as glfw_root:
                var lib_dir = path_ops.join(glfw_root.value, "tmp/vendored-glfw-prefix/lib")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
                result.push(string.String.from_str("-lrt"))
                result.push(string.String.from_str("-lm"))
                result.push(string.String.from_str("-ldl"))
            Option.none:
                pass

    if uses_binding_module(program, "std.c.tracy"):
        match vendored_source_root(roots, "tracy-upstream"):
            Option.some as tracy_root:
                var lib_dir = path_ops.join(tracy_root.value, "tmp/tracy-lib")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
            Option.none:
                pass

    if uses_binding_module(program, "std.cjson"):
        match vendored_source_root(roots, "cjson-upstream"):
            Option.some as cjson_root:
                var lib_dir = path_ops.join(cjson_root.value, "tmp/vendored-cjson")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
            Option.none:
                pass

    if uses_binding_module(program, "std.c.box3d"):
        match vendored_source_root(roots, "box3d-upstream"):
            Option.some as box3d_root:
                var box3d_lib_dir = path_ops.join(box3d_root.value, "tmp/vendored-box3d-prefix/lib")
                var box3d_lib_flag = string.String.from_str("-L")
                box3d_lib_flag.append(box3d_lib_dir.as_str())
                result.push(box3d_lib_flag)
                result.push(string.String.from_str("-lbox3d"))
                result.push(string.String.from_str("-lm"))
                box3d_lib_dir.release()
            Option.none:
                pass

    if uses_binding_module(program, "std.c.box2d"):
        match vendored_source_root(roots, "box2d-upstream"):
            Option.some as box2d_root:
                var lib_dir = path_ops.join(box2d_root.value, "tmp/vendored-box2d-prefix/lib")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
                result.push(string.String.from_str("-lm"))
            Option.none:
                pass

    if uses_binding_module(program, "std.c.sdl3"):
        match vendored_source_root(roots, "sdl3-upstream"):
            Option.some as sdl3_root:
                var lib_dir = path_ops.join(sdl3_root.value, "tmp/vendored-sdl3-prefix/lib")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
                # The static SDL3 archive's own dependencies (the vendored
                # build's `sdl3.pc` lists `Libs: -lSDL3 -pthread -lm`).
                result.push(string.String.from_str("-pthread"))
                result.push(string.String.from_str("-lm"))
            Option.none:
                pass

    if uses_binding_module(program, "std.c.flecs"):
        match vendored_source_root(roots, "flecs-upstream"):
            Option.some as flecs_root:
                var lib_dir = path_ops.join(flecs_root.value, "tmp/vendored-flecs")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
                result.push(string.String.from_str("-lrt"))
                result.push(string.String.from_str("-lpthread"))
                result.push(string.String.from_str("-lm"))
            Option.none:
                pass

    if uses_binding_module(program, "std.c.pcre2"):
        match vendored_source_root(roots, "pcre2-upstream"):
            Option.some as pcre2_root:
                var lib_dir = path_ops.join(pcre2_root.value, "tmp/vendored-pcre2-prefix/lib")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
                result.push(string.String.from_str("-lm"))
            Option.none:
                pass

    if uses_binding_module(program, "std.c.steamworks"):
        match vendored_source_root(roots, "steamworks-sdk-upstream"):
            Option.some as sw_root:
                var lib_dir = path_ops.join(sw_root.value, "tmp/vendored-steamworks")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
            Option.none:
                pass

    if uses_binding_module(program, "std.c.libuv"):
        match vendored_source_root(roots, "libuv-upstream"):
            Option.some as uv_root:
                var lib_dir = path_ops.join(uv_root.value, "tmp/vendored-libuv-prefix/lib")
                var search_flag = string.String.from_str("-L")
                search_flag.append(lib_dir.as_str())
                lib_dir.release()
                result.push(search_flag)
            Option.none:
                pass

    return result


## Run an external build tool to completion, returning a readable error message
## (including the tool's stderr) on a non-zero exit or launch failure.
function run_build_tool(command: span[str], label: str) -> Result[bool, string.String]:
    match process.capture(command):
        Result.success as captured:
            var result = captured.value
            defer: result.stdout.release()
            defer: result.stderr.release()
            if result.status.exit_code == 0:
                return Result[bool, string.String].success(value = true)
            var message = string.String.from_str(label)
            message.append(" failed:\n")
            message.append(result.stderr.as_str())
            return Result[bool, string.String].failure(error = message)
        Result.failure as failure:
            var err = failure.error
            err.release()
            var message = string.String.from_str("could not launch ")
            message.append(label)
            return Result[bool, string.String].failure(error = message)


## Multi-string join helper (mirrors c_backend j2).
