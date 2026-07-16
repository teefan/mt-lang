## Build cache for compiled binaries (`mtc build` / `mtc run`), mirroring the
## user-visible behavior of Ruby's BuildCache in minimal form: an unchanged
## program rebuilds to a byte-identical binary, so the second build reuses the
## cached one and reports `[cached]`.
##
## A cache entry is correct by construction: the full key material — the mtc
## executable's own content hash, the C compiler identity, the build
## configuration, and every loaded module's path and source — is stored beside
## the binary and compared byte-for-byte on lookup.  The FNV-1a hash only names
## the entry directory; a hash collision degrades to a cache miss, never to a
## wrong binary.  `--no-cache` bypasses both lookup and store.

import std.fs as fs
import std.libc as libc
import std.path as path_ops
import std.process as process
import std.str as text
import std.string as string
import std.vec as vec

import mtc.loader.module_loader as loader


## FNV-1a 64-bit over raw bytes, rendered as 16 lowercase hex digits.
function fnv64_hex(data: span[ubyte]) -> string.String:
    var h: ulong = 14695981039346656037
    let prime: ulong = 1099511628211
    var i: ptr_uint = 0
    while i < data.len:
        unsafe:
            h = (h ^ ulong<-read(data.data + i)) * prime
        i += 1

    var rendered = string.String.create()
    var shift: int = 60
    while shift >= 0:
        let nibble = ubyte<-((h >> ulong<-shift) & 15)
        if nibble < 10:
            rendered.push_byte('0' + nibble)
        else:
            rendered.push_byte('a' + (nibble - 10))
        shift -= 4
    return rendered


## Append a non-negative integer as decimal digits.
function append_decimal(target: ref[string.String], value: ptr_uint) -> void:
    if value == 0:
        target.push_byte('0')
        return
    var digits: array[ubyte, 20]
    var count: ptr_uint = 0
    var remaining = value
    while remaining > 0 and count < 20:
        digits[count] = ubyte<-(remaining % 10) + '0'
        remaining /= 10
        count += 1
    while count > 0:
        count -= 1
        target.push_byte(digits[count])


## The cache root: `$XDG_CACHE_HOME/milk_tea/mtc-cache`, falling back to
## `~/.cache/milk_tea/mtc-cache`.
function cache_root() -> string.String:
    let xdg = libc.get_environment_variable("XDG_CACHE_HOME")
    if xdg != null:
        let xdg_path = text.cstr_as_str(xdg)
        if xdg_path.len > 0:
            return path_ops.join(xdg_path, "milk_tea/mtc-cache")

    let home = libc.get_environment_variable("HOME")
    if home != null:
        let home_path = text.cstr_as_str(home)
        if home_path.len > 0:
            return path_ops.join(home_path, ".cache/milk_tea/mtc-cache")

    return string.String.from_str("/tmp/milk_tea-mtc-cache")


## Content hash of the running mtc executable, so a rebuilt compiler never
## reuses output cached by an older one (the foot-gun Ruby's cache documents as
## requiring --no-cache).  Falls back to a constant when /proc/self/exe is
## unreadable, which degrades to Ruby-equivalent behavior.
function compiler_identity() -> string.String:
    match fs.read_bytes("/proc/self/exe"):
        Result.success as payload:
            var exe_bytes = payload.value
            let digest = fnv64_hex(exe_bytes.as_span())
            exe_bytes.release()
            return digest
        Result.failure as failure:
            var read_error = failure.error
            read_error.release()
            return string.String.from_str("unknown-exe")


## Identity of the C compiler (`<cc> --version` output), so switching or
## upgrading compilers invalidates cached binaries.
function cc_identity(c_compiler: str) -> string.String:
    var argv = vec.Vec[str].create()
    defer argv.release()
    argv.push(c_compiler)
    argv.push("--version")
    match process.capture(argv.as_span()):
        Result.success as captured:
            var result = captured.value
            let version_opt = result.stdout_text()
            var rendered = string.String.create()
            match version_opt:
                Option.some as version:
                    rendered.append(version.value)
                Option.none:
                    rendered.append(c_compiler)
            result.release()
            return rendered
        Result.failure as failure:
            var launch_error = failure.error
            launch_error.release()
            return string.String.from_str(c_compiler)


## The full key material for a program build.  Any changed byte — in the
## compiler, the C compiler, the configuration, or any module source — produces
## a different key.  Module entries embed the source length so concatenation
## boundaries are unambiguous.
public function compute_key(program: ref[loader.Program], c_compiler: str, platform_name: str) -> string.String:
    var key = string.String.create()
    key.append("mtc-exe:")
    var exe_digest = compiler_identity()
    key.append(exe_digest.as_str())
    exe_digest.release()
    key.append("\ncc:")
    key.append(c_compiler)
    key.append("\ncc-version:")
    var compiler_version = cc_identity(c_compiler)
    key.append(compiler_version.as_str())
    compiler_version.release()
    key.append("\nplatform:")
    key.append(platform_name)
    key.append("\n")

    var i: ptr_uint = 0
    while i < program.modules.len():
        let module_ptr = program.modules.get(i) else:
            break
        unsafe:
            key.append("module:")
            key.append(read(module_ptr).path.as_str())
            key.append(":")
            append_decimal(ref_of(key), read(module_ptr).source.len())
            key.append("\n")
            key.append(read(module_ptr).source.as_str())
            key.append("\n")
        i += 1
    return key


