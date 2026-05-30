import std.mem.heap as heap

struct Node[K, V]:
    hash: uint
    key: K
    value: V
    bucket_next: ptr[Node[K, V]]?
    order_prev: ptr[Node[K, V]]?
    order_next: ptr[Node[K, V]]?

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

public struct LinkedMap[K, V]:
    buckets: ptr[ptr[Node[K, V]]?]?
    len: ptr_uint
    capacity: ptr_uint
    head: ptr[Node[K, V]]?
    tail: ptr[Node[K, V]]?


extending LinkedMap[K, V]:
    public static function create() -> LinkedMap[K, V]:
        return LinkedMap[K, V](buckets = null, len = 0, capacity = 0, head = null, tail = null)


    public static function with_capacity(capacity: ptr_uint) -> LinkedMap[K, V]:
        var result = LinkedMap[K, V].create()
        result.reserve(capacity)
        return result


    static function bucket_index(entry_hash: uint, capacity: ptr_uint) -> ptr_uint:
        let bucket_count = uint<-capacity
        return ptr_uint<-(entry_hash % bucket_count)


    static function find_node(current: LinkedMap[K, V], key: K, key_hash: uint) -> ptr[Node[K, V]]?:
        if current.len == 0:
            return null

        let buckets = current.buckets else:
            fatal(c"linked_map.LinkedMap.find_node missing buckets")

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            let index = LinkedMap[K, V].bucket_index(key_hash, current.capacity)
            var node = read(bucket_ptr + index)
            while node != null:
                let node_ptr = ptr[Node[K, V]]<-node
                let stored_key = const_ptr_of(read(node_ptr).key)
                if read(node_ptr).hash == key_hash and equal[K](key, stored_key):
                    return node
                node = read(node_ptr).bucket_next

        return null


    static function unlink_order_node(current: ref[LinkedMap[K, V]], node: ptr[Node[K, V]]) -> void:
        let previous = unsafe: read(node).order_prev
        let next = unsafe: read(node).order_next

        if previous == null:
            current.head = next
        else:
            unsafe:
                read(ptr[Node[K, V]]<-previous).order_next = next

        if next == null:
            current.tail = previous
        else:
            unsafe:
                read(ptr[Node[K, V]]<-next).order_prev = previous


    public function len() -> ptr_uint:
        return this.len


    public function capacity() -> ptr_uint:
        return this.capacity


    public function is_empty() -> bool:
        return this.len == 0


    public function get(key: K) -> ptr[V]?:
        let key_hash = hash[K](key)
        let node = LinkedMap[K, V].find_node(this, key, key_hash) else:
            return null

        unsafe:
            return ptr_of(read(ptr[Node[K, V]]<-node).value)


    public function get_key(key: K) -> const_ptr[K]?:
        let key_hash = hash[K](key)
        let node = LinkedMap[K, V].find_node(this, key, key_hash) else:
            return null

        unsafe:
            return const_ptr_of(read(ptr[Node[K, V]]<-node).key)


    public function iter() -> Entries[K, V]:
        return this.entries()


    public function keys() -> Keys[K, V]:
        return Keys[K, V](node = this.head)


    public function values() -> Values[K, V]:
        return Values[K, V](node = this.head)


    public function entries() -> Entries[K, V]:
        return Entries[K, V](node = this.head, started = false)


    public function contains(key: K) -> bool:
        return this.get(key) != null


    public mutable function clear() -> void:
        if this.len == 0:
            return

        let buckets = this.buckets else:
            fatal(c"linked_map.LinkedMap.clear missing buckets")

        unsafe:
            var node = this.head
            while node != null:
                let node_ptr = ptr[Node[K, V]]<-node
                let next = read(node_ptr).order_next
                heap.release(node)
                node = next

            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            var index: ptr_uint = 0
            while index < this.capacity:
                read(bucket_ptr + index) = null
                index += 1

        this.len = 0
        this.head = null
        this.tail = null


    public mutable function release() -> void:
        this.clear()
        heap.release(this.buckets)
        this.buckets = null
        this.capacity = 0


    public mutable function reserve(min_capacity: ptr_uint) -> void:
        if min_capacity <= this.capacity:
            return

        var new_capacity = this.capacity
        if new_capacity == 0:
            new_capacity = 8

        while new_capacity < min_capacity:
            if new_capacity > heap.ptr_uint_max() / 2:
                new_capacity = min_capacity
            else:
                new_capacity *= 2

        let new_buckets = heap.must_alloc_zeroed[ptr[Node[K, V]]?](new_capacity)
        let old_buckets = this.buckets

        unsafe:
            let new_ptr = ptr[ptr[Node[K, V]]?]<-new_buckets
            var node = this.head
            while node != null:
                let node_ptr = ptr[Node[K, V]]<-node
                let next = read(node_ptr).order_next
                let target = LinkedMap[K, V].bucket_index(read(node_ptr).hash, new_capacity)
                read(node_ptr).bucket_next = read(new_ptr + target)
                read(new_ptr + target) = node
                node = next

        heap.release(old_buckets)
        this.buckets = new_buckets
        this.capacity = new_capacity


    public mutable function set(key: K, value: V) -> Option[V]:
        let key_hash = hash[K](key)
        let existing = LinkedMap[K, V].find_node(this, key, key_hash)
        if existing != null:
            unsafe:
                let node_ptr = ptr[Node[K, V]]<-existing
                let previous = read(node_ptr).value
                read(node_ptr).value = value
                return Option[V].some(value = previous)

        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let current_buckets = this.buckets else:
            fatal(c"linked_map.LinkedMap.set missing buckets")

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-current_buckets
            let index = LinkedMap[K, V].bucket_index(key_hash, this.capacity)
            let node = heap.must_alloc[Node[K, V]](1)
            let tail = this.tail
            read(node) = Node[K, V](
                hash = key_hash,
                key = key,
                value = value,
                bucket_next = read(bucket_ptr + index),
                order_prev = tail,
                order_next = null
            )
            read(bucket_ptr + index) = node

            if tail == null:
                this.head = node
            else:
                read(ptr[Node[K, V]]<-tail).order_next = node
            this.tail = node

        this.len += 1
        return Option[V].none


    public mutable function get_or_insert(key: K, value: V) -> ptr[V]:
        let key_hash = hash[K](key)
        let existing = LinkedMap[K, V].find_node(this, key, key_hash)
        if existing != null:
            unsafe:
                return ptr_of(read(ptr[Node[K, V]]<-existing).value)

        let inserted = this.set(key, value)
        match inserted:
            Option.none:
                let current = LinkedMap[K, V].find_node(this, key, key_hash) else:
                    fatal(c"linked_map.LinkedMap.get_or_insert missing inserted value")
                unsafe:
                    return ptr_of(read(ptr[Node[K, V]]<-current).value)
            Option.some as ignored_payload:
                fatal(c"linked_map.LinkedMap.get_or_insert replaced unexpectedly")


    public mutable function remove_entry(key: K) -> Option[RemovedEntry[K, V]]:
        if this.len == 0:
            return Option[RemovedEntry[K, V]].none

        let buckets = this.buckets else:
            fatal(c"linked_map.LinkedMap.remove_entry missing buckets")

        let key_hash = hash[K](key)

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            let index = LinkedMap[K, V].bucket_index(key_hash, this.capacity)
            var previous: ptr[Node[K, V]]? = null
            var node = read(bucket_ptr + index)
            while node != null:
                let node_ptr = ptr[Node[K, V]]<-node
                let stored_key = const_ptr_of(read(node_ptr).key)
                if read(node_ptr).hash == key_hash and equal[K](key, stored_key):
                    let next_bucket = read(node_ptr).bucket_next
                    if previous == null:
                        read(bucket_ptr + index) = next_bucket
                    else:
                        read(ptr[Node[K, V]]<-previous).bucket_next = next_bucket

                    let removed = RemovedEntry[K, V](key = read(node_ptr).key, value = read(node_ptr).value)
                    LinkedMap[K, V].unlink_order_node(this, node_ptr)
                    heap.release(node)
                    this.len -= 1
                    return Option[RemovedEntry[K, V]].some(value = removed)

                previous = node
                node = read(node_ptr).bucket_next

        return Option[RemovedEntry[K, V]].none


    public mutable function remove(key: K) -> Option[V]:
        let removed = this.remove_entry(key)
        match removed:
            Option.none:
                return Option[V].none
            Option.some as payload:
                return Option[V].some(value = payload.value.value)


