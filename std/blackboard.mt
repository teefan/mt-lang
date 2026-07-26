## Blackboard — typed key-value shared state for AI.
##
## Store and retrieve named values that multiple AI systems
## can read and write. Linear O(n) lookup (tuned for small
## sizes — typical AI blackboards have under 20 entries).
##
##   import std.blackboard as bb
##   var board = bb.Blackboard[float].create()
##   board.set("health", 100.0)
##   let h = board.get("health") else: 0.0

import std.vec as vec


public struct BlackboardEntry[T]:
    key: str
    value: T


public struct Blackboard[T]:
    entries: vec.Vec[BlackboardEntry[T]]


# ── internal helpers ──

function find_entry[T](board: ref[Blackboard[T]], key: str) -> ptr[BlackboardEntry[T]]?:
    for entry in board.entries:
        unsafe:
            if read(entry).key == key:
                return entry
    return null


# ── public API ──

extending Blackboard[T]:
    public static function create() -> Blackboard[T]:
        return Blackboard[T](
            entries = vec.Vec[BlackboardEntry[T]].create()
        )


    public editable function set(key: str, value: T) -> void:
        let existing = find_entry(ref_of(this), key)
        if existing != null:
            unsafe:
                read(ptr[BlackboardEntry[T]]<-existing).value = value
            return
        this.entries.push(BlackboardEntry[T](key = key, value = value))


    public function get(key: str) -> Option[T]:
        var n = this.entries.len()
        var i: ptr_uint = 0
        while i < n:
            let entry_ptr = this.entries.get(i) else:
                break
            unsafe:
                if read(entry_ptr).key == key:
                    return Option[T].some(value = read(entry_ptr).value)
            i += 1
        return Option[T].none


    public function has(key: str) -> bool:
        var n = this.entries.len()
        var i: ptr_uint = 0
        while i < n:
            let entry_ptr = this.entries.get(i) else:
                break
            unsafe:
                if read(entry_ptr).key == key:
                    return true
            i += 1
        return false


    public editable function remove(key: str) -> void:
        var n = this.entries.len()
        var i: ptr_uint = 0
        while i < n:
            let entry_ptr = this.entries.get(i) else:
                break
            unsafe:
                if read(entry_ptr).key == key:
                    this.entries.swap_remove(i)
                    return
            i += 1


    public editable function clear() -> void:
        this.entries.clear()


    public function count() -> ptr_uint:
        return this.entries.len()


    public editable function release() -> void:
        this.entries.release()