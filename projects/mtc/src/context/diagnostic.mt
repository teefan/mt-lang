import std.vec as vec

public enum DiagLevel: ubyte
    error   = 1
    warning = 2
    note    = 3

public struct Diag:
    level: DiagLevel
    file_id: uint
    offset: ptr_uint
    message: str

public struct DiagEngine:
    diagnostics: vec.Vec[Diag]
    error_count: uint
    warning_count: uint

extending DiagEngine:
    public static function create() -> DiagEngine:
        return DiagEngine(
            diagnostics = vec.Vec[Diag].create(),
            error_count = 0,
            warning_count = 0
        )

    public editable function error(file_id: uint, offset: ptr_uint, message: str) -> void:
        this.diagnostics.push(Diag(level = DiagLevel.error, file_id = file_id, offset = offset, message = message))
        this.error_count += 1

    public editable function warning(file_id: uint, offset: ptr_uint, message: str) -> void:
        this.diagnostics.push(Diag(level = DiagLevel.warning, file_id = file_id, offset = offset, message = message))
        this.warning_count += 1

    public editable function note(file_id: uint, offset: ptr_uint, message: str) -> void:
        this.diagnostics.push(Diag(level = DiagLevel.note, file_id = file_id, offset = offset, message = message))

    public function has_errors() -> bool:
        return this.error_count > 0

    public function has_warnings() -> bool:
        return this.warning_count > 0

    public editable function release() -> void:
        this.diagnostics.release()
