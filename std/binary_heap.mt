import std.vec as vec


public struct BinaryHeap[T]:
    values: vec.Vec[T]


public struct Iter[T]:
    data: ptr[T]?
    index: ptr_uint
    len: ptr_uint


extending BinaryHeap[T]:
    public static function create() -> BinaryHeap[T]:
        return BinaryHeap[T](values = vec.Vec[T].create())


    public static function with_capacity(capacity: ptr_uint) -> BinaryHeap[T]:
        var result = BinaryHeap[T].create()
        result.reserve(capacity)
        return result


    static function parent_index(index: ptr_uint) -> ptr_uint:
        return (index - 1) / 2


    static function left_child_index(index: ptr_uint) -> ptr_uint:
        return (index * 2) + 1


    static function right_child_index(index: ptr_uint) -> ptr_uint:
        return (index * 2) + 2


    static function slot(current: ref[BinaryHeap[T]], index: ptr_uint) -> ptr[T]:
        let value = current.values.get(index) else:
            fatal(c"binary_heap.BinaryHeap.slot missing value")

        return unsafe: ptr[T]<-value


    static function swap(current: ref[BinaryHeap[T]], left_index: ptr_uint, right_index: ptr_uint) -> void:
        let left = BinaryHeap[T].slot(current, left_index)
        let right = BinaryHeap[T].slot(current, right_index)

        unsafe:
            let temp = read(left)
            read(left) = read(right)
            read(right) = temp



    static function sift_up(current: ref[BinaryHeap[T]], start_index: ptr_uint) -> void:
        var child = start_index
        while child != 0:
            let parent = BinaryHeap[T].parent_index(child)
            let child_value = BinaryHeap[T].slot(current, child)
            let parent_value = BinaryHeap[T].slot(current, parent)
            if order[T](child_value, parent_value) <= 0:
                break

            BinaryHeap[T].swap(current, child, parent)
            child = parent



    static function sift_down(current: ref[BinaryHeap[T]], start_index: ptr_uint) -> void:
        let length = current.values.len()
        if length <= 1:
            return

        var parent = start_index
        while true:
            let left = BinaryHeap[T].left_child_index(parent)
            if left >= length:
                break

            var candidate = left
            let right = BinaryHeap[T].right_child_index(parent)
            if right < length:
                let left_value = BinaryHeap[T].slot(current, left)
                let right_value = BinaryHeap[T].slot(current, right)
                if order[T](right_value, left_value) > 0:
                    candidate = right

            let parent_value = BinaryHeap[T].slot(current, parent)
            let candidate_value = BinaryHeap[T].slot(current, candidate)
            if order[T](candidate_value, parent_value) <= 0:
                break

            BinaryHeap[T].swap(current, parent, candidate)
            parent = candidate



    public function len() -> ptr_uint:
        return this.values.len()


    public function capacity() -> ptr_uint:
        return this.values.capacity()


    public function is_empty() -> bool:
        return this.values.is_empty()


    public function iter() -> Iter[T]:
        let view = this.values.as_span()
        return Iter[T](data = view.data, index = 0, len = view.len)


    public function peek() -> const_ptr[T]?:
        let current = this.values.get(0) else:
            return null

        unsafe:
            return const_ptr_of(read(ptr[T]<-current))


    public mutable function clear() -> void:
        this.values.clear()


    public mutable function release() -> void:
        this.values.release()


    public mutable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)


    public mutable function push(value: T) -> void:
        this.values.push(value)
        BinaryHeap[T].sift_up(this, this.values.len() - 1)


    public mutable function pop() -> Option[T]:
        let removed = this.values.swap_remove(0)
        match removed:
            Option.none:
                return Option[T].none
            Option.some as payload:
                if not this.values.is_empty():
                    BinaryHeap[T].sift_down(this, 0)
                return Option[T].some(value = payload.value)


extending Iter[T]:
    public function iter() -> Iter[T]:
        return this


    public mutable function next() -> const_ptr[T]?:
        if this.index >= this.len:
            return null

        let data = this.data else:
            fatal(c"binary_heap.Iter.next missing storage")

        let current_index = this.index
        this.index += 1

        unsafe:
            let current = ptr[T]<-data + current_index
            return const_ptr_of(read(current))
