module examples.raylib.textures.textures_tiled_drawing

import std.c.raylib as rl

const opt_width: i32 = 220
const margin_size: i32 = 8
const color_size: i32 = 16
const max_colors: i32 = 10
const pattern_count: i32 = 6
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - tiled drawing"
const pattern_path: cstr = c"../resources/patterns.png"
const select_pattern_text: cstr = c"Select Pattern"
const select_color_text: cstr = c"Select Color"
const scale_label_text: cstr = c"Scale (UP/DOWN to change)"
const scale_format: cstr = c"%.2fx"
const rotation_label_text: cstr = c"Rotation (LEFT/RIGHT to change)"
const rotation_format: cstr = c"%.0f degrees"
const reset_text: cstr = c"Press [SPACE] to reset"
const fps_format: cstr = c"%i FPS"


def draw_texture_tiled(texture: rl.Texture2D, source: rl.Rectangle, dest: rl.Rectangle, origin: rl.Vector2, rotation: f32, scale: f32, tint: rl.Color) -> void:
    if texture.id <= 0 or scale <= 0.0:
        return
    if source.width == 0.0 or source.height == 0.0:
        return

    let tile_width = i32<-(source.width * scale)
    let tile_height = i32<-(source.height * scale)

    if dest.width < f32<-tile_width and dest.height < f32<-tile_height:
        rl.DrawTexturePro(
            texture,
            rl.Rectangle(
                x = source.x,
                y = source.y,
                width = (dest.width / f32<-tile_width) * source.width,
                height = (dest.height / f32<-tile_height) * source.height,
            ),
            rl.Rectangle(x = dest.x, y = dest.y, width = dest.width, height = dest.height),
            origin,
            rotation,
            tint,
        )
        return

    if dest.width <= f32<-tile_width:
        var dy = 0
        while dy + tile_height < i32<-dest.height:
            rl.DrawTexturePro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = (dest.width / f32<-tile_width) * source.width,
                    height = source.height,
                ),
                rl.Rectangle(x = dest.x, y = dest.y + f32<-dy, width = dest.width, height = f32<-tile_height),
                origin,
                rotation,
                tint,
            )
            dy += tile_height

        if f32<-dy < dest.height:
            rl.DrawTexturePro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = (dest.width / f32<-tile_width) * source.width,
                    height = ((dest.height - f32<-dy) / f32<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x, y = dest.y + f32<-dy, width = dest.width, height = dest.height - f32<-dy),
                origin,
                rotation,
                tint,
            )
        return

    if dest.height <= f32<-tile_height:
        var dx = 0
        while dx + tile_width < i32<-dest.width:
            rl.DrawTexturePro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = source.width,
                    height = (dest.height / f32<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x + f32<-dx, y = dest.y, width = f32<-tile_width, height = dest.height),
                origin,
                rotation,
                tint,
            )
            dx += tile_width

        if f32<-dx < dest.width:
            rl.DrawTexturePro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = ((dest.width - f32<-dx) / f32<-tile_width) * source.width,
                    height = (dest.height / f32<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x + f32<-dx, y = dest.y, width = dest.width - f32<-dx, height = dest.height),
                origin,
                rotation,
                tint,
            )
        return

    var dx = 0
    while dx + tile_width < i32<-dest.width:
        var dy = 0
        while dy + tile_height < i32<-dest.height:
            rl.DrawTexturePro(
                texture,
                source,
                rl.Rectangle(x = dest.x + f32<-dx, y = dest.y + f32<-dy, width = f32<-tile_width, height = f32<-tile_height),
                origin,
                rotation,
                tint,
            )
            dy += tile_height

        if f32<-dy < dest.height:
            rl.DrawTexturePro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = source.width,
                    height = ((dest.height - f32<-dy) / f32<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x + f32<-dx, y = dest.y + f32<-dy, width = f32<-tile_width, height = dest.height - f32<-dy),
                origin,
                rotation,
                tint,
            )

        dx += tile_width

    if f32<-dx < dest.width:
        var dy = 0
        while dy + tile_height < i32<-dest.height:
            rl.DrawTexturePro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = ((dest.width - f32<-dx) / f32<-tile_width) * source.width,
                    height = source.height,
                ),
                rl.Rectangle(x = dest.x + f32<-dx, y = dest.y + f32<-dy, width = dest.width - f32<-dx, height = f32<-tile_height),
                origin,
                rotation,
                tint,
            )
            dy += tile_height

        if f32<-dy < dest.height:
            rl.DrawTexturePro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = ((dest.width - f32<-dx) / f32<-tile_width) * source.width,
                    height = ((dest.height - f32<-dy) / f32<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x + f32<-dx, y = dest.y + f32<-dy, width = dest.width - f32<-dx, height = dest.height - f32<-dy),
                origin,
                rotation,
                tint,
            )


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let tex_pattern = rl.LoadTexture(pattern_path)
    defer rl.UnloadTexture(tex_pattern)

    rl.SetTextureFilter(tex_pattern, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    let rec_pattern = array[rl.Rectangle, pattern_count](
        rl.Rectangle(x = 3.0, y = 3.0, width = 66.0, height = 66.0),
        rl.Rectangle(x = 75.0, y = 3.0, width = 100.0, height = 100.0),
        rl.Rectangle(x = 3.0, y = 75.0, width = 66.0, height = 66.0),
        rl.Rectangle(x = 7.0, y = 156.0, width = 50.0, height = 50.0),
        rl.Rectangle(x = 85.0, y = 106.0, width = 90.0, height = 45.0),
        rl.Rectangle(x = 75.0, y = 154.0, width = 100.0, height = 60.0),
    )

    let colors = array[rl.Color, max_colors](rl.BLACK, rl.MAROON, rl.ORANGE, rl.BLUE, rl.PURPLE, rl.BEIGE, rl.LIME, rl.RED, rl.DARKGRAY, rl.SKYBLUE)
    var color_rec = zero[array[rl.Rectangle, max_colors]]

    var x: f32 = 0.0
    var y: f32 = 0.0
    for index in 0..max_colors:
        color_rec[index].x = 2.0 + f32<-margin_size + x
        color_rec[index].y = 22.0 + 256.0 + f32<-margin_size + y
        color_rec[index].width = f32<-(color_size * 2)
        color_rec[index].height = f32<-color_size

        if index == max_colors / 2 - 1:
            x = 0.0
            y += f32<-(color_size + margin_size)
        else:
            x += f32<-(color_size * 2 + margin_size)

    var active_pattern = 0
    var active_col = 0
    var scale: f32 = 1.0
    var rotation: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let mouse = rl.GetMousePosition()

            for index in 0..pattern_count:
                if rl.CheckCollisionPointRec(
                    mouse,
                    rl.Rectangle(
                        x = 2.0 + f32<-margin_size + rec_pattern[index].x,
                        y = 40.0 + f32<-margin_size + rec_pattern[index].y,
                        width = rec_pattern[index].width,
                        height = rec_pattern[index].height,
                    ),
                ):
                    active_pattern = index
                    break

            for index in 0..max_colors:
                if rl.CheckCollisionPointRec(mouse, color_rec[index]):
                    active_col = index
                    break

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            scale += 0.25
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            scale -= 0.25

        if scale > 10.0:
            scale = 10.0
        elif scale <= 0.0:
            scale = 0.25

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            rotation -= 25.0
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            rotation += 25.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            rotation = 0.0
            scale = 1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        draw_texture_tiled(
            tex_pattern,
            rec_pattern[active_pattern],
            rl.Rectangle(
                x = f32<-(opt_width + margin_size),
                y = f32<-margin_size,
                width = f32<-(rl.GetScreenWidth() - opt_width - 2 * margin_size),
                height = f32<-(rl.GetScreenHeight() - 2 * margin_size),
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            rotation,
            scale,
            colors[active_col],
        )

        rl.DrawRectangle(margin_size, margin_size, opt_width - margin_size, rl.GetScreenHeight() - 2 * margin_size, rl.ColorAlpha(rl.LIGHTGRAY, 0.5))

        rl.DrawText(select_pattern_text, 2 + margin_size, 30 + margin_size, 10, rl.BLACK)
        rl.DrawTexture(tex_pattern, 2 + margin_size, 40 + margin_size, rl.BLACK)
        rl.DrawRectangle(
            2 + margin_size + i32<-rec_pattern[active_pattern].x,
            40 + margin_size + i32<-rec_pattern[active_pattern].y,
            i32<-rec_pattern[active_pattern].width,
            i32<-rec_pattern[active_pattern].height,
            rl.ColorAlpha(rl.DARKBLUE, 0.3),
        )

        rl.DrawText(select_color_text, 2 + margin_size, 10 + 256 + margin_size, 10, rl.BLACK)
        for index in 0..max_colors:
            rl.DrawRectangleRec(color_rec[index], colors[index])
            if active_col == index:
                rl.DrawRectangleLinesEx(color_rec[index], 3.0, rl.ColorAlpha(rl.WHITE, 0.5))

        rl.DrawText(scale_label_text, 2 + margin_size, 80 + 256 + margin_size, 10, rl.BLACK)
        rl.DrawText(rl.TextFormat(scale_format, scale), 2 + margin_size, 92 + 256 + margin_size, 20, rl.BLACK)

        rl.DrawText(rotation_label_text, 2 + margin_size, 122 + 256 + margin_size, 10, rl.BLACK)
        rl.DrawText(rl.TextFormat(rotation_format, rotation), 2 + margin_size, 134 + 256 + margin_size, 20, rl.BLACK)
        rl.DrawText(reset_text, 2 + margin_size, 164 + 256 + margin_size, 10, rl.DARKBLUE)

        rl.DrawText(rl.TextFormat(fps_format, rl.GetFPS()), 2 + margin_size, 2 + margin_size, 20, rl.BLACK)

    return 0
