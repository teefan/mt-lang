public function encode_u32_be(value: uint) -> array[ubyte, 4]:
    return array[ubyte, 4](
        ubyte<-((value >> 24) & 255),
        ubyte<-((value >> 16) & 255),
        ubyte<-((value >> 8) & 255),
        ubyte<-(value & 255)
    )


public function decode_u32_be(input: span[ubyte], offset: ptr_uint) -> uint:
    return (
        ((uint<-input[offset]) << 24)
        | ((uint<-input[offset + 1]) << 16)
        | ((uint<-input[offset + 2]) << 8)
        | (uint<-input[offset + 3])
    )


public function encode_u64_be(value: ulong) -> array[ubyte, 8]:
    return array[ubyte, 8](
        ubyte<-((value >> 56) & 255),
        ubyte<-((value >> 48) & 255),
        ubyte<-((value >> 40) & 255),
        ubyte<-((value >> 32) & 255),
        ubyte<-((value >> 24) & 255),
        ubyte<-((value >> 16) & 255),
        ubyte<-((value >> 8) & 255),
        ubyte<-(value & 255)
    )


public function decode_u64_be(input: span[ubyte], offset: ptr_uint) -> ulong:
    return (
        ((ulong<-input[offset]) << 56)
        | ((ulong<-input[offset + 1]) << 48)
        | ((ulong<-input[offset + 2]) << 40)
        | ((ulong<-input[offset + 3]) << 32)
        | ((ulong<-input[offset + 4]) << 24)
        | ((ulong<-input[offset + 5]) << 16)
        | ((ulong<-input[offset + 6]) << 8)
        | (ulong<-input[offset + 7])
    )
