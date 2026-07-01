import lexer.token as token_mod
import std.fmt as fmt
import std.mem.arena as arena
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


public function fatal_at(path: str, line: ptr_uint, column: ptr_uint, message: str) -> void:
    var arena_storage = arena.create(path.len + message.len + 128)
    var formatted = string.String.create()
    formatted.append(path)
    formatted.append(":")
    fmt.append_ptr_uint(ref_of(formatted), line)
    formatted.append(":")
    fmt.append_ptr_uint(ref_of(formatted), column)
    formatted.append(": error: ")
    formatted.append(message)
    fatal(arena_storage.to_cstr(formatted.as_str()))


public function fatal_at_token(
    path: str,
    line: ptr_uint,
    column: ptr_uint,
    lexeme: str,
    kind: token_mod.TokenKind,
    message: str,
) -> void:
    var arena_storage = arena.create(path.len + message.len + lexeme.len + 128)
    var formatted = string.String.create()
    formatted.append(path)
    formatted.append(":")
    fmt.append_ptr_uint(ref_of(formatted), line)
    formatted.append(":")
    fmt.append_ptr_uint(ref_of(formatted), column)
    formatted.append(": error: ")
    formatted.append(message)
    formatted.append(" (got ")
    formatted.append(lexeme)
    formatted.append(" / kind=")
    formatted.append(token_mod.token_kind_name(kind))
    formatted.append(")")
    fatal(arena_storage.to_cstr(formatted.as_str()))


extending LexError:
    public editable function release() -> void:
        this.message.release()
