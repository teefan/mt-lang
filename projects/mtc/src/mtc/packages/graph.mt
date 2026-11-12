## Package dependency graph — the self-host port of
## `lib/milk_tea/packages/graph.rb`: resolves the root manifest's transitive
## path/git/registry dependencies into nodes, preserving edge order, detecting
## cycles, and exposing source roots, package lookup by path, and the `deps
## tree` rendering.

import std.str
import std.string as string
import std.vec as vec

import mtc.packages.manifest as manifest
import mtc.packages.paths as paths
import mtc.packages.solver as solver
import mtc.packages.source as source


public struct GraphEdge:
    dependency_name: string.String
    ## Index into `PackageGraph.nodes`; none only for an unresolved edge (the
    ## locked graph never leaves one).
    node_index: Option[ptr_uint]


public struct GraphNode:
    manifest: manifest.PackageManifest
    source: source.Source
    edges: vec.Vec[GraphEdge]


public struct PackageGraph:
    nodes: vec.Vec[GraphNode]
    root_index: ptr_uint


struct NodeRef:
    path: string.String
    index: ptr_uint


extending GraphEdge:
    public editable function release() -> void:
        this.dependency_name.release()


extending GraphNode:
    public editable function release() -> void:
        this.manifest.release()
        this.source.release()
        var i: ptr_uint = 0
        while i < this.edges.len():
            let edge = this.edges.get(i) else:
                break
            unsafe: read(edge).release()
            i += 1
        this.edges.release()


extending PackageGraph:
    public editable function release() -> void:
        var i: ptr_uint = 0
        while i < this.nodes.len():
            let node = this.nodes.get(i) else:
                break
            unsafe: read(node).release()
            i += 1
        this.nodes.release()


function graph_error(message: string.String) -> Result[PackageGraph, string.String]:
    return Result[PackageGraph, string.String].failure(error = message)


function index_error(message: string.String) -> Result[ptr_uint, string.String]:
    return Result[ptr_uint, string.String].failure(error = message)


## Load the graph rooted at `path`.  A resolver that supports dependency
## solving first runs the registry solver and pins the resolved versions.
public function load(path: str, resolver: ref[source.SourceResolver]) -> Result[PackageGraph, string.String]:
    var root_manifest: manifest.PackageManifest
    match manifest.load(path):
        Result.failure as manifest_failure:
            return graph_error(manifest_failure.error)
        Result.success as manifest_payload:
            root_manifest = manifest_payload.value

    var active: source.SourceResolver
    if resolver.supports_dependency_solving():
        match solver.solve(root_manifest, resolver):
            Result.failure as solve_failure:
                root_manifest.release()
                return graph_error(solve_failure.error)
            Result.success as solution_payload:
                var solution = solution_payload.value
                active = source.with_resolved_versions(resolver, ref_of(solution.registry_versions))
                solution.release()
    else:
        active = source.SourceResolver(
            cache_root = string.String.from_str(resolver.cache_root.as_str()),
            mode = resolver.mode,
            resolved_versions = vec.Vec[source.ResolvedVersion].create(),
        )
    defer: active.release()

    var graph = PackageGraph(nodes = vec.Vec[GraphNode].create(), root_index = 0)
    var seen = vec.Vec[NodeRef].create()
    defer: release_node_refs(ref_of(seen))
    var stack = vec.Vec[string.String].create()
    defer: source.release_strings(ref_of(stack))

    let root_source = source.source_for_manifest(ref_of(active), root_manifest)
    match build_node(ref_of(graph), ref_of(active), root_manifest, root_source, ref_of(seen), ref_of(stack)):
        Result.failure as build_failure:
            graph.release()
            return graph_error(build_failure.error)
        Result.success as index_payload:
            graph.root_index = index_payload.value
    return Result[PackageGraph, string.String].success(value = graph)


function release_node_refs(refs: ref[vec.Vec[NodeRef]]) -> void:
    var i: ptr_uint = 0
    while i < refs.len():
        let ref_entry = refs.get(i) else:
            break
        unsafe: read(ref_entry).path.release()
        i += 1
    refs.release()


