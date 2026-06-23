import std.string

public struct SourceFile:
    text: str
    path: string.String


public function from_str(text: str, path: str) -> SourceFile:
    return SourceFile(
        text = text,
        path = string.String.from_str(path),
    )


extending SourceFile:
    public function len() -> ptr_uint:
        return this.text.len
