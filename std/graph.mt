import std.vec as vec
import std.deque as deque
import std.mem.heap as heap

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

        var visited = heap.must_alloc[ubyte](n)
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

        var visited = heap.must_alloc[ubyte](n)

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

        var in_degree = heap.must_alloc[ptr_uint](n)

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

        return DenseGraph[T](
            nodes = this.nodes,
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

        var visited = heap.must_alloc[ubyte](n)
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

        var visited = heap.must_alloc[ubyte](n)
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


    public editable function release():
        this.nodes.release()
        this.offsets.release()
        this.targets.release()
        this.weights.release()
