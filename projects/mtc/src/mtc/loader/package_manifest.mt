## Package manifest lookup for module roots: the nearest ancestor
## `package.toml` and its `[package] source_root` (default `src`).
##
## Mirrors Ruby's `ModuleRoots.package_root_for_path` + `PackageGraph#source_roots`,
## which make a package's own modules resolvable by their bare names — with
## `SimpleGame/package.toml` (`source_root = "src"`), `import game` resolves
## `SimpleGame/src/game.mt` for a file anywhere inside the package.

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.toml as toml


const DEFAULT_SOURCE_ROOT: str = "src"


## The `<package_dir>/<source_root>` directory of the nearest ancestor
## `package.toml` containing `path`, when that directory exists.
## Owned; the caller releases.
public function package_source_root_for_path(path: str) -> Option[string.String]:
    if path.len == 0:
        return Option[string.String].none

    var current = if fs.is_directory(path): path else: path_ops.dirname(path)
    while true:
        var manifest = path_ops.join(current, "package.toml")
        defer: manifest.release()
        if fs.is_file(manifest.as_str()):
            return source_root_in_manifest(current, manifest.as_str())

        let parent = path_ops.dirname(current)
        if parent.equal(current):
            return Option[string.String].none
        current = parent


## Read `[package] source_root` (default `src`) from a manifest and join it
## onto the package directory.
function source_root_in_manifest(package_dir: str, manifest_path: str) -> Option[string.String]:
    match fs.read_text(manifest_path):
        Result.success as payload:
            var text = payload.value
            defer: text.release()

            var source_root = string.String.from_str(DEFAULT_SOURCE_ROOT)
            defer: source_root.release()

            match toml.parse(text.as_str()):
                Result.success as document:
                    var di: ptr_uint = 0
                    while di < document.value.tables.len():
                        let entry = document.value.tables.get(di) else:
                            break
                        let table = unsafe: read(entry)
                        if table.name.as_str().equal("package"):
                            match table.entries.get_string("source_root"):
                                Option.some as value:
                                    if value.value.len > 0:
                                        source_root.release()
                                        source_root = string.String.from_str(value.value)
                                Option.none:
                                    pass
                            break
                        di += 1
                Result.failure as failure:
                    var parse_error = failure.error
                    parse_error.message.release()

            var joined = path_ops.join(package_dir, source_root.as_str())
            if fs.is_directory(joined.as_str()):
                return Option[string.String].some(value = joined)
            joined.release()
            return Option[string.String].none
        Result.failure as failure:
            var read_error = failure.error
            read_error.release()
            return Option[string.String].none
