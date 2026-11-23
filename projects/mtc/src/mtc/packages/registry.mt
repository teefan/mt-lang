## Package registry store — the self-host port of
## `lib/milk_tea/packages/registry_store.rb` and
## `registry_metadata_provider.rb`: a filesystem registry rooted at
## `MILK_TEA_PACKAGE_REGISTRY` (or `$XDG_DATA_HOME/milk_tea/registry`), an
## optional filesystem or HTTP upstream, deterministic archives plus a
## `versions.txt` index, and sync-on-demand for missing packages.

import std.async as aio
import std.bytes as bytes
import std.env as env
import std.fs as fs
import std.http as http
import std.path as path_ops
import std.str
import std.string as string
import std.tar as tar
import std.vec as vec

import mtc.packages.manifest as manifest
import mtc.packages.paths as paths
import mtc.packages.version as version


## Nested generic argument spelled as an alias (see manifest.mt).
type VersionList = vec.Vec[string.String]


public struct RegistryStore:
    root: string.String
    upstream_root: Option[string.String]


public struct RegistryResult:
    package_name: string.String
    version: string.String
    path: string.String


struct HttpResponse:
    status: int
    reason: string.String
    body: bytes.Bytes
    location: string.String


struct HttpOutcome:
    ok: bool
    status: int
    reason: string.String
    body: bytes.Bytes
    location: string.String
    message: string.String


extending RegistryResult:
    public editable function release() -> void:
        this.package_name.release()
        this.version.release()
        this.path.release()


extending HttpResponse:
    public editable function release() -> void:
        this.reason.release()
        this.body.release()
        this.location.release()


function failure(message: string.String) -> Result[RegistryStore, string.String]:
    return Result[RegistryStore, string.String].failure(error = message)


function result_failure(message: string.String) -> Result[RegistryResult, string.String]:
    return Result[RegistryResult, string.String].failure(error = message)


function store_error(store: ref[RegistryStore], message: str) -> string.String:
    return string.String.from_str(message)


# =============================================================================
#  Store construction
# =============================================================================

public function create() -> RegistryStore:
    var root = string.String.create()
    var explicit = env_non_empty("MILK_TEA_PACKAGE_REGISTRY")
    if explicit.is_some():
        var value = explicit.unwrap()
        var absolute = paths.absolute_path(value.as_str())
        root.append(absolute.as_str())
        absolute.release()
        value.release()
    else:
        var base = xdg_data_home()
        defer: base.release()
        var joined = path_ops.join(base.as_str(), "milk_tea/registry")
        var absolute = paths.absolute_path(joined.as_str())
        root.append(absolute.as_str())
        absolute.release()
        joined.release()

    var upstream: Option[string.String] = Option[string.String].none
    var configured = env_non_empty("MILK_TEA_PACKAGE_REGISTRY_UPSTREAM")
    if configured.is_some():
        var value = configured.unwrap()
        var text = string.String.create()
        let trimmed = value.as_str().trim_ascii_whitespace()
        if http_url(trimmed):
            text.append(trim_trailing_slashes(trimmed))
        else:
            var absolute = paths.absolute_path(trimmed)
            text.append(absolute.as_str())
            absolute.release()
        value.release()
        upstream = Option[string.String].some(value = text)

    return RegistryStore(root = root, upstream_root = upstream)


public function release_store(store: ref[RegistryStore]) -> void:
    store.root.release()
    match read(store).upstream_root:
        Option.some as payload:
            var owned = payload.value
            owned.release()
        Option.none:
            pass


function xdg_data_home() -> string.String:
    var explicit = env_non_empty("XDG_DATA_HOME")
    if explicit.is_some():
        var value = explicit.unwrap()
        var absolute = paths.absolute_path(value.as_str())
        value.release()
        return absolute
    match env.home():
        Option.some as home:
            var joined = path_ops.join(home.value, ".local/share")
            var absolute = paths.absolute_path(joined.as_str())
            joined.release()
            return absolute
        Option.none:
            return string.String.from_str("/tmp")
    return string.String.from_str("/tmp")


function env_non_empty(name: str) -> Option[string.String]:
    match env.get(name):
        Option.some as value:
            let trimmed = value.value.trim_ascii_whitespace()
            if trimmed.len == 0:
                return Option[string.String].none
            return Option[string.String].some(value = string.String.from_str(trimmed))
        Option.none:
            return Option[string.String].none


function http_url(value: str) -> bool:
    return value.starts_with("http://") or value.starts_with("https://")


function trim_trailing_slashes(value: str) -> str:
    var end = value.len
    while end > 0 and value.byte_at(end - 1) == 47:
        end -= 1
    return value.slice(0, end)


public function upstream_configured(store: ref[RegistryStore]) -> bool:
    return read(store).upstream_root.is_some()


public function upstream_http(store: ref[RegistryStore]) -> bool:
    match read(store).upstream_root:
        Option.some as payload:
            return http_url(payload.value.as_str())
        Option.none:
            return false
    return false


