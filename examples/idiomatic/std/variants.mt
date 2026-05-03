module examples.idiomatic.std.variants

import std.io as io

variant Event:
    click(x: i32, y: i32)
    key(code: i32, pressed: bool)
    resized(width: i32, height: i32)
    quit

# Payload construction with named arguments.


def make_click(x: i32, y: i32) -> Event:
    return Event.click(x= x, y= y)

# No-payload arm construction as a plain value.


def make_quit() -> Event:
    return Event.quit

# Exhaustive matching over every arm.


def event_code(event: Event) -> i32:
    match event:
        Event.click as click_event:
            return click_event.x + click_event.y
        Event.key as key_event:
            if key_event.pressed:
                return key_event.code
            return -key_event.code
        Event.resized as resize_event:
            return resize_event.width * resize_event.height
        Event.quit:
            return 0
    return 0

# Wildcard matching when only one arm needs special handling.


def is_terminal(event: Event) -> bool:
    match event:
        Event.quit:
            return true
        _:
            return false


def main() -> i32:
    let click = make_click(7, 9)
    let key_down: Event = Event.key(code= 65, pressed= true)
    let key_up: Event = Event.key(code= 65, pressed= false)
    let resized: Event = Event.resized(width= 20, height= 10)
    let quit = make_quit()

    if not io.println("variant showcase"):
        return 1

    if event_code(click) != 16:
        return 2
    if event_code(key_down) != 65:
        return 3
    if event_code(key_up) != -65:
        return 4
    if event_code(resized) != 200:
        return 5

    if not is_terminal(quit):
        return 6
    if is_terminal(click):
        return 7

    if not io.println("variant checks passed"):
        return 8

    return 0
