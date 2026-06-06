import std.mem.heap as heap

struct Node[K, V]:
    key: K
    value: V
    left: ptr[Node[K, V]]?
    right: ptr[Node[K, V]]?
    parent: ptr[Node[K, V]]?
    height: int

struct SearchResult[K, V]:
    node: ptr[Node[K, V]]?
    parent: ptr[Node[K, V]]?
    compare: int
    found: bool

public struct Entry[K, V]:
    key: const_ptr[K]
    value: ptr[V]

public struct RemovedEntry[K, V]:
    key: K
    value: V

public struct Keys[K, V]:
    node: ptr[Node[K, V]]?

public struct Values[K, V]:
    node: ptr[Node[K, V]]?

public struct Entries[K, V]:
    node: ptr[Node[K, V]]?
    started: bool

public struct OrderedMap[K, V]:
    root: ptr[Node[K, V]]?
    len: ptr_uint


extending OrderedMap[K, V]:
    public static function create() -> OrderedMap[K, V]:
        return OrderedMap[K, V](root = null, len = 0)


    static function height(node: ptr[Node[K, V]]?) -> int:
        if node == null:
            return 0

        unsafe:
            return read(ptr[Node[K, V]]<-node).height


    static function update_height(node: ptr[Node[K, V]]) -> void:
        let left_height = unsafe: OrderedMap[K, V].height(read(node).left)
        let right_height = unsafe: OrderedMap[K, V].height(read(node).right)
        var next_height = left_height
        if right_height > next_height:
            next_height = right_height

        unsafe:
            read(node).height = next_height + 1


    static function balance_factor(node: ptr[Node[K, V]]?) -> int:
        if node == null:
            return 0

        unsafe:
            return OrderedMap[
                K,
                V
            ].height(read(ptr[Node[K, V]]<-node).left) - OrderedMap[K, V].height(read(ptr[Node[K, V]]<-node).right)


    static function minimum(node: ptr[Node[K, V]]?) -> ptr[Node[K, V]]?:
        var current = node
        while current != null:
            let left = unsafe: read(ptr[Node[K, V]]<-current).left else:
                return current

            current = left

        return null


    static function successor(node: ptr[Node[K, V]]?) -> ptr[Node[K, V]]?:
        if node == null:
            return null

        let current = unsafe: ptr[Node[K, V]]<-node
        let right = unsafe: read(current).right
        if right != null:
            return OrderedMap[K, V].minimum(right)

        var child = node
        var parent = unsafe: read(current).parent
        while parent != null:
            let parent_ptr = unsafe: ptr[Node[K, V]]<-parent
            if unsafe: read(parent_ptr).left == child:
                return parent

            child = parent
            parent = unsafe: read(parent_ptr).parent

        return null


    static function replace_child(
        current: ref[OrderedMap[K, V]],
        parent: ptr[Node[K, V]]?,
        previous: ptr[Node[K, V]],
        replacement: ptr[Node[K, V]]?
    ) -> void:
        if parent == null:
            current.root = replacement
        else:
            unsafe:
                let parent_ptr = ptr[Node[K, V]]<-parent
                if read(parent_ptr).left == previous:
                    read(parent_ptr).left = replacement
                else if read(parent_ptr).right == previous:
                    read(parent_ptr).right = replacement
                else:
                    fatal(c"ordered_map.OrderedMap.replace_child missing previous child")

        if replacement != null:
            unsafe:
                read(ptr[Node[K, V]]<-replacement).parent = parent


    static function rotate_left(current: ref[OrderedMap[K, V]], node: ptr[Node[K, V]]) -> ptr[Node[K, V]]:
        let pivot = unsafe: read(node).right else:
            fatal(c"ordered_map.OrderedMap.rotate_left missing pivot")

        let pivot_ptr = unsafe: ptr[Node[K, V]]<-pivot
        let parent = unsafe: read(node).parent
        let pivot_left = unsafe: read(pivot_ptr).left

        unsafe:
            read(node).right = pivot_left
        if pivot_left != null:
            unsafe:
                read(ptr[Node[K, V]]<-pivot_left).parent = node

        OrderedMap[K, V].replace_child(current, parent, node, pivot)

        unsafe:
            read(pivot_ptr).left = node
            read(node).parent = pivot

        OrderedMap[K, V].update_height(node)
        OrderedMap[K, V].update_height(pivot_ptr)
        return pivot_ptr


    static function rotate_right(current: ref[OrderedMap[K, V]], node: ptr[Node[K, V]]) -> ptr[Node[K, V]]:
        let pivot = unsafe: read(node).left else:
            fatal(c"ordered_map.OrderedMap.rotate_right missing pivot")

        let pivot_ptr = unsafe: ptr[Node[K, V]]<-pivot
        let parent = unsafe: read(node).parent
        let pivot_right = unsafe: read(pivot_ptr).right

        unsafe:
            read(node).left = pivot_right
        if pivot_right != null:
            unsafe:
                read(ptr[Node[K, V]]<-pivot_right).parent = node

        OrderedMap[K, V].replace_child(current, parent, node, pivot)

        unsafe:
            read(pivot_ptr).right = node
            read(node).parent = pivot

        OrderedMap[K, V].update_height(node)
        OrderedMap[K, V].update_height(pivot_ptr)
        return pivot_ptr


    static function rebalance(current: ref[OrderedMap[K, V]], node: ptr[Node[K, V]]?) -> void:
        var cursor = node
        while cursor != null:
            let cursor_ptr = unsafe: ptr[Node[K, V]]<-cursor
            OrderedMap[K, V].update_height(cursor_ptr)

            let balance = OrderedMap[K, V].balance_factor(cursor)
            if balance > 1:
                let left = unsafe: read(cursor_ptr).left
                if OrderedMap[K, V].balance_factor(left) < 0:
                    if left == null:
                        fatal(c"ordered_map.OrderedMap.rebalance missing left child")
                    OrderedMap[K, V].rotate_left(current, unsafe: ptr[Node[K, V]]<-left)

                let rotated = OrderedMap[K, V].rotate_right(current, cursor_ptr)
                cursor = unsafe: read(rotated).parent
            else if balance < -1:
                let right = unsafe: read(cursor_ptr).right
                if OrderedMap[K, V].balance_factor(right) > 0:
                    if right == null:
                        fatal(c"ordered_map.OrderedMap.rebalance missing right child")
                    OrderedMap[K, V].rotate_right(current, unsafe: ptr[Node[K, V]]<-right)

                let rotated = OrderedMap[K, V].rotate_left(current, cursor_ptr)
                cursor = unsafe: read(rotated).parent
            else:
                cursor = unsafe: read(cursor_ptr).parent


    static function locate(current: OrderedMap[K, V], key: K) -> SearchResult[K, V]:
        var parent: ptr[Node[K, V]]? = null
        var node = current.root
        var compare = 0
        while node != null:
            let node_ptr = unsafe: ptr[Node[K, V]]<-node
            let stored = unsafe: const_ptr_of(read(node_ptr).key)
            compare = order[K](key, stored)
            if compare < 0:
                parent = node
                unsafe:
                    node = read(node_ptr).left
            else if compare > 0:
                parent = node
                unsafe:
                    node = read(node_ptr).right
            else:
                return SearchResult[K, V](node = node, parent = parent, compare = 0, found = true)

        return SearchResult[K, V](node = null, parent = parent, compare = compare, found = false)


    static function release_subtree(node: ptr[Node[K, V]]?) -> void:
        if node == null:
            return

        let node_ptr = unsafe: ptr[Node[K, V]]<-node
        let left = unsafe: read(node_ptr).left
        let right = unsafe: read(node_ptr).right
        OrderedMap[K, V].release_subtree(left)
        OrderedMap[K, V].release_subtree(right)
        heap.release(node)


    static function detach_node(current: ref[OrderedMap[K, V]], node: ptr[Node[K, V]]) -> ptr[Node[K, V]]?:
        let left = unsafe: read(node).left
        let right = unsafe: read(node).right
        if left != null and right != null:
            let successor = OrderedMap[K, V].minimum(right) else:
                fatal(c"ordered_map.OrderedMap.detach_node missing successor")

            let successor_ptr = unsafe: ptr[Node[K, V]]<-successor
            unsafe:
                read(node).key = read(successor_ptr).key
                read(node).value = read(successor_ptr).value

            return OrderedMap[K, V].detach_node(current, successor_ptr)

        var child = left
        if child == null:
            child = right

        let parent = unsafe: read(node).parent
        OrderedMap[K, V].replace_child(current, parent, node, child)
        heap.release(node)

        if parent != null:
            return parent

        return child


    public function len() -> ptr_uint:
        return this.len


    public function is_empty() -> bool:
        return this.len == 0


    public function get(key: K) -> ptr[V]?:
        let location = OrderedMap[K, V].locate(this, key)
        if not location.found:
            return null

        let node = location.node else:
            fatal(c"ordered_map.OrderedMap.get missing node")

        unsafe:
            return ptr_of(read(ptr[Node[K, V]]<-node).value)


    public function get_key(key: K) -> const_ptr[K]?:
        let location = OrderedMap[K, V].locate(this, key)
        if not location.found:
            return null

        let node = location.node else:
            fatal(c"ordered_map.OrderedMap.get_key missing node")

        unsafe:
            return const_ptr_of(read(ptr[Node[K, V]]<-node).key)


    public function iter() -> Entries[K, V]:
        return this.entries()


    public function keys() -> Keys[K, V]:
        return Keys[K, V](node = OrderedMap[K, V].minimum(this.root))


    public function values() -> Values[K, V]:
        return Values[K, V](node = OrderedMap[K, V].minimum(this.root))


    public function entries() -> Entries[K, V]:
        return Entries[K, V](node = OrderedMap[K, V].minimum(this.root), started = false)


    public function contains(key: K) -> bool:
        return this.get(key) != null


    public editable function clear() -> void:
        OrderedMap[K, V].release_subtree(this.root)
        this.root = null
        this.len = 0


    public editable function release() -> void:
        this.clear()


    public editable function set(key: K, value: V) -> Option[V]:
        let location = OrderedMap[K, V].locate(this, key)
        if location.found:
            let node = location.node else:
                fatal(c"ordered_map.OrderedMap.set missing node")

            unsafe:
                let node_ptr = ptr[Node[K, V]]<-node
                let previous = read(node_ptr).value
                read(node_ptr).value = value
                return Option[V].some(value = previous)

        let node = heap.must_alloc[Node[K, V]](1)
        unsafe:
            read(node) = Node[K, V](
                key = key,
                value = value,
                left = null,
                right = null,
                parent = location.parent,
                height = 1
            )

        let parent = location.parent
        if parent == null:
            this.root = node
        else:
            unsafe:
                let parent_ptr = ptr[Node[K, V]]<-parent
                if location.compare < 0:
                    read(parent_ptr).left = node
                else:
                    read(parent_ptr).right = node

        this.len += 1
        OrderedMap[K, V].rebalance(this, parent)
        return Option[V].none


    public editable function get_or_insert(key: K, value: V) -> ptr[V]:
        let location = OrderedMap[K, V].locate(this, key)
        if location.found:
            let node = location.node else:
                fatal(c"ordered_map.OrderedMap.get_or_insert missing node")

            unsafe:
                return ptr_of(read(ptr[Node[K, V]]<-node).value)

        let node = heap.must_alloc[Node[K, V]](1)
        unsafe:
            read(node) = Node[K, V](
                key = key,
                value = value,
                left = null,
                right = null,
                parent = location.parent,
                height = 1
            )

        let parent = location.parent
        if parent == null:
            this.root = node
        else:
            unsafe:
                let parent_ptr = ptr[Node[K, V]]<-parent
                if location.compare < 0:
                    read(parent_ptr).left = node
                else:
                    read(parent_ptr).right = node

        this.len += 1
        OrderedMap[K, V].rebalance(this, parent)

        unsafe:
            return ptr_of(read(node).value)


    public editable function remove_entry(key: K) -> Option[RemovedEntry[K, V]]:
        let location = OrderedMap[K, V].locate(this, key)
        if not location.found:
            return Option[RemovedEntry[K, V]].none

        let node = location.node else:
            fatal(c"ordered_map.OrderedMap.remove_entry missing node")

        let node_ptr = unsafe: ptr[Node[K, V]]<-node
        let removed = unsafe: RemovedEntry[K, V](key = read(node_ptr).key, value = read(node_ptr).value)
        let rebalance_from = OrderedMap[K, V].detach_node(this, node_ptr)
        this.len -= 1
        OrderedMap[K, V].rebalance(this, rebalance_from)
        return Option[RemovedEntry[K, V]].some(value = removed)


    public editable function remove(key: K) -> Option[V]:
        let removed = this.remove_entry(key)
        match removed:
            Option.none:
                return Option[V].none
            Option.some as payload:
                return Option[V].some(value = payload.value.value)


extending Keys[K, V]:
    public function iter() -> Keys[K, V]:
        return this


    public editable function next() -> const_ptr[K]?:
        let current = this.node else:
            return null

        this.node = OrderedMap[K, V].successor(current)

        unsafe:
            return const_ptr_of(read(ptr[Node[K, V]]<-current).key)


extending Values[K, V]:
    public function iter() -> Values[K, V]:
        return this


    public editable function next() -> ptr[V]?:
        let current = this.node else:
            return null

        this.node = OrderedMap[K, V].successor(current)

        unsafe:
            return ptr_of(read(ptr[Node[K, V]]<-current).value)


extending Entries[K, V]:
    public function iter() -> Entries[K, V]:
        return this


    public editable function next() -> bool:
        let current = this.node else:
            return false

        if not this.started:
            this.started = true
            return true

        let next = OrderedMap[K, V].successor(current)
        this.node = next
        return next != null


    public function current() -> Entry[K, V]:
        let current = this.node
        if current == null or not this.started:
            fatal(c"ordered_map.Entries.current missing current node")

        unsafe:
            let node_ptr = ptr[Node[K, V]]<-current
            return Entry[K, V](key = const_ptr_of(read(node_ptr).key), value = ptr_of(read(node_ptr).value))
