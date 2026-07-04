## Module path resolution — maps logical module names (`a.b.c`) to source-file
## paths over a set of module roots, honoring platform-specific file variants
## (`name.linux.mt`), and infers a module's logical name from its file path.
##
## Mirrors the path-resolution subset of Ruby's ModulePathResolver and
## ModuleLoader (module_path_resolver.rb / module_loader.rb).  Package-graph
## dependency rules and shared analysis caches are intentionally out of scope
## here; single-root resolution comes first.

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string

import mtc.loader.errors as errors


public enum Platform: ubyte
    linux   = 0
    windows = 1
    wasm    = 2


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
    defer relative.release()

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
                    defer relative.release()
                    return module_name_from_relative(relative.as_str())
                Option.none:
                    return module_name_from_relative(path_ops.basename(path))
        Option.none:
            return module_name_from_relative(path_ops.basename(path))


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
