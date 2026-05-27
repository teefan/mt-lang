import examples.raylib.text.boxed_text as boxed
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const EMOJI_PER_WIDTH: int = 8
const EMOJI_PER_HEIGHT: int = 4
const EMOJI_SLOT_COUNT: int = EMOJI_PER_WIDTH * EMOJI_PER_HEIGHT
const EMOJI_COUNT: int = 48
const MESSAGE_COUNT: int = 12


struct EmojiSlot:
    index: int
    message: int
    color: rl.Color


struct EmojiMessage:
    text: str
    language: str


function randomize_emoji(slots: ref[array[EmojiSlot, EMOJI_SLOT_COUNT]], hovered: ref[int], selected: ref[int]) -> void:
    unsafe:
        read(hovered) = -1
        read(selected) = -1

    let start = rl.get_random_value(45, 360)
    var index = 0
    while index < EMOJI_SLOT_COUNT:
        read(slots)[index].index = rl.get_random_value(0, EMOJI_COUNT - 1)
        read(slots)[index].color = rl.fade(rl.color_from_hsv(float<-((start * (index + 1)) % 360), 0.6, 0.85), 0.8)
        read(slots)[index].message = rl.get_random_value(0, MESSAGE_COUNT - 1)
        index += 1


function uses_asian_font(language: str) -> bool:
    return language.equal("Chinese") or language.equal("Japanese") or language.equal("Korean")


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT | rl.ConfigFlags.FLAG_VSYNC_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - unicode emojis")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let font_default = rl.load_font("dejavu.fnt")
    defer rl.unload_font(font_default)
    let font_asian = rl.load_font("noto_cjk.fnt")
    defer rl.unload_font(font_asian)
    let font_emoji = rl.load_font("symbola.fnt")
    defer rl.unload_font(font_emoji)

    let emoji_texts = array[str, EMOJI_COUNT](
        "🌀", "😀", "😂", "🤣", "😃", "😆", "😉", "😋",
        "😎", "😍", "😘", "🙂", "🤗", "🤔", "😐", "🙄",
        "😴", "😛", "🤤", "😒", "😭", "🤯", "😡", "🤖",
        "💀", "👾", "👻", "👽", "🐱", "🍀", "🍓", "🍕",
        "🍔", "🍟", "🍣", "🍜", "🍰", "🍫", "🍿", "🥝",
        "🥑", "🥐", "🍩", "🍵", "🍷", "💋", "💙", "🖤",
    )

    let messages = array[EmojiMessage, MESSAGE_COUNT](
        EmojiMessage(text = "Falsches Üben von Xylophonmusik quält jeden größeren Zwerg", language = "German"),
        EmojiMessage(text = "Կրնամ ապակի ուտել և ինձ անհանգիստ չըներ", language = "Armenian"),
        EmojiMessage(text = "Jeżu klątw, spłódź Finom część gry hańb!", language = "Polish"),
        EmojiMessage(text = "Îți mulțumesc că ai ales raylib. Și sper să ai o zi bună!", language = "Romanian"),
        EmojiMessage(text = "Я люблю raylib!", language = "Russian"),
        EmojiMessage(text = "Voix ambiguë d’un cœur qui au zéphyr préfère les jattes de kiwi", language = "French"),
        EmojiMessage(text = "Benjamín pidió una bebida de kiwi y fresa; Noé pidió la más exquisita champaña.", language = "Spanish"),
        EmojiMessage(text = "Ταχύστη αλώπηξ βαφής ψημένη γη δρασκελίζει υπέρ νωθρού κυνός", language = "Greek"),
        EmojiMessage(text = "有理走遍天下，无理寸步难行。", language = "Chinese"),
        EmojiMessage(text = "猿も木から落ちる", language = "Japanese"),
        EmojiMessage(text = "고생 끝에 낙이 온다", language = "Korean"),
        EmojiMessage(text = "Hello from raylib and Milk Tea!", language = "English"),
    )

    var emoji_slots: array[EmojiSlot, EMOJI_SLOT_COUNT] = zero[array[EmojiSlot, EMOJI_SLOT_COUNT]]
    var hovered = -1
    var selected = -1
    var hovered_pos = rl.Vector2(x = 0.0, y = 0.0)
    var selected_pos = rl.Vector2(x = 0.0, y = 0.0)

    randomize_emoji(ref_of(emoji_slots), ref_of(hovered), ref_of(selected))

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            randomize_emoji(ref_of(emoji_slots), ref_of(hovered), ref_of(selected))

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and hovered != -1 and hovered != selected:
            selected = hovered
            selected_pos = hovered_pos

        let mouse = rl.get_mouse_position()
        var position = rl.Vector2(x = float<-28.8, y = float<-10.0)
        hovered = -1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var index = 0
        while index < EMOJI_SLOT_COUNT:
            let emoji_text = emoji_texts[emoji_slots[index].index]
            let emoji_rect = rl.Rectangle(x = position.x, y = position.y, width = float<-font_emoji.baseSize, height = float<-font_emoji.baseSize)

            if not rl.check_collision_point_rec(mouse, emoji_rect):
                let tint = if selected == index: emoji_slots[index].color else: rl.fade(rl.LIGHTGRAY, 0.4)
                rl.draw_text_ex(font_emoji, emoji_text, position, float<-font_emoji.baseSize, 1.0, tint)
            else:
                rl.draw_text_ex(font_emoji, emoji_text, position, float<-font_emoji.baseSize, 1.0, emoji_slots[index].color)
                hovered = index
                hovered_pos = position

            if index != 0 and (index % EMOJI_PER_WIDTH) == 0:
                position.y += float<-font_emoji.baseSize + float<-24.25
                position.x = float<-28.8
            else:
                position.x += float<-font_emoji.baseSize + float<-28.8
            index += 1

        if selected != -1:
            let message = messages[emoji_slots[selected].message]
            let selected_font = if uses_asian_font(message.language): font_asian else: font_default
            let horizontal_padding = float<-20.0
            let vertical_padding = float<-30.0
            var size = rl.measure_text_ex(selected_font, message.text, float<-selected_font.baseSize, 1.0)
            if size.x > 300.0:
                size.y *= size.x / float<-300.0
                size.x = float<-300.0
            else if size.x < 160.0:
                size.x = float<-160.0

            var message_rect = rl.Rectangle(
                x = selected_pos.x - float<-38.8,
                y = selected_pos.y,
                width = float<-2.0 * horizontal_padding + size.x,
                height = float<-2.0 * vertical_padding + size.y,
            )
            message_rect.y -= message_rect.height

            var a = rl.Vector2(x = selected_pos.x, y = message_rect.y + message_rect.height)
            var b = rl.Vector2(x = a.x + float<-8.0, y = a.y + float<-10.0)
            var c = rl.Vector2(x = a.x + float<-10.0, y = a.y)

            if message_rect.x < float<-10.0:
                message_rect.x += float<-28.0
            if message_rect.y < float<-10.0:
                message_rect.y = selected_pos.y + float<-84.0
                a.y = message_rect.y
                c.y = a.y
                b.y = a.y - float<-10.0
                let temp = a
                a = b
                b = temp

            if message_rect.x + message_rect.width > float<-SCREEN_WIDTH:
                message_rect.x -= message_rect.x + message_rect.width - float<-SCREEN_WIDTH + float<-10.0

            rl.draw_rectangle_rec(message_rect, emoji_slots[selected].color)
            rl.draw_triangle(a, b, c, emoji_slots[selected].color)

            let text_rect = rl.Rectangle(
                x = message_rect.x + horizontal_padding / 2.0,
                y = message_rect.y + vertical_padding / 2.0,
                width = message_rect.width - horizontal_padding,
                height = message_rect.height,
            )
            boxed.draw_text_boxed(selected_font, message.text, text_rect, float<-selected_font.baseSize, 1.0, true, rl.WHITE)

            let info_text = text.cstr_as_str(
                rl.text_format(
                    "%s %i characters %i bytes",
                    message.language,
                    rl.get_codepoint_count(message.text),
                    int<-rl.text_length(message.text),
                )
            )
            let info_size = rl.measure_text_ex(rl.get_font_default(), info_text, 10.0, 1.0)
            rl.draw_text(info_text, int<-(text_rect.x + text_rect.width - info_size.x), int<-(message_rect.y + message_rect.height - info_size.y - 2.0), 10, rl.RAYWHITE)

        rl.draw_text("These emojis have something to tell you, click each to find out!", (SCREEN_WIDTH - 650) / 2, SCREEN_HEIGHT - 40, 20, rl.GRAY)
        rl.draw_text("Each emoji is a unicode character from a font, not a texture... Press [SPACEBAR] to refresh", (SCREEN_WIDTH - 484) / 2, SCREEN_HEIGHT - 16, 10, rl.GRAY)

        rl.end_drawing()

    return 0
