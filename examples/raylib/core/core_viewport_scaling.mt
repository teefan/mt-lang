module examples.raylib.core.core_viewport_scaling

import std.c.raylib as rl

const screen_width_default: i32 = 800
const screen_height_default: i32 = 450
const resolution_count: i32 = 4
const viewport_type_count: i32 = 6
const window_title: cstr = c"raylib [core] example - viewport scaling"

enum ViewportType: i32
    KEEP_ASPECT_INTEGER = 0
    KEEP_HEIGHT_INTEGER = 1
    KEEP_WIDTH_INTEGER = 2
    KEEP_ASPECT = 3
    KEEP_HEIGHT = 4
    KEEP_WIDTH = 5

def viewport_type_name(viewport_type: ViewportType) -> cstr:
    if viewport_type == ViewportType.KEEP_ASPECT_INTEGER:
        return c"KEEP_ASPECT_INTEGER"
    if viewport_type == ViewportType.KEEP_HEIGHT_INTEGER:
        return c"KEEP_HEIGHT_INTEGER"
    if viewport_type == ViewportType.KEEP_WIDTH_INTEGER:
        return c"KEEP_WIDTH_INTEGER"
    if viewport_type == ViewportType.KEEP_ASPECT:
        return c"KEEP_ASPECT"
    if viewport_type == ViewportType.KEEP_HEIGHT:
        return c"KEEP_HEIGHT"
    return c"KEEP_WIDTH"

def keep_aspect_centered_integer(screen_width: i32, screen_height: i32, game_width: i32, game_height: i32, source_rect: ref[rl.Rectangle], dest_rect: ref[rl.Rectangle]) -> void:
    var source = value(source_rect)
    source.x = 0.0
    source.y = game_height
    source.width = game_width
    source.height = -game_height
    value(source_rect) = source

    let ratio_x = screen_width / game_width
    let ratio_y = screen_height / game_height
    let resize_ratio = if ratio_x < ratio_y then ratio_x else ratio_y

    var dest = value(dest_rect)
    dest.x = cast[f32](cast[i32]((screen_width - game_width * resize_ratio) * 0.5))
    dest.y = cast[f32](cast[i32]((screen_height - game_height * resize_ratio) * 0.5))
    dest.width = cast[f32](game_width * resize_ratio)
    dest.height = cast[f32](game_height * resize_ratio)
    value(dest_rect) = dest
    return

def keep_height_centered_integer(screen_width: i32, screen_height: i32, game_width: i32, game_height: i32, source_rect: ref[rl.Rectangle], dest_rect: ref[rl.Rectangle]) -> void:
    let resize_ratio: f32 = cast[f32](screen_height) / game_height

    var source = value(source_rect)
    source.x = 0.0
    source.y = 0.0
    source.width = cast[f32](cast[i32](screen_width / resize_ratio))
    source.height = -game_height
    value(source_rect) = source

    var dest = value(dest_rect)
    dest.x = cast[f32](cast[i32]((screen_width - source.width * resize_ratio) * 0.5))
    dest.y = cast[f32](cast[i32]((screen_height - game_height * resize_ratio) * 0.5))
    dest.width = cast[f32](cast[i32](source.width * resize_ratio))
    dest.height = cast[f32](cast[i32](game_height * resize_ratio))
    value(dest_rect) = dest
    return

def keep_width_centered_integer(screen_width: i32, screen_height: i32, game_width: i32, game_height: i32, source_rect: ref[rl.Rectangle], dest_rect: ref[rl.Rectangle]) -> void:
    let resize_ratio: f32 = cast[f32](screen_width) / game_width

    var source = value(source_rect)
    source.x = 0.0
    source.y = 0.0
    source.width = game_width
    source.height = cast[f32](cast[i32](screen_height / resize_ratio))
    value(source_rect) = source

    var dest = value(dest_rect)
    dest.x = cast[f32](cast[i32]((screen_width - game_width * resize_ratio) * 0.5))
    dest.y = cast[f32](cast[i32]((screen_height - source.height * resize_ratio) * 0.5))
    dest.width = cast[f32](cast[i32](game_width * resize_ratio))
    dest.height = cast[f32](cast[i32](source.height * resize_ratio))
    value(dest_rect) = dest

    source = value(source_rect)
    source.height *= -1.0
    value(source_rect) = source
    return

