## `mtc watch PATH` — poll `.mt` files and rebuild on changes.
##
## Each rebuild is a child `mtc build` process, so the long-lived watcher never
## accumulates the compiler's per-build arenas/IR.  With `--split` the child
## uses the per-TU object cache, so unchanged units are not recompiled.
##
## The first version polls mtimes/sizes (no platform fs-event backend) and
## watches the entry's directory plus every `-I` root recursively.  It does not
## yet reuse the loader's ModuleCache in-process; that is the follow-up once the
## child-build loop is proven.

import std.fs as fs
import std.parse as parse_mod
import std.path as path_ops
import std.process as process
import std.stdio as stdio
import std.terminal as terminal
import std.string as string
import std.time as time
import std.vec as vec

import mtc.cli_help as cli_help


struct WatchFile:
    path: string.String
    mtime_seconds: ptr_int
    mtime_nanoseconds: ptr_int
    size: ptr_uint


function watch_file_release(files: ref[vec.Vec[WatchFile]]) -> void:
    var i: ptr_uint = 0
    while i < files.len():
        let file_ptr = files.get(i) else:
            break
        unsafe: read(file_ptr).path.release()
        i += 1
    files.release()


function watch_roots_has(roots: ref[vec.Vec[string.String]], value: str) -> bool:
    var i: ptr_uint = 0
    while i < roots.len():
        let root_ptr = roots.get(i) else:
            break
        if unsafe: read(root_ptr).as_str() == value:
            return true
        i += 1
    return false


function watch_files_find(files: ref[vec.Vec[WatchFile]], path: str) -> ptr[WatchFile]?:
    var i: ptr_uint = 0
    while i < files.len():
        let file_ptr = files.get(i) else:
            break
        if unsafe: read(file_ptr).path.as_str() == path:
            return file_ptr
        i += 1
    return null


function collect_watch_files(roots: ref[vec.Vec[string.String]], files: ref[vec.Vec[WatchFile]]) -> void:
    var ri: ptr_uint = 0
    while ri < roots.len():
        let root_ptr = roots.get(ri) else:
            break
        let root = unsafe: read(root_ptr).as_str()
        match fs.list_files_recursive(root):
            Result.failure as failure:
                var error = failure.error
                error.release()
            Result.success as payload:
                var entries = payload.value
                defer: entries.release()
                var ei: ptr_uint = 0
                while ei < entries.len():
                    let path = entries.get(ei) else:
                        break
                    if path.ends_with(".mt") and watch_files_find(ref_of(files), path) == null:
                        match fs.metadata(path):
                            Result.success as meta_payload:
                                var meta = meta_payload.value
                                files.push(WatchFile(
                                    path = string.String.from_str(path),
                                    mtime_seconds = meta.modified_seconds,
                                    mtime_nanoseconds = meta.modified_nanoseconds,
                                    size = meta.size
                                ))
                            Result.failure:
                                pass
                    ei += 1
        ri += 1


function snapshots_differ(
    old: ref[vec.Vec[WatchFile]],
    fresh: ref[vec.Vec[WatchFile]],
) -> bool:
    if old.len() != fresh.len():
        return true
    var i: ptr_uint = 0
    while i < old.len():
        let old_ptr = old.get(i) else:
            break
        let old_file = unsafe: read(old_ptr)
        let new_ptr = watch_files_find(ref_of(fresh), old_file.path.as_str()) else:
            return true
        let new_file = unsafe: read(new_ptr)
        if (
            old_file.mtime_seconds != new_file.mtime_seconds
            or old_file.mtime_nanoseconds != new_file.mtime_nanoseconds
            or old_file.size != new_file.size
        ):
            return true
        i += 1
    return false


function print_captured_output(stdout_text: str, stderr_text: str) -> void:
    if stdout_text.len > 0:
        stdio.print_format(c"%.*s", int<-stdout_text.len, stdout_text.data)
    if stderr_text.len > 0:
        stdio.print_format(c"%.*s", int<-stderr_text.len, stderr_text.data)


function run_watch_build(self_bin: str, build_args: span[str]) -> bool:
    var command = vec.Vec[str].create()
    defer: command.release()
    command.push(self_bin)
    var i: ptr_uint = 0
    while i < build_args.len:
        command.push(build_args[i])
        i += 1
    match process.capture(command.as_span()):
        Result.failure as failure:
            var error = failure.error
            stdio.print_line("watch: could not launch build")
            error.release()
            return false
        Result.success as captured:
            var result = captured.value
            defer:
                result.stdout.release()
                result.stderr.release()
            print_captured_output(result.stdout.as_str(), result.stderr.as_str())
            return result.status.exit_code == 0


function run_watch_program(output: str) -> void:
    var command = vec.Vec[str].create()
    defer: command.release()
    command.push(output)
    match process.capture(command.as_span()):
        Result.failure as failure:
            var error = failure.error
            stdio.print_line("watch: could not launch program")
            error.release()
        Result.success as captured:
            var result = captured.value
            defer:
                result.stdout.release()
                result.stderr.release()
            print_captured_output(result.stdout.as_str(), result.stderr.as_str())


