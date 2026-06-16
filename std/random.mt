import std.vec as vec

const pcg_multiplier: ulong = 0x5851F42D4C957F2D

public struct Rng:
    state: ulong
    increment: ulong


public function from_seed(seed: ulong) -> Rng:
    var rng = Rng(state = ulong<-0, increment = (seed << ulong<-1) | ulong<-1)
    rng.next_u32()
    rng.state = rng.state + seed
    rng.next_u32()
    return rng


public function from_seed_str(seed_str: str) -> Rng:
    var hash: ulong = ulong<-5381
    var i: ptr_uint = 0
    while i < seed_str.len:
        unsafe:
            let byte_val = ulong<-ubyte<-read(seed_str.data + i)
            hash = ((hash << ulong<-5) + hash) + byte_val
            i += 1
    return from_seed(hash)


extending Rng:
    public editable function next_u32() -> uint:
        let oldstate = this.state
        this.state = oldstate * pcg_multiplier + this.increment
        let xorshifted = uint<-(((oldstate >> ulong<-18) ^ oldstate) >> ulong<-27)
        let rot = uint<-(oldstate >> ulong<-59)
        return (xorshifted >> rot) | (xorshifted << (uint<-32 - rot))


    public editable function next_u64() -> ulong:
        let hi = ulong<-this.next_u32()
        let lo = ulong<-this.next_u32()
        return (hi << ulong<-32) | lo


    public editable function next_f64() -> double:
        let val = this.next_u32()
        return double<-val / 4294967296.0


    public editable function next_f32() -> float:
        let val = this.next_u32()
        return float<-val / 4294967296.0


    public editable function next_ubyte() -> ubyte:
        let val = this.next_u32()
        return ubyte<-(val & uint<-0xFF)


    public editable function next_bool() -> bool:
        let val = this.next_u32()
        return (val & uint<-1) != uint<-0


    public editable function next_uint() -> uint:
        return this.next_u32()


    public editable function next_ulong() -> ulong:
        return this.next_u64()


    public editable function next_uint_range(min: uint, max: uint) -> uint:
        if min >= max:
            return min
        let range = max - min
        return min + (this.next_u32() % range)


    public editable function next_int_range(min: int, max: int) -> int:
        if min >= max:
            return min
        let range = uint<-(int<-max - int<-min)
        let offset = this.next_u32() % range
        return min + int<-offset


    public editable function next_f64_range(min: double, max: double) -> double:
        let t = this.next_f64()
        return min + (max - min) * t


    public editable function next_f32_range(min: float, max: float) -> float:
        let t = this.next_f32()
        return min + (max - min) * t


    public editable function chance(probability: double) -> bool:
        return this.next_f64() < probability


    public editable function pick_ref[T](items: span[T]) -> ptr[T]?:
        let len = items.len
        if len == ptr_uint<-0:
            return null
        let index = ptr_uint<-this.next_uint_range(uint<-0, uint<-len)
        return items.data + index


    public editable function pick[T](items: ref[vec.Vec[T]]) -> Option[T]:
        let len = items.len()
        if len == ptr_uint<-0:
            return Option[T].none()
        let index = ptr_uint<-this.next_uint_range(uint<-0, uint<-len)
        let ptr = items.get(index) else:
            return Option[T].none()
        return Option[T].some(value = unsafe: read(ptr))


    public editable function shuffle[T](items: ref[vec.Vec[T]]) -> void:
        let n = items.len()
        if n <= ptr_uint<-1:
            return
        var i: ptr_uint = n - ptr_uint<-1
        while i > ptr_uint<-0:
            let j = ptr_uint<-this.next_uint_range(uint<-0, uint<-(i + ptr_uint<-1))
            items.swap(i, j)
            i -= 1
        return


    public editable function skip(count: ptr_uint) -> void:
        var i: ptr_uint = 0
        while i < count:
            this.next_u32()
            i += 1
        return


    public editable function fork() -> Rng:
        let seed = this.next_u64()
        return from_seed(seed)


    public editable function seeds() -> array[ulong, 4]:
        return array[ulong, 4](
            this.next_u64(), this.next_u64(),
            this.next_u64(), this.next_u64()
        )
