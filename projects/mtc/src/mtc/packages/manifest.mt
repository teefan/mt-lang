## Full package manifest — the self-host port of
## `lib/milk_tea/packages/manifest.rb`: `package.toml` discovery, package/build
## settings, and the registry/path/git dependency views the resolver, lockfile
## and graph consume.
##
## Every entry point returns `Result[..., string.String]` with the host's error
## text.  The build CLI's smaller `PackageBuild` view in
## `mtc.loader.package_manifest` stays the build-path loader; this module is the
## dependency subsystem's manifest.

import std.fmt as fmt
import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.toml as toml
import std.vec as vec

import mtc.packages.paths as paths
import mtc.packages.version as version

public enum PackageKind: ubyte
    application = 0
    library = 1

public struct PackageDependency:
    name: string.String
    ## The exact version text when the requirement has exactly one `=` arm.
    version: Option[string.String]
    version_req: Option[version.PackageVersionReq]
    git: Option[string.String]
    git_rev: Option[string.String]
    git_subdir: Option[string.String]
    path: Option[string.String]

public struct PackageManifest:
    root_dir: string.String
    manifest_path: string.String
    package_name: string.String
    package_version: Option[string.String]
    package_kind: PackageKind
    source_root: string.String
    source_path: Option[string.String]
    profile: str
    platform: str
    output_path: Option[string.String]
    assets_paths: vec.Vec[string.String]
    html_template_path: Option[string.String]
    dependencies: vec.Vec[PackageDependency]

struct ManifestLocation:
    manifest_path: string.String
    root_dir: string.String


## Nested generic argument types spelled as aliases: the parser reads
## `Result[vec.Vec[...], ...]` in expression position as an index expression.
type AssetPathList = vec.Vec[string.String]
type DependencyList = vec.Vec[PackageDependency]
type OptionalPath = Option[string.String]


extending PackageDependency:
    public function path_dependency() -> bool:
        return this.path.is_some()


    public function git_dependency() -> bool:
        return this.git.is_some()


    public function registry() -> bool:
        return this.version_req.is_some() and not this.path_dependency() and not this.git_dependency()


    public function exact_registry_version() -> bool:
        if not this.registry():
            return false
        return this.version.is_some()


    public editable function release() -> void:
        this.name.release()
        release_option_string(ref_of(this.version))
        match this.version_req:
            Option.some as req:
                var owned = req.value
                owned.release()
            Option.none:
                pass
        release_option_string(ref_of(this.git))
        release_option_string(ref_of(this.git_rev))
        release_option_string(ref_of(this.git_subdir))
        release_option_string(ref_of(this.path))


extending PackageManifest:
    public function kind_name() -> str:
        match this.package_kind:
            PackageKind.application:
                return "application"
            PackageKind.library:
                return "library"
        return "application"


    public editable function release() -> void:
        this.root_dir.release()
        this.manifest_path.release()
        this.package_name.release()
        release_option_string(ref_of(this.package_version))
        this.source_root.release()
        release_option_string(ref_of(this.source_path))
        release_option_string(ref_of(this.output_path))
        var i: ptr_uint = 0
        while i < this.assets_paths.len():
            let asset = this.assets_paths.get(i) else:
                break
            unsafe: read(asset).release()
            i += 1
        this.assets_paths.release()
        release_option_string(ref_of(this.html_template_path))
        var di: ptr_uint = 0
        while di < this.dependencies.len():
            let dependency = this.dependencies.get(di) else:
                break
            unsafe: read(dependency).release()
            di += 1
        this.dependencies.release()


function release_option_string(value: ref[Option[string.String]]) -> void:
    match read(value):
        Option.some as payload:
            var owned = payload.value
            owned.release()
        Option.none:
            pass


function failure(message: string.String) -> Result[PackageManifest, string.String]:
    return Result[PackageManifest, string.String].failure(error = message)


function location_failure(message: string.String) -> Result[ManifestLocation, string.String]:
    return Result[ManifestLocation, string.String].failure(error = message)

# =============================================================================
#  Public loading
# =============================================================================

public function load(path: str) -> Result[PackageManifest, string.String]:
    var requested = paths.absolute_path(path)
    defer: requested.release()

    var location: ManifestLocation
    match resolve_manifest_path(requested.as_str()):
        Result.failure as failure_payload:
            return failure(failure_payload.error)
        Result.success as location_payload:
            location = location_payload.value
    defer: location.manifest_path.release()
    defer: location.root_dir.release()

    var text: string.String
    match fs.read_text(location.manifest_path.as_str()):
        Result.failure as read_failure:
            var read_error = read_failure.error
            var message = invalid_manifest_prefix(location.manifest_path.as_str())
            message.append(read_error.message.as_str())
            read_error.release()
            return failure(message)
        Result.success as read_payload:
            text = read_payload.value
    defer: text.release()

    var document: toml.Document
    match toml.parse(text.as_str()):
        Result.failure as parse_failure:
            var parse_error = parse_failure.error
            var message = invalid_manifest_prefix(location.manifest_path.as_str())
            message.append(parse_error.message.as_str())
            parse_error.release()
            return failure(message)
        Result.success as parse_payload:
            document = parse_payload.value
    defer: document.release()

    return build_manifest(
        ref_of(document),
        requested.as_str(),
        location.root_dir.as_str(),
        location.manifest_path.as_str()
    )


