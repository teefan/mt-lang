module std.sdl3.runtime

import std.sdl3 as sdl
import std.str as text
import std.string as string

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

pub def locale_list(locales: ptr[ptr[sdl.Locale]], count: i32) -> span[ptr[sdl.Locale]?]:
    unsafe:
        return span[ptr[sdl.Locale]?](data = ptr[ptr[sdl.Locale]?]<-locales, len = usize<-count)

pub def locale_string(locale: ptr[sdl.Locale]) -> string.String:
    unsafe:
        var result = string.String.from_str(text.cstr_as_str(locale.language))
        let country = ptr[char]?<-locale.country
        if country != null:
            result.append("_")
            result.append(text.chars_as_str(ptr[char]<-country))
        return result

pub def debug_text_width(text_value: str) -> f32:
    return f32<-sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE * f32<-text_value.len