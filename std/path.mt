module std.path

import std.string as string

pub def join(left: str, right: str) -> string.String:
    if left.len == 0:
        return string.from_str(right)
    if right.len == 0:
        return string.from_str(left)

    unsafe:
        if deref(right.data) == cast[char](47):
            return string.from_str(right)

    var result = string.with_capacity(left.len + right.len + 1)
    string.append(addr(result), left)

    unsafe:
        let last = deref(left.data + (left.len - 1))
        if last != cast[char](47):
            string.append(addr(result), "/")

    string.append(addr(result), right)
    return result

pub def module_relative_path(module_name: str) -> string.String:
    var result = string.with_capacity(module_name.len + 3)
    var index: usize = 0
    while index < module_name.len:
        unsafe:
            let byte = cast[u8](deref(module_name.data + index))
            if byte == cast[u8](46):
                string.push_byte(addr(result), cast[u8](47))
            else:
                string.push_byte(addr(result), byte)
        index += 1

    string.append(addr(result), ".mt")
    return result
