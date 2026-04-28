module std.ascii

pub def is_digit(byte: u8) -> bool:
    return byte >= cast[u8](48) and byte <= cast[u8](57)

pub def is_lower(byte: u8) -> bool:
    return byte >= cast[u8](97) and byte <= cast[u8](122)

pub def is_upper(byte: u8) -> bool:
    return byte >= cast[u8](65) and byte <= cast[u8](90)

pub def is_alpha(byte: u8) -> bool:
    return is_lower(byte) or is_upper(byte)

pub def is_alnum(byte: u8) -> bool:
    return is_alpha(byte) or is_digit(byte)

pub def is_hex_digit(byte: u8) -> bool:
    return is_digit(byte) or (byte >= cast[u8](97) and byte <= cast[u8](102)) or (byte >= cast[u8](65) and byte <= cast[u8](70))

pub def is_space(byte: u8) -> bool:
    return byte == cast[u8](32) or byte == cast[u8](9) or byte == cast[u8](10) or byte == cast[u8](13) or byte == cast[u8](12)

pub def is_ident_start(byte: u8) -> bool:
    return is_alpha(byte) or byte == cast[u8](95)

pub def is_ident_continue(byte: u8) -> bool:
    return is_ident_start(byte) or is_digit(byte)

pub def to_lower(byte: u8) -> u8:
    if is_upper(byte):
        return byte + cast[u8](32)
    return byte

pub def digit_value(byte: u8) -> i32:
    if is_digit(byte):
        return cast[i32](byte - cast[u8](48))
    return -1

pub def hex_digit_value(byte: u8) -> i32:
    if is_digit(byte):
        return cast[i32](byte - cast[u8](48))
    if byte >= cast[u8](97) and byte <= cast[u8](102):
        return cast[i32](byte - cast[u8](97) + cast[u8](10))
    if byte >= cast[u8](65) and byte <= cast[u8](70):
        return cast[i32](byte - cast[u8](65) + cast[u8](10))
    return -1
