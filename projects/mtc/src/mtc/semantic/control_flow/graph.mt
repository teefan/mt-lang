## Control-flow graph and its nullability dataflow — the host's
## `ControlFlow::Graph`, `ControlFlow::Dataflow.solve` and
## `ControlFlow::NullabilityFlow` ported to the self, so the analyzer's
## continuation refinement and the linter's flow rules run over one graph
## instead of per-rule AST walks.
##
## Ownership:  the caller creates a graph with `empty_graph()` (a struct
## literal — safe to return by value), fills it with the builder, and resets it
## with `graph_clear` between function bodies.  Never return a CfgGraph or a
## NullabilityFlow by value from a function that stores it in a local variable.
##
## Identity:  a node's `statement` is the *address* of the AST statement it was
## built from, the self's analogue of the host's `statement.object_id`; it is
## what the analyzer looks a statement up by.  Node ids start at 1, so id 0
## means "no node" (the host's nil).

import std.map as map_mod
import std.mem.heap as heap
import std.vec as vec

import mtc.parser.ast as ast


## One null-test edge refinement (an entry of the host's
## `set_edge_refinement(from, to, refinement)`: taking this edge adds `key` to
## the non-null set when `non_null`, removes it otherwise).
public struct EdgeRefinement:
    from: ptr_uint
    to: ptr_uint
    key: ptr_uint
    non_null: bool


## An edge's label (`true_branch`, `false_branch`, `non_null`, `null`), the
## host's `Graph#edge_label`.
public struct EdgeLabel:
    from: ptr_uint
    to: ptr_uint
    label: str


## A binding read site — the host's `ReadSite`.
public struct ReadSite:
    key: ptr_uint
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


## A binding write site — the host's `writes_info` entry.  `origin` is one of
## `declaration`, `assignment`, `for_binding`, `match_binding`,
## `call_argument`.
public struct WriteSite:
    key: ptr_uint
    name: str
    line: ptr_uint
    column: ptr_uint
    origin: str


## A basic-block node: its kind, the statement it was built from, and the
## binding accesses the dataflow passes read.
public struct CfgNode:
    id: ptr_uint
    kind: str
    statement: ptr_uint
    line: ptr_uint
    column: ptr_uint
    read_sites: vec.Vec[ReadSite]
    write_sites: vec.Vec[WriteSite]
    succs: vec.Vec[ptr_uint]
    preds: vec.Vec[ptr_uint]


## The graph: nodes indexed by id - 1, the flat edge tables, and the
## statement → node map (`graph_clear` releases every buffer, including the
## per-node site vectors).
public struct CfgGraph:
    nodes: vec.Vec[ptr[CfgNode]]
    edge_labels: vec.Vec[EdgeLabel]
    edge_refinements: vec.Vec[EdgeRefinement]
    by_statement: map_mod.Map[ptr_uint, ptr_uint]
    entry_id: ptr_uint
    exit_id: ptr_uint
    next_id: ptr_uint


## The non-null set before every node (the host's `NullabilityFlow::Result`): a
## flat `node × binding` bool table of in-states.  `row_size` is the binding
## count plus one, so a binding id indexes a row directly.
public struct NullabilityFlow:
    state: ptr[bool]?
    row_size: ptr_uint
    node_count: ptr_uint


## Return an empty graph.  A struct literal, so safe to return by value.
public function empty_graph() -> CfgGraph:
    return CfgGraph(
        nodes = vec.Vec[ptr[CfgNode]].create(),
        edge_labels = vec.Vec[EdgeLabel].create(),
        edge_refinements = vec.Vec[EdgeRefinement].create(),
        by_statement = map_mod.Map[ptr_uint, ptr_uint].create(),
        entry_id = 0,
        exit_id = 0,
        next_id = 1,
    )


## Release the graph's nodes (with their site vectors) and its tables, keeping
## the graph usable for the next function body.
public function graph_clear(graph: ref[CfgGraph]) -> void:
    var i: ptr_uint = 0
    while i < read(graph).nodes.len():
        let slot = read(graph).nodes.get(i) else:
            break
        let n = unsafe: read(slot)
        unsafe:
            read(n).read_sites.release()
            read(n).write_sites.release()
            read(n).succs.release()
            read(n).preds.release()
        heap.release(n)
        i += 1
    read(graph).nodes.clear()
    read(graph).edge_labels.clear()
    read(graph).edge_refinements.clear()
    read(graph).by_statement.clear()
    read(graph).entry_id = 0
    read(graph).exit_id = 0
    read(graph).next_id = 1


