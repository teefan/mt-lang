# POC 019 — Format strings and str_buffer: f"..." with interpolations,
# precision :.N, integer format :x/:X/:o/:O/:b/:B, str_buffer methods.

function main() -> int:
    let count = 42
    let name = "world"
    let pi = 3.14159f
    let hex_val = 255

    # basic interpolation
    let msg = f"hello #{name}, count=#{count}"
    let _msg = msg

    # float precision
    let pi_str = f"pi=#{pi:.2}"
    let _ps = pi_str

    # integer formats
    let hex = f"hex=#{hex_val:x}"
    let HEX = f"HEX=#{hex_val:X}"
    let oct = f"oct=#{hex_val:o}"
    let OCT = f"OCT=#{hex_val:O}"
    let bin = f"bin=#{hex_val:b}"
    let BIN = f"BIN=#{hex_val:B}"
    let _h = hex
    let _H = HEX
    let _oct = oct
    let _OCT = OCT
    let _bin = bin
    let _BIN = BIN

    # str_buffer methods
    var buf: str_buffer[64]
    buf.assign("start")
    buf.append(" middle")
    buf.append_format(f" #{count}")
    buf.assign_format(f"reset to #{count}")

    let bl = buf.len()
    let bc = buf.capacity()
    let _bl = bl
    let _bc = bc

    let s = buf.as_str()
    let _s = s

    let cs = buf.as_cstr()
    let _cs = cs

    buf.clear()

    return 0
