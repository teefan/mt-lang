import std.c.libc as c

public type IntDiv = c.div_t
public type PtrIntDiv = c.ldiv_t
public type LongDiv = c.lldiv_t

public const EXIT_FAILURE: int = c.EXIT_FAILURE
public const EXIT_SUCCESS: int = c.EXIT_SUCCESS

public foreign function parse_double(text: str as cstr) -> double = c.atof
public foreign function parse_int(text: str as cstr) -> int = c.atoi
public foreign function parse_long(text: str as cstr) -> ptr_int = c.atol
public foreign function parse_long_long(text: str as cstr) -> long = c.atoll
public foreign function parse_float_to_end(text: str as cstr, end_ptr: ptr[ptr[char]]?) -> float = c.strtof
public foreign function parse_double_to_end(text: str as cstr, end_ptr: ptr[ptr[char]]?) -> double = c.strtod
public foreign function parse_long_to_end(text: str as cstr, end_ptr: ptr[ptr[char]]?, base: int) -> ptr_int = c.strtol
public foreign function parse_ulong_to_end(text: str as cstr, end_ptr: ptr[ptr[char]]?, base: int) -> ptr_uint = c.strtoul
public foreign function parse_long_long_to_end(text: str as cstr, end_ptr: ptr[ptr[char]]?, base: int) -> long = c.strtoll
public foreign function parse_ulong_long_to_end(text: str as cstr, end_ptr: ptr[ptr[char]]?, base: int) -> ulong = c.strtoull
public foreign function get_environment_variable(name: str as cstr) -> cstr? = c.getenv
public foreign function create_temp_file[N](template: str_buffer[N] as ptr[char]) -> int = c.mkstemp
public foreign function create_temp_file_with_suffix[N](template: str_buffer[N] as ptr[char], suffix_length: int) -> int = c.mkstemps
public foreign function create_temp_directory[N](template: str_buffer[N] as ptr[char]) -> cstr? = c.mkdtemp
public foreign function resolve_path[N](name: str as cstr, resolved: str_buffer[N] as ptr[char]) -> cstr? = c.realpath
public foreign function binary_search(key: const_ptr[void], base: const_ptr[void], count: ptr_uint, element_size: ptr_uint, compare: fn(a: const_ptr[void], b: const_ptr[void]) -> int) -> ptr[void]? = c.bsearch
public foreign function sort_array(base: ptr[void], count: ptr_uint, element_size: ptr_uint, compare: fn(a: const_ptr[void], b: const_ptr[void]) -> int) -> void = c.qsort
public foreign function abs_int(value: int) -> int = c.abs
public foreign function abs_long(value: ptr_int) -> ptr_int = c.labs
public foreign function abs_long_long(value: long) -> long = c.llabs
public foreign function divide_int(numerator: int, denominator: int) -> IntDiv = c.div
public foreign function divide_long(numerator: ptr_int, denominator: ptr_int) -> PtrIntDiv = c.ldiv
public foreign function divide_long_long(numerator: long, denominator: long) -> LongDiv = c.lldiv
