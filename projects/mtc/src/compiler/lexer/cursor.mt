## SourceCursor — safe byte-at-a-time access over source text.
##
## This is the single unsafe boundary for character-level source access.
## All other compiler modules (lexer, parser) use safe Cursor operations.
## Confines: pointer arithmetic, raw pointer dereference, unsafe block.

public struct Cursor:
    data: span[ubyte]
    pos: ptr_uint
    line: ptr_uint
    col: ptr_uint


public function create(source: span[ubyte]) -> Cursor:
    return Cursor(
        data = source,
        pos = 0,
        line = 1,
        col = 1,
    )


extending Cursor:
    public function at_end() -> bool:
        return this.pos >= this.data.len


    public function current() -> ubyte:
        let raw = this.data.data
        unsafe:
            return read(raw + this.pos)


    public function current_ptr() -> ptr[ubyte]:
        let raw = this.data.data
        unsafe:
            return raw + this.pos


    public function peek(offset: ptr_uint) -> Option[ubyte]:
        let target = this.pos + offset
        if target >= this.data.len:
            return Option[ubyte].none

        let raw = this.data.data
        unsafe:
            return Option[ubyte].some(value = read(raw + target))


    public editable function advance() -> void:
        if this.at_end():
            return

        let ch = this.current()
        this.pos += 1
        if ch == 10:
            this.line += 1
            this.col = 1
        else:
            this.col += 1


    public editable function advance_by(count: ptr_uint) -> void:
        var remaining = count
        while remaining > 0 and not this.at_end():
            this.advance()
            remaining -= 1


    public function remaining() -> ptr_uint:
        return this.data.len - this.pos


    public function slice_from(start: ptr_uint, len: ptr_uint) -> str:
        if start > this.data.len or len > this.data.len - start:
            fatal(c"SourceCursor.slice_from out of bounds")

        unsafe:
            let raw = ptr[char]<-this.data.data
            return str(data = raw + start, len = len)