## Borrowed view of the configured upstream ("" when unset), valid while the
## store lives.  Callers must not release it.
function upstream_view(store: ref[RegistryStore]) -> str:
    match read(store).upstream_root:
        Option.some as payload:
            return payload.value.as_str()
        Option.none:
            return ""
    return ""


## Convenience entry points for the resolver/fetcher: each builds the store
## from the environment, performs one operation, and releases it.
public function available_versions_default(package_name: str) -> Result[VersionList, string.String]:
    var store = create()
    defer: release_store(ref_of(store))
    return available_versions(ref_of(store), package_name)


public function published_root_default(
    package_name: str,
    package_version: str,
    sync_missing: bool,
) -> Result[string.String, string.String]:
    var store = create()
    defer: release_store(ref_of(store))
    return published_root_for(ref_of(store), package_name, package_version, sync_missing)


public function publish_default(path: str, target_upstream: bool) -> Result[RegistryResult, string.String]:
    var store = create()
    defer: release_store(ref_of(store))
    return publish(ref_of(store), path, target_upstream)


# =============================================================================
#  Paths and publication state
# =============================================================================

public function package_root_for(store: ref[RegistryStore], package_name: str, package_version: str) -> Result[string.String, string.String]:
    return package_root_for_root(read(store).root.as_str(), package_name, package_version)


function package_root_for_root(root: str, package_name: str, package_version: str) -> Result[string.String, string.String]:
    match normalize_component(package_name, "package name"):
        Result.failure as failure_payload:
            return Result[string.String, string.String].failure(error = failure_payload.error)
        Result.success as name_payload:
            var name = name_payload.value
            defer: name.release()
            match normalize_component(package_version, "package version"):
                Result.failure as version_failure:
                    return Result[string.String, string.String].failure(error = version_failure.error)
                Result.success as version_payload:
                    var version_text = version_payload.value
                    defer: version_text.release()
                    var base = path_ops.join(root, "packages")
                    defer: base.release()
                    var package_dir = path_ops.join(base.as_str(), name.as_str())
                    defer: package_dir.release()
                    return Result[string.String, string.String].success(
                        value = path_ops.join(package_dir.as_str(), version_text.as_str())
                    )
    return Result[string.String, string.String].failure(error = string.String.from_str("invalid package path"))


public function manifest_path_for(store: ref[RegistryStore], package_name: str, package_version: str) -> Result[string.String, string.String]:
    match package_root_for(store, package_name, package_version):
        Result.failure as failure_payload:
            return Result[string.String, string.String].failure(error = failure_payload.error)
        Result.success as root_payload:
            var root = root_payload.value
            defer: root.release()
            return Result[string.String, string.String].success(
                value = path_ops.join(root.as_str(), "package.toml")
            )


public function published(store: ref[RegistryStore], package_name: str, package_version: str) -> bool:
    match manifest_path_for(store, package_name, package_version):
        Result.failure as failure_payload:
            var message = failure_payload.error
            message.release()
            return false
        Result.success as path_payload:
            var path = path_payload.value
            defer: path.release()
            return fs.is_file(path.as_str())


public function published_root_for(
    store: ref[RegistryStore],
    package_name: str,
    package_version: str,
    sync_missing: bool,
) -> Result[string.String, string.String]:
    if sync_missing and not published(store, package_name, package_version) and upstream_configured(store):
        match sync(store, package_name, package_version):
            Result.failure as failure_payload:
                return Result[string.String, string.String].failure(error = failure_payload.error)
            Result.success as synced:
                var result = synced.value
                result.release()

    if not published(store, package_name, package_version):
        var message = string.String.from_str("registry package ")
        message.append(package_name)
        message.append(" version ")
        message.append(package_version)
        message.append(" not found in ")
        message.append(read(store).root.as_str())
        return Result[string.String, string.String].failure(error = message)

    return package_root_for(store, package_name, package_version)


function normalize_component(value: str, label: str) -> Result[string.String, string.String]:
    let text = value.trim_ascii_whitespace()
    if text.len == 0:
        var message = string.String.from_str(label)
        message.append(" cannot be empty")
        return Result[string.String, string.String].failure(error = message)
    var i: ptr_uint = 0
    while i < text.len:
        let byte_value = text.byte_at(i)
        if byte_value == 47 or byte_value == 92:
            var message = string.String.from_str(label)
            message.append(" contains an unsupported path separator: \"")
            message.append(text)
            message.append("\"")
            return Result[string.String, string.String].failure(error = message)
        i += 1
    if text.equal(".") or text.equal(".."):
        var message = string.String.from_str(label)
        message.append(" contains an unsupported path separator: \"")
        message.append(text)
        message.append("\"")
        return Result[string.String, string.String].failure(error = message)
    return Result[string.String, string.String].success(value = string.String.from_str(text))


# =============================================================================
#  Version listing
# =============================================================================

