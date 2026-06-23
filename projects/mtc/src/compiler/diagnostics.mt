import std.string

public enum Severity: int
    error = 0
    warning = 1
    note = 2


public struct Diagnostic:
    severity: Severity
    message: string.String
    line: ptr_uint
    column: ptr_uint


public function create_error(message: str, line: ptr_uint, column: ptr_uint) -> Diagnostic:
    return Diagnostic(
        severity = Severity.error,
        message = string.String.from_str(message),
        line = line,
        column = column,
    )


public function create_warning(message: str, line: ptr_uint, column: ptr_uint) -> Diagnostic:
    return Diagnostic(
        severity = Severity.warning,
        message = string.String.from_str(message),
        line = line,
        column = column,
    )


public function create_note(message: str, line: ptr_uint, column: ptr_uint) -> Diagnostic:
    return Diagnostic(
        severity = Severity.note,
        message = string.String.from_str(message),
        line = line,
        column = column,
    )
