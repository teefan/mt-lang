## Package source identities, the shared source cache, dependency resolution
## modes, and git/registry materialization — the self-host port of
## `source_resolver.rb`, `source_cache.rb` and `source_fetcher.rb`.

import std.crypto as crypto
import std.env as env
import std.fs as fs
import std.path as path_ops
import std.process as process
import std.str as text_ops
import std.string as string
import std.vec as vec

import mtc.packages.manifest as manifest
import mtc.packages.paths as paths
import mtc.packages.registry as registry

public enum ResolutionMode: ubyte
    reject = 0
    cache = 1
    materialize = 2

public enum SourceKind: ubyte
    path_ = 0
    registry_ = 1
    git_ = 2

public struct SourceIdentity:
    kind: SourceKind
    path: string.String
    registry_package: string.String
    registry_version: string.String
    git_url: string.String
    git_rev: string.String
    git_subdir: Option[string.String]

public struct LockAttribute:
    key: string.String
    value: string.String

public struct Source:
    identity: SourceIdentity
    local_root: string.String

public struct ResolvedVersion:
    ## The canonical parent-source/dependency key, and the package name used
    ## for the host's name-only fallback lookup.
    key: string.String
    package_name: string.String
    version: string.String

public struct SourceResolver:
    cache_root: string.String
    mode: ResolutionMode
    resolved_versions: vec.Vec[ResolvedVersion]

public struct ResolvedPackage:
    manifest: manifest.PackageManifest
    source: Source

public struct FetchResult:
    package_name: string.String
    identity: SourceIdentity
    present: bool
    path: string.String


extending LockAttribute:
    public editable function release() -> void:
        this.key.release()
        this.value.release()


extending SourceIdentity:
    public function kind_name() -> str:
        match this.kind:
            SourceKind.path_:
                return "path"
            SourceKind.registry_:
                return "registry"
            SourceKind.git_:
                return "git"
        return "path"


    public function cache_key() -> Option[string.String]:
        match this.kind:
            SourceKind.registry_:
                var key = string.String.create()
                key.append("registry/")
                key.append(this.registry_package.as_str())
                key.push_byte('@')
                key.append(this.registry_version.as_str())
                return Option[string.String].some(value = key)
            SourceKind.git_:
                var material = string.String.create()
                material.append(this.git_url.as_str())
                material.push_byte(0)
                material.append(this.git_rev.as_str())
                material.push_byte(0)
                match this.git_subdir:
                    Option.some as subdir:
                        material.append(subdir.value.as_str())
                    Option.none:
                        pass
                var digest = crypto.sha256_to_str(text_ops.as_byte_span(material.as_str()))
                material.release()
                var key = string.String.create()
                key.append("git/")
                key.append(digest.as_str())
                digest.release()
                return Option[string.String].some(value = key)
            SourceKind.path_:
                return Option[string.String].none
        return Option[string.String].none


    public function cacheable() -> bool:
        return not this.cache_key().is_none()


    public editable function release() -> void:
        this.path.release()
        this.registry_package.release()
        this.registry_version.release()
        this.git_url.release()
        this.git_rev.release()
        match this.git_subdir:
            Option.some as payload:
                var owned = payload.value
                owned.release()
            Option.none:
                pass


extending Source:
    public function kind_name() -> str:
        return this.identity.kind_name()


    public editable function release() -> void:
        this.identity.release()
        this.local_root.release()


extending ResolvedVersion:
    public editable function release() -> void:
        this.key.release()
        this.package_name.release()
        this.version.release()


extending SourceResolver:
    public function supports_dependency_solving() -> bool:
        return this.mode != ResolutionMode.reject


    public editable function release() -> void:
        this.cache_root.release()
        release_resolved_versions(ref_of(this.resolved_versions))


extending ResolvedPackage:
    public editable function release() -> void:
        this.manifest.release()
        this.source.release()


extending FetchResult:
    public editable function release() -> void:
        this.package_name.release()
        this.identity.release()
        this.path.release()


function identity_error(message: string.String) -> Result[SourceIdentity, string.String]:
    return Result[SourceIdentity, string.String].failure(error = message)


function source_error(message: str) -> string.String:
    return string.String.from_str(message)

# =============================================================================
#  Identity construction
# =============================================================================

public function identity_path(path: str) -> Result[SourceIdentity, string.String]:
    return Result[SourceIdentity, string.String].success(
        value = SourceIdentity(
            kind = SourceKind.path_,
            path = paths.absolute_path(path),
            registry_package = string.String.create(),
            registry_version = string.String.create(),
            git_url = string.String.create(),
            git_rev = string.String.create(),
            git_subdir = Option[string.String].none,
        )
    )


public function identity_registry(package_name: str, package_version: str) -> Result[SourceIdentity, string.String]:
    match normalize_required(package_name, "registry package name"):
        Result.failure as name_failure:
            return identity_error(name_failure.error)
        Result.success as name_payload:
            var name = name_payload.value
            match normalize_registry_component(package_version, "registry package version"):
                Result.failure as version_failure:
                    name.release()
                    return identity_error(version_failure.error)
                Result.success as version_payload:
                    var owned_name = string.String.from_str(name.as_str())
                    name.release()
                    return Result[SourceIdentity, string.String].success(
                        value = SourceIdentity(
                            kind = SourceKind.registry_,
                            path = string.String.create(),
                            registry_package = owned_name,
                            registry_version = version_payload.value,
                            git_url = string.String.create(),
                            git_rev = string.String.create(),
                            git_subdir = Option[string.String].none,
                        )
                    )
    return identity_error(source_error("invalid registry identity"))


