import std.raylib as rl

public struct DebugState:
    enabled: bool
    visible: bool


public function debug_init() -> DebugState:
    return DebugState(
        enabled = true,
        visible = false
    )


public function debug_update(state: ref[DebugState]) -> void:
    let key_f3 = rl.is_key_pressed(rl.KeyboardKey.KEY_F3)
    if key_f3:
        state.visible = not(state.visible)


public function debug_draw(state: const_ptr[DebugState], font_size: int) -> void:
    var visible = false
    unsafe:
        visible = read(state).visible

    if not visible:
        return

    let width = rl.get_screen_width()
    let height = rl.get_screen_height()
    let panel_x = width - 290
    let panel_y = 10
    let panel_width = 280
    let panel_height = 160

    rl.draw_rectangle(
        panel_x,
        panel_y,
        panel_width,
        panel_height,
        rl.Color(r = 0, g = 0, b = 0, a = 200)
    )

    let fps = rl.get_fps()
    let fps_text = f"FPS: #{fps}"
    rl.draw_text(
        fps_text,
        panel_x + 4,
        panel_y + 4,
        font_size,
        rl.Color(r = 0, g = 255, b = 0, a = 255)
    )

    let dt = rl.get_frame_time() * 1000.0
    let dt_text = f"Frame: #{dt} ms"
    rl.draw_text(
        dt_text,
        panel_x + 4,
        panel_y + 4 + font_size + 4,
        font_size,
        rl.Color(r = 255, g = 255, b = 0, a = 255)
    )

    let screen_text = f"#{width}x#{height}"
    rl.draw_text(
        screen_text,
        panel_x + 4,
        panel_y + 4 + (font_size + 4) * 2,
        font_size,
        rl.Color(r = 200, g = 200, b = 200, a = 255)
    )
