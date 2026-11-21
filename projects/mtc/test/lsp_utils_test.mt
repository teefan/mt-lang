import mtc.lsp.utils as utils


@[test]
function test_utf16_column_ascii() -> void:
    let line = "abcdef"
    if utils.utf16_column_to_byte(line, 0) != 0:
        expect(false, "ascii column 0")
    if utils.utf16_column_to_byte(line, 3) != 3:
        expect(false, "ascii column 3")
    if utils.utf16_column_to_byte(line, 6) != 6:
        expect(false, "ascii end of line")
    return


@[test]
function test_utf16_column_bmp_multibyte() -> void:
    # Section signs are 2 UTF-8 bytes and 1 UTF-16 code unit.
    let line = "a§b"
    if utils.utf16_column_to_byte(line, 0) != 0:
        expect(false, "bmp column 0")
    if utils.utf16_column_to_byte(line, 1) != 1:
        expect(false, "bmp column 1 points at the section sign")
    if utils.utf16_column_to_byte(line, 2) != 3:
        expect(false, "bmp column 2 points at b")
    if utils.utf16_column_to_byte(line, 3) != 4:
        expect(false, "bmp end of line")
    return


@[test]
function test_utf16_column_astral() -> void:
    # An emoji is 4 UTF-8 bytes, 2 UTF-16 code units and 1 character.
    let line = "a🌍b"
    if utils.utf16_column_to_byte(line, 1) != 1:
        expect(false, "astral column 1 points at the emoji")
    # A column between the surrogate halves clamps to the emoji's end.
    if utils.utf16_column_to_byte(line, 2) != 5:
        expect(false, "astral mid-surrogate clamps forward")
    if utils.utf16_column_to_byte(line, 3) != 5:
        expect(false, "astral column 3 points at b")
    if utils.utf16_column_to_byte(line, 4) != 6:
        expect(false, "astral end of line")
    return


@[test]
function test_utf16_column_out_of_range_keeps_raw() -> void:
    # Past the line's UTF-16 length the raw column is kept, so an out-of-range
    # position cannot match text the client never meant.
    let line = "a§b"
    if utils.utf16_column_to_byte(line, 9) != 9:
        expect(false, "out-of-range column kept")
    return


@[test]
function test_position_to_byte_lines() -> void:
    let source = "## §1 x\nab§c\ntail"
    if utils.position_to_byte_utf16(source, 0, 4) != 5:
        expect(false, "first line conversion")
    if utils.position_to_byte_utf16(source, 1, 2) != 2:
        expect(false, "second line byte offset within the line")
    if utils.position_to_byte_utf16(source, 2, 4) != 4:
        expect(false, "last line without a trailing newline")
    # A line past the end keeps the raw character.
    if utils.position_to_byte_utf16(source, 7, 3) != 3:
        expect(false, "missing line keeps the raw character")
    return


@[test]
function test_position_to_byte_utf8() -> void:
    let source = "a§b\ncd"
    if utils.position_to_byte_utf8(source, 0, 2) != 2:
        expect(false, "utf-8 byte column inside a multibyte line")
    if utils.position_to_byte_utf8(source, 0, 9) != 4:
        expect(false, "utf-8 column past the line clamps to its end")
    if utils.position_to_byte_utf8(source, 1, 1) != 6:
        expect(false, "utf-8 second line offset")
    if utils.position_to_byte_utf8(source, 4, 1) != source.len:
        expect(false, "utf-8 line past the text clamps to the text length")
    return


@[test]
function test_byte_to_utf16_column() -> void:
    let line = "a§🌍b"
    # a=1, section sign=2 bytes/1 unit, emoji=4 bytes/2 units, b=1.
    if utils.byte_to_utf16_column(line, 0) != 0:
        expect(false, "byte 0")
    if utils.byte_to_utf16_column(line, 1) != 1:
        expect(false, "before the section sign")
    if utils.byte_to_utf16_column(line, 3) != 2:
        expect(false, "after the section sign")
    if utils.byte_to_utf16_column(line, 7) != 4:
        expect(false, "after the astral character")
    if utils.byte_to_utf16_column(line, 8) != 5:
        expect(false, "end of line")
    if utils.byte_to_utf16_column(line, 99) != 5:
        expect(false, "a column past the line returns its unit count")
    return


@[test]
function test_line_starts_and_index() -> void:
    let source = "ab\ncd\n"
    var starts = utils.build_line_starts(source)
    defer: starts.release()
    if starts.len() != 3:
        expect(false, "one start per line, including the trailing empty line")
    if utils.line_at_index(source, starts.as_span(), 0) != "ab":
        expect(false, "first line")
    if utils.line_at_index(source, starts.as_span(), 1) != "cd":
        expect(false, "second line")
    if utils.line_at_index(source, starts.as_span(), 2) != "":
        expect(false, "trailing empty line")
    return
