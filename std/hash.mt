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
            return uint<-reinterpret[uint](read(ptr[double]<-value))


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
