## Deterministic `package.lock` support — the self-host port of
## `lib/milk_tea/packages/lock.rb`: schema 1/2 parsing, duplicate-instance and
## root-package validation, a SHA-256 instance identity over the source's lock
## attributes, the host's exact rendering, and locked-graph loading.

import std.crypto as crypto
import std.fmt as fmt
import std.fs as fs
import std.path as path_ops
import std.str as text_ops
import std.string as string
import std.toml as toml
import std.vec as vec

import mtc.packages.graph as graph
import mtc.packages.manifest as manifest
import mtc.packages.paths as paths
import mtc.packages.source as pkg_source


public enum LockStatus: ubyte
    current = 0
    missing = 1
    stale = 2


public struct LockCheck:
    lock_path: string.String
    status: LockStatus


public struct LockedPackage:
    package_name: string.String
    instance_id: string.String
    identity: pkg_source.SourceIdentity
    manifest_path: string.String
    dependency_names: vec.Vec[string.String]
    dependency_ids: vec.Vec[string.String]


struct LockRecord:
    instance_id: string.String
    package_name: string.String
    identity: pkg_source.SourceIdentity
    manifest_path: string.String
    dependency_ids: vec.Vec[string.String]


struct LockContext:
    root_manifest: manifest.PackageManifest
    lock_path: string.String
    root_package_id: string.String
    schema_version: int
    records: vec.Vec[LockRecord]


struct LockedNodeRef:
    instance_id: string.String
    index: ptr_uint


struct PackageSortEntry:
    package_name: string.String
    instance_id: string.String
    index: ptr_uint


struct DependencySortEntry:
    name: string.String
    instance_id: string.String


type LockedPackageList = vec.Vec[LockedPackage]
type StringList = vec.Vec[string.String]


extending LockCheck:
    public function current() -> bool:
        return this.status == LockStatus.current

    public function missing() -> bool:
        return this.status == LockStatus.missing

    public editable function release() -> void:
        this.lock_path.release()


extending LockedPackage:
    public editable function release() -> void:
        this.package_name.release()
        this.instance_id.release()
        this.identity.release()
        this.manifest_path.release()
        pkg_source.release_strings(ref_of(this.dependency_names))
        pkg_source.release_strings(ref_of(this.dependency_ids))


extending LockRecord:
    public editable function release() -> void:
        this.instance_id.release()
        this.package_name.release()
        this.identity.release()
        this.manifest_path.release()
        pkg_source.release_strings(ref_of(this.dependency_ids))


extending LockContext:
    public editable function release() -> void:
        this.root_manifest.release()
        this.lock_path.release()
        this.root_package_id.release()
        var i: ptr_uint = 0
        while i < this.records.len():
            let record = this.records.get(i) else:
                break
            unsafe: read(record).release()
            i += 1
        this.records.release()


function lock_error(message: string.String) -> Result[LockCheck, string.String]:
    return Result[LockCheck, string.String].failure(error = message)


function packages_error(message: string.String) -> Result[LockedPackageList, string.String]:
    return Result[LockedPackageList, string.String].failure(error = message)


function path_error(message: string.String) -> Result[string.String, string.String]:
    return Result[string.String, string.String].failure(error = message)


function context_error(message: string.String) -> Result[LockContext, string.String]:
    return Result[LockContext, string.String].failure(error = message)


function graph_error(message: string.String) -> Result[graph.PackageGraph, string.String]:
    return Result[graph.PackageGraph, string.String].failure(error = message)


function index_error(message: string.String) -> Result[ptr_uint, string.String]:
    return Result[ptr_uint, string.String].failure(error = message)


# =============================================================================
#  Rendering and the public check/write API
# =============================================================================

public function render(path: str, resolver: ref[pkg_source.SourceResolver]) -> Result[string.String, string.String]:
    var loaded: graph.PackageGraph
    match graph.load(path, resolver):
        Result.failure as load_failure:
            return path_error(load_failure.error)
        Result.success as graph_payload:
            loaded = graph_payload.value
    defer: loaded.release()

    var lock_path = lock_path_for(ref_of(loaded))
    defer: lock_path.release()
    var content = string.String.create()
    var root_id = package_instance_id(ref_of(loaded), loaded.root_index)
    let root_node_entry = loaded.nodes.get(loaded.root_index) else:
        root_id.release()
        return path_error(string.String.from_str("package graph root missing"))
    let root_manifest = unsafe: read(root_node_entry).manifest

    content.append("schema_version = 2\n")
    content.append("root_package = ")
    append_toml_string(ref_of(content), root_manifest.package_name.as_str())
    content.append("\nroot_package_id = ")
    append_toml_string(ref_of(content), root_id.as_str())
    content.append("\n\n")
    root_id.release()

    var indices = vec.Vec[ptr_uint].create()
    defer: indices.release()
    var visited = vec.Vec[string.String].create()
    defer: pkg_source.release_strings(ref_of(visited))
    collect_packages(ref_of(loaded), loaded.root_index, ref_of(indices), ref_of(visited))
    sort_package_indices(ref_of(loaded), ref_of(indices))

    var index_position: ptr_uint = 0
    while index_position < indices.len():
        let index_entry = indices.get(index_position) else:
            break
        let index = unsafe: read(index_entry)
        let node_entry = loaded.nodes.get(index) else:
            break
        var node = unsafe: read(node_entry)
        let node_manifest = node.manifest
        var instance_id = package_instance_id(ref_of(loaded), index)
        defer: instance_id.release()

        content.append("[[package]]\n")
        content.append("name = ")
        append_toml_string(ref_of(content), node_manifest.package_name.as_str())
        content.append("\nkind = ")
        append_toml_string(ref_of(content), node_manifest.kind_name())
        content.append("\n")
        match node_manifest.package_version:
            Option.some as version_payload:
                content.append("version = ")
                append_toml_string(ref_of(content), version_payload.value.as_str())
                content.append("\n")
            Option.none:
                pass
        content.append("instance_id = ")
        append_toml_string(ref_of(content), instance_id.as_str())
        content.append("\nsource_kind = ")
        append_toml_string(ref_of(content), node.source.identity.kind_name())
        content.append("\n")

        var attributes = pkg_source.identity_lock_attributes(node.source.identity)
        pkg_source.sort_lock_attributes(ref_of(attributes))
        var ai: ptr_uint = 0
        while ai < attributes.len():
            let entry = attributes.get(ai) else:
                break
            unsafe:
                content.append(read(entry).key.as_str())
                content.append(" = ")
                append_toml_string(ref_of(content), read(entry).value.as_str())
                content.append("\n")
            ai += 1
        pkg_source.release_lock_attributes(ref_of(attributes))

        content.append("manifest_path = ")
        append_toml_string(ref_of(content), node_manifest.manifest_path.as_str())
        content.append("\nsource_root = ")
        append_toml_string(ref_of(content), node_manifest.source_root.as_str())
        content.append("\ndependencies = ")
        append_dependency_names(ref_of(loaded), ref_of(node), ref_of(content))
        content.append("\ndependency_ids = ")
        append_dependency_ids(ref_of(loaded), ref_of(node), ref_of(content))
        content.append("\n")
        if index_position + 1 < indices.len():
            content.append("\n")
        index_position += 1

    return Result[string.String, string.String].success(value = content)


