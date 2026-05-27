import std.raygui as gui
import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const FILTER: str = ".png;.c"
const ROW_HEIGHT: int = 22


function clamp_scroll(index: int, count: int, visible_rows: int) -> int:
    if count <= visible_rows:
        return 0
    if index < 0:
        return 0
    if index > count - visible_rows:
        return count - visible_rows
    return index


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - directory files")
    defer rl.close_window()

    var directory: str_buffer[1024]
    directory.assign(text.cstr_as_str(rl.get_working_directory()))
    var files = rl.load_directory_files_ex(directory.as_str(), FILTER, false)
    defer rl.unload_directory_files(files)

    var list_scroll_index = 0
    let visible_rows = (SCREEN_HEIGHT - 60) / ROW_HEIGHT

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let wheel = rl.get_mouse_wheel_move()
        if wheel > 0.0:
            list_scroll_index -= 1
        else if wheel < 0.0:
            list_scroll_index += 1
        list_scroll_index = clamp_scroll(list_scroll_index, int<-files.count, visible_rows)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        let btn_back_pressed = gui.button(gui.Rectangle(x = 40.0, y = 10.0, width = 48.0, height = 28.0), "<") != 0
        if btn_back_pressed:
            directory.assign(text.cstr_as_str(rl.get_prev_directory_path(directory.as_str())))
            rl.unload_directory_files(files)
            files = rl.load_directory_files_ex(directory.as_str(), FILTER, false)
            list_scroll_index = 0

        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SIZE, rl.get_font_default().baseSize * 2)
        gui.label(gui.Rectangle(x = 98.0, y = 10.0, width = 700.0, height = 28.0), directory.as_str())
        gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SIZE, rl.get_font_default().baseSize)

        var row = 0
        var index = list_scroll_index
        while row < visible_rows and index < int<-files.count:
            let y = 50 + row * ROW_HEIGHT
            if (row % 2) == 0:
                rl.draw_rectangle(0, y, SCREEN_WIDTH, ROW_HEIGHT, rl.fade(rl.LIGHTGRAY, 0.35))

            unsafe:
                let entry = text.cstr_as_str(cstr<-read(files.paths + ptr_uint<-index))
                rl.draw_text(entry, 14, y + 4, 18, rl.DARKGRAY)

            row += 1
            index += 1

        rl.end_drawing()

    return 0
