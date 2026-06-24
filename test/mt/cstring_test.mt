# In-language tests for std.cstring (migrated from
# test/std/std_cstring_test.rb, run by `mtc test`).

import std.testing as t
import std.cstring as cstring

@[test]
function test_cstring_and_memory_helpers() -> t.Check:
    t.expect(cstring.length("milk") == 4, "length(milk) == 4")?
    t.expect(cstring.compare("milk", "milk") == 0, "compare equal == 0")?
    t.expect(cstring.compare_prefix("milk-tea", "milk", 4) == 0, "compare_prefix == 0")?
    t.expect(cstring.find_char("milk", 108) != null, "find_char l non-null")?
    t.expect(cstring.find_last_char("level", 108) != null, "find_last_char l non-null")?
    t.expect(cstring.find_substring("milk tea", "tea") != null, "find_substring non-null")?

    var source = array[ubyte, 4](65, 66, 67, 68)
    var target = zero[array[ubyte, 4]]
    cstring.copy_bytes(unsafe: ptr[void]<-ptr_of(target[0]), unsafe: const_ptr[void]<-ptr_of(source[0]), 4)
    t.expect(cstring.compare_bytes(unsafe: const_ptr[void]<-ptr_of(source[0]), unsafe: const_ptr[void]<-ptr_of(target[0]), 4) == 0, "compare_bytes == 0")?

    cstring.set_bytes(unsafe: ptr[void]<-ptr_of(target[0]), 90, 2)
    t.expect(target[0] == ubyte<-90 and target[1] == ubyte<-90, "set_bytes filled 90")?

    var moved = array[ubyte, 6](1, 2, 3, 4, 5, 0)
    cstring.move_bytes(unsafe: ptr[void]<-ptr_of(moved[1]), unsafe: const_ptr[void]<-ptr_of(moved[0]), 4)
    t.expect(moved[1] == ubyte<-1 and moved[4] == ubyte<-4, "move_bytes shifted")?
    return t.expect(cstring.find_byte(unsafe: const_ptr[void]<-ptr_of(target[0]), 67, 4) != null, "find_byte C non-null")