public function identity_git(url: str, revision: str, subdir_raw: Option[str]) -> Result[SourceIdentity, string.String]:
    match normalize_required(url, "git source url"):
        Result.failure as url_failure:
            return identity_error(url_failure.error)
        Result.success as url_payload:
            var owned_url = url_payload.value
            defer: owned_url.release()
            match normalize_required(revision, "git source revision"):
                Result.failure as revision_failure:
                    return identity_error(revision_failure.error)
                Result.success as revision_payload:
                    var owned_revision = revision_payload.value
                    defer: owned_revision.release()
                    var subdir: Option[string.String] = Option[string.String].none
                    match subdir_raw:
                        Option.some as raw:
                            match normalize_git_subdir(raw.value):
                                Result.failure as subdir_failure:
                                    return identity_error(subdir_failure.error)
                                Result.success as subdir_payload:
                                    subdir = subdir_payload.value
                        Option.none:
                            pass
                    return Result[SourceIdentity, string.String].success(
                        value = SourceIdentity(
                            kind = SourceKind.git_,
                            path = string.String.create(),
                            registry_package = string.String.create(),
                            registry_version = string.String.create(),
                            git_url = string.String.from_str(owned_url.as_str()),
                            git_rev = string.String.from_str(owned_revision.as_str()),
                            git_subdir = subdir,
                        )
                    )
    return identity_error(source_error("invalid git identity"))


function is_ascii_alpha(value: ubyte) -> bool:
    return (value >= 65 and value <= 90) or (value >= 97 and value <= 122)


function normalize_required(value: str, label: str) -> Result[string.String, string.String]:
    let text = value.trim_ascii_whitespace()
    if text.len == 0:
        var message = string.String.from_str(label)
        message.append(" cannot be empty")
        return Result[string.String, string.String].failure(error = message)
    return Result[string.String, string.String].success(value = string.String.from_str(text))


function normalize_registry_component(value: str, label: str) -> Result[string.String, string.String]:
    match normalize_required(value, label):
        Result.failure as failure_payload:
            return Result[string.String, string.String].failure(error = failure_payload.error)
        Result.success as payload:
            let text = payload.value.as_str()
            var i: ptr_uint = 0
            while i < text.len:
                let byte_value = text.byte_at(i)
                if byte_value == 47 or byte_value == 92:
                    payload.value.release()
                    var message = string.String.from_str(label)
                    message.append(" cannot contain path separators")
                    return Result[string.String, string.String].failure(error = message)
                i += 1
            return Result[string.String, string.String].success(value = payload.value)
    return Result[string.String, string.String].failure(error = source_error("invalid registry component"))


function normalize_git_subdir(value: str) -> Result[Option[string.String], string.String]:
    let text = value.trim_ascii_whitespace()
    if text.len == 0:
        return Result[Option[string.String], string.String].success(value = Option[string.String].none)
    if text.byte_at(0) == 47 or text.byte_at(0) == 92:
        return Result[Option[string.String], string.String].failure(
            error = source_error("git source subdir cannot be absolute")
        )
    if (
        text.len >= 3
        and is_ascii_alpha(text.byte_at(0))
        and text.byte_at(1) == 58
        and (text.byte_at(2) == 92 or text.byte_at(2) == 47)
    ):
        return Result[Option[string.String], string.String].failure(
            error = source_error("git source subdir cannot be absolute")
        )

    var normalized = string.String.create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= text.len:
        if i == text.len or text.byte_at(i) == 47 or text.byte_at(i) == 92:
            if i > start:
                let segment = text.slice(start, i - start)
                if segment.equal(".."):
                    normalized.release()
                    return Result[Option[string.String], string.String].failure(
                        error = source_error("git source subdir cannot escape the repository root")
                    )
                if not segment.equal("."):
                    if normalized.len() > 0:
                        normalized.push_byte('/')
                    normalized.append(segment)
            start = i + 1
        i += 1
    if normalized.len() == 0:
        return Result[Option[string.String], string.String].success(value = Option[string.String].none)
    return Result[Option[string.String], string.String].success(
        value = Option[string.String].some(value = normalized)
    )


public function clone_identity(identity: SourceIdentity) -> SourceIdentity:
    var subdir: Option[string.String] = Option[string.String].none
    match identity.git_subdir:
        Option.some as payload:
            subdir = Option[string.String].some(value = string.String.from_str(payload.value.as_str()))
        Option.none:
            pass
    return SourceIdentity(
        kind = identity.kind,
        path = string.String.from_str(identity.path.as_str()),
        registry_package = string.String.from_str(identity.registry_package.as_str()),
        registry_version = string.String.from_str(identity.registry_version.as_str()),
        git_url = string.String.from_str(identity.git_url.as_str()),
        git_rev = string.String.from_str(identity.git_rev.as_str()),
        git_subdir = subdir,
    )


public function clone_source(source: Source) -> Source:
    return Source(
        identity = clone_identity(source.identity),
        local_root = string.String.from_str(source.local_root.as_str()),
    )

