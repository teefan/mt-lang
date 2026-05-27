import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl
import std.str as text
import std.time as time


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const TIMESTAMP_BUFFER_SIZE: int = 64


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - hot reloading")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let frag_shader_file_name = rl.text_format("shaders/glsl%i/reload.fs", GLSL_VERSION)
    var frag_shader_file_mod_time = time.Timestamp<-rl.get_file_mod_time(frag_shader_file_name)

    var shader = rl.load_shader(null, frag_shader_file_name)
    defer rl.unload_shader(shader)

    var resolution_location = rl.get_shader_location(shader, "resolution")
    var mouse_location = rl.get_shader_location(shader, "mouse")
    var time_location = rl.get_shader_location(shader, "time")

    let resolution = rl.Vector2(x = float<-SCREEN_WIDTH, y = float<-SCREEN_HEIGHT)
    rl.set_shader_value(shader, resolution_location, resolution, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var total_time: float = 0.0
    var shader_auto_reloading = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        total_time += rl.get_frame_time()
        let mouse_position = rl.get_mouse_position()

        rl.set_shader_value(shader, time_location, total_time, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.set_shader_value(shader, mouse_location, mouse_position, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        if shader_auto_reloading or rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let current_frag_shader_mod_time = time.Timestamp<-rl.get_file_mod_time(frag_shader_file_name)
            if current_frag_shader_mod_time != frag_shader_file_mod_time:
                let updated_shader = rl.load_shader(null, frag_shader_file_name)
                if updated_shader.id != rlgl.get_shader_id_default():
                    rl.unload_shader(shader)
                    shader = updated_shader
                    resolution_location = rl.get_shader_location(shader, "resolution")
                    mouse_location = rl.get_shader_location(shader, "mouse")
                    time_location = rl.get_shader_location(shader, "time")
                    rl.set_shader_value(shader, resolution_location, resolution, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
                frag_shader_file_mod_time = current_frag_shader_mod_time

        if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            shader_auto_reloading = not shader_auto_reloading

        var timestamp_buffer = zero[array[char, TIMESTAMP_BUFFER_SIZE]]
        let timestamp_written = time.format_local_time_into(
            ptr_of(timestamp_buffer[0]),
            ptr_uint<-TIMESTAMP_BUFFER_SIZE,
            "%Y-%m-%d %H:%M:%S",
            frag_shader_file_mod_time,
        )
        let timestamp_text = if timestamp_written != 0: text.chars_as_str(ptr_of(timestamp_buffer[0])) else: "unknown"
        let reload_mode_text = if shader_auto_reloading: "AUTO" else: "MANUAL"
        let reload_mode_color = if shader_auto_reloading: rl.RED else: rl.BLACK
        let reload_mode_label = rl.text_format("PRESS [A] to TOGGLE SHADER AUTOLOADING: %s", reload_mode_text)
        let modified_label = rl.text_format("Shader last modification: %s", timestamp_text)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shader)
        rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.WHITE)
        rl.end_shader_mode()

        rl.draw_text(reload_mode_label, 10, 10, 10, reload_mode_color)
        if not shader_auto_reloading:
            rl.draw_text("MOUSE CLICK to SHADER RE-LOADING", 10, 30, 10, rl.BLACK)
        rl.draw_text(modified_label, 10, 430, 10, rl.BLACK)
        rl.end_drawing()

    return 0
