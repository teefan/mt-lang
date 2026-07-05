## Build driver — the Phase 1 native build path: lower the checked program to
## IR, generate C, write it to a temporary file, and invoke the C compiler to
## produce a binary.
##
## Mirrors the Ruby Build orchestration (lib/milk_tea/tooling/build.rb) in
## minimal form: no build cache, no package graph, no platform/profile matrix —
## those arrive in Phase 7.  Uses std.process to launch the compiler.

import std.fs as fs
import std.process as process
import std.string as string
import std.str
import std.vec as vec

import mtc.loader.module_loader as loader
import mtc.lowering.lowering as lowering
import mtc.c_backend.c_backend as c_backend


## Build a checked program to `output_path` using `c_compiler`.  On success the
## success value is the output path; on failure the error is a human-readable
## message (compiler diagnostics or driver error).
public function build(program: loader.Program, output_path: str, c_compiler: str) -> Result[string.String, string.String]:
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
    command.push("-o")
    command.push(output_path)
    command.push(c_path.as_str())

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