# =============================================================================
#  Lock attributes and source keys
# =============================================================================

public function identity_lock_attributes(identity: SourceIdentity) -> vec.Vec[LockAttribute]:
    var attributes = vec.Vec[LockAttribute].create()
    match identity.kind:
        SourceKind.path_:
            attributes.push(LockAttribute(
                key = string.String.from_str("source_path"),
                value = string.String.from_str(identity.path.as_str()),
            ))
        SourceKind.registry_:
            attributes.push(LockAttribute(
                key = string.String.from_str("registry_package"),
                value = string.String.from_str(identity.registry_package.as_str()),
            ))
            attributes.push(LockAttribute(
                key = string.String.from_str("registry_version"),
                value = string.String.from_str(identity.registry_version.as_str()),
            ))
        SourceKind.git_:
            attributes.push(LockAttribute(
                key = string.String.from_str("git_url"),
                value = string.String.from_str(identity.git_url.as_str()),
            ))
            attributes.push(LockAttribute(
                key = string.String.from_str("git_rev"),
                value = string.String.from_str(identity.git_rev.as_str()),
            ))
            match identity.git_subdir:
                Option.some as payload:
                    attributes.push(LockAttribute(
                        key = string.String.from_str("git_subdir"),
                        value = string.String.from_str(payload.value.as_str()),
                    ))
                Option.none:
                    pass
    return attributes


public function release_lock_attributes(attributes: ref[vec.Vec[LockAttribute]]) -> void:
    var i: ptr_uint = 0
    while i < attributes.len():
        let entry = attributes.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    attributes.release()


public function sort_lock_attributes(attributes: ref[vec.Vec[LockAttribute]]) -> void:
    attributes.sort_by(proc(
        left: ptr[LockAttribute],
        right: ptr[LockAttribute]
    ) -> int: unsafe: read(left).key.as_str().compare(unsafe: read(right).key.as_str()))


public function source_key_for_identity(identity: SourceIdentity) -> Result[string.String, string.String]:
    match identity.kind:
        SourceKind.path_:
            var key = string.String.from_str("path:")
            key.append(identity.path.as_str())
            return Result[string.String, string.String].success(value = key)
        SourceKind.registry_:
            var key = string.String.from_str("registry:")
            match identity.cache_key():
                Option.some as cache_key:
                    key.append(cache_key.value.as_str())
                    cache_key.value.release()
                Option.none:
                    pass
            return Result[string.String, string.String].success(value = key)
        SourceKind.git_:
            var key = string.String.from_str("git:")
            match identity.cache_key():
                Option.some as cache_key:
                    key.append(cache_key.value.as_str())
                    cache_key.value.release()
                Option.none:
                    pass
            return Result[string.String, string.String].success(value = key)
    return Result[string.String, string.String].failure(
        error = source_error("unsupported source identity for registry dependency key")
    )


public function registry_dependency_key(parent_source_key: str, dependency_name: str) -> string.String:
    var key = string.String.from_str(parent_source_key)
    key.push_byte(31)
    key.append(dependency_name)
    return key

# =============================================================================
#  Source cache
# =============================================================================

public function default_cache_root() -> string.String:
    match env.get("XDG_CACHE_HOME"):
        Option.some as xdg:
            let trimmed = xdg.value.trim_ascii_whitespace()
            if trimmed.len > 0:
                var base = paths.absolute_path(trimmed)
                var joined = path_ops.join(base.as_str(), "milk_tea/package_sources")
                base.release()
                return paths.absolute_path(joined.as_str())
        Option.none:
            pass
    match env.home():
        Option.some as home:
            var base = path_ops.join(home.value, ".cache/milk_tea/package_sources")
            var absolute = paths.absolute_path(base.as_str())
            base.release()
            return absolute
        Option.none:
            return string.String.from_str("/tmp/milk_tea/package_sources")
    return string.String.from_str("/tmp/milk_tea/package_sources")


public function cache_path_for(cache_root: str, identity: SourceIdentity) -> Result[string.String, string.String]:
    match identity.cache_key():
        Option.none:
            var message = string.String.from_str("package source kind \"")
            message.append(identity.kind_name())
            message.append("\" does not use the shared source cache")
            return Result[string.String, string.String].failure(error = message)
        Option.some as key_payload:
            var key = key_payload.value
            defer: key.release()
            var result = string.String.from_str(cache_root)
            let segments = key.as_str()
            var start: ptr_uint = 0
            var i: ptr_uint = 0
            while i <= segments.len:
                if i == segments.len or segments.byte_at(i) == 47:
                    if i > start:
                        result.push_byte('/')
                        result.append(segments.slice(start, i - start))
                    start = i + 1
                i += 1
            return Result[string.String, string.String].success(value = result)
    return Result[string.String, string.String].failure(error = source_error("invalid cache key"))


