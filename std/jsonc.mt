module std.jsonc

import std.ascii as ascii
import std.cjson as cjson
import std.status as status
import std.str as text
import std.string as string

public type JSON = cjson.JSON

public enum Error: ubyte
    unterminated_string = 1
    unterminated_block_comment = 2
    parse_failed = 3


function append_string_segment(output: ref[string.String], source: str, start: ptr_uint) -> status.Status[ptr_uint, Error]:
    var index = start
    output.push_byte(text.byte_at(source, index))
    index += 1

    while index < source.len:
        let current = text.byte_at(source, index)
        output.push_byte(current)
        index += 1

        if current == ubyte<-92:
            if index >= source.len:
                return status.Status[ptr_uint, Error].err(error= Error.unterminated_string)
            output.push_byte(text.byte_at(source, index))
            index += 1
            continue

        if current == ubyte<-34:
            return status.Status[ptr_uint, Error].ok(value= index)

    return status.Status[ptr_uint, Error].err(error= Error.unterminated_string)


function skip_line_comment(source: str, start: ptr_uint) -> ptr_uint:
    var index = start
    while index < source.len and text.byte_at(source, index) != ubyte<-10:
        index += 1
    return index


function skip_block_comment(source: str, start: ptr_uint) -> status.Status[ptr_uint, Error]:
    var index = start
    while index + 1 < source.len:
        if text.byte_at(source, index) == ubyte<-42 and text.byte_at(source, index + 1) == ubyte<-47:
            return status.Status[ptr_uint, Error].ok(value= index + 2)
        index += 1

    return status.Status[ptr_uint, Error].err(error= Error.unterminated_block_comment)


function next_significant_index(source: str, start: ptr_uint) -> status.Status[ptr_uint, Error]:
    var index = start
    while index < source.len:
        let current = text.byte_at(source, index)
        if ascii.is_space(current):
            index += 1
            continue

        if current == ubyte<-47 and index + 1 < source.len:
            let next = text.byte_at(source, index + 1)
            if next == ubyte<-47:
                index = skip_line_comment(source, index + 2)
                continue
            if next == ubyte<-42:
                let block_end = skip_block_comment(source, index + 2)
                match block_end:
                    status.Status.err as payload:
                        return status.Status[ptr_uint, Error].err(error= payload.error)
                    status.Status.ok as payload:
                        index = payload.value
                continue

        return status.Status[ptr_uint, Error].ok(value= index)

    return status.Status[ptr_uint, Error].ok(value= source.len)


public function normalize(source: str) -> status.Status[string.String, Error]:
    var output = string.String.with_capacity(source.len)
    var index: ptr_uint = 0

    while index < source.len:
        let current = text.byte_at(source, index)
        if current == ubyte<-34:
            let string_end = append_string_segment(ref_of(output), source, index)
            match string_end:
                status.Status.err as payload:
                    output.release()
                    return status.Status[string.String, Error].err(error= payload.error)
                status.Status.ok as payload:
                    index = payload.value
            continue

        if current == ubyte<-47 and index + 1 < source.len:
            let next = text.byte_at(source, index + 1)
            if next == ubyte<-47:
                index = skip_line_comment(source, index + 2)
                continue
            if next == ubyte<-42:
                let block_end = skip_block_comment(source, index + 2)
                match block_end:
                    status.Status.err as payload:
                        output.release()
                        return status.Status[string.String, Error].err(error= payload.error)
                    status.Status.ok as payload:
                        output.push_byte(ubyte<-32)
                        index = payload.value
                        continue

        if current == ubyte<-44:
            let next_index = next_significant_index(source, index + 1)
            var next_value: ptr_uint = 0
            match next_index:
                status.Status.err as payload:
                    output.release()
                    return status.Status[string.String, Error].err(error= payload.error)
                status.Status.ok as payload:
                    next_value = payload.value
            if next_value < source.len:
                let next_byte = text.byte_at(source, next_value)
                if next_byte == ubyte<-125 or next_byte == ubyte<-93:
                    index += 1
                    continue

        output.push_byte(current)
        index += 1

    return status.Status[string.String, Error].ok(value= output)


public function parse(source: str) -> status.Status[ptr[JSON], Error]:
    let normalized_result = normalize(source)
    match normalized_result:
        status.Status.err as payload:
            return status.Status[ptr[JSON], Error].err(error= payload.error)
        status.Status.ok as payload:
            var normalized = payload.value
            defer normalized.release()

            let parsed = cjson.parse(normalized.as_str())
            if parsed == null:
                return status.Status[ptr[JSON], Error].err(error= Error.parse_failed)

            unsafe:
                return status.Status[ptr[JSON], Error].ok(value= ptr[JSON]<-parsed)
