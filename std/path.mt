import std.str as text_ops
import std.string as string
import std.vec as vec


struct Segment:
    start: ptr_uint
    len: ptr_uint


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


public function relative_path(path: str, base: str) -> Option[string.String]:
    var normalized_path = normalize_separators(path)
    defer normalized_path.release()
    var normalized_base = normalize_separators(base)
    defer normalized_base.release()

    let path_text = normalized_path.as_str()
    let base_text = normalized_base.as_str()
    let path_root = root_length(path_text)
    let base_root = root_length(base_text)
    if not roots_compatible(path_text, path_root, base_text, base_root):
        return Option[string.String].none

    var path_segments = vec.Vec[Segment].create()
    defer path_segments.release()
    collect_normalized_segments(path_text, path_root, ref_of(path_segments))

    var base_segments = vec.Vec[Segment].create()
    defer base_segments.release()
    collect_normalized_segments(base_text, base_root, ref_of(base_segments))

    var common: ptr_uint = 0
    let shared_len = min_ptr_uint(path_segments.len(), base_segments.len())
    while common < shared_len:
        let path_segment_ptr = path_segments.get(common) else:
            fatal(c"path.relative_path missing path segment")
        let base_segment_ptr = base_segments.get(common) else:
            fatal(c"path.relative_path missing base segment")

        unsafe:
            if not segments_equal(path_text, read(path_segment_ptr), base_text, read(base_segment_ptr)):
                break

        common += 1

    var result = string.String.with_capacity(path_text.len + base_text.len)
    var index: ptr_uint = common
    while index < base_segments.len():
        append_relative_segment(ref_of(result), "..")
        index += 1

    index = common
    while index < path_segments.len():
        let path_segment_ptr = path_segments.get(index) else:
            fatal(c"path.relative_path missing path segment for append")

        unsafe:
            append_relative_segment(ref_of(result), segment_text(path_text, read(path_segment_ptr)))

        index += 1

    if result.is_empty():
        result.append(".")

    return Option[string.String].some(value= result)


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


function roots_compatible(left: str, left_root: ptr_uint, right: str, right_root: ptr_uint) -> bool:
    if left_root != right_root:
        return false

    if left_root == 0:
        return true

    if left_root == 1:
        return true

    if left_root == 3 and left.byte_at(1) == ubyte<-58 and right.byte_at(1) == ubyte<-58:
        return ascii_fold(left.byte_at(0)) == ascii_fold(right.byte_at(0))

    var index: ptr_uint = 0
    while index < left_root:
        if left.byte_at(index) != right.byte_at(index):
            return false

        index += 1

    return true


function ascii_fold(value: ubyte) -> ubyte:
    if value >= ubyte<-65 and value <= ubyte<-90:
        return value + ubyte<-32

    return value


function collect_normalized_segments(path: str, root: ptr_uint, output: ref[vec.Vec[Segment]]) -> void:
    var index = root
    while index < path.len:
        while index < path.len and is_separator(path.byte_at(index)):
            index += 1

        if index == path.len:
            return

        let segment_start = index
        while index < path.len and not is_separator(path.byte_at(index)):
            index += 1

        let segment_len = index - segment_start
        if segment_is_current_directory(path, segment_start, segment_len):
            continue

        if segment_is_parent_directory(path, segment_start, segment_len):
            let last_segment_ptr = output.last()
            if last_segment_ptr != null:
                unsafe:
                    let last_segment = read(last_segment_ptr)
                    if not segment_is_parent_directory(path, last_segment.start, last_segment.len):
                        match output.pop():
                            Option.some as _:
                                pass
                            Option.none:
                                fatal(c"path.collect_normalized_segments failed to pop segment")
                        continue

            if root == 0:
                output.push(Segment(start = segment_start, len = segment_len))

            continue

        output.push(Segment(start = segment_start, len = segment_len))


function segment_is_current_directory(path: str, start: ptr_uint, len: ptr_uint) -> bool:
    return len == 1 and path.byte_at(start) == ubyte<-46


function segment_is_parent_directory(path: str, start: ptr_uint, len: ptr_uint) -> bool:
    return len == 2 and path.byte_at(start) == ubyte<-46 and path.byte_at(start + 1) == ubyte<-46


function segments_equal(left: str, left_segment: Segment, right: str, right_segment: Segment) -> bool:
    if left_segment.len != right_segment.len:
        return false

    var index: ptr_uint = 0
    while index < left_segment.len:
        if left.byte_at(left_segment.start + index) != right.byte_at(right_segment.start + index):
            return false

        index += 1

    return true


function segment_text(path: str, segment: Segment) -> str:
    return path.slice(segment.start, segment.len)


function append_relative_segment(output: ref[string.String], segment: str) -> void:
    if not output.is_empty():
        output.append("/")

    output.append(segment)


function min_ptr_uint(left: ptr_uint, right: ptr_uint) -> ptr_uint:
    if left < right:
        return left

    return right


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
