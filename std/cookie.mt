import std.str as text
import std.string as string
import std.time as time

public struct Cookie:
    name: string.String
    value: string.String
    domain: Option[string.String]
    path: Option[string.String]
    max_age: Option[ptr_int]
    expires: Option[time.Timestamp]
    secure: bool
    http_only: bool
    same_site: Option[string.String]


public function parse_set_cookie(header_value: str) -> Option[Cookie]:
    var pos: ptr_uint = 0

    let semi = find_byte_from(header_value, 59, pos)
    var end = header_value.len
    match semi:
        Option.none:
            pass
        Option.some as s:
            end = s.value

    let part = header_value.slice(pos, end - pos).trim_ascii_whitespace()
    if part.len == 0:
        return Option[Cookie].none

    var cookie = parse_name_value(part)?
    match semi:
        Option.none:
            return Option[Cookie].some(value = cookie)
        Option.some as s:
            pos = s.value + 1

    while pos < header_value.len:
        let next_semi = find_byte_from(header_value, 59, pos)
        var next_end = header_value.len
        match next_semi:
            Option.none:
                pass
            Option.some as ns:
                next_end = ns.value

        let next_part = header_value.slice(pos, next_end - pos).trim_ascii_whitespace()
        if next_part.len > 0:
            apply_attribute(ref_of(cookie), next_part)

        match next_semi:
            Option.none:
                pos = header_value.len
            Option.some as ns:
                pos = ns.value + 1

    return Option[Cookie].some(value = cookie)


function parse_name_value(text_value: str) -> Option[Cookie]:
    let eq = text_value.find_byte(61)
    match eq:
        Option.none:
            return Option[Cookie].none
        Option.some as e:
            let name_text = text_value.slice(0, e.value).trim_ascii_whitespace()
            let value_text = text_value.slice(e.value + 1, text_value.len - e.value - 1).trim_ascii_whitespace()

            var cookie_value = string.String.from_str(value_text)
            if cookie_value.len() >= 2 and cookie_value.as_str().byte_at(0) == 34:
                let last = cookie_value.len() - 1
                if cookie_value.as_str().byte_at(last) == 34:
                    let inner = cookie_value.as_str().slice(1, last - 1)
                    cookie_value.assign(inner)

            let cookie = Cookie(
                name = string.String.from_str(name_text),
                value = cookie_value,
                domain = Option[string.String].none,
                path = Option[string.String].none,
                max_age = Option[ptr_int].none,
                expires = Option[time.Timestamp].none,
                secure = false,
                http_only = false,
                same_site = Option[string.String].none
            )

            return Option[Cookie].some(value = cookie)


function apply_attribute(cookie: ref[Cookie], attribute_text: str) -> void:
    let eq = attribute_text.find_byte(61)
    match eq:
        Option.none:
            var normalized = ascii_lower(attribute_text)
            defer normalized.release()

            if normalized.as_str().equal("secure"):
                cookie.secure = true
            else if normalized.as_str().equal("httponly"):
                cookie.http_only = true

        Option.some as e:
            let key_text = attribute_text.slice(0, e.value).trim_ascii_whitespace()
            let value_text = attribute_text.slice(e.value + 1, attribute_text.len - e.value - 1).trim_ascii_whitespace()

            var normalized_key = ascii_lower(key_text)
            defer normalized_key.release()

            if normalized_key.as_str().equal("domain"):
                cookie.domain = Option[string.String].some(value = string.String.from_str(value_text))
            else if normalized_key.as_str().equal("path"):
                cookie.path = Option[string.String].some(value = string.String.from_str(value_text))
            else if normalized_key.as_str().equal("max-age"):
                let parsed = parse_decimal(value_text)
                match parsed:
                    Option.some as payload:
                        cookie.max_age = Option[ptr_int].some(value = ptr_int<-payload.value)
                    Option.none:
                        pass
            else if normalized_key.as_str().equal("samesite"):
                cookie.same_site = Option[string.String].some(value = ascii_lower(value_text))


public function format_cookie(cookie: Cookie) -> string.String:
    var result = string.String.with_capacity(cookie.name.len() + cookie.value.len() + 128)

    result.append(cookie.name.as_str())
    result.push_byte(61)
    result.append(cookie.value.as_str())

    return result


function ascii_lower(text_value: str) -> string.String:
    var result = string.String.with_capacity(text_value.len)
    var index: ptr_uint = 0
    while index < text_value.len:
        let value = text_value.byte_at(index)
        if value >= 65 and value <= 90:
            result.push_byte(value + 32)
        else:
            result.push_byte(value)
        index += 1

    return result


function find_byte_from(data: str, target: ubyte, start: ptr_uint) -> Option[ptr_uint]:
    var index = start
    while index < data.len:
        if data.byte_at(index) == target:
            return Option[ptr_uint].some(value = index)
        index += 1

    return Option[ptr_uint].none


function parse_decimal(text_value: str) -> Option[ptr_uint]:
    if text_value.len == 0:
        return Option[ptr_uint].none

    var value: ptr_uint = 0
    var index: ptr_uint = 0
    while index < text_value.len:
        let current = text_value.byte_at(index)
        if current < 48 or current > 57:
            return Option[ptr_uint].none

        value = value * 10 + ptr_uint<-(current - 48)
        index += 1

    return Option[ptr_uint].some(value = value)


extending Cookie:
    public editable function release() -> void:
        this.name.release()
        this.value.release()

        match this.domain:
            Option.some as payload:
                payload.value.release()
            Option.none:
                pass

        match this.path:
            Option.some as payload:
                payload.value.release()
            Option.none:
                pass

        match this.same_site:
            Option.some as payload:
                payload.value.release()
            Option.none:
                pass