function find_node_ref(refs: ref[vec.Vec[NodeRef]], path: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < refs.len():
        let entry = refs.get(i) else:
            return Option[ptr_uint].none
        unsafe:
            if read(entry).path.as_str().equal(path):
                return Option[ptr_uint].some(value = read(entry).index)
        i += 1
    return Option[ptr_uint].none


function stack_index(stack: ref[vec.Vec[string.String]], path: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < stack.len():
        let entry = stack.get(i) else:
            return Option[ptr_uint].none
        if unsafe: read(entry).as_str().equal(path):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function build_node(
    graph: ref[PackageGraph],
    resolver: ref[source.SourceResolver],
    package: manifest.PackageManifest,
    package_source: source.Source,
    seen: ref[vec.Vec[NodeRef]],
    stack: ref[vec.Vec[string.String]],
) -> Result[ptr_uint, string.String]:
    var owned_source = package_source
    var package_view = package
    let path = package.manifest_path.as_str()
    match find_node_ref(seen, path):
        Option.some as existing:
            owned_source.release()
            return Result[ptr_uint, string.String].success(value = existing.value)
        Option.none:
            pass
    if stack_index(stack, path).is_some():
        owned_source.release()
        var message = string.String.from_str("package dependency cycle detected: ")
        var i: ptr_uint = 0
        while i < stack.len():
            let entry = stack.get(i) else:
                break
            if i > 0:
                message.append(" -> ")
            message.append(unsafe: read(entry).as_str())
            i += 1
        message.append(" -> ")
        message.append(package.package_name.as_str())
        return index_error(message)

    let node_index = graph.nodes.len()
    graph.nodes.push(GraphNode(
        manifest = package,
        source = owned_source,
        edges = vec.Vec[GraphEdge].create(),
    ))
    seen.push(NodeRef(
        path = string.String.from_str(package.manifest_path.as_str()),
        index = node_index,
    ))
    stack.push(string.String.from_str(package.manifest_path.as_str()))

    var edges = vec.Vec[GraphEdge].create()
    var failed: Option[string.String] = Option[string.String].none
    var i: ptr_uint = 0
    while i < package.dependencies.len():
        let dependency = package.dependencies.get(i) else:
            break
        match source.resolve(resolver, unsafe: read(dependency), ref_of(package_view), ref_of(owned_source)):
            Result.failure as resolve_failure:
                failed = Option[string.String].some(value = resolve_failure.error)
                break
            Result.success as resolved_payload:
                var resolved = resolved_payload.value
                match build_node(graph, resolver, resolved.manifest, resolved.source, seen, stack):
                    Result.failure as child_failure:
                        failed = Option[string.String].some(value = child_failure.error)
                        break
                    Result.success as child_payload:
                        edges.push(GraphEdge(
                            dependency_name = string.String.from_str(unsafe: read(dependency).name.as_str()),
                            node_index = Option[ptr_uint].some(value = child_payload.value),
                        ))
        i += 1

    match stack.pop():
        Option.some as popped:
            var owned = popped.value
            owned.release()
        Option.none:
            pass

    match failed:
        Option.some as error_payload:
            release_edges(ref_of(edges))
            return index_error(error_payload.value)
        Option.none:
            pass

    let node_ptr = graph.nodes.get(node_index) else:
        release_edges(ref_of(edges))
        return index_error(string.String.from_str("package graph node disappeared"))
    unsafe:
        var node = read(node_ptr)
        node.edges = edges
        read(node_ptr) = node
    return Result[ptr_uint, string.String].success(value = node_index)


function release_edges(edges: ref[vec.Vec[GraphEdge]]) -> void:
    var i: ptr_uint = 0
    while i < edges.len():
        let edge = edges.get(i) else:
            break
        unsafe: read(edge).release()
        i += 1
    edges.release()


# =============================================================================
#  Queries
# =============================================================================

public function node_count(graph: ref[PackageGraph]) -> ptr_uint:
    return graph.nodes.len()


public function node_at(graph: ref[PackageGraph], index: ptr_uint) -> ptr[GraphNode]?:
    return graph.nodes.get(index)


public function root_node(graph: ref[PackageGraph]) -> ptr[GraphNode]?:
    return graph.nodes.get(graph.root_index)


## Pre-order DFS from the root, deduplicated by manifest path (the host's
## `Node#packages`).
function collect_node_indices(graph: ref[PackageGraph], index: ptr_uint, output: ref[vec.Vec[ptr_uint]], visited: ref[vec.Vec[string.String]]) -> void:
    let node = graph.nodes.get(index) else:
        return
    let node_value = unsafe: read(node)
    let path = node_value.manifest.manifest_path.as_str()
    var vi: ptr_uint = 0
    while vi < visited.len():
        let entry = visited.get(vi) else:
            return
        if unsafe: read(entry).as_str().equal(path):
            return
        vi += 1
    visited.push(string.String.from_str(path))
    output.push(index)

    var i: ptr_uint = 0
    while i < node_value.edges.len():
        let edge = node_value.edges.get(i) else:
            break
        match unsafe: read(edge).node_index:
            Option.some as child:
                collect_node_indices(graph, child.value, output, visited)
            Option.none:
                pass
        i += 1


public function source_roots(graph: ref[PackageGraph]) -> vec.Vec[string.String]:
    var roots = vec.Vec[string.String].create()
    var indices = vec.Vec[ptr_uint].create()
    defer: indices.release()
    var visited = vec.Vec[string.String].create()
    defer: source.release_strings(ref_of(visited))
    collect_node_indices(graph, graph.root_index, ref_of(indices), ref_of(visited))

    var i: ptr_uint = 0
    while i < indices.len():
        let index = indices.get(i) else:
            break
        let node = graph.nodes.get(unsafe: read(index)) else:
            break
        let root = unsafe: read(node).manifest.source_root.as_str()
        if not contains_text(ref_of(roots), root):
            roots.push(string.String.from_str(root))
        i += 1
    return roots


function contains_text(values: ref[vec.Vec[string.String]], candidate: str) -> bool:
    var i: ptr_uint = 0
    while i < values.len():
        let entry = values.get(i) else:
            return false
        if unsafe: read(entry).as_str().equal(candidate):
            return true
        i += 1
    return false


## The deepest package root containing `path`, or none (the host's
## `Node#package_for_path`).
public function package_for_path(graph: ref[PackageGraph], path: str) -> Option[ptr_uint]:
    var best: Option[ptr_uint] = Option[ptr_uint].none
    var best_length: ptr_uint = 0
    var i: ptr_uint = 0
    while i < graph.nodes.len():
        let node = graph.nodes.get(i) else:
            break
        let root = unsafe: read(node).manifest.root_dir.as_str()
        if paths.path_within_root(path, root):
            if best.is_none() or root.len > best_length:
                best = Option[ptr_uint].some(value = i)
                best_length = root.len
        i += 1
    return best


## `PackageGraph.render_tree`: package names, one dependency level indented by
## two spaces per depth.  The returned String has no trailing newline.
public function render_tree(graph: ref[PackageGraph]) -> string.String:
    var output = string.String.create()
    append_tree_lines(graph, graph.root_index, 0, ref_of(output))
    return output


function append_tree_lines(
    graph: ref[PackageGraph],
    index: ptr_uint,
    depth: ptr_uint,
    output: ref[string.String],
) -> void:
    let node_ptr = graph.nodes.get(index) else:
        return
    let node = unsafe: read(node_ptr)

    var d: ptr_uint = 0
    while d < depth:
        output.append("  ")
        d += 1
    output.append(node.manifest.package_name.as_str())
    output.push_byte('\n')

    var i: ptr_uint = 0
    while i < node.edges.len():
        let edge = node.edges.get(i) else:
            break
        match unsafe: read(edge).node_index:
            Option.some as child:
                append_tree_lines(graph, child.value, depth + 1, output)
            Option.none:
                var d2: ptr_uint = 0
                while d2 < depth + 1:
                    output.append("  ")
                    d2 += 1
                output.append(unsafe: read(edge).dependency_name.as_str())
                output.push_byte('\n')
        i += 1


public function tree_text(graph: ref[PackageGraph]) -> string.String:
    var rendered = render_tree(graph)
    if rendered.len() > 0:
        # The CLI prints the rendering as one line block; drop the final
        # newline so `print_line` does not add a blank line.
        rendered.truncate(rendered.len() - 1)
    return rendered
