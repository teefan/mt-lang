import lexer.token as token_mod
import std.fmt as fmt
import std.mem.arena as arena
import std.string
import std.vec

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


public function recover_or_fatal_at(
    recover: ptr[vec.Vec[LexError]]?,
    path: str,
    line: ptr_uint,
    column: ptr_uint,
    message: str,
) -> void:
    let errors = recover else:
        fatal_at(path, line, column, message)
        return
    unsafe:
        read(errors).push(LexError(
            message = string.String.from_str(message),
            line = line,
            column = column,
        ))


public function recover_or_fatal_at_token(
    recover: ptr[vec.Vec[LexError]]?,
    path: str,
    line: ptr_uint,
    column: ptr_uint,
    lexeme: str,
    kind: token_mod.TokenKind,
    message: str,
) -> void:
    let errors = recover else:
        fatal_at_token(path, line, column, lexeme, kind, message)
        return
    unsafe:
        read(errors).push(LexError(
            message = string.String.from_str(message),
            line = line,
            column = column,
        ))


extending LexError:
    public editable function release() -> void:
        this.message.release()
