import std.str as text
import std.string as string


public function is_absolute(path: str) -> bool:
    return root_length(path) != 0


public function normalize_separators(path: str) -> string.String:
    var result = string.String.with_capacity(path.len)

    var index: ptr_uint = 0
    while index < path.len:
        let value = path.byte_at(index)
        if value == ubyte<-92:
            result.push_byte(ubyte<-47)
        else:
            result.push_byte(value)
        index += 1

    return result


public function join(left: str, right: str) -> string.String:
    if left.len == 0:
        return string.String.from_str(right)

    if right.len == 0:
        return string.String.from_str(left)

    if is_absolute(right):
        return string.String.from_str(right)

    var result = string.String.from_str(left)
    let last = result.as_str().byte_at(result.len() - 1)
    if not is_separator(last):
        result.append("/")

    var start: ptr_uint = 0
    while start < right.len and is_separator(right.byte_at(start)):
        start += 1

    if start == right.len:
        return result

    result.append(right.slice(start, right.len - start))
    return result


public function basename(path: str) -> str:
    if path.len == 0:
        return "."

    let root = root_length(path)
    let stop = trim_trailing_separators(path, root)
    if stop == root:
        if root == 0:
            return "."

        return path.slice(0, root)

    var index = stop
    while index > root:
        if is_separator(path.byte_at(index - 1)):
            return path.slice(index, stop - index)
        index -= 1

    if root != 0:
        return path.slice(root, stop - root)

    return path.slice(0, stop)


public function dirname(path: str) -> str:
    if path.len == 0:
        return "."

    let root = root_length(path)
    let stop = trim_trailing_separators(path, root)
    if stop == root:
        if root == 0:
            return "."

        return path.slice(0, root)

    var index = stop
    while index > root:
        if is_separator(path.byte_at(index - 1)):
            var dir_stop = index - 1
            while dir_stop > root and is_separator(path.byte_at(dir_stop - 1)):
                dir_stop -= 1

            if dir_stop == 0:
                return "."

            return path.slice(0, dir_stop)
        index -= 1

    if root != 0:
        return path.slice(0, root)

    return "."


public function extension(path: str) -> Option[str]:
    let name = basename(path)
    match extension_dot(name):
        Option.some as payload:
            return Option[str].some(value= name.slice(payload.value, name.len - payload.value))
        Option.none:
            return Option[str].none


public function stem(path: str) -> str:
    let name = basename(path)
    match extension_dot(name):
        Option.some as payload:
            return name.slice(0, payload.value)
        Option.none:
            return name


function root_length(path: str) -> ptr_uint:
    if path.len == 0:
        return 0

    if is_separator(path.byte_at(0)):
        return 1

    if path.len >= 3 and is_ascii_letter(path.byte_at(0)) and path.byte_at(1) == ubyte<-58 and is_separator(path.byte_at(2)):
        return 3

    return 0


function trim_trailing_separators(path: str, minimum: ptr_uint) -> ptr_uint:
    var stop = path.len
    while stop > minimum and is_separator(path.byte_at(stop - 1)):
        stop -= 1

    return stop


function extension_dot(name: str) -> Option[ptr_uint]:
    var index = name.len
    while index > 0:
        index -= 1
        if name.byte_at(index) == ubyte<-46:
            if index == 0:
                return Option[ptr_uint].none

            return Option[ptr_uint].some(value= index)

    return Option[ptr_uint].none


function is_separator(value: ubyte) -> bool:
    return value == ubyte<-47 or value == ubyte<-92


function is_ascii_letter(value: ubyte) -> bool:
    return (value >= ubyte<-65 and value <= ubyte<-90) or (value >= ubyte<-97 and value <= ubyte<-122)