public function manifest_exists_for(path: str) -> bool:
    var expanded = paths.absolute_path(path)
    defer: expanded.release()
    var current = string.String.from_str(expanded.as_str())
    defer: current.release()
    if not fs.is_directory(current.as_str()):
        let parent = path_ops.dirname(current.as_str())
        var next = string.String.from_str(parent)
        current.release()
        current = next
    while true:
        var candidate = path_ops.join(current.as_str(), "package.toml")
        let exists = fs.is_file(candidate.as_str())
        candidate.release()
        if exists:
            return true
        let parent = path_ops.dirname(current.as_str())
        if parent.equal(current.as_str()):
            return false
        var next = string.String.from_str(parent)
        current.release()
        current = next


public function default_package_name_for_root(root_dir: str) -> string.String:
    return snake_case_identifier(path_ops.basename(root_dir))


## Ruby's `snake_case_identifier` gsub chain.
public function snake_case_identifier(name: str) -> string.String:
    var result = string.String.create()
    var i: ptr_uint = 0
    while i < name.len:
        let current = name.byte_at(i)
        if current == 45 or current == 32:
            result.push_byte('_')
            i += 1
            continue
        if is_upper(current):
            var boundary = false
            if i > 0:
                let previous = name.byte_at(i - 1)
                if is_lower(previous) or is_digit(previous):
                    boundary = true
                else if is_upper(previous) and i + 1 < name.len and is_lower(name.byte_at(i + 1)):
                    boundary = true
            if boundary:
                result.push_byte('_')
            result.push_byte(current + 32)
        else:
            result.push_byte(current)
        i += 1

    var collapsed = string.String.create()
    var last_underscore = false
    var ci: ptr_uint = 0
    while ci < result.len():
        let byte_value = result.as_str().byte_at(ci)
        if byte_value == 95:
            if not last_underscore:
                collapsed.push_byte(byte_value)
            last_underscore = true
        else:
            collapsed.push_byte(byte_value)
            last_underscore = false
        ci += 1
    result.release()
    return collapsed


function is_upper(value: ubyte) -> bool:
    return value >= 65 and value <= 90


function is_lower(value: ubyte) -> bool:
    return value >= 97 and value <= 122


function is_digit(value: ubyte) -> bool:
    return value >= 48 and value <= 57


function invalid_manifest_prefix(manifest_path: str) -> string.String:
    var message = string.String.from_str("invalid package.toml at ")
    message.append(manifest_path)
    message.append(": ")
    return message

# =============================================================================
#  Manifest discovery
# =============================================================================

function resolve_manifest_path(path: str) -> Result[ManifestLocation, string.String]:
    if fs.is_directory(path):
        var manifest_path = path_ops.join(path, "package.toml")
        if not fs.is_file(manifest_path.as_str()):
            var message = string.String.from_str("package manifest not found: ")
            message.append(manifest_path.as_str())
            manifest_path.release()
            return location_failure(message)
        return Result[ManifestLocation, string.String].success(
            value = ManifestLocation(
                manifest_path = manifest_path,
                root_dir = string.String.from_str(path),
            )
        )

    if path_ops.basename(path).equal("package.toml"):
        if not fs.is_file(path):
            var message = string.String.from_str("package manifest not found: ")
            message.append(path)
            return location_failure(message)
        var root_dir = string.String.from_str(path_ops.dirname(path))
        return Result[ManifestLocation, string.String].success(
            value = ManifestLocation(
                manifest_path = string.String.from_str(path),
                root_dir = root_dir,
            )
        )

    var current = string.String.from_str(path_ops.dirname(path))
    defer: current.release()
    while true:
        var candidate = path_ops.join(current.as_str(), "package.toml")
        if fs.is_file(candidate.as_str()):
            return Result[ManifestLocation, string.String].success(
                value = ManifestLocation(
                    manifest_path = candidate,
                    root_dir = string.String.from_str(current.as_str()),
                )
            )
        candidate.release()
        let parent = path_ops.dirname(current.as_str())
        if parent.equal(current.as_str()):
            var message = string.String.from_str("package manifest not found for ")
            message.append(path)
            return location_failure(message)
        var next = string.String.from_str(parent)
        current.release()
        current = next

# =============================================================================
#  Manifest construction
# =============================================================================