public function cache_materialized_root(
    cache_root: str,
    identity: SourceIdentity
) -> Result[string.String, string.String]:
    var base: string.String
    match cache_path_for(cache_root, identity):
        Result.failure as failure_payload:
            return Result[string.String, string.String].failure(error = failure_payload.error)
        Result.success as path_payload:
            base = path_payload.value

    match identity.git_subdir:
        Option.none:
            return Result[string.String, string.String].success(value = base)
        Option.some as subdir:
            var materialized = string.String.from_str(base.as_str())
            let segments = subdir.value.as_str()
            var start: ptr_uint = 0
            var i: ptr_uint = 0
            while i <= segments.len:
                if i == segments.len or segments.byte_at(i) == 47 or segments.byte_at(i) == 92:
                    if i > start:
                        var segment = segments.slice(start, i - start)
                        if segment.equal(".") or segment.len == 0:
                            pass
                        else:
                            materialized.push_byte('/')
                            materialized.append(segment)
                    start = i + 1
                i += 1
            var expanded = paths.absolute_path(materialized.as_str())
            materialized.release()
            if not expanded.as_str().equal(base.as_str()) and not paths.path_within_root(
                expanded.as_str(),
                base.as_str()
            ):
                var message = string.String.from_str("git source subdir escapes the materialized package root: \"")
                message.append(subdir.value.as_str())
                message.append("\"")
                expanded.release()
                base.release()
                return Result[string.String, string.String].failure(error = message)
            base.release()
            return Result[string.String, string.String].success(value = expanded)
    return Result[string.String, string.String].success(value = base)


public function cache_manifest_path(cache_root: str, identity: SourceIdentity) -> Result[string.String, string.String]:
    match cache_materialized_root(cache_root, identity):
        Result.failure as failure_payload:
            return Result[string.String, string.String].failure(error = failure_payload.error)
        Result.success as root_payload:
            var root = root_payload.value
            defer: root.release()
            return Result[string.String, string.String].success(
                value = path_ops.join(root.as_str(), "package.toml")
            )
    return Result[string.String, string.String].failure(error = source_error("invalid cache path"))


public function cache_materialized(cache_root: str, identity: SourceIdentity) -> bool:
    match cache_manifest_path(cache_root, identity):
        Result.failure as failure_payload:
            var message = failure_payload.error
            message.release()
            return false
        Result.success as path_payload:
            var path = path_payload.value
            defer: path.release()
            return fs.is_file(path.as_str())

# =============================================================================
#  Resolver
# =============================================================================

public function create_resolver(mode: ResolutionMode) -> SourceResolver:
    return SourceResolver(
        cache_root = default_cache_root(),
        mode = mode,
        resolved_versions = vec.Vec[ResolvedVersion].create(),
    )


