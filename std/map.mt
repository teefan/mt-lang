import std.mem.heap as heap

struct Node[K, V]:
    hash: uint
    key: K
    value: V
    next: ptr[Node[K, V]]?

public struct Entry[K, V]:
    key: const_ptr[K]
    value: ptr[V]

public struct RemovedEntry[K, V]:
    key: K
    value: V

public struct Keys[K, V]:
    buckets: ptr[ptr[Node[K, V]]?]?
    bucket_index: ptr_uint
    bucket_count: ptr_uint
    node: ptr[Node[K, V]]?

public struct Values[K, V]:
    buckets: ptr[ptr[Node[K, V]]?]?
    bucket_index: ptr_uint
    bucket_count: ptr_uint
    node: ptr[Node[K, V]]?

public struct Entries[K, V]:
    buckets: ptr[ptr[Node[K, V]]?]?
    bucket_index: ptr_uint
    bucket_count: ptr_uint
    node: ptr[Node[K, V]]?

public struct Map[K, V]:
    buckets: ptr[ptr[Node[K, V]]?]?
    len: ptr_uint
    capacity: ptr_uint


extending Map[K, V]:
    public static function create() -> Map[K, V]:
        return Map[K, V](buckets = null, len = 0, capacity = 0)


    public static function with_capacity(capacity: ptr_uint) -> Map[K, V]:
        var result = Map[K, V].create()
        result.reserve(capacity)
        return result


    static function bucket_index(entry_hash: uint, capacity: ptr_uint) -> ptr_uint:
        let bucket_count = uint<-capacity
        return ptr_uint<-(entry_hash % bucket_count)


    static function find_node(current: Map[K, V], key: K, key_hash: uint) -> ptr[Node[K, V]]?:
        if current.len == 0:
            return null

        let buckets = current.buckets else:
            fatal(c"map.Map.find_node missing buckets")

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            let index = Map[K, V].bucket_index(key_hash, current.capacity)
            var node = read(bucket_ptr + index)
            while node != null:
                let node_ptr = ptr[Node[K, V]]<-node
                let stored_key = const_ptr_of(read(node_ptr).key)
                if read(node_ptr).hash == key_hash and equal[K](key, stored_key):
                    return node
                node = read(node_ptr).next

        return null


    public function len() -> ptr_uint:
        return this.len


    public function capacity() -> ptr_uint:
        return this.capacity


    public function is_empty() -> bool:
        return this.len == 0


    public function get(key: K) -> ptr[V]?:
        let key_hash = hash[K](key)
        let node = Map[K, V].find_node(this, key, key_hash) else:
            return null

        unsafe:
            return ptr_of(read(ptr[Node[K, V]]<-node).value)


    public function get_key(key: K) -> const_ptr[K]?:
        let key_hash = hash[K](key)
        let node = Map[K, V].find_node(this, key, key_hash) else:
            return null

        unsafe:
            return const_ptr_of(read(ptr[Node[K, V]]<-node).key)


    public function iter() -> Entries[K, V]:
        return this.entries()


    public function keys() -> Keys[K, V]:
        return Keys[K, V](buckets = this.buckets, bucket_index = 0, bucket_count = this.capacity, node = null)


    public function values() -> Values[K, V]:
        return Values[K, V](buckets = this.buckets, bucket_index = 0, bucket_count = this.capacity, node = null)


    public function entries() -> Entries[K, V]:
        return Entries[K, V](buckets = this.buckets, bucket_index = 0, bucket_count = this.capacity, node = null)


    public function contains(key: K) -> bool:
        return this.get(key) != null


    public mutable function clear() -> void:
        if this.len == 0:
            return

        let buckets = this.buckets else:
            fatal(c"map.Map.clear missing buckets")

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            var index: ptr_uint = 0
            while index < this.capacity:
                var node = read(bucket_ptr + index)
                while node != null:
                    let node_ptr = ptr[Node[K, V]]<-node
                    let next = read(node_ptr).next
                    heap.release(node)
                    node = next
                read(bucket_ptr + index) = null
                index += 1

        this.len = 0


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
            if new_capacity > heap.ptr_uint_max / 2:
                new_capacity = min_capacity
            else:
                new_capacity *= 2

        let new_buckets = heap.must_alloc_zeroed[ptr[Node[K, V]]?](new_capacity)
        let old_buckets = this.buckets
        let old_capacity = this.capacity

        if old_buckets != null:
            unsafe:
                let old_ptr = ptr[ptr[Node[K, V]]?]<-old_buckets
                let new_ptr = ptr[ptr[Node[K, V]]?]<-new_buckets
                var index: ptr_uint = 0
                while index < old_capacity:
                    var node = read(old_ptr + index)
                    while node != null:
                        let node_ptr = ptr[Node[K, V]]<-node
                        let next = read(node_ptr).next
                        let target = Map[K, V].bucket_index(read(node_ptr).hash, new_capacity)
                        read(node_ptr).next = read(new_ptr + target)
                        read(new_ptr + target) = node
                        node = next
                    index += 1
            heap.release(old_buckets)

        this.buckets = new_buckets
        this.capacity = new_capacity


    public mutable function set(key: K, value: V) -> Option[V]:
        let key_hash = hash[K](key)
        let existing = Map[K, V].find_node(this, key, key_hash)
        if existing != null:
            unsafe:
                let node_ptr = ptr[Node[K, V]]<-existing
                let previous = read(node_ptr).value
                read(node_ptr).value = value
                return Option[V].some(value = previous)

        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let current_buckets = this.buckets else:
            fatal(c"map.Map.set missing buckets")

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-current_buckets
            let index = Map[K, V].bucket_index(key_hash, this.capacity)
            let node = heap.must_alloc[Node[K, V]](1)
            let node_ptr = ptr[Node[K, V]]<-node
            read(node_ptr) = Node[K, V](
                hash = key_hash,
                key = key,
                value = value,
                next = read(bucket_ptr + index)
            )
            read(bucket_ptr + index) = node

        this.len += 1
        return Option[V].none


    public mutable function get_or_insert(key: K, value: V) -> ptr[V]:
        let key_hash = hash[K](key)
        let existing = Map[K, V].find_node(this, key, key_hash)
        if existing != null:
            unsafe:
                return ptr_of(read(ptr[Node[K, V]]<-existing).value)

        let inserted = this.set(key, value)
        match inserted:
            Option.none:
                let current = Map[K, V].find_node(this, key, key_hash) else:
                    fatal(c"map.Map.get_or_insert missing inserted value")
                unsafe:
                    return ptr_of(read(ptr[Node[K, V]]<-current).value)
            Option.some:
                fatal(c"map.Map.get_or_insert replaced unexpectedly")


    public mutable function remove_entry(key: K) -> Option[RemovedEntry[K, V]]:
        if this.len == 0:
            return Option[RemovedEntry[K, V]].none

        let buckets = this.buckets else:
            fatal(c"map.Map.remove_entry missing buckets")

        let key_hash = hash[K](key)

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            let index = Map[K, V].bucket_index(key_hash, this.capacity)
            var previous: ptr[Node[K, V]]? = null
            var node = read(bucket_ptr + index)
            while node != null:
                let node_ptr = ptr[Node[K, V]]<-node
                let stored_key = const_ptr_of(read(node_ptr).key)
                if read(node_ptr).hash == key_hash and equal[K](key, stored_key):
                    let next = read(node_ptr).next
                    if previous == null:
                        read(bucket_ptr + index) = next
                    else:
                        read(ptr[Node[K, V]]<-previous).next = next

                    let removed = RemovedEntry[K, V](key = read(node_ptr).key, value = read(node_ptr).value)
                    heap.release(node)
                    this.len -= 1
                    return Option[RemovedEntry[K, V]].some(value = removed)

                previous = node
                node = read(node_ptr).next

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
        let current_node = this.node
        if current_node != null:
            unsafe:
                let next_node = read(ptr[Node[K, V]]<-current_node).next
                if next_node != null:
                    this.node = next_node
                    return const_ptr_of(read(ptr[Node[K, V]]<-next_node).key)

        let buckets = this.buckets else:
            this.bucket_index = this.bucket_count
            this.node = null
            return null

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            var index = this.bucket_index
            while index < this.bucket_count:
                let candidate = read(bucket_ptr + index)
                index += 1
                if candidate != null:
                    this.bucket_index = index
                    this.node = candidate
                    return const_ptr_of(read(ptr[Node[K, V]]<-candidate).key)

        this.bucket_index = this.bucket_count
        this.node = null
        return null


