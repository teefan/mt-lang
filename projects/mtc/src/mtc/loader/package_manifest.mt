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
import std.vec as vec


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


## The package identity and build settings the build CLI consumes — the subset
## of the host's `PackageManifest::DataView`
## (`lib/milk_tea/packages/manifest.rb`) that `build`/`run`/`test` read.
public enum PackageKind: ubyte
    application = 0
    library = 1


public struct PackageBuild:
    root_dir: string.String
    manifest_path: string.String
    name: string.String
    kind: PackageKind
    source_root: string.String
    source_path: Option[string.String]
    ## Canonical names (`debug`/`release`, `linux`/`windows`/`wasm`).
    profile: str
    platform: str
    output_path: Option[string.String]
    ## Absolute `build.assets` paths, in manifest order.
    assets: vec.Vec[string.String]
    html_template: Option[string.String]


extending PackageBuild:
    public editable function release() -> void:
        this.root_dir.release()
        this.manifest_path.release()
        this.name.release()
        this.source_root.release()
        match this.source_path:
            Option.some as source:
                source.value.release()
            Option.none:
                pass
        match this.output_path:
            Option.some as output:
                output.value.release()
            Option.none:
                pass
        match this.html_template:
            Option.some as template:
                template.value.release()
            Option.none:
                pass
        var i: ptr_uint = 0
        while i < this.assets.len():
            let asset = this.assets.get(i) else:
                break
            unsafe:
                read(asset).release()
            i += 1
        this.assets.release()


## Load the manifest governing `path` (absolute): a directory operand uses its
## own `package.toml`; a file operand uses the nearest ancestor manifest only
## when that manifest's entry resolves to the file — the host's
## `use_package_build_for?` rule.  `Ok(none)` means "not a package build".
public function load_package_for(path: str) -> Result[Option[PackageBuild], string.String]:
    var root_owner = string.String.create()
    defer: root_owner.release()
    var manifest_owner = string.String.create()
    defer: manifest_owner.release()
    var found = false

    if fs.is_directory(path):
        var candidate = path_ops.join(path, "package.toml")
        defer: candidate.release()
        if fs.is_file(candidate.as_str()):
            root_owner.append(path)
            manifest_owner.append(candidate.as_str())
            found = true
    else:
        var current: str = path_ops.dirname(path)
        while true:
            var candidate = path_ops.join(current, "package.toml")
            if fs.is_file(candidate.as_str()):
                root_owner.append(current)
                manifest_owner.append(candidate.as_str())
                candidate.release()
                found = true
                break
            candidate.release()
            let parent = path_ops.dirname(current)
            if parent.equal(current):
                break
            current = parent

    if not found:
        return Result[Option[PackageBuild], string.String].success(value = Option[PackageBuild].none)

    return parse_package_manifest(path, root_owner.as_str(), manifest_owner.as_str())


function find_toml_table(document: ref[toml.Document], name: str) -> ptr[toml.Table]?:
    var i: ptr_uint = 0
    while i < document.tables.len():
        let table = document.tables.get(i) else:
            break
        unsafe:
            if read(table).name.as_str().equal(name):
                return table
        i += 1
    return null


function table_string(table: ptr[toml.Table]?, key: str) -> Option[str]:
    if table == null:
        return Option[str].none
    unsafe:
        return read(table).entries.get_string(key)


function table_array(table: ptr[toml.Table]?, key: str) -> ptr[toml.Array]?:
    if table == null:
        return null
    unsafe:
        return read(table).entries.get_array(key)


## `File.expand_path(value, root)`: absolute values stand, relative ones join.
function resolve_under(root: str, value: str) -> string.String:
    if path_ops.is_absolute(value):
        return string.String.from_str(value)
    return path_ops.join(root, value)


