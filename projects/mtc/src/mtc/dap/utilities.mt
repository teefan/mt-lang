## DAP utilities — launch-program resolution, temp builds and helpers.

import std.fs as fs_mod
import std.path as path_ops
import std.process as process
import std.str
import std.string as string
import std.vec as vec


## Result of resolving a launch `program`: the runnable executable and the
## temporary build directory that must be cleaned up (empty when the program
## was already built).
public struct LaunchResolved:
    ok: bool
    runnable_path: string.String
    tmp_dir: string.String
    error: string.String


## Resolve a DAP launch program.  A `.mt` source is compiled by the running
## compiler into a fresh temp directory with the host's debug settings
## (`debug: true, debug_guards: false` -> `--profile debug --no-debug-guards`,
## `dap/server/launch.rb:125-137`); a binary path is used as-is.
public function resolve_launch_program(program: str) -> LaunchResolved:
    if program.len == 0:
        return launch_failure(string.String.from_str("launch requires a non-empty 'program' argument"))

    var expanded = absolute_path(program)
    defer: expanded.release()

    if program.ends_with(".mt"):
        if not fs_mod.is_file(expanded.as_str()):
            var missing = string.String.from_str("Milk Tea program not found: ")
            missing.append(expanded.as_str())
            return launch_failure(missing)
        return build_launch_program(expanded.as_str())

    if not fs_mod.is_file(expanded.as_str()):
        var missing = string.String.from_str("Program not found: ")
        missing.append(expanded.as_str())
        return launch_failure(missing)

    return LaunchResolved(
        ok = true,
        runnable_path = string.String.from_str(expanded.as_str()),
        tmp_dir = string.String.create(),
        error = string.String.create(),
    )


## Compile a `.mt` source into a fresh temp directory.  On failure the temp
## directory is removed; on success the caller owns it via `tmp_dir`.
function build_launch_program(source_path: str) -> LaunchResolved:
    match fs_mod.create_temporary_directory_in_system_temp("milk-tea-dap-"):
        Result.failure as failure:
            var error = failure.error
            var message = string.String.from_str("could not create a temp directory: ")
            message.append(error.message.as_str())
            error.release()
            return launch_failure(message)
        Result.success as created:
            var tmp_dir = created.value
            var output_path = path_ops.join(tmp_dir.as_str(), path_ops.stem(source_path))
            defer: output_path.release()

            var exe = compiler_executable()
            defer: exe.release()
            if exe.is_empty():
                cleanup_dir(ref_of(tmp_dir))
                return launch_failure(string.String.from_str("could not locate the running compiler"))

            var command = vec.Vec[str].create()
            defer: command.release()
            command.push(exe.as_str())
            command.push("build")
            command.push(source_path)
            command.push("-o")
            command.push(output_path.as_str())
            command.push("--profile")
            command.push("debug")
            command.push("--no-debug-guards")

            match process.capture(command.as_span()):
                Result.success as captured:
                    var result = captured.value
                    defer: result.stdout.release()
                    defer: result.stderr.release()
                    if result.status.exit_code == 0:
                        return LaunchResolved(
                            ok = true,
                            runnable_path = string.String.from_str(output_path.as_str()),
                            tmp_dir = tmp_dir,
                            error = string.String.create(),
                        )
                    var message = build_error_message(result.stdout.as_str(), result.stderr.as_str())
                    cleanup_dir(ref_of(tmp_dir))
                    return launch_failure(message)
                Result.failure as failure:
                    var error = failure.error
                    var message = string.String.from_str("could not run the compiler: ")
                    message.append(error.message.as_str())
                    error.release()
                    cleanup_dir(ref_of(tmp_dir))
                    return launch_failure(message)


## The build failure text shown to the client (the build prints `error: ...`
## on stdout; fall back to stderr, then a generic line).
function build_error_message(stdout_text: str, stderr_text: str) -> string.String:
    if stdout_text.len > 0:
        return string.String.from_str(stdout_text)
    if stderr_text.len > 0:
        return string.String.from_str(stderr_text)
    return string.String.from_str("Milk Tea build failed")


## The running compiler (`/proc/self/exe`), or "mtc" from PATH when the link
## is unavailable.
function compiler_executable() -> string.String:
    match fs_mod.canonicalize("/proc/self/exe"):
        Result.success as exe:
            return exe.value
        Result.failure as failure:
            var error = failure.error
            error.release()
            return string.String.from_str("mtc")


## A failed resolution (no runnable, no temp dir).
function launch_failure(message: string.String) -> LaunchResolved:
    return LaunchResolved(
        ok = false,
        runnable_path = string.String.create(),
        tmp_dir = string.String.create(),
        error = message,
    )


## Remove a temp directory tree, swallowing failures, and release its string.
function cleanup_dir(dir: ref[string.String]) -> void:
    match fs_mod.remove_tree(dir.as_str()):
        Result.success:
            pass
        Result.failure as failure:
            var error = failure.error
            error.release()
    dir.release()


## Syntactic absolute path (the host's `File.expand_path`).
function absolute_path(path_text: str) -> string.String:
    if path_ops.is_absolute(path_text):
        return path_ops.normalize_separators(path_text)
    var cwd = string.String.create()
    defer: cwd.release()
    match fs_mod.current_directory():
        Result.success as current:
            cwd.assign(current.value.as_str())
            current.value.release()
        Result.failure as failure:
            var error = failure.error
            error.release()
            cwd.assign(".")
    return path_ops.join(cwd.as_str(), path_text)


## Release a LaunchResolved struct.
public function release_launch_resolved(resolved: ref[LaunchResolved]) -> void:
    resolved.runnable_path.release()
    resolved.tmp_dir.release()
    resolved.error.release()

## Dereference a ptr[ptr_uint] to a ptr_uint value.  The caller must
## ensure lp is non-null before calling.
public function read_ptr(lp: ptr[ptr_uint]) -> ptr_uint:
    unsafe: return read(lp)
