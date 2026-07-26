## Object pool — fixed-capacity reusable object storage.
##
## Pre-allocate objects once, then acquire/release without
## allocation churn. O(1) acquire and release via free stack.
##
##   import std.pool as pool
##   var p = pool.Pool[Bullet].create(64)
##   let id = p.acquire() else: /* pool exhausted */
##   let bullet = p.get(id)   # ptr to object
##   p.release(id)

import std.vec as vec
import std.mem.heap as heap


public struct Pool[T]:
    objects: ptr[T]
    free_stack: vec.Vec[ptr_uint]
    capacity: ptr_uint


# ── public API ──

extending Pool[T]:
    public static function create(capacity: ptr_uint) -> Pool[T]:
        var p = Pool[T](
            objects = heap.must_alloc[T](capacity),
            free_stack = vec.Vec[ptr_uint].with_capacity(capacity),
            capacity = capacity
        )

        # Push all indices onto the free stack in reverse order so
        # acquire() returns them in ascending order (0 first).
        var i = capacity
        while i > 0:
            i -= 1
            p.free_stack.push(i)

        return p


    public editable function acquire() -> Option[ptr_uint]:
        let idx = this.free_stack.pop() else:
            return Option[ptr_uint].none
        return Option[ptr_uint].some(value = idx)


    public function get(index: ptr_uint) -> ptr[T]?:
        if index >= this.capacity:
            return null
        unsafe:
            return this.objects + index


    public editable function release_object(index: ptr_uint) -> void:
        if index >= this.capacity:
            return

        # Check for double-release by scanning free stack.
        # Skip this check for simplicity — caller must not double-release.
        this.free_stack.push(index)


    public function available() -> ptr_uint:
        return this.free_stack.len()


    public function count() -> ptr_uint:
        return this.capacity - this.free_stack.len()


    public editable function clear() -> void:
        this.free_stack.clear()
        var i = this.capacity
        while i > 0:
            i -= 1
            this.free_stack.push(i)


    public editable function release() -> void:
        this.free_stack.release()
        heap.release(this.objects)