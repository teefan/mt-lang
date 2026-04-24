module examples.raylib.core.core_storage_values

import std.c.raylib as rl
import std.raylib.runtime as runtime

const screen_width: i32 = 800
const screen_height: i32 = 450
const storage_data_file: cstr = c"storage.data"
const window_title: cstr = c"raylib [core] example - storage values"
const score_position: usize = 0
const hiscore_position: usize = 1

def storage_size_bytes(position: usize) -> i32:
    return cast[i32]((position + 1) * cast[usize](sizeof(i32)))

def save_storage_value(position: usize, stored_value: i32) -> bool:
    var data_size = 0
    let loaded_file_data: ptr[u8]? = rl.LoadFileData(storage_data_file, raw(addr(data_size)))
    let required_size = storage_size_bytes(position)

    if loaded_file_data != null:
        unsafe:
            let file_data = cast[ptr[u8]](loaded_file_data)
            var writable_file_data = file_data
            var writable_size = data_size
            var can_store_value = data_size >= required_size

            if data_size < required_size:
                let resized_file_data: ptr[u8]? = cast[ptr[u8]?](rl.MemRealloc(cast[ptr[void]](file_data), cast[u32](required_size)))
                if resized_file_data != null:
                    writable_file_data = cast[ptr[u8]](resized_file_data)
                    writable_size = required_size
                    can_store_value = true

            if can_store_value:
                let data_ptr = cast[ptr[i32]](writable_file_data)
                value(data_ptr + position) = stored_value

            let success = rl.SaveFileData(storage_data_file, cast[ptr[void]](writable_file_data), writable_size)
            rl.MemFree(cast[ptr[void]](writable_file_data))
            return success

    unsafe:
        let new_file_data = cast[ptr[i32]](rl.MemAlloc(cast[u32](required_size)))
        value(new_file_data + position) = stored_value
        let success = rl.SaveFileData(storage_data_file, cast[ptr[void]](new_file_data), required_size)
        rl.MemFree(cast[ptr[void]](new_file_data))
        return success

def load_storage_value(position: usize) -> i32:
    var data_size = 0
    let loaded_file_data: ptr[u8]? = rl.LoadFileData(storage_data_file, raw(addr(data_size)))
    if loaded_file_data == null:
        return 0

    let required_size = storage_size_bytes(position)
    unsafe:
        let file_data = cast[ptr[u8]](loaded_file_data)
        if data_size < required_size:
            rl.UnloadFileData(file_data)
            return 0

        let data_ptr = cast[ptr[i32]](file_data)
        let stored_value = value(data_ptr + position)
        rl.UnloadFileData(file_data)
        return stored_value

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var score = 0
    var hiscore = 0
    var frames_counter = 0
    var smoke_frame_count = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            score = rl.GetRandomValue(1000, 2000)
            hiscore = rl.GetRandomValue(2000, 4000)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER):
            save_storage_value(score_position, score)
            save_storage_value(hiscore_position, hiscore)
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            score = load_storage_value(score_position)
            hiscore = load_storage_value(hiscore_position)

        frames_counter += 1

        rl.BeginDrawing()
        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(rl.TextFormat(c"SCORE: %i", score), 280, 130, 40, rl.MAROON)
        rl.DrawText(rl.TextFormat(c"HI-SCORE: %i", hiscore), 210, 200, 50, rl.BLACK)
        rl.DrawText(rl.TextFormat(c"frames: %i", frames_counter), 10, 10, 20, rl.LIME)
        rl.DrawText(c"Press R to generate random numbers", 220, 40, 20, rl.LIGHTGRAY)
        rl.DrawText(c"Press ENTER to SAVE values", 250, 310, 20, rl.LIGHTGRAY)
        rl.DrawText(c"Press SPACE to LOAD values", 252, 350, 20, rl.LIGHTGRAY)

        rl.EndDrawing()

        smoke_frame_count += 1
        if runtime.smoke_capture(smoke_frame_count, 3):
            break

    return 0