function parse_package_manifest(operand: str, root: str, manifest: str) -> Result[Option[PackageBuild], string.String]:
    var text_owner: string.String
    match fs.read_text(manifest):
        Result.failure as read_failure:
            var read_error = read_failure.error
            var message = string.String.from_str("invalid package.toml at ")
            message.append(manifest)
            message.append(": ")
            message.append(read_error.message.as_str())
            read_error.release()
            return Result[Option[PackageBuild], string.String].failure(error = message)
        Result.success as payload:
            text_owner = payload.value
    defer: text_owner.release()

    var document: toml.Document
    match toml.parse(text_owner.as_str()):
        Result.failure as parse_failure:
            var parse_error = parse_failure.error
            var message = string.String.from_str("invalid package.toml at ")
            message.append(manifest)
            message.append(": ")
            message.append(parse_error.message.as_str())
            parse_error.release()
            return Result[Option[PackageBuild], string.String].failure(error = message)
        Result.success as parsed:
            document = parsed.value

    let package_table = find_toml_table(ref_of(document), "package")
    let build_table = find_toml_table(ref_of(document), "build")
    let profile_table = find_toml_table(ref_of(document), "profile")
    let platform_table = find_toml_table(ref_of(document), "platform")

    var name = string.String.create()
    match table_string(package_table, "name"):
        Option.some as declared:
            if declared.value.len > 0:
                name.append(declared.value)
        Option.none:
            pass
    if name.len() == 0:
        name.append(path_ops.basename(root))

    var kind_text: str = "application"
    match table_string(package_table, "kind"):
        Option.some as declared_kind:
            kind_text = declared_kind.value
        Option.none:
            match table_string(build_table, "type"):
                Option.some as declared_type:
                    kind_text = declared_type.value
                Option.none:
                    pass
    var kind = PackageKind.application
    if kind_text == "library" or kind_text == "lib":
        kind = PackageKind.library
    else if not (kind_text == "" or kind_text == "application" or kind_text == "app" or kind_text == "executable"):
        var message = string.String.from_str("unknown package kind ")
        message.append(kind_text)
        message.append("; expected application|library")
        name.release()
        return Result[Option[PackageBuild], string.String].failure(error = message)

    var source_root_value = string.String.create()
    match table_string(package_table, "source_root"):
        Option.some as declared_root:
            if declared_root.value.len > 0:
                source_root_value.append(declared_root.value)
        Option.none:
            pass
    if source_root_value.len() == 0:
        var conventional = path_ops.join(root, "src")
        let has_src = fs.is_directory(conventional.as_str())
        conventional.release()
        if has_src:
            source_root_value.append("src")
        else:
            source_root_value.append(".")
    var source_root_abs = resolve_under(root, source_root_value.as_str())
    if not fs.is_directory(source_root_abs.as_str()):
        var message = string.String.from_str("package.source_root not found: ")
        message.append(source_root_value.as_str())
        message.append(" (resolved to ")
        message.append(source_root_abs.as_str())
        message.append(")")
        source_root_value.release()
        source_root_abs.release()
        name.release()
        return Result[Option[PackageBuild], string.String].failure(error = message)

    var profile: str = "debug"
    var profile_value: Option[str] = table_string(build_table, "profile")
    if profile_value.is_none():
        profile_value = table_string(profile_table, "default")
    match profile_value:
        Option.some as declared_profile:
            match normalize_package_profile(declared_profile.value):
                Option.some as canonical:
                    profile = canonical.value
                Option.none:
                    var message = string.String.from_str("unknown profile ")
                    message.append(declared_profile.value)
                    message.append("; expected debug|release")
                    source_root_value.release()
                    source_root_abs.release()
                    name.release()
                    return Result[Option[PackageBuild], string.String].failure(error = message)
        Option.none:
            pass

    var platform: str = "linux"
    var platform_value: Option[str] = table_string(build_table, "platform")
    if platform_value.is_none():
        platform_value = table_string(platform_table, "default")
    match platform_value:
        Option.some as declared_platform:
            match normalize_package_platform(declared_platform.value):
                Option.some as canonical:
                    platform = canonical.value
                Option.none:
                    var message = string.String.from_str("unknown platform ")
                    message.append(declared_platform.value)
                    message.append("; expected linux|windows|wasm")
                    source_root_value.release()
                    source_root_abs.release()
                    name.release()
                    return Result[Option[PackageBuild], string.String].failure(error = message)
        Option.none:
            pass

    var source_path: Option[string.String] = Option[string.String].none
    if kind != PackageKind.library:
        match table_string(build_table, "entry"):
            Option.some as declared_entry:
                var entry_abs = resolve_under(root, declared_entry.value)
                if not fs.is_file(entry_abs.as_str()):
                    var message = string.String.from_str("build.entry not found: ")
                    message.append(declared_entry.value)
                    message.append(" (resolved to ")
                    message.append(entry_abs.as_str())
                    message.append(")")
                    entry_abs.release()
                    source_root_value.release()
                    source_root_abs.release()
                    name.release()
                    return Result[Option[PackageBuild], string.String].failure(error = message)
                source_path = Option[string.String].some(value = entry_abs)
            Option.none:
                var default_main = path_ops.join(root, "src/main.mt")
                if fs.is_file(default_main.as_str()):
                    source_path = Option[string.String].some(value = default_main)
                else:
                    default_main.release()
                    if fs.is_file(operand) and path_within(operand, root):
                        source_path = Option[string.String].some(value = string.String.from_str(operand))

    # The host's `use_package_build_for?` requires a resolved entry (a library
    # package or one with no entry/`src/main.mt` is not a package build), and a
    # file operand must be that entry.
    var applies = true
    match source_path:
        Option.none:
            applies = false
        Option.some as declared_source:
            if not fs.is_directory(operand) and not path_ops.basename(operand).equal("package.toml"):
                if not declared_source.value.as_str().equal(operand):
                    applies = false
    if not applies:
        source_root_value.release()
        source_root_abs.release()
        name.release()
        match source_path:
            Option.some as owned_source:
                owned_source.value.release()
            Option.none:
                pass
        return Result[Option[PackageBuild], string.String].success(value = Option[PackageBuild].none)

    source_root_value.release()
    match finish_package_build(
        root, manifest, build_table, name, kind, source_root_abs, source_path, profile, platform
    ):
        Result.success as built:
            return Result[Option[PackageBuild], string.String].success(value = built.value)
        Result.failure as failure:
            name.release()
            source_root_abs.release()
            match source_path:
                Option.some as owned_source:
                    owned_source.value.release()
                Option.none:
                    pass
            return Result[Option[PackageBuild], string.String].failure(error = failure.error)


