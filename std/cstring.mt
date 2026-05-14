module std.cstring

import std.c.string as c

public foreign function copy_bytes(destination: ptr[void], source: const_ptr[void], size_bytes: ptr_uint) -> ptr[void] = c.mt_string_memcpy
public foreign function move_bytes(destination: ptr[void], source: const_ptr[void], size_bytes: ptr_uint) -> ptr[void] = c.mt_string_memmove
public foreign function set_bytes(destination: ptr[void], value: int, size_bytes: ptr_uint) -> ptr[void] = c.mt_string_memset
public foreign function compare_bytes(left: const_ptr[void], right: const_ptr[void], size_bytes: ptr_uint) -> int = c.mt_string_memcmp
public foreign function find_byte(source: const_ptr[void], value: int, size_bytes: ptr_uint) -> ptr[void]? = c.mt_string_memchr

public foreign function length(text: str as cstr) -> ptr_uint = c.mt_string_strlen
public foreign function compare(left: str as cstr, right: str as cstr) -> int = c.mt_string_strcmp
public foreign function compare_prefix(left: str as cstr, right: str as cstr, size_bytes: ptr_uint) -> int = c.mt_string_strncmp
public foreign function find_char(text: str as cstr, value: int) -> ptr[char]? = c.mt_string_strchr
public foreign function find_last_char(text: str as cstr, value: int) -> ptr[char]? = c.mt_string_strrchr
public foreign function find_substring(haystack: str as cstr, needle: str as cstr) -> ptr[char]? = c.mt_string_strstr
