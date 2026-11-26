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

import mtc.debug_map as debug_map
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
    # The host's `MilkTea.data_root`: the source tree when the compiler runs
    # from its checkout (the usual case), otherwise the XDG cache directory
    # (an installed gem).  Locate the checkout the same way module roots do:
    # the nearest ancestor of the running binary containing `std/`.
    match fs.canonicalize("/proc/self/exe"):
        Result.success as exe_payload:
            var exe = exe_payload.value
            defer: exe.release()
            match fs.find_ancestor_containing(exe.as_str(), "std"):
                Option.some as root_payload:
                    var data_root = root_payload.value
                    defer: data_root.release()
                    return path_ops.join(data_root.as_str(), "tmp/mtc-cache")
                Option.none:
                    pass
        Result.failure as exe_failure:
            var exe_error = exe_failure.error
            exe_error.release()

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
public function cc_identity(c_compiler: str) -> string.String:
    var argv = vec.Vec[str].create()
    defer: argv.release()
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
public function compute_key(
    program: ref[loader.Program],
    c_compiler: str,
    platform_name: str,
    profile: str,
    sanitize: bool,
    debug_guards: bool
) -> string.String:
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
    # The cached artifact is the compiled binary, so the profile, sanitizer,
    # and guard settings are part of the key (otherwise a release build could
    # reuse a debug binary and vice versa).
    key.append("\nprofile:")
    key.append(profile)
    key.append("\nsanitize:")
    if sanitize:
        key.append("1")
    else:
        key.append("0")
    key.append("\ndebug-guards:")
    if debug_guards:
        key.append("1")
    else:
        key.append("0")
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
    defer: root.release()
    var entry_name = fnv64_hex(text.as_byte_span(key))
    defer: entry_name.release()
    var entry_dir = path_ops.join(root.as_str(), entry_name.as_str())
    defer: entry_dir.release()
    var key_path = path_ops.join(entry_dir.as_str(), "key")
    defer: key_path.release()
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
    defer: root.release()
    var entry_name = fnv64_hex(text.as_byte_span(key))
    defer: entry_name.release()
    var entry_dir = path_ops.join(root.as_str(), entry_name.as_str())
    defer: entry_dir.release()

    match fs.create_directories(entry_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            return
        Result.success:
            pass

    var key_path = path_ops.join(entry_dir.as_str(), "key")
    defer: key_path.release()
    match fs.write_text(key_path.as_str(), key):
        Result.failure as key_failure:
            var key_error = key_failure.error
            key_error.release()
            return
        Result.success:
            pass

    var cached_binary = path_ops.join(entry_dir.as_str(), "binary")
    defer: cached_binary.release()
    let _copied = copy_binary(binary_path, cached_binary.as_str())

    # Carry the debug-map sidecar with the binary so a cache hit still maps
    # frames (the host skips the map on program-cache hits).
    var sidecar = debug_map.sidecar_path_for(binary_path)
    defer: sidecar.release()
    if fs.is_file(sidecar.as_str()):
        var cached_map = path_ops.join(entry_dir.as_str(), "debug-map.json")
        defer: cached_map.release()
        let _copied_map = copy_file_with_mode(sidecar.as_str(), cached_map.as_str(), 420)


## Copy a cached binary to the requested output path with mode 0755.  Returns
## false when the copy failed (callers then fall back to a full build).  A
## cached debug-map sidecar is restored next to the output when present.
public function materialize(cached_path: str, output_path: str) -> bool:
    if not copy_binary(cached_path, output_path):
        return false

    var cached_dir = path_ops.dirname(cached_path)
    var cached_map = path_ops.join(cached_dir, "debug-map.json")
    defer: cached_map.release()
    if fs.is_file(cached_map.as_str()):
        var sidecar = debug_map.sidecar_path_for(output_path)
        defer: sidecar.release()
        let _copied_map = copy_file_with_mode(cached_map.as_str(), sidecar.as_str(), 420)
    return true


function copy_binary(source_path: str, destination_path: str) -> bool:
    return copy_file_with_mode(source_path, destination_path, 493)


function copy_file_with_mode(source_path: str, destination_path: str, mode: int) -> bool:
    match fs.read_bytes(source_path):
        Result.failure as read_failure:
            var read_error = read_failure.error
            read_error.release()
            return false
        Result.success as payload:
            var content = payload.value
            defer: content.release()
            match fs.write_bytes(destination_path, content.as_span()):
                Result.failure as write_failure:
                    var write_error = write_failure.error
                    write_error.release()
                    return false
                Result.success:
                    pass
            match fs.set_permissions(destination_path, mode):
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
            defer: msg.release()
            return Result[string.String, string.String].failure(error = string.String.from_str(msg.as_str()))
        Result.success:
            pass
    return Result[string.String, string.String].success(value = root)

struct CacheStatus:
    programs: ptr_uint
    binaries: ptr_uint
    objects: ptr_uint
    total_bytes: ptr_uint


## Count the flat cache entries (`<root>/<hash>/{key,binary,debug-map.json}`).
## `programs` counts entries with a `key` file; `binaries` counts entries with a
## `binary` file.  The directory is a single level, not the older
## `programs/<2>/<key>` / `binaries/<2>/<key>` layout.
public function status() -> CacheStatus:
    var root = cache_root()
    defer: root.release()
    if not fs.is_directory(root.as_str()):
        return CacheStatus(programs = 0, binaries = 0, objects = 0, total_bytes = 0)

    var total_bytes: ptr_uint = 0
    var programs: ptr_uint = 0
    var binaries: ptr_uint = 0
    match fs.list_entries(root.as_str()):
        Result.failure as failure:
            var err = failure.error
            err.release()
            return CacheStatus(programs = 0, binaries = 0, objects = 0, total_bytes = 0)
        Result.success as entries_payload:
            var entries = entries_payload.value
            defer: entries.release()
            var i: ptr_uint = 0
            while i < entries.len():
                let name = entries.get(i) else:
                    break
                var entry_path = path_ops.join(root.as_str(), name)
                if fs.is_directory(entry_path.as_str()):
                    var key_path = path_ops.join(entry_path.as_str(), "key")
                    if fs.is_file(key_path.as_str()):
                        programs += 1
                    key_path.release()
                    var binary_path = path_ops.join(entry_path.as_str(), "binary")
                    if fs.is_file(binary_path.as_str()):
                        binaries += 1
                    binary_path.release()
                    add_tree_size(entry_path.as_str(), ref_of(total_bytes))
                entry_path.release()
                i += 1

    let object_stats = object_status()
    return CacheStatus(
        programs = programs,
        binaries = binaries,
        objects = object_stats.objects,
        total_bytes = total_bytes
    )


## Add every regular file's size under `dir` (recursively) to `total`.
function add_tree_size(dir: str, total: ref[ptr_uint]) -> void:
    match fs.list_files_recursive(dir):
        Result.failure as failure:
            var err = failure.error
            err.release()
        Result.success as files_payload:
            var files = files_payload.value
            defer: files.release()
            var i: ptr_uint = 0
            while i < files.len():
                let fp = files.get(i) else:
                    break
                match fs.metadata(fp):
                    Result.success as meta_payload:
                        var meta = meta_payload.value
                        unsafe: read(total) += meta.size
                    Result.failure:
                        pass
                i += 1



## Object-cache entries: one `.o` plus a `.key` beside it.  The `.key` stores
## the exact material so an FNV collision degrades to a miss, never a wrong
## object.
const OBJECT_CACHE_MAX_OBJECTS: ptr_uint = 512
const OBJECT_CACHE_MAX_BYTES: ptr_uint = 536870912


public struct ObjectCacheStatus:
    objects: ptr_uint
    total_bytes: ptr_uint


struct ObjectEntry:
    path: string.String
    size: ptr_uint
    mtime: ptr_int


function objects_dir() -> string.String:
    var root = cache_root()
    defer: root.release()
    return path_ops.join(root.as_str(), "objects")


public function object_status() -> ObjectCacheStatus:
    var dir = objects_dir()
    defer: dir.release()
    if not fs.is_directory(dir.as_str()):
        return ObjectCacheStatus(objects = 0, total_bytes = 0)
    var count: ptr_uint = 0
    var total: ptr_uint = 0
    match fs.list_entries(dir.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
        Result.success as payload:
            var entries = payload.value
            defer: entries.release()
            var i: ptr_uint = 0
            while i < entries.len():
                let name = entries.get(i) else:
                    break
                if name.ends_with(".o"):
                    var path = path_ops.join(dir.as_str(), name)
                    match fs.metadata(path.as_str()):
                        Result.success as meta_payload:
                            var meta = meta_payload.value
                            count += 1
                            total += meta.size
                        Result.failure:
                            pass
                    path.release()
                i += 1
    return ObjectCacheStatus(objects = count, total_bytes = total)


public function object_lookup(key: str) -> Option[string.String]:
    var dir = objects_dir()
    defer: dir.release()
    var name = fnv64_hex(text.as_byte_span(key))
    defer: name.release()
    var object_name = string.String.create()
    defer: object_name.release()
    object_name.append(name.as_str())
    object_name.append(".o")
    var key_name = string.String.create()
    defer: key_name.release()
    key_name.append(name.as_str())
    key_name.append(".key")
    var object_path = path_ops.join(dir.as_str(), object_name.as_str())
    var key_path = path_ops.join(dir.as_str(), key_name.as_str())
    if not fs.is_file(object_path.as_str()) or not fs.is_file(key_path.as_str()):
        object_path.release()
        key_path.release()
        return Option[string.String].none
    match fs.read_text(key_path.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
            object_path.release()
        Result.success as payload:
            var stored = payload.value
            var matches = false
            if stored.as_str().starts_with("object:"):
                match stored.as_str().find_byte(10):
                    Option.some as line_end:
                        let stored_hash = stored.as_str().slice(7, line_end.value - 7)
                        let stored_key = stored.as_str().slice(line_end.value + 1, stored.len - line_end.value - 1)
                        matches = stored_key.equal(key)
                        if matches:
                            match object_content_hash(object_path.as_str()):
                                Option.some as object_hash:
                                    matches = object_hash.value.as_str().equal(stored_hash)
                                    object_hash.value.release()
                                Option.none:
                                    matches = false
                    Option.none:
                        pass
            stored.release()
            if matches:
                key_path.release()
                return Option[string.String].some(value = object_path)
            # A corrupt/truncated entry is a miss, and is removed so the next
            # build does not trip over it again.
            match fs.remove(object_path.as_str()):
                Result.success:
                    pass
                Result.failure:
                    pass
            match fs.remove(key_path.as_str()):
                Result.success:
                    pass
                Result.failure:
                    pass
            object_path.release()
    key_path.release()
    return Option[string.String].none


function object_content_hash(path: str) -> Option[string.String]:
    match fs.read_bytes(path):
        Result.failure as failure:
            var error = failure.error
            error.release()
            return Option[string.String].none
        Result.success as payload:
            var bytes = payload.value
            let hash = fnv64_hex(bytes.as_span())
            bytes.release()
            return Option[string.String].some(value = hash)


public function object_materialize(cached_path: str, destination_path: str) -> bool:
    return copy_file_with_mode(cached_path, destination_path, 420)


public function object_store(key: str, object_path: str) -> void:
    var dir = objects_dir()
    defer: dir.release()
    match fs.create_directories(dir.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
            return
        Result.success:
            pass
    var name = fnv64_hex(text.as_byte_span(key))
    defer: name.release()
    var object_name = string.String.create()
    defer: object_name.release()
    object_name.append(name.as_str())
    object_name.append(".o")
    var key_name = string.String.create()
    defer: key_name.release()
    key_name.append(name.as_str())
    key_name.append(".key")
    var cached_object = path_ops.join(dir.as_str(), object_name.as_str())
    defer: cached_object.release()
    let copied = copy_file_with_mode(object_path, cached_object.as_str(), 420)
    if not copied:
        return
    var key_path = path_ops.join(dir.as_str(), key_name.as_str())
    defer: key_path.release()
    match object_content_hash(object_path):
        Option.none:
            return
        Option.some as object_digest:
            var metadata = string.String.create()
            metadata.append("object:")
            metadata.append(object_digest.value.as_str())
            metadata.append("\n")
            metadata.append(key)
            object_digest.value.release()
            match fs.write_text(key_path.as_str(), metadata.as_str()):
                Result.failure as failure:
                    var error = failure.error
                    error.release()
                    metadata.release()
                    return
                Result.success:
                    pass
            metadata.release()
    evict_objects()


function compare_object_entries(left: ptr[ObjectEntry], right: ptr[ObjectEntry]) -> int:
    let l = unsafe: read(left).mtime
    let r = unsafe: read(right).mtime
    if l < r:
        return -1
    if l > r:
        return 1
    return 0


## Bound the object cache by count and total bytes, dropping the oldest entries
## first.  Eviction failures are ignored: the cache is only an optimization.
public function object_prune() -> void:
    evict_objects()


function evict_objects() -> void:
    var dir = objects_dir()
    defer: dir.release()
    var entries = vec.Vec[ObjectEntry].create()
    match fs.list_entries(dir.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
            return
        Result.success as payload:
            var names = payload.value
            defer: names.release()
            var i: ptr_uint = 0
            while i < names.len():
                let name = names.get(i) else:
                    break
                if name.ends_with(".o"):
                    var path = path_ops.join(dir.as_str(), name)
                    match fs.metadata(path.as_str()):
                        Result.success as meta_payload:
                            var meta = meta_payload.value
                            var key_size: ptr_uint = 0
                            var side_key = string.String.create()
                            side_key.append(path.as_str().slice(0, path.len - 2))
                            side_key.append(".key")
                            match fs.metadata(side_key.as_str()):
                                Result.success as key_meta_payload:
                                    var key_meta = key_meta_payload.value
                                    key_size = key_meta.size
                                Result.failure:
                                    pass
                            side_key.release()
                            entries.push(ObjectEntry(
                                path = path,
                                size = meta.size + key_size,
                                mtime = meta.modified_seconds
                            ))
                        Result.failure:
                            path.release()
                i += 1
    # Newest first: keep entries until either bound is reached, then delete the
    # rest (and their key sidecars).
    entries.sort_by(compare_object_entries)
    var kept: ptr_uint = 0
    var kept_bytes: ptr_uint = 0
    var idx = entries.len()
    while idx > 0:
        idx -= 1
        let entry_ptr = entries.get(idx) else:
            break
        var entry = unsafe: read(entry_ptr)
        let fits = kept < OBJECT_CACHE_MAX_OBJECTS and kept_bytes + entry.size <= OBJECT_CACHE_MAX_BYTES
        if fits:
            kept += 1
            kept_bytes += entry.size
        else:
            match fs.remove(entry.path.as_str()):
                Result.success:
                    pass
                Result.failure:
                    pass
            var key_path = string.String.create()
            if entry.path.len >= 2:
                key_path.append(entry.path.as_str().slice(0, entry.path.len - 2))
            key_path.append(".key")
            match fs.remove(key_path.as_str()):
                Result.success:
                    pass
                Result.failure:
                    pass
            key_path.release()
    var rel: ptr_uint = 0
    while rel < entries.len():
        let entry_ptr = entries.get(rel) else:
            break
        unsafe: read(entry_ptr).path.release()
        rel += 1
    entries.release()