public function check(path: str, resolver: ref[pkg_source.SourceResolver]) -> Result[LockCheck, string.String]:
    var expected: string.String
    match render(path, resolver):
        Result.failure as render_failure:
            return lock_error(render_failure.error)
        Result.success as expected_payload:
            expected = expected_payload.value
    defer: expected.release()

    var root_manifest = manifest.load(path)
    var lock_path: string.String
    match root_manifest:
        Result.failure as manifest_failure:
            return lock_error(manifest_failure.error)
        Result.success as manifest_payload:
            var owned_manifest = manifest_payload.value
            lock_path = path_ops.join(owned_manifest.root_dir.as_str(), "package.lock")
            owned_manifest.release()

    if not fs.is_file(lock_path.as_str()):
        return Result[LockCheck, string.String].success(
            value = LockCheck(lock_path = lock_path, status = LockStatus.missing)
        )

    var actual: string.String
    match fs.read_text(lock_path.as_str()):
        Result.failure as read_failure:
            var read_error = read_failure.error
            var message = string.String.from_str("failed to read ")
            message.append(lock_path.as_str())
            message.append(": ")
            message.append(read_error.message.as_str())
            read_error.release()
            lock_path.release()
            return lock_error(message)
        Result.success as read_payload:
            actual = read_payload.value
    defer: actual.release()

    var status = LockStatus.stale
    if actual.as_str().equal(expected.as_str()):
        status = LockStatus.current
    return Result[LockCheck, string.String].success(
        value = LockCheck(lock_path = lock_path, status = status)
    )


public function write(path: str, resolver: ref[pkg_source.SourceResolver]) -> Result[string.String, string.String]:
    var content: string.String
    match render(path, resolver):
        Result.failure as render_failure:
            return path_error(render_failure.error)
        Result.success as content_payload:
            content = content_payload.value
    defer: content.release()

    var lock_path: string.String
    var root_manifest = manifest.load(path)
    match root_manifest:
        Result.failure as manifest_failure:
            return path_error(manifest_failure.error)
        Result.success as manifest_payload:
            var owned_manifest = manifest_payload.value
            lock_path = path_ops.join(owned_manifest.root_dir.as_str(), "package.lock")
            owned_manifest.release()

    match write_atomic(lock_path.as_str(), content.as_str()):
        Result.failure as write_failure:
            var message = string.String.from_str("failed to write ")
            message.append(lock_path.as_str())
            message.append(": ")
            message.append(write_failure.error.as_str())
            var owned = write_failure.error
            owned.release()
            lock_path.release()
            return path_error(message)
        Result.success:
            pass
    return Result[string.String, string.String].success(value = lock_path)


## The CLI's `--frozen` check: a missing or stale lock is a hard error.
public function ensure_current(path: str, cache_only: bool) -> Result[bool, string.String]:
    var mode = pkg_source.ResolutionMode.materialize
    if cache_only:
        mode = pkg_source.ResolutionMode.cache
    var resolver = pkg_source.create_resolver(mode)
    defer: resolver.release()
    match check(path, ref_of(resolver)):
        Result.failure as check_failure:
            return Result[bool, string.String].failure(error = check_failure.error)
        Result.success as check_payload:
            var result = check_payload.value
            defer: result.release()
            if result.current():
                return Result[bool, string.String].success(value = true)
            var message = string.String.create()
            if result.missing():
                message.append("package.lock is missing: ")
            else:
                message.append("package.lock is out of date: ")
            message.append(result.lock_path.as_str())
            return Result[bool, string.String].failure(error = message)
    return Result[bool, string.String].failure(error = string.String.from_str("package lock check failed"))


function lock_path_for(loaded: ref[graph.PackageGraph]) -> string.String:
    let node = loaded.nodes.get(loaded.root_index) else:
        return string.String.create()
    return path_ops.join(unsafe: read(node).manifest.root_dir.as_str(), "package.lock")


