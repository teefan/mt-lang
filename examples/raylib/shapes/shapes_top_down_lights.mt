module examples.raylib.shapes.shapes_top_down_lights

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as mt_math

const rlgl_src_alpha: i32 = 0x0302
const rlgl_min: i32 = 0x8007
const rlgl_max: i32 = 0x8008
const max_boxes: i32 = 20
const max_shadows: i32 = max_boxes * 3
const max_lights: i32 = 16
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - top down lights"

struct ShadowGeometry:
    vertices: array[rl.Vector2, 4]

struct LightInfo:
    active: bool
    dirty: bool
    valid: bool
    position: rl.Vector2
    mask: rl.RenderTexture
    outer_radius: f32
    bounds: rl.Rectangle
    shadows: array[ShadowGeometry, 60]
    shadow_count: i32


def move_light(light: LightInfo, x: f32, y: f32) -> LightInfo:
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


def draw_light_mask(light: LightInfo) -> void:
    rl.BeginTextureMode(light.mask)
    rl.ClearBackground(rl.WHITE)

    rlgl.rlSetBlendFactors(rlgl_src_alpha, rlgl_src_alpha, rlgl_min)
    rlgl.rlSetBlendMode(rl.BlendMode.BLEND_CUSTOM)

    if light.valid:
        rl.DrawCircleGradient(light.position, light.outer_radius, rl.ColorAlpha(rl.WHITE, 0.0), rl.WHITE)

    rlgl.rlDrawRenderBatchActive()

    rlgl.rlSetBlendMode(rl.BlendMode.BLEND_ALPHA)
    rlgl.rlSetBlendFactors(rlgl_src_alpha, rlgl_src_alpha, rlgl_max)
    rlgl.rlSetBlendMode(rl.BlendMode.BLEND_CUSTOM)

    for index in 0..light.shadow_count:
        var shadow_vertices = light.shadows[index].vertices
        rl.DrawTriangleFan(ptr_of(shadow_vertices[0]), 4, rl.WHITE)

    rlgl.rlDrawRenderBatchActive()
    rlgl.rlSetBlendMode(rl.BlendMode.BLEND_ALPHA)
    rl.EndTextureMode()
    return


def move_light_slot(lights: ref[array[LightInfo, 16]], slot: i32, x: f32, y: f32) -> void:
    var lights_view = read(lights)
    lights_view[slot] = move_light(lights_view[slot], x, y)
    read(lights) = lights_view
    return


def setup_light(lights: ref[array[LightInfo, 16]], slot: i32, x: f32, y: f32, radius: f32) -> void:
    var lights_view = read(lights)
    var light = lights_view[slot]
    light.active = true
    light.valid = false
    light.mask = rl.LoadRenderTexture(rl.GetScreenWidth(), rl.GetScreenHeight())
    light.outer_radius = radius
    light.bounds.width = radius * 2.0
    light.bounds.height = radius * 2.0
    light = move_light(light, x, y)
    lights_view[slot] = light
    read(lights) = lights_view
    draw_light_mask(light)
    return


def update_light(lights: ref[array[LightInfo, 16]], slot: i32, boxes: array[rl.Rectangle, 20], count: i32) -> bool:
    var lights_view = read(lights)
    var light = lights_view[slot]

    if not light.active or not light.dirty:
        return false

    light.dirty = false
    light.shadow_count = 0
    light.valid = false

    for index in 0..count:
        let box = boxes[index]

        if rl.CheckCollisionPointRec(light.position, box):
            lights_view[slot] = light
            read(lights) = lights_view
            return false

        if not rl.CheckCollisionRecs(light.bounds, box):
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
    lights_view[slot] = light
    read(lights) = lights_view
    draw_light_mask(light)
    return true