extending Keys[K, V]:
    public function iter() -> Keys[K, V]:
        return this


    public mutable function next() -> const_ptr[K]?:
        let current = this.node else:
            return null

        unsafe:
            let current_ptr = ptr[Node[K, V]]<-current
            this.node = read(current_ptr).order_next
            return const_ptr_of(read(current_ptr).key)


extending Values[K, V]:
    public function iter() -> Values[K, V]:
        return this


    public mutable function next() -> ptr[V]?:
        let current = this.node else:
            return null

        unsafe:
            let current_ptr = ptr[Node[K, V]]<-current
            this.node = read(current_ptr).order_next
            return ptr_of(read(current_ptr).value)


extending Entries[K, V]:
    public function iter() -> Entries[K, V]:
        return this


    public mutable function next() -> bool:
        let current = this.node else:
            return false

        if not this.started:
            this.started = true
            return true

        let next = unsafe: read(ptr[Node[K, V]]<-current).order_next
        this.node = next
        return next != null


    public function current() -> Entry[K, V]:
        let current = this.node
        if current == null or not this.started:
            fatal(c"linked_map.Entries.current missing current node")

        unsafe:
            let node_ptr = ptr[Node[K, V]]<-current
            return Entry[K, V](key = const_ptr_of(read(node_ptr).key), value = ptr_of(read(node_ptr).value))
