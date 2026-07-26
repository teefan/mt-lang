import std.vec as vec
import std.deque as deque
import std.mem.heap as heap
import std.binary_heap as heap_mod

const INF: float = 3.4028235e38
const NIL_NODE: ptr_uint = ~(ptr_uint<-0)

public struct Edge:
    from: ptr_uint
    to: ptr_uint
    weight: float

public struct Graph[T]:
    nodes: vec.Vec[T]
    edges: vec.Vec[Edge]
    is_directed: bool

public struct DenseGraph[T]:
    nodes: vec.Vec[T]
    offsets: vec.Vec[ptr_uint]
    targets: vec.Vec[ptr_uint]
    weights: vec.Vec[float]
    is_directed: bool


public struct HeapEntry:
    node: ptr_uint
    dist: float

extending HeapEntry:
    public static function order(a: const_ptr[HeapEntry], b: const_ptr[HeapEntry]) -> int:
        let da = unsafe: read(a).dist
        let db = unsafe: read(b).dist
        if da < db:
            return 1
        else if da > db:
            return -1
        else:
            return 0


public struct ShortestPaths:
    dist: vec.Vec[float]
    prev: vec.Vec[ptr_uint]


extending Graph[T]:
    public static function create() -> Graph[T]:
        return Graph[T](
            nodes = vec.Vec[T].create(),
            edges = vec.Vec[Edge].create(),
            is_directed = false
        )


    public static function create_directed() -> Graph[T]:
        return Graph[T](
            nodes = vec.Vec[T].create(),
            edges = vec.Vec[Edge].create(),
            is_directed = true
        )


    public function node_count() -> ptr_uint:
        return this.nodes.len()


    public function edge_count() -> ptr_uint:
        return this.edges.len()


    public editable function add_node(value: T) -> ptr_uint:
        let index = this.nodes.len()
        this.nodes.push(value)
        return index


    public function get_node(index: ptr_uint) -> T:
        let node_ptr = this.nodes.get(index) else:
            fatal(c"graph.get_node: index out of bounds")
        return unsafe: read(node_ptr)


    public editable function add_edge(from: ptr_uint, to: ptr_uint):
        this.add_weighted_edge(from, to, 1.0)


    public editable function add_weighted_edge(from: ptr_uint, to: ptr_uint, weight: float):
        var e = zero[Edge]
        e.from = from
        e.to = to
        e.weight = weight
        this.edges.push(e)
        if not this.is_directed:
            var rev = zero[Edge]
            rev.from = to
            rev.to = from
            rev.weight = weight
            this.edges.push(rev)


    public function has_edge(from: ptr_uint, to: ptr_uint) -> bool:
        let edge_span = this.edges.as_span()
        var i: ptr_uint = 0
        while i < edge_span.len:
            let e = edge_span[i]
            if e.from == from and e.to == to:
                return true
            i += 1
        return false


    public editable function remove_edge(from: ptr_uint, to: ptr_uint) -> bool:
        let count = this.edges.len()
        var i: ptr_uint = 0
        while i < count:
            let e_ptr = this.edges.get(i) else:
                break
            unsafe:
                if read(e_ptr).from == from and read(e_ptr).to == to:
                    this.edges.swap_remove(i)
                    return true
            i += 1
        return false


    public function neighbors(index: ptr_uint) -> vec.Vec[ptr_uint]:
        var result = vec.Vec[ptr_uint].create()
        let edge_span = this.edges.as_span()
        var i: ptr_uint = 0
        while i < edge_span.len:
            let e = edge_span[i]
            if e.from == index:
                result.push(e.to)
            i += 1
        return result


    public function bfs(start: ptr_uint) -> vec.Vec[ptr_uint]:
        var order = vec.Vec[ptr_uint].create()
        let n = this.node_count()
        if n == 0 or start >= n:
            return order

        var visited = heap.must_alloc_zeroed[ubyte](n)
        var queue = deque.Deque[ptr_uint].create()

        queue.push_back(start)
        unsafe:
            visited[start] = 1

        let edge_span = this.edges.as_span()
        while not queue.is_empty():
            let current = queue.pop_front() else:
                break
            order.push(current)

            var i: ptr_uint = 0
            while i < edge_span.len:
                let e = edge_span[i]
                if e.from == current:
                    unsafe:
                        if visited[e.to] == 0:
                            visited[e.to] = 1
                            queue.push_back(e.to)
                i += 1

        heap.release(visited)
        queue.release()
        return order


    public function dfs(start: ptr_uint) -> vec.Vec[ptr_uint]:
        var order = vec.Vec[ptr_uint].create()
        let n = this.node_count()
        if n == 0 or start >= n:
            return order

        var visited = heap.must_alloc_zeroed[ubyte](n)

        var stack = deque.Deque[ptr_uint].create()
        stack.push_back(start)

        let edge_span = this.edges.as_span()
        while not stack.is_empty():
            let current = stack.pop_back() else:
                break
            unsafe:
                if visited[current] != 0:
                    continue
                visited[current] = 1
            order.push(current)

            var i: ptr_uint = 0
            while i < edge_span.len:
                let e = edge_span[i]
                if e.from == current:
                    unsafe:
                        if visited[e.to] == 0:
                            stack.push_back(e.to)
                i += 1

        heap.release(visited)
        stack.release()
        return order


    public function toposort() -> vec.Vec[ptr_uint]:
        var order = vec.Vec[ptr_uint].create()
        let n = this.node_count()
        if n == 0:
            return order

        var in_degree = heap.must_alloc_zeroed[ptr_uint](n)

        let edge_span = this.edges.as_span()
        var i: ptr_uint = 0
        while i < edge_span.len:
            let e = edge_span[i]
            unsafe:
                in_degree[e.to] += 1
            i += 1

        var queue = deque.Deque[ptr_uint].create()
        i = 0
        while i < n:
            unsafe:
                if in_degree[i] == 0:
                    queue.push_back(i)
            i += 1

        while not queue.is_empty():
            let current = queue.pop_front() else:
                break
            order.push(current)

            var j: ptr_uint = 0
            while j < edge_span.len:
                let e = edge_span[j]
                if e.from == current:
                    unsafe:
                        in_degree[e.to] -= 1
                        if in_degree[e.to] == 0:
                            queue.push_back(e.to)
                j += 1

        heap.release(in_degree)
        queue.release()
        return order


    public function compile() -> DenseGraph[T]:
        let n = this.node_count()
        let m = this.edge_count()

        var offsets = vec.Vec[ptr_uint].with_capacity(n + 1)
        var targets = vec.Vec[ptr_uint].with_capacity(m)
        var weights = vec.Vec[float].with_capacity(m)

        if n == 0:
            return DenseGraph[T](
                nodes = vec.Vec[T].create(),
                offsets = offsets,
                targets = targets,
                weights = weights,
                is_directed = this.is_directed
            )

        var counts = heap.must_alloc[ptr_uint](n)
        var pos = heap.must_alloc[ptr_uint](n)
        var i: ptr_uint = 0
        while i < n:
            unsafe:
                counts[i] = 0
            i += 1

        let edge_span = this.edges.as_span()
        i = 0
        while i < edge_span.len:
            let e = edge_span[i]
            unsafe:
                counts[e.from] += 1
            i += 1

        offsets.push(0)
        i = 0
        while i < n:
            unsafe:
                let total = offsets.get(offsets.len() - 1) else:
                    break
                let accum = read(total) + counts[i]
                pos[i] = read(total)
                offsets.push(accum)
            i += 1

        i = 0
        while i < m:
            targets.push(0)
            weights.push(0.0)
            i += 1

        i = 0
        while i < edge_span.len:
            let e = edge_span[i]
            unsafe:
                let at = pos[e.from]
                let t_ptr = targets.get(at) else:
                    break
                let w_ptr = weights.get(at) else:
                    break
                read(t_ptr) = e.to
                read(w_ptr) = e.weight
                pos[e.from] += 1
            i += 1

        heap.release(counts)
        heap.release(pos)

        # The dense graph owns an independent copy of the node values: Vec
        # copies are shallow (they share the data pointer), so handing
        # `this.nodes` to the DenseGraph directly would double-free when both
        # graphs are released.
        var node_copy = vec.Vec[T].with_capacity(n)
        var old_span = this.nodes.as_span()
        var ci: ptr_uint = 0
        while ci < n:
            unsafe:
                node_copy.push(read(old_span.data + ci))
            ci += 1

        return DenseGraph[T](
            nodes = node_copy,
            offsets = offsets,
            targets = targets,
            weights = weights,
            is_directed = this.is_directed
        )


    public editable function clear():
        this.nodes.clear()
        this.edges.clear()


    public editable function release():
        this.nodes.release()
        this.edges.release()