## Release the graph itself.
public function graph_release(graph: ref[CfgGraph]) -> void:
    graph_clear(graph)
    read(graph).nodes.release()
    read(graph).edge_labels.release()
    read(graph).edge_refinements.release()
    read(graph).by_statement.release()


# =============================================================================
#  Nodes and edges
# =============================================================================

public function graph_add_node(graph: ref[CfgGraph], kind: str, statement: ptr_uint, line: ptr_uint, column: ptr_uint) -> ptr_uint:
    let id = read(graph).next_id
    let raw = heap.must_alloc[CfgNode](1)
    let node = unsafe: ptr[CfgNode]<-raw
    unsafe:
        read(node) = CfgNode(
            id = id,
            kind = kind,
            statement = statement,
            line = line,
            column = column,
            read_sites = vec.Vec[ReadSite].create(),
            write_sites = vec.Vec[WriteSite].create(),
            succs = vec.Vec[ptr_uint].create(),
            preds = vec.Vec[ptr_uint].create(),
        )
    read(graph).nodes.push(node)
    read(graph).next_id = id + 1
    if statement != 0:
        let _prev = read(graph).by_statement.set(statement, id)
    return id


public function graph_node(graph: ref[CfgGraph], id: ptr_uint) -> ptr[CfgNode]?:
    if id == 0:
        return null
    if id > read(graph).nodes.len():
        return null
    let slot = read(graph).nodes.get(id - 1) else:
        return null
    return unsafe: read(slot)


## The node built from `statement` (the host's `stmt_to_node_id`); 0 when the
## statement is transparent in the graph (a block, an `unsafe:` wrapper) or has
## no node.  When a statement produced more than one node the last one wins,
## matching the host's map-fill order.
public function graph_node_for_statement(graph: ref[CfgGraph], statement: ptr_uint) -> ptr_uint:
    let found = read(graph).by_statement.get(statement) else:
        return 0
    return unsafe: read(found)


## Add a `from → to` edge.  Parallel edges collapse, as the host's `add_edge`
## does; id 0 never names a node.
public function graph_add_edge(graph: ref[CfgGraph], from: ptr_uint, to: ptr_uint) -> void:
    if from == 0 or to == 0:
        return
    let a = graph_node(graph, from) else:
        return
    let b = graph_node(graph, to) else:
        return
    unsafe:
        if not id_vec_contains(ref_of(read(a).succs), to):
            read(a).succs.push(to)
        if not id_vec_contains(ref_of(read(b).preds), from):
            read(b).preds.push(from)


public function graph_set_edge_label(graph: ref[CfgGraph], from: ptr_uint, to: ptr_uint, label: str) -> void:
    read(graph).edge_labels.push(EdgeLabel(from = from, to = to, label = label))


## Record one null-test refinement on the edge (the host's
## `set_edge_refinement`).  A later call for the same (edge, key) replaces the
## earlier value, as the host's hash assignment does.
public function graph_set_edge_refinement(graph: ref[CfgGraph], from: ptr_uint, to: ptr_uint, key: ptr_uint, non_null: bool) -> void:
    var i: ptr_uint = 0
    while i < read(graph).edge_refinements.len():
        let r = read(graph).edge_refinements.get(i) else:
            break
        unsafe:
            if read(r).from == from and read(r).to == to and read(r).key == key:
                read(r).non_null = non_null
                return
        i += 1
    read(graph).edge_refinements.push(EdgeRefinement(from = from, to = to, key = key, non_null = non_null))


## True when the given edge carries a refinement, and whether it adds `key` to
## the non-null set (`nonnull_out`) or removes it.
public function graph_edge_refinement_of(graph: ref[CfgGraph], from: ptr_uint, to: ptr_uint, key: ptr_uint, nonnull_out: ref[bool]) -> bool:
    var i: ptr_uint = 0
    while i < read(graph).edge_refinements.len():
        let r = read(graph).edge_refinements.get(i) else:
            break
        unsafe:
            if read(r).from == from and read(r).to == to and read(r).key == key:
                read(nonnull_out) = read(r).non_null
                return true
        i += 1
    return false


