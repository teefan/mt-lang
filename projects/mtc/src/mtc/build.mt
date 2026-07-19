## Build driver — lower the checked program to IR, generate C, write it to a
## temporary file, compile it, and link it against any required vendored static
## libraries.  Mirrors the Ruby Build orchestration (lib/milk_tea/tooling/build.rb).
## Build-cache checks and package-graph resolution are handled by the CLI layer
## (main.mt).

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
## When `sanitize` is true, the binary is compiled with AddressSanitizer and UBSan.
## On success the success value is the output path; on failure the error is a
## human-readable message.
public function build(program: loader.Program, ir_program: ir.Program, output_path: str, c_compiler: str, roots: span[str], sanitize: bool) -> Result[string.String, string.String]:
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
    if sanitize:
        command.push("-fsanitize=address,undefined")
        command.push("-fno-sanitize-recover=all")
        command.push("-fno-omit-frame-pointer")

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
        defer raylib_src.release()
        if raylib_src.len() > 0:
            result.push(string.String.from_str(j2("-I", raylib_src.as_str())))
        result.push(string.String.from_str("-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB"))
        result.push(string.String.from_str("-DPLATFORM_DESKTOP_GLFW"))
        result.push(string.String.from_str("-DGRAPHICS_API_OPENGL_43"))

    if uses_raymath:
        result.push(string.String.from_str("-DRAYMATH_STATIC_INLINE"))

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

    if uses_cjson:
        var cjson_include = vendored_tree_path(roots, "cjson-upstream")
        defer cjson_include.release()
        if cjson_include.len() > 0:
            result.push(string.String.from_str(j2("-I", cjson_include.as_str())))

    if uses_box2d:
        var box2d_include = vendored_tree_path(roots, "box2d-upstream/include")
        defer box2d_include.release()
        if box2d_include.len() > 0:
            result.push(string.String.from_str(j2("-I", box2d_include.as_str())))

    if uses_sdl3:
        var sdl3_include = vendored_tree_path(roots, "sdl3-upstream/include")
        defer sdl3_include.release()
        if sdl3_include.len() > 0:
            result.push(string.String.from_str(j2("-I", sdl3_include.as_str())))
        result.push(string.String.from_str("-DSDL_MAIN_HANDLED"))

    if uses_flecs:
        var flecs_include = vendored_tree_path(roots, "flecs-upstream/distr")
        defer flecs_include.release()
        if flecs_include.len() > 0:
            result.push(string.String.from_str(j2("-I", flecs_include.as_str())))

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
        defer sw_include.release()
        if sw_include.len() > 0:
            result.push(string.String.from_str(j2("-I", sw_include.as_str())))

    if uses_libuv:
        var uv_include = vendored_tree_path(roots, "libuv-upstream/include")
        defer uv_include.release()
        if uv_include.len() > 0:
            result.push(string.String.from_str(j2("-I", uv_include.as_str())))

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
    defer build_dir.release()
    var archive = path_ops.join(build_dir.as_str(), "libraylib.a")
    defer archive.release()
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
    defer src_dir.release()
    var include_flag = string.String.from_str("-I")
    include_flag.append(src_dir.as_str())
    defer include_flag.release()

    let sources = array[str, 6]("rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "rmodels.c", "raudio.c")

    var ar_cmd = vec.Vec[str].create()
    defer ar_cmd.release()
    ar_cmd.push("ar")
    ar_cmd.push("rcs")
    ar_cmd.push(archive.as_str())

    var si: ptr_uint = 0
    while si < 6:
        let source_name = sources[si]
        let source_file = j2(src_dir.as_str(), j2("/", source_name))
        let object_file = j2(build_dir.as_str(), j2("/", j2(source_name, ".o")))

        var compile = vec.Vec[str].create()
        defer compile.release()
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


## Build the vendored cJSON static library from third_party/cjson-upstream when
## the program imports `std.cjson`.  cJSON is a single-source C library; we
## compile cJSON.c and archive it as libcjson.a.
function prepare_vendored_cjson(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "cjson-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored cJSON source not found: std.json needs third_party/cjson-upstream to build libcjson"
        ))

    var lib_dir = path_ops.join(root, "tmp/vendored-cjson")
    defer lib_dir.release()
    var archive = path_ops.join(lib_dir.as_str(), "libcjson.a")
    defer archive.release()
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
    defer src_dir.release()
    var include_flag = string.String.from_str("-I")
    include_flag.append(src_dir.as_str())
    defer include_flag.release()

    var source_file = path_ops.join(src_dir.as_str(), "cJSON.c")
    defer source_file.release()
    var object_file = path_ops.join(lib_dir.as_str(), "cJSON.o")
    defer object_file.release()

    var compile = vec.Vec[str].create()
    defer compile.release()
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
    defer ar_cmd.release()
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
    defer prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libbox2d.a")
    defer archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/box2d-upstream")
    defer source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-box2d")
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
    defer build_cmd.release()
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


