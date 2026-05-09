module std.path

import std.str as text
import std.string as string
import std.vec as vec

struct Segment:
    start: ptr_uint
    len: ptr_uint


function byte_at(path: str, index: ptr_uint) -> ubyte:
    return unsafe: ubyte<-read(path.data + index)


function segment_text(path: str, segment: Segment) -> str:
    return unsafe: str(data = path.data + segment.start, len = segment.len)


function segment_equals(path: str, segment: Segment, value: str) -> bool:
    return text.equal(segment_text(path, segment), value)


public function is_absolute(path: str) -> bool:
    if path.len == 0:
        return false
    return byte_at(path, 0) == ubyte<-47


public function join(left: str, right: str) -> string.String:
    if left.len == 0:
        return string.String.from_str(right)
    if right.len == 0:
        return string.String.from_str(left)

    unsafe:
        if read(right.data) == char<-47:
            return string.String.from_str(right)

    var result = string.String.with_capacity(left.len + right.len + 1)
    result.append(left)

    unsafe:
        let last = read(left.data + (left.len - 1))
        if last != char<-47:
            result.append("/")

    result.append(right)
    return result


public function module_relative_path(module_name: str) -> string.String:
    var result = string.String.with_capacity(module_name.len + 3)
    var index: ptr_uint = 0
    while index < module_name.len:
        unsafe:
            let byte = ubyte<-read(module_name.data + index)
            if byte == ubyte<-46:
                result.push_byte(ubyte<-47)
            else:
                result.push_byte(byte)
        index += 1

    result.append(".mt")
    return result


public function normalize(path: str) -> string.String:
    let absolute = is_absolute(path)
    var segments = vec.Vec[Segment].create()

    var index: ptr_uint = 0
    while index < path.len:
        while index < path.len and byte_at(path, index) == ubyte<-47:
            index += 1

        let start = index
        while index < path.len and byte_at(path, index) != ubyte<-47:
            index += 1

        let length = index - start
        if length > 0:
            let segment = Segment(start = start, len = length)
            if not segment_equals(path, segment, "."):
                if segment_equals(path, segment, ".."):
                    if segments.count() > 0:
                        let last_index = segments.count() - 1
                        let last = segments.get(last_index)
                        if not segment_equals(path, last, ".."):
                            segments.remove_ordered(last_index)
                        elif not absolute:
                            segments.push(segment)
                    elif not absolute:
                        segments.push(segment)
                else:
                    segments.push(segment)

    var result = string.String.with_capacity(path.len)
    if absolute:
        result.append("/")

    if segments.count() == 0:
        if not absolute:
            result.append(".")
    else:
        var segment_index: ptr_uint = 0
        while segment_index < segments.count():
            if segment_index > 0:
                result.append("/")
            let segment = segments.get(segment_index)
            result.append(segment_text(path, segment))
            segment_index += 1

    segments.release()
    return result


public function expand(path: str, cwd: str) -> string.String:
    if is_absolute(path):
        return normalize(path)

    var joined = join(cwd, path)
    let result = normalize(joined.as_str())
    joined.release()
    return result


public function basename(path: str) -> string.String:
    if path.len == 0:
        return string.String.from_str(".")

    var stop = path.len
    while stop > 1 and byte_at(path, stop - 1) == ubyte<-47:
        stop -= 1

    if stop == 1 and byte_at(path, 0) == ubyte<-47:
        return string.String.from_str("/")

    var start = stop
    while start > 0 and byte_at(path, start - 1) != ubyte<-47:
        start -= 1

    return unsafe: string.String.from_str(str(data = path.data + start, len = stop - start))


public function dirname(path: str) -> string.String:
    if path.len == 0:
        return string.String.from_str(".")

    var stop = path.len
    while stop > 1 and byte_at(path, stop - 1) == ubyte<-47:
        stop -= 1

    var slash = stop
    while slash > 0 and byte_at(path, slash - 1) != ubyte<-47:
        slash -= 1

    if slash == 0:
        return string.String.from_str(".")

    while slash > 1 and byte_at(path, slash - 1) == ubyte<-47:
        slash -= 1

    return unsafe: string.String.from_str(str(data = path.data, len = slash))
