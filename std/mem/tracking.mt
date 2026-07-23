import std.mem.heap as heap
import std.vec as vec
import std.string as string
import std.terminal as terminal
import std.fmt as fmt

public struct Tracker:
    entries: vec.Vec[Entry]

public struct Entry:
    pointer: ptr[void]?
    size: ptr_uint
    tag: str

public type Tag = str


public function create() -> Tracker:
    return Tracker(entries = vec.Vec[Entry].create())


extending Tracker:
    public editable function release() -> void:
        this.entries.release()


    public function count() -> ptr_uint:
        return this.entries.len()


    public function is_empty() -> bool:
        return this.entries.len() == 0


    public function total_bytes() -> ptr_uint:
        var total: ptr_uint = 0
        var iter = this.entries.iter()
        var ep = iter.next()
        while ep != null:
            total += unsafe: read(ep).size
            ep = iter.next()
        return total


    public function report() -> void:
        if this.entries.len() == 0:
            return

        var sb = string.String.create()
        defer sb.release()

        sb.append("[tracking] ")
        sb.append(fmt.format(f"#{this.entries.len()} leaked allocation(s):\n").as_str())

        var i: ptr_uint = 0
        while i < this.entries.len():
            let ep = this.entries.get(i) else:
                fatal(c"tracking.report entry is null")
            let entry = unsafe: read(ep)
            sb.append("  ")
            sb.append(entry.tag)
            sb.append(": ")
            sb.append(fmt.format(f"#{entry.size} bytes\n").as_str())
            i += 1

        sb.append(fmt.format(f"total: #{this.total_bytes()} bytes in #{this.entries.len()} allocation(s)\n").as_str())

        let _ = terminal.write_stderr(sb.as_str())
        terminal.flush_stderr()


public function alloc_bytes(tracker: ref[Tracker], size: ptr_uint, tag: Tag) -> ptr[void]?:
    let p = heap.alloc_bytes(size) else:
        return null
    tracker.entries.push(Entry(pointer = p, size = size, tag = tag))
    return p


public function must_alloc_bytes(tracker: ref[Tracker], size: ptr_uint, tag: Tag) -> ptr[void]:
    let p = alloc_bytes(tracker, size, tag) else:
        fatal(c"tracking.must_alloc_bytes allocation failed")
    return p


public function alloc[T](tracker: ref[Tracker], count: ptr_uint, tag: Tag) -> own[T]?:
    let raw = heap.alloc_bytes(size_of(T) * count) else:
        return null
    tracker.entries.push(Entry(pointer = raw, size = size_of(T) * count, tag = tag))
    unsafe:
        return own[T]<-raw


public function must_alloc[T](tracker: ref[Tracker], count: ptr_uint, tag: Tag) -> own[T]:
    let p = alloc[T](tracker, count, tag) else:
        fatal(c"tracking.must_alloc allocation failed")
    return p


public function release_bytes(tracker: ref[Tracker], memory: ptr[void]?) -> void:
    if memory == null:
        return
    var i: ptr_uint = 0
    var found = false
    while i < tracker.entries.len():
        let ep = tracker.entries.get(i) else:
            fatal(c"tracking.release_bytes entry is null")
        let entry = unsafe: read(ep)
        if entry.pointer == memory:
            tracker.entries.swap_remove(i)
            found = true
            break
        i += 1
    if not found:
        fatal(c"tracking.release_bytes: pointer not tracked (bad free or double free)")
    heap.release_bytes(memory)


public function release[T](tracker: ref[Tracker], memory: ptr[T]?) -> void:
    release_bytes(tracker, unsafe: ptr[void]<-memory)
