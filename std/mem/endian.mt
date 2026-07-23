public function swap_u16(value: ushort) -> ushort:
    return ushort<-(
        ((uint<-value & 0x00ff) << 8) |
        ((uint<-value & 0xff00) >> 8)
    )


public function swap_u32(value: uint) -> uint:
    return (
        ((value & 0x000000ff) << 24) |
        ((value & 0x0000ff00) << 8) |
        ((value & 0x00ff0000) >> 8) |
        ((value & 0xff000000) >> 24)
    )


public function swap_u64(value: ulong) -> ulong:
    return (
        ((value & 0x00000000000000fful) << 56) |
        ((value & 0x000000000000ff00ul) << 40) |
        ((value & 0x0000000000ff0000ul) << 24) |
        ((value & 0x00000000ff000000ul) << 8) |
        ((value & 0x000000ff00000000ul) >> 8) |
        ((value & 0x0000ff0000000000ul) >> 24) |
        ((value & 0x00ff000000000000ul) >> 40) |
        ((value & 0xff00000000000000ul) >> 56)
    )


public function hton16(value: ushort) -> ushort:
    return swap_u16(value)


public function hton32(value: uint) -> uint:
    return swap_u32(value)


public function hton64(value: ulong) -> ulong:
    return swap_u64(value)


public function ntoh16(value: ushort) -> ushort:
    return swap_u16(value)


public function ntoh32(value: uint) -> uint:
    return swap_u32(value)


public function ntoh64(value: ulong) -> ulong:
    return swap_u64(value)