function write_atomic(path: str, content: str) -> Result[bool, string.String]:
    let directory = path_ops.dirname(path)
    match fs.create_directories(directory):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            var message = string.String.from_str(dir_error.message.as_str())
            dir_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass

    var temp_path: string.String
    match fs.create_temporary_file(directory, "milk-tea-package-lock", ".tmp"):
        Result.failure as temp_failure:
            var temp_error = temp_failure.error
            var message = string.String.from_str(temp_error.message.as_str())
            temp_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success as temp_payload:
            temp_path = temp_payload.value
    defer: temp_path.release()

    match fs.write_text(temp_path.as_str(), content):
        Result.failure as write_failure:
            var write_error = write_failure.error
            var message = string.String.from_str(write_error.message.as_str())
            write_error.release()
            let _ = fs.remove(temp_path.as_str())
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass

    match fs.rename(temp_path.as_str(), path):
        Result.failure as rename_failure:
            var rename_error = rename_failure.error
            var message = string.String.from_str(rename_error.message.as_str())
            rename_error.release()
            let _ = fs.remove(temp_path.as_str())
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass
    return Result[bool, string.String].success(value = true)


# =============================================================================
#  Instance identity
# =============================================================================

function package_instance_id(loaded: ref[graph.PackageGraph], index: ptr_uint) -> string.String:
    let node = loaded.nodes.get(index) else:
        return string.String.create()
    let value = unsafe: read(node)

    var joined = string.String.create()
    defer: joined.release()
    joined.append(value.manifest.package_name.as_str())
    joined.push_byte(0)
    joined.append(value.source.identity.kind_name())
    var attributes = pkg_source.identity_lock_attributes(value.source.identity)
    pkg_source.sort_lock_attributes(ref_of(attributes))
    var i: ptr_uint = 0
    while i < attributes.len():
        let entry = attributes.get(i) else:
            break
        unsafe:
            joined.push_byte(0)
            joined.append(read(entry).key.as_str())
            joined.push_byte(0)
            joined.append(read(entry).value.as_str())
        i += 1
    pkg_source.release_lock_attributes(ref_of(attributes))
    return crypto.sha256_to_str(text_ops.as_byte_span(joined.as_str()))


function identity_instance_id(package_name: str, identity: pkg_source.SourceIdentity) -> string.String:
    var joined = string.String.create()
    defer: joined.release()
    joined.append(package_name)
    joined.push_byte(0)
    joined.append(identity.kind_name())
    var attributes = pkg_source.identity_lock_attributes(identity)
    pkg_source.sort_lock_attributes(ref_of(attributes))
    var i: ptr_uint = 0
    while i < attributes.len():
        let entry = attributes.get(i) else:
            break
        unsafe:
            joined.push_byte(0)
            joined.append(read(entry).key.as_str())
            joined.push_byte(0)
            joined.append(read(entry).value.as_str())
        i += 1
    pkg_source.release_lock_attributes(ref_of(attributes))
    return crypto.sha256_to_str(text_ops.as_byte_span(joined.as_str()))


# =============================================================================
#  Rendering helpers
# =============================================================================

function collect_packages(
    loaded: ref[graph.PackageGraph],
    index: ptr_uint,
    output: ref[vec.Vec[ptr_uint]],
    visited: ref[StringList],
) -> void:
    let node_entry = loaded.nodes.get(index) else:
        return
    let node = unsafe: read(node_entry)
    let path = node.manifest.manifest_path.as_str()
    var i: ptr_uint = 0
    while i < visited.len():
        let entry = visited.get(i) else:
            return
        if unsafe: read(entry).as_str().equal(path):
            return
        i += 1
    visited.push(string.String.from_str(path))
    output.push(index)

    i = 0
    while i < node.edges.len():
        let edge = node.edges.get(i) else:
            break
        match unsafe: read(edge).node_index:
            Option.some as child:
                collect_packages(loaded, child.value, output, visited)
            Option.none:
                pass
        i += 1


function sort_package_indices(loaded: ref[graph.PackageGraph], indices: ref[vec.Vec[ptr_uint]]) -> void:
    var entries = vec.Vec[PackageSortEntry].create()
    defer: release_sort_entries(ref_of(entries))
    var i: ptr_uint = 0
    while i < indices.len():
        let index_entry = indices.get(i) else:
            break
        let index = unsafe: read(index_entry)
        let node_entry = loaded.nodes.get(index) else:
            break
        let node = unsafe: read(node_entry)
        entries.push(PackageSortEntry(
            package_name = string.String.from_str(node.manifest.package_name.as_str()),
            instance_id = package_instance_id(loaded, index),
            index = index,
        ))
        i += 1
    entries.sort_by(proc(left: ptr[PackageSortEntry], right: ptr[PackageSortEntry]) -> int: compare_sort_entries(left, right))
    indices.clear()
    i = 0
    while i < entries.len():
        let entry = entries.get(i) else:
            break
        indices.push(unsafe: read(entry).index)
        i += 1


function compare_sort_entries(left: ptr[PackageSortEntry], right: ptr[PackageSortEntry]) -> int:
    let left_value = unsafe: read(left)
    let right_value = unsafe: read(right)
    let by_name = left_value.package_name.as_str().compare(right_value.package_name.as_str())
    if by_name != 0:
        return by_name
    return left_value.instance_id.as_str().compare(right_value.instance_id.as_str())


