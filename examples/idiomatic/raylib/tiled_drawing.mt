module examples.idiomatic.raylib.tiled_drawing

import std.raylib as rl

const opt_width: i32 = 220
const margin_size: i32 = 8
const color_size: i32 = 16
const max_colors: i32 = 10
const pattern_count: i32 = 6
const screen_width: i32 = 800
const screen_height: i32 = 450
const pattern_path: str = "../../raylib/resources/patterns.png"


def draw_texture_tiled(texture: rl.Texture2D, source: rl.Rectangle, dest: rl.Rectangle, origin: rl.Vector2, rotation: f32, scale: f32, tint: rl.Color) -> void:
    if texture.id <= 0 or scale <= 0.0:
        return
    if source.width == 0.0 or source.height == 0.0:
        return

    let tile_width = i32<-(source.width * scale)
    let tile_height = i32<-(source.height * scale)

    if dest.width < f32<-tile_width and dest.height < f32<-tile_height:
        rl.draw_texture_pro(
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
            rl.draw_texture_pro(
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
            rl.draw_texture_pro(
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
            rl.draw_texture_pro(
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
            rl.draw_texture_pro(
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
            rl.draw_texture_pro(
                texture,
                source,
                rl.Rectangle(x = dest.x + f32<-dx, y = dest.y + f32<-dy, width = f32<-tile_width, height = f32<-tile_height),
                origin,
                rotation,
                tint,
            )
            dy += tile_height

        if f32<-dy < dest.height:
            rl.draw_texture_pro(
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
            rl.draw_texture_pro(
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
            rl.draw_texture_pro(
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
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.init_window(screen_width, screen_height, "Milk Tea Tiled Drawing")
    defer rl.close_window()

    let tex_pattern = rl.load_texture(pattern_path)
    defer rl.unload_texture(tex_pattern)

    rl.set_texture_filter(tex_pattern, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    let rec_pattern = array[rl.Rectangle, 6](
        rl.Rectangle(x = 3.0, y = 3.0, width = 66.0, height = 66.0),
        rl.Rectangle(x = 75.0, y = 3.0, width = 100.0, height = 100.0),
        rl.Rectangle(x = 3.0, y = 75.0, width = 66.0, height = 66.0),
        rl.Rectangle(x = 7.0, y = 156.0, width = 50.0, height = 50.0),
        rl.Rectangle(x = 85.0, y = 106.0, width = 90.0, height = 45.0),
        rl.Rectangle(x = 75.0, y = 154.0, width = 100.0, height = 60.0),
    )

    let colors = array[rl.Color, 10](rl.BLACK, rl.MAROON, rl.ORANGE, rl.BLUE, rl.PURPLE, rl.BEIGE, rl.LIME, rl.RED, rl.DARKGRAY, rl.SKYBLUE)
    var color_rec = zero[array[rl.Rectangle, 10]]()

    var x: f32 = 0.0
    var y: f32 = 0.0
    for index in range(0, max_colors):
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

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let mouse = rl.get_mouse_position()

            for index in range(0, pattern_count):
                if rl.check_collision_point_rec(
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

            for index in range(0, max_colors):
                if rl.check_collision_point_rec(mouse, color_rec[index]):
                    active_col = index
                    break

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            scale += 0.25
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            scale -= 0.25

        if scale > 10.0:
            scale = 10.0
        elif scale <= 0.0:
            scale = 0.25

        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            rotation -= 25.0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            rotation += 25.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rotation = 0.0
            scale = 1.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        draw_texture_tiled(
            tex_pattern,
            rec_pattern[active_pattern],
            rl.Rectangle(
                x = f32<-(opt_width + margin_size),
                y = f32<-margin_size,
                width = f32<-(rl.get_screen_width() - opt_width - 2 * margin_size),
                height = f32<-(rl.get_screen_height() - 2 * margin_size),
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            rotation,
            scale,
            colors[active_col],
        )

        rl.draw_rectangle(margin_size, margin_size, opt_width - margin_size, rl.get_screen_height() - 2 * margin_size, rl.color_alpha(rl.LIGHTGRAY, 0.5))

        rl.draw_text("Select Pattern", 2 + margin_size, 30 + margin_size, 10, rl.BLACK)
        rl.draw_texture(tex_pattern, 2 + margin_size, 40 + margin_size, rl.BLACK)
        rl.draw_rectangle(
            2 + margin_size + i32<-rec_pattern[active_pattern].x,
            40 + margin_size + i32<-rec_pattern[active_pattern].y,
            i32<-rec_pattern[active_pattern].width,
            i32<-rec_pattern[active_pattern].height,
            rl.color_alpha(rl.DARKBLUE, 0.3),
        )

        rl.draw_text("Select Color", 2 + margin_size, 10 + 256 + margin_size, 10, rl.BLACK)
        for index in range(0, max_colors):
            rl.draw_rectangle_rec(color_rec[index], colors[index])
            if active_col == index:
                rl.draw_rectangle_lines_ex(color_rec[index], 3.0, rl.color_alpha(rl.WHITE, 0.5))

        rl.draw_text("Scale (UP/DOWN to change)", 2 + margin_size, 80 + 256 + margin_size, 10, rl.BLACK)
        rl.draw_text(rl.text_format_f32("%.2fx", scale), 2 + margin_size, 92 + 256 + margin_size, 20, rl.BLACK)

        rl.draw_text("Rotation (LEFT/RIGHT to change)", 2 + margin_size, 122 + 256 + margin_size, 10, rl.BLACK)
        rl.draw_text(rl.text_format_f32("%.0f degrees", rotation), 2 + margin_size, 134 + 256 + margin_size, 20, rl.BLACK)
        rl.draw_text("Press [SPACE] to reset", 2 + margin_size, 164 + 256 + margin_size, 10, rl.DARKBLUE)

        rl.draw_text(rl.text_format_i32("%i FPS", rl.get_fps()), 2 + margin_size, 2 + margin_size, 20, rl.BLACK)

    return 0
