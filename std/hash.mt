## Canonical hash, equal, and order implementations for common primitive types.
## Import this module to use primitive types as keys in hash-based and
## order-based collections (Map, Set, BinaryHeap, OrderedMap, etc.).

# ---------------------------------------------------------------------------
#  int
# ---------------------------------------------------------------------------

extending int:
    public static function hash(value: const_ptr[int]) -> uint:
        unsafe:
            let v = read(ptr[int]<-value)
            let as_uint: uint = uint<-v
            let fnv: uint = 0x811C9DC5
            let prime: uint = 0x01000193
            var h = fnv
            h = (h ^ (as_uint & uint<-(0xFF))) * prime
            h = (h ^ ((as_uint >> uint<-(8)) & uint<-(0xFF))) * prime
            h = (h ^ ((as_uint >> uint<-(16)) & uint<-(0xFF))) * prime
            h = (h ^ ((as_uint >> uint<-(24)) & uint<-(0xFF))) * prime
            return h


    public static function equal(a: const_ptr[int], b: const_ptr[int]) -> bool:
        unsafe:
            return read(ptr[int]<-a) == read(ptr[int]<-b)


    public static function order(a: const_ptr[int], b: const_ptr[int]) -> int:
        unsafe:
            let av = read(ptr[int]<-a)
            let bv = read(ptr[int]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0

# ---------------------------------------------------------------------------
#  uint
# ---------------------------------------------------------------------------

extending uint:
    public static function hash(value: const_ptr[uint]) -> uint:
        unsafe:
            let v = read(ptr[uint]<-value)
            let fnv: uint = 0x811C9DC5
            let prime: uint = 0x01000193
            var h = fnv
            h = (h ^ (uint<-(ubyte<-(v & uint<-(0xFF))))) * prime
            h = (h ^ (uint<-(ubyte<-((v >> uint<-(8)) & uint<-(0xFF))))) * prime
            h = (h ^ (uint<-(ubyte<-((v >> uint<-(16)) & uint<-(0xFF))))) * prime
            h = (h ^ (uint<-(ubyte<-((v >> uint<-(24)) & uint<-(0xFF))))) * prime
            return h


    public static function equal(a: const_ptr[uint], b: const_ptr[uint]) -> bool:
        unsafe:
            return read(ptr[uint]<-a) == read(ptr[uint]<-b)


    public static function order(a: const_ptr[uint], b: const_ptr[uint]) -> int:
        unsafe:
            let av = read(ptr[uint]<-a)
            let bv = read(ptr[uint]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0

# ---------------------------------------------------------------------------
#  bool
# ---------------------------------------------------------------------------

extending bool:
    public static function hash(value: const_ptr[bool]) -> uint:
        unsafe:
            if read(ptr[bool]<-value):
                return 1
            return 0


    public static function equal(a: const_ptr[bool], b: const_ptr[bool]) -> bool:
        unsafe:
            return read(ptr[bool]<-a) == read(ptr[bool]<-b)


    public static function order(a: const_ptr[bool], b: const_ptr[bool]) -> int:
        unsafe:
            let av = read(ptr[bool]<-a)
            let bv = read(ptr[bool]<-b)
            if av == bv:
                return 0
            else if av:
                return 1
            return -1

# ---------------------------------------------------------------------------
#  float — bitwise hash, exact equal
# ---------------------------------------------------------------------------

extending float:
    public static function hash(value: const_ptr[float]) -> uint:
        unsafe:
            return uint<-reinterpret[uint](read(ptr[float]<-value))


    public static function equal(a: const_ptr[float], b: const_ptr[float]) -> bool:
        unsafe:
            return read(ptr[float]<-a) == read(ptr[float]<-b)


    public static function order(a: const_ptr[float], b: const_ptr[float]) -> int:
        unsafe:
            let av = read(ptr[float]<-a)
            let bv = read(ptr[float]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0

# ---------------------------------------------------------------------------
#  double — bitwise hash, exact equal
# ---------------------------------------------------------------------------

extending double:
    public static function hash(value: const_ptr[double]) -> uint:
        unsafe:
            let bits: ulong = reinterpret[ulong](read(ptr[double]<-value))
            return uint<-((bits >> uint<-(32)) ^ bits)


    public static function equal(a: const_ptr[double], b: const_ptr[double]) -> bool:
        unsafe:
            return read(ptr[double]<-a) == read(ptr[double]<-b)


    public static function order(a: const_ptr[double], b: const_ptr[double]) -> int:
        unsafe:
            let av = read(ptr[double]<-a)
            let bv = read(ptr[double]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0

# ---------------------------------------------------------------------------
#  char
# ---------------------------------------------------------------------------

extending char:
    public static function hash(value: const_ptr[char]) -> uint:
        unsafe:
            return uint<-read(ptr[char]<-value)


    public static function equal(a: const_ptr[char], b: const_ptr[char]) -> bool:
        unsafe:
            return read(ptr[char]<-a) == read(ptr[char]<-b)


    public static function order(a: const_ptr[char], b: const_ptr[char]) -> int:
        unsafe:
            let av = int<-read(ptr[char]<-a)
            let bv = int<-read(ptr[char]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0

# ---------------------------------------------------------------------------
#  Remaining integer widths — byte/short/long and unsigned variants, ptr_int.
#  hash mixes the value's bytes (FNV-1a); equal/order use native operators.
# ---------------------------------------------------------------------------

function hash_u32(value: uint) -> uint:
    let fnv: uint = 0x811C9DC5
    let prime: uint = 0x01000193
    var h = fnv
    h = (h ^ (value & uint<-(0xFF))) * prime
    h = (h ^ ((value >> uint<-(8)) & uint<-(0xFF))) * prime
    h = (h ^ ((value >> uint<-(16)) & uint<-(0xFF))) * prime
    h = (h ^ ((value >> uint<-(24)) & uint<-(0xFF))) * prime
    return h


function hash_u64(value: ulong) -> uint:
    return hash_u32(uint<-((value >> uint<-(32)) ^ value))


extending byte:
    public static function hash(value: const_ptr[byte]) -> uint:
        unsafe:
            return hash_u32(uint<-(int<-read(ptr[byte]<-value)))


    public static function equal(a: const_ptr[byte], b: const_ptr[byte]) -> bool:
        unsafe:
            return read(ptr[byte]<-a) == read(ptr[byte]<-b)


    public static function order(a: const_ptr[byte], b: const_ptr[byte]) -> int:
        unsafe:
            let av = read(ptr[byte]<-a)
            let bv = read(ptr[byte]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0


extending ubyte:
    public static function hash(value: const_ptr[ubyte]) -> uint:
        unsafe:
            return hash_u32(uint<-read(ptr[ubyte]<-value))


    public static function equal(a: const_ptr[ubyte], b: const_ptr[ubyte]) -> bool:
        unsafe:
            return read(ptr[ubyte]<-a) == read(ptr[ubyte]<-b)


    public static function order(a: const_ptr[ubyte], b: const_ptr[ubyte]) -> int:
        unsafe:
            let av = read(ptr[ubyte]<-a)
            let bv = read(ptr[ubyte]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0


extending short:
    public static function hash(value: const_ptr[short]) -> uint:
        unsafe:
            return hash_u32(uint<-(int<-read(ptr[short]<-value)))


    public static function equal(a: const_ptr[short], b: const_ptr[short]) -> bool:
        unsafe:
            return read(ptr[short]<-a) == read(ptr[short]<-b)


    public static function order(a: const_ptr[short], b: const_ptr[short]) -> int:
        unsafe:
            let av = read(ptr[short]<-a)
            let bv = read(ptr[short]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0


extending ushort:
    public static function hash(value: const_ptr[ushort]) -> uint:
        unsafe:
            return hash_u32(uint<-read(ptr[ushort]<-value))


    public static function equal(a: const_ptr[ushort], b: const_ptr[ushort]) -> bool:
        unsafe:
            return read(ptr[ushort]<-a) == read(ptr[ushort]<-b)


    public static function order(a: const_ptr[ushort], b: const_ptr[ushort]) -> int:
        unsafe:
            let av = read(ptr[ushort]<-a)
            let bv = read(ptr[ushort]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0


extending long:
    public static function hash(value: const_ptr[long]) -> uint:
        unsafe:
            return hash_u64(ulong<-read(ptr[long]<-value))


    public static function equal(a: const_ptr[long], b: const_ptr[long]) -> bool:
        unsafe:
            return read(ptr[long]<-a) == read(ptr[long]<-b)


    public static function order(a: const_ptr[long], b: const_ptr[long]) -> int:
        unsafe:
            let av = read(ptr[long]<-a)
            let bv = read(ptr[long]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0


extending ulong:
    public static function hash(value: const_ptr[ulong]) -> uint:
        unsafe:
            return hash_u64(read(ptr[ulong]<-value))


    public static function equal(a: const_ptr[ulong], b: const_ptr[ulong]) -> bool:
        unsafe:
            return read(ptr[ulong]<-a) == read(ptr[ulong]<-b)


    public static function order(a: const_ptr[ulong], b: const_ptr[ulong]) -> int:
        unsafe:
            let av = read(ptr[ulong]<-a)
            let bv = read(ptr[ulong]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0


extending ptr_int:
    public static function hash(value: const_ptr[ptr_int]) -> uint:
        unsafe:
            return hash_u64(ulong<-read(ptr[ptr_int]<-value))


    public static function equal(a: const_ptr[ptr_int], b: const_ptr[ptr_int]) -> bool:
        unsafe:
            return read(ptr[ptr_int]<-a) == read(ptr[ptr_int]<-b)


    public static function order(a: const_ptr[ptr_int], b: const_ptr[ptr_int]) -> int:
        unsafe:
            let av = read(ptr[ptr_int]<-a)
            let bv = read(ptr[ptr_int]<-b)
            if av < bv:
                return -1
            else if av > bv:
                return 1
            return 0

# ---------------------------------------------------------------------------
#  Generic struct helpers — per-field reflection-based hash/equal/order.
# ---------------------------------------------------------------------------

const fnv_offset: uint = 0x811C9DC5
const fnv_prime: uint = 0x01000193

public function hash_struct[T](value: const_ptr[T]) -> uint:
    var h = fnv_offset
    inline for field in fields_of(T):
        let offset = offset_of(T, field)
        let field_size = size_of(field.type)
        var data_ptr = unsafe: ptr[ubyte]<-value + offset
        var b: ptr_uint = 0
        while b < field_size:
            h = (h ^ uint<-unsafe: read(data_ptr + b)) * fnv_prime
            b += 1
    return h


public function equal_struct[T](a: const_ptr[T], b: const_ptr[T]) -> bool:
    inline for field in fields_of(T):
        let offset = offset_of(T, field)
        let field_size = size_of(field.type)
        var pa = unsafe: ptr[ubyte]<-a + offset
        var pb = unsafe: ptr[ubyte]<-b + offset
        var i: ptr_uint = 0
        while i < field_size:
            if unsafe: read(pa + i) != read(pb + i):
                return false
            i += 1
    return true


public function order_struct[T](a: const_ptr[T], b: const_ptr[T]) -> int:
    inline for field in fields_of(T):
        let offset = offset_of(T, field)
        let field_size = size_of(field.type)
        var pa = unsafe: ptr[ubyte]<-a + offset
        var pb = unsafe: ptr[ubyte]<-b + offset
        var i: ptr_uint = 0
        while i < field_size:
            let va = unsafe: read(pa + i)
            let vb = unsafe: read(pb + i)
            if va < vb:
                return -1
            else if va > vb:
                return 1
            i += 1
    return 0


# ---------------------------------------------------------------------------
#  ptr_uint (for map keys)
# ---------------------------------------------------------------------------

extending ptr_uint:
    public static function hash(value: const_ptr[ptr_uint]) -> uint:
        unsafe:
            let v = read(ptr[ptr_uint]<-value)
            return uint<-v * 0x01000193


    public static function equal(
        a: const_ptr[ptr_uint],
        b: const_ptr[ptr_uint],
    ) -> bool:
        unsafe:
            return read(ptr[ptr_uint]<-a) == read(ptr[ptr_uint]<-b)
