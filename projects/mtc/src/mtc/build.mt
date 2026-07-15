## Build driver — the Phase 1 native build path: lower the checked program to
## IR, generate C, write it to a temporary file, and invoke the C compiler to
## produce a binary.
##
## Mirrors the Ruby Build orchestration (lib/milk_tea/tooling/build.rb) in
## minimal form: no build cache, no package graph, no platform/profile matrix —
## those arrive in Phase 7.  Uses std.process to launch the compiler.

import std.fs as fs
import std.path as path_ops
import std.process as process
import std.string as string
import std.str
import std.vec as vec

import mtc.loader.module_loader as loader
import mtc.ir as ir
import mtc.c_backend.c_backend as c_backend
import mtc.parser.ast as ast


## Build a checked program to `output_path` using `c_compiler`.  `roots` are the
## module search roots (as passed on the CLI): the one containing `std/c` supplies
## the C ABI header include path.  `ir_program` is the caller-lowered IR (the CLI
## lowers once, so the entrypoint check and the build share a single lowering).
## On success the success value is the output path; on failure the error is a
## human-readable message.
public function build(program: loader.Program, ir_program: ir.Program, output_path: str, c_compiler: str, roots: span[str]) -> Result[string.String, string.String]:
    # Vendored static libraries (GLFW, the Tracy client) must exist before the
    # link step; build them on demand for raw bindings that require them.
    match prepare_vendored_libraries(program, roots):
        Result.failure as prep_failure:
            return Result[string.String, string.String].failure(error = prep_failure.error)
        Result.success:
            pass

    var c_source = c_backend.generate_c(ir_program)
    defer c_source.release()

    var c_path = string.String.from_str("/tmp/mtc_build.c")
    defer c_path.release()

    match fs.write_text(c_path.as_str(), c_source.as_str()):
        Result.success:
            pass
        Result.failure as failure:
            var err = failure.error
            err.release()
            return Result[string.String, string.String].failure(
                error = string.String.from_str("could not write generated C source")
            )

    var command = vec.Vec[str].create()
    defer command.release()
    command.push(c_compiler)
    command.push("-std=c11")
    command.push("-D_GNU_SOURCE")

    # C ABI struct definitions (`fs_support.h`, etc.) live under `<root>/std/c`;
    # add the include path from whichever root contains that directory.
    var include_flag = std_c_include_flag(roots)
    defer include_flag.release()
    if include_flag.len() > 0:
        command.push(include_flag.as_str())

    command.push("-o")
    command.push(output_path)
    command.push(c_path.as_str())

    # Link libraries declared via `link "..."` directives in external modules
    # (e.g. `link "uv"` in std.c.fs → `-luv`).
    var link_flags = collect_link_flags(program)
    defer link_flags.release()
    var lfi: ptr_uint = 0
    while lfi < link_flags.len():
        let flag_ptr = link_flags.get(lfi) else:
            break
        unsafe:
            command.push(read(flag_ptr).as_str())
        lfi += 1

    # Vendored static library search paths (`-L`) plus their static-link system
    # dependencies.  The `-l<lib>` flags themselves come from the bindings'
    # `link "..."` directives above; GNU ld applies `-L` to all `-l` options
    # regardless of order.
    var vendored_flags = collect_vendored_link_flags(program, roots)
    defer vendored_flags.release()
    var vfi: ptr_uint = 0
    while vfi < vendored_flags.len():
        let flag_ptr = vendored_flags.get(vfi) else:
            break
        unsafe:
            command.push(read(flag_ptr).as_str())
        vfi += 1

    # Binding build flags (include paths and implementation defines) that the
    # raw std.c.* modules require but do not express as source directives — e.g.
    # raygui needs its header include path plus -DRAYGUI_IMPLEMENTATION.  These
    # mirror the Ruby raw-binding registry entries.
    var binding_flags = collect_binding_flags(program, roots)
    defer binding_flags.release()
    var bfi: ptr_uint = 0
    while bfi < binding_flags.len():
        let flag_ptr = binding_flags.get(bfi) else:
            break
        unsafe:
            command.push(read(flag_ptr).as_str())
        bfi += 1

    match process.capture(command.as_span()):
        Result.success as captured:
            var result = captured.value
            defer result.stdout.release()
            defer result.stderr.release()
            if result.status.exit_code == 0:
                return Result[string.String, string.String].success(value = string.String.from_str(output_path))
            var message = string.String.from_str("C compiler exited with an error:\n")
            message.append(result.stderr.as_str())
            return Result[string.String, string.String].failure(error = message)
        Result.failure as failure:
            var err = failure.error
            err.release()
            var message = string.String.from_str("could not launch C compiler '")
            message.append(c_compiler)
            message.append("'")
            return Result[string.String, string.String].failure(error = message)


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
## registry: raygui needs its vendored header include path plus
## `-DRAYGUI_IMPLEMENTATION -DGRAPHICS_API_OPENGL_43`, rlgl-facing modules
## need `-DGRAPHICS_API_OPENGL_43 -DMT_LANG_GL_REGISTRY_HAVE_RAYLIB`, glfw needs
## the vendored GLFW headers (the pinned tree defines constants such as
## `GLFW_UNLIMITED_MOUSE_BUTTONS` that system headers may lack), and tracy needs
## the vendored TracyC.h include paths plus `-DTRACY_ENABLE`.  Header paths are
## resolved relative to whichever module root contains the vendored tree, so no
## absolute machine path is baked in.
function collect_binding_flags(program: loader.Program, roots: span[str]) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()
    var uses_raygui = false
    var uses_rlgl = false
    var uses_gl = false
    var uses_glfw = false
    var uses_tracy = false
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            break
        var analysis = unsafe: read(a_ptr)
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
        mi += 1

    if uses_raygui:
        var include_dir = vendored_raylib_include(roots, "examples/shapes")
        defer include_dir.release()
        if include_dir.len() > 0:
            result.push(string.String.from_str(j2("-I", include_dir.as_str())))
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
        defer glfw_include.release()
        if glfw_include.len() > 0:
            result.push(string.String.from_str(j2("-I", glfw_include.as_str())))
        result.push(string.String.from_str("-DMT_LANG_GL_REGISTRY_HAVE_GLFW"))

    if uses_tracy:
        var tracy_inner = vendored_tree_path(roots, "tracy-upstream/public/tracy")
        defer tracy_inner.release()
        if tracy_inner.len() > 0:
            result.push(string.String.from_str(j2("-I", tracy_inner.as_str())))
        var tracy_public = vendored_tree_path(roots, "tracy-upstream/public")
        defer tracy_public.release()
        if tracy_public.len() > 0:
            result.push(string.String.from_str(j2("-I", tracy_public.as_str())))
        result.push(string.String.from_str("-DTRACY_ENABLE"))

    return result