extending DenseGraph[T]:
    public function node_count() -> ptr_uint:
        return this.nodes.len()


    public function edge_count() -> ptr_uint:
        return this.targets.len()


    public function neighbor_count(node: ptr_uint) -> ptr_uint:
        let n = this.node_count()
        if node >= n:
            return 0
        let start = this.offsets.get(node) else:
            return 0
        let end = this.offsets.get(node + 1) else:
            return 0
        return unsafe: read(end) - read(start)


    public function neighbor_target(node: ptr_uint, index: ptr_uint) -> ptr_uint:
        let start = this.offsets.get(node) else:
            fatal(c"dense_graph.neighbor_target: invalid node")
        let target = this.targets.get(unsafe: read(start) + index) else:
            fatal(c"dense_graph.neighbor_target: invalid neighbor index")
        return unsafe: read(target)


    public function neighbor_weight(node: ptr_uint, index: ptr_uint) -> float:
        let start = this.offsets.get(node) else:
            fatal(c"dense_graph.neighbor_weight: invalid node")
        let weight = this.weights.get(unsafe: read(start) + index) else:
            fatal(c"dense_graph.neighbor_weight: invalid neighbor index")
        return unsafe: read(weight)


    public function has_edge(from: ptr_uint, to: ptr_uint) -> bool:
        let start = this.offsets.get(from) else:
            return false
        let end = this.offsets.get(from + 1) else:
            return false
        let begin = unsafe: read(start)
        let finish = unsafe: read(end)
        var i = begin
        while i < finish:
            let t_ptr = this.targets.get(i) else:
                break
            unsafe:
                if read(t_ptr) == to:
                    return true
            i += 1
        return false


    public function bfs(start: ptr_uint) -> vec.Vec[ptr_uint]:
        var order = vec.Vec[ptr_uint].create()
        let n = this.node_count()
        if n == 0 or start >= n:
            return order

        var visited = heap.must_alloc_zeroed[ubyte](n)
        var queue = deque.Deque[ptr_uint].create()

        queue.push_back(start)
        unsafe:
            visited[start] = 1

        while not queue.is_empty():
            let current = queue.pop_front() else:
                break
            order.push(current)

            let cur_start_ptr = this.offsets.get(current) else:
                break
            let cur_end_ptr = this.offsets.get(current + 1) else:
                break
            let cur_start = unsafe: read(cur_start_ptr)
            let cur_end = unsafe: read(cur_end_ptr)
            var i = cur_start
            while i < cur_end:
                let t_ptr = this.targets.get(i) else:
                    break
                let next = unsafe: read(t_ptr)
                unsafe:
                    if visited[next] == 0:
                        visited[next] = 1
                        queue.push_back(next)
                i += 1

        heap.release(visited)
        queue.release()
        return order


    public function dfs(start: ptr_uint) -> vec.Vec[ptr_uint]:
        var order = vec.Vec[ptr_uint].create()
        let n = this.node_count()
        if n == 0 or start >= n:
            return order

        var visited = heap.must_alloc_zeroed[ubyte](n)
        var stack = deque.Deque[ptr_uint].create()
        stack.push_back(start)

        while not stack.is_empty():
            let current = stack.pop_back() else:
                break
            unsafe:
                if visited[current] != 0:
                    continue
                visited[current] = 1
            order.push(current)

            let cur_start_ptr = this.offsets.get(current) else:
                break
            let cur_end_ptr = this.offsets.get(current + 1) else:
                break
            let cur_start = unsafe: read(cur_start_ptr)
            let cur_end = unsafe: read(cur_end_ptr)
            var i = cur_start
            while i < cur_end:
                let t_ptr = this.targets.get(i) else:
                    break
                let next = unsafe: read(t_ptr)
                unsafe:
                    if visited[next] == 0:
                        stack.push_back(next)
                i += 1

        heap.release(visited)
        stack.release()
        return order


    public function toposort() -> vec.Vec[ptr_uint]:
        var order = vec.Vec[ptr_uint].create()
        let n = this.node_count()
        if n == 0:
            return order

        var in_degree = heap.must_alloc[ptr_uint](n)

        var i: ptr_uint = 0
        while i < n:
            unsafe:
                in_degree[i] = 0
            i += 1

        i = 0
        while i < n:
            let start_ptr = this.offsets.get(i) else:
                break
            let end_ptr = this.offsets.get(i + 1) else:
                break
            let start = unsafe: read(start_ptr)
            let end = unsafe: read(end_ptr)
            var j = start
            while j < end:
                let t_ptr = this.targets.get(j) else:
                    break
                unsafe:
                    in_degree[read(t_ptr)] += 1
                j += 1
            i += 1

        var queue = deque.Deque[ptr_uint].create()
        i = 0
        while i < n:
            unsafe:
                if in_degree[i] == 0:
                    queue.push_back(i)
            i += 1

        while not queue.is_empty():
            let current = queue.pop_front() else:
                break
            order.push(current)

            let cur_start_ptr = this.offsets.get(current) else:
                break
            let cur_end_ptr = this.offsets.get(current + 1) else:
                break
            let cur_start = unsafe: read(cur_start_ptr)
            let cur_end = unsafe: read(cur_end_ptr)
            var k = cur_start
            while k < cur_end:
                let t_ptr = this.targets.get(k) else:
                    break
                let next = unsafe: read(t_ptr)
                unsafe:
                    in_degree[next] -= 1
                    if in_degree[next] == 0:
                        queue.push_back(next)
                k += 1

        heap.release(in_degree)
        queue.release()
        return order


    public function dijkstra(source: ptr_uint) -> ShortestPaths:
        var dist = vec.Vec[float].with_capacity(this.node_count())
        var prev = vec.Vec[ptr_uint].with_capacity(this.node_count())
        let n = this.node_count()

        var i: ptr_uint = 0
        while i < n:
            dist.push(INF)
            prev.push(NIL_NODE)
            i += 1

        if n == 0 or source >= n:
            return ShortestPaths(dist = dist, prev = prev)

        let src_dist_ptr = dist.get(source) else:
            return ShortestPaths(dist = dist, prev = prev)
        unsafe:
            read(src_dist_ptr) = 0.0

        var pq = heap_mod.BinaryHeap[HeapEntry].create()
        pq.push(HeapEntry(node = source, dist = 0.0))

        while not pq.is_empty():
            let entry = pq.pop() else:
                break
            let u = entry.node
            let d = entry.dist

            let cur_dist_ptr = dist.get(u) else:
                break
            if d > unsafe: read(cur_dist_ptr):
                continue

            let start_ptr = this.offsets.get(u) else:
                break
            let end_ptr = this.offsets.get(u + 1) else:
                break
            let start = unsafe: read(start_ptr)
            let end = unsafe: read(end_ptr)
            var j = start
            while j < end:
                let t_ptr = this.targets.get(j) else:
                    break
                let w_ptr = this.weights.get(j) else:
                    break
                let v = unsafe: read(t_ptr)
                let weight = unsafe: read(w_ptr)
                let new_dist = d + weight

                let v_dist_ptr = dist.get(v) else:
                    continue
                if new_dist < unsafe: read(v_dist_ptr):
                    unsafe:
                        read(v_dist_ptr) = new_dist
                    let v_prev_ptr = prev.get(v) else:
                        continue
                    unsafe:
                        read(v_prev_ptr) = u
                    pq.push(HeapEntry(node = v, dist = new_dist))
                j += 1

        pq.release()
        return ShortestPaths(dist = dist, prev = prev)


    public function astar(source: ptr_uint, target: ptr_uint, heuristic: fn(node: ptr_uint) -> float) -> vec.Vec[ptr_uint]:
        var path = vec.Vec[ptr_uint].create()
        let n = this.node_count()
        if n == 0 or source >= n or target >= n:
            return path

        var g_score = heap.must_alloc[float](n)
        var came_from = heap.must_alloc[ptr_uint](n)
        var i: ptr_uint = 0
        while i < n:
            unsafe:
                g_score[i] = INF
                came_from[i] = NIL_NODE
            i += 1
        unsafe:
            g_score[source] = 0.0

        var pq = heap_mod.BinaryHeap[HeapEntry].create()
        pq.push(HeapEntry(node = source, dist = heuristic(source)))

        while not pq.is_empty():
            let entry = pq.pop() else:
                break
            let u = entry.node

            if u == target:
                var cur = target
                while cur != source:
                    path.push(cur)
                    unsafe:
                        cur = came_from[cur]
                path.push(source)
                var li: ptr_uint = 0
                var lj = path.len()
                if lj > 0:
                    lj -= 1
                while li < lj:
                    let a_ptr = path.get(li) else:
                        break
                    let b_ptr = path.get(lj) else:
                        break
                    let tmp = unsafe: read(a_ptr)
                    unsafe:
                        read(a_ptr) = unsafe: read(b_ptr)
                        read(b_ptr) = tmp
                    li += 1
                    lj -= 1
                break

            let cur_g = unsafe: g_score[u]

            let start_ptr = this.offsets.get(u) else:
                break
            let end_ptr = this.offsets.get(u + 1) else:
                break
            let start = unsafe: read(start_ptr)
            let end = unsafe: read(end_ptr)
            var j = start
            while j < end:
                let t_ptr = this.targets.get(j) else:
                    break
                let w_ptr = this.weights.get(j) else:
                    break
                let v = unsafe: read(t_ptr)
                let weight = unsafe: read(w_ptr)
                let tentative_g = cur_g + weight

                if tentative_g < unsafe: g_score[v]:
                    unsafe:
                        g_score[v] = tentative_g
                        came_from[v] = u
                    pq.push(HeapEntry(node = v, dist = tentative_g + heuristic(v)))
                j += 1

        pq.release()
        heap.release(g_score)
        heap.release(came_from)
        return path


    public editable function release():
        this.nodes.release()
        this.offsets.release()
        this.targets.release()
        this.weights.release()


