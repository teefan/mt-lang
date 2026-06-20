# Source view and span helpers for the self-hosting compiler.
# Mirrors the path + text model used by the Ruby compiler's SourceFile.

import std.str

public struct SourceView:
    path: str
    text: str

public struct Span:
    start: ptr_uint
    end: ptr_uint
