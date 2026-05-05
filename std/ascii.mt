module std.ascii


pub def is_digit(byte: ubyte) -> bool:
    return byte >= ubyte<-48 and byte <= ubyte<-57


pub def is_lower(byte: ubyte) -> bool:
    return byte >= ubyte<-97 and byte <= ubyte<-122


pub def is_upper(byte: ubyte) -> bool:
    return byte >= ubyte<-65 and byte <= ubyte<-90


pub def is_alpha(byte: ubyte) -> bool:
    return is_lower(byte) or is_upper(byte)


pub def is_alnum(byte: ubyte) -> bool:
    return is_alpha(byte) or is_digit(byte)


pub def is_hex_digit(byte: ubyte) -> bool:
    return is_digit(byte) or (byte >= ubyte<-97 and byte <= ubyte<-102) or (byte >= ubyte<-65 and byte <= ubyte<-70)


pub def is_space(byte: ubyte) -> bool:
    return byte == ubyte<-32 or byte == ubyte<-9 or byte == ubyte<-10 or byte == ubyte<-13 or byte == ubyte<-12


pub def is_ident_start(byte: ubyte) -> bool:
    return is_alpha(byte) or byte == ubyte<-95


pub def is_ident_continue(byte: ubyte) -> bool:
    return is_ident_start(byte) or is_digit(byte)


pub def to_lower(byte: ubyte) -> ubyte:
    if is_upper(byte):
        return byte + ubyte<-32
    return byte


pub def digit_value(byte: ubyte) -> int:
    if is_digit(byte):
        return int<-(byte - ubyte<-48)
    return -1


pub def hex_digit_value(byte: ubyte) -> int:
    if is_digit(byte):
        return int<-(byte - ubyte<-48)
    if byte >= ubyte<-97 and byte <= ubyte<-102:
        return int<-(byte - ubyte<-97 + ubyte<-10)
    if byte >= ubyte<-65 and byte <= ubyte<-70:
        return int<-(byte - ubyte<-65 + ubyte<-10)
    return -1
