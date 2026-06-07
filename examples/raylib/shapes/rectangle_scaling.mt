import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MOUSE_SCALE_MARK_SIZE: int = 12


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - rectangle scaling")
    defer rl.close_window()

    var rec = rl.Rectangle(x = 100.0, y = 100.0, width = 200.0, height = 80.0)
    var mouse_position = rl.Vector2(x = 0.0, y = 0.0)
    var mouse_scale_ready = false
    var mouse_scale_mode = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        mouse_position = rl.get_mouse_position()
        let scale_mark = rl.Rectangle(
            x = rec.x + rec.width - float<-MOUSE_SCALE_MARK_SIZE,
            y = rec.y + rec.height - float<-MOUSE_SCALE_MARK_SIZE,
            width = float<-MOUSE_SCALE_MARK_SIZE,
            height = float<-MOUSE_SCALE_MARK_SIZE
        )

        if rl.check_collision_point_rec(mouse_position, scale_mark):
            mouse_scale_ready = true
            if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                mouse_scale_mode = true
        else:
            mouse_scale_ready = false

        if mouse_scale_mode:
            mouse_scale_ready = true
            rec.width = mouse_position.x - rec.x
            rec.height = mouse_position.y - rec.y

            if rec.width < float<-MOUSE_SCALE_MARK_SIZE:
                rec.width = float<-MOUSE_SCALE_MARK_SIZE
            if rec.height < float<-MOUSE_SCALE_MARK_SIZE:
                rec.height = float<-MOUSE_SCALE_MARK_SIZE

            if rec.width > float<-rl.get_screen_width() - rec.x:
                rec.width = float<-rl.get_screen_width() - rec.x
            if rec.height > float<-rl.get_screen_height() - rec.y:
                rec.height = float<-rl.get_screen_height() - rec.y

            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                mouse_scale_mode = false

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("Scale rectangle dragging from bottom-right corner!", 10, 10, 20, rl.GRAY)
        rl.draw_rectangle_rec(rec, rl.fade(rl.GREEN, 0.5))

        if mouse_scale_ready:
            rl.draw_rectangle_lines_ex(rec, 1.0, rl.RED)
            rl.draw_triangle(
                rl.Vector2(x = rec.x + rec.width - float<-MOUSE_SCALE_MARK_SIZE, y = rec.y + rec.height),
                rl.Vector2(x = rec.x + rec.width, y = rec.y + rec.height),
                rl.Vector2(x = rec.x + rec.width, y = rec.y + rec.height - float<-MOUSE_SCALE_MARK_SIZE),
                rl.RED
            )

        rl.end_drawing()

    return 0
