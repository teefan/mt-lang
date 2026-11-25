## Pinned upstream (vendored) source checkouts: the source table, the
## `config/upstream_versions.yml` overrides, and the clone/verify machinery.
##
## Extracted from `toolchain_cli` so `build` can fetch a missing tree on demand:
## the CLI entry point ranks above `build`, so a downward import of it was a
## layering violation.  Nothing here knows about the CLI, the doctor report or
## the vendored-tool build; those stay in `toolchain_cli`.

import std.env as env
import std.fs as fs
import std.path as path_ops
import std.process as process
import std.str as str
import std.string as string
import std.vec as vec


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
            # `math_types.h` is the discriminator, not just any header: it
            # appeared in 3.2.0 when `core.h`/`geometry.h` were dropped.  The
            # old sentinel (`box2d.h`) exists in *every* version, so a cached
            # 3.1.1 checkout satisfied it and was silently reused after the pin
            # moved to 3.2.0 — the CI failure this replaces.
            sentinels = array[str, 6]("include/box2d/math_types.h", "", "", "", "", ""),
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
public struct SourceOverride:
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


## The file a checkout records its own revision in.  Sentinels alone cannot
## detect a *version* change: every box2d release ships `include/box2d/box2d.h`,
## so a cached 3.1.1 tree satisfied the 3.2.0 pin's sentinel and was silently
## reused (the CI failure that prompted this).  The stamp makes a pin change
## visible.
const REVISION_STAMP: str = ".mt-source-revision"


## True when `checkout` records exactly `revision` in its stamp.
function revision_stamp_matches(checkout: str, revision: str) -> bool:
    var path = path_ops.join(checkout, REVISION_STAMP)
    defer: path.release()
    match fs.read_text(path.as_str()):
        Result.failure:
            return false
        Result.success as payload:
            var text = payload.value
            defer: text.release()
            return text.as_str().trim_ascii_whitespace().equal(revision)


## Record `revision` in the checkout's stamp.  Failure is reported because a
## silent failure would reintroduce the stale-checkout bug it prevents.
function write_revision_stamp(checkout: str, revision: str) -> bool:
    var path = path_ops.join(checkout, REVISION_STAMP)
    defer: path.release()
    match fs.write_text(path.as_str(), revision):
        Result.failure as failure:
            var error = failure.error
            error.release()
            return false
        Result.success:
            return true


## A checkout is usable only when the stamp matches the pinned revision *and*
## the sentinel files are present.  The revision is passed separately because
## it may come from `config/upstream_versions.yml`.
public function checkout_is_current(checkout: str, src: UpstreamSource, revision: str, overrides: ref[vec.Vec[SourceOverride]]) -> bool:
    return revision_stamp_matches(checkout, revision) and source_complete(checkout, src, overrides)


## True when the checkout directory and every sentinel exist.
public function source_complete(checkout: str, src: UpstreamSource, overrides: ref[vec.Vec[SourceOverride]]) -> bool:
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


public function revision_for(src: UpstreamSource, overrides: ref[vec.Vec[SourceOverride]]) -> str:
    let override = find_override(overrides, src.name)
    if override != null:
        let entry = unsafe: read(override)
        if entry.has_revision:
            return entry.revision.as_str()
    return src.revision


## Remove an incomplete checkout, clone the pinned revision, and verify.
public function bootstrap_source(checkout: str, url: str, revision: str, src: UpstreamSource, overrides: ref[vec.Vec[SourceOverride]], failure_message: ref[string.String]) -> bool:
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
    if not write_revision_stamp(checkout, revision):
        failure_message.assign("bootstrapped ")
        failure_message.append(src.name)
        failure_message.append(" but could not record its revision under ")
        failure_message.append(checkout)
        return false
    return true


## Run a command and return its combined output on a non-zero exit (the host's
## `run_git!` details) or the spawn error message when it cannot start.
public function run_command(command: span[str]) -> Result[bool, string.String]:
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

public function load_overrides(root: str) -> vec.Vec[SourceOverride]:
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


public function find_override(overrides: ref[vec.Vec[SourceOverride]], name: str) -> ptr[SourceOverride]?:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            if read(entry_ptr).name.as_str().equal(name):
                return entry_ptr
        i += 1
    return null


public function release_overrides(overrides: ref[vec.Vec[SourceOverride]]) -> void:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            read(entry_ptr).release()
        i += 1
    overrides.release()




## Ensure one pinned source (by `UpstreamSource.name`) is present under
## `data_root`, fetching it on demand.
##
## This is the seam `mtc build` uses: a vendored binding cannot link without its
## source tree, and requiring a separate `mtc toolchain bootstrap` was a gap
## every release re-exposed.  A warm checkout costs one stat.
public function ensure_source(name: str, data_root: str, failure_message: ref[string.String]) -> Option[string.String]:
    var overrides = load_overrides(data_root)
    defer: release_overrides(ref_of(overrides))

    var index: ptr_uint = 0
    while index < source_count():
        let src = source_at(index)
        if not src.name.equal(name):
            index += 1
            continue
        var checkout = path_ops.join(data_root, src.dir)
        let revision = revision_for(src, ref_of(overrides))
        if checkout_is_current(checkout.as_str(), src, revision, ref_of(overrides)):
            return Option[string.String].some(value = checkout)
        let ok = bootstrap_source(
            checkout.as_str(), src.url, revision, src, ref_of(overrides), failure_message
        )
        if ok:
            return Option[string.String].some(value = checkout)
        checkout.release()
        return Option[string.String].none
    return Option[string.String].none


## The first sentinel missing under `checkout` (the `toolchain doctor` report
## and the bootstrap skip both ask this), applying `upstream_versions.yml`'s
## sentinel overrides when present.
public function first_missing_sentinel(checkout: str, src: UpstreamSource, overrides: ref[vec.Vec[SourceOverride]]) -> Option[str]:
    let override = find_override(overrides, src.name)
    if override != null:
        let entry = unsafe: read(override)
        if entry.has_sentinels:
            var index: ptr_uint = 0
            while index < entry.sentinels.len():
                let sentinel_ptr = entry.sentinels.get(index) else:
                    break
                let sentinel = unsafe: read(sentinel_ptr).as_str()
                var path = path_ops.join(checkout, sentinel)
                let present = fs.exists(path.as_str())
                path.release()
                if not present:
                    return Option[str].some(value = sentinel)
                index += 1
            return Option[str].none

    var index: ptr_uint = 0
    while index < src.sentinel_count:
        let sentinel = src.sentinels[index]
        var path = path_ops.join(checkout, sentinel)
        let present = fs.exists(path.as_str())
        path.release()
        if not present:
            return Option[str].some(value = sentinel)
        index += 1
    return Option[str].none
