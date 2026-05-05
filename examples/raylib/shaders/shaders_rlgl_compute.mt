module examples.raylib.shaders.shaders_rlgl_compute

import std.c.raylib as rl
import std.rlgl as rlgl

const gol_width: int = 768
const max_buffered_transferts: int = 48
const screen_width: int = gol_width
const screen_height: int = gol_width
const window_title: cstr = c"raylib [shaders] example - rlgl compute"
const gol_logic_shader_path: cstr = c"../resources/shaders/glsl430/gol.glsl"
const gol_render_shader_path: cstr = c"../resources/shaders/glsl430/gol_render.glsl"
const gol_transfert_shader_path: cstr = c"../resources/shaders/glsl430/gol_transfert.glsl"
const resolution_uniform_name: cstr = c"resolution"
const brush_text: cstr = c"Use Mouse wheel to increase/decrease brush size"

struct GolUpdateCmd:
    x: uint
    y: uint
    w: uint
    enabled: uint

struct GolUpdateSSBO:
    count: uint
    commands: array[GolUpdateCmd, 48]


def char_ptr_to_cstr(value: ptr[char]) -> cstr:
    unsafe:
        return cstr<-value


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var resolution = array[float, 2](float<-screen_width, float<-screen_height)
    var brush_size = 8

    let gol_logic_code = rl.LoadFileText(gol_logic_shader_path)
    let gol_logic_shader = rlgl.load_shader(char_ptr_to_cstr(gol_logic_code), rlgl.RL_COMPUTE_SHADER)
    let gol_logic_program = rlgl.load_shader_program_compute(gol_logic_shader)
    rl.UnloadFileText(gol_logic_code)

    let gol_render_shader = rl.LoadShader(zero[cstr?], gol_render_shader_path)
    defer rl.UnloadShader(gol_render_shader)
    let res_uniform_loc = rl.GetShaderLocation(gol_render_shader, resolution_uniform_name)

    let gol_transfert_code = rl.LoadFileText(gol_transfert_shader_path)
    let gol_transfert_shader = rlgl.load_shader(char_ptr_to_cstr(gol_transfert_code), rlgl.RL_COMPUTE_SHADER)
    let gol_transfert_program = rlgl.load_shader_program_compute(gol_transfert_shader)
    rl.UnloadFileText(gol_transfert_code)

    let ssbo_a = rlgl.load_shader_buffer(uint<-(gol_width * gol_width * int<-sizeof(uint)), null, rlgl.RL_DYNAMIC_COPY)
    defer rlgl.unload_shader_buffer(ssbo_a)
    var current_ssbo = ssbo_a
    let ssbo_b = rlgl.load_shader_buffer(uint<-(gol_width * gol_width * int<-sizeof(uint)), null, rlgl.RL_DYNAMIC_COPY)
    defer rlgl.unload_shader_buffer(ssbo_b)
    var next_ssbo = ssbo_b
    let ssbo_transfert = rlgl.load_shader_buffer(uint<-sizeof(GolUpdateSSBO), null, rlgl.RL_DYNAMIC_COPY)
    defer rlgl.unload_shader_buffer(ssbo_transfert)

    var transfert_buffer = zero[GolUpdateSSBO]

    let white_image = rl.GenImageColor(gol_width, gol_width, rl.WHITE)
    let white_tex = rl.LoadTextureFromImage(white_image)
    defer rl.UnloadTexture(white_tex)
    rl.UnloadImage(white_image)

    defer:
        rlgl.unload_shader(gol_logic_shader)
        rlgl.unload_shader(gol_transfert_shader)
        rlgl.unload_shader_program(gol_transfert_program)
        rlgl.unload_shader_program(gol_logic_program)

    while not rl.WindowShouldClose():
        brush_size += int<-rl.GetMouseWheelMove()

        if (rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT)) and (transfert_buffer.count < uint<-max_buffered_transferts):
            let command_index = int<-transfert_buffer.count
            transfert_buffer.commands[command_index].x = uint<-(rl.GetMouseX() - brush_size / 2)
            transfert_buffer.commands[command_index].y = uint<-(rl.GetMouseY() - brush_size / 2)
            transfert_buffer.commands[command_index].w = uint<-brush_size
            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
                transfert_buffer.commands[command_index].enabled = uint<-1
            else:
                transfert_buffer.commands[command_index].enabled = uint<-0
            transfert_buffer.count += uint<-1
        elif transfert_buffer.count > 0:
            rlgl.update_shader_buffer(ssbo_transfert, ptr_of(transfert_buffer), uint<-sizeof(GolUpdateSSBO), 0)

            rlgl.enable_shader(gol_transfert_program)
            rlgl.bind_shader_buffer(current_ssbo, 1)
            rlgl.bind_shader_buffer(ssbo_transfert, 3)
            rlgl.compute_shader_dispatch(transfert_buffer.count, uint<-1, uint<-1)
            rlgl.disable_shader()

            transfert_buffer.count = uint<-0
        else:
            rlgl.enable_shader(gol_logic_program)
            rlgl.bind_shader_buffer(current_ssbo, 1)
            rlgl.bind_shader_buffer(next_ssbo, 2)
            rlgl.compute_shader_dispatch(uint<-(gol_width / 16), uint<-(gol_width / 16), uint<-1)
            rlgl.disable_shader()

            let temp = current_ssbo
            current_ssbo = next_ssbo
            next_ssbo = temp

        rlgl.bind_shader_buffer(current_ssbo, 1)
        rl.SetShaderValue(gol_render_shader, res_uniform_loc, ptr_of(resolution[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLANK)
        rl.BeginShaderMode(gol_render_shader)
        rl.DrawTexture(white_tex, 0, 0, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawRectangleLines(rl.GetMouseX() - brush_size / 2, rl.GetMouseY() - brush_size / 2, brush_size, brush_size, rl.RED)
        rl.DrawText(brush_text, 10, 10, 20, rl.WHITE)
        rl.DrawFPS(rl.GetScreenWidth() - 100, 10)

    return 0
