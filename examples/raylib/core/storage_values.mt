import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const STORAGE_DATA_FILE: str = "storage.data"
const STORAGE_POSITION_SCORE: int = 0
const STORAGE_POSITION_HISCORE: int = 1
const STORAGE_VALUE_COUNT: int = 2


function save_storage_value(position: int, value: int) -> bool:
    if position < 0 or position >= STORAGE_VALUE_COUNT:
        return false

    var values: array[int, STORAGE_VALUE_COUNT] = zero[array[int, STORAGE_VALUE_COUNT]]
    var data_size = 0
    let data = rl.load_file_data(STORAGE_DATA_FILE, data_size)
    if data != null:
        defer rl.unload_file_data(data)

        let stored_values = data_size / int<-size_of(int)
        var index = 0
        while index < stored_values and index < STORAGE_VALUE_COUNT:
            unsafe:
                let source = ptr[int]<-data
                values[index] = read(source + ptr_uint<-index)
            index += 1

    values[position] = value
    return rl.save_file_data(
        STORAGE_DATA_FILE,
        unsafe: span[ubyte](
            data = ptr[ubyte]<-ptr_of(values[0]),
            len = ptr_uint<-(STORAGE_VALUE_COUNT * int<-size_of(int))
        )
    )


function load_storage_value(position: int) -> int:
    if position < 0 or position >= STORAGE_VALUE_COUNT:
        return 0

    var data_size = 0
    let data = rl.load_file_data(STORAGE_DATA_FILE, data_size) else:
        return 0
    defer rl.unload_file_data(data)

    if data_size < (position + 1) * int<-size_of(int):
        return 0

    unsafe:
        let values = ptr[int]<-data
        return read(values + ptr_uint<-position)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - storage values")
    defer rl.close_window()

    var score = 0
    var hiscore = 0
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            score = rl.get_random_value(1000, 2000)
            hiscore = rl.get_random_value(2000, 4000)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
            unsafe: save_storage_value(STORAGE_POSITION_SCORE, score)
            unsafe: save_storage_value(STORAGE_POSITION_HISCORE, hiscore)
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            score = load_storage_value(STORAGE_POSITION_SCORE)
            hiscore = load_storage_value(STORAGE_POSITION_HISCORE)

        frames_counter += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(f"SCORE: #{score}", 280, 130, 40, rl.MAROON)
        rl.draw_text(f"HI-SCORE: #{hiscore}", 210, 200, 50, rl.BLACK)
        rl.draw_text(f"frames: #{frames_counter}", 10, 10, 20, rl.LIME)
        rl.draw_text("Press R to generate random numbers", 220, 40, 20, rl.LIGHTGRAY)
        rl.draw_text("Press ENTER to SAVE values", 250, 310, 20, rl.LIGHTGRAY)
        rl.draw_text("Press SPACE to LOAD values", 252, 350, 20, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
