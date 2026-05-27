import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MIN_WINDOW_SIZE: int = 450
const CELL_SIZE: int = 50


function draw_text_center(text: str, x: int, y: int, font_size: int, color: rl.Color) -> void:
    let size = rl.measure_text_ex(rl.get_font_default(), text, float<-font_size, 3.0)
    let position = rl.Vector2(
        x = (float<-x) - size.x / 2.0,
        y = (float<-y) - size.y / 2.0,
    )
    rl.draw_text_ex(rl.get_font_default(), text, position, float<-font_size, 3.0, color)


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_HIGHDPI | rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - highdpi demo")
    defer rl.close_window()

    rl.set_window_min_size(MIN_WINDOW_SIZE, MIN_WINDOW_SIZE)

    let logical_grid_desc_y = 120
    let logical_grid_label_y = logical_grid_desc_y + 30
    let logical_grid_top = logical_grid_label_y + 30
    let logical_grid_bottom = logical_grid_top + 80
    let pixel_grid_top = logical_grid_bottom - 20
    let pixel_grid_bottom = pixel_grid_top + 80
    let pixel_grid_label_y = pixel_grid_bottom + 30
    let pixel_grid_desc_y = pixel_grid_label_y + 30

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let monitor_count = rl.get_monitor_count()
        if monitor_count > 1 and rl.is_key_pressed(rl.KeyboardKey.KEY_N):
            rl.set_window_monitor((rl.get_current_monitor() + 1) % monitor_count)

        let current_monitor = rl.get_current_monitor()
        let dpi_scale = rl.get_window_scale_dpi()
        let cell_size_px = (float<-CELL_SIZE) / dpi_scale.x

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        let window_center = rl.get_screen_width() / 2
        draw_text_center(f"Dpi Scale: #{dpi_scale.x}", window_center, 30, 40, rl.DARKGRAY)
        draw_text_center(f"Monitor: #{current_monitor + 1}/#{monitor_count} ([N] next monitor)", window_center, 70, 20, rl.LIGHTGRAY)
        draw_text_center(f"Window is #{rl.get_screen_width()} \"logical points\" wide", window_center, logical_grid_desc_y, 20, rl.ORANGE)

        var odd = true
        var logical_x = CELL_SIZE
        while logical_x < rl.get_screen_width():
            if odd:
                rl.draw_rectangle(logical_x, logical_grid_top, CELL_SIZE, logical_grid_bottom - logical_grid_top, rl.ORANGE)

            draw_text_center(f"#{logical_x}", logical_x, logical_grid_label_y, 10, rl.LIGHTGRAY)
            rl.draw_line(logical_x, logical_grid_label_y + 10, logical_x, logical_grid_bottom, rl.GRAY)

            logical_x += CELL_SIZE
            odd = not odd

        odd = true
        let min_text_space = 30
        var last_text_x = -min_text_space
        var render_x = CELL_SIZE
        while render_x < rl.get_render_width():
            let x = int<-((float<-render_x) / dpi_scale.x)
            if odd:
                rl.draw_rectangle(x, pixel_grid_top, int<-cell_size_px, pixel_grid_bottom - pixel_grid_top, rl.Color(r = 0, g = 121, b = 241, a = 100))

            rl.draw_line(x, pixel_grid_top, int<-((float<-render_x) / dpi_scale.x), pixel_grid_label_y - 10, rl.GRAY)
            if (x - last_text_x) >= min_text_space:
                draw_text_center(f"#{render_x}", x, pixel_grid_label_y, 10, rl.LIGHTGRAY)
                last_text_x = x

            render_x += CELL_SIZE
            odd = not odd

        draw_text_center(f"Window is #{rl.get_render_width()} \"physical pixels\" wide", window_center, pixel_grid_desc_y, 20, rl.BLUE)

        let text = "Can you see this?"
        let size = rl.measure_text_ex(rl.get_font_default(), text, 20.0, 3.0)
        let position = rl.Vector2(
            x = (float<-rl.get_screen_width()) - size.x - 5.0,
            y = (float<-rl.get_screen_height()) - size.y - 5.0,
        )
        rl.draw_text_ex(rl.get_font_default(), text, position, 20.0, 3.0, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
