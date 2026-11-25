## Registry dependency solver — the self-host port of
## `lib/milk_tea/packages/dependency_solver.rb`: a depth-first resolver that
## walks path/git/exact-registry dependencies directly and branches over the
## available versions for ranged registry requirements, honoring locked
## versions and detecting cycles.
##
## Ownership note: solver states are a short-lived search structure.  Every
## mutation happens on a `clone_state` copy (the vector fields are shallow
## copies otherwise), and only the final state is reclaimed — intermediate
## branch states are bounded by the dependency graph and the process exits
## after the command.  This mirrors the compiler's arena-leaked AST storage.

import std.str
import std.string as string
import std.vec as vec

import mtc.packages.manifest as manifest
import mtc.packages.registry as registry
import mtc.packages.source as pkg_source
import mtc.packages.version as version

public struct Solution:
    registry_versions: vec.Vec[pkg_source.ResolvedVersion]

struct SeenManifest:
    path: string.String
    package_name: string.String

struct SelectedVersion:
    key: string.String
    package_name: string.String
    version: string.String

struct SolverState:
    seen: vec.Vec[SeenManifest]
    selected: vec.Vec[SelectedVersion]
    stack: vec.Vec[string.String]

type StateList = vec.Vec[SolverState]
type VersionEntryList = vec.Vec[PackageVersionEntry]

struct PackageVersionEntry:
    text: string.String
    parsed: version.PackageVersion


extending Solution:
    public editable function release() -> void:
        pkg_source.release_resolved_versions(ref_of(this.registry_versions))


function solver_error(message: string.String) -> Result[SolverState, string.String]:
    return Result[SolverState, string.String].failure(error = message)


function list_error(message: string.String) -> Result[StateList, string.String]:
    return Result[StateList, string.String].failure(error = message)


function empty_state() -> SolverState:
    return SolverState(
        seen = vec.Vec[SeenManifest].create(),
        selected = vec.Vec[SelectedVersion].create(),
        stack = vec.Vec[string.String].create(),
    )


function clone_state(state: SolverState) -> SolverState:
    var copy = empty_state()
    var i: ptr_uint = 0
    while i < state.seen.len():
        let entry = state.seen.get(i) else:
            break
        copy.seen.push(SeenManifest(
            path = string.String.from_str(unsafe: read(entry).path.as_str()),
            package_name = string.String.from_str(unsafe: read(entry).package_name.as_str()),
        ))
        i += 1
    i = 0
    while i < state.selected.len():
        let entry = state.selected.get(i) else:
            break
        copy.selected.push(SelectedVersion(
            key = string.String.from_str(unsafe: read(entry).key.as_str()),
            package_name = string.String.from_str(unsafe: read(entry).package_name.as_str()),
            version = string.String.from_str(unsafe: read(entry).version.as_str()),
        ))
        i += 1
    i = 0
    while i < state.stack.len():
        let entry = state.stack.get(i) else:
            break
        copy.stack.push(string.String.from_str(unsafe: read(entry).as_str()))
        i += 1
    return copy


function release_state(state: ref[SolverState]) -> void:
    var i: ptr_uint = 0
    while i < state.seen.len():
        let entry = state.seen.get(i) else:
            break
        unsafe:
            read(entry).path.release()
            read(entry).package_name.release()
        i += 1
    state.seen.release()
    i = 0
    while i < state.selected.len():
        let entry = state.selected.get(i) else:
            break
        unsafe:
            read(entry).key.release()
            read(entry).package_name.release()
            read(entry).version.release()
        i += 1
    state.selected.release()
    i = 0
    while i < state.stack.len():
        let entry = state.stack.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    state.stack.release()


