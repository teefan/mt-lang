module std.gl.util

import std.gl as gl


pub def uniform_location(program: uint, name: cstr) -> gl.GLint:
    unsafe:
        return gl.get_uniform_location(program, const_ptr[gl.GLchar]<-name)


pub def attrib_location(program: uint, name: cstr) -> gl.GLint:
    unsafe:
        return gl.get_attrib_location(program, const_ptr[gl.GLchar]<-name)


pub def shader_source(shader: uint, source_text: cstr) -> void:
    var sources = zero[array[const_ptr[gl.GLchar], 1]]
    var source_ptrs = zero[const_ptr[const_ptr[gl.GLchar]]]
    unsafe:
        sources[0] = const_ptr[gl.GLchar]<-source_text
        source_ptrs = const_ptr[const_ptr[gl.GLchar]]<-ptr_of(sources[0])
    gl.shader_source(shader, 1, source_ptrs, zero[const_ptr[gl.GLint]])


pub def build_shader(shader_type: gl.GLenum, source_text: cstr) -> gl.GLuint:
    let shader = gl.create_shader(uint<-shader_type)
    shader_source(shader, source_text)
    gl.compile_shader(shader)
    return shader


pub def buffer_data[T](target: uint, data: T, usage: uint) -> void:
    unsafe:
        gl.buffer_data(target, ptr_int<-(int<-size_of(T)), const_ptr[void]<-const_ptr_of(data), usage)


pub def uniform_matrix_4(location: int, transpose: ubyte, matrix: array[float, 16]) -> void:
    gl.uniform_matrix_4fv(location, 1, transpose, const_ptr_of(matrix[0]))
