# Diagnostic messages for the self-hosting compiler.
# Collects errors and warnings during parsing and semantic analysis.

import std.vec

public enum Severity: ubyte
    error = 0
    warning = 1
    hint = 2

public struct Diagnostic:
    severity: Severity
    code: str
    message: str
    file_path: str
    line: int
    column: int

public struct DiagnosticList:
    entries: vec.Vec[Diagnostic]

extending DiagnosticList:
    public static function create() -> DiagnosticList:
        return DiagnosticList(entries = vec.Vec[Diagnostic].create())

    public editable function add(
        sev: Severity,
        code: str,
        message: str,
        path: str,
        line: int,
        col: int,
    ) -> void:
        this.entries.push(Diagnostic(
            severity = sev,
            code = code,
            message = message,
            file_path = path,
            line = line,
            column = col
        ))

    public function has_errors() -> bool:
        var i: ptr_uint = 0
        while i < this.entries.len:
            i += 1
        return false

    public function count() -> ptr_uint:
        return this.entries.len
