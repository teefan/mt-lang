## Module path resolution — maps logical module names (`a.b.c`) to source-file
## paths over a set of module roots, honoring platform-specific file variants
## (`name.linux.mt`), and infers a module's logical name from its file path.
##
## Mirrors the path-resolution subset of Ruby's ModulePathResolver and
## ModuleLoader (module_path_resolver.rb / module_loader.rb).  Package-graph
## dependency rules and shared analysis caches are intentionally out of scope
## here; single-root resolution comes first.

import std.env as env
import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.loader.errors as errors

public enum Platform: ubyte
    linux = 0
    windows = 1
    wasm = 2


## The platform a configuration label names (`linux`/`windows`/`wasm`).
public function platform_from_label(label: str) -> Option[Platform]:
    if label.equal("linux"):
        return Option[Platform].some(value = Platform.linux)
    if label.equal("windows"):
        return Option[Platform].some(value = Platform.windows)
    if label.equal("wasm"):
        return Option[Platform].some(value = Platform.wasm)
    return Option[Platform].none


public function platform_suffix(platform: Platform) -> str:
    match platform:
        Platform.linux:
            return "linux"
        Platform.windows:
            return "windows"
        Platform.wasm:
            return "wasm"


## The pinned platform of a source file whose name ends in `.linux.mt`,
## `.windows.mt`, or `.wasm.mt`; none for a plain `.mt` file.
public function platform_suffix_for_path(path: str) -> Option[Platform]:
    if path.ends_with(".linux.mt"):
        return Option[Platform].some(value= Platform.linux)
    if path.ends_with(".windows.mt"):
        return Option[Platform].some(value= Platform.windows)
    if path.ends_with(".wasm.mt"):
        return Option[Platform].some(value= Platform.wasm)
    return Option[Platform].none


## Resolve a source-file path to its active-platform variant.  A file already
## pinned to a platform (`name.linux.mt`) is returned unchanged.  Otherwise, for
## a plain `name.mt`, prefer a sibling `name.<platform>.mt` when it exists,
## falling back to `name.mt`.  Always returns an owned copy.
public function resolve_source_path(path: str, platform: Platform) -> string.String:
    if platform_suffix_for_path(path).is_some():
        return string.String.from_str(path)
    if not path.ends_with(".mt"):
        return string.String.from_str(path)

    var candidate = variant_path(path, platform)
    if fs.is_file(candidate.as_str()):
        return candidate
    candidate.release()
    return string.String.from_str(path)


## Resolve a logical module name (`a.b.c`) to an existing source file under one
## of `roots`, honoring platform variants.  Roots are searched in order; the
## first existing file wins.
public function resolve_module_path(
    module_name: str,
    roots: span[str],
    platform: Platform,
) -> Result[string.String, errors.ModuleLoadError]:
    var relative = module_relative_path(module_name)
    defer: relative.release()

    var i: ptr_uint = 0
    while i < roots.len:
        let root = unsafe: read(roots.data + i)
        var joined = path_ops.join(root, relative.as_str())
        var resolved = resolve_source_path(joined.as_str(), platform)
        joined.release()
        if fs.is_file(resolved.as_str()):
            return Result[string.String, errors.ModuleLoadError].success(value= resolved)
        resolved.release()
        i += 1

    return Result[string.String, errors.ModuleLoadError].failure(
        error= errors.module_load_error("module not found", module_name)
    )


## Infer a file's logical module name from its path relative to the longest
## matching root: strip the root prefix and the `.mt` (or `.<platform>.mt`)
## suffix, then join the path segments with `.`.  With no matching root, the
## bare file stem is used.
public function infer_module_name(path: str, roots: span[str]) -> string.String:
    var best_root: Option[str] = Option[str].none
    var best_len: ptr_uint = 0
    var i: ptr_uint = 0
    while i < roots.len:
        let root = unsafe: read(roots.data + i)
        if path_ops.is_within_root(path, root):
            if best_root.is_none() or root.len > best_len:
                best_root = Option[str].some(value= root)
                best_len = root.len
        i += 1

    match best_root:
        Option.some as chosen:
            match path_ops.relative_path(path, chosen.value):
                Option.some as rel:
                    var relative = rel.value
                    defer: relative.release()
                    return module_name_from_relative(relative.as_str())
                Option.none:
                    return module_name_from_relative(path_ops.basename(path))
        Option.none:
            return module_name_from_relative(path_ops.basename(path))

