# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaRawBindingsTest < Minitest::Test
  def test_default_registry_exposes_known_checked_in_bindings
    registry = MilkTea::RawBindings.default_registry

    assert_equal %w[raylib raymath raygui rlgl libc ctype errno math string sdl3 glfw gl box2d cjson flecs libuv enet zstd sqlite3 curl pcre2 steamworks], registry.map(&:name)
    assert_equal "std.c.raylib", registry.fetch("raylib").module_name
    assert_includes registry.fetch("raylib").header_candidates.first, "third_party/raylib-upstream/src/raylib.h"
    assert_includes registry.fetch("raylib").link_flags, "-lglfw"
    assert_includes registry.fetch("raylib").compiler_flags, "-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB"
    assert_equal({ "indices" => "ptr[ushort]?" }, registry.fetch("raylib").field_type_overrides.fetch("Mesh"))
    assert_equal({ "fileName" => "cstr?" }, registry.fetch("raylib").function_param_type_overrides.fetch("LoadAutomationEventList"))
    assert_equal({ "codepoints" => "ptr[int]?" }, registry.fetch("raylib").function_param_type_overrides.fetch("LoadFontEx"))
    assert_equal({ "vsFileName" => "cstr?", "fsFileName" => "cstr?" }, registry.fetch("raylib").function_param_type_overrides.fetch("LoadShader"))
    assert_equal({ "vsCode" => "cstr?", "fsCode" => "cstr?" }, registry.fetch("raylib").function_param_type_overrides.fetch("LoadShaderFromMemory"))
    assert_equal "ptr[ubyte]?", registry.fetch("raylib").function_return_type_overrides.fetch("LoadFileData")
    assert_equal "ptr[void]?", registry.fetch("raylib").function_return_type_overrides.fetch("MemAlloc")
    assert_equal "ptr[Material]?", registry.fetch("raylib").function_return_type_overrides.fetch("LoadMaterials")
    assert_equal "std.c.raymath", registry.fetch("raymath").module_name
    assert_equal ["m"], registry.fetch("raymath").link_libraries
    assert_equal ["RAYMATH_STATIC_INLINE"], registry.fetch("raymath").bindgen_defines
    assert_equal ["raylib.h"], registry.fetch("raymath").bindgen_include_directives
    assert_includes registry.fetch("raymath").compiler_flags, "-DRAYMATH_STATIC_INLINE"
    assert_equal ["double_t"], registry.fetch("raymath").excluded_declaration_names
    assert_equal({ "float3" => "Float3Array", "float16" => "Float16Array" }, registry.fetch("raymath").type_name_overrides)
    assert_equal [{ module_name: "std.c.raylib", alias: "rl" }], registry.fetch("raymath").module_imports
    assert_equal "rl.Vector3", registry.fetch("raymath").type_overrides.fetch("Vector3")
    assert_equal "rl.Quaternion", registry.fetch("raymath").type_overrides.fetch("Quaternion")
    assert_includes registry.fetch("raymath").header_candidates.first, "third_party/raylib-upstream/src/raymath.h"
    assert_equal ["RAYGUI_IMPLEMENTATION"], registry.fetch("raygui").implementation_defines
    assert_equal ["raylib", "m"], registry.fetch("raygui").link_libraries
    assert_includes registry.fetch("raygui").header_candidates.first, "third_party/raylib-upstream/examples/shapes/raygui.h"
    assert_equal({ "codepoints" => "ptr[int]?" }, registry.fetch("raygui").function_param_type_overrides.fetch("LoadFontData"))
    assert_equal "ptr[ptr[char]]?", registry.fetch("raygui").function_return_type_overrides.fetch("GuiLoadIcons")
    assert_equal "std.c.rlgl", registry.fetch("rlgl").module_name
    assert_equal ["raylib"], registry.fetch("rlgl").link_libraries
    assert_includes registry.fetch("rlgl").header_candidates.first, "third_party/raylib-upstream/src/rlgl.h"
    assert_includes registry.fetch("rlgl").compiler_flags, "-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB"
    assert_equal({ "data" => "const_ptr[void]?" }, registry.fetch("rlgl").function_param_type_overrides.fetch("rlLoadTexture"))
    assert_equal({ "data" => "const_ptr[void]?" }, registry.fetch("rlgl").function_param_type_overrides.fetch("rlLoadTextureCubemap"))
    assert_equal({ "data" => "const_ptr[void]?" }, registry.fetch("rlgl").function_param_type_overrides.fetch("rlLoadShaderBuffer"))
    assert_equal({ "batch" => "ptr[rlRenderBatch]?" }, registry.fetch("rlgl").function_param_type_overrides.fetch("rlSetRenderBatchActive"))
    assert_equal({ "vsCode" => "cstr?", "fsCode" => "cstr?" }, registry.fetch("rlgl").function_param_type_overrides.fetch("rlLoadShaderProgram"))
    assert_equal "ptr[void]?", registry.fetch("rlgl").function_return_type_overrides.fetch("rlGetProcAddress")
    assert_equal "std.c.sdl3", registry.fetch("sdl3").module_name
    assert_equal ["SDL3"], registry.fetch("sdl3").link_libraries
    assert_includes registry.fetch("sdl3").compiler_flags, "-DSDL_MAIN_HANDLED=1"
    assert_includes registry.fetch("sdl3").compiler_flags, "-DMT_LANG_GL_REGISTRY_HAVE_SDL3"
    assert_includes registry.fetch("sdl3").compiler_flags, "-I#{MilkTea::VendoredSDL3.include_root}"
    assert_includes registry.fetch("sdl3").header_candidates.first, "third_party/sdl3-upstream/include/SDL3/SDL.h"
    assert_equal ["SDL_MAIN_HANDLED=1"], registry.fetch("sdl3").bindgen_defines
    assert_equal ["SDL3/SDL_main.h"], registry.fetch("sdl3").bindgen_include_directives
    assert_includes registry.fetch("sdl3").link_flags, "-L#{MilkTea::VendoredSDL3.archive_path.dirname}"
    assert_equal ["SDL_", "Sint", "Uint"], registry.fetch("sdl3").declaration_name_prefixes
    assert_equal({ "reserved" => "ptr[void]?", "argv" => "ptr[ptr[char]]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_RunApp"))
    assert_equal({ "spec" => "const_ptr[SDL_AudioSpec]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_OpenAudioDevice"))
    assert_equal({ "dst_spec" => "const_ptr[SDL_AudioSpec]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_CreateAudioStream"))
    assert_equal({ "userdata" => "ptr[void]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_OpenAudioDeviceStream"))
    assert_equal({ "channel_buffers" => "const_ptr[const_ptr[void]?]" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_PutAudioStreamPlanarData"))
    assert_equal({ "pslen" => "ptr[ptr_uint]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_StepUTF8"))
    assert_equal({ "palette" => "const_ptr[SDL_Palette]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_MapRGB"))
    assert_equal({ "palette" => "const_ptr[SDL_Palette]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_MapRGBA"))
    assert_equal({ "rect" => "const_ptr[SDL_Rect]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_LockTextureToSurface"))
    assert_equal({ "rect" => "const_ptr[SDL_Rect]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_FillSurfaceRect"))
    assert_equal({ "rect" => "const_ptr[SDL_Rect]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_UpdateTexture"))
    assert_equal({ "rect" => "const_ptr[SDL_Rect]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_SetRenderViewport"))
    assert_equal({ "rect" => "const_ptr[SDL_Rect]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_SetRenderClipRect"))
    assert_equal({ "spec" => "const_ptr[SDL_CameraSpec]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_OpenCamera"))
    assert_equal({ "texture" => "ptr[SDL_Texture]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_SetRenderTarget"))
    assert_equal({ "name" => "cstr?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_CreateRenderer"))
    assert_equal({ "device" => "ptr[SDL_GPUDevice]?", "window" => "ptr[SDL_Window]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_CreateGPURenderer"))
    assert_equal({ "w" => "ptr[int]?", "h" => "ptr[int]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_GetWindowSize"))
    assert_equal({ "swapchain_texture_width" => "ptr[uint]?", "swapchain_texture_height" => "ptr[uint]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_AcquireGPUSwapchainTexture"))
    assert_equal({ "rect" => "const_ptr[SDL_Rect]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_RenderReadPixels"))
    assert_equal({ "srcrect" => "const_ptr[SDL_FRect]?", "dstrect" => "const_ptr[SDL_FRect]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_RenderTexture"))
    assert_equal({ "srcrect" => "const_ptr[SDL_FRect]?", "dstrect" => "const_ptr[SDL_FRect]?", "center" => "const_ptr[SDL_FPoint]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_RenderTextureRotated"))
    assert_equal({ "srcrect" => "const_ptr[SDL_FRect]?", "origin" => "const_ptr[SDL_FPoint]?", "right" => "const_ptr[SDL_FPoint]?", "down" => "const_ptr[SDL_FPoint]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_RenderTextureAffine"))
    assert_equal({ "texture" => "ptr[SDL_Texture]?", "indices" => "const_ptr[int]?" }, registry.fetch("sdl3").function_param_type_overrides.fetch("SDL_RenderGeometry"))
    assert_equal "ptr[SDL_Surface]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_LoadPNG")
    assert_equal "ptr[SDL_Surface]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_ConvertSurface")
    assert_equal "ptr[SDL_Texture]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_CreateTexture")
    assert_equal "ptr[SDL_Texture]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_CreateTextureFromSurface")
    assert_equal "ptr[SDL_AudioStream]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_CreateAudioStream")
    assert_equal "ptr[SDL_Window]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_CreateWindow")
    assert_equal "ptr[SDL_Renderer]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_CreateRenderer")
    assert_equal "ptr[SDL_Surface]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_CreateSurface")
    assert_equal "ptr[SDL_IOStream]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_OpenIO")
    assert_equal "ptr[SDL_Haptic]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_OpenHaptic")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetHint")
    assert_equal "SDL_FunctionPointer?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GL_GetProcAddress")
    assert_equal "SDL_FunctionPointer?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_EGL_GetProcAddress")
    assert_equal "ptr[void]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_malloc")
    assert_equal "ptr[char]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_strdup")
    assert_equal "ptr[void]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_LoadFile")
    assert_equal "ptr[char]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_strchr")
    assert_equal "ptr[char]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetClipboardText")
    assert_equal "ptr[char]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetPrimarySelectionText")
    assert_equal "ptr[ptr[SDL_Locale]]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetPreferredLocales")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetBasePath")
    assert_equal "ptr[SDL_DisplayID]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetDisplays")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetDisplayName")
    assert_equal "ptr[ptr[SDL_DisplayMode]]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetFullscreenDisplayModes")
    assert_equal "const_ptr[SDL_DisplayMode]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetDesktopDisplayMode")
    assert_equal "const_ptr[SDL_DisplayMode]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetCurrentDisplayMode")
    assert_equal "ptr[void]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetWindowICCProfile")
    assert_equal "ptr[ptr[SDL_Window]]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetWindows")
    assert_equal "ptr[SDL_SharedObject]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_LoadObject")
    assert_equal "SDL_FunctionPointer?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_LoadFunction")
    assert_equal "ptr[SDL_Window]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GL_GetCurrentWindow")
    assert_equal "SDL_GLContext?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GL_GetCurrentContext")
    assert_equal "ptr[SDL_AudioStream]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_OpenAudioDeviceStream")
    assert_equal "ptr[SDL_KeyboardID]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetKeyboards")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetKeyboardNameForID")
    assert_equal "ptr[SDL_MouseID]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetMice")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetMouseNameForID")
    assert_equal "ptr[SDL_TouchID]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetTouchDevices")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetTouchDeviceName")
    assert_equal "ptr[ptr[SDL_Finger]]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetTouchFingers")
    assert_equal "ptr[SDL_SensorID]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetSensors")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetSensorNameForID")
    assert_equal "ptr[SDL_Sensor]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_OpenSensor")
    assert_equal "ptr[SDL_Sensor]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetSensorFromID")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetSensorName")
    assert_equal "ptr[SDL_CameraID]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetCameras")
    assert_equal "ptr[SDL_Camera]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_OpenCamera")
    assert_equal "ptr[SDL_Surface]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_AcquireCameraFrame")
    assert_equal "ptr[SDL_JoystickID]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetJoysticks")
    assert_equal "ptr[SDL_Joystick]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_OpenJoystick")
    assert_equal "ptr[SDL_Joystick]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetJoystickFromID")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetJoystickNameForID")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetJoystickName")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetJoystickPathForID")
    assert_equal "ptr[SDL_Joystick]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetJoystickFromPlayerIndex")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetJoystickPath")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetJoystickSerial")
    assert_equal "ptr[ptr[char]]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadMappings")
    assert_equal "ptr[SDL_JoystickID]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepads")
    assert_equal "ptr[SDL_Gamepad]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_OpenGamepad")
    assert_equal "ptr[SDL_Gamepad]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadFromID")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadNameForID")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadName")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadPathForID")
    assert_equal "cstr?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadPath")
    assert_equal "ptr[char]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadMapping")
    assert_equal "ptr[char]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadMappingForGUID")
    assert_equal "ptr[char]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_GetGamepadMappingForID")
    assert_equal "ptr[SDL_Surface]?", registry.fetch("sdl3").function_return_type_overrides.fetch("SDL_RenderReadPixels")
    assert_equal "std.c.glfw", registry.fetch("glfw").module_name
    assert_equal ["glfw3"], registry.fetch("glfw").link_libraries
    assert_includes registry.fetch("glfw").compiler_flags, "-DMT_LANG_GL_REGISTRY_HAVE_GLFW"
    assert_includes registry.fetch("glfw").compiler_flags, "-I#{MilkTea::VendoredGLFW.include_root}"
    assert_includes registry.fetch("glfw").header_candidates.first, "third_party/glfw-upstream/include/GLFW/glfw3.h"
    assert_includes registry.fetch("glfw").tracked_header_paths.first, "third_party/glfw-upstream/include/GLFW/glfw3.h"
    assert_includes registry.fetch("glfw").tracked_header_prefixes.first, "third_party/glfw-upstream/include/GLFW"
    assert_includes registry.fetch("glfw").link_flags, "-L#{MilkTea::VendoredGLFW.archive_path.dirname}"
    assert_equal ["GLFW", "glfw"], registry.fetch("glfw").declaration_name_prefixes
    assert_equal({ "description" => "ptr[cstr]?" }, registry.fetch("glfw").function_param_type_overrides.fetch("glfwGetError"))
    assert_equal({ "window" => "ptr[GLFWwindow]?" }, registry.fetch("glfw").function_param_type_overrides.fetch("glfwMakeContextCurrent"))
    assert_equal "ptr[GLFWwindow]?", registry.fetch("glfw").function_return_type_overrides.fetch("glfwCreateWindow")
    assert_equal "GLFWglproc?", registry.fetch("glfw").function_return_type_overrides.fetch("glfwGetProcAddress")
    assert_equal "std.c.gl", registry.fetch("gl").module_name
    assert_equal [], registry.fetch("gl").link_libraries
    assert_equal [MilkTea::OpenGLRegistry::IMPLEMENTATION_DEFINE], registry.fetch("gl").implementation_defines
    assert_includes registry.fetch("gl").header_candidates.first, "/std/c/gl_registry_helpers.h"
    assert_includes registry.fetch("gl").tracked_header_paths.first, "/std/c/gl_registry_helpers.h"
    assert_equal ["GL", "gl", "mt_gl_"], registry.fetch("gl").declaration_name_prefixes
    assert_equal "std.c.box2d", registry.fetch("box2d").module_name
    assert_equal ["box2d"], registry.fetch("box2d").link_libraries
    assert_includes registry.fetch("box2d").compiler_flags, "-I#{MilkTea::VendoredBox2D.include_root}"
    assert_includes registry.fetch("box2d").header_candidates.first, "third_party/box2d-upstream/include/box2d/box2d.h"
    assert_includes registry.fetch("box2d").tracked_header_paths.first, "third_party/box2d-upstream/include/box2d/box2d.h"
    assert_includes registry.fetch("box2d").tracked_header_prefixes.first, "third_party/box2d-upstream/include/box2d"
    assert_includes registry.fetch("box2d").link_flags, "-L#{MilkTea::VendoredBox2D.archive_path.dirname}"
    assert_includes registry.fetch("box2d").link_flags, "-lm"
    assert_equal ["b2", "B2_"], registry.fetch("box2d").declaration_name_prefixes
    assert_equal "std.c.cjson", registry.fetch("cjson").module_name
    assert_equal ["cjson"], registry.fetch("cjson").link_libraries
    assert_includes registry.fetch("cjson").header_candidates.first, "third_party/cjson-upstream/cJSON.h"
    assert_includes registry.fetch("cjson").link_flags, "-L#{MilkTea::VendoredCJSON.archive_path.dirname}"
    assert_includes registry.fetch("cjson").link_flags, "-lm"
    assert_equal ["cJSON", "CJSON_"], registry.fetch("cjson").declaration_name_prefixes
    assert_equal "ptr[cJSON]?", registry.fetch("cjson").function_return_type_overrides.fetch("cJSON_Parse")
    assert_equal "ptr[char]?", registry.fetch("cjson").function_return_type_overrides.fetch("cJSON_Print")
    assert_equal "cstr?", registry.fetch("cjson").function_return_type_overrides.fetch("cJSON_GetErrorPtr")
    assert_equal "ptr[cJSON]?", registry.fetch("cjson").function_return_type_overrides.fetch("cJSON_AddNullToObject")
    assert_equal "ptr[cJSON]?", registry.fetch("cjson").function_return_type_overrides.fetch("cJSON_AddStringToObject")
    assert_equal "std.c.flecs", registry.fetch("flecs").module_name
    assert_equal ["flecs"], registry.fetch("flecs").link_libraries
    assert_includes registry.fetch("flecs").compiler_flags, "-I#{MilkTea::VendoredFlecs.include_root}"
    assert_includes registry.fetch("flecs").header_candidates.first, "third_party/flecs-upstream/distr/flecs.h"
    assert_includes registry.fetch("flecs").tracked_header_paths.first, "third_party/flecs-upstream/distr/flecs.h"
    assert_includes registry.fetch("flecs").tracked_header_prefixes.first, "third_party/flecs-upstream/distr"
    assert_includes registry.fetch("flecs").link_flags, "-L#{MilkTea::VendoredFlecs.archive_path.dirname}"
    assert_includes registry.fetch("flecs").link_flags, "-lrt"
    assert_includes registry.fetch("flecs").link_flags, "-lpthread"
    assert_includes registry.fetch("flecs").link_flags, "-lm"
    assert_equal ["ecs_", "Ecs", "ECS_", "FLECS_"], registry.fetch("flecs").declaration_name_prefixes
    assert_equal "std.c.libuv", registry.fetch("libuv").module_name
    assert_equal ["uv"], registry.fetch("libuv").link_libraries
    assert_includes registry.fetch("libuv").compiler_flags, "-I#{MilkTea::VendoredLibUV.include_root}"
    assert_includes registry.fetch("libuv").header_candidates.first, "third_party/libuv-upstream/include/uv.h"
    assert_includes registry.fetch("libuv").tracked_header_paths.first, "third_party/libuv-upstream/include/uv.h"
    assert_includes registry.fetch("libuv").tracked_header_prefixes.first, "third_party/libuv-upstream/include"
    assert_includes registry.fetch("libuv").link_flags, "-L#{MilkTea::VendoredLibUV.archive_path.dirname}"
    assert_equal ["uv_", "UV_"], registry.fetch("libuv").declaration_name_prefixes
    assert_equal({ "node" => "cstr?", "service" => "cstr?", "hints" => "const_ptr[addrinfo]?" }, registry.fetch("libuv").function_param_type_overrides.fetch("uv_getaddrinfo"))
    assert_equal({ "ai" => "ptr[addrinfo]?" }, registry.fetch("libuv").function_param_type_overrides.fetch("uv_freeaddrinfo"))
    assert_equal({ "loop" => "ptr[uv_loop_t]?", "cb" => "uv_fs_cb?" }, registry.fetch("libuv").function_param_type_overrides.fetch("uv_fs_access"))
    assert_equal({ "loop" => "ptr[uv_loop_t]?", "cb" => "uv_fs_cb?" }, registry.fetch("libuv").function_param_type_overrides.fetch("uv_fs_copyfile"))
    assert_equal({ "loop" => "ptr[uv_loop_t]?", "cb" => "uv_fs_cb?" }, registry.fetch("libuv").function_param_type_overrides.fetch("uv_fs_stat"))
    assert_equal({ "loop" => "ptr[uv_loop_t]?", "cb" => "uv_fs_cb?" }, registry.fetch("libuv").function_param_type_overrides.fetch("uv_fs_scandir"))
    assert_equal({ "loop" => "ptr[uv_loop_t]?", "cb" => "uv_fs_cb?" }, registry.fetch("libuv").field_type_overrides.fetch("uv_fs_s"))
    assert_equal "ptr[uv_loop_t]?", registry.fetch("libuv").function_return_type_overrides.fetch("uv_default_loop")
    assert_equal "ptr[uv_loop_t]?", registry.fetch("libuv").function_return_type_overrides.fetch("uv_loop_new")
    assert_equal "ptr[void]?", registry.fetch("libuv").function_return_type_overrides.fetch("uv_handle_get_data")
    assert_equal "ptr[void]?", registry.fetch("libuv").function_return_type_overrides.fetch("uv_req_get_data")
    assert_equal "ptr[void]?", registry.fetch("libuv").function_return_type_overrides.fetch("uv_key_get")
    assert_equal "ptr[void]?", registry.fetch("libuv").function_return_type_overrides.fetch("uv_loop_get_data")
    assert_equal "cstr?", registry.fetch("libuv").function_return_type_overrides.fetch("uv_dlerror")
    assert_equal "std.c.enet", registry.fetch("enet").module_name
    assert_equal ["enet"], registry.fetch("enet").link_libraries
    assert_includes registry.fetch("enet").header_candidates, "/usr/include/enet/enet.h"
    assert_includes registry.fetch("enet").tracked_header_paths, "/usr/include/enet/enet.h"
    assert_includes registry.fetch("enet").tracked_header_prefixes, "/usr/include/enet"
    assert_equal ["enet_", "ENET_", "ENet", "_ENet"], registry.fetch("enet").declaration_name_prefixes
    assert_equal "std.c.zstd", registry.fetch("zstd").module_name
    assert_equal ["zstd"], registry.fetch("zstd").link_libraries
    assert_includes registry.fetch("zstd").header_candidates, "/usr/include/zstd.h"
    assert_includes registry.fetch("zstd").tracked_header_paths, "/usr/include/zstd.h"
    assert_includes registry.fetch("zstd").tracked_header_paths, "/usr/include/zstd_errors.h"
    assert_includes registry.fetch("zstd").declaration_name_prefixes, "ZSTD_"
    assert_equal "std.c.sqlite3", registry.fetch("sqlite3").module_name
    assert_equal ["sqlite3"], registry.fetch("sqlite3").link_libraries
    assert_equal ["SQLITE_OMIT_LOAD_EXTENSION"], registry.fetch("sqlite3").bindgen_defines
    assert_includes registry.fetch("sqlite3").header_candidates, "/usr/include/sqlite3.h"
    assert_includes registry.fetch("sqlite3").declaration_name_prefixes, "sqlite3"
    assert_equal "std.c.curl", registry.fetch("curl").module_name
    assert_equal ["curl"], registry.fetch("curl").link_libraries
    assert_includes registry.fetch("curl").header_candidates, "/usr/include/curl/curl.h"
    assert_equal ["curl_", "curlfiletype", "CURL", "CURLOPT_", "CURLINFO_", "CURLM", "CURLSH"], registry.fetch("curl").declaration_name_prefixes
    assert_equal "std.c.pcre2", registry.fetch("pcre2").module_name
    assert_equal ["pcre2-8"], registry.fetch("pcre2").link_libraries
    assert_equal ["PCRE2_CODE_UNIT_WIDTH=8"], registry.fetch("pcre2").bindgen_defines
    assert_includes registry.fetch("pcre2").compiler_flags, "-DPCRE2_CODE_UNIT_WIDTH=8"
    assert_includes registry.fetch("pcre2").compiler_flags, "-I#{MilkTea::VendoredPCRE2.include_root}"
    assert_equal ["pcre2_", "PCRE2_"], registry.fetch("pcre2").declaration_name_prefixes
    assert_includes registry.fetch("pcre2").header_candidates.first, "tmp/vendored-pcre2-prefix/include/pcre2.h"
    assert_includes registry.fetch("pcre2").tracked_header_paths.first, "tmp/vendored-pcre2-prefix/include/pcre2.h"
    assert_includes registry.fetch("pcre2").tracked_header_prefixes.first, "tmp/vendored-pcre2-prefix/include"
    assert_includes registry.fetch("pcre2").link_flags, "-L#{MilkTea::VendoredPCRE2.archive_path.dirname}"
    assert_includes registry.fetch("pcre2").link_flags, "-lm"
    assert_equal "std.c.steamworks", registry.fetch("steamworks").module_name
    assert_equal MilkTea::Steamworks.default_link_libraries, registry.fetch("steamworks").link_libraries
    assert_includes registry.fetch("steamworks").header_candidates.first, "/std/c/steamworks.h"
    assert_includes registry.fetch("steamworks").tracked_header_paths.first, "/std/c/steamworks.h"
    assert_includes registry.fetch("steamworks").link_flags.first, "/tmp/vendored-steamworks"
    assert_equal ["-D_GNU_SOURCE"], registry.fetch("libc").compiler_flags
    assert_equal "bindgen:check:libc", registry.fetch("libc").check_task_name
    assert_equal({ "__endptr" => "ptr[ptr[char]]?" }, registry.fetch("libc").function_param_type_overrides.fetch("strtoul"))
    assert_equal "std.c.ctype", registry.fetch("ctype").module_name
    assert_equal ["mt_ctype_"], registry.fetch("ctype").declaration_name_prefixes
    assert_equal "bindgen:check:ctype", registry.fetch("ctype").check_task_name
    assert_includes registry.fetch("ctype").header_candidates.first, "/std/c/ctype_bindgen.h"
    assert_equal "std.c.errno", registry.fetch("errno").module_name
    assert_equal ["MT_ERRNO_", "mt_errno_"], registry.fetch("errno").declaration_name_prefixes
    assert_equal "bindgen:check:errno", registry.fetch("errno").check_task_name
    assert_equal "cstr?", registry.fetch("errno").function_return_type_overrides.fetch("mt_errno_strerror")
    assert_includes registry.fetch("errno").header_candidates.first, "/std/c/errno_bindgen.h"
    assert_equal "std.c.math", registry.fetch("math").module_name
    assert_equal ["mt_math_"], registry.fetch("math").declaration_name_prefixes
    assert_equal ["m"], registry.fetch("math").link_libraries
    assert_equal "bindgen:check:math", registry.fetch("math").check_task_name
    assert_includes registry.fetch("math").header_candidates.first, "/std/c/math_bindgen.h"
    assert_equal "std.c.string", registry.fetch("string").module_name
    assert_equal ["mt_string_"], registry.fetch("string").declaration_name_prefixes
    assert_equal "ptr[void]?", registry.fetch("string").function_return_type_overrides.fetch("mt_string_memchr")
    assert_equal "ptr[char]?", registry.fetch("string").function_return_type_overrides.fetch("mt_string_strstr")
    assert_equal "bindgen:check:string", registry.fetch("string").check_task_name
    assert_includes registry.fetch("string").header_candidates.first, "/std/c/string_bindgen.h"
    assert_equal "bindgen:check_raylib", registry.fetch("raylib").legacy_check_task_name
  end

  def test_header_path_prefers_env_override_before_default_candidates
    Dir.mktmpdir("milk-tea-raw-binding-path") do |dir|
      default_header = File.join(dir, "default.h")
      override_header = File.join(dir, "override.h")
      File.write(default_header, "")
      File.write(override_header, "")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: File.join(dir, "sample.mt"),
        header_candidates: [default_header],
        include_directives: ["sample.h"],
        env_var: "SAMPLE_HEADER",
      )

      assert_equal override_header, binding.header_path(env: { "SAMPLE_HEADER" => override_header })
      assert_equal default_header, binding.header_path(env: {})
    end
  end

  def test_default_registry_scopes_vendored_library_paths_to_root
    Dir.mktmpdir("milk-tea-raw-binding-root") do |dir|
      root = Pathname.new(dir)
      registry = MilkTea::RawBindings.default_registry(root:)

      assert_equal root.join("third_party/raylib-upstream/src"), registry.fetch("raylib").vendored_library.source_root
      assert_includes registry.fetch("raylib").header_candidates.first, root.join("third_party/raylib-upstream/src/raylib.h").to_s

      assert_equal root.join("third_party/sdl3-upstream"), registry.fetch("sdl3").vendored_library.source_root
      assert_includes registry.fetch("sdl3").compiler_flags, "-I#{root.join('third_party/sdl3-upstream/include')}"
      assert_includes registry.fetch("sdl3").header_candidates.first, root.join("third_party/sdl3-upstream/include/SDL3/SDL.h").to_s

      assert_equal root.join("third_party/flecs-upstream"), registry.fetch("flecs").vendored_library.source_root
      assert_includes registry.fetch("flecs").compiler_flags, "-I#{root.join('third_party/flecs-upstream/distr')}"
      assert_includes registry.fetch("flecs").header_candidates.first, root.join("third_party/flecs-upstream/distr/flecs.h").to_s
    end
  end

  def test_generate_forwards_binding_configuration_to_bindgen
    Dir.mktmpdir("milk-tea-raw-binding-generate") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, "")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: File.join(dir, "sample.mt"),
        header_candidates: [header_path],
        include_directives: ["sample.h"],
        bindgen_defines: ["SAMPLE_MAIN_HANDLED=1"],
        bindgen_include_directives: ["sample_main.h"],
        link_libraries: ["sample"],
        env_var: "SAMPLE_HEADER",
        clang_args: ["-I#{dir}"],
        allow_static_inline_functions: true,
        function_param_type_overrides: { "sample_function" => { "data" => "ptr[ubyte]?" } },
        field_type_overrides: { "Sample" => { "data" => "ptr[ubyte]?" } },
      )

      observed = nil
      with_singleton_method_override(MilkTea::Bindgen, :generate, lambda { |**kwargs|
        observed = kwargs
        "generated"
      }) do
        assert_equal "generated", binding.generate(env: { "SAMPLE_HEADER" => header_path, "CLANG" => "clang-custom" })
      end

      assert_equal(
        {
          module_name: "std.c.sample",
          header_path:,
          link_libraries: ["sample"],
          include_directives: ["sample.h"],
          bindgen_defines: ["SAMPLE_MAIN_HANDLED=1"],
          bindgen_include_directives: ["sample_main.h"],
          module_imports: [],
          clang: "clang-custom",
          clang_args: ["-I#{dir}"],
          allow_static_inline_functions: true,
          type_name_overrides: {},
          type_overrides: {},
          function_param_type_overrides: { "sample_function" => { "data" => "ptr[ubyte]?" } },
          function_return_type_overrides: {},
          field_type_overrides: { "Sample" => { "data" => "ptr[ubyte]?" } },
        },
        observed,
      )
    end
  end

  def test_generate_can_delegate_to_custom_generator
    Dir.mktmpdir("milk-tea-raw-binding-custom-generate") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, "")

      observed = nil
      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: File.join(dir, "sample.mt"),
        header_candidates: [header_path],
        generator: lambda { |resolved_binding, env:, header_path:|
          observed = {
            binding_name: resolved_binding.name,
            module_name: resolved_binding.module_name,
            header_path:,
            marker: env.fetch("MARKER"),
          }
          "generated"
        },
      )

      with_singleton_method_override(MilkTea::Bindgen, :generate, ->(**) { flunk("expected custom generator to bypass Bindgen.generate") }) do
        assert_equal "generated", binding.generate(env: { "MARKER" => "ok" })
      end

      assert_equal(
        {
          binding_name: "sample",
          module_name: "std.c.sample",
          header_path:,
          marker: "ok",
        },
        observed,
      )
    end
  end

  def test_build_flags_include_header_directory_implementation_defines_and_extra_compiler_flags
    Dir.mktmpdir("milk-tea-raw-binding-build-flags") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, "")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: File.join(dir, "sample.mt"),
        header_candidates: [header_path],
        include_directives: ["sample.h"],
        implementation_defines: ["SAMPLE_IMPLEMENTATION"],
        compiler_flags: ["-DSAMPLE_TOOLING=1"],
      )

      assert_equal ["-I#{dir}", "-DSAMPLE_IMPLEMENTATION", "-DSAMPLE_TOOLING=1"], binding.build_flags
    end
  end

  def test_binding_exposes_extra_link_flags
    binding = MilkTea::RawBindings::Binding.new(
      name: "sample",
      module_name: "std.c.sample",
      binding_path: "/tmp/sample.mt",
      header_candidates: ["/tmp/sample.h"],
      link_flags: ["-L/tmp/sample", "-lsample_helper"],
    )

    assert_equal ["-L/tmp/sample", "-lsample_helper"], binding.link_flags
  end

  def test_prepare_hook_can_be_invoked
    invoked = []
    binding = MilkTea::RawBindings::Binding.new(
      name: "sample",
      module_name: "std.c.sample",
      binding_path: "/tmp/sample.mt",
      header_candidates: ["/tmp/sample.h"],
      prepare: ->(_binding, env:, cc:) { invoked << [env.fetch("MARKER"), cc] },
    )

    binding.prepare!(env: { "MARKER" => "ok", "CC" => "cc" }, cc: "clang")

    assert_equal [["ok", "clang"]], invoked
  end

  def test_binding_uses_vendored_library_for_link_flags_and_prepare
    invoked = []
    vendored_library = Object.new
    vendored_library.define_singleton_method(:link_flags) { |platform: nil| ["-L/tmp/vendored", "-lvendored"] }
    vendored_library.define_singleton_method(:prepare!) do |env:, cc:, platform: nil|
      invoked << [env.fetch("MARKER"), cc]
    end

    binding = MilkTea::RawBindings::Binding.new(
      name: "sample",
      module_name: "std.c.sample",
      binding_path: "/tmp/sample.mt",
      header_candidates: ["/tmp/sample.h"],
      vendored_library:,
      link_flags: ["-lsample"],
    )

    assert_equal ["-L/tmp/vendored", "-lvendored", "-lsample"], binding.link_flags

    binding.prepare!(env: { "MARKER" => "ok" }, cc: "clang")

    assert_equal [["ok", "clang"]], invoked
  end

  def test_prepare_hook_runs_before_vendored_library_prepare
    invoked = []
    vendored_library = Object.new
    vendored_library.define_singleton_method(:link_flags) { |platform: nil| [] }
    vendored_library.define_singleton_method(:prepare!) do |env:, cc:, platform: nil|
      invoked << [:vendored, env.fetch("MARKER"), cc]
    end

    binding = MilkTea::RawBindings::Binding.new(
      name: "sample",
      module_name: "std.c.sample",
      binding_path: "/tmp/sample.mt",
      header_candidates: ["/tmp/sample.h"],
      vendored_library:,
      prepare: lambda { |_binding, env:, cc:|
        invoked << [:binding, env.fetch("MARKER"), cc]
      },
    )

    binding.prepare!(env: { "MARKER" => "ok" }, cc: "clang")

    assert_equal [[:binding, "ok", "clang"], [:vendored, "ok", "clang"]], invoked
  end

  def test_write_and_check_prepare_vendored_libraries_before_resolving_headers
    Dir.mktmpdir("milk-tea-raw-binding-prepare-for-bindgen") do |dir|
      header_path = File.join(dir, "generated.h")
      binding_path = File.join(dir, "generated.mt")

      vendored_library = Object.new
      prepared = []
      vendored_library.define_singleton_method(:link_flags) { |platform: nil| [] }
      vendored_library.define_singleton_method(:prepare!) do |env:, cc:, platform: nil|
        prepared << [env.fetch("MARKER"), cc]
        File.write(header_path, "")
      end

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path:,
        header_candidates: [header_path],
        include_directives: ["generated.h"],
        vendored_library:,
      )

      generated = <<~MT
        # generated by mtc bindgen from #{header_path}
        external

        include "generated.h"
      MT
      File.write(binding_path, generated)

      with_singleton_method_override(MilkTea::Bindgen, :generate, ->(**) { generated }) do
        assert_equal header_path, binding.write!(env: { "MARKER" => "write", "CC" => "clang" })
        assert_equal header_path, binding.check!(env: { "MARKER" => "check", "CC" => "clang" })
      end

      assert_equal [["write", "clang"], ["check", "clang"]], prepared
    end
  end

  def test_registry_can_find_bindings_by_module_name
    registry = MilkTea::RawBindings::Registry.new([
      MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: "/tmp/sample.mt",
        header_candidates: ["/tmp/sample.h"],
      ),
    ])

    assert_equal "sample", registry.find_by_module_name("std.c.sample").name
    assert_nil registry.find_by_module_name("std.c.missing")
  end

  def test_check_ignores_generated_header_banner_path_and_validates_module
    Dir.mktmpdir("milk-tea-raw-binding-check") do |dir|
      header_path = File.join(dir, "sample.h")
      binding_path = File.join(dir, "sample.mt")
      File.write(header_path, "")
      File.write(binding_path, "# generated by mtc bindgen from /tmp/original.h\nexternal\n")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path:,
        header_candidates: [header_path],
        include_directives: ["sample.h"],
        env_var: "SAMPLE_HEADER",
      )

      checked_paths = []
  generated = "# generated by mtc bindgen from #{header_path}\nexternal\n"

      with_singleton_method_override(MilkTea::Bindgen, :generate, ->(**) { generated }) do
        with_singleton_method_override(MilkTea::ModuleLoader, :check_file, ->(path) { checked_paths << path }) do
          assert_equal header_path, binding.check!(env: { "SAMPLE_HEADER" => header_path })
        end
      end

      assert_equal [binding_path], checked_paths
    end
  end

  def test_check_reports_binding_drift_with_regeneration_task_name
    Dir.mktmpdir("milk-tea-raw-binding-drift") do |dir|
      header_path = File.join(dir, "sample.h")
      binding_path = File.join(dir, "sample.mt")
      File.write(header_path, "")
      File.write(binding_path, "# generated by mtc bindgen from /tmp/original.h\nexternal\n")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path:,
        header_candidates: [header_path],
        include_directives: ["sample.h"],
        env_var: "SAMPLE_HEADER",
      )

      with_singleton_method_override(MilkTea::Bindgen, :generate, ->(**) { "# generated by mtc bindgen from #{header_path}\nexternal\n    const CHANGED: int = 1\n" }) do
        error = assert_raises(MilkTea::RawBindings::Error) do
          binding.check!(env: { "SAMPLE_HEADER" => header_path })
        end

        assert_match(/#{Regexp.escape(binding_path)} is out of date for #{Regexp.escape(header_path)}/, error.message)
        assert_match(/Run `rake bindgen:sample` to regenerate it\./, error.message)
      end
    end
  end

  def with_singleton_method_override(object, method_name, implementation)
    singleton_class = class << object; self; end
    original_name = "__raw_bindings_original_#{method_name}__"
    original_defined = singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
    singleton_class.alias_method(original_name, method_name) if original_defined
    singleton_class.define_method(method_name) do |*args, **kwargs, &block|
      implementation.call(*args, **kwargs, &block)
    end
    yield
  ensure
    singleton_class.remove_method(method_name) if singleton_class.method_defined?(method_name)
    if original_defined
      singleton_class.alias_method(method_name, original_name)
      singleton_class.remove_method(original_name)
    end
  end
end
