module examples.raylib.core.core_compute_hash

import std.c.raygui as gui
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const input_buffer_size: i32 = 96
const output_text_size: i32 = 120
const window_title: cstr = c"raylib [core] example - compute hash"
const default_input_text: cstr = c"The quick brown fox jumps over the lazy dog."

def readonly_text_box(bounds: gui.Rectangle, text: cstr, text_size: i32) -> void:
    unsafe:
        gui.GuiTextBox(bounds, cast[ptr[char]](text), text_size, false)

def hash_crc32_text(hash_crc32: u32) -> cstr:
    return rl.TextFormat(c"%08X", hash_crc32)

def hash_md5_text(hash_md5: ptr[u32]?) -> cstr:
    if hash_md5 == null:
        return c"00000000000000000000000000000000"

    unsafe:
        return rl.TextFormat(
            c"%08X%08X%08X%08X",
            deref(hash_md5),
            deref(hash_md5 + 1),
            deref(hash_md5 + 2),
            deref(hash_md5 + 3),
        )

def hash_sha1_text(hash_sha1: ptr[u32]?) -> cstr:
    if hash_sha1 == null:
        return c"0000000000000000000000000000000000000000"

    unsafe:
        return rl.TextFormat(
            c"%08X%08X%08X%08X%08X",
            deref(hash_sha1),
            deref(hash_sha1 + 1),
            deref(hash_sha1 + 2),
            deref(hash_sha1 + 3),
            deref(hash_sha1 + 4),
        )

def hash_sha256_text(hash_sha256: ptr[u32]?) -> cstr:
    if hash_sha256 == null:
        return c"0000000000000000000000000000000000000000000000000000000000000000"

    unsafe:
        return rl.TextFormat(
            c"%08X%08X%08X%08X%08X%08X%08X%08X",
            deref(hash_sha256),
            deref(hash_sha256 + 1),
            deref(hash_sha256 + 2),
            deref(hash_sha256 + 3),
            deref(hash_sha256 + 4),
            deref(hash_sha256 + 5),
            deref(hash_sha256 + 6),
            deref(hash_sha256 + 7),
        )

def base64_display_text(base64_text: ptr[char]?) -> cstr:
    if base64_text == null:
        return c""

    unsafe:
        return cast[cstr](base64_text)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var text_input = zero[array[char, 96]]()
    let text_input_ptr = raw(addr(text_input[0]))
    rl.TextCopy(text_input_ptr, default_input_text)

    var text_box_edit_mode = false
    var btn_compute_hashes = false
    var hash_crc32: u32 = 0
    var hash_md5: ptr[u32]? = null[ptr[u32]]
    var hash_sha1: ptr[u32]? = null[ptr[u32]]
    var hash_sha256: ptr[u32]? = null[ptr[u32]]
    var base64_text: ptr[char]? = null[ptr[char]]
    var base64_text_size = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if btn_compute_hashes:
            unsafe:
                let text_input_len = cast[i32](rl.TextLength(cast[cstr](text_input_ptr)))
                if base64_text != null:
                    rl.MemFree(cast[ptr[void]](base64_text))

                let input_bytes = cast[ptr[u8]](text_input_ptr)
                base64_text = rl.EncodeDataBase64(input_bytes, text_input_len, raw(addr(base64_text_size)))
                hash_crc32 = rl.ComputeCRC32(input_bytes, text_input_len)
                hash_md5 = rl.ComputeMD5(input_bytes, text_input_len)
                hash_sha1 = rl.ComputeSHA1(input_bytes, text_input_len)
                hash_sha256 = rl.ComputeSHA256(input_bytes, text_input_len)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SIZE, 20)
        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SPACING, 2)
        gui.GuiLabel(gui.Rectangle(x = 40.0, y = 26.0, width = 720.0, height = 32.0), c"INPUT DATA (TEXT):")
        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SPACING, 1)
        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SIZE, 10)

        if gui.GuiTextBox(
            gui.Rectangle(x = 40.0, y = 64.0, width = 720.0, height = 32.0),
            text_input_ptr,
            input_buffer_size - 1,
            text_box_edit_mode,
        ) != 0:
            text_box_edit_mode = not text_box_edit_mode

        btn_compute_hashes = gui.GuiButton(
            gui.Rectangle(x = 40.0, y = 104.0, width = 720.0, height = 32.0),
            c"COMPUTE INPUT DATA HASHES",
        ) != 0

        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SIZE, 20)
        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SPACING, 2)
        gui.GuiLabel(gui.Rectangle(x = 40.0, y = 160.0, width = 720.0, height = 32.0), c"INPUT DATA HASH VALUES:")
        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SPACING, 1)
        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SIZE, 10)

        gui.GuiSetStyle(gui.GuiControl.TEXTBOX, gui.GuiTextBoxProperty.TEXT_READONLY, 1)
        gui.GuiLabel(gui.Rectangle(x = 40.0, y = 200.0, width = 120.0, height = 32.0), c"CRC32 [32 bit]:")
        readonly_text_box(gui.Rectangle(x = 160.0, y = 200.0, width = 600.0, height = 32.0), hash_crc32_text(hash_crc32), output_text_size)
        gui.GuiLabel(gui.Rectangle(x = 40.0, y = 236.0, width = 120.0, height = 32.0), c"MD5 [128 bit]:")
        readonly_text_box(gui.Rectangle(x = 160.0, y = 236.0, width = 600.0, height = 32.0), hash_md5_text(hash_md5), output_text_size)
        gui.GuiLabel(gui.Rectangle(x = 40.0, y = 272.0, width = 120.0, height = 32.0), c"SHA1 [160 bit]:")
        readonly_text_box(gui.Rectangle(x = 160.0, y = 272.0, width = 600.0, height = 32.0), hash_sha1_text(hash_sha1), output_text_size)
        gui.GuiLabel(gui.Rectangle(x = 40.0, y = 308.0, width = 120.0, height = 32.0), c"SHA256 [256 bit]:")
        readonly_text_box(gui.Rectangle(x = 160.0, y = 308.0, width = 600.0, height = 32.0), hash_sha256_text(hash_sha256), output_text_size)

        gui.GuiSetState(gui.GuiState.STATE_FOCUSED)
        gui.GuiLabel(gui.Rectangle(x = 40.0, y = 350.0, width = 320.0, height = 32.0), c"BONUS - BAS64 ENCODED STRING:")
        gui.GuiSetState(gui.GuiState.STATE_NORMAL)
        gui.GuiLabel(gui.Rectangle(x = 40.0, y = 380.0, width = 120.0, height = 32.0), c"BASE64 ENCODING:")
        readonly_text_box(gui.Rectangle(x = 160.0, y = 380.0, width = 600.0, height = 32.0), base64_display_text(base64_text), output_text_size)
        gui.GuiSetStyle(gui.GuiControl.TEXTBOX, gui.GuiTextBoxProperty.TEXT_READONLY, 0)

    if base64_text != null:
        unsafe:
            rl.MemFree(cast[ptr[void]](base64_text))

    return 0
