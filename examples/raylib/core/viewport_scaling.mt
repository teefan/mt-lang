import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const RESOLUTION_COUNT: int = 4
const VIEWPORT_TYPE_COUNT: int = 6

struct ViewportLayout:
    source: rl.Rectangle
    destination: rl.Rectangle


function viewport_type_name(viewport_type: int) -> str:
    if viewport_type == 0:
        return "KEEP_ASPECT_INTEGER"
    if viewport_type == 1:
        return "KEEP_HEIGHT_INTEGER"
    if viewport_type == 2:
        return "KEEP_WIDTH_INTEGER"
    if viewport_type == 3:
        return "KEEP_ASPECT"
    if viewport_type == 4:
        return "KEEP_HEIGHT"

    return "KEEP_WIDTH"


function keep_aspect_centered_integer(
    screen_width: int,
    screen_height: int,
    game_width: int,
    game_height: int
) -> ViewportLayout:
    let ratio_x = screen_width / game_width
    let ratio_y = screen_height / game_height
    let resize_ratio = float<-((if ratio_x < ratio_y: ratio_x else: ratio_y))

    return ViewportLayout(
        source = rl.Rectangle(
            x = 0.0,
            y = float<-game_height,
            width = float<-game_width,
            height = -(float<-game_height)
        ),
        destination = rl.Rectangle(
            x = float<-((screen_width - int<-((float<-game_width) * resize_ratio)) / 2),
            y = float<-((screen_height - int<-((float<-game_height) * resize_ratio)) / 2),
            width = float<-(int<-((float<-game_width) * resize_ratio)),
            height = float<-(int<-((float<-game_height) * resize_ratio))
        )
    )


function keep_height_centered_integer(
    screen_width: int,
    screen_height: int,
    game_width: int,
    game_height: int
) -> ViewportLayout:
    let resize_ratio = (float<-screen_height) / (float<-game_height)
    let source_width = float<-(int<-((float<-screen_width) / resize_ratio))

    return ViewportLayout(
        source = rl.Rectangle(x = 0.0, y = 0.0, width = source_width, height = -(float<-game_height)),
        destination = rl.Rectangle(
            x = float<-((screen_width - int<-(source_width * resize_ratio)) / 2),
            y = float<-((screen_height - int<-((float<-game_height) * resize_ratio)) / 2),
            width = float<-(int<-(source_width * resize_ratio)),
            height = float<-(int<-((float<-game_height) * resize_ratio))
        )
    )


function keep_width_centered_integer(
    screen_width: int,
    screen_height: int,
    game_width: int,
    game_height: int
) -> ViewportLayout:
    let resize_ratio = (float<-screen_width) / (float<-game_width)
    let source_height = float<-(int<-((float<-screen_height) / resize_ratio))

    return ViewportLayout(
        source = rl.Rectangle(x = 0.0, y = 0.0, width = float<-game_width, height = -source_height),
        destination = rl.Rectangle(
            x = float<-((screen_width - int<-((float<-game_width) * resize_ratio)) / 2),
            y = float<-((screen_height - int<-(source_height * resize_ratio)) / 2),
            width = float<-(int<-((float<-game_width) * resize_ratio)),
            height = float<-(int<-(source_height * resize_ratio))
        )
    )


function keep_aspect_centered(
    screen_width: int,
    screen_height: int,
    game_width: int,
    game_height: int
) -> ViewportLayout:
    let ratio_x = (float<-screen_width) / (float<-game_width)
    let ratio_y = (float<-screen_height) / (float<-game_height)
    var resize_ratio = ratio_x
    if ratio_y < resize_ratio:
        resize_ratio = ratio_y

    return ViewportLayout(
        source = rl.Rectangle(
            x = 0.0,
            y = float<-game_height,
            width = float<-game_width,
            height = -(float<-game_height)
        ),
        destination = rl.Rectangle(
            x = float<-((screen_width - int<-((float<-game_width) * resize_ratio)) / 2),
            y = float<-((screen_height - int<-((float<-game_height) * resize_ratio)) / 2),
            width = float<-(int<-((float<-game_width) * resize_ratio)),
            height = float<-(int<-((float<-game_height) * resize_ratio))
        )
    )