def keep_aspect_centered(screen_width: i32, screen_height: i32, game_width: i32, game_height: i32, source_rect: ref[rl.Rectangle], dest_rect: ref[rl.Rectangle]) -> void:
    var source = value(source_rect)
    source.x = 0.0
    source.y = game_height
    source.width = game_width
    source.height = -game_height
    value(source_rect) = source

    let ratio_x: f32 = cast[f32](screen_width) / game_width
    let ratio_y: f32 = cast[f32](screen_height) / game_height
    let resize_ratio = if ratio_x < ratio_y then ratio_x else ratio_y

    var dest = value(dest_rect)
    dest.x = cast[f32](cast[i32]((screen_width - game_width * resize_ratio) * 0.5))
    dest.y = cast[f32](cast[i32]((screen_height - game_height * resize_ratio) * 0.5))
    dest.width = cast[f32](cast[i32](game_width * resize_ratio))
    dest.height = cast[f32](cast[i32](game_height * resize_ratio))
    value(dest_rect) = dest
    return

def keep_height_centered(screen_width: i32, screen_height: i32, game_width: i32, game_height: i32, source_rect: ref[rl.Rectangle], dest_rect: ref[rl.Rectangle]) -> void:
    let resize_ratio: f32 = cast[f32](screen_height) / game_height

    var source = value(source_rect)
    source.x = 0.0
    source.y = 0.0
    source.width = cast[f32](cast[i32](cast[f32](screen_width) / resize_ratio))
    source.height = -game_height
    value(source_rect) = source

    var dest = value(dest_rect)
    dest.x = cast[f32](cast[i32]((screen_width - source.width * resize_ratio) * 0.5))
    dest.y = cast[f32](cast[i32]((screen_height - game_height * resize_ratio) * 0.5))
    dest.width = cast[f32](cast[i32](source.width * resize_ratio))
    dest.height = cast[f32](cast[i32](game_height * resize_ratio))
    value(dest_rect) = dest
    return

def keep_width_centered(screen_width: i32, screen_height: i32, game_width: i32, game_height: i32, source_rect: ref[rl.Rectangle], dest_rect: ref[rl.Rectangle]) -> void:
    let resize_ratio: f32 = cast[f32](screen_width) / game_width

    var source = value(source_rect)
    source.x = 0.0
    source.y = 0.0
    source.width = game_width
    source.height = cast[f32](cast[i32](cast[f32](screen_height) / resize_ratio))
    value(source_rect) = source

    var dest = value(dest_rect)
    dest.x = cast[f32](cast[i32]((screen_width - game_width * resize_ratio) * 0.5))
    dest.y = cast[f32](cast[i32]((screen_height - source.height * resize_ratio) * 0.5))
    dest.width = cast[f32](cast[i32](game_width * resize_ratio))
    dest.height = cast[f32](cast[i32](source.height * resize_ratio))
    value(dest_rect) = dest

    source = value(source_rect)
    source.height *= -1.0
    value(source_rect) = source
    return

