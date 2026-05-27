import std.raylib as rl
import std.raylib.runtime as rl_runtime


const OPT_WIDTH: int = 220
const MARGIN_SIZE: int = 8
const COLOR_SIZE: int = 16
const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_PATTERNS: int = 6
const MAX_COLORS: int = 10


function draw_texture_tiled(texture: rl.Texture2D, source: rl.Rectangle, dest: rl.Rectangle, origin: rl.Vector2, rotation: float, scale: float, tint: rl.Color) -> void:
    if texture.id <= 0 or scale <= 0.0:
        return
    if source.width == 0.0 or source.height == 0.0:
        return

    let tile_width = int<-(source.width * scale)
    let tile_height = int<-(source.height * scale)

    if dest.width < float<-tile_width and dest.height < float<-tile_height:
        rl.draw_texture_pro(
            texture,
            rl.Rectangle(
                x = source.x,
                y = source.y,
                width = (dest.width / float<-tile_width) * source.width,
                height = (dest.height / float<-tile_height) * source.height,
            ),
            dest,
            origin,
            rotation,
            tint,
        )
        return

    if dest.width <= float<-tile_width:
        var dy = 0
        while dy + tile_height < int<-dest.height:
            rl.draw_texture_pro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = (dest.width / float<-tile_width) * source.width,
                    height = source.height,
                ),
                rl.Rectangle(x = dest.x, y = dest.y + float<-dy, width = dest.width, height = float<-tile_height),
                origin,
                rotation,
                tint,
            )
            dy += tile_height

        if float<-dy < dest.height:
            rl.draw_texture_pro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = (dest.width / float<-tile_width) * source.width,
                    height = ((dest.height - float<-dy) / float<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x, y = dest.y + float<-dy, width = dest.width, height = dest.height - float<-dy),
                origin,
                rotation,
                tint,
            )
        return

    if dest.height <= float<-tile_height:
        var dx = 0
        while dx + tile_width < int<-dest.width:
            rl.draw_texture_pro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = source.width,
                    height = (dest.height / float<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x + float<-dx, y = dest.y, width = float<-tile_width, height = dest.height),
                origin,
                rotation,
                tint,
            )
            dx += tile_width

        if float<-dx < dest.width:
            rl.draw_texture_pro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = ((dest.width - float<-dx) / float<-tile_width) * source.width,
                    height = (dest.height / float<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x + float<-dx, y = dest.y, width = dest.width - float<-dx, height = dest.height),
                origin,
                rotation,
                tint,
            )
        return

    var dx = 0
    while dx + tile_width < int<-dest.width:
        var dy = 0
        while dy + tile_height < int<-dest.height:
            rl.draw_texture_pro(
                texture,
                source,
                rl.Rectangle(x = dest.x + float<-dx, y = dest.y + float<-dy, width = float<-tile_width, height = float<-tile_height),
                origin,
                rotation,
                tint,
            )
            dy += tile_height

        if float<-dy < dest.height:
            rl.draw_texture_pro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = source.width,
                    height = ((dest.height - float<-dy) / float<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x + float<-dx, y = dest.y + float<-dy, width = float<-tile_width, height = dest.height - float<-dy),
                origin,
                rotation,
                tint,
            )
        dx += tile_width

    if float<-dx < dest.width:
        var dy = 0
        while dy + tile_height < int<-dest.height:
            rl.draw_texture_pro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = ((dest.width - float<-dx) / float<-tile_width) * source.width,
                    height = source.height,
                ),
                rl.Rectangle(x = dest.x + float<-dx, y = dest.y + float<-dy, width = dest.width - float<-dx, height = float<-tile_height),
                origin,
                rotation,
                tint,
            )
            dy += tile_height

        if float<-dy < dest.height:
            rl.draw_texture_pro(
                texture,
                rl.Rectangle(
                    x = source.x,
                    y = source.y,
                    width = ((dest.width - float<-dx) / float<-tile_width) * source.width,
                    height = ((dest.height - float<-dy) / float<-tile_height) * source.height,
                ),
                rl.Rectangle(x = dest.x + float<-dx, y = dest.y + float<-dy, width = dest.width - float<-dx, height = dest.height - float<-dy),
                origin,
                rotation,
                tint,
            )


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - tiled drawing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let pattern_texture = rl.load_texture("patterns.png")
    defer rl.unload_texture(pattern_texture)
    rl.set_texture_filter(pattern_texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    let patterns = array[rl.Rectangle, MAX_PATTERNS](
        rl.Rectangle(x = 3.0, y = 3.0, width = 66.0, height = 66.0),
        rl.Rectangle(x = 75.0, y = 3.0, width = 100.0, height = 100.0),
        rl.Rectangle(x = 3.0, y = 75.0, width = 66.0, height = 66.0),
        rl.Rectangle(x = 7.0, y = 156.0, width = 50.0, height = 50.0),
        rl.Rectangle(x = 85.0, y = 106.0, width = 90.0, height = 45.0),
        rl.Rectangle(x = 75.0, y = 154.0, width = 100.0, height = 60.0),
    )
    let colors = array[rl.Color, MAX_COLORS](
        rl.BLACK,
        rl.MAROON,
        rl.ORANGE,
        rl.BLUE,
        rl.PURPLE,
        rl.BEIGE,
        rl.LIME,
        rl.RED,
        rl.DARKGRAY,
        rl.SKYBLUE,
    )

    var color_rects: array[rl.Rectangle, MAX_COLORS] = zero[array[rl.Rectangle, MAX_COLORS]]
    var index = 0
    var x_offset = 0
    var y_offset = 0
    while index < MAX_COLORS:
        color_rects[index].x = 2.0 + float<-MARGIN_SIZE + float<-x_offset
        color_rects[index].y = 22.0 + 256.0 + float<-MARGIN_SIZE + float<-y_offset
        color_rects[index].width = float<-(COLOR_SIZE * 2)
        color_rects[index].height = float<-COLOR_SIZE

        if index == (MAX_COLORS / 2) - 1:
            x_offset = 0
            y_offset += COLOR_SIZE + MARGIN_SIZE
        else:
            x_offset += (COLOR_SIZE * 2) + MARGIN_SIZE
        index += 1

    var active_pattern = 0
    var active_color = 0
    var scale = float<-1.0
    var rotation = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let mouse = rl.get_mouse_position()

            index = 0
            while index < MAX_PATTERNS:
                let hit_rect = rl.Rectangle(
                    x = 2.0 + float<-MARGIN_SIZE + patterns[index].x,
                    y = 40.0 + float<-MARGIN_SIZE + patterns[index].y,
                    width = patterns[index].width,
                    height = patterns[index].height,
                )
                if rl.check_collision_point_rec(mouse, hit_rect):
                    active_pattern = index
                    break
                index += 1

            index = 0
            while index < MAX_COLORS:
                if rl.check_collision_point_rec(mouse, color_rects[index]):
                    active_color = index
                    break
                index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            scale += 0.25
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            scale -= 0.25
        if scale > 10.0:
            scale = 10.0
        else if scale <= 0.0:
            scale = 0.25

        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            rotation -= 25.0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            rotation += 25.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rotation = 0.0
            scale = 1.0

        let scale_text = rl.text_format("%.2fx", scale)
        let rotation_text = rl.text_format("%.0f degrees", rotation)
        let fps_text = rl.text_format("%i FPS", rl.get_fps())

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        draw_texture_tiled(
            pattern_texture,
            patterns[active_pattern],
            rl.Rectangle(
                x = float<-OPT_WIDTH + float<-MARGIN_SIZE,
                y = float<-MARGIN_SIZE,
                width = float<-rl.get_screen_width() - float<-OPT_WIDTH - 2.0 * float<-MARGIN_SIZE,
                height = float<-rl.get_screen_height() - 2.0 * float<-MARGIN_SIZE,
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            rotation,
            scale,
            colors[active_color],
        )

        rl.draw_rectangle(
            MARGIN_SIZE,
            MARGIN_SIZE,
            OPT_WIDTH - MARGIN_SIZE,
            rl.get_screen_height() - (2 * MARGIN_SIZE),
            rl.color_alpha(rl.LIGHTGRAY, 0.5),
        )
        rl.draw_text("Select Pattern", 2 + MARGIN_SIZE, 30 + MARGIN_SIZE, 10, rl.BLACK)
        rl.draw_texture(pattern_texture, 2 + MARGIN_SIZE, 40 + MARGIN_SIZE, rl.BLACK)
        rl.draw_rectangle(
            2 + MARGIN_SIZE + int<-patterns[active_pattern].x,
            40 + MARGIN_SIZE + int<-patterns[active_pattern].y,
            int<-patterns[active_pattern].width,
            int<-patterns[active_pattern].height,
            rl.color_alpha(rl.DARKBLUE, 0.3),
        )

        rl.draw_text("Select Color", 2 + MARGIN_SIZE, 10 + 256 + MARGIN_SIZE, 10, rl.BLACK)
        index = 0
        while index < MAX_COLORS:
            rl.draw_rectangle_rec(color_rects[index], colors[index])
            if active_color == index:
                rl.draw_rectangle_lines_ex(color_rects[index], 3.0, rl.color_alpha(rl.WHITE, 0.5))
            index += 1

        rl.draw_text("Scale (UP/DOWN to change)", 2 + MARGIN_SIZE, 80 + 256 + MARGIN_SIZE, 10, rl.BLACK)
        rl.draw_text(scale_text, 2 + MARGIN_SIZE, 92 + 256 + MARGIN_SIZE, 20, rl.BLACK)
        rl.draw_text("Rotation (LEFT/RIGHT to change)", 2 + MARGIN_SIZE, 122 + 256 + MARGIN_SIZE, 10, rl.BLACK)
        rl.draw_text(rotation_text, 2 + MARGIN_SIZE, 134 + 256 + MARGIN_SIZE, 20, rl.BLACK)
        rl.draw_text("Press [SPACE] to reset", 2 + MARGIN_SIZE, 164 + 256 + MARGIN_SIZE, 10, rl.DARKBLUE)
        rl.draw_text(fps_text, 2 + MARGIN_SIZE, 2 + MARGIN_SIZE, 20, rl.BLACK)

        rl.end_drawing()

    return 0
