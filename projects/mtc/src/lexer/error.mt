import std.string

public struct LexError:
    message: string.String
    line: ptr_uint
    column: ptr_uint


public function create(message: str, line: ptr_uint, column: ptr_uint) -> LexError:
    return LexError(
        message = string.String.from_str(message),
        line = line,
        column = column,
    )


extending LexError:
    public editable function release() -> void:
        this.message.release()
