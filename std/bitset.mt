import std.mem.heap as heap

public struct Bitset:
    words: ptr[ptr_uint]?
    word_count: ptr_uint
    bit_count: ptr_uint

const WORD_BITS: ptr_uint = 8 * size_of(ptr_uint)


function word_index(bit_index: ptr_uint) -> ptr_uint:
    return bit_index / WORD_BITS


function bit_offset(bit_index: ptr_uint) -> ptr_uint:
    return bit_index % WORD_BITS


function popcount_word(word: ptr_uint) -> ptr_uint:
    var count: ptr_uint = 0
    var value = word
    while value != 0:
        count += 1
        value = value & value - 1
    return count


function find_first_set_in_word(word: ptr_uint) -> Option[ptr_uint]:
    if word == 0:
        return Option[ptr_uint].none
    var index: ptr_uint = 0
    var value = word
    while (value & ptr_uint<-1) == 0:
        value = value >> ptr_uint<-1
        index += 1
    return Option[ptr_uint].some(value = index)


public function create() -> Bitset:
    return Bitset(words = null, word_count = 0, bit_count = 0)


public function with_capacity(min_bits: ptr_uint) -> Bitset:
    var result = create()
    result.reserve(min_bits)
    return result


extending Bitset:
    public function len() -> ptr_uint:
        return this.bit_count


    public function is_empty() -> bool:
        return this.bit_count == 0


    public editable function set(index: ptr_uint) -> void:
        let wi = word_index(index)
        if wi >= this.word_count:
            this.reserve(index + 1)
        let words = this.words else:
            fatal(c"bitset.set missing storage")
        let bit = bit_offset(index)
        unsafe:
            let word_ptr = words + wi
            read(word_ptr) = read(word_ptr) | ptr_uint<-1 << bit


    public editable function clear(index: ptr_uint) -> void:
        let wi = word_index(index)
        if wi >= this.word_count:
            return
        let words = this.words else:
            return
        let bit = bit_offset(index)
        unsafe:
            let word_ptr = words + wi
            read(word_ptr) = read(word_ptr) & ~(ptr_uint<-1 << bit)


    public function test(index: ptr_uint) -> bool:
        let wi = word_index(index)
        if wi >= this.word_count:
            return false
        let words = this.words else:
            return false
        let bit = bit_offset(index)
        unsafe:
            let word_ptr = words + wi
            return (read(word_ptr) >> bit & ptr_uint<-1) != 0


    public editable function toggle(index: ptr_uint) -> void:
        let wi = word_index(index)
        if wi >= this.word_count:
            this.reserve(index + 1)
        let words = this.words else:
            fatal(c"bitset.toggle missing storage")
        let bit = bit_offset(index)
        unsafe:
            let word_ptr = words + wi
            read(word_ptr) = read(word_ptr) ^ ptr_uint<-1 << bit


    public function count() -> ptr_uint:
        if this.words == null:
            return 0
        var total: ptr_uint = 0
        unsafe:
            var wi: ptr_uint = 0
            while wi < this.word_count:
                let w = read(ptr[ptr_uint]<-this.words + wi)
                total += popcount_word(w)
                wi += 1
        return total


    public function any() -> bool:
        if this.words == null:
            return false
        unsafe:
            var wi: ptr_uint = 0
            while wi < this.word_count:
                let w = read(ptr[ptr_uint]<-this.words + wi)
                if w != 0:
                    return true
                wi += 1
        return false


    public function all() -> bool:
        if this.bit_count == 0:
            return false
        if this.words == null:
            return false
        let full_words = this.word_count - 1
        let remaining_bits = this.bit_count - full_words * WORD_BITS
        unsafe:
            var wi: ptr_uint = 0
            while wi < full_words:
                let w = read(ptr[ptr_uint]<-this.words + wi)
                if w != ~ptr_uint<-0:
                    return false
                wi += 1
            if remaining_bits > 0:
                let last = read(ptr[ptr_uint]<-this.words + full_words)
                let mask = (ptr_uint<-1 << remaining_bits) - ptr_uint<-1
                if last != mask:
                    return false
        return true


    public function none() -> bool:
        return not this.any()


    public function find_first_set() -> Option[ptr_uint]:
        if this.words == null:
            return Option[ptr_uint].none
        unsafe:
            var wi: ptr_uint = 0
            while wi < this.word_count:
                let w = read(ptr[ptr_uint]<-this.words + wi)
                let found = find_first_set_in_word(w)
                match found:
                    Option.some as payload:
                        return Option[ptr_uint].some(value = wi * WORD_BITS + payload.value)
                    Option.none:
                        pass
                wi += 1
        return Option[ptr_uint].none


    public function find_first_clear() -> Option[ptr_uint]:
        if this.bit_count == 0:
            return Option[ptr_uint].some(value = 0)
        if this.words == null:
            return Option[ptr_uint].some(value = 0)
        let full_words = this.word_count - 1
        let remaining_bits = this.bit_count - full_words * WORD_BITS
        unsafe:
            var wi: ptr_uint = 0
            while wi < full_words:
                let w = read(ptr[ptr_uint]<-this.words + wi)
                if w != ~ptr_uint<-0:
                    let inverted = ~w
                    let found = find_first_set_in_word(inverted)
                    match found:
                        Option.some as payload:
                            return Option[ptr_uint].some(value = wi * WORD_BITS + payload.value)
                        Option.none:
                            pass
                wi += 1
            if remaining_bits > 0:
                let last = read(ptr[ptr_uint]<-this.words + full_words)
                let mask = (ptr_uint<-1 << remaining_bits) - ptr_uint<-1
                if last != mask:
                    let inverted = ~last & mask
                    let found = find_first_set_in_word(inverted)
                    match found:
                        Option.some as payload:
                            return Option[ptr_uint].some(value = full_words * WORD_BITS + payload.value)
                        Option.none:
                            pass
        return Option[ptr_uint].some(value = this.bit_count)


    public editable function clear_all() -> void:
        if this.words == null:
            return
        unsafe:
            var wi: ptr_uint = 0
            while wi < this.word_count:
                read(ptr[ptr_uint]<-this.words + wi) = 0
                wi += 1


    public editable function reserve(min_bits: ptr_uint) -> void:
        if min_bits <= this.bit_count:
            return
        let new_word_count = word_index(min_bits + WORD_BITS - 1)
        let resized = heap.resize[ptr_uint](this.words, new_word_count) else:
            fatal(c"bitset.reserve out of memory")
        this.words = resized
        unsafe:
            var wi = this.word_count
            while wi < new_word_count:
                read(ptr[ptr_uint]<-this.words + wi) = 0
                wi += 1
        this.word_count = new_word_count
        this.bit_count = new_word_count * WORD_BITS


    public editable function release() -> void:
        heap.release(this.words)
        this.words = null
        this.word_count = 0
        this.bit_count = 0
