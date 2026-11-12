## Lexical path helpers for the package subsystem: the `File.expand_path`
## behavior the host relies on (absolute, `.`/`..` collapsed, symlinks kept).
## `fs.canonicalize` resolves symlinks and is the wrong primitive here because
## lockfile bytes and manifest paths must match the host's expansion.

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec


## Absolute lexical path: relative paths join the current directory, `.` and
## `..` segments collapse, duplicate separators drop, and no symlink is
## resolved.  Always returns an owned String.
public function absolute_path(path: str) -> string.String:
    var full = string.String.create()
    defer: full.release()
    if path_ops.is_absolute(path):
        full.append(path)
    else:
        match fs.current_directory():
            Result.success as cwd_payload:
                var cwd = cwd_payload.value
                defer: cwd.release()
                full.append(cwd.as_str())
                full.push_byte('/')
                full.append(path)
            Result.failure:
                full.append(path)

    var segments = vec.Vec[string.String].create()
    defer: segments.release()
    let text_path = full.as_str()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= text_path.len:
        if i == text_path.len or text_path.byte_at(i) == 47:
            if i > start:
                let seg = text_path.slice(start, i - start)
                if seg == "..":
                    match segments.pop():
                        Option.some as popped:
                            var owned = popped.value
                            owned.release()
                        Option.none:
                            pass
                else if seg != ".":
                    segments.push(string.String.from_str(seg))
            start = i + 1
        i += 1

    var result = string.String.create()
    result.push_byte('/')
    var si: ptr_uint = 0
    while si < segments.len():
        if si > 0:
            result.push_byte('/')
        let segment = segments.get(si) else:
            break
        result.append(unsafe: read(segment).as_str())
        si += 1
    return result


## True when `path` equals `root` or lies below it (both lexical absolutes).
public function path_within_root(path: str, root: str) -> bool:
    if path.equal(root):
        return true
    if path.len <= root.len:
        return false
    if not path.slice(0, root.len).equal(root):
        return false
    return path.byte_at(root.len) == 47


## `File.expand_path(value, root)`: an absolute value stands, a relative one
## joins `root`.
public function resolve_under(root: str, value: str) -> string.String:
    if path_ops.is_absolute(value):
        return absolute_path(value)
    var joined = path_ops.join(root, value)
    defer: joined.release()
    return absolute_path(joined.as_str())
