## DAP utilities — path resolution and helper functions.

import std.fs as fs_mod
import std.str
import std.string as string


## Resolve a DAP launch program path.  For .mt source files, the user
## must pre-build the binary with `mtc build` before launching the DAP
## session.  Raw binary paths are accepted directly.
public struct LaunchResolved:
    ok: bool
    runnable_path: string.String
    error: string.String


public function resolve_launch_program(program: str) -> LaunchResolved:
    if program.len == 0:
        return LaunchResolved(
            ok = false,
            runnable_path = string.String.create(),
            error = string.String.from_str("launch requires a non-empty 'program' argument")
        )

    if program.ends_with(".mt"):
        let bin_path = program.slice(0, program.len - 3)
        if fs_mod.exists(bin_path):
            return LaunchResolved(ok = true, runnable_path = string.String.from_str(bin_path), error = string.String.create())
        var err = string.String.create()
        err.append("Milk Tea binary not found: ")
        err.append(bin_path)
        err.append(" (build with mtc build first)")
        return LaunchResolved(ok = false, runnable_path = string.String.create(), error = err)

    if not fs_mod.exists(program):
        var err = string.String.create()
        err.append("Program not found: ")
        err.append(program)
        return LaunchResolved(ok = false, runnable_path = string.String.create(), error = err)

    return LaunchResolved(ok = true, runnable_path = string.String.from_str(program), error = string.String.create())


## Release a LaunchResolved struct.
public function release_launch_resolved(resolved: ref[LaunchResolved]) -> void:
    resolved.runnable_path.release()
    resolved.error.release()
