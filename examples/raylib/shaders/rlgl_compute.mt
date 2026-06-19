import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl
import std.str as text

const GOL_WIDTH: int = 768
const SCREEN_WIDTH: int = GOL_WIDTH
const SCREEN_HEIGHT: int = GOL_WIDTH
const MAX_BUFFERED_TRANSFERS: int = 48

struct GolUpdateCmd:
    x: uint
    y: uint
    w: uint
    enabled: uint

struct GolUpdateSSBO:
    count: uint
    commands: array[GolUpdateCmd, 48]


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - rlgl compute")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let resolution = array[float, 2](float<-SCREEN_WIDTH, float<-SCREEN_HEIGHT)
    var brush_size: int = 8

    let gol_logic_code = rl.load_file_text("shaders/glsl430/gol.glsl") else:
        fatal("failed to load gol.glsl")
    let gol_logic_shader = rlgl.load_shader(text.chars_as_str(gol_logic_code), rlgl.RL_COMPUTE_SHADER)
    let gol_logic_program = rlgl.load_shader_program_compute(gol_logic_shader)
    rl.unload_file_text(gol_logic_code)

    let gol_render_shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/gol_render.glsl", 430))
    defer rl.unload_shader(gol_render_shader)
    let resolution_uniform_location = rl.get_shader_location(gol_render_shader, "resolution")

    let gol_transfer_code = rl.load_file_text("shaders/glsl430/gol_transfert.glsl") else:
        fatal("failed to load gol_transfert.glsl")
    let gol_transfer_shader = rlgl.load_shader(text.chars_as_str(gol_transfer_code), rlgl.RL_COMPUTE_SHADER)
    let gol_transfer_program = rlgl.load_shader_program_compute(gol_transfer_shader)
    rl.unload_file_text(gol_transfer_code)

    var ssbo_a = rlgl.load_shader_buffer(uint<-(GOL_WIDTH * GOL_WIDTH * int<-size_of(uint)), null, rlgl.RL_DYNAMIC_COPY)
    defer rlgl.unload_shader_buffer(ssbo_a)
    var ssbo_b = rlgl.load_shader_buffer(uint<-(GOL_WIDTH * GOL_WIDTH * int<-size_of(uint)), null, rlgl.RL_DYNAMIC_COPY)
    defer rlgl.unload_shader_buffer(ssbo_b)
    let ssbo_transfer = rlgl.load_shader_buffer(uint<-size_of(GolUpdateSSBO), null, rlgl.RL_DYNAMIC_COPY)
    defer rlgl.unload_shader_buffer(ssbo_transfer)

    var transfer_buffer: GolUpdateSSBO = zero[GolUpdateSSBO]

    let white_image = rl.gen_image_color(GOL_WIDTH, GOL_WIDTH, rl.WHITE)
    defer rl.unload_image(white_image)
    let white_texture = rl.load_texture_from_image(white_image)
    defer rl.unload_texture(white_texture)

    defer rlgl.unload_shader(gol_logic_shader)
    defer rlgl.unload_shader(gol_transfer_shader)
    defer rlgl.unload_shader_program(gol_transfer_program)
    defer rlgl.unload_shader_program(gol_logic_program)

    while not rl.window_should_close():
        brush_size += int<-rl.get_mouse_wheel_move()
        if brush_size < 1:
            brush_size = 1

        if (rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT)) and (transfer_buffer.count < uint<-MAX_BUFFERED_TRANSFERS):
            let command_index = int<-transfer_buffer.count
            transfer_buffer.commands[command_index].x = uint<-(rl.get_mouse_x() - brush_size / 2)
            transfer_buffer.commands[command_index].y = uint<-(rl.get_mouse_y() - brush_size / 2)
            transfer_buffer.commands[command_index].w = uint<-brush_size
            transfer_buffer.commands[command_index].enabled = if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT): 1u else: 0u
            transfer_buffer.count += 1u
        else if transfer_buffer.count > 0u:
            rlgl.update_shader_buffer(ssbo_transfer, ptr_of(transfer_buffer), uint<-size_of(GolUpdateSSBO), 0u)

            rlgl.enable_shader(gol_transfer_program)
            rlgl.bind_shader_buffer(ssbo_a, 1u)
            rlgl.bind_shader_buffer(ssbo_transfer, 3u)
            rlgl.compute_shader_dispatch(transfer_buffer.count, 1u, 1u)
            rlgl.disable_shader()

            transfer_buffer.count = 0u
        else:
            rlgl.enable_shader(gol_logic_program)
            rlgl.bind_shader_buffer(ssbo_a, 1u)
            rlgl.bind_shader_buffer(ssbo_b, 2u)
            rlgl.compute_shader_dispatch(uint<-(GOL_WIDTH / 16), uint<-(GOL_WIDTH / 16), 1u)
            rlgl.disable_shader()

            let temp = ssbo_a
            ssbo_a = ssbo_b
            ssbo_b = temp

        rlgl.bind_shader_buffer(ssbo_a, 1u)
        rl.set_shader_value(
            gol_render_shader,
            resolution_uniform_location,
            resolution,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2
        )

        rl.begin_drawing()
        rl.clear_background(rl.BLANK)
        rl.begin_shader_mode(gol_render_shader)
        rl.draw_texture(white_texture, 0, 0, rl.WHITE)
        rl.end_shader_mode()
        rl.draw_rectangle_lines(
            rl.get_mouse_x() - brush_size / 2,
            rl.get_mouse_y() - brush_size / 2,
            brush_size,
            brush_size,
            rl.RED
        )
        rl.draw_text("Use Mouse wheel to increase/decrease brush size", 10, 10, 20, rl.WHITE)
        rl.draw_fps(rl.get_screen_width() - 100, 10)
        rl.end_drawing()

    return 0
