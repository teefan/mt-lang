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


## One pinned upstream checkout: `dir` is relative to the data root, and the
## first `sentinel_count` entries of `sentinels` must exist for it to count as
## present.
struct UpstreamSource:
    name: str
    dir: str
    url: str
    revision: str
    sentinels: array[str, 6]
    sentinel_count: ptr_uint


public function source_count() -> ptr_uint:
    return 18


public function source_at(index: ptr_uint) -> UpstreamSource:
    if index == 0:
        return UpstreamSource(
            name = "raylib",
            dir = "third_party/raylib-upstream",
            url = "https://github.com/raysan5/raylib.git",
            revision = "dbc56a87da87d973a9c5baa4e7438a9d20121d28",
            sentinels = array[str, 6]("src/raylib.h", "examples/shapes/raygui.h", "examples/core/msf_gif.h", "", "", ""),
            sentinel_count = 3,
        )
    if index == 1:
        return UpstreamSource(
            name = "sdl3",
            dir = "third_party/sdl3-upstream",
            url = "https://github.com/libsdl-org/SDL.git",
            revision = "41f079491a0e79b22441fd32a7c8ad91db237744",
            sentinels = array[str, 6]("CMakeLists.txt", "include/SDL3/SDL.h", "include/SDL3/SDL_main.h", "", "", ""),
            sentinel_count = 3,
        )
    if index == 2:
        return UpstreamSource(
            name = "glfw",
            dir = "third_party/glfw-upstream",
            url = "https://github.com/glfw/glfw.git",
            revision = "b00e6a8a88ad1b60c0a045e696301deb92c9a13e",
            sentinels = array[str, 6]("include/GLFW/glfw3.h", "include/GLFW/glfw3native.h", "", "", "", ""),
            sentinel_count = 2,
        )
    if index == 3:
        return UpstreamSource(
            name = "opengl_registry",
            dir = "third_party/opengl-registry-upstream",
            url = "https://github.com/KhronosGroup/OpenGL-Registry.git",
            revision = "9cb90ca4902d588bef3c830fbb1da484893bd5fb",
            sentinels = array[str, 6]("xml/gl.xml", "xml/glx.xml", "xml/wgl.xml", "", "", ""),
            sentinel_count = 3,
        )
    if index == 4:
        return UpstreamSource(
            name = "box2d",
            dir = "third_party/box2d-upstream",
            url = "https://github.com/erincatto/box2d.git",
            revision = "ddfd9df727a06940af34b5bc2ef79bcaba287d50",
            sentinels = array[str, 6]("include/box2d/box2d.h", "", "", "", "", ""),
            sentinel_count = 1,
        )
    if index == 5:
        return UpstreamSource(
            name = "box3d",
            dir = "third_party/box3d-upstream",
            url = "https://github.com/erincatto/box3d.git",
            revision = "30c67b5e6d0a3a66f0f506c69ce9e9e0587e3b7c",
            sentinels = array[str, 6]("include/box3d/box3d.h", "", "", "", "", ""),
            sentinel_count = 1,
        )
    if index == 6:
        return UpstreamSource(
            name = "cjson",
            dir = "third_party/cjson-upstream",
            url = "https://github.com/DaveGamble/cJSON.git",
            revision = "c859b25da02955fef659d658b8f324b5cde87be3",
            sentinels = array[str, 6]("cJSON.h", "cJSON.c", "", "", "", ""),
            sentinel_count = 2,
        )
    if index == 7:
        return UpstreamSource(
            name = "flecs",
            dir = "third_party/flecs-upstream",
            url = "https://github.com/SanderMertens/flecs.git",
            revision = "d7d0c4f7afb4518a6bae749efdc52c7cb5cffee6",
            sentinels = array[str, 6]("distr/flecs.c", "distr/flecs.h", "include/flecs.h", "", "", ""),
            sentinel_count = 3,
        )
    if index == 8:
        return UpstreamSource(
            name = "libuv",
            dir = "third_party/libuv-upstream",
            url = "https://github.com/libuv/libuv.git",
            revision = "1cfa32ff59c076ffb6ed735bbc8c18361558661f",
            sentinels = array[str, 6]("CMakeLists.txt", "include/uv.h", "include/uv/version.h", "", "", ""),
            sentinel_count = 3,
        )
    if index == 9:
        return UpstreamSource(
            name = "pcre2",
            dir = "third_party/pcre2-upstream",
            url = "https://github.com/PCRE2Project/pcre2.git",
            revision = "b2bd4254b379b9d7dc9a3dda060a7e27009ccdff",
            sentinels = array[str, 6]("CMakeLists.txt", "src/pcre2.h.generic", "src/pcre2_compile.c", "", "", ""),
            sentinel_count = 3,
        )
    if index == 10:
        return UpstreamSource(
            name = "steamworks_sdk",
            dir = "third_party/steamworks-sdk-upstream",
            url = "https://github.com/rlabrecque/steamworkssdk.git",
            revision = "be6107f4b75bf996531415c53a6488a33a2a1be3",
            sentinels = array[str, 6](
                "public/steam/steam_api.h",
                "public/steam/steam_api_common.h",
                "public/steam/steam_api_internal.h",
                "public/steam/steam_api_flat.h",
                "public/steam/steam_api.json",
                "public/steam/steam_gameserver.h",
            ),
            sentinel_count = 6,
        )
    if index == 11:
        return UpstreamSource(
            name = "miniaudio",
            dir = "third_party/miniaudio-upstream",
            url = "https://github.com/mackron/miniaudio.git",
            revision = "9634bedb5b5a2ca38c1ee7108a9358a4e233f14d",
            sentinels = array[str, 6]("miniaudio.h", "", "", "", "", ""),
            sentinel_count = 1,
        )
    if index == 12:
        return UpstreamSource(
            name = "tracy",
            dir = "third_party/tracy-upstream",
            url = "https://github.com/wolfpld/tracy.git",
            revision = "v0.13.1",
            sentinels = array[str, 6]("public/tracy/TracyC.h", "", "", "", "", ""),
            sentinel_count = 1,
        )
    if index == 13:
        return UpstreamSource(
            name = "raygui",
            dir = "third_party/raygui-upstream",
            url = "https://github.com/raysan5/raygui.git",
            revision = "5.0",
            sentinels = array[str, 6]("src/raygui.h", "", "", "", "", ""),
            sentinel_count = 1,
        )
    if index == 14:
        return UpstreamSource(
            name = "rres",
            dir = "third_party/rres-upstream",
            url = "https://github.com/raysan5/rres.git",
            revision = "5f2a7310197f8b7843ab5b024277a14da83f68f9",
            sentinels = array[str, 6]("src/rres.h", "", "", "", "", ""),
            sentinel_count = 1,
        )
    if index == 15:
        return UpstreamSource(
            name = "rpng",
            dir = "third_party/rpng-upstream",
            url = "https://github.com/raysan5/rpng.git",
            revision = "b8c05ae4e9d7535f8bceac9ea365211ae7401cee",
            sentinels = array[str, 6]("src/rpng.h", "", "", "", "", ""),
            sentinel_count = 1,
        )
    if index == 16:
        return UpstreamSource(
            name = "stb",
            dir = "third_party/stb-upstream",
            url = "https://github.com/nothings/stb.git",
            revision = "31c1ad37456438565541f4919958214b6e762fb4",
            sentinels = array[str, 6]("stb_image.h", "stb_truetype.h", "", "", "", ""),
            sentinel_count = 2,
        )
    return UpstreamSource(
        name = "cgltf",
        dir = "third_party/cgltf-upstream",
        url = "https://github.com/jkuhlmann/cgltf.git",
        revision = "85cd62382dfea638278962690cf515023f33ed00",
        sentinels = array[str, 6]("cgltf.h", "", "", "", "", ""),
        sentinel_count = 1,
    )