public function available_versions(store: ref[RegistryStore], package_name: str) -> Result[VersionList, string.String]:
    var versions = vec.Vec[string.String].create()
    if upstream_configured(store):
        if upstream_http(store):
            match package_versions_for_http(store, package_name):
                Result.failure as failure_payload:
                    release_versions(ref_of(versions))
                    return Result[VersionList, string.String].failure(error = failure_payload.error)
                Result.success as upstream_payload:
                    append_versions(ref_of(versions), ref_of(upstream_payload.value))
                    upstream_payload.value.release()
        else:
            let upstream_root = upstream_view(store)
            match package_versions_for_root(upstream_root, package_name):
                Result.failure as failure_payload:
                    release_versions(ref_of(versions))
                    return Result[VersionList, string.String].failure(error = failure_payload.error)
                Result.success as upstream_payload:
                    append_versions(ref_of(versions), ref_of(upstream_payload.value))
                    upstream_payload.value.release()

    match package_versions_for_root(read(store).root.as_str(), package_name):
        Result.failure as failure_payload:
            release_versions(ref_of(versions))
            return Result[VersionList, string.String].failure(error = failure_payload.error)
        Result.success as local_payload:
            append_versions(ref_of(versions), ref_of(local_payload.value))
            local_payload.value.release()

    return Result[VersionList, string.String].success(value = versions)


