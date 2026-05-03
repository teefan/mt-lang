module std.path

import std.str as text
import std.string as string
import std.vec as vec

struct Segment:
    start: usize
    len: usize

def byte_at(path: str, index: usize) -> u8:
    unsafe:
        return u8<-read(path.data + index)

def segment_text(path: str, segment: Segment) -> str:
    unsafe:
        return str(data = path.data + segment.start, len = segment.len)

def segment_equals(path: str, segment: Segment, value: str) -> bool:
    return text.equal(segment_text(path, segment), value)

pub def is_absolute(path: str) -> bool:
    if path.len == 0:
        return false
    return byte_at(path, 0) == u8<-47

pub def join(left: str, right: str) -> string.String:
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

pub def module_relative_path(module_name: str) -> string.String:
    var result = string.String.with_capacity(module_name.len + 3)
    var index: usize = 0
    while index < module_name.len:
        unsafe:
            let byte = u8<-read(module_name.data + index)
            if byte == u8<-46:
                result.push_byte(u8<-47)
            else:
                result.push_byte(byte)
        index += 1

    result.append(".mt")
    return result

pub def normalize(path: str) -> string.String:
    let absolute = is_absolute(path)
    var segments = vec.create[Segment]()

    var index: usize = 0
    while index < path.len:
        while index < path.len and byte_at(path, index) == u8<-47:
            index += 1

        let start = index
        while index < path.len and byte_at(path, index) != u8<-47:
            index += 1

        let length = index - start
        if length > 0:
            let segment = Segment(start = start, len = length)
            if not segment_equals(path, segment, "."):
                if segment_equals(path, segment, ".."):
                    if vec.count[Segment](segments) > 0:
                        let last_index = vec.count[Segment](segments) - 1
                        let last = vec.get[Segment](segments, last_index)
                        if not segment_equals(path, last, ".."):
                            vec.remove_ordered[Segment](ref_of(segments), last_index)
                        elif not absolute:
                            vec.push[Segment](ref_of(segments), segment)
                    elif not absolute:
                        vec.push[Segment](ref_of(segments), segment)
                else:
                    vec.push[Segment](ref_of(segments), segment)

    var result = string.String.with_capacity(path.len)
    if absolute:
        result.append("/")

    if vec.count[Segment](segments) == 0:
        if not absolute:
            result.append(".")
    else:
        var segment_index: usize = 0
        while segment_index < vec.count[Segment](segments):
            if segment_index > 0:
                result.append("/")
            let segment = vec.get[Segment](segments, segment_index)
            result.append(segment_text(path, segment))
            segment_index += 1

    vec.release[Segment](ref_of(segments))
    return result

pub def expand(path: str, cwd: str) -> string.String:
    if is_absolute(path):
        return normalize(path)

    var joined = join(cwd, path)
    let result = normalize(joined.as_str())
    joined.release()
    return result

pub def basename(path: str) -> string.String:
    if path.len == 0:
        return string.String.from_str(".")

    var stop = path.len
    while stop > 1 and byte_at(path, stop - 1) == u8<-47:
        stop -= 1

    if stop == 1 and byte_at(path, 0) == u8<-47:
        return string.String.from_str("/")

    var start = stop
    while start > 0 and byte_at(path, start - 1) != u8<-47:
        start -= 1

    unsafe:
        return string.String.from_str(str(data = path.data + start, len = stop - start))

pub def dirname(path: str) -> string.String:
    if path.len == 0:
        return string.String.from_str(".")

    var stop = path.len
    while stop > 1 and byte_at(path, stop - 1) == u8<-47:
        stop -= 1

    var slash = stop
    while slash > 0 and byte_at(path, slash - 1) != u8<-47:
        slash -= 1

    if slash == 0:
        return string.String.from_str(".")

    while slash > 1 and byte_at(path, slash - 1) == u8<-47:
        slash -= 1

    unsafe:
        return string.String.from_str(str(data = path.data, len = slash))