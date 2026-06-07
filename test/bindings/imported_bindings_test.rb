# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaImportedBindingsTest < Minitest::Test
  def test_default_registry_exposes_checked_in_imported_bindings
    registry = MilkTea::ImportedBindings.default_registry

    assert_equal ["raymath", "raylib", "rlgl", "raygui", "sdl3", "gl", "glfw", "box2d", "cjson", "flecs", "libuv", "enet", "zstd", "sqlite3", "curl", "pcre2", "steamworks", "miniaudio"], registry.map(&:name)
    assert_equal "std.raylib", registry.fetch("raylib").module_name
    assert_equal "std.c.raylib", registry.fetch("raylib").raw_module_name
    assert_includes registry.fetch("raylib").binding_path, "/std/raylib.mt"
    assert_includes registry.fetch("raylib").policy_path, "/bindings/imported/raylib.binding.json"

    assert_equal "std.raymath", registry.fetch("raymath").module_name
    assert_equal "std.c.raymath", registry.fetch("raymath").raw_module_name
    assert_includes registry.fetch("raymath").binding_path, "/std/raymath.mt"
    assert_includes registry.fetch("raymath").policy_path, "/bindings/imported/raymath.binding.json"

    assert_equal "std.rlgl", registry.fetch("rlgl").module_name
    assert_equal "std.c.rlgl", registry.fetch("rlgl").raw_module_name
    assert_includes registry.fetch("rlgl").binding_path, "/std/rlgl.mt"
    assert_includes registry.fetch("rlgl").policy_path, "/bindings/imported/rlgl.binding.json"

    assert_equal "std.raygui", registry.fetch("raygui").module_name
    assert_equal "std.c.raygui", registry.fetch("raygui").raw_module_name
    assert_includes registry.fetch("raygui").binding_path, "/std/raygui.mt"
    assert_includes registry.fetch("raygui").policy_path, "/bindings/imported/raygui.binding.json"

    assert_equal "std.sdl3", registry.fetch("sdl3").module_name
    assert_equal "std.c.sdl3", registry.fetch("sdl3").raw_module_name
    assert_includes registry.fetch("sdl3").binding_path, "/std/sdl3.mt"
    assert_includes registry.fetch("sdl3").policy_path, "/bindings/imported/sdl3.binding.json"

    assert_equal "std.gl", registry.fetch("gl").module_name
    assert_equal "std.c.gl", registry.fetch("gl").raw_module_name
    assert_includes registry.fetch("gl").binding_path, "/std/gl.mt"
    assert_includes registry.fetch("gl").policy_path, "/bindings/imported/gl.binding.json"

    assert_equal "std.glfw", registry.fetch("glfw").module_name
    assert_equal "std.c.glfw", registry.fetch("glfw").raw_module_name
    assert_includes registry.fetch("glfw").binding_path, "/std/glfw.mt"
    assert_includes registry.fetch("glfw").policy_path, "/bindings/imported/glfw.binding.json"

    assert_equal "std.box2d", registry.fetch("box2d").module_name
    assert_equal "std.c.box2d", registry.fetch("box2d").raw_module_name
    assert_includes registry.fetch("box2d").binding_path, "/std/box2d.mt"
    assert_includes registry.fetch("box2d").policy_path, "/bindings/imported/box2d.binding.json"

    assert_equal "std.cjson", registry.fetch("cjson").module_name
    assert_equal "std.c.cjson", registry.fetch("cjson").raw_module_name
    assert_includes registry.fetch("cjson").binding_path, "/std/cjson.mt"
    assert_includes registry.fetch("cjson").policy_path, "/bindings/imported/cjson.binding.json"

    assert_equal "std.flecs", registry.fetch("flecs").module_name
    assert_equal "std.c.flecs", registry.fetch("flecs").raw_module_name
    assert_includes registry.fetch("flecs").binding_path, "/std/flecs.mt"
    assert_includes registry.fetch("flecs").policy_path, "/bindings/imported/flecs.binding.json"

    assert_equal "std.libuv", registry.fetch("libuv").module_name
    assert_equal "std.c.libuv", registry.fetch("libuv").raw_module_name
    assert_includes registry.fetch("libuv").binding_path, "/std/libuv.mt"
    assert_includes registry.fetch("libuv").policy_path, "/bindings/imported/libuv.binding.json"

    assert_equal "std.enet", registry.fetch("enet").module_name
    assert_equal "std.c.enet", registry.fetch("enet").raw_module_name
    assert_includes registry.fetch("enet").binding_path, "/std/enet.mt"
    assert_includes registry.fetch("enet").policy_path, "/bindings/imported/enet.binding.json"

    assert_equal "std.zstd", registry.fetch("zstd").module_name
    assert_equal "std.c.zstd", registry.fetch("zstd").raw_module_name
    assert_includes registry.fetch("zstd").binding_path, "/std/zstd.mt"
    assert_includes registry.fetch("zstd").policy_path, "/bindings/imported/zstd.binding.json"

    assert_equal "std.sqlite3", registry.fetch("sqlite3").module_name
    assert_equal "std.c.sqlite3", registry.fetch("sqlite3").raw_module_name
    assert_includes registry.fetch("sqlite3").binding_path, "/std/sqlite3.mt"
    assert_includes registry.fetch("sqlite3").policy_path, "/bindings/imported/sqlite3.binding.json"

    assert_equal "std.curl", registry.fetch("curl").module_name
    assert_equal "std.c.curl", registry.fetch("curl").raw_module_name
    assert_includes registry.fetch("curl").binding_path, "/std/curl.mt"
    assert_includes registry.fetch("curl").policy_path, "/bindings/imported/curl.binding.json"

    assert_equal "std.pcre2", registry.fetch("pcre2").module_name
    assert_equal "std.c.pcre2", registry.fetch("pcre2").raw_module_name
    assert_includes registry.fetch("pcre2").binding_path, "/std/pcre2.mt"
    assert_includes registry.fetch("pcre2").policy_path, "/bindings/imported/pcre2.binding.json"

    assert_equal "std.steamworks", registry.fetch("steamworks").module_name
    assert_equal "std.c.steamworks", registry.fetch("steamworks").raw_module_name
    assert_includes registry.fetch("steamworks").binding_path, "/std/steamworks.mt"
    assert_includes registry.fetch("steamworks").policy_path, "/bindings/imported/steamworks.binding.json"

  end

  def test_checked_in_libuv_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("libuv")

    assert_includes binding.check!, "/std/c/libuv.mt"

    source = File.read(binding.binding_path)
    refute_match(/^module /, source)
    assert_match(/^import std\.c\.libuv as c$/, source)
    assert_match(/^public type uv_loop_t = c\.uv_loop_t$/, source)
    assert_match(/^public const VERSION_MAJOR: int = c\.UV_VERSION_MAJOR$/, source)
    assert_match(/^public foreign function default_loop\(\) -> ptr\[uv_loop_t\]\? = c\.uv_default_loop$/, source)
    assert_match(/^public foreign function loop_close\(loop: ptr\[uv_loop_t\]\) -> int = c\.uv_loop_close$/, source)
    assert_match(/^public foreign function getaddrinfo\(loop: ptr\[uv_loop_t\], req: ptr\[uv_getaddrinfo_t\], getaddrinfo_cb: fn\(arg0: ptr\[uv_getaddrinfo_t\], arg1: int, arg2: ptr\[addrinfo\]\) -> void, node: cstr\?, service: cstr\?, hints: const_ptr\[addrinfo\]\?\) -> int = c\.uv_getaddrinfo$/, source)
    assert_match(/^public foreign function freeaddrinfo\(ai: ptr\[addrinfo\]\?\) -> void = c\.uv_freeaddrinfo$/, source)
    assert_match(/^public foreign function send_buffer_size\(handle: ptr\[uv_handle_t\], inout value: int\) -> int = c\.uv_send_buffer_size$/, source)
    assert_match(/^public foreign function fileno\(handle: const_ptr\[uv_handle_t\], out fd: uv_os_fd_t\) -> int = c\.uv_fileno$/, source)
    assert_match(/^public foreign function tcp_getsockname\(handle: const_ptr\[uv_tcp_t\], out name: sockaddr, inout namelen: int\) -> int = c\.uv_tcp_getsockname$/, source)
    assert_match(/^public foreign function udp_getsockname\(handle: const_ptr\[uv_udp_t\], out name: sockaddr, inout namelen: int\) -> int = c\.uv_udp_getsockname$/, source)
    assert_match(/^public foreign function tty_get_winsize\(arg_0: ptr\[uv_tty_t\], out width: int, out height: int\) -> int = c\.uv_tty_get_winsize$/, source)
    assert_match(/^public foreign function pipe_getsockname\(handle: const_ptr\[uv_pipe_t\], buffer: ptr\[char\], inout size: ptr_uint\) -> int = c\.uv_pipe_getsockname$/, source)
    assert_match(/^public foreign function os_getenv\(name: str as cstr, buffer: ptr\[char\], inout size: ptr_uint\) -> int = c\.uv_os_getenv$/, source)
    assert_match(/^public foreign function cpu_info\(out cpu_infos: ptr\[uv_cpu_info_t\]\?, out count: int\) -> int = c\.uv_cpu_info$/, source)
    assert_match(/^public foreign function interface_addresses\(out addresses: ptr\[uv_interface_address_t\]\?, out count: int\) -> int = c\.uv_interface_addresses$/, source)
    assert_match(/^public foreign function os_environ\(out envitems: ptr\[uv_env_item_t\]\?, out count: int\) -> int = c\.uv_os_environ$/, source)
    assert_match(/^public foreign function metrics_info\(loop: ptr\[uv_loop_t\], out metrics: uv_metrics_t\) -> int = c\.uv_metrics_info$/, source)
    assert_match(/^public foreign function fs_scandir_next\(req: ptr\[uv_fs_t\], out ent: uv_dirent_t\) -> int = c\.uv_fs_scandir_next$/, source)
    assert_match(/^public foreign function ip4_addr\(ip: str as cstr, port: int, out addr: sockaddr_in\) -> int = c\.uv_ip4_addr$/, source)
    assert_match(/^public foreign function dlsym\(lib: ptr\[uv_lib_t\], name: str as cstr, out ptr: ptr\[void\]\?\) -> int = c\.uv_dlsym$/, source)
    assert_match(/^public foreign function utf16_to_wtf8\(utf_16: const_ptr\[ushort\], utf_16_len: ptr_int, out wtf_8_ptr: ptr\[char\]\?, out wtf_8_len_ptr: ptr_uint\) -> int = c\.uv_utf16_to_wtf8$/, source)
  end

  def test_checked_in_sdl3_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("sdl3")

    assert_includes binding.check!, "/std/c/sdl3.mt"

    source = File.read(binding.binding_path)
    refute_match(/^import std\.mem\.arena as arena$/, source)
    refute_match(/^import std\.string as string$/, source)
    assert_match(/^public opaque Window = c"SDL_Window"$/, source)
    assert_match(/^public opaque Renderer = c"SDL_Renderer"$/, source)
    assert_match(/^public type MainFunc = c\.SDL_main_func$/, source)
    refute_match(/^public type Sint8 = /, source)
    refute_match(/^public type Uint8 = /, source)
    refute_match(/^public type Sint16 = /, source)
    refute_match(/^public type Uint16 = /, source)
    refute_match(/^public type Sint32 = /, source)
    refute_match(/^public type Uint32 = /, source)
    refute_match(/^public type Sint64 = /, source)
    refute_match(/^public type Uint64 = /, source)
    assert_match(/^public type InitFlags = c\.SDL_InitFlags$/, source)
    assert_match(/^public const INIT_VIDEO: uint = c\.SDL_INIT_VIDEO$/, source)
    assert_match(/^public foreign function malloc\(size: ptr_uint\) -> ptr\[void\]\? = c\.SDL_malloc$/, source)
    assert_match(/^public foreign function create_window\(title: str as cstr, w: int, h: int, flag_bits: ptr_uint\) -> Window\? = c\.SDL_CreateWindow$/, source)
    assert_match(/^public foreign function create_window_and_renderer\(title: str as cstr, width: int, height: int, window_flags: ptr_uint, out window: Window, out renderer: Renderer\) -> bool = c\.SDL_CreateWindowAndRenderer$/, source)
    assert_match(/^public foreign function run_app\(argc: int, argv: ptr\[ptr\[char\]\], main_function: MainFunc\) -> int = c\.SDL_RunApp\(argc, argv, main_function, null\)$/, source)
    assert_match(/^public foreign function set_app_metadata\(appname: str as cstr, appversion: str as cstr, appidentifier: str as cstr\) -> bool = c\.SDL_SetAppMetadata$/, source)
    assert_match(/^public foreign function init\(flag_bits: InitFlags\) -> bool = c\.SDL_Init$/, source)
    assert_match(/^public foreign function poll_event\(out event_: Event\) -> bool = c\.SDL_PollEvent$/, source)
    assert_match(/^public foreign function set_clipboard_text\(text: str as cstr\) -> bool = c\.SDL_SetClipboardText$/, source)
    assert_match(/^public foreign function get_window_size\(window: Window, out w: int, out h: int\) -> bool = c\.SDL_GetWindowSize$/, source)
    assert_match(/^public foreign function get_render_output_size\(renderer: Renderer, out w: int, out h: int\) -> bool = c\.SDL_GetRenderOutputSize$/, source)
    assert_match(/^public foreign function get_power_info\(out seconds: int, out percent: int\) -> PowerState = c\.SDL_GetPowerInfo$/, source)
    assert_match(/^public foreign function get_preferred_locales\(out count: int\) -> ptr\[ptr\[Locale\]\]\? = c\.SDL_GetPreferredLocales$/, source)
    assert_match(/^public foreign function get_displays\(count: ptr\[int\]\?\) -> ptr\[DisplayID\]\? = c\.SDL_GetDisplays$/, source)
    assert_match(/^public foreign function get_display_name\(display_id: uint\) -> cstr\? = c\.SDL_GetDisplayName$/, source)
    assert_match(/^public foreign function get_fullscreen_display_modes\(display_id: uint, count: ptr\[int\]\?\) -> ptr\[ptr\[DisplayMode\]\]\? = c\.SDL_GetFullscreenDisplayModes$/, source)
    assert_match(/^public foreign function get_desktop_display_mode\(display_id: uint\) -> const_ptr\[DisplayMode\]\? = c\.SDL_GetDesktopDisplayMode$/, source)
    assert_match(/^public foreign function get_current_display_mode\(display_id: uint\) -> const_ptr\[DisplayMode\]\? = c\.SDL_GetCurrentDisplayMode$/, source)
    assert_match(/^public foreign function get_window_icc_profile\(window: Window, size: ptr\[ptr_uint\]\) -> ptr\[void\]\? = c\.SDL_GetWindowICCProfile$/, source)
    assert_match(/^public foreign function get_windows\(count: ptr\[int\]\?\) -> ptr\[ptr\[Window\]\]\? = c\.SDL_GetWindows$/, source)
    assert_match(/^public foreign function convert_event_to_render_coordinates\(renderer: Renderer, inout event_: Event\) -> bool = c\.SDL_ConvertEventToRenderCoordinates$/, source)
    assert_match(/^public foreign function get_current_time\(out ticks: Time\) -> bool = c\.SDL_GetCurrentTime$/, source)
    assert_match(/^public foreign function time_to_date_time\(ticks: Time, out dt: DateTime, local_time: bool\) -> bool = c\.SDL_TimeToDateTime$/, source)
    assert_match(/^public foreign function render_points\(renderer: Renderer, points: span\[FPoint\]\) -> bool = c\.SDL_RenderPoints\(renderer, points\.data, int<-points\.len\)$/, source)
    assert_match(/^public foreign function render_lines\(renderer: Renderer, points: span\[FPoint\]\) -> bool = c\.SDL_RenderLines\(renderer, points\.data, int<-points\.len\)$/, source)
    assert_match(/^public foreign function render_rect\(renderer: Renderer, in rect: FRect as const_ptr\[FRect\]\) -> bool = c\.SDL_RenderRect$/, source)
    assert_match(/^public foreign function render_rects\(renderer: Renderer, rects: span\[FRect\]\) -> bool = c\.SDL_RenderRects\(renderer, rects\.data, int<-rects\.len\)$/, source)
    assert_match(/^public foreign function render_fill_rect\(renderer: Renderer, in rect: FRect as const_ptr\[FRect\]\) -> bool = c\.SDL_RenderFillRect$/, source)
    assert_match(/^public foreign function render_fill_rects\(renderer: Renderer, rects: span\[FRect\]\) -> bool = c\.SDL_RenderFillRects\(renderer, rects\.data, int<-rects\.len\)$/, source)
    assert_match(/^public foreign function render_debug_text\(renderer: Renderer, x: float, y: float, text: str as cstr\) -> bool = c\.SDL_RenderDebugText$/, source)
    assert_match(/^public foreign function load_png\(file: str as cstr\) -> ptr\[Surface\]\? = c\.SDL_LoadPNG$/, source)
    assert_match(/^public foreign function gl_get_proc_address\(proc_: str as cstr\) -> FunctionPointer\? = c\.SDL_GL_GetProcAddress$/, source)
    assert_match(/^public foreign function egl_get_proc_address\(proc_: str as cstr\) -> FunctionPointer\? = c\.SDL_EGL_GetProcAddress$/, source)
    assert_match(/^public foreign function gl_get_current_window\(\) -> Window\? = c\.SDL_GL_GetCurrentWindow$/, source)
    assert_match(/^public foreign function gl_get_current_context\(\) -> GLContext\? = c\.SDL_GL_GetCurrentContext$/, source)
    assert_match(/^public foreign function load_object\(sofile: str as cstr\) -> ptr\[SharedObject\]\? = c\.SDL_LoadObject$/, source)
    assert_match(/^public foreign function load_function\(handle: ptr\[SharedObject\], name: str as cstr\) -> FunctionPointer\? = c\.SDL_LoadFunction$/, source)
    assert_match(/^public foreign function get_keyboards\(count: ptr\[int\]\?\) -> ptr\[KeyboardID\]\? = c\.SDL_GetKeyboards$/, source)
    assert_match(/^public foreign function get_keyboard_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetKeyboardNameForID$/, source)
    assert_match(/^public foreign function get_mice\(count: ptr\[int\]\?\) -> ptr\[MouseID\]\? = c\.SDL_GetMice$/, source)
    assert_match(/^public foreign function get_mouse_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetMouseNameForID$/, source)
    assert_match(/^public foreign function get_touch_devices\(count: ptr\[int\]\?\) -> ptr\[TouchID\]\? = c\.SDL_GetTouchDevices$/, source)
    assert_match(/^public foreign function get_touch_device_name\(touch_id: ptr_uint\) -> cstr\? = c\.SDL_GetTouchDeviceName$/, source)
    assert_match(/^public foreign function get_touch_fingers\(touch_id: ptr_uint, count: ptr\[int\]\) -> ptr\[ptr\[Finger\]\]\? = c\.SDL_GetTouchFingers$/, source)
    assert_match(/^public foreign function get_sensors\(count: ptr\[int\]\?\) -> ptr\[SensorID\]\? = c\.SDL_GetSensors$/, source)
    assert_match(/^public foreign function get_sensor_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetSensorNameForID$/, source)
    assert_match(/^public foreign function open_sensor\(instance_id: uint\) -> ptr\[Sensor\]\? = c\.SDL_OpenSensor$/, source)
    assert_match(/^public foreign function get_sensor_from_id\(instance_id: uint\) -> ptr\[Sensor\]\? = c\.SDL_GetSensorFromID$/, source)
    assert_match(/^public foreign function get_sensor_name\(sensor: ptr\[Sensor\]\) -> cstr\? = c\.SDL_GetSensorName$/, source)
    assert_match(/^public foreign function get_joysticks\(out count: int\) -> ptr\[JoystickID\]\? = c\.SDL_GetJoysticks$/, source)
    assert_match(/^public foreign function get_joystick_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetJoystickNameForID$/, source)
    assert_match(/^public foreign function get_joystick_name\(joystick: ptr\[Joystick\]\) -> cstr\? = c\.SDL_GetJoystickName$/, source)
    assert_match(/^public foreign function get_joystick_path_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetJoystickPathForID$/, source)
    assert_match(/^public foreign function get_joystick_from_player_index\(player_index: int\) -> ptr\[Joystick\]\? = c\.SDL_GetJoystickFromPlayerIndex$/, source)
    assert_match(/^public foreign function get_joystick_path\(joystick: ptr\[Joystick\]\) -> cstr\? = c\.SDL_GetJoystickPath$/, source)
    assert_match(/^public foreign function get_joystick_serial\(joystick: ptr\[Joystick\]\) -> cstr\? = c\.SDL_GetJoystickSerial$/, source)
    assert_match(/^public foreign function get_gamepad_mappings\(count: ptr\[int\]\) -> ptr\[ptr\[char\]\]\? = c\.SDL_GetGamepadMappings$/, source)
    assert_match(/^public foreign function get_gamepads\(out count: int\) -> ptr\[JoystickID\]\? = c\.SDL_GetGamepads$/, source)
    assert_match(/^public foreign function get_gamepad_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetGamepadNameForID$/, source)
    assert_match(/^public foreign function get_gamepad_name\(gamepad: ptr\[Gamepad\]\) -> cstr\? = c\.SDL_GetGamepadName$/, source)
    assert_match(/^public foreign function get_gamepad_path_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetGamepadPathForID$/, source)
    assert_match(/^public foreign function get_gamepad_path\(gamepad: ptr\[Gamepad\]\) -> cstr\? = c\.SDL_GetGamepadPath$/, source)
    refute_match(/^public def cstr_as_str\(text: cstr\) -> str:$/, source)
    refute_match(/^public def free_chars\(text: ptr\[char\]\?\) -> void:$/, source)
    refute_match(/^public def preferred_locale_at\(locales: ptr\[ptr\[Locale\]\], index: int\) -> ptr\[Locale\]\?:$/, source)
    refute_match(/^public def free_preferred_locales\(locales: ptr\[ptr\[Locale\]\]\?\) -> void:$/, source)
    refute_match(/^public def preferred_locale_string\(locale: ptr\[Locale\]\) -> string\.String:$/, source)
    refute_match(/^public def render_debug_text_str\(renderer: ptr\[Renderer\], x: float, y: float, text: str\) -> bool:$/, source)
    assert_match(/^public foreign function quit\(\) -> void = c\.SDL_Quit$/, source)
  end

  def test_checked_in_gl_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("gl")

    assert_includes binding.check!, "/std/c/gl.mt"

    source = File.read(binding.binding_path)
    refute_match(/^module /, source)
    assert_match(/^import std\.c\.gl as c$/, source)
    assert_match(/^public opaque Sync = c"struct __GLsync"$/, source)
    assert_match(/^public type GLuint = c\.GLuint$/, source)
    assert_match(/^public const COLOR_BUFFER_BIT: int = c\.GL_COLOR_BUFFER_BIT$/, source)
    assert_match(/^public foreign function use_glfw_loader\(\) -> void = c\.mt_gl_use_glfw_loader$/, source)
    assert_match(/^public foreign function use_raylib_loader\(\) -> void = c\.mt_gl_use_raylib_loader$/, source)
    assert_match(/^public foreign function clear\(mask: uint\) -> void = c\.glClear$/, source)
    assert_match(/^public foreign function create_shader\(type_: uint\) -> GLuint = c\.glCreateShader$/, source)
    assert_match(/^public foreign function map_buffer\(target: uint, access: uint\) -> ptr\[void\]\? = c\.glMapBuffer$/, source)
    assert_match(/^public foreign function get_uniform_subroutine_uint_values\(shadertype: uint, location: int, params: ptr\[GLuint\]\) -> void = c\.glGetUniformSubroutineuiv$/, source)
    assert_match(/^public foreign function uniform_subroutines_uint_values\(shadertype: uint, count: int, indices: const_ptr\[GLuint\]\) -> void = c\.glUniformSubroutinesuiv$/, source)
    assert_match(/^public foreign function get_vertex_array_indexed_int_values\(vaobj: uint, index: uint, pname: uint, param: ptr\[GLint\]\) -> void = c\.glGetVertexArrayIndexediv$/, source)
    assert_match(/^public foreign function get_n_uniform_double_values\(program: uint, location: int, buf_size: int, params: ptr\[GLdouble\]\) -> void = c\.glGetnUniformdv$/, source)
    assert_match(/^public foreign function get_n_uniform_float_values\(program: uint, location: int, buf_size: int, params: ptr\[GLfloat\]\) -> void = c\.glGetnUniformfv$/, source)
    assert_match(/^public foreign function get_n_uniform_int_values\(program: uint, location: int, buf_size: int, params: ptr\[GLint\]\) -> void = c\.glGetnUniformiv$/, source)
    assert_match(/^public foreign function get_n_uniform_uint_values\(program: uint, location: int, buf_size: int, params: ptr\[GLuint\]\) -> void = c\.glGetnUniformuiv$/, source)
    assert_match(/^public foreign function scissor_array_values\(first: uint, count: int, v: const_ptr\[GLint\]\) -> void = c\.glScissorArrayv$/, source)
    assert_match(/^public foreign function scissor_indexed_values\(index: uint, v: const_ptr\[GLint\]\) -> void = c\.glScissorIndexedv$/, source)
    assert_match(/^public foreign function viewport_array_values\(first: uint, count: int, v: const_ptr\[GLfloat\]\) -> void = c\.glViewportArrayv$/, source)
    assert_match(/^public foreign function tex_image_2d_multisample\(/, source)
    refute_match(/^public foreign function begin\(/, source)
  end

  def test_checked_in_glfw_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("glfw")

    assert_includes binding.check!, "/std/c/glfw.mt"

    source = File.read(binding.binding_path)
    refute_match(/^module /, source)
    assert_match(/^import std\.c\.glfw as c$/, source)
    assert_match(/^public opaque Window = c"GLFWwindow"$/, source)
    assert_match(/^public const VERSION_MAJOR: int = c\.GLFW_VERSION_MAJOR$/, source)
    assert_match(/^public foreign function init\(\) -> bool = c\.glfwInit\(\) != 0$/, source)
    assert_match(/^public foreign function create_window\(width: int, height: int, title: str as cstr, monitor: Monitor\?, share: Window\?\) -> Window\? = c\.glfwCreateWindow$/, source)
    assert_match(/^public foreign function make_context_current\(window: Window\?\) -> void = c\.glfwMakeContextCurrent$/, source)
    assert_match(/^public foreign function get_proc_address\(procname: str as cstr\) -> GLProc\? = c\.glfwGetProcAddress$/, source)
  end

  def test_checked_in_enet_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("enet")

    assert_includes binding.check!, "/std/c/enet.mt"

    source = File.read(binding.binding_path)
    refute_match(/^module /, source)
    assert_match(/^import std\.c\.enet as c$/, source)
    refute_match(/^public type enet_uint32 = c\.enet_uint32$/, source)
    assert_match(/^public type Host = c\.ENetHost$/, source)
    assert_match(/^public const VERSION_MAJOR: int = c\.ENET_VERSION_MAJOR$/, source)
    assert_match(/^public foreign function initialize\(\) -> int = c\.enet_initialize$/, source)
    assert_match(/^public foreign function deinitialize\(\) -> void = c\.enet_deinitialize$/, source)
    assert_match(/^public foreign function time_get\(\) -> uint = c\.enet_time_get$/, source)
    assert_match(/^public foreign function packet_create\(data: const_ptr\[void\], data_length: ptr_uint, flag_bits: PacketFlag\) -> ptr\[Packet\]\? = c\.enet_packet_create$/, source)
  end

  def test_checked_in_box2d_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("box2d")

    assert_includes binding.check!, "/std/c/box2d.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.c\.box2d as c$/, source)
    assert_match(/^public type WorldId = c\.b2WorldId$/, source)
    assert_match(/^public type Vec2 = c\.b2Vec2$/, source)
    assert_match(/^public type DebugDraw = c\.b2DebugDraw$/, source)
    assert_match(/^public const b2_nullWorldId: WorldId = c\.b2_nullWorldId$/, source)
    assert_match(/^public foreign function default_world_def\(\) -> WorldDef = c\.b2DefaultWorldDef$/, source)
    assert_match(/^public foreign function default_body_def\(\) -> BodyDef = c\.b2DefaultBodyDef$/, source)
    assert_match(/^public foreign function default_shape_def\(\) -> ShapeDef = c\.b2DefaultShapeDef$/, source)
    assert_match(/^public foreign function make_box\(half_width: float, half_height: float\) -> Polygon = c\.b2MakeBox$/, source)
    assert_match(/^public foreign function create_world\(in world_def: WorldDef\) -> WorldId = c\.b2CreateWorld$/, source)
    assert_match(/^public foreign function world_step\(world_id: WorldId, time_step: float, sub_step_count: int\) -> void = c\.b2World_Step$/, source)
    assert_match(/^public foreign function create_body\(world_id: WorldId, in body_def: BodyDef\) -> BodyId = c\.b2CreateBody$/, source)
    assert_match(/^public foreign function create_polygon_shape\(body_id: BodyId, in shape_def: ShapeDef, in polygon: Polygon\) -> ShapeId = c\.b2CreatePolygonShape$/, source)
    assert_match(/^public foreign function world_draw\(world_id: WorldId, inout draw: DebugDraw\) -> void = c\.b2World_Draw$/, source)
  end

  def test_checked_in_cjson_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("cjson")

    assert_includes binding.check!, "/std/c/cjson.mt"

    source = File.read(binding.binding_path)
    refute_match(/^module /, source)
    assert_match(/^import std\.c\.cjson as c$/, source)
    assert_match(/^public type JSON = c\.cJSON$/, source)
    assert_match(/^public type Hooks = c\.cJSON_Hooks$/, source)
    assert_match(/^public type Bool = c\.cJSON_bool$/, source)
    assert_match(/^public const VERSION_MAJOR: int = c\.CJSON_VERSION_MAJOR$/, source)
    assert_match(/^public foreign function parse\(value: str as cstr\) -> ptr\[JSON\]\? = c\.cJSON_Parse$/, source)
    assert_match(/^public foreign function parse_with_length\(value: str as cstr, buffer_length: ptr_uint\) -> ptr\[JSON\]\? = c\.cJSON_ParseWithLength$/, source)
    assert_match(/^public foreign function get_object_item\(object: const_ptr\[JSON\], string: str as cstr\) -> ptr\[JSON\]\? = c\.cJSON_GetObjectItem$/, source)
    assert_match(/^public foreign function add_string_to_object\(object: ptr\[JSON\], name: str as cstr, string: str as cstr\) -> ptr\[JSON\]\? = c\.cJSON_AddStringToObject$/, source)
    refute_match(/^public foreign function cjson_parse\(/, source)
    refute_match(/^public foreign function malloc\(/, source)
    refute_match(/^public foreign function free\(/, source)
  end

  def test_checked_in_curl_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("curl")

    assert_includes binding.check!, "/std/c/curl.mt"

    source = File.read(binding.binding_path)
    refute_match(/^module /, source)
    assert_match(/^import std\.c\.curl as c$/, source)
    assert_match(/^public type EasyHandle = c\.CURL$/, source)
    assert_match(/^public type Code = c\.CURLcode$/, source)
    assert_match(/^public type CurlOption = c\.CURLoption$/, source)
    assert_match(/^public type Info = c\.CURLINFO$/, source)
    assert_match(/^public const CURLE_ALREADY_COMPLETE: int = c\.CURLE_ALREADY_COMPLETE$/, source)
    assert_match(/^public const CURL_GLOBAL_NOTHING: int = c\.CURL_GLOBAL_NOTHING$/, source)
    assert_match(/^public foreign function global_init\(flag_bits: ptr_int\) -> Code = c\.curl_global_init$/, source)
    assert_match(/^public foreign function global_cleanup\(\) -> void = c\.curl_global_cleanup$/, source)
    assert_match(/^public foreign function easy_init\(\) -> ptr\[EasyHandle\]\? = c\.curl_easy_init$/, source)
    assert_match(/^public foreign function easy_perform\(curl: ptr\[EasyHandle\]\) -> Code = c\.curl_easy_perform$/, source)
    assert_match(/^public foreign function easy_cleanup\(curl: ptr\[EasyHandle\]\) -> void = c\.curl_easy_cleanup$/, source)
    assert_match(/^public foreign function easy_strerror\(error: Code\) -> cstr = c\.curl_easy_strerror$/, source)
    assert_match(/^public foreign function slist_append\(list: ptr\[SList\], data: str as cstr\) -> ptr\[SList\] = c\.curl_slist_append$/, source)
    assert_match(/^public foreign function slist_free_all\(list: ptr\[SList\]\) -> void = c\.curl_slist_free_all$/, source)
    refute_match(/^public foreign function easy_setopt\(/, source)
    refute_match(/^public foreign function easy_getinfo\(/, source)
  end

  def test_checked_in_pcre2_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("pcre2")

    assert_includes binding.check!, "/std/c/pcre2.mt"

    source = File.read(binding.binding_path)
    refute_match(/^module /, source)
    assert_match(/^import std\.c\.pcre2 as c$/, source)
    assert_match(/^public type Code = c\.pcre2_code_8$/, source)
    assert_match(/^public type MatchData = c\.pcre2_match_data_8$/, source)
    assert_match(/^public const CASELESS: uint = c\.PCRE2_CASELESS$/, source)
    assert_match(/^public foreign function compile_bytes\(pattern: span\[ubyte\], options: uint, out error_code: int, out error_offset: ptr_uint, compile_context: ptr\[CompileContext\]\) -> ptr\[Code\]\? = c\.pcre2_compile_8\(pattern\.data, ptr_uint<-pattern\.len, options, error_code, error_offset, compile_context\)$/, source)
    assert_match(/^public foreign function match_bytes\(code: const_ptr\[Code\], subject: span\[ubyte\], start_offset: ptr_uint, options: uint, match_data: ptr\[MatchData\], match_context: ptr\[MatchContext\]\) -> int = c\.pcre2_match_8\(code, subject\.data, ptr_uint<-subject\.len, start_offset, options, match_data, match_context\)$/, source)
    assert_match(/^public foreign function get_error_message\(error_code: int, buffer: span\[ubyte\]\) -> int = c\.pcre2_get_error_message_8\(error_code, buffer\.data, ptr_uint<-buffer\.len\)$/, source)
    refute_match(/^public type general_context_16 = /, source)
    refute_match(/^public foreign function compile_16\(/, source)
  end

  def test_generate_rejects_extra_source_policy_escape_hatch
    Dir.mktmpdir("milk-tea-imported-binding-extra-source") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        external function sample() -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {},
        constants: {},
        functions: {
          include: ["sample"],
        },
        extra_source: [
          "public function helper() -> void:",
          "    return",
        ],
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      error = assert_raises(MilkTea::ImportedBindings::Error) do
        binding.generate(module_roots: [dir])
      end

      assert_match(/extra_source .* no longer supported/, error.message)
    end
  end

  def test_generate_replays_raw_module_imports_needed_by_exposed_types
    Dir.mktmpdir("milk-tea-imported-binding-raw-imports") do |dir|
      dep_path = File.join(dir, "std", "c", "dep.mt")
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(dep_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(dep_path, <<~MT)
        external

        opaque Thing = c"Thing"
      MT

      File.write(raw_path, <<~MT)
        external

        import std.c.dep as dep

        external function sample(arg: ptr[dep.Thing]) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {},
        constants: {},
        functions: {
          include: ["sample"],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      source = binding.generate(module_roots: [dir])

      assert_match(/^import std\.c\.sample as c$/, source)
      assert_match(/^import std\.c\.dep as dep$/, source)
      assert_match(/^public foreign function sample\(arg: ptr\[dep\.Thing\]\) -> void = c\.sample$/, source)

      File.write(binding_path, source)
      assert_includes binding.check!(module_roots: [dir]), "/std/c/sample.mt"
    end
  end

  def test_checked_in_raylib_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("raylib")

    assert_includes binding.check!, "/std/c/raylib.mt"

    raw_source = File.read(File.expand_path("../../std/c/raylib.mt", __dir__))
    source = File.read(binding.binding_path)
    assert_match(/^type TraceLogCallback = /, raw_source)
    assert_match(/^external function SetTraceLogCallback\(/, raw_source)
    refute_match(/^public type __va_list_tag = /, source)
    refute_match(/^public type va_list = /, source)
    refute_match(/^public type TraceLogCallback = /, source)
    refute_match(/^public foreign function set_trace_log_callback\(/, source)
    assert_match(/^import std\.c\.raylib as c$/, source)
    assert_match(/^import std\.raymath as math$/, source)
    refute_match(/^import std\.bytes as bytes$/, source)
    refute_match(/^import std\.maybe as maybe$/, source)
    refute_match(/^import std\.vec as vec$/, source)
    refute_match(/^import std\.string as string$/, source)
    refute_match(/^import std\.str as text$/, source)
    assert_match(/^public foreign function load_shader\(vs_file_name: cstr\?, fs_file_name: cstr\?\) -> Shader = c\.LoadShader$/, source)
    assert_match(/^public foreign function load_shader_from_memory\(vs_code: cstr\?, fs_code: cstr\?\) -> Shader = c\.LoadShaderFromMemory$/, source)
    assert_match(/^public foreign function set_shader_value\[T\]\(shader: Shader, loc_index: int, in value: T as const_ptr\[void\], uniform_type: int\) -> void = c\.SetShaderValue$/, source)
    assert_match(/^public foreign function set_shader_value_v\[T\]\(shader: Shader, loc_index: int, value: ptr\[T\] as const_ptr\[void\], uniform_type: int, count: int\) -> void = c\.SetShaderValueV$/, source)
    assert_match(/^public foreign function load_image\(file_name: str as cstr\) -> Image = c\.LoadImage$/, source)
    assert_match(/^public foreign function load_image_raw\(file_name: str as cstr, width: int, height: int, format: int, header_size: int\) -> Image = c\.LoadImageRaw$/, source)
    assert_match(/^public foreign function load_image_anim\(file_name: str as cstr, out frames: int\) -> Image = c\.LoadImageAnim$/, source)
    assert_match(/^public foreign function load_image_from_memory\(file_type: str as cstr, file_data: span\[ubyte\]\) -> Image = c\.LoadImageFromMemory\(file_type, file_data\.data, int<-file_data\.len\)$/, source)
    assert_match(/^public foreign function set_window_title\(title: str as cstr\) -> void = c\.SetWindowTitle$/, source)
    assert_match(/^public foreign function get_monitor_name\(monitor: int\) -> cstr = c\.GetMonitorName$/, source)
    assert_match(/^public foreign function get_clipboard_text\(\) -> cstr = c\.GetClipboardText$/, source)
    assert_match(/^public foreign function get_working_directory\(\) -> cstr = c\.GetWorkingDirectory$/, source)
    assert_match(/^public foreign function get_application_directory\(\) -> cstr = c\.GetApplicationDirectory$/, source)
    assert_match(/^public foreign function get_file_length\(file_name: str as cstr\) -> int = c\.GetFileLength$/, source)
    assert_match(/^public foreign function get_file_mod_time\(file_name: str as cstr\) -> ptr_int = c\.GetFileModTime$/, source)
    assert_match(/^public foreign function get_file_extension\(file_name: str as cstr\) -> cstr = c\.GetFileExtension$/, source)
    assert_match(/^public foreign function get_file_name\(file_path: str as cstr\) -> cstr = c\.GetFileName$/, source)
    assert_match(/^public foreign function get_file_name_without_ext\(file_path: str as cstr\) -> cstr = c\.GetFileNameWithoutExt$/, source)
    assert_match(/^public foreign function get_directory_path\(file_path: str as cstr\) -> cstr = c\.GetDirectoryPath$/, source)
    assert_match(/^public foreign function get_prev_directory_path\(dir_path: str as cstr\) -> cstr = c\.GetPrevDirectoryPath$/, source)
    assert_match(/^public foreign function begin_mode_2d\(camera: Camera2D\) -> void = c\.BeginMode2D$/, source)
    assert_match(/^public foreign function end_mode_2d\(\) -> void = c\.EndMode2D$/, source)
    assert_match(/^public foreign function begin_mode_3d\(camera: Camera3D\) -> void = c\.BeginMode3D$/, source)
    assert_match(/^public foreign function end_mode_3d\(\) -> void = c\.EndMode3D$/, source)
    assert_match(/^public foreign function get_world_to_screen_2d\(position: Vector2, camera: Camera2D\) -> Vector2 = c\.GetWorldToScreen2D$/, source)
    assert_match(/^public foreign function get_screen_to_world_2d\(position: Vector2, camera: Camera2D\) -> Vector2 = c\.GetScreenToWorld2D$/, source)
    assert_match(/^public foreign function get_camera_matrix_2d\(camera: Camera2D\) -> Matrix = c\.GetCameraMatrix2D$/, source)
    assert_match(/^public foreign function make_directory\(dir_path: str as cstr\) -> int = c\.MakeDirectory$/, source)
    assert_match(/^public foreign function change_directory\(dir_path: str as cstr\) -> bool = c\.ChangeDirectory$/, source)
    assert_match(/^public foreign function is_path_file\(path: str as cstr\) -> bool = c\.IsPathFile$/, source)
    assert_match(/^public foreign function is_file_name_valid\(file_name: str as cstr\) -> bool = c\.IsFileNameValid$/, source)
    assert_match(/^public foreign function load_directory_files\(dir_path: str as cstr\) -> FilePathList = c\.LoadDirectoryFiles$/, source)
    assert_match(/^public foreign function load_directory_files_ex\(base_path: str as cstr, filter: str as cstr, scan_subdirs: bool\) -> FilePathList = c\.LoadDirectoryFilesEx$/, source)
    assert_match(/^public foreign function get_directory_file_count\(dir_path: str as cstr\) -> uint = c\.GetDirectoryFileCount$/, source)
    assert_match(/^public foreign function get_directory_file_count_ex\(base_path: str as cstr, filter: str as cstr, scan_subdirs: bool\) -> uint = c\.GetDirectoryFileCountEx$/, source)
    assert_match(/^public foreign function get_key_name\(key: int\) -> cstr = c\.GetKeyName$/, source)
    assert_match(/^public foreign function get_gamepad_name\(gamepad: int\) -> cstr = c\.GetGamepadName$/, source)
    assert_match(/^public foreign function export_image\(image: Image, file_name: str as cstr\) -> bool = c\.ExportImage$/, source)
    assert_match(/^public foreign function update_texture\[T\]\(texture: Texture, pixels: ptr\[T\] as const_ptr\[void\]\) -> void = c\.UpdateTexture$/, source)
    assert_match(/^public foreign function update_mesh_buffer\[T\]\(mesh: Mesh, index: int, data: ptr\[T\] as const_ptr\[void\], data_size: int, offset: int\) -> void = c\.UpdateMeshBuffer$/, source)
    assert_match(/^public foreign function update_audio_stream\[T\]\(stream: AudioStream, data: ptr\[T\] as const_ptr\[void\], frame_count: int\) -> void = c\.UpdateAudioStream$/, source)
    assert_match(/^public foreign function draw_spline_linear_ptr\(points: const_ptr\[Vector2\], point_count: int, thick: float, color: Color\) -> void = c\.DrawSplineLinear$/, source)
    assert_match(/^public foreign function load_file_data\(file_name: str as cstr, out data_size: int\) -> ptr\[ubyte\]\? = c\.LoadFileData$/, source)
    assert_match(/^public foreign function unload_file_data\(consuming data: ptr\[ubyte\]\) -> void = c\.UnloadFileData$/, source)
    assert_match(/^public foreign function load_file_text\(file_name: str as cstr\) -> ptr\[char\]\? = c\.LoadFileText$/, source)
    assert_match(/^public foreign function unload_file_text\(text: ptr\[char\]\) -> void = c\.UnloadFileText$/, source)
    assert_match(/^public foreign function load_utf8\(codepoints: const_ptr\[int\], length: int\) -> ptr\[char\]\? = c\.LoadUTF8$/, source)
    assert_match(/^public foreign function unload_utf8\(text: ptr\[char\]\) -> void = c\.UnloadUTF8$/, source)
    assert_match(/^public foreign function image_format\(inout image: Image, new_format: int\) -> void = c\.ImageFormat$/, source)
    assert_match(/^public foreign function image_kernel_convolution\(inout image: Image, kernel: span\[float\]\) -> void = c\.ImageKernelConvolution\(image, kernel\.data, int<-kernel\.len\)$/, source)
    assert_match(/^public foreign function image_draw_text_ex\(inout dst: Image, font: Font, text: str as cstr, position: Vector2, font_size: float, spacing: float, tint: Color\) -> void = c\.ImageDrawTextEx$/, source)
    assert_match(/^public foreign function draw_text_ex\(font: Font, text: str as cstr, position: Vector2, font_size: float, spacing: float, tint: Color\) -> void = c\.DrawTextEx$/, source)
    assert_match(/^public foreign function load_font\(file_name: str as cstr\) -> Font = c\.LoadFont$/, source)
    assert_match(/^public foreign function load_font_ex\(file_name: str as cstr, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int\) -> Font = c\.LoadFontEx$/, source)
    assert_match(/^public foreign function load_sound\(file_name: str as cstr\) -> Sound = c\.LoadSound$/, source)
    assert_match(/^public foreign function load_wave_from_memory\(file_type: str as cstr, file_data: span\[ubyte\]\) -> Wave = c\.LoadWaveFromMemory\(file_type, file_data\.data, int<-file_data\.len\)$/, source)
    assert_match(/^public foreign function set_clipboard_text\(text: str as cstr\) -> void = c\.SetClipboardText$/, source)
    assert_match(/^public foreign function draw_line_3d\(start_pos: Vector3, end_pos: Vector3, color: Color\) -> void = c\.DrawLine3D$/, source)
    assert_match(/^public foreign function draw_point_3d\(position: Vector3, color: Color\) -> void = c\.DrawPoint3D$/, source)
    assert_match(/^public foreign function draw_circle_3d\(center: Vector3, radius: float, rotation_axis: Vector3, rotation_angle: float, color: Color\) -> void = c\.DrawCircle3D$/, source)
    assert_match(/^public foreign function draw_triangle_3d\(v1: Vector3, v2: Vector3, v3: Vector3, color: Color\) -> void = c\.DrawTriangle3D$/, source)
    assert_match(/^public foreign function load_font_from_memory\(file_type: str as cstr, file_data: const_ptr\[ubyte\], data_size: int, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int\) -> Font = c\.LoadFontFromMemory$/, source)
    assert_match(/^public foreign function gen_texture_mipmaps\(inout texture: Texture2D\) -> void = c\.GenTextureMipmaps$/, source)
    assert_match(/^public foreign function load_font_data\(file_data: const_ptr\[ubyte\], data_size: int, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int, kind: FontType, out glyph_count: int\) -> ptr\[GlyphInfo\] = c\.LoadFontData$/, source)
    assert_match(/^public foreign function gen_image_font_atlas\(glyphs: const_ptr\[GlyphInfo\], out glyph_recs: ptr\[Rectangle\], glyph_count: int, font_size: int, padding: int, pack_method: int\) -> Image = c\.GenImageFontAtlas$/, source)
    assert_match(/^public foreign function load_codepoints\(text: str as cstr, out count: int\) -> ptr\[int\]\? = c\.LoadCodepoints$/, source)
    assert_match(/^public foreign function unload_codepoints\(codepoints: ptr\[int\]\) -> void = c\.UnloadCodepoints$/, source)
    assert_match(/^public foreign function codepoint_to_utf8\(codepoint: int, out utf_8_size: int\) -> cstr = c\.CodepointToUTF8$/, source)
    assert_match(/^public foreign function text_subtext\(text: str as cstr, position: int, length: int\) -> cstr = c\.TextSubtext$/, source)
    assert_match(/^public foreign function text_remove_spaces\(text: str as cstr\) -> cstr = c\.TextRemoveSpaces$/, source)
    assert_match(/^public foreign function load_fragment_shader\(fs_file_name: str as cstr\) -> Shader = c\.LoadShader\(null, fs_file_name\)$/, source)
    assert_match(/extending Color:.*?public function alpha\(alpha: float\) -> Color:\n\s+return color_alpha\(this, alpha\)/m, source)
    assert_match(/extending Color:.*?public static function from_hsv\(hue: float, saturation: float, value: float\) -> Color:\n\s+return color_from_hsv\(hue, saturation, value\)/m, source)
    assert_match(/extending Image:.*?public static function text\(text: str, font_size: int, color: Color\) -> Image:\n\s+return image_text\(text, font_size, color\)/m, source)
    assert_match(/extending Image:.*?public editable function mipmaps\(\) -> void:\n\s+image_mipmaps\(this\)/m, source)
    assert_match(/extending Wave:.*?public function copy\(\) -> Wave:\n\s+return wave_copy\(this\)/m, source)
    assert_match(/extending ptr\[Wave\]:.*?public function crop\(init_frame: int, final_frame: int\) -> void:\n\s+wave_crop\(this, init_frame, final_frame\).*?public function format\(sample_rate: int, sample_size: int, channels: int\) -> void:\n\s+wave_format\(this, sample_rate, sample_size, channels\)/m, source)
    assert_match(/extending Vector2:.*?public static function zero\(\) -> Vector2:\n\s+return math\.vector2_zero\(\).*?public function add\(v2: Vector2\) -> Vector2:\n\s+return math\.vector2_add\(this, v2\)/m, source)
    assert_match(/extending Vector3:.*?public function to_float_v\(\) -> array\[float, 3\]:\n\s+return math\.vector3_to_float_v\(this\)/m, source)
    assert_match(/extending Matrix:.*?public function determinant\(\) -> float:\n\s+return math\.matrix_determinant\(this\).*?public static function identity\(\) -> Matrix:\n\s+return math\.matrix_identity\(\).*?public function to_float_v\(\) -> array\[float, 16\]:\n\s+return math\.matrix_to_float_v\(this\)/m, source)
    assert_match(/extending Quaternion:.*?public static function identity\(\) -> Quaternion:\n\s+return math\.quaternion_identity\(\).*?public function nlerp\(q2: Vector4, amount: float\) -> Quaternion:\n\s+return math\.quaternion_nlerp\(this, q2, amount\)/m, source)
    refute_match(/^public foreign function begin_mode2_d\(/, source)
    refute_match(/^public foreign function get_world_to_screen2_d\(/, source)
    refute_match(/^public foreign function draw_line3_d\(/, source)
    refute_match(/cstr_as_str/, source)
    refute_match(/^foreign function mt_raw_/, source)
    refute_match(/^public function load_file_data\(/, source)
    refute_match(/^public function load_file_text\(/, source)
    refute_match(/^public function load_utf_8\(/, source)
    refute_match(/^public function load_codepoints\(/, source)
    refute_match(/^public foreign function text_format_/, source)
    refute_match(/^# extension from /, source)
    refute_match(/^public struct CodepointList:$/, source)
    refute_match(/^public def load_codepoints\(text: str\) -> CodepointList:$/, source)
    refute_match(/^public def file_path_at\(files: FilePathList, index: int\) -> cstr:$/, source)
    refute_match(/^public def update_texture_from_image\(texture: Texture, image: Image\) -> void:$/, source)
    refute_match(/^public def set_shader_vec4\(shader: Shader, loc_index: int, value: Vector4\) -> void:$/, source)
  end

  def test_checked_in_rlgl_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("rlgl")

    assert_includes binding.check!, "/std/c/rlgl.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.c\.rlgl as c$/, source)
    refute_match(/^import std\.raylib as raylib$/, source)
    assert_match(/^public type Matrix = c\.Matrix$/, source)
    assert_match(/^public foreign function matrix_mode\(mode: int\) -> void = c\.rlMatrixMode$/, source)
    assert_match(/^public foreign function load_vertex_buffer\[T\]\(buffer: ptr\[T\] as const_ptr\[void\], size: int, dynamic: bool\) -> uint = c\.rlLoadVertexBuffer$/, source)
    assert_match(/^public foreign function load_texture\(data: const_ptr\[void\]\?, width: int, height: int, format: int, mipmap_count: int\) -> uint = c\.rlLoadTexture$/, source)
    assert_match(/^public foreign function load_texture_cubemap\(data: const_ptr\[void\]\?, size: int, format: int, mipmap_count: int\) -> uint = c\.rlLoadTextureCubemap$/, source)
    assert_match(/^public foreign function set_render_batch_active\(batch: ptr\[RenderBatch\]\?\) -> void = c\.rlSetRenderBatchActive$/, source)
    assert_match(/^public foreign function get_gl_texture_formats\(format: int, out gl_internal_format: uint, out gl_format: uint, out gl_type: uint\) -> void = c\.rlGetGlTextureFormats$/, source)
    assert_match(/^public foreign function gen_texture_mipmaps\(id: uint, width: int, height: int, format: int, out mipmaps: int\) -> void = c\.rlGenTextureMipmaps$/, source)
    assert_match(/^public foreign function get_proc_address\(proc_name: str as cstr\) -> ptr\[void\]\? = c\.rlGetProcAddress$/, source)
    assert_match(/^public foreign function load_shader_program\(vs_code: cstr\?, fs_code: cstr\?\) -> uint = c\.rlLoadShaderProgram$/, source)
    assert_match(/^public foreign function set_uniform\[T\]\(loc_index: int, value: ptr\[T\] as const_ptr\[void\], uniform_type: int, count: int\) -> void = c\.rlSetUniform$/, source)
    assert_match(/^public foreign function load_shader_buffer\(size: uint, data: const_ptr\[void\]\?, usage_hint: int\) -> uint = c\.rlLoadShaderBuffer$/, source)
    assert_match(/^public foreign function update_shader_buffer\[T\]\(id: uint, data: ptr\[T\] as const_ptr\[void\], data_size: uint, offset: uint\) -> void = c\.rlUpdateShaderBuffer$/, source)
  end

  def test_checked_in_raymath_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("raymath")

    assert_includes binding.check!, "/std/c/raymath.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.c\.raymath as c$/, source)
    assert_match(/^import std\.c\.raylib as rl$/, source)
    refute_match(/^public type float3 = c\.float3$/, source)
    refute_match(/^public type float16 = c\.float16$/, source)
    refute_match(/^public type double_t = c\.double_t$/, source)
    assert_match(/^public foreign function clamp\(value: float, min: float, max: float\) -> float = c\.Clamp$/, source)
    assert_match(/^public foreign function vector3_to_float_v\(v: rl\.Vector3\) -> array\[float, 3\] = c\.Vector3ToFloatV\(v\)\.v$/, source)
    assert_match(/^public foreign function matrix_to_float_v\(mat: rl\.Matrix\) -> array\[float, 16\] = c\.MatrixToFloatV\(mat\)\.v$/, source)
    assert_match(/^public foreign function vector2_zero\(\) -> rl\.Vector2 = c\.Vector2Zero$/, source)
    refute_match(/^public foreign function vector_2zero\(\) -> rl\.Vector2 = c\.Vector2Zero$/, source)
    refute_match(/^public foreign function vector_2_zero\(\) -> rl\.Vector2 = c\.Vector2Zero$/, source)
    assert_match(/^public foreign function vector3_ortho_normalize\(inout v1: rl\.Vector3, inout v2: rl\.Vector3\) -> void = c\.Vector3OrthoNormalize$/, source)
    assert_match(/^public foreign function quaternion_to_axis_angle\(q: rl\.Quaternion, out axis: rl\.Vector3, out angle: float\) -> void = c\.QuaternionToAxisAngle$/, source)
    assert_match(/^public foreign function matrix_decompose\(mat: rl\.Matrix, out translation: rl\.Vector3, out rotation: rl\.Quaternion, out scale: rl\.Vector3\) -> void = c\.MatrixDecompose$/, source)
    refute_match(/^extending rl\.Vector2:$/, source)
    refute_match(/^extending rl\.Matrix:$/, source)
    refute_match(/^extending rl\.Quaternion:$/, source)
  end

  def test_checked_in_raygui_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("raygui")

    assert_includes binding.check!, "/std/c/raygui.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.c\.raygui as c$/, source)
    assert_match(/^import std\.raylib as rl$/, source)
    assert_match(/^public type Rectangle = rl\.Rectangle$/, source)
    assert_match(/^public type Color = rl\.Color$/, source)
    assert_match(/^public type State = c\.GuiState$/, source)
    assert_match(/^public foreign function set_state\(state: State\) -> void = c\.GuiSetState\(int<-state\)$/, source)
    assert_match(/^public foreign function get_state\(\) -> State = State<-c\.GuiGetState\(\)$/, source)
    assert_match(/^public foreign function get_icons\(\) -> span\[uint\] = span\[uint\]\(data = c\.GuiGetIcons\(\), len = 2048\)$/, source)
    assert_match(/^public foreign function tab_bar\(bounds: Rectangle, text: span\[str\] as span\[ptr\[char\]\], inout active: int\) -> int = c\.GuiTabBar\(bounds, text\.data, int<-text\.len, active\)$/, source)
    assert_match(/^public foreign function scroll_panel\(bounds: Rectangle, text: str as cstr, content: Rectangle, inout scroll: Vector2, out view: Rectangle\) -> int = c\.GuiScrollPanel$/, source)
    assert_match(/^public foreign function toggle\(bounds: Rectangle, text: str as cstr, inout active: bool\) -> int = c\.GuiToggle$/, source)
    assert_match(/^public foreign function list_view_ex\(bounds: Rectangle, text: span\[str\] as span\[ptr\[char\]\], inout scroll_index: int, inout active: int, inout focus: int\) -> int = c\.GuiListViewEx\(bounds, text\.data, int<-text\.len, scroll_index, active, focus\)$/, source)
    assert_match(/^public foreign function value_box_float\[N\]\(bounds: Rectangle, text: str as cstr, text_value: str_buffer\[N\] as ptr\[char\], inout value: float, edit_mode: bool\) -> int = c\.GuiValueBoxFloat\(bounds, text, text_value, value, edit_mode\)$/, source)
    assert_match(/^public foreign function text_box\[N\]\(bounds: Rectangle, text: str_buffer\[N\] as ptr\[char\], edit_mode: bool\) -> int = c\.GuiTextBox\(bounds, text, int<-\(text_public\.capacity\(\) \+ 1\), edit_mode\)$/, source)
    assert_match(/^public foreign function text_input_box\[N\]\(bounds: Rectangle, title: str as cstr, message: str as cstr, buttons: str as cstr, text: str_buffer\[N\] as ptr\[char\], inout secret_view_active: bool\) -> int = c\.GuiTextInputBox\(bounds, title, message, buttons, text, int<-\(text_public\.capacity\(\) \+ 1\), secret_view_active\)$/, source)
  end

  def test_imported_bindings_outside_raylib_and_rlgl_do_not_expose_raw_ptr_void
    offending_bindings = MilkTea::ImportedBindings.default_registry.reject do |binding|
      %w[raylib rlgl sdl3 box2d cjson libuv steamworks].include?(binding.name)
    end.filter_map do |binding|
      binding.name if File.read(binding.binding_path).match?(/\bptr\[void\]\b/)
    end

    assert_empty offending_bindings, "unexpected raw ptr[void] surfaces in imported bindings: #{offending_bindings.join(", ")}"
  end

  def test_checked_in_steamworks_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("steamworks")

    assert_includes binding.check!, "/std/c/steamworks.mt"

    source = File.read(binding.binding_path)
    refute_match(/^module /, source)
    assert_match(/^import std\.c\.steamworks as c$/, source)
    refute_match(/^import std\.str as text$/, source)
    assert_match(/^public type AppId_t = c\.AppId_t$/, source)
    assert_match(/^public type Friends = c\.ISteamFriends$/, source)
    assert_match(/^public type ErrMsg = c\.SteamErrMsg$/, source)
    assert_match(/^public type EAPIInitResult = c\.ESteamAPIInitResult$/, source)
    assert_match(/^public const k_flMaxTimelineEventDuration: float = c\.k_flMaxTimelineEventDuration$/, source)
    assert_match(/^public foreign function restart_app_if_necessary\(un_own_app_id: uint\) -> bool = c\.SteamAPI_RestartAppIfNecessary$/, source)
    assert_match(/^public foreign function init\(\) -> bool = c\.SteamAPI_Init$/, source)
    assert_match(/^public foreign function shutdown\(\) -> void = c\.SteamAPI_Shutdown$/, source)
    assert_match(/^public foreign function friends\(\) -> ptr\[Friends\] = c\.SteamAPI_SteamFriends$/, source)
    assert_match(/^public foreign function friends_get_persona_name\(self: ptr\[Friends\]\) -> cstr = c\.SteamAPI_ISteamFriends_GetPersonaName$/, source)
    assert_match(/^public foreign function internal_context_init\(p_context_init_data: ptr\[void\]\) -> ptr\[void\] = c\.SteamInternal_ContextInit$/, source)
    refute_match(/cstr_as_str/, source)
    refute_match(/^public foreign function steam_api_init\(/, source)
    refute_match(/^public foreign function steam_api_i_steam_friends_get_persona_name\(/, source)
  end

  def test_generate_supports_policy_imports_for_shared_type_aliases
    Dir.mktmpdir("milk-tea-imported-binding-imports") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))
      FileUtils.mkdir_p(File.join(dir, "std"))

      File.write(raw_path, <<~MT)
        external

        struct Rectangle:
            x: float

        external function Sample(bounds: Rectangle) -> void
      MT

      File.write(File.join(dir, "std", "shared.mt"), <<~MT)
        import std.c.sample as c

        public type Rectangle = c.Rectangle
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        imports: [
          {
            module_name: "std.shared",
            alias: "shared",
          },
        ],
        types: {
          include: ["Rectangle"],
          overrides: [
            {
              raw: "Rectangle",
              mapping: "shared.Rectangle",
            },
          ],
        },
        constants: {},
        functions: {
          overrides: [
            {
              raw: "Sample",
              params: [
                {
                  name: "bounds",
                  type: "Rectangle",
                },
              ],
            },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      source = binding.generate(module_roots: [dir])

      assert_match(/^import std\.c\.sample as c$/, source)
      assert_match(/^import std\.shared as shared$/, source)
      assert_match(/^public type Rectangle = shared\.Rectangle$/, source)
      assert_match(/^public foreign function sample\(bounds: Rectangle\) -> void = c\.Sample$/, source)
    end
  end

  def test_generate_supports_public_opaque_handles_and_projects_plain_handle_signatures
    Dir.mktmpdir("milk-tea-imported-binding-opaque-handles") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        opaque WindowHandle = c"WindowHandle"

        external function CreateWindow() -> ptr[WindowHandle]?
        external function DestroyWindow(window: ptr[WindowHandle]) -> void
        external function CreateWindowInPlace(window: ptr[ptr[WindowHandle]]?) -> bool
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {
          overrides: [
            {
              raw: "WindowHandle",
              name: "Window",
              kind: "opaque",
            },
          ],
        },
        constants: {},
        functions: {
          overrides: [
            {
              raw: "CreateWindowInPlace",
              name: "create_window_in_place",
              params: [
                {
                  name: "window",
                  type: "Window",
                  mode: "out",
                },
              ],
            },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public opaque Window = c"WindowHandle"

        public foreign function create_window() -> Window? = c.CreateWindow
        public foreign function destroy_window(window: Window) -> void = c.DestroyWindow
        public foreign function create_window_in_place(out window: Window) -> bool = c.CreateWindowInPlace
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
    end
  end

  def test_generate_rejects_function_wrapper_overrides
    Dir.mktmpdir("milk-tea-imported-binding-wrapper") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        external function LoadText(file_name: cstr) -> ptr[char]?
        external function UnloadText(text: ptr[char]) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {},
        constants: {},
        functions: {
          overrides: [
            {
              raw: "LoadText",
              name: "load_text",
              wrapper: {
                kind: "owned_string",
              },
            },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      error = assert_raises(MilkTea::ImportedBindings::Error) do
        binding.generate(module_roots: [dir])
      end

      assert_match(/function override in #{Regexp.escape(policy_path)} has unknown keys: wrapper/, error.message)
    end
  end

  def test_generate_supports_direct_pointer_and_count_overrides_for_bytes_results
    Dir.mktmpdir("milk-tea-imported-binding-direct-bytes") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        external function LoadData(file_name: cstr, data_size: ptr[int]) -> ptr[ubyte]?
        external function UnloadData(data: ptr[ubyte]) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {},
        constants: {},
        functions: {
          overrides: [
            {
              raw: "LoadData",
              name: "load_data",
              params: [
                {
                  name: "file_name",
                  type: "str",
                  boundary_type: "cstr",
                },
                {
                  name: "data_size",
                  type: "int",
                  mode: "out",
                },
              ],
              return_type: "ptr[ubyte]?",
            },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public foreign function load_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadData
        public foreign function unload_data(data: ptr[ubyte]) -> void = c.UnloadData
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: [dir])
    end
  end

  def test_generate_supports_direct_pointer_and_count_overrides_for_vec_results
    Dir.mktmpdir("milk-tea-imported-binding-direct-vec") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        external function LoadItems(text: cstr, count: ptr[int]) -> ptr[int]?
        external function UnloadItems(items: ptr[int]) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {},
        constants: {},
        functions: {
          overrides: [
            {
              raw: "LoadItems",
              name: "load_items",
              params: [
                {
                  name: "text",
                  type: "str",
                  boundary_type: "cstr",
                },
                {
                  name: "count",
                  type: "int",
                  mode: "out",
                },
              ],
              return_type: "ptr[int]?",
            },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public foreign function load_items(text: str as cstr, out count: int) -> ptr[int]? = c.LoadItems
        public foreign function unload_items(items: ptr[int]) -> void = c.UnloadItems
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: [dir])
    end
  end

  def test_generate_supports_methods_sourced_from_another_module
    Dir.mktmpdir("milk-tea-imported-binding-method-source") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      helper_path = File.join(dir, "std", "helper.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        struct Vector2:
            x: float
            y: float

        external function Vector2Zero() -> Vector2
        external function Vector2Add(v1: Vector2, v2: Vector2) -> Vector2
        external function Vector2Tag(v: Vector2) -> int
      MT

      File.write(helper_path, <<~MT)
        import std.c.sample as raw

        public type SampleTag = int

        public foreign function vector2_zero() -> raw.Vector2 = raw.Vector2Zero
        public foreign function vector2_add(v1: raw.Vector2, v2: raw.Vector2) -> raw.Vector2 = raw.Vector2Add
        public foreign function vector2_tag(v: raw.Vector2) -> SampleTag = raw.Vector2Tag
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {},
        constants: {},
        functions: [],
        methods: [
          {
            type: "Vector2",
            module_name: "std.helper",
            module_import_alias: "helper",
            include_prefixes: ["vector2_"],
            strip_prefix: "vector2_",
          },
        ],
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c
        import std.helper as helper

        public type Vector2 = c.Vector2


        extending Vector2:
            public static function zero() -> Vector2:
                return helper.vector2_zero()


            public function add(v2: Vector2) -> Vector2:
                return helper.vector2_add(this, v2)


            public function tag() -> helper.SampleTag:
                return helper.vector2_tag(this)
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
    end
  end

  def test_generate_rejects_type_shared_from
    Dir.mktmpdir("milk-tea-imported-binding-shared-types") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        struct Matrix:
            m0: float

        enum rlMode: int
            RL_MODE_DEFAULT = 1

        const IDENTITY: Matrix = Matrix(m0 = 1.0)

        external function rlSetMatrix(matrix: Matrix) -> void
        external function rlGetMatrix() -> Matrix
        external function rlGetMode() -> rlMode
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {
          strip_prefix: "rl",
          shared_from: ["shared"],
        },
        constants: {},
        functions: {
          strip_prefix: "rl",
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      error = assert_raises(MilkTea::ImportedBindings::Error) do
        binding.generate(module_roots: [dir])
      end

      assert_match(/type section in #{Regexp.escape(policy_path)} has unknown keys: shared_from/, error.message)
    end
  end

  def test_generate_supports_include_prefixes_for_filtered_mixed_raw_modules
    Dir.mktmpdir("milk-tea-imported-binding-prefixes") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        struct Color:
            r: ubyte

        enum GuiState: int
            STATE_NORMAL = 0

        enum GuiIconName: int
            ICON_NONE = 0

        const RAYGUI_VERSION_MAJOR: int = 4
        const SCROLLBAR_LEFT_SIDE: int = 0

        external function InitWindow() -> void
        external function GuiSetState(state: int) -> void
        external function GuiDrawIcon(iconId: int, color: Color) -> void
        external function GuiLabel(text: cstr) -> int
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {
          include: ["Color"],
          include_prefixes: ["Gui"],
          strip_prefix: "Gui",
        },
        constants: {
          include: ["SCROLLBAR_LEFT_SIDE"],
          include_prefixes: ["RAYGUI_VERSION_"],
        },
        functions: {
          include_prefixes: ["Gui"],
          strip_prefix: "Gui",
          overrides: [
            {
              raw: "GuiSetState",
              params: [
                { "name": "state", "type": "State" },
              ],
            },
            {
              raw: "GuiDrawIcon",
              params: [
                { "name": "icon_id", "type": "IconName" },
                { "name": "color", "type": "Color" },
              ],
            },
            {
              raw: "GuiLabel",
              params: [
                { "name": "text", "type": "str", "boundary_type": "cstr" },
              ],
            },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public type Color = c.Color
        public type State = c.GuiState
        public type IconName = c.GuiIconName

        public const RAYGUI_VERSION_MAJOR: int = c.RAYGUI_VERSION_MAJOR
        public const SCROLLBAR_LEFT_SIDE: int = c.SCROLLBAR_LEFT_SIDE

        public foreign function set_state(state: State) -> void = c.GuiSetState
        public foreign function draw_icon(icon_id: IconName, color: Color) -> void = c.GuiDrawIcon
        public foreign function label(text: str as cstr) -> int = c.GuiLabel
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
      refute_match(/^public foreign function init_window\(/, generated)
    end
  end

  def test_generate_supports_ordered_rename_rules
    Dir.mktmpdir("milk-tea-imported-binding-rename-rules") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        opaque ISteamFriends = c"ISteamFriends"
        opaque ISteamNetworkingMessages = c"ISteamNetworkingMessages"

        type SteamErrMsg = int
        flags ESteamAPIInitResult: int
            ESteamAPIInitResult_OK = 0

        const k_flMaxTimelineEventDuration: float = 12.0

        external function SteamAPI_Init() -> bool
        external function SteamAPI_SteamFriends() -> ptr[ISteamFriends]
        external function SteamAPI_ISteamFriends_GetPersonaName(self: ptr[ISteamFriends]) -> cstr
        external function SteamAPI_SteamNetworkingMessages_SteamAPI_v002() -> ptr[ISteamNetworkingMessages]
        external function SteamInternal_ContextInit(pContextInitData: ptr[void]) -> ptr[void]
        external function SteamGameServer_RunCallbacks() -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {
          rename_rules: [
            { kind: "prefix", match: "ISteam" },
            { kind: "prefix", match: "ESteam", replace_with: "E" },
            { kind: "prefix", match: "Steam" },
          ],
        },
        constants: {},
        functions: {
          rename_rules: [
            { kind: "prefix", match: "SteamAPI_ISteam" },
            { kind: "prefix", match: "SteamAPI_Steam" },
            { kind: "prefix", match: "SteamAPI_" },
            { kind: "prefix", match: "SteamInternal_", replace_with: "Internal_" },
            { kind: "replace", match: "_SteamAPI_", replace_with: "_" },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public type Friends = c.ISteamFriends
        public type NetworkingMessages = c.ISteamNetworkingMessages
        public type ErrMsg = c.SteamErrMsg
        public type EAPIInitResult = c.ESteamAPIInitResult

        public const k_flMaxTimelineEventDuration: float = c.k_flMaxTimelineEventDuration

        public foreign function init() -> bool = c.SteamAPI_Init
        public foreign function friends() -> ptr[Friends] = c.SteamAPI_SteamFriends
        public foreign function friends_get_persona_name(self: ptr[Friends]) -> cstr = c.SteamAPI_ISteamFriends_GetPersonaName
        public foreign function networking_messages_v002() -> ptr[NetworkingMessages] = c.SteamAPI_SteamNetworkingMessages_SteamAPI_v002
        public foreign function internal_context_init(p_context_init_data: ptr[void]) -> ptr[void] = c.SteamInternal_ContextInit
        public foreign function steam_game_server_run_callbacks() -> void = c.SteamGameServer_RunCallbacks
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
    end
  end

  def test_generate_supports_camelize_type_rename_rules
    Dir.mktmpdir("milk-tea-imported-binding-camelize-types") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        opaque pcre2_general_context_8 = c"pcre2_general_context_8"
        opaque pcre2_match_data_8 = c"pcre2_match_data_8"
        opaque pcre2_substitute_callout_block_8 = c"pcre2_substitute_callout_block_8"

        external function pcre2_general_context_free_8(ctx: ptr[pcre2_general_context_8]) -> void
        external function pcre2_match_data_free_8(data: ptr[pcre2_match_data_8]) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {
          include_prefixes: ["pcre2_"],
          rename_rules: [
            { kind: "prefix", match: "pcre2_" },
            { kind: "replace", match: "_8", replace_with: "" },
            { kind: "camelize" },
          ],
        },
        constants: {},
        functions: {
          include_prefixes: ["pcre2_"],
          strip_prefix: "pcre2_",
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public type GeneralContext = c.pcre2_general_context_8
        public type MatchData = c.pcre2_match_data_8
        public type SubstituteCalloutBlock = c.pcre2_substitute_callout_block_8

        public foreign function general_context_free_8(ctx: ptr[GeneralContext]) -> void = c.pcre2_general_context_free_8
        public foreign function match_data_free_8(data: ptr[MatchData]) -> void = c.pcre2_match_data_free_8
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
    end
  end

  def test_generate_supports_opengl_rename_rules
    Dir.mktmpdir("milk-tea-imported-binding-opengl-rename-rules") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        external function glBlendEquation(mode: uint) -> void
        external function glBlendEquationi(buf: uint, mode: uint) -> void
        external function glBlendFunc(sfactor: uint, dfactor: uint) -> void
        external function glBlendFunci(buf: uint, src: uint, dst: uint) -> void
        external function glBufferSubData(target: uint) -> void
        external function glClearBufferfi(target: uint) -> void
        external function glCheckFramebufferStatus(target: uint) -> uint
        external function glClearDepth(depth: double) -> void
        external function glClearDepthf(d: float) -> void
        external function glTexImage2D(target: uint) -> void
        external function glTexImage2DMultisample(target: uint) -> void
        external function glGetBooleani_v(target: uint) -> void
        external function glGetBooleanv(target: uint) -> void
        external function glGetBufferParameteri64v(target: uint) -> void
        external function glGetBufferParameteriv(target: uint) -> void
        external function glGetInternalformati64v(target: uint) -> void
        external function glGetInteger64i_v(target: uint) -> void
        external function glGetInteger64v(target: uint) -> void
        external function glGetIntegeri_v(target: uint) -> void
        external function glGetIntegerv(target: uint) -> void
        external function glGetPointerv(target: uint) -> void
        external function glGetProgramiv(target: uint) -> void
        external function glGetQueryObjecti64v(target: uint) -> void
        external function glGetGraphicsResetStatus() -> uint
        external function glGetTransformFeedbacki_v(xfb: uint) -> void
        external function glPixelStoref(pname: uint) -> void
        external function glPixelStorei(pname: uint) -> void
        external function glProgramUniform1uiv(program: uint) -> void
        external function glProgramUniformMatrix4x3fv(program: uint) -> void
        external function glSampleMaski(maskNumber: uint) -> void
        external function glSamplerParameterIuiv(sampler: uint) -> void
        external function glTexParameteriv(target: uint) -> void
        external function glVertexAttribI4uiv(index: uint) -> void
        external function glVertexAttrib4Nub(index: uint) -> void
        external function glGetTransformFeedbacki64_v(xfb: uint) -> void
        external function glViewportIndexedf(index: uint) -> void
        external function glViewportIndexedfv(index: uint) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {},
        constants: {},
        functions: {
          include_prefixes: ["gl"],
          rename_rules: [
            { kind: "opengl" },
          ],
          strip_prefix: "gl",
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public foreign function blend_equation(mode: uint) -> void = c.glBlendEquation
        public foreign function blend_equation_indexed(buf: uint, mode: uint) -> void = c.glBlendEquationi
        public foreign function blend_func(sfactor: uint, dfactor: uint) -> void = c.glBlendFunc
        public foreign function blend_func_indexed(buf: uint, src: uint, dst: uint) -> void = c.glBlendFunci
        public foreign function buffer_sub_data(target: uint) -> void = c.glBufferSubData
        public foreign function clear_buffer_float_int(target: uint) -> void = c.glClearBufferfi
        public foreign function check_framebuffer_status(target: uint) -> uint = c.glCheckFramebufferStatus
        public foreign function clear_depth(depth: double) -> void = c.glClearDepth
        public foreign function clear_depth_float(d: float) -> void = c.glClearDepthf
        public foreign function tex_image_2d(target: uint) -> void = c.glTexImage2D
        public foreign function tex_image_2d_multisample(target: uint) -> void = c.glTexImage2DMultisample
        public foreign function get_boolean_indexed_values(target: uint) -> void = c.glGetBooleani_v
        public foreign function get_boolean_values(target: uint) -> void = c.glGetBooleanv
        public foreign function get_buffer_parameter_int64_values(target: uint) -> void = c.glGetBufferParameteri64v
        public foreign function get_buffer_parameter_int_values(target: uint) -> void = c.glGetBufferParameteriv
        public foreign function get_internalformat_int64_values(target: uint) -> void = c.glGetInternalformati64v
        public foreign function get_integer64_indexed_values(target: uint) -> void = c.glGetInteger64i_v
        public foreign function get_integer64_values(target: uint) -> void = c.glGetInteger64v
        public foreign function get_integer_indexed_values(target: uint) -> void = c.glGetIntegeri_v
        public foreign function get_integer_values(target: uint) -> void = c.glGetIntegerv
        public foreign function get_pointer_values(target: uint) -> void = c.glGetPointerv
        public foreign function get_program_int_values(target: uint) -> void = c.glGetProgramiv
        public foreign function get_query_object_int64_values(target: uint) -> void = c.glGetQueryObjecti64v
        public foreign function get_graphics_reset_status() -> uint = c.glGetGraphicsResetStatus
        public foreign function get_transform_feedback_int_indexed_values(xfb: uint) -> void = c.glGetTransformFeedbacki_v
        public foreign function pixel_store_float(pname: uint) -> void = c.glPixelStoref
        public foreign function pixel_store_int(pname: uint) -> void = c.glPixelStorei
        public foreign function program_uniform_1_uint_values(program: uint) -> void = c.glProgramUniform1uiv
        public foreign function program_uniform_matrix_4x3_float_values(program: uint) -> void = c.glProgramUniformMatrix4x3fv
        public foreign function sample_mask_indexed(mask_number: uint) -> void = c.glSampleMaski
        public foreign function sampler_parameter_integer_uint_values(sampler: uint) -> void = c.glSamplerParameterIuiv
        public foreign function tex_parameter_int_values(target: uint) -> void = c.glTexParameteriv
        public foreign function vertex_attrib_integer_4_uint_values(index: uint) -> void = c.glVertexAttribI4uiv
        public foreign function vertex_attrib_4_normalized_ubyte(index: uint) -> void = c.glVertexAttrib4Nub
        public foreign function get_transform_feedback_int64_indexed_values(xfb: uint) -> void = c.glGetTransformFeedbacki64_v
        public foreign function viewport_indexed_float(index: uint) -> void = c.glViewportIndexedf
        public foreign function viewport_indexed_float_values(index: uint) -> void = c.glViewportIndexedfv
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
    end
  end

  def test_generate_renames_reserved_public_names_for_ordinary_imported_modules
    Dir.mktmpdir("milk-tea-imported-binding-reserved-public-names") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        type json_array = int

        const json_float: int = 1

        external function json_bool(count: int) -> int
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {
          strip_prefix: "json_",
        },
        constants: {
          strip_prefix: "json_",
        },
        functions: {
          include: "all",
          strip_prefix: "json_",
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public type array_ = c.json_array

        public const float_: int = c.json_float

        public foreign function bool_(count: int) -> int = c.json_bool
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated

      binding.write!(module_roots: [dir])
      assert_includes binding.check!(module_roots: [dir]), "/std/c/sample.mt"
    end
  end

  def test_generate_emits_imported_module_from_policy_and_validates_it
    Dir.mktmpdir("milk-tea-imported-binding-generate") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        struct Color:
            r: ubyte
            g: ubyte
            b: ubyte
            a: ubyte

        flags Mode: int
            MODE_DEFAULT = 1

        const WHITE: Color = Color(r = 255, g = 255, b = 255, a = 255)

        external function CloseWindow() -> void
        external function SetWindowSize(frameWidth: int, frameHeight: int) -> void
        external function InitWindow(width: int, height: int, title: cstr) -> void
        external function LoadData(file_name: cstr, data_size: ptr[int]) -> ptr[ubyte]
        external function SaveData(file_name: cstr, data: ptr[void], data_size: int) -> bool
        external function ReleaseData(data: ptr[ubyte]) -> void
        external function MemAlloc(size: uint) -> ptr[void]
        external function TraceLog(level: int, text: cstr, ...) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        types: {},
        constants: {},
        functions: {
          overrides: [
            {
              raw: "InitWindow",
              params: [
                { name: "width", type: "int" },
                { name: "height", type: "int" },
                { name: "title", type: "str", boundary_type: "cstr" },
              ],
            },
            {
              raw: "LoadData",
              params: [
                { name: "file_name", type: "str", boundary_type: "cstr" },
                { name: "data_size", type: "int", mode: "out" },
              ],
              return_type: "ptr[ubyte]?",
            },
            {
              raw: "SaveData",
              params: [
                { name: "file_name", type: "str", boundary_type: "cstr" },
                { name: "data", type: "span[ubyte]" },
              ],
              mapping: "c.SaveData(file_name, data.data, int<-data.len)",
            },
            {
              raw: "ReleaseData",
              params: [
                { name: "data", type: "ptr[ubyte]", mode: "consuming" },
              ],
            },
            {
              raw: "MemAlloc",
              type_params: ["T"],
              params: [
                { name: "count", type: "ptr_uint" },
              ],
              return_type: "ptr[T]?",
              mapping: "c.MemAlloc(count * uint<-size_of(T))",
            },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public type Color = c.Color
        public type Mode = c.Mode

        public const WHITE: Color = c.WHITE

        public foreign function close_window() -> void = c.CloseWindow
        public foreign function set_window_size(frame_width: int, frame_height: int) -> void = c.SetWindowSize
        public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
        public foreign function load_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadData
        public foreign function save_data(file_name: str as cstr, data: span[ubyte]) -> bool = c.SaveData(file_name, data.data, int<-data.len)
        public foreign function release_data(consuming data: ptr[ubyte]) -> void = c.ReleaseData
        public foreign function mem_alloc[T](count: ptr_uint) -> ptr[T]? = c.MemAlloc(count * uint<-size_of(T))
        public foreign function trace_log(level: int, text: str as cstr, ...) -> void = c.TraceLog
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: [dir])
    end
  end

  def test_generate_supports_multiple_variadic_override_helpers
    Dir.mktmpdir("milk-tea-imported-binding-variadic-overrides") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        external function TextFormat(text: cstr, ...) -> cstr
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        functions: {
          overrides: [
            {
              raw: "TextFormat",
              name: "text_format_int",
              params: [
                { name: "format", type: "str", boundary_type: "cstr" },
                { name: "value", type: "int" },
              ],
              return_type: "cstr",
              mapping: "c.TextFormat(format, value)",
            },
            {
              raw: "TextFormat",
              name: "text_format_int_int",
              params: [
                { name: "format", type: "str", boundary_type: "cstr" },
                { name: "first", type: "int" },
                { name: "second", type: "int" },
              ],
              return_type: "cstr",
              mapping: "c.TextFormat(format, first, second)",
            },
          ],
        },
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public foreign function text_format_int(format: str as cstr, value: int) -> cstr = c.TextFormat(format, value)
        public foreign function text_format_int_int(format: str as cstr, first: int, second: int) -> cstr = c.TextFormat(format, first, second)
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: [dir])
    end
  end

  def test_generate_supports_variadic_pass_through_functions
    Dir.mktmpdir("milk-tea-imported-binding-variadic-pass-through") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        external function TextFormat(text: cstr, ...) -> cstr
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        functions: ["TextFormat"],
      }))

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json

        import std.c.sample as c

        public foreign function text_format(text: str as cstr, ...) -> cstr = c.TextFormat
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: [dir])
    end
  end

  def test_check_reports_binding_drift_with_regeneration_task_name
    Dir.mktmpdir("milk-tea-imported-binding-drift") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external

        struct Color:
            r: ubyte
            g: ubyte
            b: ubyte
            a: ubyte

        const WHITE: Color = Color(r = 255, g = 255, b = 255, a = 255)
      MT
      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        types: ["Color"],
        constants: ["WHITE"],
      }))
      File.write(binding_path, "module std.sample\n")

      binding = MilkTea::ImportedBindings::Binding.new(
        name: "sample",
        module_name: "std.sample",
        binding_path:,
        raw_module_name: "std.c.sample",
        policy_path:,
      )

      error = assert_raises(MilkTea::ImportedBindings::Error) do
        binding.check!(module_roots: [dir])
      end

      assert_match(/#{Regexp.escape(binding_path)} is out of date for #{Regexp.escape(File.expand_path(raw_path))} and #{Regexp.escape(File.expand_path(policy_path))}/, error.message)
      assert_match(/Run `rake imported_bindings:sample` to regenerate it\./, error.message)
    end
  end
end