extending Values[K, V]:
    public function iter() -> Values[K, V]:
        return this


    public mutable function next() -> ptr[V]?:
        let current_node = this.node
        if current_node != null:
            unsafe:
                let next_node = read(ptr[Node[K, V]]<-current_node).next
                if next_node != null:
                    this.node = next_node
                    return ptr_of(read(ptr[Node[K, V]]<-next_node).value)

        let buckets = this.buckets else:
            this.bucket_index = this.bucket_count
            this.node = null
            return null

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            var index = this.bucket_index
            while index < this.bucket_count:
                let candidate = read(bucket_ptr + index)
                index += 1
                if candidate != null:
                    this.bucket_index = index
                    this.node = candidate
                    return ptr_of(read(ptr[Node[K, V]]<-candidate).value)

        this.bucket_index = this.bucket_count
        this.node = null
        return null


extending Entries[K, V]:
    public function iter() -> Entries[K, V]:
        return this


    public mutable function next() -> bool:
        let current_node = this.node
        if current_node != null:
            unsafe:
                let next_node = read(ptr[Node[K, V]]<-current_node).next
                if next_node != null:
                    this.node = next_node
                    return true

        let buckets = this.buckets else:
            this.bucket_index = this.bucket_count
            this.node = null
            return false

        unsafe:
            let bucket_ptr = ptr[ptr[Node[K, V]]?]<-buckets
            var index = this.bucket_index
            while index < this.bucket_count:
                let candidate = read(bucket_ptr + index)
                index += 1
                if candidate != null:
                    this.bucket_index = index
                    this.node = candidate
                    return true

        this.bucket_index = this.bucket_count
        this.node = null
        return false


    public function current() -> Entry[K, V]:
        let current_node = this.node else:
            fatal(c"map.Entries.current missing current node")

        unsafe:
            let node_ptr = ptr[Node[K, V]]<-current_node
            return Entry[K, V](key = const_ptr_of(read(node_ptr).key), value = ptr_of(read(node_ptr).value))