def resize_render_size(viewport_type: ViewportType, screen_width: ref[i32], screen_height: ref[i32], game_width: i32, game_height: i32, source_rect: ref[rl.Rectangle], dest_rect: ref[rl.Rectangle], target: ref[rl.RenderTexture2D]) -> void:
    value(screen_width) = rl.GetScreenWidth()
    value(screen_height) = rl.GetScreenHeight()

    if viewport_type == ViewportType.KEEP_ASPECT_INTEGER:
        keep_aspect_centered_integer(value(screen_width), value(screen_height), game_width, game_height, source_rect, dest_rect)
    elif viewport_type == ViewportType.KEEP_HEIGHT_INTEGER:
        keep_height_centered_integer(value(screen_width), value(screen_height), game_width, game_height, source_rect, dest_rect)
    elif viewport_type == ViewportType.KEEP_WIDTH_INTEGER:
        keep_width_centered_integer(value(screen_width), value(screen_height), game_width, game_height, source_rect, dest_rect)
    elif viewport_type == ViewportType.KEEP_ASPECT:
        keep_aspect_centered(value(screen_width), value(screen_height), game_width, game_height, source_rect, dest_rect)
    elif viewport_type == ViewportType.KEEP_HEIGHT:
        keep_height_centered(value(screen_width), value(screen_height), game_width, game_height, source_rect, dest_rect)
    else:
        keep_width_centered(value(screen_width), value(screen_height), game_width, game_height, source_rect, dest_rect)

    let current_target = value(target)
    if current_target.id != 0:
        rl.UnloadRenderTexture(current_target)
    value(target) = rl.LoadRenderTexture(cast[i32](value(source_rect).width), -cast[i32](value(source_rect).height))
    return

def screen_to_render_texture_position(point: rl.Vector2, texture_rect: rl.Rectangle, scaled_rect: rl.Rectangle) -> rl.Vector2:
    let relative_position = rl.Vector2(
        x = point.x - scaled_rect.x,
        y = point.y - scaled_rect.y,
    )
    let ratio = rl.Vector2(
        x = texture_rect.width / scaled_rect.width,
        y = -texture_rect.height / scaled_rect.height,
    )
    return rl.Vector2(
        x = relative_position.x * ratio.x,
        y = relative_position.y * ratio.x,
    )

