module examples.raylib.textures.textures_mouse_painting

import std.c.raylib as rl

const max_colors_count: i32 = 23
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - mouse painting"
const save_path: cstr = c"my_amazing_texture_painting.png"
const save_text: cstr = c"SAVE!"
const saved_text: cstr = c"IMAGE SAVED!"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let colors = array[rl.Color, max_colors_count](
        rl.RAYWHITE, rl.YELLOW, rl.GOLD, rl.ORANGE, rl.PINK, rl.RED, rl.MAROON, rl.GREEN, rl.LIME, rl.DARKGREEN,
        rl.SKYBLUE, rl.BLUE, rl.DARKBLUE, rl.PURPLE, rl.VIOLET, rl.DARKPURPLE, rl.BEIGE, rl.BROWN, rl.DARKBROWN,
        rl.LIGHTGRAY, rl.GRAY, rl.DARKGRAY, rl.BLACK,
    )

    var colors_recs = zero[array[rl.Rectangle, max_colors_count]]()
    for index in range(0, max_colors_count):
        colors_recs[index].x = 10.0 + 30.0 * f32<-index + 2.0 * f32<-index
        colors_recs[index].y = 10.0
        colors_recs[index].width = 30.0
        colors_recs[index].height = 30.0

    var color_selected = 0
    var color_selected_prev = color_selected
    var color_mouse_hover = 0
    var brush_size: f32 = 20.0
    var mouse_was_pressed = false

    let btn_save_rec = rl.Rectangle(x = 750.0, y = 10.0, width = 40.0, height = 30.0)
    var btn_save_mouse_hover = false
    var show_save_message = false
    var save_message_counter = 0

    let target = rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(target)

    rl.BeginTextureMode(target)
    rl.ClearBackground(colors[0])
    rl.EndTextureMode()

    rl.SetTargetFPS(120)

    while not rl.WindowShouldClose():
        let mouse_pos = rl.GetMousePosition()

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            color_selected += 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            color_selected -= 1

        if color_selected >= max_colors_count:
            color_selected = max_colors_count - 1
        elif color_selected < 0:
            color_selected = 0

        color_mouse_hover = -1
        for index in range(0, max_colors_count):
            if rl.CheckCollisionPointRec(mouse_pos, colors_recs[index]):
                color_mouse_hover = index
                break

        if color_mouse_hover >= 0 and rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            color_selected = color_mouse_hover
            color_selected_prev = color_selected

        brush_size += rl.GetMouseWheelMove() * 5.0
        if brush_size < 2.0:
            brush_size = 2.0
        if brush_size > 50.0:
            brush_size = 50.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_C):
            rl.BeginTextureMode(target)
            rl.ClearBackground(colors[0])
            rl.EndTextureMode()

        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.GetGestureDetected() == rl.Gesture.GESTURE_DRAG:
            rl.BeginTextureMode(target)
            if mouse_pos.y > 50.0:
                rl.DrawCircle(i32<-mouse_pos.x, i32<-mouse_pos.y, brush_size, colors[color_selected])
            rl.EndTextureMode()

        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if not mouse_was_pressed:
                color_selected_prev = color_selected
                color_selected = 0

            mouse_was_pressed = true

            rl.BeginTextureMode(target)
            if mouse_pos.y > 50.0:
                rl.DrawCircle(i32<-mouse_pos.x, i32<-mouse_pos.y, brush_size, colors[0])
            rl.EndTextureMode()
        elif rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_RIGHT) and mouse_was_pressed:
            color_selected = color_selected_prev
            mouse_was_pressed = false

        btn_save_mouse_hover = rl.CheckCollisionPointRec(mouse_pos, btn_save_rec)

        if (btn_save_mouse_hover and rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT)) or rl.IsKeyPressed(rl.KeyboardKey.KEY_S):
            var image = rl.LoadImageFromTexture(target.texture)
            rl.ImageFlipVertical(ptr_of(ref_of(image)))
            rl.ExportImage(image, save_path)
            rl.UnloadImage(image)
            show_save_message = true

        if show_save_message:
            save_message_counter += 1
            if save_message_counter > 240:
                show_save_message = false
                save_message_counter = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTextureRec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = target.texture.width, height = -target.texture.height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )

        if mouse_pos.y > 50.0:
            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT):
                rl.DrawCircleLines(i32<-mouse_pos.x, i32<-mouse_pos.y, brush_size, rl.GRAY)
            else:
                rl.DrawCircle(rl.GetMouseX(), rl.GetMouseY(), brush_size, colors[color_selected])

        rl.DrawRectangle(0, 0, rl.GetScreenWidth(), 50, rl.RAYWHITE)
        rl.DrawLine(0, 50, rl.GetScreenWidth(), 50, rl.LIGHTGRAY)

        for index in range(0, max_colors_count):
            rl.DrawRectangleRec(colors_recs[index], colors[index])
        rl.DrawRectangleLines(10, 10, 30, 30, rl.LIGHTGRAY)

        if color_mouse_hover >= 0:
            rl.DrawRectangleRec(colors_recs[color_mouse_hover], rl.Fade(rl.WHITE, 0.6))

        rl.DrawRectangleLinesEx(
            rl.Rectangle(
                x = colors_recs[color_selected].x - 2.0,
                y = colors_recs[color_selected].y - 2.0,
                width = colors_recs[color_selected].width + 4.0,
                height = colors_recs[color_selected].height + 4.0,
            ),
            2.0,
            rl.BLACK,
        )

        rl.DrawRectangleLinesEx(btn_save_rec, 2.0, if btn_save_mouse_hover: rl.RED else: rl.BLACK)
        rl.DrawText(save_text, 755, 20, 10, if btn_save_mouse_hover: rl.RED else: rl.BLACK)

        if show_save_message:
            rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Fade(rl.RAYWHITE, 0.8))
            rl.DrawRectangle(0, 150, rl.GetScreenWidth(), 80, rl.BLACK)
            rl.DrawText(saved_text, 150, 180, 20, rl.RAYWHITE)

    return 0