public function graph_edge_label(graph: ref[CfgGraph], from: ptr_uint, to: ptr_uint) -> str:
    var i: ptr_uint = 0
    while i < read(graph).edge_labels.len():
        let e = read(graph).edge_labels.get(i) else:
            break
        unsafe:
            if read(e).from == from and read(e).to == to:
                return read(e).label
        i += 1
    return ""


## True when `to` is reachable from `from` over successor edges (the host's
## `Termination` question: a block whose fall-through is unreachable always
## terminates).
public function graph_reaches(graph: ref[CfgGraph], from: ptr_uint, to: ptr_uint) -> bool:
    if from == 0 or to == 0:
        return false
    var seen = map_mod.Map[ptr_uint, bool].create()
    defer: seen.release()
    var work = vec.Vec[ptr_uint].create()
    defer: work.release()
    work.push(from)
    while work.len() > 0:
        let popped = work.pop() else:
            break
        let current = popped
        if current == to:
            return true
        if seen.contains(current):
            continue
        seen.set(current, true)
        let node = graph_node(graph, current) else:
            continue
        unsafe:
            var si: ptr_uint = 0
            while si < read(node).succs.len():
                let succ = read(node).succs.get(si) else:
                    break
                work.push(read(succ))
                si += 1
    return false


## Fill `ids` with the graph's nodes in reverse post-order from the entry (a
## predecessor-before-successor order for the forward solver).
public function graph_rpo_ids(graph: ref[CfgGraph], ids: ref[vec.Vec[ptr_uint]]) -> void:
    var visited = map_mod.Map[ptr_uint, bool].create()
    defer: visited.release()
    graph_rpo_visit(graph, ref_of(visited), ids, read(graph).entry_id)


function graph_rpo_visit(graph: ref[CfgGraph], visited: ref[map_mod.Map[ptr_uint, bool]], ids: ref[vec.Vec[ptr_uint]], id: ptr_uint) -> void:
    if id == 0:
        return
    if read(visited).contains(id):
        return
    read(visited).set(id, true)
    let node = graph_node(graph, id) else:
        return
    unsafe:
        var si: ptr_uint = 0
        while si < read(node).succs.len():
            let succ = read(node).succs.get(si) else:
                break
            graph_rpo_visit(graph, visited, ids, read(succ))
            si += 1
    ids.push(id)


## Every binding key the graph reads (the host's `all_read_binding_keys`).
public function graph_read_keys(graph: ref[CfgGraph], keys: ref[vec.Vec[ptr_uint]]) -> void:
    var i: ptr_uint = 0
    while i < read(graph).nodes.len():
        let slot = read(graph).nodes.get(i) else:
            break
        let node = unsafe: read(slot)
        unsafe:
            var si: ptr_uint = 0
            while si < read(node).read_sites.len():
                let site = read(node).read_sites.get(si) else:
                    break
                if not id_vec_contains(keys, read(site).key):
                    keys.push(read(site).key)
                si += 1
        i += 1


# =============================================================================
#  The nullability dataflow — the host's `NullabilityFlow.solve`
# =============================================================================

## Allocate the table: `row_size * (node_count + 2)` bits, all clear (the
## host's `initial` state is the empty non-null set).
public function flow_create(row_size: ptr_uint, node_count: ptr_uint) -> NullabilityFlow:
    let total = row_size * (node_count + 2)
    if total == 0:
        return NullabilityFlow(state = null, row_size = row_size, node_count = node_count)
    let raw = heap.must_alloc_zeroed[bool](total)
    let state = unsafe: ptr[bool]<-raw
    return NullabilityFlow(state = state, row_size = row_size, node_count = node_count)


public function flow_release(flow: ref[NullabilityFlow]) -> void:
    let state = read(flow).state else:
        return
    heap.release(state)
    read(flow).state = null


## The host's `Result#nonnull_before(stmt)`: is `key` known non-null on entry to
## the node built from that statement?
public function nonnull_before(flow: ref[NullabilityFlow], node_id: ptr_uint, key: ptr_uint) -> bool:
    if node_id == 0:
        return false
    if key >= read(flow).row_size:
        return false
    if node_id > read(flow).node_count:
        return false
    return flow_get(flow, node_id * read(flow).row_size + key)


