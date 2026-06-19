import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_TEXT_PARTICLES: int = 100
const FONT_SIZE: int = 30
const INITIAL_TEXT: str = "raylib => fun videogames programming!"

struct TextParticle:
    text: str_buffer[100]
    rect: rl.Rectangle
    vel: rl.Vector2
    ppos: rl.Vector2
    padding: float
    border_width: float
    friction: float
    elasticity: float
    color: rl.Color
    grabbed: bool


function random_particle_color() -> rl.Color:
    return rl.Color(
        r = ubyte<-rl.get_random_value(0, 255),
        g = ubyte<-rl.get_random_value(0, 255),
        b = ubyte<-rl.get_random_value(0, 255),
        a = 255
    )


function create_text_particle(source_text: str, x: float, y: float, color: rl.Color) -> TextParticle:
    var particle = TextParticle(
        text = zero[str_buffer[100]],
        rect = rl.Rectangle(x = x, y = y, width = 30.0, height = 30.0),
        vel = rl.Vector2(x = float<-rl.get_random_value(-200, 200), y = float<-rl.get_random_value(-200, 200)),
        ppos = rl.Vector2(x = 0.0, y = 0.0),
        padding = 5.0,
        border_width = 5.0,
        friction = 0.99,
        elasticity = 0.9,
        color = color,
        grabbed = false
    )

    particle.text.assign(source_text)
    particle.rect.width = float<-rl.measure_text(particle.text.as_str(), FONT_SIZE) + particle.padding * 2.0
    particle.rect.height = float<-FONT_SIZE + particle.padding * 2.0
    return particle


function prepare_first_text_particle(
    source_text: str,
    particles: ref[array[TextParticle, MAX_TEXT_PARTICLES]],
    particle_count: ref[int]
) -> void:
    read(particles)[0] = create_text_particle(
        source_text,
        float<-SCREEN_WIDTH / 2.0,
        float<-SCREEN_HEIGHT / 2.0,
        rl.RAYWHITE
    )
    unsafe: read(particle_count) = 1


function reallocate_text_particles(
    particles: ref[array[TextParticle, MAX_TEXT_PARTICLES]],
    particle_pos: int,
    particle_count: ref[int]
) -> void:
    var index = particle_pos + 1
    while index < read(particle_count):
        read(particles)[index - 1] = read(particles)[index]
        index += 1
    unsafe: read(particle_count) -= 1


function slice_text_particle(
    particles: ref[array[TextParticle, MAX_TEXT_PARTICLES]],
    particle_pos: int,
    slice_length: int,
    particle_count: ref[int]
) -> void:
    let source_text = read(particles)[particle_pos].text.as_str()
    let length = int<-rl.text_length(source_text)

    if length > 1 and read(particle_count) + length < MAX_TEXT_PARTICLES:
        var index = 0
        while index < length:
            var piece_text = source_text.slice(ptr_uint<-index, 1z)
            if slice_length != 1:
                piece_text = text.cstr_as_str(rl.text_subtext(source_text, index, slice_length))

            read(particles)[read(particle_count)] = create_text_particle(
                piece_text,
                read(particles)[particle_pos].rect.x + float<-index * read(particles)[particle_pos].rect.width / float<-length,
                read(particles)[particle_pos].rect.y,
                random_particle_color()
            )
            unsafe: read(particle_count) += 1
            index += slice_length

        reallocate_text_particles(particles, particle_pos, particle_count)


function slice_text_particle_by_char(
    particles: ref[array[TextParticle, MAX_TEXT_PARTICLES]],
    char_to_slice: char,
    particle_count: ref[int]
) -> void:
    let particle = read(particles)[0]
    let source_text = particle.text.as_str()
    var token_count = 0
    let tokens = rl.text_split_ptr(source_text, char_to_slice, token_count)
    if token_count <= 1:
        return

    let length = int<-rl.text_length(source_text)
    var index = 0
    while index < length:
        var char_size = 0
        let codepoint = rl.get_codepoint_next(source_text.slice(ptr_uint<-index, ptr_uint<-(length - index)), char_size)
        var advance = char_size
        if codepoint == 0x3f:
            advance = 1

        if codepoint == int<-char_to_slice:
            read(particles)[read(particle_count)] = create_text_particle(
                source_text.slice(ptr_uint<-index, ptr_uint<-advance),
                particle.rect.x + float<-index * particle.rect.width / float<-length,
                particle.rect.y,
                random_particle_color()
            )
            unsafe: read(particle_count) += 1
        index += advance

    index = 0
    while index < token_count:
        let token_text = unsafe: text.chars_as_str(read(tokens + ptr_uint<-index))
        let token_length = int<-rl.text_length(token_text)
        let effective_length = if token_length > 0: token_length else: 1
        read(particles)[read(particle_count)] = create_text_particle(
            token_text,
            particle.rect.x + float<-index * particle.rect.width / float<-effective_length,
            particle.rect.y,
            random_particle_color()
        )
        unsafe: read(particle_count) += 1
        index += 1

    reallocate_text_particles(particles, 0, particle_count)


