module examples.raylib.text.text_strings_management

import std.c.raylib as rl

const max_text_length: i32 = 100
const max_text_particles: i32 = 100
const font_size: i32 = 30
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - strings management"
const base_text: cstr = c"raylib => fun videogames programming!"
const snake_source: cstr = c"raylib_fun_videogames_programming"
const camel_source: cstr = c"RaylibFunVideogamesProgramming"
const particle_count_format: cstr = c"TEXT PARTICLE COUNT: %d"
const char_format: cstr = c"%c"
const concat_format: cstr = c"%s%s"
const copy_format: cstr = c"%s"
const grab_help_text: cstr = c"grab a text particle by pressing with the mouse and throw it by releasing"
const slice_help_text: cstr = c"slice a text particle by pressing it with the mouse right button"
const shatter_help_text: cstr = c"shatter a text particle keeping left shift pressed and pressing it with the mouse right button"
const glue_help_text: cstr = c"glue text particles by grabbing than and keeping left control pressed"
const reset_help_text: cstr = c"1 to 6 to reset"
const char_help_text: cstr = c"when you have only one text particle, you can slice it by pressing a char"

struct TextParticle:
    text: array[char, 100]
    rect: rl.Rectangle
    vel: rl.Vector2
    ppos: rl.Vector2
    padding: f32
    border_width: f32
    friction: f32
    elasticity: f32
    color: rl.Color
    grabbed: bool


def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text


def text_particle_text_ptr(tp: ptr[TextParticle]) -> ptr[char]:
    unsafe:
        return ptr_of(tp.text[0])


def text_particle_text(tp: ptr[TextParticle]) -> cstr:
    return chars_to_cstr(text_particle_text_ptr(tp))


def random_color() -> rl.Color:
    return rl.Color(
        r = u8<-rl.GetRandomValue(0, 255),
        g = u8<-rl.GetRandomValue(0, 255),
        b = u8<-rl.GetRandomValue(0, 255),
        a = 255,
    )


def create_text_particle(text: cstr, x: f32, y: f32, color: rl.Color) -> TextParticle:
    var tp = zero[TextParticle]
    tp.rect = rl.Rectangle(x = x, y = y, width = 30.0, height = 30.0)
    tp.vel = rl.Vector2(x = f32<-rl.GetRandomValue(-200, 200), y = f32<-rl.GetRandomValue(-200, 200))
    tp.ppos = rl.Vector2(x = 0.0, y = 0.0)
    tp.padding = 5.0
    tp.border_width = 5.0
    tp.friction = 0.99
    tp.elasticity = 0.9
    tp.color = color
    tp.grabbed = false

    rl.TextCopy(ptr_of(tp.text[0]), text)
    tp.rect.width = f32<-rl.MeasureText(chars_to_cstr(ptr_of(tp.text[0])), font_size) + tp.padding * 2.0
    tp.rect.height = f32<-font_size + tp.padding * 2.0

    return tp


def prepare_first_text_particle(text: cstr, tps: ptr[TextParticle], particle_count: ptr[i32]) -> void:
    unsafe:
        read(tps) = create_text_particle(
            text,
            f32<-rl.GetScreenWidth() / 2.0,
            f32<-rl.GetScreenHeight() / 2.0,
            rl.RAYWHITE,
        )
        read(particle_count) = 1


def append_particle(tps: ptr[TextParticle], particle_count: ptr[i32], particle: TextParticle) -> void:
    unsafe:
        let next_index = read(particle_count)
        read(tps + next_index) = particle
        read(particle_count) = next_index + 1


def reallocate_text_particles(tps: ptr[TextParticle], particle_pos: i32, particle_count: ptr[i32]) -> void:
    unsafe:
        var index = particle_pos + 1
        while index < read(particle_count):
            read(tps + index - 1) = read(tps + index)
            index += 1

        read(particle_count) = read(particle_count) - 1


def slice_text_particle(tp: ptr[TextParticle], particle_pos: i32, slice_length: i32, tps: ptr[TextParticle], particle_count: ptr[i32]) -> void:
    let length = i32<-rl.TextLength(text_particle_text(tp))

    unsafe:
        if slice_length > 0 and length > 1 and (read(particle_count) + length) < max_text_particles:
            var index = 0
            while index < length:
                let piece_text = if slice_length == 1: rl.TextFormat(char_format, i32<-read(text_particle_text_ptr(tp) + index)) else: rl.TextSubtext(text_particle_text(tp), index, slice_length)
                append_particle(
                    tps,
                    particle_count,
                    create_text_particle(
                        piece_text,
                        tp.rect.x + f32<-index * tp.rect.width / f32<-length,
                        tp.rect.y,
                        random_color(),
                    ),
                )
                index += slice_length

            reallocate_text_particles(tps, particle_pos, particle_count)