function build_manifest(
    document: ref[toml.Document],
    requested_path: str,
    root_dir: str,
    manifest_path: str,
) -> Result[PackageManifest, string.String]:
    let package_table = document.get_table("package")
    let build_table = document.get_table("build")
    let profile_table = document.get_table("profile")
    let platform_table = document.get_table("platform")

    var package_name = string.String.create()
    match table_text(package_table, "name"):
        Option.some as declared:
            if declared.value.len() > 0:
                package_name.append(declared.value.as_str())
            declared.value.release()
        Option.none:
            pass
    if package_name.len() == 0:
        var default_name = default_package_name_for_root(root_dir)
        package_name.append(default_name.as_str())
        default_name.release()

    var package_version: Option[string.String] = Option[string.String].none
    match table_text(package_table, "version"):
        Option.some as declared:
            if declared.value.len() > 0:
                package_version = Option[string.String].some(
                    value = string.String.from_str(declared.value.as_str())
                )
            declared.value.release()
        Option.none:
            pass

    var package_kind: PackageKind
    match resolve_package_kind(package_table, build_table):
        Result.failure as kind_failure:
            package_name.release()
            release_option_string(ref_of(package_version))
            return failure(kind_failure.error)
        Result.success as kind_payload:
            package_kind = kind_payload.value

    var source_root: string.String
    match resolve_manifest_source_root(package_table, root_dir):
        Result.failure as source_failure:
            package_name.release()
            release_option_string(ref_of(package_version))
            return failure(source_failure.error)
        Result.success as source_payload:
            source_root = source_payload.value

    var profile: str
    match resolve_manifest_profile(build_table, profile_table):
        Result.failure as profile_failure:
            package_name.release()
            release_option_string(ref_of(package_version))
            source_root.release()
            return failure(profile_failure.error)
        Result.success as profile_payload:
            profile = profile_payload.value

    var platform: str
    match resolve_manifest_platform(build_table, platform_table):
        Result.failure as platform_failure:
            package_name.release()
            release_option_string(ref_of(package_version))
            source_root.release()
            return failure(platform_failure.error)
        Result.success as platform_payload:
            platform = platform_payload.value

    var source_path: Option[string.String] = Option[string.String].none
    if package_kind != PackageKind.library:
        match resolve_source_path(root_dir, requested_path, build_table):
            Result.failure as source_failure:
                package_name.release()
                release_option_string(ref_of(package_version))
                source_root.release()
                return failure(source_failure.error)
            Result.success as source_payload:
                source_path = source_payload.value

    var output_path: Option[string.String] = Option[string.String].none
    match table_text(build_table, "output"):
        Option.some as declared_output:
            output_path = Option[string.String].some(
                value = paths.resolve_under(root_dir, declared_output.value.as_str())
            )
            declared_output.value.release()
        Option.none:
            pass

    var assets = vec.Vec[string.String].create()
    match parse_assets(build_table, root_dir):
        Result.failure as asset_failure:
            package_name.release()
            release_option_string(ref_of(package_version))
            source_root.release()
            release_option_string(ref_of(source_path))
            release_option_string(ref_of(output_path))
            return failure(asset_failure.error)
        Result.success as asset_payload:
            assets = asset_payload.value

    var html_template: Option[string.String]
    match resolve_manifest_html_template(build_table, root_dir):
        Result.failure as template_failure:
            package_name.release()
            release_option_string(ref_of(package_version))
            source_root.release()
            release_option_string(ref_of(source_path))
            release_option_string(ref_of(output_path))
            release_asset_paths(ref_of(assets))
            return failure(template_failure.error)
        Result.success as template_payload:
            html_template = template_payload.value

    var dependencies = vec.Vec[PackageDependency].create()
    match parse_dependencies(document, root_dir, manifest_path):
        Result.failure as dependency_failure:
            package_name.release()
            release_option_string(ref_of(package_version))
            source_root.release()
            release_option_string(ref_of(source_path))
            release_option_string(ref_of(output_path))
            release_asset_paths(ref_of(assets))
            release_option_string(ref_of(html_template))
            return failure(dependency_failure.error)
        Result.success as dependency_payload:
            dependencies = dependency_payload.value

    return Result[PackageManifest, string.String].success(
        value = PackageManifest(
            root_dir = string.String.from_str(root_dir),
            manifest_path = string.String.from_str(manifest_path),
            package_name = package_name,
            package_version = package_version,
            package_kind = package_kind,
            source_root = source_root,
            source_path = source_path,
            profile = profile,
            platform = platform,
            output_path = output_path,
            assets_paths = assets,
            html_template_path = html_template,
            dependencies = dependencies,
        )
    )


function resolve_package_kind(
    package_table: ptr[toml.Table]?,
    build_table: ptr[toml.Table]?,
) -> Result[PackageKind, string.String]:
    var kind_text = string.String.from_str("application")
    match table_text(package_table, "kind"):
        Option.some as declared_kind:
            kind_text.release()
            kind_text = string.String.from_str(declared_kind.value.as_str())
            declared_kind.value.release()
        Option.none:
            match table_text(build_table, "type"):
                Option.some as declared_type:
                    kind_text.release()
                    kind_text = string.String.from_str(declared_type.value.as_str())
                    declared_type.value.release()
                Option.none:
                    pass
    let normalized = normalize_kind(kind_text.as_str())
    kind_text.release()
    return normalized