## `config/upstream_versions.yml`'s entry for one source.
struct SourceOverride:
    name: string.String
    has_revision: bool
    revision: string.String
    has_sentinels: bool
    sentinels: vec.Vec[string.String]


extending SourceOverride:
    public editable function release() -> void:
        this.name.release()
        this.revision.release()
        var i: ptr_uint = 0
        while i < this.sentinels.len():
            let p = this.sentinels.get(i) else:
                break
            unsafe:
                read(p).release()
            i += 1
        this.sentinels.release()


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
        return doctor_command()
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


## `unknown toolchain option <arg>` + help for any argument after the
## subcommand; true when one was present.
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
    let root_opt = compiler_root()
    var data_root = data_root_dir(root_opt)
    defer: data_root.release()

    var overrides = load_overrides(data_root.as_str())
    defer: release_overrides(ref_of(overrides))

    let total = source_count()
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
        let src = source_at(i)
        var checkout = path_ops.join(data_root.as_str(), src.dir)
        defer: checkout.release()
        let complete = source_complete(checkout.as_str(), src, ref_of(overrides))
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

        let revision = revision_for(src, ref_of(overrides))
        var failure_message = string.String.create()
        let bootstrapped = bootstrap_source(
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


## True when the checkout directory and every sentinel exist.
function source_complete(checkout: str, src: UpstreamSource, overrides: ref[vec.Vec[SourceOverride]]) -> bool:
    if not fs.is_directory(checkout):
        return false
    let override = find_override(overrides, src.name)
    if override != null:
        let entry = unsafe: read(override)
        if entry.has_sentinels:
            var i: ptr_uint = 0
            while i < entry.sentinels.len():
                let sp = entry.sentinels.get(i) else:
                    break
                var path = path_ops.join(checkout, unsafe: read(sp).as_str())
                let present = fs.exists(path.as_str())
                path.release()
                if not present:
                    return false
                i += 1
            return true
    var i: ptr_uint = 0
    while i < src.sentinel_count:
        var path = path_ops.join(checkout, src.sentinels[i])
        let present = fs.exists(path.as_str())
        path.release()
        if not present:
            return false
        i += 1
    return true


function revision_for(src: UpstreamSource, overrides: ref[vec.Vec[SourceOverride]]) -> str:
    let override = find_override(overrides, src.name)
    if override != null:
        let entry = unsafe: read(override)
        if entry.has_revision:
            return entry.revision.as_str()
    return src.revision


## Remove an incomplete checkout, clone the pinned revision, and verify.
function bootstrap_source(checkout: str, url: str, revision: str, src: UpstreamSource, overrides: ref[vec.Vec[SourceOverride]], failure_message: ref[string.String]) -> bool:
    if fs.exists(checkout):
        match fs.remove_tree(checkout):
            Result.failure as remove_failure:
                var remove_error = remove_failure.error
                failure_message.assign(remove_error.message.as_str())
                remove_error.release()
                return false
            Result.success:
                pass

    var parent = path_ops.dirname(checkout)
    match fs.create_directories(parent):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            failure_message.assign(dir_error.message.as_str())
            dir_error.release()
            return false
        Result.success:
            pass

    var clone_cmd = vec.Vec[str].create()
    defer: clone_cmd.release()
    clone_cmd.push("git")
    clone_cmd.push("clone")
    clone_cmd.push(url)
    clone_cmd.push(checkout)
    match run_command(clone_cmd.as_span()):
        Result.failure as failure:
            var error = failure.error
            failure_message.assign("failed to bootstrap ")
            failure_message.append(src.name)
            failure_message.append(":\n")
            failure_message.append(error.as_str())
            error.release()
            return false
        Result.success:
            pass

    var checkout_cmd = vec.Vec[str].create()
    defer: checkout_cmd.release()
    checkout_cmd.push("git")
    checkout_cmd.push("-C")
    checkout_cmd.push(checkout)
    checkout_cmd.push("checkout")
    checkout_cmd.push("--detach")
    checkout_cmd.push(revision)
    match run_command(checkout_cmd.as_span()):
        Result.failure as failure:
            var error = failure.error
            failure_message.assign("failed to bootstrap ")
            failure_message.append(src.name)
            failure_message.append(":\n")
            failure_message.append(error.as_str())
            error.release()
            return false
        Result.success:
            pass

    if not source_complete(checkout, src, overrides):
        failure_message.assign("bootstrapped ")
        failure_message.append(src.name)
        failure_message.append(" but required files are still missing under ")
        failure_message.append(checkout)
        return false
    return true


## Run a command and return its combined output on a non-zero exit (the host's
## `run_git!` details) or the spawn error message when it cannot start.
function run_command(command: span[str]) -> Result[bool, string.String]:
    match process.capture(command):
        Result.success as captured:
            var result = captured.value
            let succeeded = result.status.success()
            if succeeded:
                result.release()
                return Result[bool, string.String].success(value = true)
            var details = string.String.create()
            match result.stdout_text():
                Option.some as stdout_text:
                    details.append(stdout_text.value)
                Option.none:
                    pass
            match result.stderr_text():
                Option.some as stderr_text:
                    details.append(stderr_text.value)
                Option.none:
                    pass
            result.release()
            return Result[bool, string.String].failure(error = details)
        Result.failure as spawn_failure:
            var error = spawn_failure.error
            let message = string.String.from_str(error.message.as_str())
            error.release()
            return Result[bool, string.String].failure(error = message)


## ── upstream_versions.yml ───────────────────────────────────────────────────

function load_overrides(root: str) -> vec.Vec[SourceOverride]:
    var result = vec.Vec[SourceOverride].create()
    var config_path = path_ops.join(root, "config/upstream_versions.yml")
    defer: config_path.release()
    match fs.read_text(config_path.as_str()):
        Result.failure:
            return result
        Result.success as payload:
            var text = payload.value
            defer: text.release()
            let source = text.as_str()
            var current_index: ptr_uint = 0
            var has_current = false
            var in_sentinels = false
            var start: ptr_uint = 0
            var pos: ptr_uint = 0
            while pos <= source.len:
                if pos == source.len or source.byte_at(pos) == 10:
                    let line = source.slice(start, pos - start)
                    parse_override_line(
                        line, ref_of(result), ref_of(current_index), ref_of(has_current), ref_of(in_sentinels)
                    )
                    start = pos + 1
                pos += 1
            return result


function parse_override_line(line: str, result: ref[vec.Vec[SourceOverride]], current_index: ref[ptr_uint], has_current: ref[bool], in_sentinels: ref[bool]) -> void:
    var indent: ptr_uint = 0
    while indent < line.len and line.byte_at(indent) == 32:
        indent += 1
    let trimmed = line.slice(indent, line.len - indent)
    if trimmed.len == 0 or trimmed.byte_at(0) == 35:
        return
    if trimmed.starts_with("- "):
        if not read(in_sentinels) or not read(has_current):
            return
        let item = strip_yaml_quotes(trimmed.slice(2, trimmed.len - 2).trim_ascii_whitespace())
        if item.len == 0:
            return
        let entry_ptr = result.get(read(current_index)) else:
            return
        unsafe:
            read(entry_ptr).sentinels.push(string.String.from_str(item))
        return

    match trimmed.find_substring(":"):
        Option.none:
            return
        Option.some as colon:
            let key = trimmed.slice(0, colon.value).trim_ascii_whitespace()
            let value = strip_yaml_quotes(
                trimmed.slice(colon.value + 1, trimmed.len - colon.value - 1).trim_ascii_whitespace()
            )
            if indent == 0:
                read(in_sentinels) = false
                result.push(SourceOverride(
                    name = string.String.from_str(key),
                    has_revision = value.len > 0,
                    revision = string.String.from_str(value),
                    has_sentinels = false,
                    sentinels = vec.Vec[string.String].create(),
                ))
                read(current_index) = result.len() - 1
                read(has_current) = true
                return
            if not read(has_current):
                return
            let entry_ptr = result.get(read(current_index)) else:
                return
            unsafe:
                var entry = read(entry_ptr)
                if key == "revision":
                    entry.revision.assign(value)
                    entry.has_revision = value.len > 0
                    read(in_sentinels) = false
                else if key == "sentinels":
                    entry.has_sentinels = true
                    read(in_sentinels) = true
                else:
                    read(in_sentinels) = false


function strip_yaml_quotes(value: str) -> str:
    if value.len >= 2:
        let first = value.byte_at(0)
        let last = value.byte_at(value.len - 1)
        if (first == 34 and last == 34) or (first == 39 and last == 39):
            return value.slice(1, value.len - 2)
    return value


function find_override(overrides: ref[vec.Vec[SourceOverride]], name: str) -> ptr[SourceOverride]?:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            if read(entry_ptr).name.as_str().equal(name):
                return entry_ptr
        i += 1
    return null


function release_overrides(overrides: ref[vec.Vec[SourceOverride]]) -> void:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            read(entry_ptr).release()
        i += 1
    overrides.release()


## ── tools ───────────────────────────────────────────────────────────────────

function tools_command(quiet: bool) -> int:
    let root_opt = compiler_root()
    var data_root = data_root_dir(root_opt)
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
        match run_command(configure.as_span()):
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
        match run_command(build_cmd.as_span()):
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
    match fs.metadata(path):
        Result.success as meta:
            let metadata = meta.value
            if not metadata.is_file():
                return false
            return (metadata.mode & 73) != 0
        Result.failure:
            return false


## ── doctor ──────────────────────────────────────────────────────────────────

## The self's existing simplified check: the external tools the build flow
## invokes.  (The host additionally reports Ruby, vendored-source sentinels and
## raw-binding headers; those rows are listed as remaining work in Track B.)
function doctor_command() -> int:
    var all_ok = true
    var checks: array[str, 6] = array[str, 6]("cc", "ar", "clang", "cmake", "ninja", "git")
    var i: ptr_uint = 0
    while i < 6:
        let tool = checks[i]
        if is_executable_on_path(tool):
            stdio.print_format(c"ok   %.*s\n", int<-(tool.len), tool.data)
        else:
            stdio.print_format(c"fail %.*s (not found on PATH)\n", int<-(tool.len), tool.data)
            all_ok = false
        i += 1
    if all_ok:
        return 0
    return 1


function is_executable_on_path(name: str) -> bool:
    var which_cmd = vec.Vec[str].create()
    defer: which_cmd.release()
    which_cmd.push("which")
    which_cmd.push(name)
    match process.capture(which_cmd.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.release()
            return result.status.exit_code == 0
        Result.failure:
            return false


## ── root discovery ──────────────────────────────────────────────────────────

## The compiler's source tree: the nearest ancestor of the running binary that
## contains `std/` (the same lookup `build_cache.cache_root` uses).
function compiler_root() -> Option[string.String]:
    match fs.canonicalize("/proc/self/exe"):
        Result.success as exe_payload:
            var exe = exe_payload.value
            defer: exe.release()
            return fs.find_ancestor_containing(exe.as_str(), "std")
        Result.failure as exe_failure:
            var exe_error = exe_failure.error
            exe_error.release()
            return Option[string.String].none


## `MilkTea.data_root`: the checkout when the binary runs from one, else the XDG
## cache directory (`$XDG_CACHE_HOME/milk_tea`, or `~/.cache/milk_tea`).
function data_root_dir(root_opt: Option[string.String]) -> string.String:
    match root_opt:
        Option.some as root_payload:
            return root_payload.value
        Option.none:
            pass
    match env.get("XDG_CACHE_HOME"):
        Option.some as xdg:
            if xdg.value.len > 0:
                return path_ops.join(xdg.value, "milk_tea")
        Option.none:
            pass
    match env.get("HOME"):
        Option.some as home:
            if home.value.len > 0:
                return path_ops.join(home.value, ".cache/milk_tea")
        Option.none:
            pass
    return string.String.from_str("/tmp/milk_tea")
