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

    public editable function clear():
        this.nodes.clear()
        this.edges.clear()

    public editable function release():
        this.nodes.release()
        this.edges.release()
