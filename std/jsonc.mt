module std.jsonc

import std.ascii as ascii
import std.cjson as cjson
import std.str as text
import std.string as string

pub type JSON = cjson.JSON

pub enum Error: ubyte
    unterminated_string = 1
    unterminated_block_comment = 2
    parse_failed = 3


def append_string_segment(output: ref[string.String], source: str, start: ptr_uint) -> Result[ptr_uint, Error]:
    var index = start
    output.push_byte(text.byte_at(source, index))
    index += 1

    while index < source.len:
        let current = text.byte_at(source, index)
        output.push_byte(current)
        index += 1

        if current == ubyte<-92:
            if index >= source.len:
                return err(Error.unterminated_string)
            output.push_byte(text.byte_at(source, index))
            index += 1
            continue

        if current == ubyte<-34:
            return ok(index)

    return err(Error.unterminated_string)


def skip_line_comment(source: str, start: ptr_uint) -> ptr_uint:
    var index = start
    while index < source.len and text.byte_at(source, index) != ubyte<-10:
        index += 1
    return index


def skip_block_comment(source: str, start: ptr_uint) -> Result[ptr_uint, Error]:
    var index = start
    while index + 1 < source.len:
        if text.byte_at(source, index) == ubyte<-42 and text.byte_at(source, index + 1) == ubyte<-47:
            return ok(index + 2)
        index += 1

    return err(Error.unterminated_block_comment)


def next_significant_index(source: str, start: ptr_uint) -> Result[ptr_uint, Error]:
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
                if not block_end.is_ok:
                    return err(block_end.error)
                index = block_end.value
                continue

        return ok(index)

    return ok(source.len)


pub def normalize(source: str) -> Result[string.String, Error]:
    var output = string.String.with_capacity(source.len)
    var index: ptr_uint = 0

    while index < source.len:
        let current = text.byte_at(source, index)
        if current == ubyte<-34:
            let string_end = append_string_segment(ref_of(output), source, index)
            if not string_end.is_ok:
                output.release()
                return err(string_end.error)
            index = string_end.value
            continue

        if current == ubyte<-47 and index + 1 < source.len:
            let next = text.byte_at(source, index + 1)
            if next == ubyte<-47:
                index = skip_line_comment(source, index + 2)
                continue
            if next == ubyte<-42:
                let block_end = skip_block_comment(source, index + 2)
                if not block_end.is_ok:
                    output.release()
                    return err(block_end.error)
                output.push_byte(ubyte<-32)
                index = block_end.value
                continue

        if current == ubyte<-44:
            let next_index = next_significant_index(source, index + 1)
            if not next_index.is_ok:
                output.release()
                return err(next_index.error)
            if next_index.value < source.len:
                let next_byte = text.byte_at(source, next_index.value)
                if next_byte == ubyte<-125 or next_byte == ubyte<-93:
                    index += 1
                    continue

        output.push_byte(current)
        index += 1

    return ok(output)


pub def parse(source: str) -> Result[ptr[JSON], Error]:
    let normalized_result = normalize(source)
    if not normalized_result.is_ok:
        return err(normalized_result.error)

    var normalized = normalized_result.value
    defer normalized.release()

    let parsed = cjson.parse(normalized.as_str())
    if parsed == null:
        return err(Error.parse_failed)

    unsafe:
        return ok(ptr[JSON]<-parsed)