def slice_text_particle_by_char(tp: ptr[TextParticle], char_to_slice: char, tps: ptr[TextParticle], particle_count: ptr[i32]) -> void:
    var token_count = 0
    let tokens = rl.TextSplit(text_particle_text(tp), char_to_slice, ptr_of(token_count))

    unsafe:
        if token_count > 1:
            let text_length = i32<-rl.TextLength(text_particle_text(tp))
            var index = 0
            while index < text_length:
                if read(text_particle_text_ptr(tp) + index) == char_to_slice:
                    append_particle(
                        tps,
                        particle_count,
                        create_text_particle(
                            rl.TextFormat(char_format, i32<-char_to_slice),
                            tp.rect.x,
                            tp.rect.y,
                            random_color(),
                        ),
                    )
                index += 1

            index = 0
            while index < token_count:
                let token = chars_to_cstr(read(tokens + index))
                let token_length = i32<-rl.TextLength(token)
                append_particle(
                    tps,
                    particle_count,
                    create_text_particle(
                        rl.TextFormat(copy_format, token),
                        tp.rect.x + f32<-index * tp.rect.width / f32<-token_length,
                        tp.rect.y,
                        random_color(),
                    ),
                )
                index += 1

            reallocate_text_particles(tps, 0, particle_count)


def shatter_text_particle(tp: ptr[TextParticle], particle_pos: i32, tps: ptr[TextParticle], particle_count: ptr[i32]) -> void:
    slice_text_particle(tp, particle_pos, 1, tps, particle_count)