function resolve_manifest_source_root(
    package_table: ptr[toml.Table]?,
    root_dir: str,
) -> Result[string.String, string.String]:
    var source_root_value: Option[string.String] = table_text(package_table, "source_root")
    if source_root_value.is_none():
        source_root_value = default_source_root(root_dir)

    var source_root_raw = string.String.create()
    match source_root_value:
        Option.some as declared_root:
            source_root_raw.append(declared_root.value.as_str())
            declared_root.value.release()
        Option.none:
            pass
    var source_root = paths.resolve_under(root_dir, source_root_raw.as_str())
    if not fs.is_directory(source_root.as_str()):
        var message = string.String.from_str("package.source_root not found: ")
        message.append(source_root_raw.as_str())
        message.append(" (resolved to ")
        message.append(source_root.as_str())
        message.append(")")
        source_root_raw.release()
        source_root.release()
        return Result[string.String, string.String].failure(error = message)
    source_root_raw.release()
    return Result[string.String, string.String].success(value = source_root)


function resolve_manifest_profile(
    build_table: ptr[toml.Table]?,
    profile_table: ptr[toml.Table]?,
) -> Result[str, string.String]:
    var profile_value: Option[string.String] = table_text(build_table, "profile")
    if profile_value.is_none():
        profile_value = table_text(profile_table, "default")
    match profile_value:
        Option.some as declared_profile:
            var text = declared_profile.value
            let normalized = normalize_profile(text.as_str())
            text.release()
            return normalized
        Option.none:
            return Result[str, string.String].success(value = "debug")


function resolve_manifest_platform(
    build_table: ptr[toml.Table]?,
    platform_table: ptr[toml.Table]?,
) -> Result[str, string.String]:
    var platform_value: Option[string.String] = table_text(build_table, "platform")
    if platform_value.is_none():
        platform_value = table_text(platform_table, "default")
    match platform_value:
        Option.some as declared_platform:
            var text = declared_platform.value
            let normalized = normalize_platform(text.as_str())
            text.release()
            return normalized
        Option.none:
            return Result[str, string.String].success(value = "linux")


function resolve_manifest_html_template(
    build_table: ptr[toml.Table]?,
    root_dir: str,
) -> Result[OptionalPath, string.String]:
    match table_text(build_table, "html_template"):
        Option.some as declared_template:
            var resolved = paths.resolve_under(root_dir, declared_template.value.as_str())
            if not fs.is_file(resolved.as_str()):
                var message = string.String.from_str("build.html_template not found: ")
                message.append(declared_template.value.as_str())
                message.append(" (resolved to ")
                message.append(resolved.as_str())
                message.append(")")
                resolved.release()
                declared_template.value.release()
                return Result[OptionalPath, string.String].failure(error = message)
            declared_template.value.release()
            return Result[OptionalPath, string.String].success(
                value = Option[string.String].some(value = resolved)
            )
        Option.none:
            return Result[OptionalPath, string.String].success(value = Option[string.String].none)


function default_source_root(root_dir: str) -> Option[string.String]:
    var conventional = path_ops.join(root_dir, "src")
    let exists = fs.is_directory(conventional.as_str())
    conventional.release()
    if exists:
        return Option[string.String].some(value = string.String.from_str("src"))
    return Option[string.String].some(value = string.String.from_str("."))


## The host's `resolve_source_path`: no source for an entry-less package; an
## explicit `build.entry` must exist, otherwise `src/main.mt` (or the requested
## file, when it lies within the package) is used.
function resolve_source_path(
    root_dir: str,
    requested_path: str,
    build_table: ptr[toml.Table]?,
) -> Result[OptionalPath, string.String]:
    match table_text(build_table, "entry"):
        Option.some as declared_entry:
            var source_path = paths.resolve_under(root_dir, declared_entry.value.as_str())
            if not fs.is_file(source_path.as_str()):
                var message = string.String.from_str("build.entry not found: ")
                message.append(declared_entry.value.as_str())
                message.append(" (resolved to ")
                message.append(source_path.as_str())
                message.append(")")
                source_path.release()
                return Result[OptionalPath, string.String].failure(error = message)
            return Result[OptionalPath, string.String].success(
                value = Option[string.String].some(value = source_path)
            )
        Option.none:
            pass

    var default_main = path_ops.join(root_dir, "src/main.mt")
    let has_default = fs.is_file(default_main.as_str())
    if has_default:
        let absolute = paths.absolute_path(default_main.as_str())
        default_main.release()
        return Result[OptionalPath, string.String].success(
            value = Option[string.String].some(value = absolute)
        )
    default_main.release()

    var requested = paths.absolute_path(requested_path)
    defer: requested.release()
    if fs.is_file(requested.as_str()) and paths.path_within_root(requested.as_str(), root_dir):
        return Result[OptionalPath, string.String].success(
            value = Option[string.String].some(value = string.String.from_str(requested.as_str()))
        )
    return Result[OptionalPath, string.String].success(value = Option[string.String].none)