function keep_height_centered(
    screen_width: int,
    screen_height: int,
    game_width: int,
    game_height: int
) -> ViewportLayout:
    let resize_ratio = (float<-screen_height) / (float<-game_height)
    let source_width = float<-(int<-((float<-screen_width) / resize_ratio))

    return ViewportLayout(
        source = rl.Rectangle(x = 0.0, y = 0.0, width = source_width, height = -(float<-game_height)),
        destination = rl.Rectangle(
            x = float<-((screen_width - int<-(source_width * resize_ratio)) / 2),
            y = float<-((screen_height - int<-((float<-game_height) * resize_ratio)) / 2),
            width = float<-(int<-(source_width * resize_ratio)),
            height = float<-(int<-((float<-game_height) * resize_ratio))
        )
    )


function keep_width_centered(
    screen_width: int,
    screen_height: int,
    game_width: int,
    game_height: int
) -> ViewportLayout:
    let resize_ratio = (float<-screen_width) / (float<-game_width)
    let source_height = float<-(int<-((float<-screen_height) / resize_ratio))

    return ViewportLayout(
        source = rl.Rectangle(x = 0.0, y = 0.0, width = float<-game_width, height = -source_height),
        destination = rl.Rectangle(
            x = float<-((screen_width - int<-((float<-game_width) * resize_ratio)) / 2),
            y = float<-((screen_height - int<-(source_height * resize_ratio)) / 2),
            width = float<-(int<-((float<-game_width) * resize_ratio)),
            height = float<-(int<-(source_height * resize_ratio))
        )
    )


function resize_render_size(
    viewport_type: int,
    game_width: int,
    game_height: int,
    target: ref[rl.RenderTexture2D]
) -> ViewportLayout:
    let screen_width = rl.get_screen_width()
    let screen_height = rl.get_screen_height()

    var layout = keep_aspect_centered_integer(screen_width, screen_height, game_width, game_height)
    if viewport_type == 1:
        layout = keep_height_centered_integer(screen_width, screen_height, game_width, game_height)
    else if viewport_type == 2:
        layout = keep_width_centered_integer(screen_width, screen_height, game_width, game_height)
    else if viewport_type == 3:
        layout = keep_aspect_centered(screen_width, screen_height, game_width, game_height)
    else if viewport_type == 4:
        layout = keep_height_centered(screen_width, screen_height, game_width, game_height)
    else if viewport_type == 5:
        layout = keep_width_centered(screen_width, screen_height, game_width, game_height)

    unsafe:
        if read(target).id != 0:
            rl.unload_render_texture(read(target))

        let next_target = rl.load_render_texture(int<-layout.source.width, -(int<-layout.source.height))
        read(target) = next_target

    return layout


function screen_to_render_texture_position(point: rl.Vector2, layout: ViewportLayout) -> rl.Vector2:
    let relative_position = rl.Vector2(x = point.x - layout.destination.x, y = point.y - layout.destination.y)
    let ratio = rl.Vector2(
        x = layout.source.width / layout.destination.width,
        y = -(layout.source.height) / layout.destination.height
    )
    return rl.Vector2(x = relative_position.x * ratio.x, y = relative_position.y * ratio.x)


