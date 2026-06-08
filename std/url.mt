import std.str as text
import std.string as string
import std.vec as vec


function is_unreserved(value: ubyte) -> bool:
    return (
        (value >= 48 and value <= 57)
        or (value >= 65 and value <= 90)
        or (value >= 97 and value <= 122)
        or value == 45
        or value == 46
        or value == 95
        or value == 126
    )


function hex_digit(value: ubyte) -> ubyte:
    if value < 10:
        return 48 + value

    return 65 + (value - 10)


function hex_value(value: ubyte) -> int:
    if value >= 48 and value <= 57:
        return int<-(value - ubyte<-48)
    if value >= 65 and value <= 70:
        return 10 + int<-(value - ubyte<-65)
    if value >= 97 and value <= 102:
        return 10 + int<-(value - ubyte<-97)

    return -1


function find_byte_from(data: str, target: ubyte, start: ptr_uint) -> Option[ptr_uint]:
    var index = start
    while index < data.len:
        if data.byte_at(index) == target:
            return Option[ptr_uint].some(value = index)
        index += 1

    return Option[ptr_uint].none


public function percent_encode(text_value: str) -> string.String:
    var result = string.String.with_capacity(text_value.len * 3)
    var index: ptr_uint = 0
    while index < text_value.len:
        let value = text_value.byte_at(index)
        if is_unreserved(value):
            result.push_byte(value)
        else:
            result.push_byte(37)
            result.push_byte(hex_digit(value >> 4))
            result.push_byte(hex_digit(value & 0x0F))
        index += 1

    return result


public function percent_decode(text_value: str) -> Option[string.String]:
    var result = string.String.with_capacity(text_value.len)
    var index: ptr_uint = 0
    while index < text_value.len:
        let value = text_value.byte_at(index)
        if value != 37:
            result.push_byte(value)
            index += 1
            continue

        if index + 2 >= text_value.len:
            result.release()
            return Option[string.String].none

        let high = hex_value(text_value.byte_at(index + 1))
        let low = hex_value(text_value.byte_at(index + 2))
        if high < 0 or low < 0:
            result.release()
            return Option[string.String].none

        let decoded = ubyte<-(high * 16 + low)
        result.push_byte(decoded)
        index += 3

    return Option[string.String].some(value = result)

public struct QueryParam:
    key: string.String
    value: string.String


public function parse_query(url: str) -> Result[vec.Vec[QueryParam], string.String]:
    var params = vec.Vec[QueryParam].create()

    let question = url.find_byte(63)
    var rest: str = zero[str]
    match question:
        Option.none:
            return Result[vec.Vec[QueryParam], string.String].success(value = params)
        Option.some as q:
            rest = url.slice(q.value + 1, url.len - q.value - 1)

    let fragment = rest.find_byte(35)
    match fragment:
        Option.none:
            pass
        Option.some as f:
            rest = rest.slice(0, f.value)

    if rest.len == 0:
        return Result[vec.Vec[QueryParam], string.String].success(value = params)

    var start: ptr_uint = 0
    while start < rest.len:
        let amp = find_byte_from(rest, 38, start)
        match amp:
            Option.none:
                let pair_text = rest.slice(start, rest.len - start)
                let pair_result = parse_query_pair(pair_text)
                match pair_result:
                    Result.failure as payload:
                        release_params(ref_of(params))
                        return Result[
                            vec.Vec[QueryParam],
                            string.String
                        ].failure(error = payload.error)
                    Result.success as payload:
                        params.push(payload.value)

                start = rest.len
            Option.some as a:
                let pair_text = rest.slice(start, a.value - start)
                let pair_result = parse_query_pair(pair_text)
                match pair_result:
                    Result.failure as payload:
                        release_params(ref_of(params))
                        return Result[
                            vec.Vec[QueryParam],
                            string.String
                        ].failure(error = payload.error)
                    Result.success as payload:
                        params.push(payload.value)

                start = a.value + 1

    return Result[vec.Vec[QueryParam], string.String].success(value = params)


function parse_query_pair(text_value: str) -> Result[QueryParam, string.String]:
    let eq = text_value.find_byte(61)
    match eq:
        Option.none:
            let decoded_key = percent_decode(text_value) else:
                return Result[
                    QueryParam,
                    string.String
                ].failure(error = string.String.from_str("url: invalid percent-encoding in query key"))

            return Result[QueryParam, string.String].success(
                value = QueryParam(key = decoded_key, value = string.String.create())
            )
        Option.some as e:
            let key_text = text_value.slice(0, e.value)
            let value_text = text_value.slice(e.value + 1, text_value.len - e.value - 1)

            let decoded_key = percent_decode(key_text) else:
                return Result[
                    QueryParam,
                    string.String
                ].failure(error = string.String.from_str("url: invalid percent-encoding in query key"))

            let decoded_value = percent_decode(value_text) else:
                var owned_key = decoded_key
                owned_key.release()
                return Result[
                    QueryParam,
                    string.String
                ].failure(error = string.String.from_str("url: invalid percent-encoding in query value"))

            return Result[QueryParam, string.String].success(
                value = QueryParam(key = decoded_key, value = decoded_value)
            )


