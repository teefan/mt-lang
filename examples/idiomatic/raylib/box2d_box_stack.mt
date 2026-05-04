module examples.idiomatic.raylib.box2d_box_stack

import std.box2d as b2
import std.raylib as rl
import std.raylib.math as math

struct BoxSprite:
    body_id: b2.BodyId
    half_width: f32
    half_height: f32
    color: rl.Color

const screen_width: i32 = 960
const screen_height: i32 = 640
const pixels_per_meter: f32 = 48.0
const time_step: f32 = 1.0 / 60.0
const sub_step_count: i32 = 4
const stack_columns: i32 = 5
const stack_rows: i32 = 6
const stack_box_count: i32 = 30


def create_static_box(world_id: b2.WorldId, position: b2.Vec2, half_width: f32, half_height: f32) -> b2.BodyId:
    var body_def = b2.default_body_def()
    body_def.position = position
    let body_id = b2.create_body(world_id, in body_def)
    b2.body_set_type(body_id, b2.BodyType.b2_dynamicBody)
    let shape_def = b2.default_shape_def()
    let polygon = b2.make_box(half_width, half_height)
    b2.create_polygon_shape(body_id, in shape_def, in polygon)
    return body_id


def create_dynamic_box(world_id: b2.WorldId, position: b2.Vec2, half_width: f32, half_height: f32, density: f32) -> b2.BodyId:
    var body_def = b2.default_body_def()
    body_def.position = position
    let body_id = b2.create_body(world_id, in body_def)
    b2.body_set_type(body_id, b2.BodyType.b2_dynamicBody)

    var shape_def = b2.default_shape_def()
    shape_def.density = density
    let polygon = b2.make_box(half_width, half_height)
    b2.create_polygon_shape(body_id, in shape_def, in polygon)
    return body_id


def to_screen(position: b2.Vec2) -> rl.Vector2:
    return rl.Vector2(
        x = position.x * pixels_per_meter,
        y = position.y * pixels_per_meter,
    )


def body_angle_degrees(body_id: b2.BodyId) -> f32:
    let rotation = b2.body_get_rotation(body_id)
    return math.atan2(rotation.s, rotation.c) * math.rad2deg


def draw_box(sprite: BoxSprite) -> void:
    let center = to_screen(b2.body_get_position(sprite.body_id))
    let width = sprite.half_width * pixels_per_meter * 2.0
    let height = sprite.half_height * pixels_per_meter * 2.0

    rl.draw_rectangle_pro(
        rl.Rectangle(
            x = center.x,
            y = center.y,
            width = width,
            height = height,
        ),
        rl.Vector2(x = width * 0.5, y = height * 0.5),
        body_angle_degrees(sprite.body_id),
        sprite.color,
    )


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Box2D Box Stack")
    defer rl.close_window()
    rl.set_target_fps(60)

    var world_def = b2.default_world_def()
    world_def.gravity = b2.Vec2(x = 0.0, y = 22.0)

    let world_id = b2.create_world(in world_def)
    defer b2.destroy_world(world_id)

    let ground_sprite = BoxSprite(
        body_id = create_static_box(world_id, b2.Vec2(x = 10.0, y = 12.25), 8.75, 0.4),
        half_width = 8.75,
        half_height = 0.4,
        color = rl.Color(r = 51, g = 73, b = 92, a = 255),
    )

    let stack_colors = array[rl.Color, 6](
        rl.Color(r = 214, g = 90, b = 80, a = 255),
        rl.Color(r = 236, g = 151, b = 78, a = 255),
        rl.Color(r = 240, g = 196, b = 99, a = 255),
        rl.Color(r = 120, g = 181, b = 138, a = 255),
        rl.Color(r = 80, g = 160, b = 192, a = 255),
        rl.Color(r = 128, g = 128, b = 181, a = 255),
    )

    let box_half_width: f32 = 0.45
    let box_half_height: f32 = 0.45
    var box_count = 0
    var boxes = zero[array[BoxSprite, 30]]()

    for row in 0..stack_rows:
        for column in 0..stack_columns:
            let position = b2.Vec2(
                x = 7.6 + f32<-column * 0.96,
                y = 11.3 - f32<-row * 0.96,
            )
            boxes[box_count] = BoxSprite(
                body_id = create_dynamic_box(world_id, position, box_half_width, box_half_height, 1.0),
                half_width = box_half_width,
                half_height = box_half_height,
                color = stack_colors[row],
            )
            box_count += 1

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            let top_box = boxes[stack_box_count - 1]
            b2.body_apply_linear_impulse_to_center(top_box.body_id, b2.Vec2(x = 5.5, y = -2.5), true)

        b2.world_step(world_id, time_step, sub_step_count)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.Color(r = 234, g = 242, b = 248, a = 255))
        draw_box(ground_sprite)

        for index in 0..box_count:
            draw_box(boxes[index])

        rl.draw_text("SPACE nudges the top crate", 24, 20, 20, rl.DARKGRAY)
        rl.draw_text("A full Box2D stack driven through the imported binding", 24, 48, 20, rl.DARKGRAY)
        rl.draw_fps(screen_width - 96, 16)

    return 0
