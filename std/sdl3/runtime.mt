module std.sdl3.runtime

import std.sdl3 as sdl
import std.str as text
import std.string as string


def run_app_no_args_uninitialized() -> int:
    panic(c"std.sdl3.runtime.run_app_no_args callback not initialized")


var run_app_no_args_slot: array[fn() -> int, 1] = array[fn() -> int, 1](run_app_no_args_uninitialized)


def run_app_no_args_trampoline(argc: int, argv: ptr[ptr[char]]) -> int:
    let callback = run_app_no_args_slot[0]
    return callback()


pub def run_app_no_args(argc: int, argv: ptr[ptr[char]], main_function: fn() -> int) -> int:
    run_app_no_args_slot[0] = main_function
    return sdl.run_app(argc, argv, run_app_no_args_trampoline)


pub def require_ptr[T](value: ptr[T]?, message: str) -> ptr[T]:
    if value == null:
        panic(message)

    unsafe:
        return ptr[T]<-value


pub def free_chars(text_ptr: ptr[char]?) -> void:
    if text_ptr != null:
        unsafe:
            sdl.free(ptr[void]<-ptr[char]<-text_ptr)
    return


pub def free_locale_list(locales: ptr[ptr[sdl.Locale]]?) -> void:
    if locales != null:
        unsafe:
            sdl.free(ptr[void]<-ptr[ptr[sdl.Locale]]<-locales)
    return


pub def locale_list(locales: ptr[ptr[sdl.Locale]], count: int) -> span[ptr[sdl.Locale]?]:
    unsafe:
        return span[ptr[sdl.Locale]?](data = ptr[ptr[sdl.Locale]?]<-locales, len = ptr_uint<-count)


pub def locale_string(locale: ptr[sdl.Locale]) -> string.String:
    unsafe:
        var result = string.String.from_str(text.cstr_as_str(locale.language))
        let country = ptr[char]?<-locale.country
        if country != null:
            result.append("_")
            result.append(text.chars_as_str(ptr[char]<-country))
        return result


pub def debug_text_width(text_value: str) -> float:
    return float<-sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE * float<-text_value.len
