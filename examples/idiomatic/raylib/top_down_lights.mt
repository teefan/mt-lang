module examples.idiomatic.raylib.top_down_lights

import std.raylib as rl
import std.raylib.math as math
import std.rlgl as rlgl

const max_boxes: int = 20
const max_shadows: int = max_boxes * 3
const max_lights: int = 16
const screen_width: int = 800
const screen_height: int = 450

struct ShadowGeometry:
    vertices: array[rl.Vector2, 4]

struct LightInfo:
    active: bool
    dirty: bool
    valid: bool
    position: rl.Vector2
    mask: rl.RenderTexture
    outer_radius: float
    bounds: rl.Rectangle
    shadows: array[ShadowGeometry, 60]
    shadow_count: int


def move_light(light: LightInfo, x: float, y: float) -> LightInfo:
    var current = light
    current.dirty = true
    current.position.x = x
    current.position.y = y
    current.bounds.x = x - current.outer_radius
    current.bounds.y = y - current.outer_radius
    return current


def push_shadow(light: LightInfo, v0: rl.Vector2, v1: rl.Vector2, v2: rl.Vector2, v3: rl.Vector2) -> LightInfo:
    var current = light
    if current.shadow_count >= max_shadows:
        return current

    current.shadows[current.shadow_count].vertices[0] = v0
    current.shadows[current.shadow_count].vertices[1] = v1
    current.shadows[current.shadow_count].vertices[2] = v2
    current.shadows[current.shadow_count].vertices[3] = v3
    current.shadow_count += 1
    return current


def compute_shadow_volume_for_edge(light: LightInfo, start_point: rl.Vector2, end_point: rl.Vector2) -> LightInfo:
    let extension = light.outer_radius * 2.0
    let start_vector = start_point.subtract(light.position).normalize()
    let start_projection = start_point.add(start_vector.scale(extension))
    let end_vector = end_point.subtract(light.position).normalize()
    let end_projection = end_point.add(end_vector.scale(extension))
    return push_shadow(light, start_point, end_point, end_projection, start_projection)


def draw_shadow(shadow: ShadowGeometry, color: rl.Color) -> void:
    rl.draw_triangle(shadow.vertices[0], shadow.vertices[1], shadow.vertices[2], color)
    rl.draw_triangle(shadow.vertices[0], shadow.vertices[2], shadow.vertices[3], color)


def draw_light_mask(light: LightInfo) -> void:
    rl.begin_texture_mode(light.mask)
    rl.clear_background(rl.WHITE)

    rlgl.set_blend_factors(rlgl.RL_SRC_ALPHA, rlgl.RL_SRC_ALPHA, rlgl.RL_MIN)
    rlgl.set_blend_mode(rl.BlendMode.BLEND_CUSTOM)

    if light.valid:
        rl.draw_circle_gradient(light.position, light.outer_radius, rl.color_alpha(rl.WHITE, 0.0), rl.WHITE)

    rlgl.draw_render_batch_active()

    rlgl.set_blend_mode(rl.BlendMode.BLEND_ALPHA)
    rlgl.set_blend_factors(rlgl.RL_SRC_ALPHA, rlgl.RL_SRC_ALPHA, rlgl.RL_MAX)
    rlgl.set_blend_mode(rl.BlendMode.BLEND_CUSTOM)

    for index in 0..light.shadow_count:
        draw_shadow(light.shadows[index], rl.WHITE)

    rlgl.draw_render_batch_active()
    rlgl.set_blend_mode(rl.BlendMode.BLEND_ALPHA)
    rl.end_texture_mode()


def move_light_slot(lights: ref[array[LightInfo, 16]], slot: int, x: float, y: float) -> void:
    read(lights)[slot] = move_light(read(lights)[slot], x, y)


def setup_light(lights: ref[array[LightInfo, 16]], slot: int, x: float, y: float, radius: float) -> void:
    var light = read(lights)[slot]
    light.active = true
    light.valid = false
    light.mask = rl.load_render_texture(rl.get_screen_width(), rl.get_screen_height())
    light.outer_radius = radius
    light.bounds.width = radius * 2.0
    light.bounds.height = radius * 2.0
    light = move_light(light, x, y)
    read(lights)[slot] = light
    draw_light_mask(light)


def update_light(lights: ref[array[LightInfo, 16]], slot: int, boxes: array[rl.Rectangle, 20], count: int) -> bool:
    var light = read(lights)[slot]

    if not light.active or not light.dirty:
        return false

    light.dirty = false
    light.shadow_count = 0
    light.valid = false

    for index in 0..count:
        let box = boxes[index]

        if rl.check_collision_point_rec(light.position, box):
            read(lights)[slot] = light
            return false

        if not rl.check_collision_recs(light.bounds, box):
            continue

        let top_left = rl.Vector2(x = box.x, y = box.y)
        let top_right = rl.Vector2(x = box.x + box.width, y = box.y)
        let bottom_right = rl.Vector2(x = box.x + box.width, y = box.y + box.height)
        let bottom_left = rl.Vector2(x = box.x, y = box.y + box.height)

        if light.position.y > top_right.y:
            light = compute_shadow_volume_for_edge(light, top_left, top_right)

        if light.position.x < top_right.x:
            light = compute_shadow_volume_for_edge(light, top_right, bottom_right)

        if light.position.y < bottom_right.y:
            light = compute_shadow_volume_for_edge(light, bottom_right, bottom_left)

        if light.position.x > bottom_left.x:
            light = compute_shadow_volume_for_edge(light, bottom_left, top_left)

        light = push_shadow(light, top_left, bottom_left, bottom_right, top_right)

    light.valid = true
    read(lights)[slot] = light
    draw_light_mask(light)
    return true