function normalize_kind(value: str) -> Result[PackageKind, string.String]:
    if value == "" or value == "application" or value == "app" or value == "executable":
        return Result[PackageKind, string.String].success(value = PackageKind.application)
    if value == "library" or value == "lib":
        return Result[PackageKind, string.String].success(value = PackageKind.library)
    var message = string.String.from_str("unknown package kind ")
    message.append(value)
    message.append("; expected application|library")
    return Result[PackageKind, string.String].failure(error = message)


function normalize_profile(value: str) -> Result[str, string.String]:
    if value == "" or value == "debug" or value == "dev":
        return Result[str, string.String].success(value = "debug")
    if value == "release" or value == "rel":
        return Result[str, string.String].success(value = "release")
    var message = string.String.from_str("unknown profile ")
    message.append(value)
    message.append("; expected debug|release")
    return Result[str, string.String].failure(error = message)


function normalize_platform(value: str) -> Result[str, string.String]:
    if value == "" or value == "linux":
        return Result[str, string.String].success(value = "linux")
    if value == "windows" or value == "win" or value == "win32":
        return Result[str, string.String].success(value = "windows")
    if value == "wasm" or value == "web" or value == "html5" or value == "browser":
        return Result[str, string.String].success(value = "wasm")
    if value == "darwin" or value == "macos" or value == "osx":
        return Result[str, string.String].success(value = "darwin")
    var message = string.String.from_str("unknown platform ")
    message.append(value)
    message.append("; expected linux|windows|wasm|darwin")
    return Result[str, string.String].failure(error = message)

# =============================================================================
#  TOML value access
# =============================================================================

function table_text(table: ptr[toml.Table]?, key: str) -> Option[string.String]:
    if table == null:
        return Option[string.String].none
    unsafe:
        let entry = find_object_entry(ref_of(read(table).entries), key)
        if entry == null:
            return Option[string.String].none
        return value_text(read(entry).value)


function object_text(object: ref[toml.Object], key: str) -> Option[string.String]:
    let entry = find_object_entry(object, key)
    if entry == null:
        return Option[string.String].none
    unsafe:
        return value_text(read(entry).value)


function find_object_entry(object: ref[toml.Object], key: str) -> ptr[toml.Entry]?:
    var i: ptr_uint = 0
    while i < object.entries.len():
        let entry = object.entries.get(i) else:
            return null
        unsafe:
            if read(entry).key.as_str().equal(key):
                return entry
        i += 1
    return null


## Ruby's `value.to_s` for the scalar kinds package manifests use.
function value_text(value: toml.Value) -> Option[string.String]:
    match value.kind:
        toml.ValueKind.string_:
            return Option[string.String].some(value = string.String.from_str(value.string_value.as_str()))
        toml.ValueKind.integer:
            var rendered = string.String.create()
            fmt.append_long(ref_of(rendered), value.integer_value)
            return Option[string.String].some(value = rendered)
        toml.ValueKind.boolean:
            if value.boolean_value:
                return Option[string.String].some(value = string.String.from_str("true"))
            return Option[string.String].some(value = string.String.from_str("false"))
        toml.ValueKind.array_:
            return Option[string.String].none
        toml.ValueKind.object_:
            return Option[string.String].none
    return Option[string.String].none


function value_class_name(value: toml.Value) -> str:
    match value.kind:
        toml.ValueKind.string_:
            return "String"
        toml.ValueKind.integer:
            return "Integer"
        toml.ValueKind.boolean:
            return "TrueClass"
        toml.ValueKind.array_:
            return "Array"
        toml.ValueKind.object_:
            return "Hash"
    return "Object"


function normalized_optional(value: Option[string.String]) -> Option[string.String]:
    match value:
        Option.some as payload:
            let text = payload.value.as_str().trim_ascii_whitespace()
            if text.len == 0:
                payload.value.release()
                return Option[string.String].none
            var owned = string.String.from_str(text)
            payload.value.release()
            return Option[string.String].some(value = owned)
        Option.none:
            return Option[string.String].none

# =============================================================================
#  Assets
# =============================================================================