## Build the vendored SDL3 static library from third_party/sdl3-upstream via
## CMake + Ninja.  Produces tmp/vendored-sdl3-prefix/lib/libSDL3.a.
function prepare_vendored_sdl3(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "sdl3-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored SDL3 source not found: the sdl3 binding needs third_party/sdl3-upstream to build libSDL3"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-sdl3-prefix")
    defer prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libSDL3.a")
    defer archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/sdl3-upstream")
    defer source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-sdl3")
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
    defer build_cmd.release()
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
    defer lib_dir.release()
    var archive = path_ops.join(lib_dir.as_str(), "libflecs.a")
    defer archive.release()
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
    defer src_dir.release()
    var include_flag = string.String.from_str("-I")
    include_flag.append(src_dir.as_str())
    defer include_flag.release()

    var source_file = path_ops.join(src_dir.as_str(), "flecs.c")
    defer source_file.release()
    var object_file = path_ops.join(lib_dir.as_str(), "flecs.o")
    defer object_file.release()

    var compile = vec.Vec[str].create()
    defer compile.release()
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
    defer ar_cmd.release()
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
    defer prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libpcre2-8.a")
    defer archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/pcre2-upstream")
    defer source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-pcre2")
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
    defer build_cmd.release()
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
    defer lib_dir.release()
    var archive = path_ops.join(lib_dir.as_str(), "libsteam_api.so")
    defer archive.release()
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
    defer sdk_dir.release()
    var source_file = path_ops.join(sdk_dir.as_str(), "libsteam_api.so")
    defer source_file.release()

    if not fs.is_file(source_file.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "Steamworks SDK libsteam_api.so not found in third_party/steamworks-sdk-upstream/redistributable_bin/linux64"
        ))

    var copy_cmd = vec.Vec[str].create()
    defer copy_cmd.release()
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


## Build the vendored libuv static library from third_party/libuv-upstream via
## CMake + Ninja.  Produces tmp/vendored-libuv-prefix/lib/libuv.a.
function prepare_vendored_libuv(roots: span[str]) -> Result[bool, string.String]:
    let root = vendored_source_root(roots, "libuv-upstream") else:
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored libuv source not found: the libuv binding needs third_party/libuv-upstream to build libuv"
        ))

    var prefix = path_ops.join(root, "tmp/vendored-libuv-prefix")
    defer prefix.release()
    var archive = path_ops.join(prefix.as_str(), "lib/libuv.a")
    defer archive.release()
    if fs.is_file(archive.as_str()):
        return Result[bool, string.String].success(value = true)

    var source_dir = path_ops.join(root, "third_party/libuv-upstream")
    defer source_dir.release()
    var build_dir = path_ops.join(root, "tmp/vendored-libuv")
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
    configure.push("-DLIBUV_BUILD_TESTS=OFF")
    configure.push("-DLIBUV_BUILD_BENCH=OFF")
    match run_build_tool(configure.as_span(), "vendored libuv cmake configure"):
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
    match run_build_tool(build_cmd.as_span(), "vendored libuv build"):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success:
            pass

    if not fs.is_file(archive.as_str()):
        return Result[bool, string.String].failure(error = string.String.from_str(
            "vendored libuv build did not produce lib/libuv.a"
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
