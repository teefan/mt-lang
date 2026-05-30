import std.pcre2 as re
import std.str as text

public struct CompileResult:
    code: ptr[re.Code]?
    error_code: int
    error_offset: ptr_uint


public function compile_str(pattern: str, options: uint, compile_context: ptr[re.CompileContext]) -> CompileResult:
    var error_code = 0
    var error_offset: ptr_uint = 0
    let code = re.compile_bytes(text.as_byte_span(pattern), options, error_code, error_offset, compile_context)
    return CompileResult(code = code, error_code = error_code, error_offset = error_offset)


public function match_str(
    code: const_ptr[re.Code],
    subject: str,
    start_offset: ptr_uint,
    options: uint,
    match_data: ptr[re.MatchData],
    match_context: ptr[re.MatchContext]
) -> int:
    return re.match_bytes(code, text.as_byte_span(subject), start_offset, options, match_data, match_context)


public function error_message_as_str(error_code: int, buffer: span[ubyte]) -> Option[str]:
    let result = re.get_error_message(error_code, buffer)
    if result <= 0:
        return Option[str].none

    let message_len = ptr_uint<-result
    let message = span[ubyte](data = buffer.data, len = message_len)
    return text.utf8_byte_span_as_str(message)