function parse_assets(build_table: ptr[toml.Table]?, root_dir: str) -> Result[AssetPathList, string.String]:
    var assets = vec.Vec[string.String].create()
    if build_table == null:
        return Result[AssetPathList, string.String].success(value = assets)

    var raws = vec.Vec[string.String].create()
    defer: release_asset_paths(ref_of(raws))

    unsafe:
        let array_ptr = read(build_table).entries.get_array("assets")
        if array_ptr != null:
            let values = read(array_ptr)
            var i: ptr_uint = 0
            while i < values.len():
                match values.get_string(i):
                    Option.some as raw:
                        raws.push(string.String.from_str(raw.value))
                    Option.none:
                        let value_ptr = values.values.get(i) else:
                            break
                        match value_text(read(value_ptr)):
                            Option.some as rendered:
                                raws.push(rendered.value)
                            Option.none:
                                raws.push(string.String.from_str(""))
                i += 1
        else:
            match table_text(build_table, "assets"):
                Option.some as raw:
                    raws.push(raw.value)
                Option.none:
                    pass

    var i: ptr_uint = 0
    while i < raws.len():
        let raw_entry = raws.get(i) else:
            break
        let raw = unsafe: read(raw_entry)
        var resolved = paths.resolve_under(root_dir, raw.as_str())
        if not fs.exists(resolved.as_str()):
            var message = string.String.from_str("build.assets not found: ")
            message.append(raw.as_str())
            message.append(" (resolved to ")
            message.append(resolved.as_str())
            message.append(")")
            resolved.release()
            release_asset_paths(ref_of(assets))
            return Result[AssetPathList, string.String].failure(error = message)
        assets.push(resolved)
        i += 1

    var duplicates = vec.Vec[string.String].create()
    var ai: ptr_uint = 0
    while ai < assets.len():
        let left_entry = assets.get(ai) else:
            break
        let left = path_ops.basename(unsafe: read(left_entry).as_str())
        var aj: ptr_uint = ai + 1
        while aj < assets.len():
            let right_entry = assets.get(aj) else:
                break
            let right = path_ops.basename(unsafe: read(right_entry).as_str())
            if left.equal(right):
                push_unique_name(ref_of(duplicates), left)
            aj += 1
        ai += 1
    if duplicates.len() > 0:
        duplicates.sort_by(proc(
            a: ptr[string.String],
            b: ptr[string.String]
        ) -> int: unsafe: read(a).as_str().compare(unsafe: read(b).as_str()))
        var message = string.String.from_str("build.assets entries must have unique basenames: ")
        var di: ptr_uint = 0
        while di < duplicates.len():
            if di > 0:
                message.append(", ")
            let duplicate = duplicates.get(di) else:
                break
            message.append(unsafe: read(duplicate).as_str())
            di += 1
        release_asset_paths(ref_of(duplicates))
        release_asset_paths(ref_of(assets))
        return Result[AssetPathList, string.String].failure(error = message)
    release_asset_paths(ref_of(duplicates))
    return Result[AssetPathList, string.String].success(value = assets)


function push_unique_name(names: ref[vec.Vec[string.String]], name: str) -> void:
    var i: ptr_uint = 0
    while i < names.len():
        let existing = names.get(i) else:
            break
        if unsafe: read(existing).as_str().equal(name):
            return
        i += 1
    names.push(string.String.from_str(name))


