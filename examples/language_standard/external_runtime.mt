external module examples.language_standard.external_runtime:
    include "stdlib.h"
    include "string.h"

    external function calloc(count: ptr_uint, size: ptr_uint) -> ptr[void]?
    external function free(memory: ptr[void]?) -> void
    external function strlen(text: cstr) -> ptr_uint
    external function memcmp(left: const_ptr[void], right: const_ptr[void], length: ptr_uint) -> int
    external function strtok_r(text: ptr[char]?, delim: cstr, saveptr: ptr[ptr[char]]) -> ptr[char]?
