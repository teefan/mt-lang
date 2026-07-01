import std.string

public struct ParseError:
    message: string.String
    path: str
    line: ptr_uint
    column: ptr_uint


public function create(path: str, line: ptr_uint, column: ptr_uint, message: str) -> ParseError:
    return ParseError(
        message = string.String.from_str(message),
        path = path,
        line = line,
        column = column,
    )


extending ParseError:
    public editable function release() -> void:
        this.message.release()
