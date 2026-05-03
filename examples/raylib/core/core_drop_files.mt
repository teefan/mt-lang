module examples.raylib.core.core_drop_files

import std.c.raylib as rl
import std.mem.heap as heap

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_filepaths_recorded: i32 = 4096
const max_filepath_size: i32 = 2048
const window_title: cstr = c"raylib [core] example - drop files"
const empty_prompt_text: cstr = c"Drop your files to this window!"
const dropped_files_text: cstr = c"Dropped files:"
const continue_prompt_text: cstr = c"Drop new files..."


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var file_path_counter = 0
    var file_paths = zero[array[ptr[char], 4096]]()

    for index in range(0, max_filepaths_recorded):
        file_paths[index] = heap.must_alloc_zeroed[char](usize<-max_filepath_size)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsFileDropped():
            let dropped_files = rl.LoadDroppedFiles()
            let dropped_count = i32<-dropped_files.count
            let offset = file_path_counter
            var dropped_index = 0

            while dropped_index < dropped_count:
                if file_path_counter < max_filepaths_recorded - 1:
                    unsafe:
                        let dropped_path = read(dropped_files.paths + usize<-dropped_index)
                        rl.TextCopy(file_paths[offset + dropped_index], cstr<-dropped_path)
                    file_path_counter += 1
                dropped_index += 1

            rl.UnloadDroppedFiles(dropped_files)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if file_path_counter == 0:
            rl.DrawText(empty_prompt_text, 100, 40, 20, rl.DARKGRAY)
        else:
            rl.DrawText(dropped_files_text, 100, 40, 20, rl.DARKGRAY)

            var index = 0
            while index < file_path_counter:
                rl.DrawRectangle(0, 85 + 40 * index, screen_width, 40, rl.Fade(rl.LIGHTGRAY, if index % 2 == 0: 0.5 else: 0.3))
                unsafe:
                    rl.DrawText(cstr<-file_paths[index], 120, 100 + 40 * index, 10, rl.GRAY)
                index += 1

            rl.DrawText(continue_prompt_text, 100, 110 + 40 * file_path_counter, 20, rl.DARKGRAY)

    for index in range(0, max_filepaths_recorded):
        heap.release(file_paths[index])

    return 0