def setup_boxes(boxes: ref[array[rl.Rectangle, 20]], count: ref[int]) -> void:
    read(boxes)[0] = rl.Rectangle(x = 150.0, y = 80.0, width = 40.0, height = 40.0)
    read(boxes)[1] = rl.Rectangle(x = 1200.0, y = 700.0, width = 40.0, height = 40.0)
    read(boxes)[2] = rl.Rectangle(x = 200.0, y = 600.0, width = 40.0, height = 40.0)
    read(boxes)[3] = rl.Rectangle(x = 1000.0, y = 50.0, width = 40.0, height = 40.0)
    read(boxes)[4] = rl.Rectangle(x = 500.0, y = 350.0, width = 40.0, height = 40.0)

    for index in 5..max_boxes:
        read(boxes)[index] = rl.Rectangle(
            x = float<-rl.get_random_value(0, rl.get_screen_width()),
            y = float<-rl.get_random_value(0, rl.get_screen_height()),
            width = float<-rl.get_random_value(10, 100),
            height = float<-rl.get_random_value(10, 100),
        )

    read(count) = max_boxes


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Top-Down Lights")
    defer rl.close_window()

    var box_count: int = 0
    var boxes = zero[array[rl.Rectangle, 20]]
    setup_boxes(ref_of(boxes), ref_of(box_count))

    let image = rl.gen_image_checked(64, 64, 32, 32, rl.DARKBROWN, rl.DARKGRAY)
    let background_texture = rl.load_texture_from_image(image)
    defer rl.unload_texture(background_texture)
    rl.unload_image(image)

    let light_mask = rl.load_render_texture(rl.get_screen_width(), rl.get_screen_height())
    defer rl.unload_render_texture(light_mask)

    var lights = zero[array[LightInfo, 16]]
    setup_light(ref_of(lights), 0, 600.0, 400.0, 300.0)
    var next_light = 1
    var show_lines = false

    let screen_rect = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-rl.get_screen_width(),
        height = float<-rl.get_screen_height(),
    )
    let flipped_screen_rect = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-rl.get_screen_width(),
        height = -float<-rl.get_screen_height(),
    )
    let origin = rl.Vector2(x = 0.0, y = 0.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let mouse_position = rl.get_mouse_position()
            move_light_slot(ref_of(lights), 0, mouse_position.x, mouse_position.y)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT) and next_light < max_lights:
            let mouse_position = rl.get_mouse_position()
            setup_light(ref_of(lights), next_light, mouse_position.x, mouse_position.y, 200.0)
            next_light += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_F1):
            show_lines = not show_lines

        var dirty_lights = false
        for index in 0..max_lights:
            if update_light(ref_of(lights), index, boxes, box_count):
                dirty_lights = true

        if dirty_lights:
            rl.begin_texture_mode(light_mask)
            rl.clear_background(rl.BLACK)

            rlgl.set_blend_factors(rlgl.RL_SRC_ALPHA, rlgl.RL_SRC_ALPHA, rlgl.RL_MIN)
            rlgl.set_blend_mode(rl.BlendMode.BLEND_CUSTOM)

            for index in 0..max_lights:
                if lights[index].active:
                    rl.draw_texture_rec(lights[index].mask.texture, flipped_screen_rect, origin, rl.WHITE)

            rlgl.draw_render_batch_active()
            rlgl.set_blend_mode(rl.BlendMode.BLEND_ALPHA)
            rl.end_texture_mode()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.BLACK)
        rl.draw_texture_rec(background_texture, screen_rect, origin, rl.WHITE)

        var overlay_alpha: float = 1.0
        if show_lines:
            overlay_alpha = 0.75

        rl.draw_texture_rec(light_mask.texture, flipped_screen_rect, origin, rl.color_alpha(rl.WHITE, overlay_alpha))

        for index in 0..max_lights:
            if lights[index].active:
                var light_color = rl.WHITE
                if index == 0:
                    light_color = rl.YELLOW
                rl.draw_circle(int<-lights[index].position.x, int<-lights[index].position.y, 10.0, light_color)

        if show_lines:
            for index in 0..lights[0].shadow_count:
                draw_shadow(lights[0].shadows[index], rl.DARKPURPLE)

            for index in 0..box_count:
                if rl.check_collision_recs(boxes[index], lights[0].bounds):
                    rl.draw_rectangle_rec(boxes[index], rl.PURPLE)

                rl.draw_rectangle_lines(
                    int<-boxes[index].x,
                    int<-boxes[index].y,
                    int<-boxes[index].width,
                    int<-boxes[index].height,
                    rl.DARKBLUE,
                )

            rl.draw_text("(F1) Hide Shadow Volumes", 10, 50, 10, rl.GREEN)
        else:
            rl.draw_text("(F1) Show Shadow Volumes", 10, 50, 10, rl.GREEN)

        rl.draw_fps(screen_width - 80, 10)
        rl.draw_text("Drag to move light #1", 10, 10, 10, rl.DARKGREEN)
        rl.draw_text("Right click to add new light", 10, 30, 10, rl.DARKGREEN)

    for index in 0..max_lights:
        if lights[index].active:
            rl.unload_render_texture(lights[index].mask)

    return 0
