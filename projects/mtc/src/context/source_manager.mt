import std.str
import std.vec as vec

public struct SourceLocation:
    file_id: uint
    offset: ptr_uint

public struct SourceFile:
    path: str
    content: str
    module_name: str
    line_starts: vec.Vec[ptr_uint]

public struct SourceManager:
    files: vec.Vec[SourceFile]

extending SourceManager:
    public static function create() -> SourceManager:
        return SourceManager(files = vec.Vec[SourceFile].create())

    public editable function add_file(path: str, content: str, module_name: str) -> ptr_uint:
        var line_starts = vec.Vec[ptr_uint].create()
        line_starts.push(0)

        var i: ptr_uint = 0
        while i < content.len:
            if content.byte_at(i) == '\n':
                line_starts.push(i + 1)
            i += 1

        let sf = SourceFile(
            path = path,
            content = content,
            module_name = module_name,
            line_starts = line_starts
        )
        this.files.push(sf)
        return this.files.len() - 1

    public function file(file_id: ptr_uint) -> SourceFile:
        let entry = this.files.get(file_id) else:
            fatal(c"source_manager.file invalid file_id")
        unsafe:
            return read(entry)

    public function file_count() -> ptr_uint:
        return this.files.len()

    public function line_column(file_id: ptr_uint, offset: ptr_uint) -> (uint, uint):
        let f = this.file(file_id)
        if f.line_starts.len() == 0:
            return (1u, 1u)

        var lo: ptr_uint = 0
        var hi = f.line_starts.len()
        while lo + 1 < hi:
            let mid = lo + (hi - lo) / 2
            let start_entry = f.line_starts.get(mid) else:
                fatal(c"source_manager.line_column missing line start")
            unsafe:
                if read(start_entry) <= offset:
                    lo = mid
                else:
                    hi = mid

        let line_start_entry = f.line_starts.get(lo) else:
            fatal(c"source_manager.line_column missing line start")
        var line_start: ptr_uint = 0
        unsafe:
            line_start = read(line_start_entry)

        let line_num = uint<-(lo) + 1
        let col_num = uint<-(offset - line_start) + 1

        return (line_num, col_num)

    public function source_line(file_id: ptr_uint, offset: ptr_uint) -> str:
        let f = this.file(file_id)
        let (line_num, _col) = this.line_column(file_id, offset)

        let starts = f.line_starts
        if starts.len() == 0:
            return ""

        let line_idx = ptr_uint<-(line_num) - 1
        if line_idx >= starts.len():
            return ""

        let line_start_entry = starts.get(line_idx) else:
            fatal(c"source_manager.source_line missing line start")
        var line_start: ptr_uint = 0
        unsafe:
            line_start = read(line_start_entry)

        var line_end = f.content.len
        if line_idx + 1 < starts.len():
            let next_entry = starts.get(line_idx + 1) else:
                fatal(c"source_manager.source_line missing next line start")
            unsafe:
                line_end = read(next_entry)

        if line_end > 0 and f.content.byte_at(line_end - 1) == '\n':
            line_end -= 1
        if line_end > 0 and f.content.byte_at(line_end - 1) == '\r':
            line_end -= 1

        return f.content.slice(line_start, line_end - line_start)

    public editable function release() -> void:
        var i: ptr_uint = 0
        while i < this.files.len():
            let entry = this.files.get(i) else:
                fatal(c"source_manager.release missing file")
            unsafe:
                read(entry).line_starts.release()
            i += 1
        this.files.release()
