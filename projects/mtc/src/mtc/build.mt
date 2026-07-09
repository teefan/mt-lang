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
import mtc.lowering.lowering as lowering
import mtc.c_backend.c_backend as c_backend
import mtc.parser.ast as ast


## Build a checked program to `output_path` using `c_compiler`.  `roots` are the
## module search roots (as passed on the CLI): the one containing `std/c` supplies
## the C ABI header include path.  On success the success value is the output
## path; on failure the error is a human-readable message.
public function build(program: loader.Program, output_path: str, c_compiler: str, roots: span[str]) -> Result[string.String, string.String]:
    let ir_program = lowering.lower(program)
    var c_source = c_backend.generate_c(ir_program)
    defer c_source.release()

    var c_path: string.String
    match fs.create_temporary_file_in_system_temp("mtc", ".c"):
        Result.success as created:
            c_path = created.value
        Result.failure as failure:
            var err = failure.error
            err.release()
            return Result[string.String, string.String].failure(
                error = string.String.from_str("could not create temporary C file")
            )
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
## raw external modules.  Mirrors Ruby's link-library collection.
function collect_link_flags(program: loader.Program) -> vec.Vec[string.String]:
    var link_libs = vec.Vec[string.String].create()
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            break
        var analysis = unsafe: read(a_ptr)
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
    return link_libs


## True when a `-l<lib>` flag is already collected (dedup).
function link_lib_seen(link_libs: ref[vec.Vec[string.String]], flag: str) -> bool:
    var i: ptr_uint = 0
    while i < link_libs.len():
        let f_ptr = link_libs.get(i) else:
            break
        unsafe:
            if read(f_ptr).as_str().equal(flag):
                return true
        i += 1
    return false
