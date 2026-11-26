## Polling helpers for `mtc watch`: snapshot `.mt` metadata under the entry's
## directory and every `-I` root, and compare snapshots.  The command loop lives
## in `main/build_cli.mt`, which owns the ModuleCache and forked build path.

import std.fs as fs
import std.string as string
import std.vec as vec


public struct WatchFile:
    path: string.String
    mtime_seconds: ptr_int
    mtime_nanoseconds: ptr_int
    size: ptr_uint


public function watch_file_release(files: ref[vec.Vec[WatchFile]]) -> void:
    var i: ptr_uint = 0
    while i < files.len():
        let file_ptr = files.get(i) else:
            break
        unsafe: read(file_ptr).path.release()
        i += 1
    files.release()


public function watch_roots_has(roots: ref[vec.Vec[string.String]], value: str) -> bool:
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


public function collect_watch_files(roots: ref[vec.Vec[string.String]], files: ref[vec.Vec[WatchFile]]) -> void:
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


public function snapshots_differ(
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