## Resolve the optional output/assets/template and build the PackageBuild.  The
## name/source-root/source-path values transfer to the result on success; the
## caller releases them on failure.
function finish_package_build(
    root: str,
    manifest: str,
    build_table: ptr[toml.Table]?,
    name: string.String,
    kind: PackageKind,
    source_root_abs: string.String,
    source_path: Option[string.String],
    profile: str,
    platform: str,
) -> Result[Option[PackageBuild], string.String]:
    var output_path: Option[string.String] = Option[string.String].none
    match table_string(build_table, "output"):
        Option.some as declared_output:
            output_path = Option[string.String].some(value = resolve_under(root, declared_output.value))
        Option.none:
            pass

    var assets = vec.Vec[string.String].create()
    var assets_ok = collect_assets(build_table, root, ref_of(assets))
    match assets_ok:
        Result.failure as asset_failure:
            var asset_error = asset_failure.error
            match output_path:
                Option.some as owned_output:
                    owned_output.value.release()
                Option.none:
                    pass
            release_asset_paths(ref_of(assets))
            return Result[Option[PackageBuild], string.String].failure(error = asset_error)
        Result.success:
            pass

    var html_template: Option[string.String] = Option[string.String].none
    match table_string(build_table, "html_template"):
        Option.some as declared_template:
            var template_abs = resolve_under(root, declared_template.value)
            if not fs.is_file(template_abs.as_str()):
                var message = string.String.from_str("build.html_template not found: ")
                message.append(declared_template.value)
                message.append(" (resolved to ")
                message.append(template_abs.as_str())
                message.append(")")
                template_abs.release()
                match output_path:
                    Option.some as owned_output:
                        owned_output.value.release()
                    Option.none:
                        pass
                release_asset_paths(ref_of(assets))
                return Result[Option[PackageBuild], string.String].failure(error = message)
            html_template = Option[string.String].some(value = template_abs)
        Option.none:
            pass

    return Result[Option[PackageBuild], string.String].success(value = Option[PackageBuild].some(value = PackageBuild(
        root_dir = string.String.from_str(root),
        manifest_path = string.String.from_str(manifest),
        name = name,
        kind = kind,
        source_root = source_root_abs,
        source_path = source_path,
        profile = profile,
        platform = platform,
        output_path = output_path,
        assets = assets,
        html_template = html_template,
    )))


