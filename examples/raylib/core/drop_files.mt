import std.raylib as rl
import std.str as text
import std.string as string
import std.vec as vec


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_FILEPATH_RECORDED: int = 4096


function release_string_values(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value_ptr = values.get(index) else:
            fatal(c"drop_files missing value")

        unsafe:
            var owned = read(value_ptr)
            owned.release()

        index += 1

    values.release()


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - drop files")
    defer rl.close_window()

    var file_paths = vec.Vec[string.String].create()
    defer release_string_values(ref_of(file_paths))

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_file_dropped():
            let dropped_files = rl.load_dropped_files()
            defer rl.unload_dropped_files(dropped_files)

            var index = 0
            while index < int<-dropped_files.count and file_paths.len() < ptr_uint<-(MAX_FILEPATH_RECORDED - 1):
                unsafe:
                    let raw_path = dropped_files.paths[index]
                    file_paths.push(string.String.from_str(text.cstr_as_str(cstr<-raw_path)))
                index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if file_paths.len() == 0:
            rl.draw_text("Drop your files to this window!", 100, 40, 20, rl.DARKGRAY)
        else:
            rl.draw_text("Dropped files:", 100, 40, 20, rl.DARKGRAY)

            var index: ptr_uint = 0
            while index < file_paths.len():
                let file_path = file_paths.get(index) else:
                    fatal(c"drop_files missing file path")

                if (index % 2) == 0:
                    rl.draw_rectangle(0, 85 + 40 * int<-index, SCREEN_WIDTH, 40, rl.fade(rl.LIGHTGRAY, 0.5))
                else:
                    rl.draw_rectangle(0, 85 + 40 * int<-index, SCREEN_WIDTH, 40, rl.fade(rl.LIGHTGRAY, 0.3))

                unsafe:
                    rl.draw_text(read(file_path).as_str(), 120, 100 + 40 * int<-index, 10, rl.GRAY)
                index += 1

            rl.draw_text("Drop new files...", 100, 110 + 40 * int<-file_paths.len(), 20, rl.DARKGRAY)

        rl.end_drawing()

    return 0