function unload_render_texture_if_loaded(target: ref[rl.RenderTexture2D]) -> void:
    unsafe:
        if read(target).id != 0:
            rl.unload_render_texture(read(target))


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - viewport scaling")
    defer rl.close_window()

    let resolution_list = array[rl.Vector2, 4](
        rl.Vector2(x = 64.0, y = 64.0),
        rl.Vector2(x = 256.0, y = 240.0),
        rl.Vector2(x = 320.0, y = 180.0),
        rl.Vector2(x = 3840.0, y = 2160.0)
    )

    var resolution_index = 0
    var game_width = 64
    var game_height = 64
    var target = zero[rl.RenderTexture2D]
    defer unload_render_texture_if_loaded(ref_of(target))
    var viewport_type = 0
    var layout = resize_render_size(viewport_type, game_width, game_height, ref_of(target))

    let decrease_resolution_button = rl.Rectangle(x = 200.0, y = 30.0, width = 10.0, height = 10.0)
    let increase_resolution_button = rl.Rectangle(x = 215.0, y = 30.0, width = 10.0, height = 10.0)
    let decrease_type_button = rl.Rectangle(x = 200.0, y = 45.0, width = 10.0, height = 10.0)
    let increase_type_button = rl.Rectangle(x = 215.0, y = 45.0, width = 10.0, height = 10.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_window_resized():
            layout = resize_render_size(viewport_type, game_width, game_height, ref_of(target))

        let mouse_position = rl.get_mouse_position()
        let mouse_pressed = rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT)

        if rl.check_collision_point_rec(mouse_position, decrease_resolution_button) and mouse_pressed:
            resolution_index = (resolution_index + RESOLUTION_COUNT - 1) % RESOLUTION_COUNT
            game_width = int<-resolution_list[resolution_index].x
            game_height = int<-resolution_list[resolution_index].y
            layout = resize_render_size(viewport_type, game_width, game_height, ref_of(target))

        if rl.check_collision_point_rec(mouse_position, increase_resolution_button) and mouse_pressed:
            resolution_index = (resolution_index + 1) % RESOLUTION_COUNT
            game_width = int<-resolution_list[resolution_index].x
            game_height = int<-resolution_list[resolution_index].y
            layout = resize_render_size(viewport_type, game_width, game_height, ref_of(target))

        if rl.check_collision_point_rec(mouse_position, decrease_type_button) and mouse_pressed:
            viewport_type = (viewport_type + VIEWPORT_TYPE_COUNT - 1) % VIEWPORT_TYPE_COUNT
            layout = resize_render_size(viewport_type, game_width, game_height, ref_of(target))

        if rl.check_collision_point_rec(mouse_position, increase_type_button) and mouse_pressed:
            viewport_type = (viewport_type + 1) % VIEWPORT_TYPE_COUNT
            layout = resize_render_size(viewport_type, game_width, game_height, ref_of(target))

        let texture_mouse_position = screen_to_render_texture_position(mouse_position, layout)

        rl.begin_texture_mode(target)
        rl.clear_background(rl.WHITE)
        rl.draw_circle_v(texture_mouse_position, 20.0, rl.LIME)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)

        rl.draw_texture_pro(
            target.texture,
            layout.source,
            layout.destination,
            rl.Vector2(x = 0.0, y = 0.0),
            0.0,
            rl.WHITE
        )

        let info_rect = rl.Rectangle(x = 5.0, y = 5.0, width = 330.0, height = 105.0)
        rl.draw_rectangle_rec(info_rect, rl.fade(rl.LIGHTGRAY, 0.7))
        rl.draw_rectangle_lines_ex(info_rect, 1.0, rl.BLUE)

        rl.draw_text(f"Window Resolution: #{rl.get_screen_width()} x #{rl.get_screen_height()}", 15, 15, 10, rl.BLACK)
        rl.draw_text(f"Game Resolution: #{game_width} x #{game_height}", 15, 30, 10, rl.BLACK)
        rl.draw_text(f"Type: #{viewport_type_name(viewport_type)}", 15, 45, 10, rl.BLACK)

        let scale_ratio = rl.Vector2(
            x = layout.destination.width / layout.source.width,
            y = -layout.destination.height / layout.source.height
        )
        if scale_ratio.x < 0.001 or scale_ratio.y < 0.001:
            rl.draw_text("Scale ratio: INVALID", 15, 60, 10, rl.BLACK)
        else:
            rl.draw_text(f"Scale ratio: #{scale_ratio.x} x #{scale_ratio.y}", 15, 60, 10, rl.BLACK)

        rl.draw_text(f"Source size: #{layout.source.width} x #{-layout.source.height}", 15, 75, 10, rl.BLACK)
        rl.draw_text(
            f"Destination size: #{layout.destination.width} x #{layout.destination.height}",
            15,
            90,
            10,
            rl.BLACK
        )

        rl.draw_rectangle_rec(decrease_type_button, rl.SKYBLUE)
        rl.draw_rectangle_rec(increase_type_button, rl.SKYBLUE)
        rl.draw_rectangle_rec(decrease_resolution_button, rl.SKYBLUE)
        rl.draw_rectangle_rec(increase_resolution_button, rl.SKYBLUE)
        rl.draw_text("<", int<-decrease_type_button.x + 3, int<-decrease_type_button.y + 1, 10, rl.BLACK)
        rl.draw_text(">", int<-increase_type_button.x + 3, int<-increase_type_button.y + 1, 10, rl.BLACK)
        rl.draw_text("<", int<-decrease_resolution_button.x + 3, int<-decrease_resolution_button.y + 1, 10, rl.BLACK)
        rl.draw_text(">", int<-increase_resolution_button.x + 3, int<-increase_resolution_button.y + 1, 10, rl.BLACK)

        rl.end_drawing()

    return 0
