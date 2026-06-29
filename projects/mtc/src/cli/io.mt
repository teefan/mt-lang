import std.mem.heap as heap

external function fopen(path: cstr, mode: cstr) -> ptr[void]?
external function fseek(file: ptr[void], offset: long, origin: int) -> int
external function ftell(file: ptr[void]) -> long
external function fread(buffer: ptr[void], size: ptr_uint, count: ptr_uint, stream: ptr[void]) -> ptr_uint
external function fwrite(buffer: ptr[void], size: ptr_uint, count: ptr_uint, stream: ptr[void]) -> ptr_uint
external function fclose(file: ptr[void]) -> int

public function read_file(path: str) -> str:
    let path_cstr = unsafe: reinterpret[cstr](path.data)
    let f = fopen(path_cstr, c"rb") else:
        return ""
    let _seek = fseek(f, 0, 2)
    let size = ftell(f)
    let _seek2 = fseek(f, 0, 0)
    if size <= 0:
        let _cl = fclose(f)
        return ""
    let buf = heap.alloc_bytes(ptr_uint<-(size) + 1) else:
        let _cl2 = fclose(f)
        return ""
    unsafe:
        let bytes_read = fread(ptr[void]<-buf, 1, ptr_uint<-(size), f)
        read(ptr[char]<-buf + bytes_read) = '\0'
        let _cl3 = fclose(f)
        return str(data = ptr[char]<-buf, len = bytes_read)

public function write_file(path: str, content: str) -> bool:
    let path_cstr = unsafe: reinterpret[cstr](path.data)
    let f = fopen(path_cstr, c"wb") else:
        return false
    let written = unsafe: fwrite(ptr[void]<-content.data, 1, content.len, f)
    let _cl = fclose(f)
    return written == content.len
