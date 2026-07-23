public function swap_ushort(value: ushort) -> ushort:
    return ushort<-(
        ((uint<-value & 0x00ff) << 8) |
        ((uint<-value & 0xff00) >> 8)
    )


public function swap_uint(value: uint) -> uint:
    return (
        ((value & 0x000000ff) << 24) |
        ((value & 0x0000ff00) << 8) |
        ((value & 0x00ff0000) >> 8) |
        ((value & 0xff000000) >> 24)
    )


public function swap_ulong(value: ulong) -> ulong:
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


public function hton_ushort(value: ushort) -> ushort:
    return swap_ushort(value)


public function hton_uint(value: uint) -> uint:
    return swap_uint(value)


public function hton_ulong(value: ulong) -> ulong:
    return swap_ulong(value)


public function ntoh_ushort(value: ushort) -> ushort:
    return swap_ushort(value)


public function ntoh_uint(value: uint) -> uint:
    return swap_uint(value)


public function ntoh_ulong(value: ulong) -> ulong:
    return swap_ulong(value)