function compare_dependency_entries(left: ptr[DependencySortEntry], right: ptr[DependencySortEntry]) -> int:
    let left_value = unsafe: read(left)
    let right_value = unsafe: read(right)
    let by_name = left_value.name.as_str().compare(right_value.name.as_str())
    if by_name != 0:
        return by_name
    return left_value.instance_id.as_str().compare(right_value.instance_id.as_str())


function release_sort_entries(entries: ref[vec.Vec[PackageSortEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry = entries.get(i) else:
            break
        unsafe:
            read(entry).package_name.release()
            read(entry).instance_id.release()
        i += 1
    entries.release()


function append_dependency_names(loaded: ref[graph.PackageGraph], node: ref[graph.GraphNode], content: ref[string.String]) -> void:
    var entries = collect_dependency_entries(loaded, node)
    defer: release_dependency_entries(ref_of(entries))
    content.push_byte('[')
    var i: ptr_uint = 0
    while i < entries.len():
        if i > 0:
            content.append(", ")
        let entry = entries.get(i) else:
            break
        append_toml_string(content, unsafe: read(entry).name.as_str())
        i += 1
    content.push_byte(']')


function append_dependency_ids(loaded: ref[graph.PackageGraph], node: ref[graph.GraphNode], content: ref[string.String]) -> void:
    var entries = collect_dependency_entries(loaded, node)
    defer: release_dependency_entries(ref_of(entries))
    content.push_byte('[')
    var i: ptr_uint = 0
    while i < entries.len():
        if i > 0:
            content.append(", ")
        let entry = entries.get(i) else:
            break
        append_toml_string(content, unsafe: read(entry).instance_id.as_str())
        i += 1
    content.push_byte(']')


function collect_dependency_entries(loaded: ref[graph.PackageGraph], node: ref[graph.GraphNode]) -> vec.Vec[DependencySortEntry]:
    var entries = vec.Vec[DependencySortEntry].create()
    var i: ptr_uint = 0
    while i < node.edges.len():
        let edge = node.edges.get(i) else:
            break
        let value = unsafe: read(edge)
        match value.node_index:
            Option.some as child:
                let child_entry = loaded.nodes.get(child.value) else:
                    break
                let child_node = unsafe: read(child_entry)
                entries.push(DependencySortEntry(
                    name = string.String.from_str(value.dependency_name.as_str()),
                    instance_id = identity_instance_id(child_node.manifest.package_name.as_str(), child_node.source.identity),
                ))
            Option.none:
                pass
        i += 1
    entries.sort_by(proc(left: ptr[DependencySortEntry], right: ptr[DependencySortEntry]) -> int: compare_dependency_entries(left, right))
    return entries


function release_dependency_entries(entries: ref[vec.Vec[DependencySortEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry = entries.get(i) else:
            break
        unsafe:
            read(entry).name.release()
            read(entry).instance_id.release()
        i += 1
    entries.release()


function append_toml_string(output: ref[string.String], value: str) -> void:
    output.push_byte('"')
    var i: ptr_uint = 0
    while i < value.len:
        let byte_value = value.byte_at(i)
        if byte_value == 92:
            output.append("\\\\")
        else if byte_value == 34:
            output.append("\\\"")
        else if byte_value == 10:
            output.append("\\n")
        else if byte_value == 13:
            output.append("\\r")
        else if byte_value == 9:
            output.append("\\t")
        else:
            output.push_byte(byte_value)
        i += 1
    output.push_byte('"')


# =============================================================================
#  Locked package records
# =============================================================================

public function locked_packages(path: str, resolver: ref[pkg_source.SourceResolver]) -> Result[LockedPackageList, string.String]:
    var context: LockContext
    match load_context(path):
        Result.failure as context_failure:
            return packages_error(context_failure.error)
        Result.success as context_payload:
            context = context_payload.value
    defer: context.release()

    var packages = vec.Vec[LockedPackage].create()
    var ri: ptr_uint = 0
    while ri < context.records.len():
        let record_entry = context.records.get(ri) else:
            break
        var record = unsafe: read(record_entry)
        var names = vec.Vec[string.String].create()
        var di: ptr_uint = 0
        var missing_id: Option[string.String] = Option[string.String].none
        while di < record.dependency_ids.len():
            let id_entry = record.dependency_ids.get(di) else:
                break
            let id_text = unsafe: read(id_entry).as_str()
            match find_record_index(ref_of(context), id_text):
                Option.some as dependency_index:
                    let dependency_record = context.records.get(dependency_index.value) else:
                        break
                    names.push(string.String.from_str(unsafe: read(dependency_record).package_name.as_str()))
                Option.none:
                    var message = string.String.from_str("package.lock missing dependency ")
                    message.append(id_text)
                    message.append(" referenced by ")
                    message.append(record.package_name.as_str())
                    missing_id = Option[string.String].some(value = message)
                    break
            di += 1
        if missing_id.is_some():
            pkg_source.release_strings(ref_of(names))
            packages.release()
            return packages_error(missing_id.unwrap())

        packages.push(LockedPackage(
            package_name = string.String.from_str(record.package_name.as_str()),
            instance_id = string.String.from_str(record.instance_id.as_str()),
            identity = pkg_source.clone_identity(record.identity),
            manifest_path = string.String.from_str(record.manifest_path.as_str()),
            dependency_names = names,
            dependency_ids = clone_strings(ref_of(record.dependency_ids)),
        ))
        ri += 1
    return Result[LockedPackageList, string.String].success(value = packages)


function clone_strings(values: ref[StringList]) -> StringList:
    var copy = vec.Vec[string.String].create()
    var i: ptr_uint = 0
    while i < values.len():
        let value = values.get(i) else:
            break
        copy.push(string.String.from_str(unsafe: read(value).as_str()))
        i += 1
    return copy


## Load the graph described by an existing package.lock (the `--locked` path).
public function load_graph(path: str, resolver: ref[pkg_source.SourceResolver]) -> Result[graph.PackageGraph, string.String]:
    var context: LockContext
    match load_context(path):
        Result.failure as context_failure:
            return graph_error(context_failure.error)
        Result.success as context_payload:
            context = context_payload.value
    defer: context.release()

    var loaded = graph.PackageGraph(nodes = vec.Vec[graph.GraphNode].create(), root_index = 0)
    var nodes_by_id = vec.Vec[LockedNodeRef].create()
    defer: release_locked_node_refs(ref_of(nodes_by_id))
    var stack = vec.Vec[string.String].create()
    defer: pkg_source.release_strings(ref_of(stack))

    match build_locked_node(ref_of(context), resolver, context.root_package_id.as_str(), ref_of(loaded), ref_of(nodes_by_id), ref_of(stack)):
        Result.failure as build_failure:
            loaded.release()
            return graph_error(build_failure.error)
        Result.success as index_payload:
            loaded.root_index = index_payload.value
    return Result[graph.PackageGraph, string.String].success(value = loaded)


function release_locked_node_refs(refs: ref[vec.Vec[LockedNodeRef]]) -> void:
    var i: ptr_uint = 0
    while i < refs.len():
        let entry = refs.get(i) else:
            break
        unsafe: read(entry).instance_id.release()
        i += 1
    refs.release()


function build_locked_node(
    context: ref[LockContext],
    resolver: ref[pkg_source.SourceResolver],
    instance_id: str,
    loaded: ref[graph.PackageGraph],
    nodes_by_id: ref[vec.Vec[LockedNodeRef]],
    stack: ref[StringList],
) -> Result[ptr_uint, string.String]:
    var i: ptr_uint = 0
    while i < nodes_by_id.len():
        let entry = nodes_by_id.get(i) else:
            break
        unsafe:
            if read(entry).instance_id.as_str().equal(instance_id):
                return Result[ptr_uint, string.String].success(value = read(entry).index)
        i += 1

    var stack_hit = false
    i = 0
    while i < stack.len():
        let entry = stack.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(instance_id):
            stack_hit = true
            break
        i += 1
    if stack_hit:
        var message = string.String.from_str("package dependency cycle detected in package.lock: ")
        i = 0
        while i < stack.len():
            let entry = stack.get(i) else:
                break
            if i > 0:
                message.append(" -> ")
            message.append(unsafe: read(entry).as_str())
            i += 1
        message.append(" -> ")
        message.append(instance_id)
        return index_error(message)

    var record_entry: ptr[LockRecord]?
    match find_record_index(context, instance_id):
        Option.some as record_index:
            record_entry = context.records.get(record_index.value)
        Option.none:
            var message = string.String.from_str("package.lock missing package ")
            message.append(instance_id)
            return index_error(message)
    if record_entry == null:
        var message = string.String.from_str("package.lock missing package ")
        message.append(instance_id)
        return index_error(message)

    var record = unsafe: read(record_entry)
    var package_source: pkg_source.Source
    match pkg_source.source_from_identity(resolver, ref_of(record.identity), context.lock_path.as_str()):
        Result.failure as source_failure:
            return index_error(source_failure.error)
        Result.success as source_payload:
            package_source = source_payload.value

    var package: manifest.PackageManifest
    match manifest.load(package_source.local_root.as_str()):
        Result.failure as manifest_failure:
            package_source.release()
            return index_error(manifest_failure.error)
        Result.success as manifest_payload:
            package = manifest_payload.value

    if not package.package_name.as_str().equal(record.package_name.as_str()):
        var message = string.String.from_str("package.lock entry ")
        message.append(record.package_name.as_str())
        message.append(" resolved materialized package ")
        message.append(package.package_name.as_str())
        message.append(" at ")
        message.append(package.manifest_path.as_str())
        package.release()
        package_source.release()
        return index_error(message)

    if record.identity.kind == pkg_source.SourceKind.registry_:
        var version_matches = false
        match package.package_version:
            Option.some as declared:
                version_matches = declared.value.as_str().equal(record.identity.registry_version.as_str())
            Option.none:
                pass
        if not version_matches:
            var message = string.String.from_str("package.lock registry entry ")
            message.append(record.package_name.as_str())
            message.append(" resolved version ")
            match package.package_version:
                Option.some as declared:
                    message.append("\"")
                    message.append(declared.value.as_str())
                    message.append("\"")
                Option.none:
                    message.append("nil")
            message.append(" at ")
            message.append(package.manifest_path.as_str())
            message.append("; expected \"")
            message.append(record.identity.registry_version.as_str())
            message.append("\"")
            package.release()
            package_source.release()
            return index_error(message)

    let node_index = loaded.nodes.len()
    loaded.nodes.push(graph.GraphNode(
        manifest = package,
        source = package_source,
        edges = vec.Vec[graph.GraphEdge].create(),
    ))
    nodes_by_id.push(LockedNodeRef(
        instance_id = string.String.from_str(instance_id),
        index = node_index,
    ))
    stack.push(string.String.from_str(instance_id))

    var edges = vec.Vec[graph.GraphEdge].create()
    var failed: Option[string.String] = Option[string.String].none
    var di: ptr_uint = 0
    while di < record.dependency_ids.len():
        let id_entry = record.dependency_ids.get(di) else:
            break
        let dependency_id = unsafe: read(id_entry).as_str()
        match find_record_index(context, dependency_id):
            Option.some as dependency_index:
                let dependency_record = context.records.get(dependency_index.value) else:
                    break
                match build_locked_node(context, resolver, dependency_id, loaded, nodes_by_id, stack):
                    Result.failure as child_failure:
                        failed = Option[string.String].some(value = child_failure.error)
                        break
                    Result.success as child_payload:
                        edges.push(graph.GraphEdge(
                            dependency_name = string.String.from_str(unsafe: read(dependency_record).package_name.as_str()),
                            node_index = Option[ptr_uint].some(value = child_payload.value),
                        ))
            Option.none:
                var message = string.String.from_str("package.lock missing dependency ")
                message.append(dependency_id)
                message.append(" referenced by ")
                message.append(record.package_name.as_str())
                failed = Option[string.String].some(value = message)
                break
        di += 1

    match stack.pop():
        Option.some as popped:
            var owned = popped.value
            owned.release()
        Option.none:
            pass

    match failed:
        Option.some as error_payload:
            var edge_i: ptr_uint = 0
            while edge_i < edges.len():
                let edge = edges.get(edge_i) else:
                    break
                unsafe: read(edge).release()
                edge_i += 1
            edges.release()
            return index_error(error_payload.value)
        Option.none:
            pass

    let node_ptr = loaded.nodes.get(node_index) else:
        edges.release()
        return index_error(string.String.from_str("package graph node disappeared"))
    unsafe:
        var node = read(node_ptr)
        node.edges = edges
        read(node_ptr) = node
    return Result[ptr_uint, string.String].success(value = node_index)


# =============================================================================
#  Lockfile parsing
# =============================================================================

function load_context(path: str) -> Result[LockContext, string.String]:
    var root_manifest: manifest.PackageManifest
    match manifest.load(path):
        Result.failure as manifest_failure:
            return context_error(manifest_failure.error)
        Result.success as manifest_payload:
            root_manifest = manifest_payload.value

    var lock_path = path_ops.join(root_manifest.root_dir.as_str(), "package.lock")
    if not fs.is_file(lock_path.as_str()):
        var message = string.String.from_str("package lock not found: ")
        message.append(lock_path.as_str())
        lock_path.release()
        root_manifest.release()
        return context_error(message)

    var text: string.String
    match fs.read_text(lock_path.as_str()):
        Result.failure as read_failure:
            var read_error = read_failure.error
            var message = string.String.from_str("invalid package.lock at ")
            message.append(lock_path.as_str())
            message.append(": ")
            message.append(read_error.message.as_str())
            read_error.release()
            lock_path.release()
            root_manifest.release()
            return context_error(message)
        Result.success as read_payload:
            text = read_payload.value
    defer: text.release()

    var document: toml.Document
    match toml.parse(text.as_str()):
        Result.failure as parse_failure:
            var parse_error = parse_failure.error
            var message = string.String.from_str("invalid package.lock at ")
            message.append(lock_path.as_str())
            message.append(": ")
            message.append(parse_error.message.as_str())
            parse_error.release()
            lock_path.release()
            root_manifest.release()
            return context_error(message)
        Result.success as parse_payload:
            document = parse_payload.value
    defer: document.release()

    var schema_version: int
    match parse_lock_schema_version(ref_of(document)):
        Result.failure as schema_failure:
            lock_path.release()
            root_manifest.release()
            return context_error(schema_failure.error)
        Result.success as schema_payload:
            schema_version = schema_payload.value

    var root_package: string.String
    match validate_lock_root_package(ref_of(document), lock_path.as_str(), ref_of(root_manifest)):
        Result.failure as root_failure:
            lock_path.release()
            root_manifest.release()
            return context_error(root_failure.error)
        Result.success as root_payload:
            root_package = root_payload.value

    var root_package_id: string.String
    if schema_version == 1:
        root_package_id = string.String.from_str(root_package.as_str())
    else:
        match required_string(ref_of(document.root), "root_package_id", lock_path.as_str()):
            Result.failure as id_failure:
                root_package.release()
                lock_path.release()
                root_manifest.release()
                return context_error(id_failure.error)
            Result.success as id_payload:
                root_package_id = id_payload.value
    root_package.release()

    let packages = document.get_array_table("package")
    var records: vec.Vec[LockRecord]
    match parse_lock_records(packages, schema_version, lock_path.as_str()):
        Result.failure as records_failure:
            root_package_id.release()
            lock_path.release()
            root_manifest.release()
            return context_error(records_failure.error)
        Result.success as records_payload:
            records = records_payload.value

    return Result[LockContext, string.String].success(
        value = LockContext(
            root_manifest = root_manifest,
            lock_path = lock_path,
            root_package_id = root_package_id,
            schema_version = schema_version,
            records = records,
        )
    )


function parse_lock_schema_version(document: ref[toml.Document]) -> Result[int, string.String]:
    var schema_version: int = 0
    match document.get_integer("schema_version"):
        Option.some as schema_payload:
            schema_version = int<-schema_payload.value
        Option.none:
            return Result[int, string.String].failure(
                error = string.String.from_str("unsupported package.lock schema version nil; expected 1 or 2")
            )
    if schema_version != 1 and schema_version != 2:
        var message = string.String.from_str("unsupported package.lock schema version ")
        fmt.append_int(ref_of(message), schema_version)
        message.append("; expected 1 or 2")
        return Result[int, string.String].failure(error = message)
    return Result[int, string.String].success(value = schema_version)


## Validate the lock's root package and its `[[package]]` table; returns the
## root package name for the schema-version-dependent id resolution.
function validate_lock_root_package(
    document: ref[toml.Document],
    lock_path: str,
    root_manifest: ref[manifest.PackageManifest],
) -> Result[string.String, string.String]:
    var root_package = string.String.create()
    match document.get_string("root_package"):
        Option.some as root_payload:
            root_package.append(root_payload.value)
        Option.none:
            pass
    if root_package.len() == 0:
        var message = string.String.from_str("package.lock missing root_package: ")
        message.append(lock_path)
        root_package.release()
        return Result[string.String, string.String].failure(error = message)
    if not root_package.as_str().equal(root_manifest.package_name.as_str()):
        var message = string.String.from_str("package.lock root package ")
        message.append(root_package.as_str())
        message.append(" does not match package manifest ")
        message.append(root_manifest.package_name.as_str())
        root_package.release()
        return Result[string.String, string.String].failure(error = message)

    let packages = document.get_array_table("package")
    if packages == null or unsafe: read(packages).len() == 0:
        var message = string.String.from_str("package.lock missing [[package]] entries: ")
        message.append(lock_path)
        root_package.release()
        return Result[string.String, string.String].failure(error = message)
    return Result[string.String, string.String].success(value = root_package)


function parse_lock_records(
    packages: ptr[toml.ArrayTable]?,
    schema_version: int,
    lock_path: str,
) -> Result[vec.Vec[LockRecord], string.String]:
    let table = packages else:
        var missing = string.String.from_str("package.lock missing [[package]] entries: ")
        missing.append(lock_path)
        return Result[vec.Vec[LockRecord], string.String].failure(error = missing)
    var records = vec.Vec[LockRecord].create()
    var entry_index: ptr_uint = 0
    while entry_index < unsafe: read(table).len():
        let package_entry = unsafe: read(table).get(entry_index) else:
            break
        var package_object = unsafe: read(package_entry)
        var package_name: string.String
        match required_string(ref_of(package_object), "name", lock_path):
            Result.failure as name_failure:
                context_release_records(ref_of(records))
                return Result[vec.Vec[LockRecord], string.String].failure(error = name_failure.error)
            Result.success as name_payload:
                package_name = name_payload.value

        var instance_id: string.String
        if schema_version == 1:
            instance_id = string.String.from_str(package_name.as_str())
        else:
            match required_string(ref_of(package_object), "instance_id", lock_path):
                Result.failure as instance_failure:
                    package_name.release()
                    context_release_records(ref_of(records))
                    return Result[vec.Vec[LockRecord], string.String].failure(error = instance_failure.error)
                Result.success as instance_payload:
                    instance_id = instance_payload.value

        if record_index_of(ref_of(records), instance_id.as_str()).is_some():
            var message = string.String.from_str("duplicate package instance ")
            message.append(instance_id.as_str())
            message.append(" in ")
            message.append(lock_path)
            instance_id.release()
            package_name.release()
            context_release_records(ref_of(records))
            return Result[vec.Vec[LockRecord], string.String].failure(error = message)

        var identity: pkg_source.SourceIdentity
        match identity_from_lock(ref_of(package_object), lock_path):
            Result.failure as identity_failure:
                instance_id.release()
                package_name.release()
                context_release_records(ref_of(records))
                return Result[vec.Vec[LockRecord], string.String].failure(error = identity_failure.error)
            Result.success as identity_payload:
                identity = identity_payload.value

        var manifest_path: string.String
        match required_string(ref_of(package_object), "manifest_path", lock_path):
            Result.failure as manifest_failure:
                identity.release()
                instance_id.release()
                package_name.release()
                context_release_records(ref_of(records))
                return Result[vec.Vec[LockRecord], string.String].failure(error = manifest_failure.error)
            Result.success as manifest_payload:
                manifest_path = paths.absolute_path(manifest_payload.value.as_str())
                manifest_payload.value.release()

        var dependency_ids: StringList
        let dependency_key = if schema_version == 1: "dependencies" else: "dependency_ids"
        match normalize_dependency_ids(ref_of(package_object), dependency_key, lock_path):
            Result.failure as ids_failure:
                manifest_path.release()
                identity.release()
                instance_id.release()
                package_name.release()
                context_release_records(ref_of(records))
                return Result[vec.Vec[LockRecord], string.String].failure(error = ids_failure.error)
            Result.success as ids_payload:
                dependency_ids = ids_payload.value

        records.push(LockRecord(
            instance_id = instance_id,
            package_name = package_name,
            identity = identity,
            manifest_path = manifest_path,
            dependency_ids = dependency_ids,
        ))
        entry_index += 1

    return Result[vec.Vec[LockRecord], string.String].success(value = records)


function context_release_records(records: ref[vec.Vec[LockRecord]]) -> void:
    var i: ptr_uint = 0
    while i < records.len():
        let record = records.get(i) else:
            break
        unsafe: read(record).release()
        i += 1
    records.release()


function record_index_of(records: ref[vec.Vec[LockRecord]], instance_id: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < records.len():
        let record = records.get(i) else:
            return Option[ptr_uint].none
        unsafe:
            if read(record).instance_id.as_str().equal(instance_id):
                return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function find_record_index(context: ref[LockContext], instance_id: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < context.records.len():
        let record = context.records.get(i) else:
            return Option[ptr_uint].none
        unsafe:
            if read(record).instance_id.as_str().equal(instance_id):
                return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function identity_from_lock(package_object: ref[toml.Object], lock_path: str) -> Result[pkg_source.SourceIdentity, string.String]:
    var source_kind = string.String.create()
    defer: source_kind.release()
    match object_string(package_object, "source_kind"):
        Option.some as kind_payload:
            source_kind.append(kind_payload.value.as_str())
            kind_payload.value.release()
        Option.none:
            pass

    if source_kind.as_str().equal("path"):
        match object_string(package_object, "source_path"):
            Option.some as path_payload:
                defer: path_payload.value.release()
                if path_payload.value.len() > 0:
                    return pkg_source.identity_path(path_payload.value.as_str())
            Option.none:
                pass
        var message = string.String.from_str("package.lock missing source_path in ")
        message.append(lock_path)
        return Result[pkg_source.SourceIdentity, string.String].failure(error = message)

    if source_kind.as_str().equal("registry"):
        var name = string.String.create()
        defer: name.release()
        match object_string(package_object, "registry_package"):
            Option.some as name_payload:
                name.append(name_payload.value.as_str())
                name_payload.value.release()
            Option.none:
                pass
        var version_text = string.String.create()
        defer: version_text.release()
        match object_string(package_object, "registry_version"):
            Option.some as version_payload:
                version_text.append(version_payload.value.as_str())
                version_payload.value.release()
            Option.none:
                pass
        return pkg_source.identity_registry(name.as_str(), version_text.as_str())

    if source_kind.as_str().equal("git"):
        var url = string.String.create()
        defer: url.release()
        match object_string(package_object, "git_url"):
            Option.some as url_payload:
                url.append(url_payload.value.as_str())
                url_payload.value.release()
            Option.none:
                pass
        var revision = string.String.create()
        defer: revision.release()
        match object_string(package_object, "git_rev"):
            Option.some as revision_payload:
                revision.append(revision_payload.value.as_str())
                revision_payload.value.release()
            Option.none:
                pass
        var subdir: Option[str] = Option[str].none
        var subdir_owner = string.String.create()
        defer: subdir_owner.release()
        match object_string(package_object, "git_subdir"):
            Option.some as subdir_payload:
                if subdir_payload.value.len() > 0:
                    subdir_owner.append(subdir_payload.value.as_str())
                    subdir = Option[str].some(value = subdir_owner.as_str())
                subdir_payload.value.release()
            Option.none:
                pass
        return pkg_source.identity_git(url.as_str(), revision.as_str(), subdir)

    var message = string.String.from_str("unsupported package source_kind \"")
    message.append(source_kind.as_str())
    message.append("\" in ")
    message.append(lock_path)
    message.append("; supported kinds are path, registry, and git")
    return Result[pkg_source.SourceIdentity, string.String].failure(error = message)


function object_string(package_object: ref[toml.Object], key: str) -> Option[string.String]:
    let entry = find_entry(package_object, key)
    if entry == null:
        return Option[string.String].none
    unsafe:
        let value = read(entry).value
        match value.kind:
            toml.ValueKind.string_:
                return Option[string.String].some(value = string.String.from_str(value.string_value.as_str()))
            toml.ValueKind.integer:
                var rendered = string.String.create()
                var number = value.integer_value
                if number < 0:
                    rendered.push_byte('-')
                    number = -number
                if number == 0:
                    rendered.push_byte('0')
                else:
                    var digits: array[ubyte, 32]
                    var count: ptr_uint = 0
                    while number > 0:
                        digits[count] = ubyte<-(number % 10) + 48
                        number = number / 10
                        count += 1
                    while count > 0:
                        count -= 1
                        rendered.push_byte(digits[count])
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


function find_entry(package_object: ref[toml.Object], key: str) -> ptr[toml.Entry]?:
    var i: ptr_uint = 0
    while i < package_object.entries.len():
        let entry = package_object.entries.get(i) else:
            return null
        unsafe:
            if read(entry).key.as_str().equal(key):
                return entry
        i += 1
    return null


function required_string(package_object: ref[toml.Object], key: str, lock_path: str) -> Result[string.String, string.String]:
    match object_string(package_object, key):
        Option.some as payload:
            if payload.value.len() > 0:
                return Result[string.String, string.String].success(value = payload.value)
            payload.value.release()
        Option.none:
            pass
    var message = string.String.from_str("package.lock missing ")
    message.append(key)
    message.append(" in ")
    message.append(lock_path)
    return Result[string.String, string.String].failure(error = message)


function normalize_dependency_ids(
    package_object: ref[toml.Object],
    key: str,
    lock_path: str,
) -> Result[StringList, string.String]:
    var ids = vec.Vec[string.String].create()
    let array_ptr = read(package_object).get_array(key)
    if array_ptr == null:
        if read(package_object).contains(key):
            var message = string.String.from_str("package.lock dependencies must be an array in ")
            message.append(lock_path)
            return Result[StringList, string.String].failure(error = message)
        return Result[StringList, string.String].success(value = ids)

    let values = unsafe: read(array_ptr)
    var i: ptr_uint = 0
    while i < values.len():
        match values.get_string(i):
            Option.some as payload:
                if payload.value.len == 0:
                    pkg_source.release_strings(ref_of(ids))
                    var message = string.String.from_str("package.lock dependency ids must be strings in ")
                    message.append(lock_path)
                    return Result[StringList, string.String].failure(error = message)
                ids.push(string.String.from_str(payload.value))
            Option.none:
                pkg_source.release_strings(ref_of(ids))
                var message = string.String.from_str("package.lock dependency ids must be strings in ")
                message.append(lock_path)
                return Result[StringList, string.String].failure(error = message)
        i += 1
    return Result[StringList, string.String].success(value = ids)

