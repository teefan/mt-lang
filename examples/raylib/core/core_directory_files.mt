module examples.raylib.core.core_directory_files

import std.c.raygui as gui
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_filepath_size: i32 = 1024
const window_title: cstr = c"raylib [core] example - directory files"
const filter_text: cstr = c".png;.c"
const back_button_text: cstr = c"<"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var directory = zero[array[char, 1024]]()
    let directory_ptr = ptr_of(ref_of(directory[0]))
    unsafe:
        rl.TextCopy(directory_ptr, rl.GetWorkingDirectory())

    var files = zero[rl.FilePathList]()
    unsafe:
        files = rl.LoadDirectoryFilesEx(cstr<-directory_ptr, filter_text, false)

    var btn_back_pressed = false
    var list_scroll_index = 0
    var list_item_active = -1
    var list_item_focused = -1

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if btn_back_pressed:
            unsafe:
                rl.TextCopy(directory_ptr, rl.GetPrevDirectoryPath(cstr<-directory_ptr))
                rl.UnloadDirectoryFiles(files)
                files = rl.LoadDirectoryFiles(cstr<-directory_ptr)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        btn_back_pressed = gui.GuiButton(gui.Rectangle(x = 40.0, y = 10.0, width = 48.0, height = 28.0), back_button_text) != 0

        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SIZE, gui.GuiGetFont().baseSize * 2)
        unsafe:
            gui.GuiLabel(gui.Rectangle(x = 98.0, y = 10.0, width = 700.0, height = 28.0), cstr<-directory_ptr)
        gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SIZE, gui.GuiGetFont().baseSize)

        gui.GuiSetStyle(gui.GuiControl.LISTVIEW, gui.GuiControlProperty.TEXT_ALIGNMENT, gui.GuiTextAlignment.TEXT_ALIGN_LEFT)
        gui.GuiSetStyle(gui.GuiControl.LISTVIEW, gui.GuiControlProperty.TEXT_PADDING, 40)
        gui.GuiListViewEx(
            gui.Rectangle(x = 0.0, y = 50.0, width = rl.GetScreenWidth(), height = rl.GetScreenHeight() - 50.0),
            files.paths,
            i32<-files.count,
            ptr_of(ref_of(list_scroll_index)),
            ptr_of(ref_of(list_item_active)),
            ptr_of(ref_of(list_item_focused)),
        )

    rl.UnloadDirectoryFiles(files)

    return 0