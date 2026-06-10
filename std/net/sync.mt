import std.net.mux as mux
import std.net.session as sess
import std.vec as vec

public struct SyncValue[T]:
    value: T
    dirty: bool


extending SyncValue[T]:
    public editable function set(new_value: T) -> void:
        this.value = new_value
        this.dirty = true


    public function get() -> T:
        return this.value


    public editable function mark_clean() -> void:
        this.dirty = false


    public function has_changed() -> bool:
        return this.dirty

public struct SyncList[T]:
    items: vec.Vec[T]
    dirty: bool


extending SyncList[T]:
    public editable function push(item: T) -> void:
        this.items.push(item)
        this.dirty = true


    public editable function clear() -> void:
        this.items.clear()
        this.dirty = true


    public function len() -> ptr_uint:
        return this.items.len()


    public function get(index: ptr_uint) -> ptr[T]?:
        return this.items.get(index)


    public editable function mark_clean() -> void:
        this.dirty = false


    public function has_changed() -> bool:
        return this.dirty

public struct Lerp:
    previous: float
    target: float
    elapsed: float
    duration: float


extending Lerp:
    public editable function set_target(new_target: float, dur: float) -> void:
        this.previous = this.target
        this.target = new_target
        this.elapsed = 0.0
        this.duration = dur


    public editable function tick(dt: float) -> void:
        this.elapsed = this.elapsed + dt


    public function current() -> float:
        if this.duration <= 0.0:
            return this.target
        var t: float = this.elapsed / this.duration
        if t > 1.0:
            t = 1.0
        return this.previous + (this.target - this.previous) * t


    public function has_arrived() -> bool:
        return this.elapsed >= this.duration

public struct CompressedUshort:
    min: float
    max: float


extending CompressedUshort:
    public function encode(value: float) -> ushort:
        var clamped: float = value
        if clamped < this.min:
            clamped = this.min
        if clamped > this.max:
            clamped = this.max
        let ratio = (clamped - this.min) / (this.max - this.min)
        return ushort<-(float<-ratio * 65535.0)


    public function decode(encoded: ushort) -> float:
        let ratio = float<-encoded / 65535.0
        return this.min + ratio * (this.max - this.min)

public struct CompressedUbyte:
    min: float
    max: float


extending CompressedUbyte:
    public function encode(value: float) -> ubyte:
        var clamped: float = value
        if clamped < this.min:
            clamped = this.min
        if clamped > this.max:
            clamped = this.max
        let ratio = (clamped - this.min) / (this.max - this.min)
        return ubyte<-(float<-ratio * 255.0)


    public function decode(encoded: ubyte) -> float:
        let ratio = float<-encoded / 255.0
        return this.min + ratio * (this.max - this.min)

public struct TickBuffer[T]:
    entries: vec.Vec[T]
    base_tick: uint


extending TickBuffer[T]:
    public editable function push(tick: uint, value: T) -> void:
        let offset: ptr_uint = ptr_uint<-(tick - this.base_tick)
        while offset >= this.entries.len():
            this.entries.push(value)
            return
        let ptr = this.entries.get(offset) else:
            return
        unsafe:
            read(ptr) = value


    public function get(tick: uint) -> Option[T]:
        if tick < this.base_tick:
            return Option[T].none()
        let offset: ptr_uint = ptr_uint<-(tick - this.base_tick)
        if offset >= this.entries.len():
            return Option[T].none()
        let ptr = this.entries.get(offset) else:
            return Option[T].none()
        return Option[T].some(value = unsafe: read(ptr))


    public function earliest_tick() -> uint:
        return this.base_tick


    public function latest_tick() -> uint:
        return this.base_tick + uint<-this.entries.len()


public async function broadcast(
    session: ref[mux.MuxedSession],
    channel_id: ubyte,
    type_id: ushort,
    payload: span[ubyte],
    send_flags: ubyte
) -> void:
    var i: ptr_uint = 0
    while i < session.session.peers.len():
        let peer_ptr = session.session.peers.get(i) else:
            break
        let peer_id = unsafe: read(peer_ptr).peer_id
        if unsafe: read(peer_ptr).channel_state != sess.ConnectionState.disconnected:
            let _ = await session.mux_send(peer_id, channel_id, type_id, payload, send_flags)
        i += 1