function append_versions(target: ref[vec.Vec[string.String]], source: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < source.len():
        let value = source.get(i) else:
            break
        let text = unsafe: read(value).as_str()
        if not contains_version(target, text):
            target.push(string.String.from_str(text))
        i += 1


function contains_version(target: ref[vec.Vec[string.String]], candidate: str) -> bool:
    var i: ptr_uint = 0
    while i < target.len():
        let value = target.get(i) else:
            return false
        if unsafe: read(value).as_str().equal(candidate):
            return true
        i += 1
    return false


function release_versions(values: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < values.len():
        let value = values.get(i) else:
            break
        unsafe: read(value).release()
        i += 1
    values.release()


function package_versions_for_root(root: str, package_name: str) -> Result[VersionList, string.String]:
    var versions = vec.Vec[string.String].create()
    match normalize_component(package_name, "package name"):
        Result.failure as name_failure:
            return Result[VersionList, string.String].failure(error = name_failure.error)
        Result.success as name_payload:
            var name = name_payload.value
            defer: name.release()
            var base = path_ops.join(root, "packages")
            defer: base.release()
            var package_dir = path_ops.join(base.as_str(), name.as_str())
            defer: package_dir.release()
            if not fs.is_directory(package_dir.as_str()):
                return Result[VersionList, string.String].success(value = versions)

            match fs.list_entries(package_dir.as_str()):
                Result.failure as list_failure:
                    var list_error = list_failure.error
                    var message = string.String.from_str("failed to inspect registry package versions under ")
                    message.append(package_dir.as_str())
                    message.append(": ")
                    message.append(list_error.message.as_str())
                    list_error.release()
                    return Result[VersionList, string.String].failure(error = message)
                Result.success as entries_payload:
                    var entries = entries_payload.value
                    defer: entries.release()
                    var names = vec.Vec[string.String].create()
                    defer: names.release()
                    var i: ptr_uint = 0
                    while i < entries.len():
                        let entry = entries.get(i) else:
                            break
                        if entry.len > 0 and not entry.starts_with(".") and not entry.equal("versions.txt") and not entry.ends_with(".tar.gz"):
                            names.push(string.String.from_str(entry))
                        i += 1
                    names.sort_by(proc(left: ptr[string.String], right: ptr[string.String]) -> int: unsafe: read(left).as_str().compare(unsafe: read(right).as_str()))
                    var ni: ptr_uint = 0
                    while ni < names.len():
                        let name_entry = names.get(ni) else:
                            break
                        let entry_name = unsafe: read(name_entry).as_str()
                        var package_toml = path_ops.join(package_dir.as_str(), entry_name)
                        var manifest_file = path_ops.join(package_toml.as_str(), "package.toml")
                        if fs.is_file(manifest_file.as_str()):
                            versions.push(string.String.from_str(entry_name))
                        manifest_file.release()
                        package_toml.release()
                        ni += 1
            return Result[VersionList, string.String].success(value = versions)
    return Result[VersionList, string.String].success(value = versions)


# =============================================================================
#  Publish and sync
# =============================================================================

public function publish(store: ref[RegistryStore], path: str, target_upstream: bool) -> Result[RegistryResult, string.String]:
    var loaded: manifest.PackageManifest
    match manifest.load(path):
        Result.failure as manifest_failure:
            return result_failure(manifest_failure.error)
        Result.success as manifest_payload:
            loaded = manifest_payload.value
    defer: loaded.release()

    var package_version = string.String.create()
    match loaded.package_version:
        Option.some as version_payload:
            package_version.append(version_payload.value.as_str().trim_ascii_whitespace())
        Option.none:
            pass

    if package_version.len() == 0:
        var message = string.String.from_str("package ")
        message.append(loaded.package_name.as_str())
        message.append(" at ")
        message.append(loaded.manifest_path.as_str())
        message.append(" must declare package.version before publishing")
        package_version.release()
        return result_failure(message)

    var target_root = string.String.create()
    if target_upstream:
        if not upstream_configured(store):
            package_version.release()
            target_root.release()
            return result_failure(string.String.from_str("registry upstream is not configured"))
        if upstream_http(store):
            package_version.release()
            target_root.release()
            return result_failure(
                string.String.from_str(
                    "publishing directly to an HTTP registry upstream is not supported; publish to a filesystem mirror instead"
                )
            )
        target_root.append(upstream_view(store))
    else:
        target_root.append(read(store).root.as_str())

    var package_root: string.String
    match package_root_for_root(target_root.as_str(), loaded.package_name.as_str(), package_version.as_str()):
        Result.failure as root_failure:
            package_version.release()
            target_root.release()
            return result_failure(root_failure.error)
        Result.success as root_payload:
            package_root = root_payload.value

    if fs.exists(package_root.as_str()):
        var message = string.String.from_str("package ")
        message.append(loaded.package_name.as_str())
        message.append(" version ")
        message.append(package_version.as_str())
        message.append(" already published in registry: ")
        message.append(package_root.as_str())
        package_version.release()
        target_root.release()
        package_root.release()
        return result_failure(message)

    match materialize_copy(loaded.root_dir.as_str(), package_root.as_str()):
        Result.failure as copy_failure:
            package_version.release()
            target_root.release()
            package_root.release()
            return result_failure(copy_failure.error)
        Result.success:
            pass

    match write_artifacts_with_rollback(target_root.as_str(), loaded.package_name.as_str(), package_version.as_str(), package_root.as_str()):
        Result.failure as write_failure:
            var message = string.String.from_str("failed to publish package to ")
            message.append(target_root.as_str())
            message.append(": ")
            message.append(write_failure.error.as_str())
            var owned_error = write_failure.error
            owned_error.release()
            package_version.release()
            target_root.release()
            package_root.release()
            return result_failure(message)
        Result.success:
            pass

    var result = RegistryResult(
        package_name = string.String.from_str(loaded.package_name.as_str()),
        version = package_version,
        path = package_root,
    )
    target_root.release()
    return Result[RegistryResult, string.String].success(value = result)


public function sync(store: ref[RegistryStore], package_name: str, package_version: str) -> Result[RegistryResult, string.String]:
    if not upstream_configured(store):
        return result_failure(string.String.from_str("registry upstream is not configured"))

    var local_root: string.String
    match package_root_for(store, package_name, package_version):
        Result.failure as root_failure:
            return result_failure(root_failure.error)
        Result.success as root_payload:
            local_root = root_payload.value

    if published(store, package_name, package_version):
        return Result[RegistryResult, string.String].success(
            value = RegistryResult(
                package_name = string.String.from_str(package_name),
                version = string.String.from_str(package_version),
                path = local_root,
            )
        )

    if upstream_http(store):
        match sync_from_http(store, package_name, package_version, local_root.as_str()):
            Result.failure as http_failure:
                local_root.release()
                return result_failure(http_failure.error)
            Result.success:
                pass
    else:
        let upstream_root = upstream_view(store)
        match package_root_for_root(upstream_root, package_name, package_version):
            Result.failure as upstream_failure:
                local_root.release()
                return result_failure(upstream_failure.error)
            Result.success as upstream_package_payload:
                var upstream_package_root = upstream_package_payload.value
                defer: upstream_package_root.release()
                var upstream_manifest_path = path_ops.join(upstream_package_root.as_str(), "package.toml")
                defer: upstream_manifest_path.release()
                if not fs.is_file(upstream_manifest_path.as_str()):
                    var message = string.String.from_str("registry package ")
                    message.append(package_name)
                    message.append(" version ")
                    message.append(package_version)
                    message.append(" not found in upstream registry ")
                    message.append(upstream_root)
                    local_root.release()
                    return result_failure(message)

                var upstream_manifest: manifest.PackageManifest
                match manifest.load(upstream_package_root.as_str()):
                    Result.failure as manifest_failure:
                        local_root.release()
                        return result_failure(manifest_failure.error)
                    Result.success as manifest_payload:
                        upstream_manifest = manifest_payload.value
                defer: upstream_manifest.release()

                if not upstream_manifest.package_name.as_str().equal(package_name) or not optional_text_equal(upstream_manifest.package_version, package_version):
                    var message = string.String.from_str("upstream registry package at ")
                    message.append(upstream_manifest.manifest_path.as_str())
                    message.append(" resolved to ")
                    message.append(upstream_manifest.package_name.as_str())
                    message.append("@")
                    match upstream_manifest.package_version:
                        Option.some as declared_version:
                            message.append("\"")
                            message.append(declared_version.value.as_str())
                            message.append("\"")
                        Option.none:
                            message.append("nil")
                    message.append("; expected ")
                    message.append(package_name)
                    message.append("@")
                    message.append(package_version)
                    local_root.release()
                    return result_failure(message)

                match materialize_copy(upstream_package_root.as_str(), local_root.as_str()):
                    Result.failure as copy_failure:
                        local_root.release()
                        return result_failure(copy_failure.error)
                    Result.success:
                        pass

    match write_artifacts_with_rollback(read(store).root.as_str(), package_name, package_version, local_root.as_str()):
        Result.failure as artifact_failure:
            var message = string.String.from_str("failed to sync package from upstream registry ")
            message.append(upstream_view(store))
            message.append(": ")
            message.append(artifact_failure.error.as_str())
            var owned_error = artifact_failure.error
            owned_error.release()
            local_root.release()
            return result_failure(message)
        Result.success:
            pass

    return Result[RegistryResult, string.String].success(
        value = RegistryResult(
            package_name = string.String.from_str(package_name),
            version = string.String.from_str(package_version),
            path = local_root,
        )
    )


function optional_text_equal(value: Option[string.String], expected: str) -> bool:
    match value:
        Option.some as payload:
            return payload.value.as_str().equal(expected)
        Option.none:
            return false
    return false


function sync_from_http(
    store: ref[RegistryStore],
    package_name: str,
    package_version: str,
    local_root: str,
) -> Result[bool, string.String]:
    var url = package_archive_url(store, package_name, package_version)
    defer: url.release()
    match http_get(url.as_str()):
        Result.failure as fetch_failure:
            return Result[bool, string.String].failure(error = fetch_failure.error)
        Result.success as response_payload:
            var response = response_payload.value
            defer: response.release()
            if response.status == 404:
                var message = string.String.from_str("registry package ")
                message.append(package_name)
                message.append(" version ")
                message.append(package_version)
                message.append(" not found in upstream registry ")
                message.append(upstream_view(store))
                return Result[bool, string.String].failure(error = message)
            if response.status < 200 or response.status >= 300:
                var message = string.String.from_str("failed to download registry package archive from upstream registry ")
                message.append(upstream_view(store))
                message.append(": HTTP ")
                var code_text = string.String.create()
                defer: code_text.release()
                var number = response.status
                if number == 0:
                    code_text.push_byte('0')
                else:
                    var digits: array[ubyte, 12]
                    var count: ptr_uint = 0
                    while number > 0:
                        digits[count] = ubyte<-(number % 10) + 48
                        number = number / 10
                        count += 1
                    while count > 0:
                        count -= 1
                        code_text.push_byte(digits[count])
                message.append(code_text.as_str())
                message.append(" ")
                message.append(response.reason.as_str())
                return Result[bool, string.String].failure(error = message)

            if fs.exists(local_root):
                match fs.remove_tree(local_root):
                    Result.failure as remove_failure:
                        var remove_error = remove_failure.error
                        var message = string.String.from_str(remove_error.message.as_str())
                        remove_error.release()
                        return Result[bool, string.String].failure(error = message)
                    Result.success:
                        pass
            match fs.create_directories(path_ops.dirname(local_root)):
                Result.failure as dir_failure:
                    var dir_error = dir_failure.error
                    var message = string.String.from_str(dir_error.message.as_str())
                    dir_error.release()
                    return Result[bool, string.String].failure(error = message)
                Result.success:
                    pass

            var staging = string.String.from_str(local_root)
            staging.append(".tmp")
            defer: staging.release()
            if fs.exists(staging.as_str()):
                match fs.remove_tree(staging.as_str()):
                    Result.failure:
                        pass
                    Result.success:
                        pass
            match tar.extract_gzip(response.body.as_span(), staging.as_str()):
                Result.failure as extract_failure:
                    var extract_error = extract_failure.error
                    var message = string.String.from_str("registry package archive extraction failed: ")
                    message.append(extract_error.message.as_str())
                    extract_error.release()
                    return Result[bool, string.String].failure(error = message)
                Result.success:
                    pass
            match fs.rename(staging.as_str(), local_root):
                Result.failure as rename_failure:
                    var rename_error = rename_failure.error
                    var message = string.String.from_str(rename_error.message.as_str())
                    rename_error.release()
                    return Result[bool, string.String].failure(error = message)
                Result.success:
                    pass

            return validate_synced_package(local_root, package_name, package_version)


function validate_synced_package(local_root: str, package_name: str, package_version: str) -> Result[bool, string.String]:
    var loaded: manifest.PackageManifest
    match manifest.load(local_root):
        Result.failure as manifest_failure:
            return Result[bool, string.String].failure(error = manifest_failure.error)
        Result.success as manifest_payload:
            loaded = manifest_payload.value
    defer: loaded.release()
    if not loaded.package_name.as_str().equal(package_name) or not optional_text_equal(loaded.package_version, package_version):
        var message = string.String.from_str("upstream registry package at ")
        message.append(loaded.manifest_path.as_str())
        message.append(" resolved to ")
        message.append(loaded.package_name.as_str())
        message.append("@")
        match loaded.package_version:
            Option.some as declared_version:
                message.append("\"")
                message.append(declared_version.value.as_str())
                message.append("\"")
            Option.none:
                message.append("nil")
        message.append("; expected ")
        message.append(package_name)
        message.append("@")
        message.append(package_version)
        return Result[bool, string.String].failure(error = message)
    return Result[bool, string.String].success(value = true)


function materialize_copy(source_root: str, destination_root: str) -> Result[bool, string.String]:
    var staging = string.String.from_str(destination_root)
    staging.append(".tmp")
    defer: staging.release()
    if fs.exists(staging.as_str()):
        match fs.remove_tree(staging.as_str()):
            Result.failure:
                pass
            Result.success:
                pass
    match fs.create_directories(path_ops.dirname(destination_root)):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            var message = string.String.from_str(dir_error.message.as_str())
            dir_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass
    match fs.copy_entry(source_root, staging.as_str()):
        Result.failure as copy_failure:
            var copy_error = copy_failure.error
            var message = string.String.from_str(copy_error.message.as_str())
            copy_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass
    match fs.rename(staging.as_str(), destination_root):
        Result.failure as rename_failure:
            var rename_error = rename_failure.error
            var message = string.String.from_str(rename_error.message.as_str())
            rename_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass
    return Result[bool, string.String].success(value = true)


# =============================================================================
#  Registry artifacts
# =============================================================================

function write_artifacts_with_rollback(
    root: str,
    package_name: str,
    package_version: str,
    package_root: str,
) -> Result[bool, string.String]:
    match write_artifacts(root, package_name, package_version, package_root):
        Result.failure as failure_payload:
            var archive_path = archive_path_for_root(root, package_name, package_version)
            match archive_path:
                Result.success as path_payload:
                    var path = path_payload.value
                    if fs.is_file(path.as_str()):
                        let _ = fs.remove(path.as_str())
                    path.release()
                Result.failure as path_failure:
                    var message = path_failure.error
                    message.release()
            if fs.exists(package_root):
                let _ = fs.remove_tree(package_root)
            return Result[bool, string.String].failure(error = failure_payload.error)
        Result.success as success_payload:
            return Result[bool, string.String].success(value = success_payload.value)
    return Result[bool, string.String].failure(error = string.String.from_str("registry artifact write failed"))


function write_artifacts(root: str, package_name: str, package_version: str, package_root: str) -> Result[bool, string.String]:
    var archive_path: string.String
    match archive_path_for_root(root, package_name, package_version):
        Result.failure as archive_failure:
            return Result[bool, string.String].failure(error = archive_failure.error)
        Result.success as archive_payload:
            archive_path = archive_payload.value
    defer: archive_path.release()

    match tar.archive_directory_gzip(package_root, "", false):
        Result.failure as tar_failure:
            var tar_error = tar_failure.error
            var message = string.String.from_str(tar_error.message.as_str())
            tar_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success as archive_payload:
            var archive = archive_payload.value
            defer: archive.release()
            match fs.create_directories(path_ops.dirname(archive_path.as_str())):
                Result.failure as dir_failure:
                    var dir_error = dir_failure.error
                    var message = string.String.from_str(dir_error.message.as_str())
                    dir_error.release()
                    return Result[bool, string.String].failure(error = message)
                Result.success:
                    pass
            match fs.write_bytes(archive_path.as_str(), archive.as_span()):
                Result.failure as write_failure:
                    var write_error = write_failure.error
                    var message = string.String.from_str(write_error.message.as_str())
                    write_error.release()
                    return Result[bool, string.String].failure(error = message)
                Result.success:
                    pass

    return write_versions_index(root, package_name)


function archive_path_for_root(root: str, package_name: str, package_version: str) -> Result[string.String, string.String]:
    match normalize_component(package_name, "package name"):
        Result.failure as name_failure:
            return Result[string.String, string.String].failure(error = name_failure.error)
        Result.success as name_payload:
            var name = name_payload.value
            defer: name.release()
            match normalize_component(package_version, "package version"):
                Result.failure as version_failure:
                    return Result[string.String, string.String].failure(error = version_failure.error)
                Result.success as version_payload:
                    var version_text = version_payload.value
                    defer: version_text.release()
                    var base = path_ops.join(root, "packages")
                    defer: base.release()
                    var package_dir = path_ops.join(base.as_str(), name.as_str())
                    defer: package_dir.release()
                    var file_name = string.String.create()
                    file_name.append(version_text.as_str())
                    file_name.append(".tar.gz")
                    return Result[string.String, string.String].success(
                        value = path_ops.join(package_dir.as_str(), file_name.as_str())
                    )
    return Result[string.String, string.String].failure(error = string.String.from_str("invalid package archive path"))


function versions_index_path(root: str, package_name: str) -> Result[string.String, string.String]:
    match normalize_component(package_name, "package name"):
        Result.failure as name_failure:
            return Result[string.String, string.String].failure(error = name_failure.error)
        Result.success as name_payload:
            var name = name_payload.value
            defer: name.release()
            var base = path_ops.join(root, "packages")
            defer: base.release()
            var package_dir = path_ops.join(base.as_str(), name.as_str())
            defer: package_dir.release()
            return Result[string.String, string.String].success(
                value = path_ops.join(package_dir.as_str(), "versions.txt")
            )
    return Result[string.String, string.String].failure(error = string.String.from_str("invalid versions index path"))


function write_versions_index(root: str, package_name: str) -> Result[bool, string.String]:
    var index_path: string.String
    match versions_index_path(root, package_name):
        Result.failure as path_failure:
            return Result[bool, string.String].failure(error = path_failure.error)
        Result.success as path_payload:
            index_path = path_payload.value
    defer: index_path.release()

    var versions: vec.Vec[string.String]
    match package_versions_for_root(root, package_name):
        Result.failure as versions_failure:
            return Result[bool, string.String].failure(error = versions_failure.error)
        Result.success as versions_payload:
            versions = versions_payload.value
    defer: release_versions(ref_of(versions))

    var content = string.String.create()
    defer: content.release()
    var i: ptr_uint = 0
    while i < versions.len():
        if i > 0:
            content.push_byte('\n')
        let value = versions.get(i) else:
            break
        content.append(unsafe: read(value).as_str())
        i += 1
    if versions.len() > 0:
        content.push_byte('\n')

    match fs.create_directories(path_ops.dirname(index_path.as_str())):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            var message = string.String.from_str(dir_error.message.as_str())
            dir_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass
    match fs.write_text(index_path.as_str(), content.as_str()):
        Result.failure as write_failure:
            var write_error = write_failure.error
            var message = string.String.from_str(write_error.message.as_str())
            write_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass
    return Result[bool, string.String].success(value = true)


# =============================================================================
#  HTTP upstream
# =============================================================================

function percent_encode(value: str) -> string.String:
    var encoded = string.String.create()
    var i: ptr_uint = 0
    while i < value.len:
        let byte_value = value.byte_at(i)
        if alphanumeric(byte_value) or byte_value == 45 or byte_value == 95 or byte_value == 46 or byte_value == 126:
            encoded.push_byte(byte_value)
        else:
            encoded.push_byte('%')
            encoded.push_byte(hex_digit(byte_value / 16))
            encoded.push_byte(hex_digit(byte_value % 16))
        i += 1
    return encoded


function alphanumeric(value: ubyte) -> bool:
    return (value >= 48 and value <= 57) or (value >= 65 and value <= 90) or (value >= 97 and value <= 122)


function hex_digit(value: ubyte) -> ubyte:
    if value < 10:
        return value + 48
    return value + 55


function join_upstream_url(store: ref[RegistryStore], first: str, second: str, third: str) -> string.String:
    let base = upstream_view(store)
    var encoded_one = percent_encode(first)
    defer: encoded_one.release()
    var encoded_two = percent_encode(second)
    defer: encoded_two.release()
    var encoded_three = percent_encode(third)
    defer: encoded_three.release()
    var url = string.String.create()
    url.append(trim_trailing_slashes(base))
    url.push_byte('/')
    url.append(encoded_one.as_str())
    url.push_byte('/')
    url.append(encoded_two.as_str())
    url.push_byte('/')
    url.append(encoded_three.as_str())
    return url


function package_versions_url(store: ref[RegistryStore], package_name: str) -> string.String:
    return join_upstream_url(store, "packages", package_name, "versions.txt")


function package_archive_url(store: ref[RegistryStore], package_name: str, package_version: str) -> string.String:
    var file_name = string.String.create()
    file_name.append(package_version)
    file_name.append(".tar.gz")
    var url = join_upstream_url(store, "packages", package_name, file_name.as_str())
    file_name.release()
    return url


function package_versions_for_http(store: ref[RegistryStore], package_name: str) -> Result[VersionList, string.String]:
    var url = package_versions_url(store, package_name)
    defer: url.release()
    match http_get(url.as_str()):
        Result.failure as fetch_failure:
            return Result[VersionList, string.String].failure(error = fetch_failure.error)
        Result.success as response_payload:
            var response = response_payload.value
            defer: response.release()
            var versions = vec.Vec[string.String].create()
            if response.status == 404:
                return Result[VersionList, string.String].success(value = versions)
            if response.status < 200 or response.status >= 300:
                var message = string.String.from_str("failed to list registry package versions from upstream registry ")
                message.append(upstream_view(store))
                message.append(": HTTP ")
                var code_text = int_to_string(response.status)
                defer: code_text.release()
                message.append(code_text.as_str())
                message.append(" ")
                message.append(response.reason.as_str())
                return Result[VersionList, string.String].failure(error = message)

            match response.body.as_str():
                Option.none:
                    return Result[VersionList, string.String].success(value = versions)
                Option.some as body_text:
                    var start: ptr_uint = 0
                    var i: ptr_uint = 0
                    while i <= body_text.value.len:
                        if i == body_text.value.len or body_text.value.byte_at(i) == 10:
                            var line = body_text.value.slice(start, i - start).trim_ascii_whitespace()
                            if line.len > 0:
                                versions.push(string.String.from_str(line))
                            start = i + 1
                        i += 1
            return Result[VersionList, string.String].success(value = versions)


function int_to_string(value: int) -> string.String:
    var result = string.String.create()
    var number = value
    if number < 0:
        result.push_byte('-')
        number = -number
    if number == 0:
        result.push_byte('0')
        return result
    var digits: array[ubyte, 20]
    var count: ptr_uint = 0
    while number > 0:
        digits[count] = ubyte<-(number % 10) + 48
        number = number / 10
        count += 1
    while count > 0:
        count -= 1
        result.push_byte(digits[count])
    return result


## GET with the host's five-redirect limit; returns the final response.
public function http_get(url: str) -> Result[HttpResponse, string.String]:
    var current = string.String.from_str(url)
    defer: current.release()
    var redirects: ptr_uint = 0
    while true:
        var outcome = aio.with_runtime[HttpOutcome](
            proc(runtime: aio.Runtime) -> HttpOutcome: do_http_get(runtime, current.as_str())
        )
        if not outcome.ok:
            var message = string.String.from_str("failed to fetch ")
            message.append(current.as_str())
            message.append(": ")
            message.append(outcome.message.as_str())
            outcome.message.release()
            outcome.reason.release()
            outcome.body.release()
            outcome.location.release()
            return Result[HttpResponse, string.String].failure(error = message)

        if outcome.status >= 300 and outcome.status < 400:
            if redirects >= 5:
                var message = string.String.from_str("too many HTTP redirects while fetching ")
                message.append(current.as_str())
                outcome.message.release()
                outcome.reason.release()
                outcome.body.release()
                outcome.location.release()
                return Result[HttpResponse, string.String].failure(error = message)
            if outcome.location.len() == 0:
                var message = string.String.from_str("missing redirect location while fetching ")
                message.append(current.as_str())
                outcome.message.release()
                outcome.reason.release()
                outcome.body.release()
                outcome.location.release()
                return Result[HttpResponse, string.String].failure(error = message)
            var joined = resolve_url(current.as_str(), outcome.location.as_str())
            outcome.message.release()
            outcome.reason.release()
            outcome.body.release()
            outcome.location.release()
            current.release()
            current = joined
            redirects += 1
            continue

        var response = HttpResponse(
            status = outcome.status,
            reason = outcome.reason,
            body = outcome.body,
            location = outcome.location,
        )
        outcome.message.release()
        return Result[HttpResponse, string.String].success(value = response)

    return Result[HttpResponse, string.String].failure(error = string.String.from_str("unreachable http state"))


function do_http_get(runtime: aio.Runtime, url: str) -> HttpOutcome:
    let fetched = aio.wait_on(runtime, http.get(url))
    match fetched:
        Result.failure as failure_payload:
            var error = failure_payload.error
            var message = string.String.from_str(error.message.as_str())
            error.release()
            return HttpOutcome(
                ok = false,
                status = 0,
                reason = string.String.create(),
                body = bytes.Bytes.empty(),
                location = string.String.create(),
                message = message,
            )
        Result.success as response_payload:
            var response = response_payload.value
            var location = string.String.create()
            match response.header("location"):
                Option.some as declared:
                    location.append(declared.value)
                Option.none:
                    pass
            var outcome = HttpOutcome(
                ok = true,
                status = response.status_code,
                reason = string.String.from_str(response.reason.as_str()),
                body = bytes.Bytes.copy(response.body.as_span()),
                location = location,
                message = string.String.create(),
            )
            response.release()
            return outcome


function resolve_url(base: str, location: str) -> string.String:
    if http_url(location):
        return string.String.from_str(location)
    var scheme_end = find_substring(base, "://")
    if scheme_end.is_none():
        return string.String.from_str(location)
    let scheme_end_index = scheme_end.unwrap()
    if location.len > 0 and location.byte_at(0) == 47:
        var authority_end = base.len
        var i = scheme_end_index + 3
        while i < base.len:
            if base.byte_at(i) == 47:
                authority_end = i
                break
            i += 1
        var result = string.String.create()
        result.append(base.slice(0, authority_end))
        result.append(location)
        return result
    var last_slash: ptr_uint = 0
    var j: ptr_uint = 0
    while j < base.len:
        if base.byte_at(j) == 47:
            last_slash = j
        j += 1
    var result = string.String.create()
    result.append(base.slice(0, last_slash + 1))
    result.append(location)
    return result


function find_substring(text: str, needle: str) -> Option[ptr_uint]:
    if needle.len == 0 or text.len < needle.len:
        return Option[ptr_uint].none
    var i: ptr_uint = 0
    while i + needle.len <= text.len:
        if text.slice(i, needle.len).equal(needle):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none