def setup_boxes(boxes: ref[array[rl.Rectangle, 20]], count: ref[i32]) -> void:
    var items = read(boxes)
    items[0] = rl.Rectangle(x = 150.0, y = 80.0, width = 40.0, height = 40.0)
    items[1] = rl.Rectangle(x = 1200.0, y = 700.0, width = 40.0, height = 40.0)
    items[2] = rl.Rectangle(x = 200.0, y = 600.0, width = 40.0, height = 40.0)
    items[3] = rl.Rectangle(x = 1000.0, y = 50.0, width = 40.0, height = 40.0)
    items[4] = rl.Rectangle(x = 500.0, y = 350.0, width = 40.0, height = 40.0)

    for index in 5..max_boxes:
        items[index] = rl.Rectangle(
            x = f32<-rl.GetRandomValue(0, rl.GetScreenWidth()),
            y = f32<-rl.GetRandomValue(0, rl.GetScreenHeight()),
            width = f32<-rl.GetRandomValue(10, 100),
            height = f32<-rl.GetRandomValue(10, 100),
        )

    read(boxes) = items
    read(count) = max_boxes
    return


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var box_count: i32 = 0
    var boxes = zero[array[rl.Rectangle, 20]]()
    setup_boxes(ref_of(boxes), ref_of(box_count))

    let image = rl.GenImageChecked(64, 64, 32, 32, rl.DARKBROWN, rl.DARKGRAY)
    let background_texture = rl.LoadTextureFromImage(image)
    defer rl.UnloadTexture(background_texture)
    rl.UnloadImage(image)

    let light_mask = rl.LoadRenderTexture(rl.GetScreenWidth(), rl.GetScreenHeight())
    defer rl.UnloadRenderTexture(light_mask)

    var lights = zero[array[LightInfo, 16]]()
    setup_light(ref_of(lights), 0, 600.0, 400.0, 300.0)
    var next_light = 1
    var show_lines = false

    let screen_rect = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = f32<-rl.GetScreenWidth(),
        height = f32<-rl.GetScreenHeight(),
    )
    let flipped_screen_rect = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = f32<-rl.GetScreenWidth(),
        height = -f32<-rl.GetScreenHeight(),
    )
    let origin = rl.Vector2(x = 0.0, y = 0.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let mouse_position = rl.GetMousePosition()
            move_light_slot(ref_of(lights), 0, mouse_position.x, mouse_position.y)

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_RIGHT) and next_light < max_lights:
            let mouse_position = rl.GetMousePosition()
            setup_light(ref_of(lights), next_light, mouse_position.x, mouse_position.y, 200.0)
            next_light += 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F1):
            show_lines = not show_lines

        var dirty_lights = false
        for index in 0..max_lights:
            if update_light(ref_of(lights), index, boxes, box_count):
                dirty_lights = true

        if dirty_lights:
            rl.BeginTextureMode(light_mask)
            rl.ClearBackground(rl.BLACK)

            rlgl.rlSetBlendFactors(rlgl_src_alpha, rlgl_src_alpha, rlgl_min)
            rlgl.rlSetBlendMode(rl.BlendMode.BLEND_CUSTOM)

            for index in 0..max_lights:
                if lights[index].active:
                    rl.DrawTextureRec(lights[index].mask.texture, flipped_screen_rect, origin, rl.WHITE)

            rlgl.rlDrawRenderBatchActive()
            rlgl.rlSetBlendMode(rl.BlendMode.BLEND_ALPHA)
            rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)
        rl.DrawTextureRec(background_texture, screen_rect, origin, rl.WHITE)

        var overlay_alpha: f32 = 1.0
        if show_lines:
            overlay_alpha = 0.75

        rl.DrawTextureRec(light_mask.texture, flipped_screen_rect, origin, rl.ColorAlpha(rl.WHITE, overlay_alpha))

        for index in 0..max_lights:
            if lights[index].active:
                var light_color = rl.WHITE
                if index == 0:
                    light_color = rl.YELLOW
                rl.DrawCircle(i32<-lights[index].position.x, i32<-lights[index].position.y, 10.0, light_color)

        if show_lines:
            for index in 0..lights[0].shadow_count:
                var shadow_vertices = lights[0].shadows[index].vertices
                rl.DrawTriangleFan(ptr_of(shadow_vertices[0]), 4, rl.DARKPURPLE)

            for index in 0..box_count:
                if rl.CheckCollisionRecs(boxes[index], lights[0].bounds):
                    rl.DrawRectangleRec(boxes[index], rl.PURPLE)

                rl.DrawRectangleLines(
                    i32<-boxes[index].x,
                    i32<-boxes[index].y,
                    i32<-boxes[index].width,
                    i32<-boxes[index].height,
                    rl.DARKBLUE,
                )

            rl.DrawText(c"(F1) Hide Shadow Volumes", 10, 50, 10, rl.GREEN)
        else:
            rl.DrawText(c"(F1) Show Shadow Volumes", 10, 50, 10, rl.GREEN)

        rl.DrawFPS(screen_width - 80, 10)
        rl.DrawText(c"Drag to move light #1", 10, 10, 10, rl.DARKGREEN)
        rl.DrawText(c"Right click to add new light", 10, 30, 10, rl.DARKGREEN)

    for index in 0..max_lights:
        if lights[index].active:
            rl.UnloadRenderTexture(lights[index].mask)

    return 0