def main() -> i32:
    var screen_width = screen_width_default
    var screen_height = screen_height_default

    rl.SetConfigFlags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let resolution_list = array[rl.Vector2, 4](
        rl.Vector2(x = 64.0, y = 64.0),
        rl.Vector2(x = 256.0, y = 240.0),
        rl.Vector2(x = 320.0, y = 180.0),
        rl.Vector2(x = 3840.0, y = 2160.0),
    )

    var resolution_index = 0
    var game_width = 64
    var game_height = 64

    var target = zero[rl.RenderTexture2D]()
    var source_rect = zero[rl.Rectangle]()
    var dest_rect = zero[rl.Rectangle]()

    var viewport_type = ViewportType.KEEP_ASPECT_INTEGER
    resize_render_size(viewport_type, addr(screen_width), addr(screen_height), game_width, game_height, addr(source_rect), addr(dest_rect), addr(target))

    let decrease_resolution_button = rl.Rectangle(x = 200.0, y = 30.0, width = 10.0, height = 10.0)
    let increase_resolution_button = rl.Rectangle(x = 215.0, y = 30.0, width = 10.0, height = 10.0)
    let decrease_type_button = rl.Rectangle(x = 200.0, y = 45.0, width = 10.0, height = 10.0)
    let increase_type_button = rl.Rectangle(x = 215.0, y = 45.0, width = 10.0, height = 10.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsWindowResized():
            resize_render_size(viewport_type, addr(screen_width), addr(screen_height), game_width, game_height, addr(source_rect), addr(dest_rect), addr(target))

        let mouse_position = rl.GetMousePosition()
        let mouse_pressed = rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT)

        if rl.CheckCollisionPointRec(mouse_position, decrease_resolution_button) and mouse_pressed:
            resolution_index = (resolution_index + resolution_count - 1) % resolution_count
            game_width = cast[i32](resolution_list[resolution_index].x)
            game_height = cast[i32](resolution_list[resolution_index].y)
            resize_render_size(viewport_type, addr(screen_width), addr(screen_height), game_width, game_height, addr(source_rect), addr(dest_rect), addr(target))

        if rl.CheckCollisionPointRec(mouse_position, increase_resolution_button) and mouse_pressed:
            resolution_index = (resolution_index + 1) % resolution_count
            game_width = cast[i32](resolution_list[resolution_index].x)
            game_height = cast[i32](resolution_list[resolution_index].y)
            resize_render_size(viewport_type, addr(screen_width), addr(screen_height), game_width, game_height, addr(source_rect), addr(dest_rect), addr(target))

        if rl.CheckCollisionPointRec(mouse_position, decrease_type_button) and mouse_pressed:
            viewport_type = cast[ViewportType]((cast[i32](viewport_type) + viewport_type_count - 1) % viewport_type_count)
            resize_render_size(viewport_type, addr(screen_width), addr(screen_height), game_width, game_height, addr(source_rect), addr(dest_rect), addr(target))

        if rl.CheckCollisionPointRec(mouse_position, increase_type_button) and mouse_pressed:
            viewport_type = cast[ViewportType]((cast[i32](viewport_type) + 1) % viewport_type_count)
            resize_render_size(viewport_type, addr(screen_width), addr(screen_height), game_width, game_height, addr(source_rect), addr(dest_rect), addr(target))

        let texture_mouse_position = screen_to_render_texture_position(mouse_position, source_rect, dest_rect)

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.WHITE)
        rl.DrawCircleV(texture_mouse_position, 20.0, rl.LIME)
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)
        rl.DrawTexturePro(target.texture, source_rect, dest_rect, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)

        let info_rect = rl.Rectangle(x = 5.0, y = 5.0, width = 330.0, height = 105.0)
        rl.DrawRectangleRec(info_rect, rl.Fade(rl.LIGHTGRAY, 0.7))
        rl.DrawRectangleLinesEx(info_rect, 1.0, rl.BLUE)

        rl.DrawText(rl.TextFormat(c"Window Resolution: %d x %d", screen_width, screen_height), 15, 15, 10, rl.BLACK)
        rl.DrawText(rl.TextFormat(c"Game Resolution: %d x %d", game_width, game_height), 15, 30, 10, rl.BLACK)
        rl.DrawText(rl.TextFormat(c"Type: %s", viewport_type_name(viewport_type)), 15, 45, 10, rl.BLACK)

        let scale_ratio = rl.Vector2(
            x = dest_rect.width / source_rect.width,
            y = -dest_rect.height / source_rect.height,
        )
        if scale_ratio.x < 0.001 or scale_ratio.y < 0.001:
            rl.DrawText(rl.TextFormat(c"Scale ratio: INVALID"), 15, 60, 10, rl.BLACK)
        else:
            rl.DrawText(rl.TextFormat(c"Scale ratio: %.2f x %.2f", scale_ratio.x, scale_ratio.y), 15, 60, 10, rl.BLACK)

        rl.DrawText(rl.TextFormat(c"Source size: %.2f x %.2f", source_rect.width, -source_rect.height), 15, 75, 10, rl.BLACK)
        rl.DrawText(rl.TextFormat(c"Destination size: %.2f x %.2f", dest_rect.width, dest_rect.height), 15, 90, 10, rl.BLACK)

        rl.DrawRectangleRec(decrease_type_button, rl.SKYBLUE)
        rl.DrawRectangleRec(increase_type_button, rl.SKYBLUE)
        rl.DrawRectangleRec(decrease_resolution_button, rl.SKYBLUE)
        rl.DrawRectangleRec(increase_resolution_button, rl.SKYBLUE)
        rl.DrawText(c"<", cast[i32](decrease_type_button.x) + 3, cast[i32](decrease_type_button.y) + 1, 10, rl.BLACK)
        rl.DrawText(c">", cast[i32](increase_type_button.x) + 3, cast[i32](increase_type_button.y) + 1, 10, rl.BLACK)
        rl.DrawText(c"<", cast[i32](decrease_resolution_button.x) + 3, cast[i32](decrease_resolution_button.y) + 1, 10, rl.BLACK)
        rl.DrawText(c">", cast[i32](increase_resolution_button.x) + 3, cast[i32](increase_resolution_button.y) + 1, 10, rl.BLACK)

    if target.id != 0:
        rl.UnloadRenderTexture(target)
    return 0