## The absolute path of a cached binary whose stored key material matches
## `key` exactly, or none.
public function lookup(key: str) -> Option[string.String]:
    var root = cache_root()
    defer root.release()
    var entry_name = fnv64_hex(text.as_byte_span(key))
    defer entry_name.release()
    var entry_dir = path_ops.join(root.as_str(), entry_name.as_str())
    defer entry_dir.release()
    var key_path = path_ops.join(entry_dir.as_str(), "key")
    defer key_path.release()
    var binary_path = path_ops.join(entry_dir.as_str(), "binary")

    if not fs.is_file(key_path.as_str()) or not fs.is_file(binary_path.as_str()):
        binary_path.release()
        return Option[string.String].none

    match fs.read_text(key_path.as_str()):
        Result.failure as failure:
            var read_error = failure.error
            read_error.release()
            binary_path.release()
            return Option[string.String].none
        Result.success as payload:
            var stored = payload.value
            let matches = stored.as_str().equal(key)
            stored.release()
            if matches:
                return Option[string.String].some(value = binary_path)
            binary_path.release()
            return Option[string.String].none


## Store a built binary under `key`.  Failures are silently ignored: the cache
## is an optimization, never a correctness dependency.
public function store(key: str, binary_path: str) -> void:
    var root = cache_root()
    defer root.release()
    var entry_name = fnv64_hex(text.as_byte_span(key))
    defer entry_name.release()
    var entry_dir = path_ops.join(root.as_str(), entry_name.as_str())
    defer entry_dir.release()

    match fs.create_directories(entry_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            return
        Result.success:
            pass

    var key_path = path_ops.join(entry_dir.as_str(), "key")
    defer key_path.release()
    match fs.write_text(key_path.as_str(), key):
        Result.failure as key_failure:
            var key_error = key_failure.error
            key_error.release()
            return
        Result.success:
            pass

    var cached_binary = path_ops.join(entry_dir.as_str(), "binary")
    defer cached_binary.release()
    let _copied = copy_binary(binary_path, cached_binary.as_str())


## Copy a cached binary to the requested output path with mode 0755.  Returns
## false when the copy failed (callers then fall back to a full build).
public function materialize(cached_path: str, output_path: str) -> bool:
    return copy_binary(cached_path, output_path)


function copy_binary(source_path: str, destination_path: str) -> bool:
    match fs.read_bytes(source_path):
        Result.failure as read_failure:
            var read_error = read_failure.error
            read_error.release()
            return false
        Result.success as payload:
            var content = payload.value
            defer content.release()
            match fs.write_bytes(destination_path, content.as_span()):
                Result.failure as write_failure:
                    var write_error = write_failure.error
                    write_error.release()
                    return false
                Result.success:
                    pass
            match fs.set_permissions(destination_path, 493):
                Result.failure as perm_failure:
                    var perm_error = perm_failure.error
                    perm_error.release()
                    return false
                Result.success:
                    return true


## The cache root directory path.
public function cache_root_path() -> string.String:
    return cache_root()


## Delete every cached entry, returning the path of the (now-empty) cache root.
public function purge() -> Result[string.String, string.String]:
    var root = cache_root()
    if not fs.exists(root.as_str()):
        return Result[string.String, string.String].success(value = root)
    match fs.remove_tree(root.as_str()):
        Result.failure as failure:
            var msg = failure.error.message
            defer msg.release()
            return Result[string.String, string.String].failure(error = string.String.from_str(msg.as_str()))
        Result.success:
            pass
    return Result[string.String, string.String].success(value = root)


struct CacheStatus:
    count: ptr_uint
    total_bytes: ptr_uint


## Count cached entries and total bytes used.
public function status() -> CacheStatus:
    var root = cache_root()
    var count: ptr_uint = 0
    var total_bytes: ptr_uint = 0
    if not fs.is_directory(root.as_str()):
        return CacheStatus(count = 0, total_bytes = 0)
    match fs.list_entries(root.as_str()):
        Result.failure as failure:
            var err = failure.error
            err.release()
            return CacheStatus(count = 0, total_bytes = 0)
        Result.success as entries_payload:
            var entries = entries_payload.value
            defer entries.release()
            var ei: ptr_uint = 0
            while ei < entries.len():
                match entries.get(ei):
                    Option.none:
                        break
                    Option.some as entry:
                        var entry_path = path_ops.join(root.as_str(), entry.value)
                        let is_dir = fs.is_directory(entry_path.as_str())
                        if is_dir:
                            match fs.list_entries(entry_path.as_str()):
                                Result.failure:
                                    pass
                                Result.success as sub_payload:
                                    var subs = sub_payload.value
                                    defer subs.release()
                                    var si: ptr_uint = 0
                                    while si < subs.len():
                                        match subs.get(si):
                                            Option.none:
                                                break
                                            Option.some as sub:
                                                var sub_path = path_ops.join(entry_path.as_str(), sub.value)
                                                defer sub_path.release()
                                                let is_file = fs.is_file(sub_path.as_str())
                                                if is_file:
                                                    match fs.metadata(sub_path.as_str()):
                                                        Result.failure:
                                                            pass
                                                        Result.success as meta_payload:
                                                            var meta = meta_payload.value
                                                            total_bytes += meta.size
                                                si += 1
                            count += 1
                        entry_path.release()
                ei += 1
            return CacheStatus(count = count, total_bytes = total_bytes)