# =============================================================================
#  Compiler-provided module roots
# =============================================================================

## Module roots the compiler itself provides, so a project outside the
## compiler's own tree still resolves `std.*`:
##
##   1. `$MILK_TEA_MODULE_ROOT` and `$MILK_TEA_STD_ROOT` (PATH-separated), and
##   2. the directory containing `std/` next to the running binary.
##
## The Ruby host appends the same two sources in `ModuleRoots.add_env_roots!`
## and its unconditional `MilkTea.root` append; a root that names `std` itself
## is normalized to its parent (`ModuleRoots.normalize_root`).  Every entry is
## owned — the caller releases the vector.
public function compiler_root_candidates() -> vec.Vec[string.String]:
    var roots = vec.Vec[string.String].create()
    append_env_root_candidates(ref_of(roots), "MILK_TEA_MODULE_ROOT")
    append_env_root_candidates(ref_of(roots), "MILK_TEA_STD_ROOT")

    match fs.canonicalize("/proc/self/exe"):
        Result.success as exe_payload:
            var exe = exe_payload.value
            defer: exe.release()
            match fs.find_ancestor_containing(exe.as_str(), "std"):
                Option.some as root_payload:
                    var root = root_payload.value
                    push_root_candidate(ref_of(roots), root.as_str())
                    root.release()
                Option.none:
                    pass
        Result.failure as failure:
            var read_error = failure.error
            read_error.release()

    return roots


## Append the PATH-separated roots of the environment variable `name`.
function append_env_root_candidates(roots: ref[vec.Vec[string.String]], name: str) -> void:
    match env.get(name):
        Option.some as value:
            let text = value.value
            var start: ptr_uint = 0
            var i: ptr_uint = 0
            while i <= text.len:
                if i == text.len or text.byte_at(i) == ':':
                    if i > start:
                        push_root_candidate(roots, text.slice(start, i - start))
                    start = i + 1
                i += 1
        Option.none:
            pass


## Append `candidate` (normalized, no duplicates) to `roots` as an owned copy.
function push_root_candidate(roots: ref[vec.Vec[string.String]], candidate: str) -> void:
    if candidate.len == 0:
        return

    var normalized = normalize_root_path(candidate)
    defer: normalized.release()
    let text = normalized.as_str()

    var i: ptr_uint = 0
    while i < roots.len():
        let entry = roots.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(text):
            return
        i += 1

    roots.push(string.String.from_str(text))


## A root that points at a `std` directory names its parent.
function normalize_root_path(root: str) -> string.String:
    if path_ops.basename(root).equal("std"):
        return string.String.from_str(path_ops.dirname(root))
    return string.String.from_str(root)

# =============================================================================
#  Internal helpers
# =============================================================================

function variant_path(path: str, platform: Platform) -> string.String:
    var result = string.String.with_capacity(path.len + 8)
    result.append(path.slice(0, path.len - 3))
    result.push_byte('.')
    result.append(platform_suffix(platform))
    result.append(".mt")
    return result


function module_relative_path(module_name: str) -> string.String:
    var result = string.String.with_capacity(module_name.len + 3)
    var i: ptr_uint = 0
    while i < module_name.len:
        let b = module_name.byte_at(i)
        if b == '.':
            result.push_byte('/')
        else:
            result.push_byte(b)
        i += 1
    result.append(".mt")
    return result


function module_name_from_relative(relative: str) -> string.String:
    let stem = strip_module_suffix(relative)
    var result = string.String.with_capacity(stem.len)
    var i: ptr_uint = 0
    while i < stem.len:
        let b = stem.byte_at(i)
        if b == '/':
            result.push_byte('.')
        else:
            result.push_byte(b)
        i += 1
    return result


function strip_module_suffix(path: str) -> str:
    if path.ends_with(".linux.mt"):
        return path.slice(0, path.len - 9)
    if path.ends_with(".windows.mt"):
        return path.slice(0, path.len - 11)
    if path.ends_with(".wasm.mt"):
        return path.slice(0, path.len - 8)
    if path.ends_with(".mt"):
        return path.slice(0, path.len - 3)
    return path