## `mtc watch PATH [--run] [--interval MS] [BUILD OPTIONS]`.
public function watch_command(args: span[str]) -> int:
    var start: ptr_uint = 0
    if args.len > 0 and args[0] == "watch":
        start = 1

    var source = string.String.create()
    defer: source.release()
    var build_args = vec.Vec[str].create()
    defer: build_args.release()
    build_args.push("build")
    var interval_ms: ptr_uint = 500
    var run_after_build = false
    var i: ptr_uint = start
    while i < args.len:
        let arg = args[i]
        if arg == "--interval":
            if i + 1 >= args.len:
                stdio.print_line("missing value for --interval")
                return 1
            let parsed = parse_mod.parse_int(args[i + 1], 10)
            if parsed <= 0:
                stdio.print_line("--interval must be a positive number of milliseconds")
                return 1
            interval_ms = ptr_uint<-parsed
            i += 2
            continue
        if arg == "--run":
            run_after_build = true
            i += 1
            continue
        if (
            arg == "-I" or arg == "--include-path"
            or arg == "-o" or arg == "--output"
            or arg == "--cc" or arg == "--profile"
            or arg == "--platform" or arg == "--keep-c"
        ) and i + 1 < args.len:
            build_args.push(arg)
            build_args.push(args[i + 1])
            i += 2
            continue
        if not arg.starts_with("-") and source.len() == 0:
            source.append(arg)
        build_args.push(arg)
        i += 1
    if source.len() == 0:
        cli_help.print_command_help("watch", true)
        return 1

    var output = string.String.create()
    defer: output.release()
    var has_output = false
    var bi: ptr_uint = 1
    while bi < build_args.len():
        let arg_ptr = build_args.get(bi) else:
            break
        let arg = unsafe: read(arg_ptr)
        if (arg == "-o" or arg == "--output") and bi + 1 < build_args.len():
            let value_ptr = build_args.get(bi + 1) else:
                break
            output.append(unsafe: read(value_ptr))
            has_output = true
            bi += 2
            continue
        bi += 1
    if not has_output:
        var stem_name = string.String.create()
        defer: stem_name.release()
        stem_name.append(path_ops.stem(source.as_str()))
        stem_name.append(".watch")
        var default_output = path_ops.join(path_ops.dirname(source.as_str()), stem_name.as_str())
        defer: default_output.release()
        output.append(default_output.as_str())
        build_args.push("-o")
        build_args.push(output.as_str())

    var self_bin = string.String.create()
    defer: self_bin.release()
    match fs.canonicalize("/proc/self/exe"):
        Result.success as exe_payload:
            self_bin.append(exe_payload.value.as_str())
            exe_payload.value.release()
        Result.failure:
            self_bin.append("mtc")

    var roots = vec.Vec[string.String].create()
    defer:
        var ri: ptr_uint = 0
        while ri < roots.len():
            let root_ptr = roots.get(ri) else:
                break
            unsafe: read(root_ptr).release()
            ri += 1
        roots.release()
    roots.push(string.String.from_str(path_ops.dirname(source.as_str())))
    bi = 1
    while bi < build_args.len():
        let arg_ptr = build_args.get(bi) else:
            break
        let arg = unsafe: read(arg_ptr)
        if (arg == "-I" or arg == "--include-path") and bi + 1 < build_args.len():
            let value_ptr = build_args.get(bi + 1) else:
                break
            let include_path = unsafe: read(value_ptr)
            if not watch_roots_has(ref_of(roots), include_path):
                roots.push(string.String.from_str(include_path))
            bi += 2
            continue
        bi += 1

    let build_ok = run_watch_build(self_bin.as_str(), build_args.as_span())
    if build_ok and run_after_build:
        run_watch_program(output.as_str())

    var files = vec.Vec[WatchFile].create()
    defer: watch_file_release(ref_of(files))
    collect_watch_files(ref_of(roots), ref_of(files))
    stdio.print_format(
        c"watching %zu .mt file(s); interval %zu ms; output %.*s\n",
        files.len(),
        interval_ms,
        int<-output.as_str().len,
        output.as_str().data
    )
    let _ = terminal.flush_stdout()

    while true:
        let _ = time.sleep_milliseconds(interval_ms)
        var fresh = vec.Vec[WatchFile].create()
        collect_watch_files(ref_of(roots), ref_of(fresh))
        if not snapshots_differ(ref_of(files), ref_of(fresh)):
            watch_file_release(ref_of(fresh))
            continue
        watch_file_release(ref_of(files))
        files = fresh
        var dirty = true
        while dirty:
            stdio.print_line("change detected; rebuilding")
            let _ = terminal.flush_stdout()
            let ok = run_watch_build(self_bin.as_str(), build_args.as_span())
            if ok and run_after_build:
                run_watch_program(output.as_str())
            var after = vec.Vec[WatchFile].create()
            collect_watch_files(ref_of(roots), ref_of(after))
            dirty = snapshots_differ(ref_of(files), ref_of(after))
            watch_file_release(ref_of(files))
            files = after
            if dirty:
                stdio.print_line("source changed during rebuild; rebuilding")
            let _ = terminal.flush_stdout()
    return 0
