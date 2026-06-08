## Milk Tea Data Structure Baseline
##
## Exercises all standard library data structure modules.
## Uses std.hash for primitive type hash/order hooks.

import std.hash
import std.str
import std.vec as vec
import std.deque as deque
import std.queue as fifo
import std.stack as lifo
import std.binary_heap as heap_mod
import std.priority_queue as pq_mod
import std.map as ht
import std.set as hset
import std.ordered_map as omap
import std.ordered_set as oset
import std.linked_map as lmap
import std.linked_set as lset
import std.counter as counter_mod
import std.multiset as mset
import std.graph as gmod

# ---------------------------------------------------------------------------
# 1  Vec[T] — contiguous dynamic array
# ---------------------------------------------------------------------------

function vec_demo() -> int:
    var v = vec.Vec[int].create()
    v.push(10)
    v.push(20)
    v.push(30)
    let elem = v.get(1)
    let _elem = elem
    v.release()
    return 1

# ---------------------------------------------------------------------------
# 2  Deque[T] — double-ended ring buffer
# ---------------------------------------------------------------------------

function deque_demo() -> int:
    var d = deque.Deque[int].create()
    d.push_back(10)
    d.push_front(5)
    d.push_back(20)
    let first = d.get(0)
    let _first = first
    d.release()
    return 1

# ---------------------------------------------------------------------------
# 3  Queue[T] — FIFO facade over Deque
# ---------------------------------------------------------------------------

function queue_demo() -> int:
    var q = fifo.Queue[int].with_capacity(4)
    q.enqueue(1)
    q.enqueue(2)
    let result = q.dequeue()
    q.release()
    return 1

# ---------------------------------------------------------------------------
# 4  Stack[T] — LIFO facade over Deque
# ---------------------------------------------------------------------------

function stack_demo() -> int:
    var s = lifo.Stack[int].with_capacity(4)
    s.push(1)
    s.push(2)
    let result = s.pop()
    s.release()
    return 1

# ---------------------------------------------------------------------------
# 5  BinaryHeap[T] — max-heap keyed by order[T]
# ---------------------------------------------------------------------------

function heap_demo() -> int:
    var h = heap_mod.BinaryHeap[int].create()
    h.push(30)
    h.push(10)
    h.push(20)
    let result = h.pop()
    h.release()
    return 1

# ---------------------------------------------------------------------------
# 6  PriorityQueue[T] — task facade over BinaryHeap
# ---------------------------------------------------------------------------

function priority_queue_demo() -> int:
    var q = pq_mod.PriorityQueue[int].create()
    q.enqueue(15)
    q.enqueue(5)
    q.enqueue(10)
    let result = q.dequeue()
    q.release()
    return 1

# ---------------------------------------------------------------------------
# 7  Map[K,V] — hash table
# ---------------------------------------------------------------------------

function map_demo() -> int:
    var m = ht.Map[str, int].create()
    m.set("x", 10)
    m.set("y", 20)
    let val = m.get("y")
    let _val = val
    m.release()
    return 1

# ---------------------------------------------------------------------------
# 8  Set[T] — hash set
# ---------------------------------------------------------------------------

function set_demo() -> int:
    var s = hset.Set[int].create()
    s.insert(1)
    s.insert(2)
    s.insert(3)
    s.remove(2)
    let has = s.contains(1)
    let _has = has
    s.release()
    return 1

# ---------------------------------------------------------------------------
# 9  OrderedMap[K,V] — AVL-backed ordered map
# ---------------------------------------------------------------------------

function ordered_map_demo() -> int:
    var m = omap.OrderedMap[int, str].create()
    m.set(3, "three")
    m.set(1, "one")
    let val = m.get(1)
    let _val = val
    m.release()
    return 1

# ---------------------------------------------------------------------------
# 10  OrderedSet[T] — AVL-backed ordered set
# ---------------------------------------------------------------------------

function ordered_set_demo() -> int:
    var s = oset.OrderedSet[int].create()
    s.insert(3)
    s.insert(1)
    s.insert(2)
    let has = s.contains(1)
    let _has = has
    s.release()
    return 1

# ---------------------------------------------------------------------------
# 11  LinkedMap[K,V] — insertion-ordered hash map
# ---------------------------------------------------------------------------

function linked_map_demo() -> int:
    var m = lmap.LinkedMap[str, int].create()
    m.set("c", 30)
    m.set("a", 10)
    m.set("b", 20)
    let val = m.get("a")
    let _val = val
    m.release()
    return 1

# ---------------------------------------------------------------------------
# 12  LinkedSet[T] — insertion-ordered hash set
# ---------------------------------------------------------------------------

function linked_set_demo() -> int:
    var s = lset.LinkedSet[int].create()
    s.insert(3)
    s.insert(1)
    s.insert(2)
    let has = s.contains(2)
    let _has = has
    s.release()
    return 1

# ---------------------------------------------------------------------------
# 13  Counter[T] — frequency table
# ---------------------------------------------------------------------------

function counter_demo() -> int:
    var c = counter_mod.Counter[int].create()
    c.increment(1)
    c.increment(1)
    c.increment(2)
    let total = c.total_count()
    let cnt = c.count(1)
    let _cnt = cnt
    c.release()
    return int<-(total)

# ---------------------------------------------------------------------------
# 14  MultiSet[T] — bag
# ---------------------------------------------------------------------------

function multiset_demo() -> int:
    var s = mset.MultiSet[int].create()
    s.insert(1)
    s.insert(1)
    s.insert(2)
    let total = s.total_count()
    let distinct = s.distinct_len()
    let _distinct = distinct
    s.release()
    return int<-(total)

# ---------------------------------------------------------------------------
# 15  SoA[T,N] — Structure of Arrays
# ---------------------------------------------------------------------------

struct Point:
    x: float
    y: float
    z: float


function soa_demo() -> float:
    var particles: SoA[Point, 4]
    particles[0].x = 1.0
    particles[0].y = 5.0
    particles[1].x = 2.0
    particles[2].x = 3.0
    return particles[0].x + particles[1].x

# ---------------------------------------------------------------------------
# 16  Graph[T] — adjacency list + DenseGraph compile
# ---------------------------------------------------------------------------

function graph_demo() -> int:
    var g = gmod.Graph[str].create_directed()
    let a = g.add_node("start")
    let b = g.add_node("middle")
    let c = g.add_node("end")
    g.add_edge(a, b)
    g.add_weighted_edge(b, c, 2.5)
    let nc = g.node_count()
    let ec = g.edge_count()

    var dg = g.compile()
    var bfs = dg.bfs(a)
    let ncount = dg.neighbor_count(a)

    bfs.release()
    dg.release()
    g.release()
    let _ec = ec
    return int<-(nc + ncount)

# ---------------------------------------------------------------------------
# 17  Entrypoint
# ---------------------------------------------------------------------------

function main() -> int:
    var total: int = 0
    total += vec_demo()
    total += deque_demo()
    total += queue_demo()
    total += stack_demo()
    total += heap_demo()
    total += priority_queue_demo()
    total += map_demo()
    total += set_demo()
    total += ordered_map_demo()
    total += ordered_set_demo()
    total += linked_map_demo()
    total += linked_set_demo()
    total += counter_demo()
    total += multiset_demo()
    total += int<-(soa_demo())
    total += graph_demo()
    return total
