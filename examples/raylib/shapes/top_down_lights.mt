import std.raylib as rl
import std.raymath as rm
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const RLGL_SRC_ALPHA: int = 0x0302
const RLGL_MIN: int = 0x8007
const RLGL_MAX: int = 0x8008
const MAX_BOXES: int = 20
const MAX_SHADOWS: int = MAX_BOXES * 3
const MAX_LIGHTS: int = 16

struct ShadowGeometry:
    vertices: array[rl.Vector2, 4]

struct LightInfo:
    active: bool
    dirty: bool
    valid: bool
    position: rl.Vector2
    mask: rl.RenderTexture2D
    outer_radius: float
    bounds: rl.Rectangle
    shadows: array[ShadowGeometry, 60]
    shadow_count: int

var lights: array[LightInfo, MAX_LIGHTS] = zero[array[LightInfo, MAX_LIGHTS]]
var boxes: array[rl.Rectangle, MAX_BOXES] = zero[array[rl.Rectangle, MAX_BOXES]]
var box_count: int = 0


function move_light(slot: int, x: float, y: float) -> void:
    lights[slot].dirty = true
    lights[slot].position.x = x
    lights[slot].position.y = y
    lights[slot].bounds.x = x - lights[slot].outer_radius
    lights[slot].bounds.y = y - lights[slot].outer_radius


function compute_shadow_volume_for_edge(slot: int, sp: rl.Vector2, ep: rl.Vector2) -> void:
    if lights[slot].shadow_count >= MAX_SHADOWS:
        return

    let extension = lights[slot].outer_radius * 2.0
    let sp_vector = rm.vector2_normalize(rm.vector2_subtract(sp, lights[slot].position))
    let sp_projection = rm.vector2_add(sp, rm.vector2_scale(sp_vector, extension))
    let ep_vector = rm.vector2_normalize(rm.vector2_subtract(ep, lights[slot].position))
    let ep_projection = rm.vector2_add(ep, rm.vector2_scale(ep_vector, extension))

    lights[slot].shadows[lights[slot].shadow_count].vertices[0] = sp
    lights[slot].shadows[lights[slot].shadow_count].vertices[1] = ep
    lights[slot].shadows[lights[slot].shadow_count].vertices[2] = ep_projection
    lights[slot].shadows[lights[slot].shadow_count].vertices[3] = sp_projection
    lights[slot].shadow_count += 1


function draw_light_mask(slot: int) -> void:
    rl.begin_texture_mode(lights[slot].mask)
    rl.clear_background(rl.WHITE)

    rlgl.set_blend_factors(RLGL_SRC_ALPHA, RLGL_SRC_ALPHA, RLGL_MIN)
    rlgl.set_blend_mode(int<-rl.BlendMode.BLEND_CUSTOM)

    if lights[slot].valid:
        rl.draw_circle_gradient(
            lights[slot].position,
            lights[slot].outer_radius,
            rl.color_alpha(rl.WHITE, 0.0),
            rl.WHITE
        )

    rlgl.draw_render_batch_active()

    rlgl.set_blend_mode(int<-rl.BlendMode.BLEND_ALPHA)
    rlgl.set_blend_factors(RLGL_SRC_ALPHA, RLGL_SRC_ALPHA, RLGL_MAX)
    rlgl.set_blend_mode(int<-rl.BlendMode.BLEND_CUSTOM)

    var index = 0
    while index < lights[slot].shadow_count:
        rl.draw_triangle_fan_ptr(ptr_of(lights[slot].shadows[index].vertices[0]), 4, rl.WHITE)
        index += 1

    rlgl.draw_render_batch_active()
    rlgl.set_blend_mode(int<-rl.BlendMode.BLEND_ALPHA)
    rl.end_texture_mode()


function setup_light(slot: int, x: float, y: float, radius: float) -> void:
    lights[slot].active = true
    lights[slot].valid = false
    lights[slot].mask = rl.load_render_texture(rl.get_screen_width(), rl.get_screen_height())
    lights[slot].outer_radius = radius
    lights[slot].bounds.width = radius * 2.0
    lights[slot].bounds.height = radius * 2.0
    move_light(slot, x, y)
    draw_light_mask(slot)


function update_light(slot: int) -> bool:
    if not lights[slot].active or not lights[slot].dirty:
        return false

    lights[slot].dirty = false
    lights[slot].shadow_count = 0
    lights[slot].valid = false

    var index = 0
    while index < box_count:
        if rl.check_collision_point_rec(lights[slot].position, boxes[index]):
            return false
        if not rl.check_collision_recs(lights[slot].bounds, boxes[index]):
            index += 1
            continue

        var sp = rl.Vector2(x = boxes[index].x, y = boxes[index].y)
        var ep = rl.Vector2(x = boxes[index].x + boxes[index].width, y = boxes[index].y)
        if lights[slot].position.y > ep.y:
            compute_shadow_volume_for_edge(slot, sp, ep)

        sp = ep
        ep.y += boxes[index].height
        if lights[slot].position.x < ep.x:
            compute_shadow_volume_for_edge(slot, sp, ep)

        sp = ep
        ep.x -= boxes[index].width
        if lights[slot].position.y < ep.y:
            compute_shadow_volume_for_edge(slot, sp, ep)

        sp = ep
        ep.y -= boxes[index].height
        if lights[slot].position.x > ep.x:
            compute_shadow_volume_for_edge(slot, sp, ep)

        if lights[slot].shadow_count < MAX_SHADOWS:
            lights[slot].shadows[lights[slot].shadow_count].vertices[0] = rl.Vector2(
                x = boxes[index].x,
                y = boxes[index].y
            )
            lights[slot].shadows[lights[slot].shadow_count].vertices[1] = rl.Vector2(
                x = boxes[index].x,
                y = boxes[index].y + boxes[index].height
            )
            lights[slot].shadows[lights[slot].shadow_count].vertices[2] = rl.Vector2(
                x = boxes[index].x + boxes[index].width,
                y = boxes[index].y + boxes[index].height
            )
            lights[slot].shadows[lights[slot].shadow_count].vertices[3] = rl.Vector2(
                x = boxes[index].x + boxes[index].width,
                y = boxes[index].y
            )
            lights[slot].shadow_count += 1

        index += 1

    lights[slot].valid = true
    draw_light_mask(slot)
    return true


