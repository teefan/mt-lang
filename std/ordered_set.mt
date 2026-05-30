import std.mem.heap as heap

struct Node[T]:
    value: T
    left: ptr[Node[T]]?
    right: ptr[Node[T]]?
    parent: ptr[Node[T]]?
    height: int

struct SearchResult[T]:
    node: ptr[Node[T]]?
    parent: ptr[Node[T]]?
    compare: int
    found: bool

public struct Iter[T]:
    node: ptr[Node[T]]?

public struct OrderedSet[T]:
    root: ptr[Node[T]]?
    len: ptr_uint


extending OrderedSet[T]:
    public static function create() -> OrderedSet[T]:
        return OrderedSet[T](root = null, len = 0)


    static function height(node: ptr[Node[T]]?) -> int:
        if node == null:
            return 0

        unsafe:
            return read(ptr[Node[T]]<-node).height


    static function update_height(node: ptr[Node[T]]) -> void:
        let left_height = unsafe: OrderedSet[T].height(read(node).left)
        let right_height = unsafe: OrderedSet[T].height(read(node).right)
        var next_height = left_height
        if right_height > next_height:
            next_height = right_height

        unsafe:
            read(node).height = next_height + 1


    static function balance_factor(node: ptr[Node[T]]?) -> int:
        if node == null:
            return 0

        unsafe:
            return OrderedSet[T].height(read(ptr[Node[T]]<-node).left) - OrderedSet[T].height(read(ptr[Node[T]]<-node).right)


    static function minimum(node: ptr[Node[T]]?) -> ptr[Node[T]]?:
        var current = node
        while current != null:
            let left = unsafe: read(ptr[Node[T]]<-current).left else:
                return current

            current = left

        return null


    static function successor(node: ptr[Node[T]]?) -> ptr[Node[T]]?:
        if node == null:
            return null

        let current = unsafe: ptr[Node[T]]<-node
        let right = unsafe: read(current).right
        if right != null:
            return OrderedSet[T].minimum(right)

        var child = node
        var parent = unsafe: read(current).parent
        while parent != null:
            let parent_ptr = unsafe: ptr[Node[T]]<-parent
            if unsafe: read(parent_ptr).left == child:
                return parent

            child = parent
            parent = unsafe: read(parent_ptr).parent

        return null


    static function replace_child(
        current: ref[OrderedSet[T]],
        parent: ptr[Node[T]]?,
        previous: ptr[Node[T]],
        replacement: ptr[Node[T]]?
    ) -> void:
        if parent == null:
            current.root = replacement
        else:
            unsafe:
                let parent_ptr = ptr[Node[T]]<-parent
                if read(parent_ptr).left == previous:
                    read(parent_ptr).left = replacement
                else if read(parent_ptr).right == previous:
                    read(parent_ptr).right = replacement
                else:
                    fatal(c"ordered_set.OrderedSet.replace_child missing previous child")

        if replacement != null:
            unsafe:
                read(ptr[Node[T]]<-replacement).parent = parent


    static function rotate_left(current: ref[OrderedSet[T]], node: ptr[Node[T]]) -> ptr[Node[T]]:
        let pivot = unsafe: read(node).right else:
            fatal(c"ordered_set.OrderedSet.rotate_left missing pivot")

        let pivot_ptr = unsafe: ptr[Node[T]]<-pivot
        let parent = unsafe: read(node).parent
        let pivot_left = unsafe: read(pivot_ptr).left

        unsafe:
            read(node).right = pivot_left
        if pivot_left != null:
            unsafe:
                read(ptr[Node[T]]<-pivot_left).parent = node

        OrderedSet[T].replace_child(current, parent, node, pivot)

        unsafe:
            read(pivot_ptr).left = node
            read(node).parent = pivot

        OrderedSet[T].update_height(node)
        OrderedSet[T].update_height(pivot_ptr)
        return pivot_ptr


    static function rotate_right(current: ref[OrderedSet[T]], node: ptr[Node[T]]) -> ptr[Node[T]]:
        let pivot = unsafe: read(node).left else:
            fatal(c"ordered_set.OrderedSet.rotate_right missing pivot")

        let pivot_ptr = unsafe: ptr[Node[T]]<-pivot
        let parent = unsafe: read(node).parent
        let pivot_right = unsafe: read(pivot_ptr).right

        unsafe:
            read(node).left = pivot_right
        if pivot_right != null:
            unsafe:
                read(ptr[Node[T]]<-pivot_right).parent = node

        OrderedSet[T].replace_child(current, parent, node, pivot)

        unsafe:
            read(pivot_ptr).right = node
            read(node).parent = pivot

        OrderedSet[T].update_height(node)
        OrderedSet[T].update_height(pivot_ptr)
        return pivot_ptr


    static function rebalance(current: ref[OrderedSet[T]], node: ptr[Node[T]]?) -> void:
        var cursor = node
        while cursor != null:
            let cursor_ptr = unsafe: ptr[Node[T]]<-cursor
            OrderedSet[T].update_height(cursor_ptr)

            let balance = OrderedSet[T].balance_factor(cursor)
            if balance > 1:
                let left = unsafe: read(cursor_ptr).left
                if OrderedSet[T].balance_factor(left) < 0:
                    if left == null:
                        fatal(c"ordered_set.OrderedSet.rebalance missing left child")
                    OrderedSet[T].rotate_left(current, unsafe: ptr[Node[T]]<-left)

                let rotated = OrderedSet[T].rotate_right(current, cursor_ptr)
                cursor = unsafe: read(rotated).parent
            else if balance < -1:
                let right = unsafe: read(cursor_ptr).right
                if OrderedSet[T].balance_factor(right) > 0:
                    if right == null:
                        fatal(c"ordered_set.OrderedSet.rebalance missing right child")
                    OrderedSet[T].rotate_right(current, unsafe: ptr[Node[T]]<-right)

                let rotated = OrderedSet[T].rotate_left(current, cursor_ptr)
                cursor = unsafe: read(rotated).parent
            else:
                cursor = unsafe: read(cursor_ptr).parent


    static function locate(current: OrderedSet[T], value: T) -> SearchResult[T]:
        var parent: ptr[Node[T]]? = null
        var node = current.root
        var compare = 0
        while node != null:
            let node_ptr = unsafe: ptr[Node[T]]<-node
            let stored = unsafe: const_ptr_of(read(node_ptr).value)
            compare = order[T](value, stored)
            if compare < 0:
                parent = node
                unsafe:
                    node = read(node_ptr).left
            else if compare > 0:
                parent = node
                unsafe:
                    node = read(node_ptr).right
            else:
                return SearchResult[T](node = node, parent = parent, compare = 0, found = true)

        return SearchResult[T](node = null, parent = parent, compare = compare, found = false)


    static function release_subtree(node: ptr[Node[T]]?) -> void:
        if node == null:
            return

        let node_ptr = unsafe: ptr[Node[T]]<-node
        let left = unsafe: read(node_ptr).left
        let right = unsafe: read(node_ptr).right
        OrderedSet[T].release_subtree(left)
        OrderedSet[T].release_subtree(right)
        heap.release(node)


    static function detach_node(current: ref[OrderedSet[T]], node: ptr[Node[T]]) -> ptr[Node[T]]?:
        let left = unsafe: read(node).left
        let right = unsafe: read(node).right
        if left != null and right != null:
            let successor = OrderedSet[T].minimum(right) else:
                fatal(c"ordered_set.OrderedSet.detach_node missing successor")

            unsafe:
                read(node).value = read(ptr[Node[T]]<-successor).value

            return OrderedSet[T].detach_node(current, unsafe: ptr[Node[T]]<-successor)

        var child = left
        if child == null:
            child = right

        let parent = unsafe: read(node).parent
        OrderedSet[T].replace_child(current, parent, node, child)
        heap.release(node)

        if parent != null:
            return parent

        return child


    public function len() -> ptr_uint:
        return this.len


    public function is_empty() -> bool:
        return this.len == 0


    public function get(value: T) -> const_ptr[T]?:
        let location = OrderedSet[T].locate(this, value)
        if not location.found:
            return null

        let candidate = location.node else:
            fatal(c"ordered_set.OrderedSet.get missing node")

        unsafe:
            return const_ptr_of(read(ptr[Node[T]]<-candidate).value)


    public function contains(value: T) -> bool:
        return this.get(value) != null


    public function iter() -> Iter[T]:
        return Iter[T](node = OrderedSet[T].minimum(this.root))


    public mutable function clear() -> void:
        OrderedSet[T].release_subtree(this.root)
        this.root = null
        this.len = 0


    public mutable function release() -> void:
        this.clear()


    public mutable function insert(value: T) -> bool:
        let location = OrderedSet[T].locate(this, value)
        if location.found:
            return false

        let node = heap.must_alloc[Node[T]](1)
        unsafe:
            read(node) = Node[T](value = value, left = null, right = null, parent = location.parent, height = 1)

        let parent = location.parent
        if parent == null:
            this.root = node
        else:
            unsafe:
                let parent_ptr = ptr[Node[T]]<-parent
                if location.compare < 0:
                    read(parent_ptr).left = node
                else:
                    read(parent_ptr).right = node

        this.len += 1
        OrderedSet[T].rebalance(this, parent)
        return true


    public mutable function remove(value: T) -> bool:
        let location = OrderedSet[T].locate(this, value)
        if not location.found:
            return false

        let node = location.node else:
            fatal(c"ordered_set.OrderedSet.remove missing node")

        let rebalance_from = OrderedSet[T].detach_node(this, unsafe: ptr[Node[T]]<-node)
        this.len -= 1
        OrderedSet[T].rebalance(this, rebalance_from)
        return true


extending Iter[T]:
    public function iter() -> Iter[T]:
        return this


    public mutable function next() -> const_ptr[T]?:
        let current = this.node else:
            return null

        this.node = OrderedSet[T].successor(current)

        unsafe:
            return const_ptr_of(read(ptr[Node[T]]<-current).value)