public function build_query(params: span[QueryParam]) -> string.String:
    var result = string.String.create()

    var index: ptr_uint = 0
    while index < params.len:
        if index > 0:
            result.push_byte(38)

        let param = unsafe: read(params.data + index)
        var encoded_key = percent_encode(param.key.as_str())
        var encoded_value = percent_encode(param.value.as_str())

        result.append(encoded_key.as_str())
        result.push_byte(61)
        result.append(encoded_value.as_str())

        encoded_key.release()
        encoded_value.release()

        index += 1

    return result

public struct FormField:
    key: str
    value: str


public function encode_form(fields: span[FormField]) -> string.String:
    var result = string.String.create()

    var index: ptr_uint = 0
    while index < fields.len:
        if index > 0:
            result.push_byte(38)

        let field = unsafe: read(fields.data + index)
        append_form_encoded(ref_of(result), field.key)
        result.push_byte(61)
        append_form_encoded(ref_of(result), field.value)

        index += 1

    return result


function append_form_encoded(output: ref[string.String], text_value: str) -> void:
    var index: ptr_uint = 0
    while index < text_value.len:
        let value = text_value.byte_at(index)
        if value == 32:
            output.push_byte(43)
        else if is_unreserved(value):
            output.push_byte(value)
        else:
            output.push_byte(37)
            output.push_byte(hex_digit(value >> 4))
            output.push_byte(hex_digit(value & 0x0F))
        index += 1


public function decode_form(body: str) -> Result[vec.Vec[QueryParam], string.String]:
    var params = vec.Vec[QueryParam].create()

    if body.len == 0:
        return Result[vec.Vec[QueryParam], string.String].success(value = params)

    var start: ptr_uint = 0
    while start < body.len:
        let amp = find_byte_from(body, 38, start)
        match amp:
            Option.none:
                let pair_text = body.slice(start, body.len - start)
                let pair_result = parse_form_pair(pair_text)
                match pair_result:
                    Result.failure as payload:
                        release_params(ref_of(params))
                        return Result[
                            vec.Vec[QueryParam],
                            string.String
                        ].failure(error = payload.error)
                    Result.success as payload:
                        params.push(payload.value)

                start = body.len
            Option.some as a:
                let pair_text = body.slice(start, a.value - start)
                let pair_result = parse_form_pair(pair_text)
                match pair_result:
                    Result.failure as payload:
                        release_params(ref_of(params))
                        return Result[
                            vec.Vec[QueryParam],
                            string.String
                        ].failure(error = payload.error)
                    Result.success as payload:
                        params.push(payload.value)

                start = a.value + 1

    return Result[vec.Vec[QueryParam], string.String].success(value = params)


function parse_form_pair(text_value: str) -> Result[QueryParam, string.String]:
    let eq = text_value.find_byte(61)
    match eq:
        Option.none:
            let decoded_key = form_percent_decode(text_value) else:
                return Result[
                    QueryParam,
                    string.String
                ].failure(error = string.String.from_str("url: invalid percent-encoding in form key"))

            return Result[QueryParam, string.String].success(
                value = QueryParam(key = decoded_key, value = string.String.create())
            )
        Option.some as e:
            let key_text = text_value.slice(0, e.value)
            let value_text = text_value.slice(e.value + 1, text_value.len - e.value - 1)

            let decoded_key = form_percent_decode(key_text) else:
                return Result[
                    QueryParam,
                    string.String
                ].failure(error = string.String.from_str("url: invalid percent-encoding in form key"))

            let decoded_value = form_percent_decode(value_text) else:
                var owned_key = decoded_key
                owned_key.release()
                return Result[
                    QueryParam,
                    string.String
                ].failure(error = string.String.from_str("url: invalid percent-encoding in form value"))

            return Result[QueryParam, string.String].success(
                value = QueryParam(key = decoded_key, value = decoded_value)
            )


function form_percent_decode(text_value: str) -> Option[string.String]:
    var result = string.String.with_capacity(text_value.len)
    var index: ptr_uint = 0
    while index < text_value.len:
        let value = text_value.byte_at(index)
        if value == 43:
            result.push_byte(32)
            index += 1
        else if value != 37:
            result.push_byte(value)
            index += 1
        else:
            if index + 2 >= text_value.len:
                result.release()
                return Option[string.String].none

            let high = hex_value(text_value.byte_at(index + 1))
            let low = hex_value(text_value.byte_at(index + 2))
            if high < 0 or low < 0:
                result.release()
                return Option[string.String].none

            let decoded = ubyte<-(high * 16 + low)
            result.push_byte(decoded)
            index += 3

    return Option[string.String].some(value = result)


function release_params(params: ref[vec.Vec[QueryParam]]) -> void:
    var index: ptr_uint = 0
    while index < params.len():
        let current = params.get(index) else:
            fatal(c"url.release_params missing value")

        unsafe:
            var param = read(current)
            param.release()

        index += 1

    params.release()


extending QueryParam:
    public editable function release() -> void:
        this.key.release()
        this.value.release()