## Absolute path to a subdirectory of the vendored raylib tree
## (`third_party/raylib-upstream/<sub>`), searched under each module root.
## Returns an empty string when no root contains the vendored tree.
function vendored_raylib_include(roots: span[str], sub: str) -> string.String:
    return vendored_tree_path(roots, j2("raylib-upstream/", sub))


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
## when their archives are not already present:
##   - `std.c.glfw`  → `tmp/vendored-glfw-prefix/lib/libglfw3.a` (CMake + Ninja
##     from `third_party/glfw-upstream`; the binding's `link "glfw3"` expects the
##     vendored archive — system packages ship `libglfw`, not `libglfw3`)
##   - `std.c.tracy` → `tmp/tracy-lib/libtracyclient.a` (`c++ TracyClient.cpp`
##     with `-DTRACY_ENABLE`, then `ar rcs`; no system package provides it)
## The vendored sources are pinned trees, so an existing archive is reused
## as-is.  Mirrors Ruby's VendoredCLibrary CMake/Archive `prepare!` flow in
## minimal form.
function prepare_vendored_libraries(program: loader.Program, roots: span[str]) -> Result[bool, string.String]:
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

    return Result[bool, string.String].success(value = true)


function prepare_vendored_glfw(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "glfw-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored GLFW source not found: the glfw binding needs third_party/glfw-upstream to build libglfw3"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-glfw-prefix")
    defer prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libglfw3.a")
    defer archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/glfw-upstream")
    defer source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-glfw")
    defer build_dir.release()
    var prefix_define = string.String.from_str("-DCMAKE_INSTALL_PREFIX=")
    prefix_define.append(prefix.as_str())
    defer prefix_define.release()

    var configure = vec.Vec[str].create()
    defer configure.release()
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
    defer build_cmd.release()
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
    defer lib_dir.release()
    var archive = path_ops.join(lib_dir.as_str(), "libtracyclient.a")
    defer archive.release()
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
    defer public_dir.release()
    var source_file = path_ops.join(public_dir.as_str(), "TracyClient.cpp")
    defer source_file.release()
    var object_file = path_ops.join(lib_dir.as_str(), "TracyClient.o")
    defer object_file.release()
    var include_flag = string.String.from_str("-I")
    include_flag.append(public_dir.as_str())
    defer include_flag.release()

    var compile = vec.Vec[str].create()
    defer compile.release()
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
    defer ar_cmd.release()
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


## Vendored library link flags: the `-L` search path for each vendored archive
## the program's raw bindings need, plus the static-link system dependencies the
## vendored pkg-config metadata declares (GLFW's `Libs.private: -lrt -lm -ldl`).
## The `-l<lib>` flags themselves come from the bindings' `link "..."` directives
## (`glfw3`, `tracyclient`, `stdc++`); GNU ld applies `-L` to all `-l` options
## regardless of command-line order.
function collect_vendored_link_flags(program: loader.Program, roots: span[str]) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()

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

    return result


## Run an external build tool to completion, returning a readable error message
## (including the tool's stderr) on a non-zero exit or launch failure.
function run_build_tool(command: span[str], label: str) -> Result[bool, string.String]:
    match process.capture(command):
        Result.success as captured:
            var result = captured.value
            defer result.stdout.release()
            defer result.stderr.release()
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
function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()