function setup_boxes() -> void:
    boxes[0] = rl.Rectangle(x = 150.0, y = 80.0, width = 40.0, height = 40.0)
    boxes[1] = rl.Rectangle(x = 1200.0, y = 700.0, width = 40.0, height = 40.0)
    boxes[2] = rl.Rectangle(x = 200.0, y = 600.0, width = 40.0, height = 40.0)
    boxes[3] = rl.Rectangle(x = 1000.0, y = 50.0, width = 40.0, height = 40.0)
    boxes[4] = rl.Rectangle(x = 500.0, y = 350.0, width = 40.0, height = 40.0)

    var index = 5
    while index < MAX_BOXES:
        boxes[index] = rl.Rectangle(
            x = float<-rl.get_random_value(0, rl.get_screen_width()),
            y = float<-rl.get_random_value(0, rl.get_screen_height()),
            width = float<-rl.get_random_value(10, 100),
            height = float<-rl.get_random_value(10, 100)
        )
        index += 1

    box_count = MAX_BOXES


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - top down lights")
    defer rl.close_window()

    setup_boxes()

    let img = rl.gen_image_checked(64, 64, 32, 32, rl.DARKBROWN, rl.DARKGRAY)
    let background_texture = rl.load_texture_from_image(img)
    defer rl.unload_texture(background_texture)
    rl.unload_image(img)

    let light_mask = rl.load_render_texture(rl.get_screen_width(), rl.get_screen_height())
    defer rl.unload_render_texture(light_mask)

    setup_light(0, 600.0, 400.0, 300.0)
    var next_light = 1
    var show_lines = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let mouse_position = rl.get_mouse_position()
            move_light(0, mouse_position.x, mouse_position.y)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT) and next_light < MAX_LIGHTS:
            let mouse_position = rl.get_mouse_position()
            setup_light(next_light, mouse_position.x, mouse_position.y, 200.0)
            next_light += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_F1):
            show_lines = not show_lines

        var dirty_lights = false
        var index = 0
        while index < MAX_LIGHTS:
            if update_light(index):
                dirty_lights = true
            index += 1

        if dirty_lights:
            rl.begin_texture_mode(light_mask)
            rl.clear_background(rl.BLACK)

            rlgl.set_blend_factors(RLGL_SRC_ALPHA, RLGL_SRC_ALPHA, RLGL_MIN)
            rlgl.set_blend_mode(int<-rl.BlendMode.BLEND_CUSTOM)

            index = 0
            while index < MAX_LIGHTS:
                if lights[index].active:
                    rl.draw_texture_rec(
                        lights[index].mask.texture,
                        rl.Rectangle(
                            x = 0.0,
                            y = 0.0,
                            width = float<-rl.get_screen_width(),
                            height = -float<-rl.get_screen_height()
                        ),
                        rl.Vector2(x = 0.0, y = 0.0),
                        rl.WHITE
                    )
                index += 1

            rlgl.draw_render_batch_active()
            rlgl.set_blend_mode(int<-rl.BlendMode.BLEND_ALPHA)
            rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)

        rl.draw_texture_rec(
            background_texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = float<-rl.get_screen_width(),
                height = float<-rl.get_screen_height()
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE
        )

        var mask_alpha: float = 1.0
        if show_lines:
            mask_alpha = 0.75
        rl.draw_texture_rec(
            light_mask.texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = float<-rl.get_screen_width(),
                height = -float<-rl.get_screen_height()
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.color_alpha(rl.WHITE, mask_alpha)
        )

        index = 0
        while index < MAX_LIGHTS:
            if lights[index].active:
                var light_color = rl.WHITE
                if index == 0:
                    light_color = rl.YELLOW
                rl.draw_circle(int<-lights[index].position.x, int<-lights[index].position.y, 10.0, light_color)
            index += 1

        if show_lines:
            index = 0
            while index < lights[0].shadow_count:
                rl.draw_triangle_fan_ptr(ptr_of(lights[0].shadows[index].vertices[0]), 4, rl.DARKPURPLE)
                index += 1

            index = 0
            while index < box_count:
                if rl.check_collision_recs(boxes[index], lights[0].bounds):
                    rl.draw_rectangle_rec(boxes[index], rl.PURPLE)
                rl.draw_rectangle_lines(
                    int<-boxes[index].x,
                    int<-boxes[index].y,
                    int<-boxes[index].width,
                    int<-boxes[index].height,
                    rl.DARKBLUE
                )
                index += 1

            rl.draw_text("(F1) Hide Shadow Volumes", 10, 50, 10, rl.GREEN)
        else:
            rl.draw_text("(F1) Show Shadow Volumes", 10, 50, 10, rl.GREEN)

        rl.draw_fps(SCREEN_WIDTH - 80, 10)
        rl.draw_text("Drag to move light #1", 10, 10, 10, rl.DARKGREEN)
        rl.draw_text("Right click to add new light", 10, 30, 10, rl.DARKGREEN)
        rl.end_drawing()

    var index = 0
    while index < MAX_LIGHTS:
        if lights[index].active:
            rl.unload_render_texture(lights[index].mask)
        index += 1

    return 0