public function release_strings(values: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < values.len():
        let value = values.get(i) else:
            break
        unsafe: read(value).release()
        i += 1
    values.release()


public function release_resolved_versions(versions: ref[vec.Vec[ResolvedVersion]]) -> void:
    var i: ptr_uint = 0
    while i < versions.len():
        let entry = versions.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    versions.release()


public function clone_resolved_versions(versions: ref[vec.Vec[ResolvedVersion]]) -> vec.Vec[ResolvedVersion]:
    var copy = vec.Vec[ResolvedVersion].create()
    var i: ptr_uint = 0
    while i < versions.len():
        let entry = versions.get(i) else:
            break
        unsafe:
            let value = read(entry)
            copy.push(ResolvedVersion(
                key = string.String.from_str(value.key.as_str()),
                package_name = string.String.from_str(value.package_name.as_str()),
                version = string.String.from_str(value.version.as_str()),
            ))
        i += 1
    return copy


public function with_resolved_versions(
    resolver: ref[SourceResolver],
    versions: ref[vec.Vec[ResolvedVersion]]
) -> SourceResolver:
    return SourceResolver(
        cache_root = string.String.from_str(resolver.cache_root.as_str()),
        mode = resolver.mode,
        resolved_versions = clone_resolved_versions(versions),
    )


public function source_for_manifest(resolver: ref[SourceResolver], package: manifest.PackageManifest) -> Source:
    return Source(
        identity = SourceIdentity(
            kind = SourceKind.path_,
            path = string.String.from_str(package.root_dir.as_str()),
            registry_package = string.String.create(),
            registry_version = string.String.create(),
            git_url = string.String.create(),
            git_rev = string.String.create(),
            git_subdir = Option[string.String].none,
        ),
        local_root = string.String.from_str(package.root_dir.as_str()),
    )


public function resolve(
    resolver: ref[SourceResolver],
    dependency: manifest.PackageDependency,
    parent_manifest: ref[manifest.PackageManifest],
    parent_source: ref[Source],
) -> Result[ResolvedPackage, string.String]:
    if dependency.path.is_some():
        var dependency_path = dependency.path.unwrap()
        # Borrowed from the manifest: never release the unwrapped copy.
        var loaded: manifest.PackageManifest
        match manifest.load(dependency_path.as_str()):
            Result.failure as manifest_failure:
                return Result[ResolvedPackage, string.String].failure(error = manifest_failure.error)
            Result.success as manifest_payload:
                loaded = manifest_payload.value
        match validate_fixed_version_requirement(dependency, ref_of(loaded), parent_manifest):
            Result.failure as version_failure:
                loaded.release()
                return Result[ResolvedPackage, string.String].failure(error = version_failure.error)
            Result.success:
                pass
        return Result[ResolvedPackage, string.String].success(
            value = ResolvedPackage(
                manifest = loaded,
                source = source_for_manifest(resolver, loaded),
            )
        )

    if dependency.registry():
        return resolve_registry_dependency(resolver, dependency, parent_manifest, parent_source)
    if dependency.git_dependency():
        match dependency.git:
            Option.some as git_holder:
                match dependency.git_rev:
                    Option.some as revision_holder:
                        var subdir: Option[str] = Option[str].none
                        match dependency.git_subdir:
                            Option.some as declared:
                                subdir = Option[str].some(value = declared.value.as_str())
                            Option.none:
                                pass
                        match identity_git(git_holder.value.as_str(), revision_holder.value.as_str(), subdir):
                            Result.failure as identity_failure:
                                return Result[ResolvedPackage, string.String].failure(error = identity_failure.error)
                            Result.success as identity_payload:
                                return resolve_cache_backed(
                                    resolver,
                                    identity_payload.value,
                                    dependency,
                                    parent_manifest
                                )
                    Option.none:
                        pass
            Option.none:
                pass
        return Result[ResolvedPackage, string.String].failure(error = source_error("invalid git dependency"))

    var message = string.String.from_str("dependency ")
    message.append(dependency.name.as_str())
    message.append(" in ")
    message.append(parent_manifest.manifest_path.as_str())
    message.append(" has no supported source resolver")
    return Result[ResolvedPackage, string.String].failure(error = message)


function resolve_registry_dependency(
    resolver: ref[SourceResolver],
    dependency: manifest.PackageDependency,
    parent_manifest: ref[manifest.PackageManifest],
    parent_source: ref[Source],
) -> Result[ResolvedPackage, string.String]:
    if dependency.exact_registry_version():
        let version_text = dependency.version.unwrap()

        match identity_registry(dependency.name.as_str(), version_text.as_str()):
            Result.failure as identity_failure:
                return Result[ResolvedPackage, string.String].failure(error = identity_failure.error)
            Result.success as identity_payload:
                return resolve_cache_backed(resolver, identity_payload.value, dependency, parent_manifest)

    match source_key_for_identity(parent_source.identity):
        Result.failure as key_failure:
            return Result[ResolvedPackage, string.String].failure(error = key_failure.error)
        Result.success as key_payload:
            var parent_key = key_payload.value
            defer: parent_key.release()
            var dependency_key = registry_dependency_key(parent_key.as_str(), dependency.name.as_str())
            defer: dependency_key.release()
            var resolved_version: Option[string.String] = Option[string.String].none
            var i: ptr_uint = 0
            while i < resolver.resolved_versions.len():
                let entry = resolver.resolved_versions.get(i) else:
                    break
                unsafe:
                    let value = read(entry)
                    if (
                        value.key.as_str().equal(dependency_key.as_str())
                        or value.package_name.as_str().equal(dependency.name.as_str())
                    ):
                        if value.key.as_str().equal(dependency_key.as_str()):
                            resolved_version = Option[string.String].some(value = string.String.from_str(value.version.as_str()))
                            break
                        if resolved_version.is_none():
                            resolved_version = Option[string.String].some(value = string.String.from_str(value.version.as_str()))
                i += 1

            match resolved_version:
                Option.some as version_payload:
                    var version_text = version_payload.value

                    match dependency.version_req:
                        Option.some as req:
                            match req.value.matches_text(version_text.as_str()):
                                Result.failure as matches_failure:
                                    return Result[ResolvedPackage, string.String].failure(error = matches_failure.error)
                                Result.success as matches_payload:
                                    if not matches_payload.value:
                                        var message = string.String.from_str("dependency ")
                                        message.append(dependency.name.as_str())
                                        message.append(" in ")
                                        message.append(parent_manifest.manifest_path.as_str())
                                        message.append(" resolved version \"")
                                        message.append(version_text.as_str())
                                        message.append("\", which does not satisfy ")
                                        var req_text = req.value.to_string()
                                        message.append(req_text.as_str())
                                        req_text.release()
                                        return Result[ResolvedPackage, string.String].failure(error = message)
                        Option.none:
                            pass
                    match identity_registry(dependency.name.as_str(), version_text.as_str()):
                        Result.failure as identity_failure:
                            return Result[ResolvedPackage, string.String].failure(error = identity_failure.error)
                        Result.success as identity_payload:
                            return resolve_cache_backed(resolver, identity_payload.value, dependency, parent_manifest)
                Option.none:
                    pass

            var message = string.String.from_str("dependency ")
            message.append(dependency.name.as_str())
            message.append(" in ")
            message.append(parent_manifest.manifest_path.as_str())
            message.append(" uses version requirement ")
            match dependency.version_req:
                Option.some as req:
                    var req_text = req.value.to_string()
                    message.append(req_text.as_str())
                    req_text.release()
                Option.none:
                    message.append("?")
            message.append(
                ", but registry dependency solving is not implemented yet; use an exact version for now"
            )
            return Result[ResolvedPackage, string.String].failure(error = message)
    return Result[ResolvedPackage, string.String].failure(error = source_error("invalid registry dependency"))


function validate_fixed_version_requirement(
    dependency: manifest.PackageDependency,
    package: ref[manifest.PackageManifest],
    parent_manifest: ref[manifest.PackageManifest],
) -> Result[bool, string.String]:
    match dependency.version_req:
        Option.none:
            return Result[bool, string.String].success(value = true)
        Option.some as req:
            match package.package_version:
                Option.none:
                    var message = string.String.from_str("dependency ")
                    message.append(dependency.name.as_str())
                    message.append(" in ")
                    message.append(parent_manifest.manifest_path.as_str())
                    message.append(" requires version ")
                    var req_text = req.value.to_string()
                    message.append(req_text.as_str())
                    req_text.release()
                    message.append(", but ")
                    message.append(package.manifest_path.as_str())
                    message.append(" does not declare package.version")
                    return Result[bool, string.String].failure(error = message)
                Option.some as version_payload:
                    match req.value.matches_text(version_payload.value.as_str()):
                        Result.failure as matches_failure:
                            return Result[bool, string.String].failure(error = matches_failure.error)
                        Result.success as matches_payload:
                            if matches_payload.value:
                                return Result[bool, string.String].success(value = true)
                            var message = string.String.from_str("dependency ")
                            message.append(dependency.name.as_str())
                            message.append(" in ")
                            message.append(parent_manifest.manifest_path.as_str())
                            message.append(" resolved version \"")
                            message.append(version_payload.value.as_str())
                            message.append("\" at ")
                            message.append(package.manifest_path.as_str())
                            message.append(", which does not satisfy ")
                            var req_text = req.value.to_string()
                            message.append(req_text.as_str())
                            req_text.release()
                            return Result[bool, string.String].failure(error = message)
    return Result[bool, string.String].success(value = true)


function resolve_cache_backed(
    resolver: ref[SourceResolver],
    identity: SourceIdentity,
    dependency: manifest.PackageDependency,
    parent_manifest: ref[manifest.PackageManifest],
) -> Result[ResolvedPackage, string.String]:
    var owned_identity = identity
    defer: owned_identity.release()

    var context_label = string.String.from_str("dependency ")
    context_label.append(dependency.name.as_str())
    context_label.append(" in ")
    context_label.append(parent_manifest.manifest_path.as_str())
    defer: context_label.release()

    var source: Source
    match resolver.mode:
        ResolutionMode.reject:
            var message = string.String.from_str(context_label.as_str())
            message.append(" uses ")
            message.append(owned_identity.kind_name())
            message.append(
                " resolution, but live dependency resolution only supports local path dependencies; run mtc deps lock and then use --locked or --frozen"
            )
            return Result[ResolvedPackage, string.String].failure(error = message)
        ResolutionMode.cache:
            match source_from_identity(resolver, ref_of(owned_identity), context_label.as_str()):
                Result.failure as source_failure:
                    return Result[ResolvedPackage, string.String].failure(error = source_failure.error)
                Result.success as source_payload:
                    source = source_payload.value
        ResolutionMode.materialize:
            match materialize_identity(resolver.cache_root.as_str(), dependency.name.as_str(), ref_of(owned_identity)):
                Result.failure as fetch_failure:
                    return Result[ResolvedPackage, string.String].failure(error = fetch_failure.error)
                Result.success as fetch_payload:
                    var fetched = fetch_payload.value
                    fetched.release()
            match source_from_identity(resolver, ref_of(owned_identity), context_label.as_str()):
                Result.failure as source_failure:
                    return Result[ResolvedPackage, string.String].failure(error = source_failure.error)
                Result.success as source_payload:
                    source = source_payload.value

    var loaded: manifest.PackageManifest
    match manifest.load(source.local_root.as_str()):
        Result.failure as manifest_failure:
            source.release()
            return Result[ResolvedPackage, string.String].failure(error = manifest_failure.error)
        Result.success as manifest_payload:
            loaded = manifest_payload.value

    if not loaded.package_name.as_str().equal(dependency.name.as_str()):
        var message = string.String.from_str(context_label.as_str())
        message.append(" resolved package ")
        message.append(loaded.package_name.as_str())
        message.append(" at ")
        message.append(loaded.manifest_path.as_str())
        loaded.release()
        source.release()
        return Result[ResolvedPackage, string.String].failure(error = message)

    if owned_identity.kind == SourceKind.registry_:
        match loaded.package_version:
            Option.some as version_payload:
                if not version_payload.value.as_str().equal(owned_identity.registry_version.as_str()):
                    var message = string.String.from_str(context_label.as_str())
                    message.append(" resolved version \"")
                    message.append(version_payload.value.as_str())
                    message.append("\" at ")
                    message.append(loaded.manifest_path.as_str())
                    message.append("; expected \"")
                    message.append(owned_identity.registry_version.as_str())
                    message.append("\"")
                    loaded.release()
                    source.release()
                    return Result[ResolvedPackage, string.String].failure(error = message)
            Option.none:
                var message = string.String.from_str(context_label.as_str())
                message.append(" resolved version nil at ")
                message.append(loaded.manifest_path.as_str())
                message.append("; expected \"")
                message.append(owned_identity.registry_version.as_str())
                message.append("\"")
                loaded.release()
                source.release()
                return Result[ResolvedPackage, string.String].failure(error = message)

    return Result[ResolvedPackage, string.String].success(
        value = ResolvedPackage(manifest = loaded, source = source)
    )


public function source_from_identity(
    resolver: ref[SourceResolver],
    identity: ref[SourceIdentity],
    context_label: str,
) -> Result[Source, string.String]:
    let identity_value = read(identity)
    if identity_value.kind == SourceKind.path_:
        return Result[Source, string.String].success(
            value = Source(
                identity = clone_identity(identity_value),
                local_root = string.String.from_str(identity_value.path.as_str()),
            )
        )

    var expected_path: string.String
    match cache_manifest_path(resolver.cache_root.as_str(), identity_value):
        Result.failure as path_failure:
            return Result[Source, string.String].failure(error = path_failure.error)
        Result.success as path_payload:
            expected_path = path_payload.value

    if not fs.is_file(expected_path.as_str()):
        var message = string.String.from_str("package source_kind \"")
        message.append(identity_value.kind_name())
        message.append("\" in ")
        message.append(context_label)
        message.append(" is not materialized in the source cache: expected ")
        message.append(expected_path.as_str())
        expected_path.release()
        return Result[Source, string.String].failure(error = message)
    expected_path.release()

    var local_root: string.String
    match cache_materialized_root(resolver.cache_root.as_str(), identity_value):
        Result.failure as root_failure:
            return Result[Source, string.String].failure(error = root_failure.error)
        Result.success as root_payload:
            local_root = root_payload.value

    return Result[Source, string.String].success(
        value = Source(identity = clone_identity(identity_value), local_root = local_root)
    )

# =============================================================================
#  Fetcher
# =============================================================================

public function materialize_identity(
    cache_root: str,
    package_name: str,
    identity: ref[SourceIdentity],
) -> Result[FetchResult, string.String]:
    let identity_value = read(identity)
    match identity_value.kind:
        SourceKind.registry_:
            return fetch_registry_package(cache_root, package_name, identity_value)
        SourceKind.git_:
            return fetch_git_package(cache_root, package_name, identity_value)
        SourceKind.path_:
            return Result[FetchResult, string.String].failure(
                error = source_error("package source kind \"path\" is not fetchable")
            )
    return Result[FetchResult, string.String].failure(error = source_error("unfetchable package source"))


function fetch_registry_package(
    cache_root: str,
    package_name: str,
    identity: SourceIdentity,
) -> Result[FetchResult, string.String]:
    var cache_root_text = string.String.from_str(cache_root)
    defer: cache_root_text.release()

    var expected_manifest: string.String
    match cache_manifest_path(cache_root_text.as_str(), identity):
        Result.failure as path_failure:
            return Result[FetchResult, string.String].failure(error = path_failure.error)
        Result.success as path_payload:
            expected_manifest = path_payload.value

    var materialized_root: string.String
    match cache_materialized_root(cache_root_text.as_str(), identity):
        Result.failure as root_failure:
            expected_manifest.release()
            return Result[FetchResult, string.String].failure(error = root_failure.error)
        Result.success as root_payload:
            materialized_root = root_payload.value

    if fs.is_file(expected_manifest.as_str()):
        return Result[FetchResult, string.String].success(
            value = FetchResult(
                package_name = string.String.from_str(package_name),
                identity = clone_identity(identity),
                present = true,
                path = materialized_root,
            )
        )

    var cache_root_path: string.String
    match cache_path_for(cache_root_text.as_str(), identity):
        Result.failure as path_failure:
            expected_manifest.release()
            materialized_root.release()
            return Result[FetchResult, string.String].failure(error = path_failure.error)
        Result.success as path_payload:
            cache_root_path = path_payload.value

    var published_root: string.String
    match registry.published_root_default(
        identity.registry_package.as_str(),
        identity.registry_version.as_str(),
        true,
    ):
        Result.failure as publish_failure:
            expected_manifest.release()
            materialized_root.release()
            cache_root_path.release()
            return Result[FetchResult, string.String].failure(error = publish_failure.error)
        Result.success as publish_payload:
            published_root = publish_payload.value

    if fs.exists(cache_root_path.as_str()):
        match fs.remove_tree(cache_root_path.as_str()):
            Result.failure:
                pass
            Result.success:
                pass
    match fs.create_directories(path_ops.dirname(cache_root_path.as_str())):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            var message = string.String.from_str(dir_error.message.as_str())
            dir_error.release()
            expected_manifest.release()
            materialized_root.release()
            cache_root_path.release()
            published_root.release()
            return Result[FetchResult, string.String].failure(error = message)
        Result.success:
            pass
    match fs.copy_entry(published_root.as_str(), cache_root_path.as_str()):
        Result.failure as copy_failure:
            var copy_error = copy_failure.error
            var message = string.String.from_str(copy_error.message.as_str())
            copy_error.release()
            expected_manifest.release()
            materialized_root.release()
            cache_root_path.release()
            published_root.release()
            return Result[FetchResult, string.String].failure(error = message)
        Result.success:
            pass
    published_root.release()
    cache_root_path.release()

    if not fs.is_file(expected_manifest.as_str()):
        var message = string.String.from_str("registry source for ")
        message.append(package_name)
        message.append(" is missing package.toml at ")
        message.append(expected_manifest.as_str())
        expected_manifest.release()
        materialized_root.release()
        return Result[FetchResult, string.String].failure(error = message)
    expected_manifest.release()

    return Result[FetchResult, string.String].success(
        value = FetchResult(
            package_name = string.String.from_str(package_name),
            identity = clone_identity(identity),
            present = false,
            path = materialized_root,
        )
    )


function fetch_git_package(
    cache_root: str,
    package_name: str,
    identity: SourceIdentity,
) -> Result[FetchResult, string.String]:
    var cache_root_text = string.String.from_str(cache_root)
    defer: cache_root_text.release()

    var checkout_root: string.String
    match cache_path_for(cache_root_text.as_str(), identity):
        Result.failure as path_failure:
            return Result[FetchResult, string.String].failure(error = path_failure.error)
        Result.success as path_payload:
            checkout_root = path_payload.value

    var materialized_root: string.String
    match cache_materialized_root(cache_root_text.as_str(), identity):
        Result.failure as root_failure:
            checkout_root.release()
            return Result[FetchResult, string.String].failure(error = root_failure.error)
        Result.success as root_payload:
            materialized_root = root_payload.value

    var expected_manifest: string.String
    match cache_manifest_path(cache_root_text.as_str(), identity):
        Result.failure as manifest_failure:
            checkout_root.release()
            materialized_root.release()
            return Result[FetchResult, string.String].failure(error = manifest_failure.error)
        Result.success as manifest_payload:
            expected_manifest = manifest_payload.value

    if git_checkout_current(
        checkout_root.as_str(),
        identity.git_rev.as_str()
    ) and fs.is_file(expected_manifest.as_str()):
        expected_manifest.release()
        checkout_root.release()
        return Result[FetchResult, string.String].success(
            value = FetchResult(
                package_name = string.String.from_str(package_name),
                identity = clone_identity(identity),
                present = true,
                path = materialized_root,
            )
        )

    if fs.exists(checkout_root.as_str()):
        match fs.remove_tree(checkout_root.as_str()):
            Result.failure:
                pass
            Result.success:
                pass
    match fs.create_directories(path_ops.dirname(checkout_root.as_str())):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            var message = string.String.from_str(dir_error.message.as_str())
            dir_error.release()
            checkout_root.release()
            materialized_root.release()
            expected_manifest.release()
            return Result[FetchResult, string.String].failure(error = message)
        Result.success:
            pass

    var clone_command = vec.Vec[str].create()
    defer: clone_command.release()
    clone_command.push("git")
    clone_command.push("clone")
    clone_command.push(identity.git_url.as_str())
    clone_command.push(checkout_root.as_str())
    match run_git(clone_command.as_span()):
        Result.failure as clone_failure:
            checkout_root.release()
            materialized_root.release()
            expected_manifest.release()
            return Result[FetchResult, string.String].failure(error = clone_failure.error)
        Result.success:
            pass

    var checkout_command = vec.Vec[str].create()
    defer: checkout_command.release()
    checkout_command.push("git")
    checkout_command.push("-C")
    checkout_command.push(checkout_root.as_str())
    checkout_command.push("checkout")
    checkout_command.push("--detach")
    checkout_command.push(identity.git_rev.as_str())
    match run_git(checkout_command.as_span()):
        Result.failure as checkout_failure:
            checkout_root.release()
            materialized_root.release()
            expected_manifest.release()
            return Result[FetchResult, string.String].failure(error = checkout_failure.error)
        Result.success:
            pass

    if not fs.is_file(expected_manifest.as_str()):
        var message = string.String.from_str("git source for ")
        message.append(package_name)
        message.append(" is missing package.toml at ")
        message.append(expected_manifest.as_str())
        checkout_root.release()
        materialized_root.release()
        expected_manifest.release()
        return Result[FetchResult, string.String].failure(error = message)
    expected_manifest.release()
    checkout_root.release()

    return Result[FetchResult, string.String].success(
        value = FetchResult(
            package_name = string.String.from_str(package_name),
            identity = clone_identity(identity),
            present = false,
            path = materialized_root,
        )
    )


function git_checkout_current(checkout_root: str, revision: str) -> bool:
    if not fs.is_directory(checkout_root):
        return false
    var command = vec.Vec[str].create()
    defer: command.release()
    command.push("git")
    command.push("-C")
    command.push(checkout_root)
    command.push("rev-parse")
    command.push("HEAD")
    match process.capture(command.as_span()):
        Result.failure as failure_payload:
            var error = failure_payload.error
            error.release()
            return false
        Result.success as capture_payload:
            var capture = capture_payload.value
            defer: release_capture(ref_of(capture))
            if capture.status.exit_code != 0:
                return false
            let current = capture.stdout.as_str().trim_ascii_whitespace().equal(revision)
            return current
    return false


function release_capture(capture: ref[process.CaptureResult]) -> void:
    capture.stdout.release()
    capture.stderr.release()


function run_git(command: span[str]) -> Result[bool, string.String]:
    match process.capture(command):
        Result.failure as failure_payload:
            var error = failure_payload.error
            var message = string.String.from_str("git not found while materializing package sources: ")
            message.append(error.message.as_str())
            error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success as capture_payload:
            var capture = capture_payload.value
            defer: release_capture(ref_of(capture))
            if capture.status.exit_code == 0:
                return Result[bool, string.String].success(value = true)
            var details = string.String.create()
            if capture.stdout.len() > 0:
                details.append(capture.stdout.as_str())
            if capture.stderr.len() > 0:
                details.append(capture.stderr.as_str())
            if details.len() == 0:
                details.release()
                return Result[bool, string.String].failure(
                    error = source_error("failed to materialize git package source")
                )
            var message = string.String.from_str("failed to materialize git package source:\n")
            message.append(details.as_str())
            details.release()
            return Result[bool, string.String].failure(error = message)
    return Result[bool, string.String].failure(error = source_error("git invocation failed"))
