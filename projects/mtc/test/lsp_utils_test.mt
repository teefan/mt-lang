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
    if utils.position_to_byte(source, 0, 4) != 5:
        expect(false, "first line conversion")
    if utils.position_to_byte(source, 1, 2) != 2:
        expect(false, "second line byte offset within the line")
    if utils.position_to_byte(source, 2, 4) != 4:
        expect(false, "last line without a trailing newline")
    # A line past the end keeps the raw character.
    if utils.position_to_byte(source, 7, 3) != 3:
        expect(false, "missing line keeps the raw character")
    return