function release_asset_paths(values: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < values.len():
        let value = values.get(i) else:
            break
        unsafe: read(value).release()
        i += 1
    values.release()

# =============================================================================
#  Dependencies
# =============================================================================

function parse_dependencies(
    document: ref[toml.Document],
    root_dir: str,
    manifest_path: str,
) -> Result[DependencyList, string.String]:
    var dependencies = vec.Vec[PackageDependency].create()

    let table = document.get_table("dependencies")
    if table != null:
        unsafe:
            let entries = read(table).entries.entries
            var i: ptr_uint = 0
            while i < entries.len():
                let entry = entries.get(i) else:
                    break
                let item = read(entry)
                match parse_dependency(item.key.as_str(), item.value, root_dir, manifest_path):
                    Result.failure as failure_payload:
                        release_dependencies(ref_of(dependencies))
                        return Result[DependencyList, string.String].failure(
                            error = failure_payload.error
                        )
                    Result.success as payload:
                        dependencies.push(payload.value)
                i += 1
        return Result[DependencyList, string.String].success(value = dependencies)

    # An inline `dependencies = { ... }` root value is a Hash in Tomlrb.
    let inline_deps = document.root.get_object("dependencies")
    if inline_deps != null:
        unsafe:
            var i: ptr_uint = 0
            while i < read(inline_deps).entries.len():
                let entry = read(inline_deps).entries.get(i) else:
                    break
                let item = read(entry)
                match parse_dependency(item.key.as_str(), item.value, root_dir, manifest_path):
                    Result.failure as failure_payload:
                        release_dependencies(ref_of(dependencies))
                        return Result[DependencyList, string.String].failure(
                            error = failure_payload.error
                        )
                    Result.success as payload:
                        dependencies.push(payload.value)
                i += 1
        return Result[DependencyList, string.String].success(value = dependencies)

    # A root `dependencies` value that is neither a table nor an inline object.
    let raw = find_object_entry(ref_of(document.root), "dependencies")
    if raw != null:
        unsafe:
            let kind = read(raw).value.kind
            if kind != toml.ValueKind.object_:
                var message = string.String.from_str("dependencies must be a table in ")
                message.append(manifest_path)
                return Result[DependencyList, string.String].failure(error = message)

    return Result[DependencyList, string.String].success(value = dependencies)


function release_dependencies(values: ref[vec.Vec[PackageDependency]]) -> void:
    var i: ptr_uint = 0
    while i < values.len():
        let value = values.get(i) else:
            break
        unsafe: read(value).release()
        i += 1
    values.release()


function parse_dependency(
    name: str,
    value: toml.Value,
    root_dir: str,
    manifest_path: str,
) -> Result[PackageDependency, string.String]:
    match value.kind:
        toml.ValueKind.string_:
            return registry_dependency(name, value.string_value.as_str(), manifest_path)
        toml.ValueKind.object_:
            return parse_dependency_object(name, value.object_value, root_dir, manifest_path)
        toml.ValueKind.array_:
            return unsupported_dependency(name, manifest_path, value_class_name(value))
        toml.ValueKind.integer:
            return unsupported_dependency(name, manifest_path, value_class_name(value))
        toml.ValueKind.boolean:
            return unsupported_dependency(name, manifest_path, value_class_name(value))
    return unsupported_dependency(name, manifest_path, value_class_name(value))


function unsupported_dependency(
    name: str,
    manifest_path: str,
    class_name: str
) -> Result[PackageDependency, string.String]:
    var message = string.String.from_str("dependency ")
    message.append(name)
    message.append(" in ")
    message.append(manifest_path)
    message.append(" has unsupported type ")
    message.append(class_name)
    return Result[PackageDependency, string.String].failure(error = message)


function parse_dependency_object(
    name: str,
    object: ptr[toml.Object]?,
    root_dir: str,
    manifest_path: str,
) -> Result[PackageDependency, string.String]:
    if object == null:
        return unsupported_dependency(name, manifest_path, "Hash")
    var fields = unsafe: read(object)

    var version_value = normalized_optional(object_text(ref_of(fields), "version"))
    var git_value = normalized_optional(object_text(ref_of(fields), "git"))
    var git_rev_value = normalized_optional(object_text(ref_of(fields), "rev"))
    var git_subdir_value = normalized_optional(object_text(ref_of(fields), "subdir"))
    var path_value = normalized_optional(object_text(ref_of(fields), "path"))

    if git_rev_value.is_some() and git_value.is_none():
        return dependency_error_owned(
            name, manifest_path, " declares rev without git", ref_of(version_value), ref_of(git_value),
            ref_of(git_rev_value), ref_of(git_subdir_value), ref_of(path_value)
        )
    if git_subdir_value.is_some() and git_value.is_none():
        return dependency_error_owned(
            name, manifest_path, " declares subdir without git", ref_of(version_value), ref_of(git_value),
            ref_of(git_rev_value), ref_of(git_subdir_value), ref_of(path_value)
        )
    if version_value.is_some() and git_value.is_some():
        return dependency_error_owned(
            name, manifest_path, " cannot combine version with git resolution", ref_of(version_value),
            ref_of(git_value), ref_of(git_rev_value), ref_of(git_subdir_value), ref_of(path_value)
        )

    var declared_sources: ptr_uint = 0
    if git_value.is_some():
        declared_sources += 1
    if path_value.is_some():
        declared_sources += 1
    if version_value.is_some() and path_value.is_none() and git_value.is_none():
        declared_sources += 1

    if declared_sources == 0:
        return dependency_error_owned(
            name, manifest_path, " must declare version, git, or path", ref_of(version_value),
            ref_of(git_value), ref_of(git_rev_value), ref_of(git_subdir_value), ref_of(path_value)
        )
    if declared_sources > 1:
        return dependency_error_owned(
            name, manifest_path, " must choose exactly one of version, git, or path", ref_of(version_value),
            ref_of(git_value), ref_of(git_rev_value), ref_of(git_subdir_value), ref_of(path_value)
        )

    if path_value.is_some():
        var declared_path = path_value.unwrap()
        var resolved = paths.resolve_under(root_dir, declared_path.as_str())
        if not fs.is_directory(resolved.as_str()):
            var message = string.String.from_str("dependency ")
            message.append(name)
            message.append(" path not found: ")
            message.append(declared_path.as_str())
            message.append(" (resolved to ")
            message.append(resolved.as_str())
            message.append(")")
            resolved.release()
            declared_path.release()
            release_option_string(ref_of(version_value))
            release_option_string(ref_of(git_value))
            release_option_string(ref_of(git_rev_value))
            release_option_string(ref_of(git_subdir_value))
            return Result[PackageDependency, string.String].failure(error = message)
        var version_req: Option[version.PackageVersionReq] = Option[version.PackageVersionReq].none
        var exact_version: Option[string.String] = Option[string.String].none
        if version_value.is_some():
            var requirement_text = version_value.unwrap()
            match parse_requirement_owned(name, requirement_text.as_str(), manifest_path):
                Result.failure as req_failure:
                    requirement_text.release()
                    resolved.release()
                    declared_path.release()
                    release_option_string(ref_of(git_value))
                    release_option_string(ref_of(git_rev_value))
                    release_option_string(ref_of(git_subdir_value))
                    return Result[PackageDependency, string.String].failure(error = req_failure.error)
                Result.success as req_payload:
                    requirement_text.release()
                    var parsed_req = req_payload.value
                    if parsed_req.exact():
                        let exact = parsed_req.exact_version().expect("exact version")
                        exact_version = Option[string.String].some(value = exact.to_string())
                    version_req = Option[version.PackageVersionReq].some(value = parsed_req)
        var dependency = PackageDependency(
            name = string.String.from_str(name),
            version = exact_version,
            version_req = version_req,
            git = Option[string.String].none,
            git_rev = Option[string.String].none,
            git_subdir = Option[string.String].none,
            path = Option[string.String].some(value = resolved),
        )
        declared_path.release()
        release_option_string(ref_of(git_value))
        release_option_string(ref_of(git_rev_value))
        release_option_string(ref_of(git_subdir_value))
        return Result[PackageDependency, string.String].success(value = dependency)

    if git_value.is_some():
        if git_rev_value.is_none():
            return dependency_error_owned(
                name, manifest_path, " uses git resolution but is missing rev", ref_of(version_value),
                ref_of(git_value), ref_of(git_rev_value), ref_of(git_subdir_value), ref_of(path_value)
            )
        return Result[PackageDependency, string.String].success(
            value = PackageDependency(
                name = string.String.from_str(name),
                version = Option[string.String].none,
                version_req = Option[version.PackageVersionReq].none,
                git = git_value,
                git_rev = git_rev_value,
                git_subdir = git_subdir_value,
                path = Option[string.String].none,
            )
        )

    # A version-only spec.
    var requirement_text = version_value.unwrap()
    match parse_requirement_owned(name, requirement_text.as_str(), manifest_path):
        Result.failure as req_failure:
            requirement_text.release()
            release_dependency_parts(
                ref_of(version_value),
                ref_of(git_value),
                ref_of(git_rev_value),
                ref_of(git_subdir_value),
                ref_of(path_value)
            )
            return Result[PackageDependency, string.String].failure(error = req_failure.error)
        Result.success as req_payload:
            requirement_text.release()
            release_option_string(ref_of(git_value))
            release_option_string(ref_of(git_rev_value))
            release_option_string(ref_of(git_subdir_value))
            release_option_string(ref_of(path_value))
            return dependency_from_requirement(name, req_payload.value)


function dependency_error_owned(
    name: str,
    manifest_path: str,
    suffix: str,
    version_value: ref[Option[string.String]],
    git_value: ref[Option[string.String]],
    git_rev_value: ref[Option[string.String]],
    git_subdir_value: ref[Option[string.String]],
    path_value: ref[Option[string.String]],
) -> Result[PackageDependency, string.String]:
    var message = string.String.from_str("dependency ")
    message.append(name)
    message.append(" in ")
    message.append(manifest_path)
    message.append(suffix)
    release_dependency_parts(version_value, git_value, git_rev_value, git_subdir_value, path_value)
    return Result[PackageDependency, string.String].failure(error = message)


function release_dependency_parts(
    version_value: ref[Option[string.String]],
    git_value: ref[Option[string.String]],
    git_rev_value: ref[Option[string.String]],
    git_subdir_value: ref[Option[string.String]],
    path_value: ref[Option[string.String]],
) -> void:
    release_option_string(version_value)
    release_option_string(git_value)
    release_option_string(git_rev_value)
    release_option_string(git_subdir_value)
    release_option_string(path_value)


function parse_requirement_owned(
    name: str,
    requirement_text: str,
    manifest_path: str,
) -> Result[version.PackageVersionReq, string.String]:
    var label = string.String.from_str("dependency ")
    label.append(name)
    label.append(" in ")
    label.append(manifest_path)
    label.append(" version requirement")
    defer: label.release()
    return version.parse_requirement(requirement_text, label.as_str())


function registry_dependency(
    name: str,
    raw_requirement: str,
    manifest_path: str,
) -> Result[PackageDependency, string.String]:
    match parse_requirement_owned(name, raw_requirement, manifest_path):
        Result.failure as req_failure:
            return Result[PackageDependency, string.String].failure(error = req_failure.error)
        Result.success as req_payload:
            return dependency_from_requirement(name, req_payload.value)


function dependency_from_requirement(
    name: str,
    req: version.PackageVersionReq,
) -> Result[PackageDependency, string.String]:
    var exact_version: Option[string.String] = Option[string.String].none
    if req.exact():
        let exact = req.exact_version().expect("exact version")
        exact_version = Option[string.String].some(value = exact.to_string())
    return Result[PackageDependency, string.String].success(
        value = PackageDependency(
            name = string.String.from_str(name),
            version = exact_version,
            version_req = Option[version.PackageVersionReq].some(value = req),
            git = Option[string.String].none,
            git_rev = Option[string.String].none,
            git_subdir = Option[string.String].none,
            path = Option[string.String].none,
        )
    )