function glue_text_particles(
    particles: ref[array[TextParticle, MAX_TEXT_PARTICLES]],
    grabbed_index: int,
    target_index: int,
    particle_count: ref[int]
) -> int:
    if (
        grabbed_index < 0
        or target_index < 0
        or grabbed_index >= read(particle_count)
        or target_index >= read(particle_count)
    ):
        return grabbed_index

    var merged_text = zero[str_buffer[100]]
    merged_text.assign(read(particles)[grabbed_index].text.as_str())
    merged_text.append(read(particles)[target_index].text.as_str())

    var particle = create_text_particle(
        merged_text.as_str(),
        read(particles)[grabbed_index].rect.x,
        read(particles)[grabbed_index].rect.y,
        rl.RAYWHITE
    )
    particle.grabbed = true
    read(particles)[read(particle_count)] = particle
    unsafe: read(particle_count) += 1
    read(particles)[grabbed_index].grabbed = false

    if grabbed_index < target_index:
        reallocate_text_particles(particles, target_index, particle_count)
        reallocate_text_particles(particles, grabbed_index, particle_count)
    else:
        reallocate_text_particles(particles, grabbed_index, particle_count)
        reallocate_text_particles(particles, target_index, particle_count)

    return read(particle_count) - 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - strings management")
    defer rl.close_window()

    var text_particles: array[TextParticle, MAX_TEXT_PARTICLES] = zero[array[TextParticle, MAX_TEXT_PARTICLES]]
    var particle_count = 0
    var grabbed_index = -1
    var press_offset = rl.Vector2(x = 0.0, y = 0.0)

    prepare_first_text_particle(INITIAL_TEXT, ref_of(text_particles), ref_of(particle_count))

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let delta = rl.get_frame_time()
        let mouse_pos = rl.get_mouse_position()

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var index = particle_count - 1
            while index >= 0:
                press_offset.x = mouse_pos.x - text_particles[index].rect.x
                press_offset.y = mouse_pos.y - text_particles[index].rect.y
                if rl.check_collision_point_rec(mouse_pos, text_particles[index].rect):
                    text_particles[index].grabbed = true
                    grabbed_index = index
                    break
                index -= 1

        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT) and grabbed_index != -1:
            text_particles[grabbed_index].grabbed = false
            grabbed_index = -1

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            var index = particle_count - 1
            while index >= 0:
                if rl.check_collision_point_rec(mouse_pos, text_particles[index].rect):
                    if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_SHIFT):
                        slice_text_particle(ref_of(text_particles), index, 1, ref_of(particle_count))
                    else:
                        let length = int<-rl.text_length(text_particles[index].text.as_str())
                        let slice_length = if length / 2 > 0: length / 2 else: 1
                        slice_text_particle(ref_of(text_particles), index, slice_length, ref_of(particle_count))
                    break
                index -= 1

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            var index = 0
            while index < particle_count:
                if not text_particles[index].grabbed:
                    text_particles[index].vel = rl.Vector2(
                        x = float<-rl.get_random_value(-2000, 2000),
                        y = float<-rl.get_random_value(-2000, 2000)
                    )
                index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            prepare_first_text_particle(INITIAL_TEXT, ref_of(text_particles), ref_of(particle_count))
            grabbed_index = -1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            prepare_first_text_particle(
                text.chars_as_str(rl.text_to_upper_ptr(INITIAL_TEXT)),
                ref_of(text_particles),
                ref_of(particle_count)
            )
            grabbed_index = -1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            prepare_first_text_particle(
                text.chars_as_str(rl.text_to_lower_ptr(INITIAL_TEXT)),
                ref_of(text_particles),
                ref_of(particle_count)
            )
            grabbed_index = -1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            prepare_first_text_particle(
                text.chars_as_str(rl.text_to_pascal_ptr("raylib_fun_videogames_programming")),
                ref_of(text_particles),
                ref_of(particle_count)
            )
            grabbed_index = -1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_FIVE):
            prepare_first_text_particle(
                text.chars_as_str(rl.text_to_snake_ptr("RaylibFunVideogamesProgramming")),
                ref_of(text_particles),
                ref_of(particle_count)
            )
            grabbed_index = -1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SIX):
            prepare_first_text_particle(
                text.chars_as_str(rl.text_to_camel_ptr("raylib_fun_videogames_programming")),
                ref_of(text_particles),
                ref_of(particle_count)
            )
            grabbed_index = -1

        let char_pressed = rl.get_char_pressed()
        if char_pressed >= 65 and char_pressed <= 122 and particle_count == 1:
            slice_text_particle_by_char(ref_of(text_particles), char<-char_pressed, ref_of(particle_count))

        var index = 0
        while index < particle_count:
            if not text_particles[index].grabbed:
                text_particles[index].rect.x += text_particles[index].vel.x * delta
                text_particles[index].rect.y += text_particles[index].vel.y * delta

                if text_particles[index].rect.x + text_particles[index].rect.width >= float<-SCREEN_WIDTH:
                    text_particles[index].rect.x = float<-SCREEN_WIDTH - text_particles[index].rect.width
                    text_particles[index].vel.x = -text_particles[index].vel.x * text_particles[index].elasticity
                else if text_particles[index].rect.x <= 0.0:
                    text_particles[index].rect.x = 0.0
                    text_particles[index].vel.x = -text_particles[index].vel.x * text_particles[index].elasticity

                if text_particles[index].rect.y + text_particles[index].rect.height >= float<-SCREEN_HEIGHT:
                    text_particles[index].rect.y = float<-SCREEN_HEIGHT - text_particles[index].rect.height
                    text_particles[index].vel.y = -text_particles[index].vel.y * text_particles[index].elasticity
                else if text_particles[index].rect.y <= 0.0:
                    text_particles[index].rect.y = 0.0
                    text_particles[index].vel.y = -text_particles[index].vel.y * text_particles[index].elasticity

                text_particles[index].vel.x = text_particles[index].vel.x * text_particles[index].friction
                text_particles[index].vel.y = text_particles[index].vel.y * text_particles[index].friction
            else:
                text_particles[index].rect.x = mouse_pos.x - press_offset.x
                text_particles[index].rect.y = mouse_pos.y - press_offset.y

                if delta > 0.0:
                    text_particles[index].vel.x = (text_particles[index].rect.x - text_particles[index].ppos.x) / delta
                    text_particles[index].vel.y = (text_particles[index].rect.y - text_particles[index].ppos.y) / delta
                text_particles[index].ppos.x = text_particles[index].rect.x
                text_particles[index].ppos.y = text_particles[index].rect.y

                if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and grabbed_index == index:
                    var other = 0
                    while other < particle_count:
                        if other != grabbed_index and text_particles[grabbed_index].grabbed and rl.check_collision_recs(
                            text_particles[grabbed_index].rect,
                            text_particles[other].rect
                        ):
                            grabbed_index = glue_text_particles(
                                ref_of(text_particles),
                                grabbed_index,
                                other,
                                ref_of(particle_count)
                            )
                            break
                        other += 1
            index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        index = 0
        while index < particle_count:
            let particle = text_particles[index]
            rl.draw_rectangle_rec(
                rl.Rectangle(
                    x = particle.rect.x - particle.border_width,
                    y = particle.rect.y - particle.border_width,
                    width = particle.rect.width + particle.border_width * 2.0,
                    height = particle.rect.height + particle.border_width * 2.0
                ),
                rl.BLACK
            )
            rl.draw_rectangle_rec(particle.rect, particle.color)
            rl.draw_text(
                particle.text.as_str(),
                int<-(particle.rect.x + particle.padding),
                int<-(particle.rect.y + particle.padding),
                FONT_SIZE,
                rl.BLACK
            )
            index += 1

        rl.draw_text(
            "grab a text particle by pressing with the mouse and throw it by releasing",
            10,
            10,
            10,
            rl.DARKGRAY
        )
        rl.draw_text("slice a text particle by pressing it with the mouse right button", 10, 30, 10, rl.DARKGRAY)
        rl.draw_text(
            "shatter a text particle keeping left shift pressed and pressing it with the mouse right button",
            10,
            50,
            10,
            rl.DARKGRAY
        )
        rl.draw_text("glue text particles by grabbing than and keeping left control pressed", 10, 70, 10, rl.DARKGRAY)
        rl.draw_text("1 to 6 to reset", 10, 90, 10, rl.DARKGRAY)
        rl.draw_text(
            "when you have only one text particle, you can slice it by pressing a char",
            10,
            110,
            10,
            rl.DARKGRAY
        )
        let particle_count_text = rl.text_format("TEXT PARTICLE COUNT: %d", particle_count)
        rl.draw_text(particle_count_text, 10, rl.get_screen_height() - 30, 20, rl.BLACK)

        rl.end_drawing()

    return 0