function find_seen(state: ref[SolverState], path: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < state.seen.len():
        let entry = state.seen.get(i) else:
            return Option[str].none
        unsafe:
            if read(entry).path.as_str().equal(path):
                return Option[str].some(value = read(entry).package_name.as_str())
        i += 1
    return Option[str].none


function stack_contains(state: ref[SolverState], path: str) -> bool:
    var i: ptr_uint = 0
    while i < state.stack.len():
        let entry = state.stack.get(i) else:
            return false
        if unsafe: read(entry).as_str().equal(path):
            return true
        i += 1
    return false


public function solve(
    package: manifest.PackageManifest,
    resolver: ref[pkg_source.SourceResolver]
) -> Result[Solution, string.String]:
    var state = empty_state()
    var parent_source = pkg_source.source_for_manifest(resolver, package)
    defer: parent_source.release()

    match visit_manifest(resolver, package, state, ref_of(parent_source)):
        Result.failure as failure_payload:
            return Result[Solution, string.String].failure(error = failure_payload.error)
        Result.success as state_payload:
            var resolved = state_payload.value
            defer: release_state(ref_of(resolved))
            var versions = vec.Vec[pkg_source.ResolvedVersion].create()
            var i: ptr_uint = 0
            while i < resolved.selected.len():
                let entry = resolved.selected.get(i) else:
                    break
                unsafe:
                    let value = read(entry)
                    versions.push(pkg_source.ResolvedVersion(
                        key = string.String.from_str(value.key.as_str()),
                        package_name = string.String.from_str(value.package_name.as_str()),
                        version = string.String.from_str(value.version.as_str()),
                    ))
                i += 1
            return Result[Solution, string.String].success(
                value = Solution(registry_versions = versions)
            )
    return Result[Solution, string.String].failure(error = string.String.from_str("dependency solve failed"))


function visit_manifest(
    resolver: ref[pkg_source.SourceResolver],
    package: manifest.PackageManifest,
    state: SolverState,
    package_source: ref[pkg_source.Source],
) -> Result[SolverState, string.String]:
    var state_view = state
    let path = package.manifest_path.as_str()
    if find_seen(ref_of(state_view), path).is_some():
        return Result[SolverState, string.String].success(value = state_view)
    if stack_contains(ref_of(state_view), path):
        var cycle = string.String.from_str("package dependency cycle detected: ")
        var i: ptr_uint = 0
        while i < state.stack.len():
            let entry = state.stack.get(i) else:
                break
            if i > 0:
                cycle.append(" -> ")
            let stack_path = unsafe: read(entry).as_str()
            match find_seen(ref_of(state_view), stack_path):
                Option.some as name:
                    cycle.append(name.value)
                Option.none:
                    cycle.append(stack_path)
            i += 1
        cycle.append(" -> ")
        cycle.append(package.package_name.as_str())
        return solver_error(cycle)

    var branch = clone_state(state)
    unsafe:
        branch.seen.push(SeenManifest(
            path = string.String.from_str(package.manifest_path.as_str()),
            package_name = string.String.from_str(package.package_name.as_str()),
        ))
    branch.stack.push(string.String.from_str(package.manifest_path.as_str()))

    match process_dependency_list(resolver, package, 0, package_source, branch):
        Result.success as resolved_payload:
            var resolved = resolved_payload.value
            match resolved.stack.pop():
                Option.some as popped:
                    var owned = popped.value
                    owned.release()
                Option.none:
                    pass
            return Result[SolverState, string.String].success(value = resolved)
        Result.failure as failure_payload:
            return Result[SolverState, string.String].failure(error = failure_payload.error)
    return Result[SolverState, string.String].failure(error = string.String.from_str("dependency resolution failed"))


function process_dependency_list(
    resolver: ref[pkg_source.SourceResolver],
    package: manifest.PackageManifest,
    index: ptr_uint,
    parent_source: ref[pkg_source.Source],
    state: SolverState,
) -> Result[SolverState, string.String]:
    if index >= package.dependencies.len():
        return Result[SolverState, string.String].success(value = state)

    let dependency = package.dependencies.get(index) else:
        return Result[SolverState, string.String].success(value = state)

    var package_view = package
    match visit_dependency(resolver, dependency, ref_of(package_view), parent_source, state):
        Result.failure as failure_payload:
            return Result[SolverState, string.String].failure(error = failure_payload.error)
        Result.success as candidate_payload:
            var states = candidate_payload.value
            var last_error: Option[string.String] = Option[string.String].none
            var i: ptr_uint = 0
            while i < states.len():
                let candidate = states.get(i) else:
                    break
                var candidate_state = unsafe: read(candidate)
                match process_dependency_list(resolver, package, index + 1, parent_source, candidate_state):
                    Result.success as resolved_payload:
                        states.release()
                        return Result[SolverState, string.String].success(value = resolved_payload.value)
                    Result.failure as child_failure:
                        if last_error.is_some():
                            var previous = last_error.unwrap()
                            previous.release()
                        last_error = Option[string.String].some(value = child_failure.error)
                i += 1
            states.release()
            match last_error:
                Option.some as error_payload:
                    return Result[SolverState, string.String].failure(error = error_payload.value)
                Option.none:
                    pass
            var message = string.String.from_str("failed to resolve dependency ")
            message.append(unsafe: read(dependency).name.as_str())
            message.append(" in ")
            message.append(package.manifest_path.as_str())
            return Result[SolverState, string.String].failure(error = message)
    return Result[SolverState, string.String].failure(error = string.String.from_str("dependency resolution failed"))


function visit_dependency(
    resolver: ref[pkg_source.SourceResolver],
    dependency: ptr[manifest.PackageDependency]?,
    package: ref[manifest.PackageManifest],
    parent_source: ref[pkg_source.Source],
    state: SolverState,
) -> Result[StateList, string.String]:
    if dependency == null:
        return list_error(string.String.from_str("missing dependency entry"))

    let dep = unsafe: read(dependency)

    if dep.path.is_some() or dep.git_dependency() or dep.exact_registry_version():
        var branch = clone_state(state)
        match pkg_source.resolve(resolver, dep, package, parent_source):
            Result.failure as resolve_failure:
                return list_error(resolve_failure.error)
            Result.success as resolved_payload:
                var resolved = resolved_payload.value
                defer: resolved.release()
                match visit_manifest(resolver, resolved.manifest, branch, ref_of(resolved.source)):
                    Result.failure as visit_failure:
                        return list_error(visit_failure.error)
                    Result.success as visited_payload:
                        var states = vec.Vec[SolverState].create()
                        states.push(visited_payload.value)
                        return Result[StateList, string.String].success(value = states)
        return list_error(string.String.from_str("dependency resolution failed"))

    if dep.registry():
        return choose_registry_version(resolver, dep, package, parent_source, clone_state(state))

    var message = string.String.from_str("dependency ")
    message.append(dep.name.as_str())
    message.append(" in ")
    message.append(package.manifest_path.as_str())
    message.append(" has no supported source resolver")
    return list_error(message)


function choose_registry_version(
    resolver: ref[pkg_source.SourceResolver],
    dependency: manifest.PackageDependency,
    package: ref[manifest.PackageManifest],
    parent_source: ref[pkg_source.Source],
    state: SolverState,
) -> Result[StateList, string.String]:
    let package_name = dependency.name.as_str()

    var dependency_key: string.String
    match pkg_source.source_key_for_identity(parent_source.identity):
        Result.failure as key_failure:
            return list_error(key_failure.error)
        Result.success as key_payload:
            var parent_key = key_payload.value
            dependency_key = pkg_source.registry_dependency_key(parent_key.as_str(), package_name)
            parent_key.release()

    var entries: vec.Vec[PackageVersionEntry]
    match load_registry_versions(package_name):
        Result.failure as versions_failure:
            dependency_key.release()
            return list_error(versions_failure.error)
        Result.success as versions_payload:
            entries = versions_payload.value

    var matching = select_matching_versions(entries, dependency.version_req)
    matching.sort_by(proc(left: ptr[PackageVersionEntry], right: ptr[PackageVersionEntry]) -> int:
        -unsafe: read(left).parsed.compare_to(unsafe: read(right).parsed)
    )

    match locked_registry_version(resolver, dependency_key.as_str(), package_name):
        Option.some as locked_payload:
            var locked = locked_payload.value
            matching = filter_locked_registry_versions(matching, locked.as_str())
            if matching.len() == 0:
                var message = locked_version_error(locked.as_str(), package_name, package, dependency.version_req)
                locked.release()
                dependency_key.release()
                return list_error(message)
            locked.release()
        Option.none:
            pass

    if matching.len() == 0:
        var message = no_matching_version_error(package_name, package, dependency.version_req)
        dependency_key.release()
        release_entries(ref_of(matching))
        return list_error(message)

    var result = visit_registry_candidates(
        resolver,
        ref_of(matching),
        dependency_key.as_str(),
        package_name,
        package,
        dependency,
        state,
    )
    release_entries(ref_of(matching))
    dependency_key.release()
    return result


function load_registry_versions(
    package_name: str,
) -> Result[vec.Vec[PackageVersionEntry], string.String]:
    var entries = vec.Vec[PackageVersionEntry].create()
    match registry.available_versions_default(package_name):
        Result.failure as versions_failure:
            entries.release()
            return Result[vec.Vec[PackageVersionEntry], string.String].failure(error = versions_failure.error)
        Result.success as versions_payload:
            var versions = versions_payload.value
            var i: ptr_uint = 0
            while i < versions.len():
                let entry = versions.get(i) else:
                    break
                let text_value = unsafe: read(entry).as_str()
                var label = string.String.from_str("registry package ")
                label.append(package_name)
                label.append(" version")
                match version.parse(text_value, label.as_str()):
                    Result.failure as parse_failure:
                        label.release()
                        release_entries(ref_of(entries))
                        pkg_source.release_strings(ref_of(versions))
                        return Result[vec.Vec[PackageVersionEntry], string.String].failure(error = parse_failure.error)
                    Result.success as parsed_payload:
                        label.release()
                        entries.push(PackageVersionEntry(
                            text = string.String.from_str(text_value),
                            parsed = parsed_payload.value,
                        ))
                i += 1
            pkg_source.release_strings(ref_of(versions))
    return Result[vec.Vec[PackageVersionEntry], string.String].success(value = entries)


function select_matching_versions(
    entries: vec.Vec[PackageVersionEntry],
    version_req: Option[version.PackageVersionReq],
) -> vec.Vec[PackageVersionEntry]:
    var matching = vec.Vec[PackageVersionEntry].create()
    var i: ptr_uint = 0
    while i < entries.len():
        let entry = entries.get(i) else:
            break
        match version_req:
            Option.some as req:
                if req.value.matches(unsafe: read(entry).parsed):
                    matching.push(unsafe: read(entry))
                else:
                    release_entry(entry)
            Option.none:
                matching.push(unsafe: read(entry))
        i += 1
    var owned = entries
    owned.release()
    return matching


function filter_locked_registry_versions(
    matching: vec.Vec[PackageVersionEntry],
    locked: str,
) -> vec.Vec[PackageVersionEntry]:
    var filtered = vec.Vec[PackageVersionEntry].create()
    var fi: ptr_uint = 0
    while fi < matching.len():
        let entry = matching.get(fi) else:
            break
        if unsafe: read(entry).text.as_str().equal(locked):
            filtered.push(unsafe: read(entry))
        else:
            release_entry(entry)
        fi += 1
    var owned = matching
    owned.release()
    return filtered


function locked_version_error(
    locked: str,
    package_name: str,
    package: ref[manifest.PackageManifest],
    version_req: Option[version.PackageVersionReq],
) -> string.String:
    var message = string.String.from_str("locked registry version ")
    message.append(locked)
    message.append(" for ")
    message.append(package_name)
    message.append(" in ")
    message.append(package.manifest_path.as_str())
    message.append(" does not satisfy ")
    append_version_requirement(ref_of(message), version_req)
    return message


function no_matching_version_error(
    package_name: str,
    package: ref[manifest.PackageManifest],
    version_req: Option[version.PackageVersionReq],
) -> string.String:
    var message = string.String.from_str("no registry version for ")
    message.append(package_name)
    message.append(" in ")
    message.append(package.manifest_path.as_str())
    message.append(" satisfies ")
    append_version_requirement(ref_of(message), version_req)
    return message


function append_version_requirement(
    message: ref[string.String],
    version_req: Option[version.PackageVersionReq],
) -> void:
    match version_req:
        Option.some as req:
            var req_text = req.value.to_string()
            message.append(req_text.as_str())
            req_text.release()
        Option.none:
            message.append("?")


function visit_registry_candidates(
    resolver: ref[pkg_source.SourceResolver],
    matching: ref[vec.Vec[PackageVersionEntry]],
    dependency_key: str,
    package_name: str,
    package: ref[manifest.PackageManifest],
    dependency: manifest.PackageDependency,
    state: SolverState,
) -> Result[StateList, string.String]:
    var states = vec.Vec[SolverState].create()
    var last_error: Option[string.String] = Option[string.String].none
    var mi: ptr_uint = 0
    while mi < matching.len():
        let candidate = matching.get(mi) else:
            break
        let candidate_text = unsafe: read(candidate).text.as_str()
        var branch = clone_state(state)
        unsafe:
            branch.selected.push(SelectedVersion(
                key = string.String.from_str(dependency_key),
                package_name = string.String.from_str(package_name),
                version = string.String.from_str(candidate_text),
            ))

        match manifest_for_registry(package_name, candidate_text):
            Result.failure as metadata_failure:
                if last_error.is_some():
                    var previous = last_error.unwrap()
                    previous.release()
                last_error = Option[string.String].some(value = metadata_failure.error)
                mi += 1
                continue
            Result.success as metadata_payload:
                var resolved_manifest = metadata_payload.value
                match pkg_source.identity_registry(package_name, candidate_text):
                    Result.failure as identity_failure:
                        resolved_manifest.release()
                        if last_error.is_some():
                            var previous = last_error.unwrap()
                            previous.release()
                        last_error = Option[string.String].some(value = identity_failure.error)
                        mi += 1
                        continue
                    Result.success as identity_payload:
                        var resolved_source = pkg_source.Source(
                            identity = identity_payload.value,
                            local_root = string.String.from_str(resolved_manifest.root_dir.as_str()),
                        )
                        match visit_manifest(resolver, resolved_manifest, branch, ref_of(resolved_source)):
                            Result.failure as visit_failure:
                                resolved_source.release()
                                resolved_manifest.release()
                                if last_error.is_some():
                                    var previous = last_error.unwrap()
                                    previous.release()
                                last_error = Option[string.String].some(value = visit_failure.error)
                            Result.success as visited_payload:
                                resolved_source.release()
                                resolved_manifest.release()
                                states.push(visited_payload.value)
        mi += 1

    if states.len() == 0:
        match last_error:
            Option.some as error_payload:
                return list_error(error_payload.value)
            Option.none:
                pass
        return list_error(no_matching_version_error(package_name, package, dependency.version_req))

    match last_error:
        Option.some as error_payload:
            var owned = error_payload.value
            owned.release()
        Option.none:
            pass
    return Result[StateList, string.String].success(value = states)


function locked_registry_version(
    resolver: ref[pkg_source.SourceResolver],
    dependency_key: str,
    package_name: str,
) -> Option[string.String]:
    var by_name: Option[string.String] = Option[string.String].none
    var i: ptr_uint = 0
    while i < resolver.resolved_versions.len():
        let entry = resolver.resolved_versions.get(i) else:
            break
        unsafe:
            let value = read(entry)
            if value.key.as_str().equal(dependency_key):
                if by_name.is_some():
                    var owned = by_name.unwrap()
                    owned.release()
                return Option[string.String].some(value = string.String.from_str(value.version.as_str()))
            if value.package_name.as_str().equal(package_name) and by_name.is_none():
                by_name = Option[string.String].some(value = string.String.from_str(value.version.as_str()))
        i += 1
    return by_name


function manifest_for_registry(
    package_name: str,
    package_version: str
) -> Result[manifest.PackageManifest, string.String]:
    var root: string.String
    match registry.published_root_default(package_name, package_version, true):
        Result.failure as root_failure:
            return Result[manifest.PackageManifest, string.String].failure(error = root_failure.error)
        Result.success as root_payload:
            root = root_payload.value
    defer: root.release()

    var loaded: manifest.PackageManifest
    match manifest.load(root.as_str()):
        Result.failure as manifest_failure:
            return Result[manifest.PackageManifest, string.String].failure(error = manifest_failure.error)
        Result.success as manifest_payload:
            loaded = manifest_payload.value

    var matches = loaded.package_name.as_str().equal(package_name)
    match loaded.package_version:
        Option.some as declared:
            if not declared.value.as_str().equal(package_version):
                matches = false
        Option.none:
            matches = false
    if not matches:
        var message = string.String.from_str("registry package at ")
        message.append(loaded.manifest_path.as_str())
        message.append(" resolved to ")
        message.append(loaded.package_name.as_str())
        message.append("@")
        match loaded.package_version:
            Option.some as declared:
                message.append("\"")
                message.append(declared.value.as_str())
                message.append("\"")
            Option.none:
                message.append("nil")
        message.append("; expected ")
        message.append(package_name)
        message.append("@")
        message.append(package_version)
        loaded.release()
        return Result[manifest.PackageManifest, string.String].failure(error = message)

    return Result[manifest.PackageManifest, string.String].success(value = loaded)


function release_entry(entry: ptr[PackageVersionEntry]) -> void:
    unsafe: read(entry).text.release()


function release_entries(entries: ref[VersionEntryList]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry = entries.get(i) else:
            break
        release_entry(entry)
        i += 1
    entries.release()
