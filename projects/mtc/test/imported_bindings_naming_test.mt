# In-language tests for the imported-bindings naming transforms.
# Run with: mtc test projects/mtc/test/imported_bindings_naming_test.mt

import std.string as string
import std.vec as vec

import mtc.imported_bindings.naming as naming
import mtc.imported_bindings.raw_scanner as raw


struct OglVector:
    raw: str
    expected: str


const OPENGL_VECTORS: array[OglVector, 37] = array[OglVector, 37](
    OglVector(raw = "glBlendEquation", expected = "blend_equation"),
    OglVector(raw = "glBlendEquationi", expected = "blend_equation_indexed"),
    OglVector(raw = "glBlendFunc", expected = "blend_func"),
    OglVector(raw = "glBlendFunci", expected = "blend_func_indexed"),
    OglVector(raw = "glBufferSubData", expected = "buffer_sub_data"),
    OglVector(raw = "glClearBufferfi", expected = "clear_buffer_float_int"),
    OglVector(raw = "glCheckFramebufferStatus", expected = "check_framebuffer_status"),
    OglVector(raw = "glClearDepth", expected = "clear_depth"),
    OglVector(raw = "glClearDepthf", expected = "clear_depth_float"),
    OglVector(raw = "glTexImage2D", expected = "tex_image_2d"),
    OglVector(raw = "glTexImage2DMultisample", expected = "tex_image_2d_multisample"),
    OglVector(raw = "glGetBooleani_v", expected = "get_boolean_indexed_values"),
    OglVector(raw = "glGetBooleanv", expected = "get_boolean_values"),
    OglVector(raw = "glGetBufferParameteri64v", expected = "get_buffer_parameter_int64_values"),
    OglVector(raw = "glGetBufferParameteriv", expected = "get_buffer_parameter_int_values"),
    OglVector(raw = "glGetInternalformati64v", expected = "get_internalformat_int64_values"),
    OglVector(raw = "glGetInteger64i_v", expected = "get_integer64_indexed_values"),
    OglVector(raw = "glGetInteger64v", expected = "get_integer64_values"),
    OglVector(raw = "glGetIntegeri_v", expected = "get_integer_indexed_values"),
    OglVector(raw = "glGetIntegerv", expected = "get_integer_values"),
    OglVector(raw = "glGetPointerv", expected = "get_pointer_values"),
    OglVector(raw = "glGetProgramiv", expected = "get_program_int_values"),
    OglVector(raw = "glGetQueryObjecti64v", expected = "get_query_object_int64_values"),
    OglVector(raw = "glGetGraphicsResetStatus", expected = "get_graphics_reset_status"),
    OglVector(raw = "glGetTransformFeedbacki_v", expected = "get_transform_feedback_int_indexed_values"),
    OglVector(raw = "glPixelStoref", expected = "pixel_store_float"),
    OglVector(raw = "glPixelStorei", expected = "pixel_store_int"),
    OglVector(raw = "glProgramUniform1uiv", expected = "program_uniform_1_uint_values"),
    OglVector(raw = "glProgramUniformMatrix4x3fv", expected = "program_uniform_matrix_4x3_float_values"),
    OglVector(raw = "glSampleMaski", expected = "sample_mask_indexed"),
    OglVector(raw = "glSamplerParameterIuiv", expected = "sampler_parameter_integer_uint_values"),
    OglVector(raw = "glTexParameteriv", expected = "tex_parameter_int_values"),
    OglVector(raw = "glVertexAttribI4uiv", expected = "vertex_attrib_integer_4_uint_values"),
    OglVector(raw = "glVertexAttrib4Nub", expected = "vertex_attrib_4_normalized_ubyte"),
    OglVector(raw = "glGetTransformFeedbacki64_v", expected = "get_transform_feedback_int64_indexed_values"),
    OglVector(raw = "glViewportIndexedf", expected = "viewport_indexed_float"),
    OglVector(raw = "glViewportIndexedfv", expected = "viewport_indexed_float_values"),
)