function collect_assets(build_table: ptr[toml.Table]?, root: str, assets: ref[vec.Vec[string.String]]) -> Result[bool, string.String]:
    var raws = vec.Vec[str].create()
    defer: raws.release()

    let asset_array = table_array(build_table, "assets")
    if asset_array != null:
        let values = unsafe: read(asset_array)
        var i: ptr_uint = 0
        while i < values.len():
            match values.get_string(i):
                Option.some as raw:
                    raws.push(raw.value)
                Option.none:
                    pass
            i += 1
    else:
        match table_string(build_table, "assets"):
            Option.some as raw:
                raws.push(raw.value)
            Option.none:
                pass

    var i: ptr_uint = 0
    while i < raws.len():
        let raw_ptr = raws.get(i) else:
            break
        let raw = unsafe: read(raw_ptr)
        var resolved = resolve_under(root, raw)
        if not fs.exists(resolved.as_str()):
            var message = string.String.from_str("build.assets not found: ")
            message.append(raw)
            message.append(" (resolved to ")
            message.append(resolved.as_str())
            message.append(")")
            resolved.release()
            release_asset_paths(assets)
            return Result[bool, string.String].failure(error = message)
        assets.push(resolved)
        i += 1

    # Duplicate basenames would collide when staged beside the binary.
    var duplicates = vec.Vec[string.String].create()
    var ai: ptr_uint = 0
    while ai < assets.len():
        let left_ptr = assets.get(ai) else:
            break
        let left = unsafe: read(left_ptr).as_str()
        var aj: ptr_uint = ai + 1
        while aj < assets.len():
            let right_ptr = assets.get(aj) else:
                break
            let right = unsafe: read(right_ptr).as_str()
            if path_ops.basename(left).equal(path_ops.basename(right)):
                push_unique_name(ref_of(duplicates), path_ops.basename(left))
            aj += 1
        ai += 1
    if duplicates.len() > 0:
        sort_strings(ref_of(duplicates))
        var message = string.String.from_str("build.assets entries must have unique basenames: ")
        var di: ptr_uint = 0
        while di < duplicates.len():
            if di > 0:
                message.append(", ")
            let dup = duplicates.get(di) else:
                break
            message.append(unsafe: read(dup).as_str())
            di += 1
        release_strings(ref_of(duplicates))
        release_asset_paths(assets)
        return Result[bool, string.String].failure(error = message)
    release_strings(ref_of(duplicates))
    return Result[bool, string.String].success(value = true)


function push_unique_name(names: ref[vec.Vec[string.String]], name: str) -> void:
    var i: ptr_uint = 0
    while i < names.len():
        let existing = names.get(i) else:
            break
        if unsafe: read(existing).as_str().equal(name):
            return
        i += 1
    names.push(string.String.from_str(name))


function sort_strings(values: ref[vec.Vec[string.String]]) -> void:
    # Small lists: insertion sort on the owned strings.
    var i: ptr_uint = 1
    while i < values.len():
        let current = values.get(i) else:
            break
        var j = i
        while j > 0:
            let previous = values.get(j - 1) else:
                break
            if unsafe: read(previous).as_str().compare(unsafe: read(current).as_str()) <= 0:
                break
            unsafe:
                let tmp = read(previous)
                read(previous) = read(current)
                read(current) = tmp
            j -= 1
        i += 1


function release_strings(values: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < values.len():
        let value = values.get(i) else:
            break
        unsafe:
            read(value).release()
        i += 1
    values.release()


function release_asset_paths(values: ref[vec.Vec[string.String]]) -> void:
    release_strings(values)


function normalize_package_profile(value: str) -> Option[str]:
    if value == "" or value == "debug" or value == "dev":
        return Option[str].some(value = "debug")
    if value == "release" or value == "rel":
        return Option[str].some(value = "release")
    return Option[str].none


function normalize_package_platform(value: str) -> Option[str]:
    if value == "" or value == "linux":
        return Option[str].some(value = "linux")
    if value == "windows" or value == "win" or value == "win32":
        return Option[str].some(value = "windows")
    if value == "wasm" or value == "web" or value == "html5" or value == "browser":
        return Option[str].some(value = "wasm")
    return Option[str].none


function path_within(path: str, root: str) -> bool:
    if path.equal(root):
        return true
    if path.len <= root.len:
        return false
    if not path.slice(0, root.len).equal(root):
        return false
    return path.byte_at(root.len) == '/'