extending ShortestPaths:
    public function distance_to(node: ptr_uint) -> float:
        let d_ptr = this.dist.get(node) else:
            return INF
        return unsafe: read(d_ptr)


    public function has_path_to(node: ptr_uint) -> bool:
        let d_ptr = this.dist.get(node) else:
            return false
        return unsafe: read(d_ptr) < INF


    public function path_to(target: ptr_uint) -> vec.Vec[ptr_uint]:
        var path = vec.Vec[ptr_uint].create()
        if target >= this.dist.len():
            return path

        let d_ptr = this.dist.get(target) else:
            return path
        if unsafe: read(d_ptr) >= INF:
            return path

        var cur = target
        path.push(cur)
        let nil = NIL_NODE
        while cur != nil:
            let p_ptr = this.prev.get(cur) else:
                break
            cur = unsafe: read(p_ptr)
            if cur == nil:
                break
            path.push(cur)

        var i: ptr_uint = 0
        var j = path.len()
        if j > 0:
            j -= 1
        while i < j:
            let a_ptr = path.get(i) else:
                break
            let b_ptr = path.get(j) else:
                break
            let tmp = unsafe: read(a_ptr)
            unsafe:
                read(a_ptr) = unsafe: read(b_ptr)
                read(b_ptr) = tmp
            i += 1
            j -= 1

        return path


    public editable function release():
        this.dist.release()
        this.prev.release()