def glue_text_particles(grabbed_index: i32, target_index: i32, tps: ptr[TextParticle], particle_count: ptr[i32]) -> i32:
    unsafe:
        if grabbed_index >= 0 and target_index >= 0 and grabbed_index < read(particle_count) and target_index < read(particle_count):
            let grabbed = tps + grabbed_index
            let target = tps + target_index
            var merged = create_text_particle(
                rl.TextFormat(concat_format, text_particle_text(grabbed), text_particle_text(target)),
                grabbed.rect.x,
                grabbed.rect.y,
                rl.RAYWHITE,
            )
            merged.grabbed = true

            append_particle(tps, particle_count, merged)
            grabbed.grabbed = false

            if grabbed_index < target_index:
                reallocate_text_particles(tps, target_index, particle_count)
                reallocate_text_particles(tps, grabbed_index, particle_count)
            else:
                reallocate_text_particles(tps, grabbed_index, particle_count)
                reallocate_text_particles(tps, target_index, particle_count)

            return read(particle_count) - 1

    return grabbed_index


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var text_particles = zero[array[TextParticle, 100]]
    var particle_count = 0
    var grabbed_particle_index = -1
    var press_offset = rl.Vector2(x = 0.0, y = 0.0)

    prepare_first_text_particle(base_text, ptr_of(text_particles[0]), ptr_of(particle_count))

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let delta = rl.GetFrameTime()
        let mouse_pos = rl.GetMousePosition()

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var index = particle_count - 1
            while index >= 0:
                press_offset.x = mouse_pos.x - text_particles[index].rect.x
                press_offset.y = mouse_pos.y - text_particles[index].rect.y
                if rl.CheckCollisionPointRec(mouse_pos, text_particles[index].rect):
                    text_particles[index].grabbed = true
                    grabbed_particle_index = index
                    break
                index -= 1

        if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if grabbed_particle_index >= 0:
                text_particles[grabbed_particle_index].grabbed = false
                grabbed_particle_index = -1

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            var index = particle_count - 1
            while index >= 0:
                if rl.CheckCollisionPointRec(mouse_pos, text_particles[index].rect):
                    if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_SHIFT):
                        shatter_text_particle(ptr_of(text_particles[index]), index, ptr_of(text_particles[0]), ptr_of(particle_count))
                    else:
                        slice_text_particle(ptr_of(text_particles[index]), index, i32<-rl.TextLength(text_particle_text(ptr_of(text_particles[index]))) / 2, ptr_of(text_particles[0]), ptr_of(particle_count))
                    break
                index -= 1

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            var index = 0
            while index < particle_count:
                if not text_particles[index].grabbed:
                    text_particles[index].vel = rl.Vector2(
                        x = f32<-rl.GetRandomValue(-2000, 2000),
                        y = f32<-rl.GetRandomValue(-2000, 2000),
                    )
                index += 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            prepare_first_text_particle(base_text, ptr_of(text_particles[0]), ptr_of(particle_count))
            grabbed_particle_index = -1
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            prepare_first_text_particle(chars_to_cstr(rl.TextToUpper(base_text)), ptr_of(text_particles[0]), ptr_of(particle_count))
            grabbed_particle_index = -1
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            prepare_first_text_particle(chars_to_cstr(rl.TextToLower(base_text)), ptr_of(text_particles[0]), ptr_of(particle_count))
            grabbed_particle_index = -1
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_FOUR):
            prepare_first_text_particle(chars_to_cstr(rl.TextToPascal(snake_source)), ptr_of(text_particles[0]), ptr_of(particle_count))
            grabbed_particle_index = -1
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_FIVE):
            prepare_first_text_particle(chars_to_cstr(rl.TextToSnake(camel_source)), ptr_of(text_particles[0]), ptr_of(particle_count))
            grabbed_particle_index = -1
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SIX):
            prepare_first_text_particle(chars_to_cstr(rl.TextToCamel(snake_source)), ptr_of(text_particles[0]), ptr_of(particle_count))
            grabbed_particle_index = -1

        let char_pressed = rl.GetCharPressed()
        if char_pressed >= 65 and char_pressed <= 122 and particle_count == 1:
            slice_text_particle_by_char(ptr_of(text_particles[0]), char<-char_pressed, ptr_of(text_particles[0]), ptr_of(particle_count))

        var index = 0
        while index < particle_count:
            if not text_particles[index].grabbed:
                text_particles[index].rect.x += text_particles[index].vel.x * delta
                text_particles[index].rect.y += text_particles[index].vel.y * delta

                if text_particles[index].rect.x + text_particles[index].rect.width >= f32<-screen_width:
                    text_particles[index].rect.x = f32<-screen_width - text_particles[index].rect.width
                    text_particles[index].vel.x = -text_particles[index].vel.x * text_particles[index].elasticity
                elif text_particles[index].rect.x <= 0.0:
                    text_particles[index].rect.x = 0.0
                    text_particles[index].vel.x = -text_particles[index].vel.x * text_particles[index].elasticity

                if text_particles[index].rect.y + text_particles[index].rect.height >= f32<-screen_height:
                    text_particles[index].rect.y = f32<-screen_height - text_particles[index].rect.height
                    text_particles[index].vel.y = -text_particles[index].vel.y * text_particles[index].elasticity
                elif text_particles[index].rect.y <= 0.0:
                    text_particles[index].rect.y = 0.0
                    text_particles[index].vel.y = -text_particles[index].vel.y * text_particles[index].elasticity

                text_particles[index].vel.x = text_particles[index].vel.x * text_particles[index].friction
                text_particles[index].vel.y = text_particles[index].vel.y * text_particles[index].friction
            else:
                text_particles[index].rect.x = mouse_pos.x - press_offset.x
                text_particles[index].rect.y = mouse_pos.y - press_offset.y
                text_particles[index].vel.x = (text_particles[index].rect.x - text_particles[index].ppos.x) / delta
                text_particles[index].vel.y = (text_particles[index].rect.y - text_particles[index].ppos.y) / delta
                text_particles[index].ppos.x = text_particles[index].rect.x
                text_particles[index].ppos.y = text_particles[index].rect.y

                if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL):
                    var other_index = 0
                    while other_index < particle_count:
                        if other_index != grabbed_particle_index and grabbed_particle_index >= 0 and text_particles[grabbed_particle_index].grabbed:
                            if rl.CheckCollisionRecs(text_particles[grabbed_particle_index].rect, text_particles[other_index].rect):
                                grabbed_particle_index = glue_text_particles(grabbed_particle_index, other_index, ptr_of(text_particles[0]), ptr_of(particle_count))
                        other_index += 1
            index += 1

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        index = 0
        while index < particle_count:
            rl.DrawRectangleRec(
                rl.Rectangle(
                    x = text_particles[index].rect.x - text_particles[index].border_width,
                    y = text_particles[index].rect.y - text_particles[index].border_width,
                    width = text_particles[index].rect.width + text_particles[index].border_width * 2.0,
                    height = text_particles[index].rect.height + text_particles[index].border_width * 2.0,
                ),
                rl.BLACK,
            )
            rl.DrawRectangleRec(text_particles[index].rect, text_particles[index].color)
            rl.DrawText(
                text_particle_text(ptr_of(text_particles[index])),
                i32<-(text_particles[index].rect.x + text_particles[index].padding),
                i32<-(text_particles[index].rect.y + text_particles[index].padding),
                font_size,
                rl.BLACK,
            )
            index += 1

        rl.DrawText(grab_help_text, 10, 10, 10, rl.DARKGRAY)
        rl.DrawText(slice_help_text, 10, 30, 10, rl.DARKGRAY)
        rl.DrawText(shatter_help_text, 10, 50, 10, rl.DARKGRAY)
        rl.DrawText(glue_help_text, 10, 70, 10, rl.DARKGRAY)
        rl.DrawText(reset_help_text, 10, 90, 10, rl.DARKGRAY)
        rl.DrawText(char_help_text, 10, 110, 10, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(particle_count_format, particle_count), 10, rl.GetScreenHeight() - 30, 20, rl.BLACK)

    return 0