## The forward solver: the state is the set of binding ids known non-null, the
## join is set intersection (a binding is non-null after a merge only when it
## is non-null on every incoming path), and the transfer subtracts the node's
## writes then applies the taken edge's refinements.  The entry state is empty.
public function solve_nullability(graph: ref[CfgGraph], flow: ref[NullabilityFlow]) -> void:
    let row = read(flow).row_size
    var ids = vec.Vec[ptr_uint].create()
    defer: ids.release()
    graph_rpo_ids(graph, ref_of(ids))

    let raw = heap.must_alloc_zeroed[bool](row)
    let work = unsafe: ptr[bool]<-raw
    defer: heap.release(work)

    var changed = true
    while changed:
        changed = false
        var ii: ptr_uint = 0
        while ii < ids.len():
            let id_slot = ids.get(ii) else:
                break
            let id = unsafe: read(id_slot)
            let node = graph_node(graph, id) else:
                ii += 1
                continue
            var has_pred = false
            unsafe:
                var pi: ptr_uint = 0
                while pi < read(node).preds.len():
                    let pred_slot = read(node).preds.get(pi) else:
                        break
                    let pred = read(pred_slot)
                    pred_edge_state(graph, flow, pred, id, work, ref_of(has_pred))
                    pi += 1
            if not has_pred or id == read(graph).entry_id:
                clear_row(work, row)
            if flow_state_differs(flow, id, work, row):
                flow_state_store(flow, id, work, row)
                changed = true
            ii += 1


## Compute the state carried by the edge `pred → to` into `work`: the
## predecessor's in-state, minus the predecessor's writes, plus the edge's
## refinements.  `has` records that at least one predecessor contributed, so an
## empty state is not confused with "no predecessor".
function pred_edge_state(graph: ref[CfgGraph], flow: ref[NullabilityFlow], pred: ptr_uint, to: ptr_uint, work: ptr[bool], has: ref[bool]) -> void:
    let row = read(flow).row_size
    let node = graph_node(graph, pred) else:
        return
    var index: ptr_uint = 0
    while index < row:
        let value = flow_get(flow, pred * row + index)
        if read(has):
            if not value:
                unsafe: read(work + index) = false
        else:
            unsafe: read(work + index) = value
        index += 1
    unsafe:
        var wi: ptr_uint = 0
        while wi < read(node).write_sites.len():
            let site = read(node).write_sites.get(wi) else:
                break
            if read(site).key < row:
                read(work + read(site).key) = false
            wi += 1
    var ri: ptr_uint = 0
    while ri < read(graph).edge_refinements.len():
        let r = read(graph).edge_refinements.get(ri) else:
            break
        unsafe:
            if read(r).from == pred and read(r).to == to and read(r).key < row:
                read(work + read(r).key) = read(r).non_null
        ri += 1
    read(has) = true


function clear_row(work: ptr[bool], row: ptr_uint) -> void:
    var index: ptr_uint = 0
    while index < row:
        unsafe:
            read(work + index) = false
        index += 1


function flow_state_differs(flow: ref[NullabilityFlow], id: ptr_uint, work: ptr[bool], row: ptr_uint) -> bool:
    var index: ptr_uint = 0
    while index < row:
        if flow_get(flow, id * row + index) != (unsafe: read(work + index)):
            return true
        index += 1
    return false


function flow_state_store(flow: ref[NullabilityFlow], id: ptr_uint, work: ptr[bool], row: ptr_uint) -> void:
    var index: ptr_uint = 0
    while index < row:
        flow_set(flow, id * row + index, unsafe: read(work + index))
        index += 1


function flow_get(flow: ref[NullabilityFlow], index: ptr_uint) -> bool:
    let state = read(flow).state else:
        return false
    return unsafe: read(state + index)


function flow_set(flow: ref[NullabilityFlow], index: ptr_uint, value: bool) -> void:
    let state = read(flow).state else:
        return
    unsafe:
        read(state + index) = value


# =============================================================================
#  Helpers
# =============================================================================

function id_vec_contains(ids: ref[vec.Vec[ptr_uint]], value: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < ids.len():
        let item = ids.get(i) else:
            break
        if unsafe: read(item) == value:
            return true
        i += 1
    return false
