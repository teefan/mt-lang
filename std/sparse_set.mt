import std.vec as vec

const SPARSE_EMPTY: ptr_uint = ~ptr_uint<-0

public struct SparseSet[T]:
    sparse: vec.Vec[ptr_uint]
    dense: vec.Vec[T]
    keys: vec.Vec[ptr_uint]

public struct Iter[T]:
    data: ptr[T]?
    index: ptr_uint
    len: ptr_uint


extending SparseSet[T]:
    public static function create() -> SparseSet[T]:
        return SparseSet[T](
            sparse = vec.Vec[ptr_uint].create(),
            dense = vec.Vec[T].create(),
            keys = vec.Vec[ptr_uint].create(),
        )


    public static function with_capacity(capacity: ptr_uint) -> SparseSet[T]:
        var result = SparseSet[T].create()
        result.reserve(capacity)
        return result


    public function len() -> ptr_uint:
        return this.dense.len()


    public function is_empty() -> bool:
        return this.dense.is_empty()


    public function iter() -> Iter[T]:
        let view = this.dense.as_span()
        return Iter[T](data = view.data, index = 0, len = view.len)


    public function get(key: ptr_uint) -> ptr[T]?:
        if key >= this.sparse.len():
            return null

        let position = this.sparse.get(key) else:
            fatal(c"sparse_set.SparseSet.get missing sparse storage")

        unsafe:
            let index = read(ptr[ptr_uint]<-position)
            if index == SPARSE_EMPTY:
                return null

            return this.dense.get(index)


    public function at(key: ptr_uint) -> Option[T]:
        let p = this.get(key) else:
            return Option[T].none

        unsafe:
            return Option[T].some(value = read(p))


    public function contains(key: ptr_uint) -> bool:
        return this.get(key) != null


    public function key_at(dense_index: ptr_uint) -> ptr_uint:
        let key_ptr = this.keys.get(dense_index) else:
            fatal(c"sparse_set.SparseSet.key_at missing keys storage")

        unsafe:
            return read(ptr[ptr_uint]<-key_ptr)


    public editable function clear() -> void:
        this.sparse.clear()
        this.dense.clear()
        this.keys.clear()


    public editable function release() -> void:
        this.sparse.release()
        this.dense.release()
        this.keys.release()


    public editable function reserve(min_capacity: ptr_uint) -> void:
        this.dense.reserve(min_capacity)
        this.keys.reserve(min_capacity)


    public editable function shrink_to_fit() -> void:
        this.sparse.shrink_to_fit()
        this.dense.shrink_to_fit()
        this.keys.shrink_to_fit()


    public editable function insert(key: ptr_uint, value: T) -> bool:
        while key >= this.sparse.len():
            this.sparse.push(SPARSE_EMPTY)

        let position = this.sparse.get(key) else:
            fatal(c"sparse_set.SparseSet.insert missing sparse storage")

        unsafe:
            if read(ptr[ptr_uint]<-position) != SPARSE_EMPTY:
                return false

        let dense_index = this.dense.len()
        this.dense.push(value)
        this.keys.push(key)

        unsafe:
            read(ptr[ptr_uint]<-position) = dense_index

        return true


    public editable function remove(key: ptr_uint) -> bool:
        if key >= this.sparse.len():
            return false

        let dense_index_ptr = this.sparse.get(key) else:
            fatal(c"sparse_set.SparseSet.remove missing sparse storage")

        unsafe:
            let dense_index = read(ptr[ptr_uint]<-dense_index_ptr)
            if dense_index == SPARSE_EMPTY:
                return false

            let last_index = this.dense.len() - 1
            if dense_index != last_index:
                let last_value = this.dense.get(last_index) else:
                    fatal(c"sparse_set.SparseSet.remove missing last dense value")
                let dense_slot = this.dense.get(dense_index) else:
                    fatal(c"sparse_set.SparseSet.remove missing dense slot")
                read(dense_slot) = read(last_value)

                let last_key = this.keys.get(last_index) else:
                    fatal(c"sparse_set.SparseSet.remove missing last key")
                let moved_key = read(ptr[ptr_uint]<-last_key)

                let key_slot = this.keys.get(dense_index) else:
                    fatal(c"sparse_set.SparseSet.remove missing key slot")
                read(ptr[ptr_uint]<-key_slot) = moved_key

                let moved_sparse_ptr = this.sparse.get(moved_key) else:
                    fatal(c"sparse_set.SparseSet.remove missing sparse entry for moved key")
                read(ptr[ptr_uint]<-moved_sparse_ptr) = dense_index

            this.dense.pop()
            this.keys.pop()
            read(ptr[ptr_uint]<-dense_index_ptr) = SPARSE_EMPTY

        return true


extending Iter[T]:
    public function iter() -> Iter[T]:
        return this


    public editable function next() -> ptr[T]?:
        if this.index >= this.len:
            return null

        let data = this.data else:
            fatal(c"sparse_set.Iter.next missing storage")

        let current_index = this.index
        this.index += 1
        return unsafe: ptr[T]<-data + current_index
