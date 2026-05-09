module examples.language_standard.foreign_bridge

import examples.language_standard.external_math as math
import examples.language_standard.external_runtime as rt
import examples.language_standard.types as types

public foreign function cosine(value: double) -> double = math.cos
public foreign function split_fraction(value: double, out integral: double) -> double = math.modf
public foreign function text_length(text: str as cstr) -> ptr_uint = rt.strlen
public foreign function header_compare(in left: types.Header as const_ptr[void], in right: types.Header as const_ptr[void]) -> int = rt.memcmp(left, right, ptr_uint<-size_of(types.Header))
public foreign function next_token(text: ptr[char]?, delim: cstr, inout state: ptr[char]?) -> ptr[char]? = rt.strtok_r
public foreign function alloc_zeroed[T](count: ptr_uint) -> ptr[T]? = rt.calloc(count, ptr_uint<-size_of(T))
public foreign function release[T](consuming memory: ptr[T]) -> void = rt.free