function make_func(name: str, p0: str, p1: str) -> raw.RawFuncInfo:
    var params = vec.Vec[raw.RawFuncParam].create()
    if p0.len > 0:
        params.push(raw.RawFuncParam(
            name = string.String.from_str(p0),
            param_type = string.String.create(),
        ))
    if p1.len > 0:
        params.push(raw.RawFuncParam(
            name = string.String.from_str(p1),
            param_type = string.String.create(),
        ))
    return raw.RawFuncInfo(
        name = string.String.from_str(name),
        params = params,
        return_type = string.String.create(),
        variadic = false,
    )


function release_funcs(funcs: ref[vec.Vec[raw.RawFuncInfo]]) -> void:
    var i: ptr_uint = 0
    while i < funcs.len():
        let p = funcs.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    funcs.release()


function expect_str(actual: string.String, expected: str, label: str) -> void:
    expect(actual.as_str().equal(expected), label)
    actual.release()


@[test]
function test_snake_case_host_vectors() -> void:
    expect_str(naming.snake_case("HelloWorld"), "hello_world", "HelloWorld")
    expect_str(naming.snake_case("GPUDriver"), "gpu_driver", "GPUDriver")
    expect_str(naming.snake_case("Vector2d"), "vector2d", "Vector2d")
    expect_str(naming.snake_case("Vector2Add"), "vector2_add", "Vector2Add")
    expect_str(naming.snake_case("Vector2_d"), "vector_2d", "Vector2_d")
    expect_str(naming.snake_case("SDL_GetGPUDriver"), "sdl_get_gpu_driver", "SDL_GetGPUDriver")
    expect_str(naming.snake_case("ABc"), "a_bc", "ABc")
    expect_str(naming.snake_case("ABCd"), "ab_cd", "ABCd")


@[test]
function test_camelize_host_vectors() -> void:
    expect_str(naming.camelize("hello_world"), "HelloWorld", "hello_world")
    expect_str(naming.camelize("GLFW_window"), "GlfwWindow", "GLFW_window")
    expect_str(naming.camelize("1_foo"), "1Foo", "1_foo")
    expect_str(naming.camelize("foo__bar"), "FooBar", "foo__bar")


@[test]
function test_replace_is_gsub() -> void:
    var replaced = naming.apply_rename_rule("aXbXc", "replace", "X", "_")
    expect_str(replaced, "a_b_c", "replace all occurrences")


@[test]
function test_reserved_sets_match_the_host() -> void:
    expect_str(naming.sanitize_type_binding_name("Option"), "Option_", "type Option")
    expect_str(naming.sanitize_value_binding_name("Option"), "Option_", "value Option")
    expect_str(naming.sanitize_type_binding_name("ptr"), "ptr_", "type ptr")
    expect_str(naming.sanitize_value_binding_name("ptr"), "ptr", "value ptr")
    expect_str(naming.sanitize_type_binding_name("as"), "as_", "type as")
    expect_str(naming.sanitize_value_binding_name("as"), "as_", "value as")
    expect_str(naming.sanitize_value_binding_name("Attribute"), "Attribute", "value Attribute")


@[test]
function test_opengl_vectors_match_the_host() -> void:
    var funcs = vec.Vec[raw.RawFuncInfo].create()
    defer: release_funcs(ref_of(funcs))
    funcs.push(make_func("glBlendEquationi", "buf", "mode"))
    funcs.push(make_func("glBlendFunci", "buf", "src"))
    funcs.push(make_func("glSampleMaski", "maskNumber", ""))

    var i: ptr_uint = 0
    while i < 37:
        let vector = OPENGL_VECTORS[i]
        var openglized = naming.openglize_binding_name(vector.raw)
        let stripped = naming.strip_prefix_str(openglized.as_str(), "gl")
        var snaked = naming.snake_case(stripped)
        var normalized = naming.normalize_opengl_snake_case(snaked.as_str())
        var final = naming.normalize_opengl_terminal_suffix(
            normalized.as_str(), vector.raw, funcs.as_span())
        expect(final.as_str().equal(vector.expected), vector.raw)
        final.release()
        normalized.release()
        snaked.release()
        openglized.release()
        i += 1
