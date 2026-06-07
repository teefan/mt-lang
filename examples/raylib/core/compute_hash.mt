import std.raygui as gui
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function assign_hex_text[N](buffer: ref[str_buffer[N]], data: ptr[uint]?, data_size: int) -> void:
    unsafe: read(buffer).clear()
    if data == null or data_size <= 0:
        unsafe: read(buffer).assign("00000000")
        return

    var index = 0
    while index < data_size:
        unsafe:
            read(buffer).append(text.cstr_as_str(rl.text_format("%08X", read(data + ptr_uint<-index))))
        index += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - compute hash")
    defer rl.close_window()

    var text_input: str_buffer[96]
    text_input.assign("The quick brown fox jumps over the lazy dog.")
    var text_box_edit_mode = false

    var hash_crc32: uint = 0
    var hash_md5: ptr[uint]? = null
    var hash_sha1: ptr[uint]? = null
    var hash_sha256: ptr[uint]? = null

    var crc32_text: str_buffer[16]
    crc32_text.assign("00000000")
    var md5_text: str_buffer[64]
    md5_text.assign("00000000")
    var sha1_text: str_buffer[64]
    sha1_text.assign("00000000")
    var sha256_text: str_buffer[96]
    sha256_text.assign("00000000")
    var base64_text: str_buffer[160]
    base64_text.assign("")

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SIZE, 20)
        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SPACING, 2)
        gui.label(gui.Rectangle(x = 40.0, y = 26.0, width = 720.0, height = 32.0), "INPUT DATA (TEXT):")
        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SPACING, 1)
        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SIZE, 10)

        if gui.text_box(
            gui.Rectangle(x = 40.0, y = 64.0, width = 720.0, height = 32.0),
            text_input,
            text_box_edit_mode
        ) != 0:
            text_box_edit_mode = not text_box_edit_mode

        let btn_compute_hashes = gui.button(
            gui.Rectangle(x = 40.0, y = 104.0, width = 720.0, height = 32.0),
            "COMPUTE INPUT DATA HASHES"
        ) != 0
        if btn_compute_hashes:
            let input_text = text_input.as_str()
            let input_len = int<-input_text.len
            let input_data = unsafe: ptr[ubyte]<-input_text.data

            var base64_text_size = 0
            let encoded = rl.encode_data_base64(input_data, input_len, ptr_of(base64_text_size))
            if encoded != null:
                base64_text.assign(text.chars_as_str(ptr[char]<-encoded))
                rl.mem_free(encoded)
            else:
                base64_text.clear()

            hash_crc32 = rl.compute_crc32(input_data, input_len)
            hash_md5 = rl.compute_md5(input_data, input_len)
            hash_sha1 = rl.compute_sha1(input_data, input_len)
            hash_sha256 = rl.compute_sha256(input_data, input_len)

            assign_hex_text(ref_of(crc32_text), ptr_of(hash_crc32), 1)
            assign_hex_text(ref_of(md5_text), hash_md5, 4)
            assign_hex_text(ref_of(sha1_text), hash_sha1, 5)
            assign_hex_text(ref_of(sha256_text), hash_sha256, 8)

        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SIZE, 20)
        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SPACING, 2)
        gui.label(gui.Rectangle(x = 40.0, y = 160.0, width = 720.0, height = 32.0), "INPUT DATA HASH VALUES:")
        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SPACING, 1)
        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SIZE, 10)

        gui.set_style(gui.Control.TEXTBOX, int<-gui.TextBoxProperty.TEXT_READONLY, 1)
        gui.label(gui.Rectangle(x = 40.0, y = 200.0, width = 120.0, height = 32.0), "CRC32 [32 bit]:")
        unsafe: gui.text_box(gui.Rectangle(x = 160.0, y = 200.0, width = 600.0, height = 32.0), crc32_text, false)
        gui.label(gui.Rectangle(x = 40.0, y = 236.0, width = 120.0, height = 32.0), "MD5 [128 bit]:")
        unsafe: gui.text_box(gui.Rectangle(x = 160.0, y = 236.0, width = 600.0, height = 32.0), md5_text, false)
        gui.label(gui.Rectangle(x = 40.0, y = 272.0, width = 120.0, height = 32.0), "SHA1 [160 bit]:")
        unsafe: gui.text_box(gui.Rectangle(x = 160.0, y = 272.0, width = 600.0, height = 32.0), sha1_text, false)
        gui.label(gui.Rectangle(x = 40.0, y = 308.0, width = 120.0, height = 32.0), "SHA256 [256 bit]:")
        unsafe: gui.text_box(gui.Rectangle(x = 160.0, y = 308.0, width = 600.0, height = 32.0), sha256_text, false)

        gui.set_state(gui.State.STATE_FOCUSED)
        gui.label(gui.Rectangle(x = 40.0, y = 350.0, width = 320.0, height = 32.0), "BONUS - BASE64 ENCODED STRING:")
        gui.set_state(gui.State.STATE_NORMAL)
        gui.label(gui.Rectangle(x = 40.0, y = 380.0, width = 120.0, height = 32.0), "BASE64 ENCODING:")
        unsafe: gui.text_box(gui.Rectangle(x = 160.0, y = 380.0, width = 600.0, height = 32.0), base64_text, false)
        gui.set_style(gui.Control.TEXTBOX, int<-gui.TextBoxProperty.TEXT_READONLY, 0)

        rl.end_drawing()

    return 0
