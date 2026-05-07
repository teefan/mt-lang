# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaImportedBindingsTest < Minitest::Test
  def test_default_registry_exposes_checked_in_imported_bindings
    registry = MilkTea::ImportedBindings.default_registry

    assert_equal ["raylib", "rlgl", "raygui", "sdl3", "box2d", "cjson", "steamworks", "gl", "glfw", "libuv", "libc", "libm"], registry.map(&:name)
    assert_equal "std.raylib", registry.fetch("raylib").module_name
    assert_equal "std.c.raylib", registry.fetch("raylib").raw_module_name
    assert_includes registry.fetch("raylib").binding_path, "/std/raylib.mt"
    assert_includes registry.fetch("raylib").policy_path, "/bindings/imported/raylib.binding.json"

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

    assert_equal "std.box2d", registry.fetch("box2d").module_name
    assert_equal "std.c.box2d", registry.fetch("box2d").raw_module_name
    assert_includes registry.fetch("box2d").binding_path, "/std/box2d.mt"
    assert_includes registry.fetch("box2d").policy_path, "/bindings/imported/box2d.binding.json"

    assert_equal "std.cjson", registry.fetch("cjson").module_name
    assert_equal "std.c.cjson", registry.fetch("cjson").raw_module_name
    assert_includes registry.fetch("cjson").binding_path, "/std/cjson.mt"
    assert_includes registry.fetch("cjson").policy_path, "/bindings/imported/cjson.binding.json"

    assert_equal "std.steamworks", registry.fetch("steamworks").module_name
    assert_equal "std.c.steamworks", registry.fetch("steamworks").raw_module_name
    assert_includes registry.fetch("steamworks").binding_path, "/std/steamworks.mt"
    assert_includes registry.fetch("steamworks").policy_path, "/bindings/imported/steamworks.binding.json"

    assert_equal "std.gl", registry.fetch("gl").module_name
    assert_equal "std.c.gl", registry.fetch("gl").raw_module_name
    assert_includes registry.fetch("gl").binding_path, "/std/gl.mt"
    assert_includes registry.fetch("gl").policy_path, "/bindings/imported/gl.binding.json"

    assert_equal "std.glfw", registry.fetch("glfw").module_name
    assert_equal "std.c.glfw", registry.fetch("glfw").raw_module_name
    assert_includes registry.fetch("glfw").binding_path, "/std/glfw.mt"
    assert_includes registry.fetch("glfw").policy_path, "/bindings/imported/glfw.binding.json"

    assert_equal "std.libuv", registry.fetch("libuv").module_name
    assert_equal "std.c.libuv", registry.fetch("libuv").raw_module_name
    assert_includes registry.fetch("libuv").binding_path, "/std/libuv.mt"
    assert_includes registry.fetch("libuv").policy_path, "/bindings/imported/libuv.binding.json"

    assert_equal "std.libc", registry.fetch("libc").module_name
    assert_equal "std.c.libc", registry.fetch("libc").raw_module_name
    assert_includes registry.fetch("libc").binding_path, "/std/libc.mt"
    assert_includes registry.fetch("libc").policy_path, "/bindings/imported/libc.binding.json"

    assert_equal "std.libm", registry.fetch("libm").module_name
    assert_equal "std.c.libm", registry.fetch("libm").raw_module_name
    assert_includes registry.fetch("libm").binding_path, "/std/libm.mt"
    assert_includes registry.fetch("libm").policy_path, "/bindings/imported/libm.binding.json"
  end

  def test_checked_in_libc_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("libc")

    assert_includes binding.check!, "/std/c/libc.mt"

    source = File.read(binding.binding_path)
    assert_match(/^module std\.libc$/, source)
    assert_match(/^import std\.c\.libc as c$/, source)
    assert_match(/^pub type IntDiv = c\.div_t$/, source)
    assert_match(/^pub type PtrIntDiv = c\.ldiv_t$/, source)
    assert_match(/^pub type LongDiv = c\.lldiv_t$/, source)
    assert_match(/^pub foreign def parse_int\(text: str as cstr\) -> int = c\.atoi$/, source)
    assert_match(/^pub foreign def parse_ptr_int\(text: str as cstr\) -> ptr_int = c\.atol$/, source)
    assert_match(/^pub foreign def parse_long\(text: str as cstr\) -> long = c\.atoll$/, source)
    assert_match(/^pub foreign def parse_double_with_end\(text: str as cstr, end_ptr: ptr\[ptr\[char\]\]\?\) -> double = c\.strtod$/, source)
    assert_match(/^pub foreign def get_env\(name: str as cstr\) -> cstr\? = c\.getenv$/, source)
    assert_match(/^pub foreign def set_env\(name: str as cstr, value: str as cstr, replace: int\) -> int = c\.setenv$/, source)
    assert_match(/^pub foreign def unset_env\(name: str as cstr\) -> int = c\.unsetenv$/, source)
    assert_match(/^pub foreign def mkstemp\[N\]\(template: str_builder\[N\] as ptr\[char\]\) -> int = c\.mkstemp$/, source)
    assert_match(/^pub foreign def mkstemps\[N\]\(template: str_builder\[N\] as ptr\[char\], suffix_length: int\) -> int = c\.mkstemps$/, source)
    assert_match(/^pub foreign def mkdtemp\[N\]\(template: str_builder\[N\] as ptr\[char\]\) -> cstr\? = c\.mkdtemp$/, source)
    assert_match(/^pub foreign def realpath\[N\]\(name: str as cstr, resolved: str_builder\[N\] as ptr\[char\]\) -> cstr\? = c\.realpath$/, source)
    refute_match(/^pub foreign def atoi\(/, source)
    refute_match(/^pub foreign def atol\(/, source)
    refute_match(/^pub foreign def atoll\(/, source)
    refute_match(/^pub foreign def putenv\(/, source)
    refute_match(/^pub foreign def mktemp\(/, source)
    refute_match(/^pub foreign def strtoq\(/, source)
    refute_match(/^pub foreign def strtouq\(/, source)
    refute_match(/^pub foreign def __ctype_get_mb_cur_max\(/, source)
  end

  def test_checked_in_libm_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("libm")

    assert_includes binding.check!, "/std/c/libm.mt"

    source = File.read(binding.binding_path)
    assert_match(/^module std\.libm$/, source)
    assert_match(/^import std\.c\.libm as c$/, source)
    assert_match(/^pub const PI: double = c\.M_PI$/, source)
    assert_match(/^pub const PI_F: float = c\.M_PI_F$/, source)
    assert_match(/^pub foreign def sqrt\(x: double\) -> double = c\.sqrt$/, source)
    assert_match(/^pub foreign def sqrtf\(x: float\) -> float = c\.sqrtf$/, source)
    assert_match(/^pub foreign def atan2\(y: double, x: double\) -> double = c\.atan2$/, source)
    assert_match(/^pub foreign def atan2f\(y: float, x: float\) -> float = c\.atan2f$/, source)
    refute_match(/^pub const M_PI:/, source)
    refute_match(/^pub foreign def atan_2\(/, source)
  end

  def test_checked_in_gl_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("gl")

    assert_includes binding.check!, "/std/c/gl.mt"

    source = File.read(binding.binding_path)
    assert_match(/^module std\.gl$/, source)
    assert_match(/^import std\.c\.gl as c$/, source)
    assert_match(/^pub type GLuint = c\.GLuint$/, source)
    assert_match(/^pub type GLsync = c\.GLsync$/, source)
    assert_match(/^pub const COLOR_BUFFER_BIT: int = c\.GL_COLOR_BUFFER_BIT$/, source)
    assert_match(/^pub const TRIANGLES: int = c\.GL_TRIANGLES$/, source)
    assert_match(/^pub foreign def clear_color\(red: float, green: float, blue: float, alpha: float\) -> void = c\.glClearColor$/, source)
    assert_match(/^pub foreign def create_shader\(type_: uint\) -> GLuint = c\.glCreateShader$/, source)
    assert_match(/^pub foreign def use_glfw_loader\(\) -> void = c\.mt_gl_use_glfw_loader$/, source)
    assert_match(/^pub foreign def use_sdl_loader\(\) -> void = c\.mt_gl_use_sdl_loader$/, source)
    assert_match(/^pub foreign def reset_loader\(\) -> void = c\.mt_gl_reset_loader$/, source)
    refute_match(/^pub foreign def gl_clear_color\(/, source)
    refute_match(/^pub foreign def mt_gl_use_glfw_loader\(/, source)
  end

  def test_checked_in_glfw_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("glfw")

    assert_includes binding.check!, "/std/c/glfw.mt"

    source = File.read(binding.binding_path)
    assert_match(/^module std\.glfw$/, source)
    assert_match(/^import std\.c\.glfw as c$/, source)
    assert_match(/^pub type GLFWwindow = c\.GLFWwindow$/, source)
    assert_match(/^pub type GLFWvidmode = c\.GLFWvidmode$/, source)
    assert_match(/^pub const TRUE: int = c\.GLFW_TRUE$/, source)
    assert_match(/^pub const KEY_ESCAPE: int = c\.GLFW_KEY_ESCAPE$/, source)
    assert_match(/^pub foreign def init\(\) -> int = c\.glfwInit$/, source)
    assert_match(/^pub foreign def get_error\(description: ptr\[cstr\]\?\) -> int = c\.glfwGetError$/, source)
    assert_match(/^pub foreign def set_error_callback\(callback: GLFWerrorfun\?\) -> GLFWerrorfun\? = c\.glfwSetErrorCallback$/, source)
    assert_match(/^pub foreign def get_monitors\(count: ptr\[int\]\) -> ptr\[ptr\[GLFWmonitor\]\]\? = c\.glfwGetMonitors$/, source)
    assert_match(/^pub foreign def get_primary_monitor\(\) -> ptr\[GLFWmonitor\]\? = c\.glfwGetPrimaryMonitor$/, source)
    assert_match(/^pub foreign def get_monitor_name\(monitor: ptr\[GLFWmonitor\]\) -> cstr\? = c\.glfwGetMonitorName$/, source)
    assert_match(/^pub foreign def set_monitor_callback\(callback: GLFWmonitorfun\?\) -> GLFWmonitorfun\? = c\.glfwSetMonitorCallback$/, source)
    assert_match(/^pub foreign def get_video_modes\(monitor: ptr\[GLFWmonitor\], count: ptr\[int\]\) -> const_ptr\[GLFWvidmode\]\? = c\.glfwGetVideoModes$/, source)
    assert_match(/^pub foreign def get_video_mode\(monitor: ptr\[GLFWmonitor\]\) -> const_ptr\[GLFWvidmode\]\? = c\.glfwGetVideoMode$/, source)
    assert_match(/^pub foreign def get_gamma_ramp\(monitor: ptr\[GLFWmonitor\]\) -> const_ptr\[GLFWgammaramp\]\? = c\.glfwGetGammaRamp$/, source)
    assert_match(/^pub foreign def create_window\(width: int, height: int, title: cstr, monitor: ptr\[GLFWmonitor\]\?, share: ptr\[GLFWwindow\]\?\) -> ptr\[GLFWwindow\]\? = c\.glfwCreateWindow$/, source)
    assert_match(/^pub foreign def get_window_title\(window: ptr\[GLFWwindow\]\) -> cstr\? = c\.glfwGetWindowTitle$/, source)
    assert_match(/^pub foreign def get_window_monitor\(window: ptr\[GLFWwindow\]\) -> ptr\[GLFWmonitor\]\? = c\.glfwGetWindowMonitor$/, source)
    assert_match(/^pub foreign def get_window_user_pointer\(window: ptr\[GLFWwindow\]\) -> ptr\[void\]\? = c\.glfwGetWindowUserPointer$/, source)
    assert_match(/^pub foreign def set_window_pos_callback\(window: ptr\[GLFWwindow\], callback: GLFWwindowposfun\?\) -> GLFWwindowposfun\? = c\.glfwSetWindowPosCallback$/, source)
    assert_match(/^pub foreign def set_window_size_callback\(window: ptr\[GLFWwindow\], callback: GLFWwindowsizefun\?\) -> GLFWwindowsizefun\? = c\.glfwSetWindowSizeCallback$/, source)
    assert_match(/^pub foreign def set_window_close_callback\(window: ptr\[GLFWwindow\], callback: GLFWwindowclosefun\?\) -> GLFWwindowclosefun\? = c\.glfwSetWindowCloseCallback$/, source)
    assert_match(/^pub foreign def set_window_refresh_callback\(window: ptr\[GLFWwindow\], callback: GLFWwindowrefreshfun\?\) -> GLFWwindowrefreshfun\? = c\.glfwSetWindowRefreshCallback$/, source)
    assert_match(/^pub foreign def set_window_focus_callback\(window: ptr\[GLFWwindow\], callback: GLFWwindowfocusfun\?\) -> GLFWwindowfocusfun\? = c\.glfwSetWindowFocusCallback$/, source)
    assert_match(/^pub foreign def set_window_iconify_callback\(window: ptr\[GLFWwindow\], callback: GLFWwindowiconifyfun\?\) -> GLFWwindowiconifyfun\? = c\.glfwSetWindowIconifyCallback$/, source)
    assert_match(/^pub foreign def set_window_maximize_callback\(window: ptr\[GLFWwindow\], callback: GLFWwindowmaximizefun\?\) -> GLFWwindowmaximizefun\? = c\.glfwSetWindowMaximizeCallback$/, source)
    assert_match(/^pub foreign def set_framebuffer_size_callback\(window: ptr\[GLFWwindow\], callback: GLFWframebuffersizefun\?\) -> GLFWframebuffersizefun\? = c\.glfwSetFramebufferSizeCallback$/, source)
    assert_match(/^pub foreign def set_window_content_scale_callback\(window: ptr\[GLFWwindow\], callback: GLFWwindowcontentscalefun\?\) -> GLFWwindowcontentscalefun\? = c\.glfwSetWindowContentScaleCallback$/, source)
    assert_match(/^pub foreign def get_key_name\(key: int, scancode: int\) -> cstr\? = c\.glfwGetKeyName$/, source)
    assert_match(/^pub foreign def get_cursor_pos\(window: ptr\[GLFWwindow\], xpos: ptr\[double\]\?, ypos: ptr\[double\]\?\) -> void = c\.glfwGetCursorPos$/, source)
    assert_match(/^pub foreign def create_cursor\(image: const_ptr\[GLFWimage\], xhot: int, yhot: int\) -> ptr\[GLFWcursor\]\? = c\.glfwCreateCursor$/, source)
    assert_match(/^pub foreign def create_standard_cursor\(shape: int\) -> ptr\[GLFWcursor\]\? = c\.glfwCreateStandardCursor$/, source)
    assert_match(/^pub foreign def set_cursor\(window: ptr\[GLFWwindow\], cursor: ptr\[GLFWcursor\]\?\) -> void = c\.glfwSetCursor$/, source)
    assert_match(/^pub foreign def set_key_callback\(window: ptr\[GLFWwindow\], callback: GLFWkeyfun\?\) -> GLFWkeyfun\? = c\.glfwSetKeyCallback$/, source)
    assert_match(/^pub foreign def set_char_callback\(window: ptr\[GLFWwindow\], callback: GLFWcharfun\?\) -> GLFWcharfun\? = c\.glfwSetCharCallback$/, source)
    assert_match(/^pub foreign def set_char_mods_callback\(window: ptr\[GLFWwindow\], callback: GLFWcharmodsfun\?\) -> GLFWcharmodsfun\? = c\.glfwSetCharModsCallback$/, source)
    assert_match(/^pub foreign def set_mouse_button_callback\(window: ptr\[GLFWwindow\], callback: GLFWmousebuttonfun\?\) -> GLFWmousebuttonfun\? = c\.glfwSetMouseButtonCallback$/, source)
    assert_match(/^pub foreign def set_cursor_pos_callback\(window: ptr\[GLFWwindow\], callback: GLFWcursorposfun\?\) -> GLFWcursorposfun\? = c\.glfwSetCursorPosCallback$/, source)
    assert_match(/^pub foreign def set_cursor_enter_callback\(window: ptr\[GLFWwindow\], callback: GLFWcursorenterfun\?\) -> GLFWcursorenterfun\? = c\.glfwSetCursorEnterCallback$/, source)
    assert_match(/^pub foreign def set_scroll_callback\(window: ptr\[GLFWwindow\], callback: GLFWscrollfun\?\) -> GLFWscrollfun\? = c\.glfwSetScrollCallback$/, source)
    assert_match(/^pub foreign def set_drop_callback\(window: ptr\[GLFWwindow\], callback: GLFWdropfun\?\) -> GLFWdropfun\? = c\.glfwSetDropCallback$/, source)
    assert_match(/^pub foreign def get_joystick_axes\(jid: int, count: ptr\[int\]\) -> const_ptr\[float\]\? = c\.glfwGetJoystickAxes$/, source)
    assert_match(/^pub foreign def get_joystick_buttons\(jid: int, count: ptr\[int\]\) -> const_ptr\[ubyte\]\? = c\.glfwGetJoystickButtons$/, source)
    assert_match(/^pub foreign def get_joystick_hats\(jid: int, count: ptr\[int\]\) -> const_ptr\[ubyte\]\? = c\.glfwGetJoystickHats$/, source)
    assert_match(/^pub foreign def get_joystick_name\(jid: int\) -> cstr\? = c\.glfwGetJoystickName$/, source)
    assert_match(/^pub foreign def get_joystick_guid\(jid: int\) -> cstr\? = c\.glfwGetJoystickGUID$/, source)
    assert_match(/^pub foreign def get_joystick_user_pointer\(jid: int\) -> ptr\[void\]\? = c\.glfwGetJoystickUserPointer$/, source)
    assert_match(/^pub foreign def set_joystick_callback\(callback: GLFWjoystickfun\?\) -> GLFWjoystickfun\? = c\.glfwSetJoystickCallback$/, source)
    assert_match(/^pub foreign def get_gamepad_name\(jid: int\) -> cstr\? = c\.glfwGetGamepadName$/, source)
    assert_match(/^pub foreign def get_clipboard_string\(window: ptr\[GLFWwindow\]\) -> cstr\? = c\.glfwGetClipboardString$/, source)
    assert_match(/^pub foreign def make_context_current\(window: ptr\[GLFWwindow\]\?\) -> void = c\.glfwMakeContextCurrent$/, source)
    assert_match(/^pub foreign def get_current_context\(\) -> ptr\[GLFWwindow\]\? = c\.glfwGetCurrentContext$/, source)
    assert_match(/^pub foreign def get_proc_address\(procname: cstr\) -> GLFWglproc\? = c\.glfwGetProcAddress$/, source)
    assert_match(/^pub foreign def get_required_instance_extensions\(count: ptr\[uint\]\) -> ptr\[cstr\]\? = c\.glfwGetRequiredInstanceExtensions$/, source)
    assert_match(/^pub foreign def get_time\(\) -> double = c\.glfwGetTime$/, source)
    assert_match(/^pub foreign def set_window_should_close\(window: ptr\[GLFWwindow\], value: int\) -> void = c\.glfwSetWindowShouldClose$/, source)
    refute_match(/^pub foreign def glfw_init\(/, source)
  end

  def test_checked_in_libuv_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("libuv")

    assert_includes binding.check!, "/std/c/libuv.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.c\.libuv_system as sys$/, source)
    assert_match(/^pub type uv_loop_t = c\.uv_loop_t$/, source)
    assert_match(/^pub type uv_run_mode = c\.uv_run_mode$/, source)
    assert_match(/^pub type uv_alloc_cb = c\.uv_alloc_cb$/, source)
    assert_match(/^pub foreign def version\(\) -> uint = c\.uv_version$/, source)
    assert_match(/^pub foreign def version_string\(\) -> cstr = c\.uv_version_string$/, source)
    assert_match(/^pub foreign def default_loop\(\) -> ptr\[uv_loop_t\] = c\.uv_default_loop$/, source)
    assert_match(/^pub foreign def loop_init\(loop: ptr\[uv_loop_t\]\) -> int = c\.uv_loop_init$/, source)
    assert_match(/^pub foreign def loop_close\(loop: ptr\[uv_loop_t\]\) -> int = c\.uv_loop_close$/, source)
    assert_match(/^pub foreign def run\(arg_0: ptr\[uv_loop_t\], mode: uv_run_mode\) -> int = c\.uv_run$/, source)
    refute_match(/^pub foreign def uv_version\(/, source)
    refute_match(/^pub foreign def loop_configure\(/, source)
  end

  def test_checked_in_sdl3_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("sdl3")

    assert_includes binding.check!, "/std/c/sdl3.mt"

    source = File.read(binding.binding_path)
    refute_match(/^import std\.mem\.arena as arena$/, source)
    refute_match(/^import std\.string as string$/, source)
    assert_match(/^pub type Window = c\.SDL_Window$/, source)
    assert_match(/^pub type MainFunc = c\.SDL_main_func$/, source)
    refute_match(/^pub type Sint8 = /, source)
    refute_match(/^pub type Uint8 = /, source)
    refute_match(/^pub type Sint16 = /, source)
    refute_match(/^pub type Uint16 = /, source)
    refute_match(/^pub type Sint32 = /, source)
    refute_match(/^pub type Uint32 = /, source)
    refute_match(/^pub type Sint64 = /, source)
    refute_match(/^pub type Uint64 = /, source)
    assert_match(/^pub type InitFlags = c\.SDL_InitFlags$/, source)
    assert_match(/^pub const INIT_VIDEO: uint = c\.SDL_INIT_VIDEO$/, source)
    assert_match(/^pub foreign def malloc\(size: ptr_uint\) -> ptr\[void\] = c\.SDL_malloc$/, source)
    assert_match(/^pub foreign def create_window\(title: str as cstr, w: int, h: int, flag_bits: ptr_uint\) -> ptr\[Window\] = c\.SDL_CreateWindow$/, source)
    assert_match(/^pub foreign def create_window_and_renderer\(title: str as cstr, width: int, height: int, window_flags: ptr_uint, out window: ptr\[Window\], out renderer: ptr\[Renderer\]\) -> bool = c\.SDL_CreateWindowAndRenderer$/, source)
    assert_match(/^pub foreign def run_app\(argc: int, argv: ptr\[ptr\[char\]\], main_function: MainFunc\) -> int = c\.SDL_RunApp\(argc, argv, main_function, null\)$/, source)
    assert_match(/^pub foreign def set_app_metadata\(app_name: str as cstr, app_version: str as cstr, app_identifier: str as cstr\) -> bool = c\.SDL_SetAppMetadata$/, source)
    assert_match(/^pub foreign def init\(flag_bits: InitFlags\) -> bool = c\.SDL_Init$/, source)
    assert_match(/^pub foreign def poll_event\(out event: Event\) -> bool = c\.SDL_PollEvent$/, source)
    assert_match(/^pub foreign def set_clipboard_text\(text: str as cstr\) -> bool = c\.SDL_SetClipboardText$/, source)
    assert_match(/^pub foreign def get_window_size\(window: ptr\[Window\], out w: int, out h: int\) -> bool = c\.SDL_GetWindowSize$/, source)
    assert_match(/^pub foreign def get_render_output_size\(renderer: ptr\[Renderer\], out w: int, out h: int\) -> bool = c\.SDL_GetRenderOutputSize$/, source)
    assert_match(/^pub foreign def get_power_info\(out seconds: int, out percent: int\) -> PowerState = c\.SDL_GetPowerInfo$/, source)
    assert_match(/^pub foreign def get_preferred_locales\(out count: int\) -> ptr\[ptr\[Locale\]\]\? = c\.SDL_GetPreferredLocales$/, source)
    assert_match(/^pub foreign def get_displays\(count: ptr\[int\]\) -> ptr\[DisplayID\]\? = c\.SDL_GetDisplays$/, source)
    assert_match(/^pub foreign def get_display_name\(display_id: uint\) -> cstr\? = c\.SDL_GetDisplayName$/, source)
    assert_match(/^pub foreign def get_fullscreen_display_modes\(display_id: uint, count: ptr\[int\]\) -> ptr\[ptr\[DisplayMode\]\]\? = c\.SDL_GetFullscreenDisplayModes$/, source)
    assert_match(/^pub foreign def get_desktop_display_mode\(display_id: uint\) -> const_ptr\[DisplayMode\]\? = c\.SDL_GetDesktopDisplayMode$/, source)
    assert_match(/^pub foreign def get_current_display_mode\(display_id: uint\) -> const_ptr\[DisplayMode\]\? = c\.SDL_GetCurrentDisplayMode$/, source)
    assert_match(/^pub foreign def get_window_icc_profile\(window: ptr\[Window\], size: ptr\[ptr_uint\]\) -> ptr\[void\]\? = c\.SDL_GetWindowICCProfile$/, source)
    assert_match(/^pub foreign def get_windows\(count: ptr\[int\]\) -> ptr\[ptr\[Window\]\]\? = c\.SDL_GetWindows$/, source)
    assert_match(/^pub foreign def convert_event_to_render_coordinates\(renderer: ptr\[Renderer\], inout event: Event\) -> bool = c\.SDL_ConvertEventToRenderCoordinates$/, source)
    assert_match(/^pub foreign def get_current_time\(out ticks: Time\) -> bool = c\.SDL_GetCurrentTime$/, source)
    assert_match(/^pub foreign def time_to_date_time\(ticks: Time, out dt: DateTime, local_time: bool\) -> bool = c\.SDL_TimeToDateTime$/, source)
    assert_match(/^pub foreign def render_debug_text\(renderer: ptr\[Renderer\], x: float, y: float, text: str as cstr\) -> bool = c\.SDL_RenderDebugText$/, source)
    assert_match(/^pub foreign def load_png\(file_name: str as cstr\) -> ptr\[Surface\]\? = c\.SDL_LoadPNG$/, source)
    assert_match(/^pub foreign def gl_get_proc_address\(proc_: cstr\) -> FunctionPointer\? = c\.SDL_GL_GetProcAddress$/, source)
    assert_match(/^pub foreign def egl_get_proc_address\(proc_: cstr\) -> FunctionPointer\? = c\.SDL_EGL_GetProcAddress$/, source)
    assert_match(/^pub foreign def gl_get_current_window\(\) -> ptr\[Window\]\? = c\.SDL_GL_GetCurrentWindow$/, source)
    assert_match(/^pub foreign def gl_get_current_context\(\) -> GLContext\? = c\.SDL_GL_GetCurrentContext$/, source)
    assert_match(/^pub foreign def load_object\(sofile: cstr\) -> ptr\[SharedObject\]\? = c\.SDL_LoadObject$/, source)
    assert_match(/^pub foreign def load_function\(handle: ptr\[SharedObject\], name: cstr\) -> FunctionPointer\? = c\.SDL_LoadFunction$/, source)
    assert_match(/^pub foreign def get_keyboards\(count: ptr\[int\]\) -> ptr\[KeyboardID\]\? = c\.SDL_GetKeyboards$/, source)
    assert_match(/^pub foreign def get_keyboard_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetKeyboardNameForID$/, source)
    assert_match(/^pub foreign def get_mice\(count: ptr\[int\]\) -> ptr\[MouseID\]\? = c\.SDL_GetMice$/, source)
    assert_match(/^pub foreign def get_mouse_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetMouseNameForID$/, source)
    assert_match(/^pub foreign def get_touch_devices\(count: ptr\[int\]\) -> ptr\[TouchID\]\? = c\.SDL_GetTouchDevices$/, source)
    assert_match(/^pub foreign def get_touch_device_name\(touch_id: ptr_uint\) -> cstr\? = c\.SDL_GetTouchDeviceName$/, source)
    assert_match(/^pub foreign def get_touch_fingers\(touch_id: ptr_uint, count: ptr\[int\]\) -> ptr\[ptr\[Finger\]\]\? = c\.SDL_GetTouchFingers$/, source)
    assert_match(/^pub foreign def get_sensors\(count: ptr\[int\]\) -> ptr\[SensorID\]\? = c\.SDL_GetSensors$/, source)
    assert_match(/^pub foreign def get_sensor_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetSensorNameForID$/, source)
    assert_match(/^pub foreign def open_sensor\(instance_id: uint\) -> ptr\[Sensor\]\? = c\.SDL_OpenSensor$/, source)
    assert_match(/^pub foreign def get_sensor_from_id\(instance_id: uint\) -> ptr\[Sensor\]\? = c\.SDL_GetSensorFromID$/, source)
    assert_match(/^pub foreign def get_sensor_name\(sensor: ptr\[Sensor\]\) -> cstr\? = c\.SDL_GetSensorName$/, source)
    assert_match(/^pub foreign def get_joysticks\(out count: int\) -> ptr\[JoystickID\]\? = c\.SDL_GetJoysticks$/, source)
    assert_match(/^pub foreign def get_joystick_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetJoystickNameForID$/, source)
    assert_match(/^pub foreign def get_joystick_name\(joystick: ptr\[Joystick\]\) -> cstr\? = c\.SDL_GetJoystickName$/, source)
    assert_match(/^pub foreign def get_joystick_path_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetJoystickPathForID$/, source)
    assert_match(/^pub foreign def get_joystick_from_player_index\(player_index: int\) -> ptr\[Joystick\]\? = c\.SDL_GetJoystickFromPlayerIndex$/, source)
    assert_match(/^pub foreign def get_joystick_path\(joystick: ptr\[Joystick\]\) -> cstr\? = c\.SDL_GetJoystickPath$/, source)
    assert_match(/^pub foreign def get_joystick_serial\(joystick: ptr\[Joystick\]\) -> cstr\? = c\.SDL_GetJoystickSerial$/, source)
    assert_match(/^pub foreign def get_gamepad_mappings\(count: ptr\[int\]\) -> ptr\[ptr\[char\]\]\? = c\.SDL_GetGamepadMappings$/, source)
    assert_match(/^pub foreign def get_gamepads\(out count: int\) -> ptr\[JoystickID\]\? = c\.SDL_GetGamepads$/, source)
    assert_match(/^pub foreign def get_gamepad_name_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetGamepadNameForID$/, source)
    assert_match(/^pub foreign def get_gamepad_name\(gamepad: ptr\[Gamepad\]\) -> cstr\? = c\.SDL_GetGamepadName$/, source)
    assert_match(/^pub foreign def get_gamepad_path_for_id\(instance_id: uint\) -> cstr\? = c\.SDL_GetGamepadPathForID$/, source)
    assert_match(/^pub foreign def get_gamepad_path\(gamepad: ptr\[Gamepad\]\) -> cstr\? = c\.SDL_GetGamepadPath$/, source)
    refute_match(/^pub def cstr_as_str\(text: cstr\) -> str:$/, source)
    refute_match(/^pub def free_chars\(text: ptr\[char\]\?\) -> void:$/, source)
    refute_match(/^pub def preferred_locale_at\(locales: ptr\[ptr\[Locale\]\], index: int\) -> ptr\[Locale\]\?:$/, source)
    refute_match(/^pub def free_preferred_locales\(locales: ptr\[ptr\[Locale\]\]\?\) -> void:$/, source)
    refute_match(/^pub def preferred_locale_string\(locale: ptr\[Locale\]\) -> string\.String:$/, source)
    refute_match(/^pub def render_debug_text_str\(renderer: ptr\[Renderer\], x: float, y: float, text: str\) -> bool:$/, source)
    assert_match(/^pub foreign def quit\(\) -> void = c\.SDL_Quit$/, source)
  end

  def test_checked_in_box2d_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("box2d")

    assert_includes binding.check!, "/std/c/box2d.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.c\.box2d as c$/, source)
    assert_match(/^pub type WorldId = c\.b2WorldId$/, source)
    assert_match(/^pub type Vec2 = c\.b2Vec2$/, source)
    assert_match(/^pub type DebugDraw = c\.b2DebugDraw$/, source)
    assert_match(/^pub const b2_nullWorldId: WorldId = c\.b2_nullWorldId$/, source)
    assert_match(/^pub foreign def default_world_def\(\) -> WorldDef = c\.b2DefaultWorldDef$/, source)
    assert_match(/^pub foreign def default_body_def\(\) -> BodyDef = c\.b2DefaultBodyDef$/, source)
    assert_match(/^pub foreign def default_shape_def\(\) -> ShapeDef = c\.b2DefaultShapeDef$/, source)
    assert_match(/^pub foreign def make_box\(half_width: float, half_height: float\) -> Polygon = c\.b2MakeBox$/, source)
    assert_match(/^pub foreign def create_world\(in world_def: WorldDef\) -> WorldId = c\.b2CreateWorld$/, source)
    assert_match(/^pub foreign def world_step\(world_id: WorldId, time_step: float, sub_step_count: int\) -> void = c\.b2World_Step$/, source)
    assert_match(/^pub foreign def create_body\(world_id: WorldId, in body_def: BodyDef\) -> BodyId = c\.b2CreateBody$/, source)
    assert_match(/^pub foreign def create_polygon_shape\(body_id: BodyId, in shape_def: ShapeDef, in polygon: Polygon\) -> ShapeId = c\.b2CreatePolygonShape$/, source)
    assert_match(/^pub foreign def world_draw\(world_id: WorldId, inout draw: DebugDraw\) -> void = c\.b2World_Draw$/, source)
  end

  def test_checked_in_cjson_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("cjson")

    assert_includes binding.check!, "/std/c/cjson.mt"

    source = File.read(binding.binding_path)
    assert_match(/^module std\.cjson$/, source)
    assert_match(/^import std\.c\.cjson as c$/, source)
    assert_match(/^pub type JSON = c\.cJSON$/, source)
    assert_match(/^pub type Hooks = c\.cJSON_Hooks$/, source)
    assert_match(/^pub type Bool = c\.cJSON_bool$/, source)
    assert_match(/^pub const VERSION_MAJOR: int = c\.CJSON_VERSION_MAJOR$/, source)
    assert_match(/^pub foreign def parse\(value: str as cstr\) -> ptr\[JSON\]\? = c\.cJSON_Parse$/, source)
    assert_match(/^pub foreign def parse_with_length\(value: str as cstr, buffer_length: ptr_uint\) -> ptr\[JSON\]\? = c\.cJSON_ParseWithLength$/, source)
    assert_match(/^pub foreign def get_object_item\(object: const_ptr\[JSON\], string: str as cstr\) -> ptr\[JSON\]\? = c\.cJSON_GetObjectItem$/, source)
    assert_match(/^pub foreign def add_string_to_object\(object: ptr\[JSON\], name: str as cstr, string: str as cstr\) -> ptr\[JSON\] = c\.cJSON_AddStringToObject$/, source)
    refute_match(/^pub foreign def cjson_parse\(/, source)
    refute_match(/^pub foreign def malloc\(/, source)
    refute_match(/^pub foreign def free\(/, source)
  end

  def test_generate_rejects_extra_source_policy_escape_hatch
    Dir.mktmpdir("milk-tea-imported-binding-extra-source") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        extern module std.c.sample:
            extern def sample() -> void
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
          "pub def helper() -> void:",
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
        extern module std.c.dep:
            opaque Thing = c"Thing"
      MT

      File.write(raw_path, <<~MT)
        extern module std.c.sample:
            import std.c.dep as dep

            extern def sample(arg: ptr[dep.Thing]) -> void
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
      assert_match(/^pub foreign def sample\(arg: ptr\[dep\.Thing\]\) -> void = c\.sample$/, source)

      File.write(binding_path, source)
      assert_includes binding.check!(module_roots: [dir]), "/std/c/sample.mt"
    end
  end

  def test_checked_in_raylib_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("raylib")

    assert_includes binding.check!, "/std/c/raylib.mt"

    source = File.read(binding.binding_path)
    refute_match(/^pub type __va_list_tag = /, source)
    refute_match(/^pub type va_list = /, source)
    refute_match(/^pub type TraceLogCallback = /, source)
    refute_match(/^pub foreign def set_trace_log_callback\(/, source)
    assert_match(/^pub foreign def load_shader\(vs_file_name: cstr\?, fs_file_name: cstr\?\) -> Shader = c\.LoadShader$/, source)
    assert_match(/^pub foreign def load_shader_from_memory\(vs_code: cstr\?, fs_code: cstr\?\) -> Shader = c\.LoadShaderFromMemory$/, source)
    assert_match(/^pub foreign def set_shader_value\[T\]\(shader: Shader, loc_index: int, in value: T as const_ptr\[void\], uniform_type: int\) -> void = c\.SetShaderValue$/, source)
    assert_match(/^pub foreign def set_shader_value_v\[T\]\(shader: Shader, loc_index: int, value: ptr\[T\] as const_ptr\[void\], uniform_type: int, count: int\) -> void = c\.SetShaderValueV$/, source)
    assert_match(/^pub foreign def load_image\(file_name: str as cstr\) -> Image = c\.LoadImage$/, source)
    assert_match(/^pub foreign def load_image_raw\(file_name: str as cstr, width: int, height: int, format: int, header_size: int\) -> Image = c\.LoadImageRaw$/, source)
    assert_match(/^pub foreign def load_image_anim\(file_name: str as cstr, out frames: int\) -> Image = c\.LoadImageAnim$/, source)
    assert_match(/^pub foreign def export_image\(image: Image, file_name: str as cstr\) -> bool = c\.ExportImage$/, source)
    assert_match(/^pub foreign def update_texture\[T\]\(texture: Texture, pixels: ptr\[T\] as const_ptr\[void\]\) -> void = c\.UpdateTexture$/, source)
    assert_match(/^pub foreign def update_mesh_buffer\[T\]\(mesh: Mesh, index: int, data: ptr\[T\] as const_ptr\[void\], data_size: int, offset: int\) -> void = c\.UpdateMeshBuffer$/, source)
    assert_match(/^pub foreign def update_audio_stream\[T\]\(stream: AudioStream, data: ptr\[T\] as const_ptr\[void\], frame_count: int\) -> void = c\.UpdateAudioStream$/, source)
    assert_match(/^pub foreign def draw_spline_linear_ptr\(points: const_ptr\[Vector2\], point_count: int, thick: float, color: Color\) -> void = c\.DrawSplineLinear$/, source)
    assert_match(/^pub foreign def text_format_int_int_int\(format: str as cstr, first: int, second: int, third: int\) -> cstr = c\.TextFormat\(format, first, second, third\)$/, source)
    assert_match(/^pub foreign def text_format_cstr_float_float\(format: str as cstr, label: str as cstr, first: float, second: float\) -> cstr = c\.TextFormat\(format, label, first, second\)$/, source)
    assert_match(/^pub foreign def image_format\(inout image: Image, new_format: int\) -> void = c\.ImageFormat$/, source)
    assert_match(/^pub foreign def image_draw_text_ex\(inout dst: Image, font: Font, text: str as cstr, position: Vector2, font_size: float, spacing: float, tint: Color\) -> void = c\.ImageDrawTextEx$/, source)
    assert_match(/^pub foreign def draw_text_ex\(font: Font, text: str as cstr, position: Vector2, font_size: float, spacing: float, tint: Color\) -> void = c\.DrawTextEx$/, source)
    assert_match(/^pub foreign def load_font\(file_name: str as cstr\) -> Font = c\.LoadFont$/, source)
    assert_match(/^pub foreign def load_font_ex\(file_name: str as cstr, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int\) -> Font = c\.LoadFontEx$/, source)
    assert_match(/^pub foreign def load_sound\(file_name: str as cstr\) -> Sound = c\.LoadSound$/, source)
    assert_match(/^pub foreign def load_font_from_memory\(file_type: cstr, file_data: const_ptr\[ubyte\], data_size: int, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int\) -> Font = c\.LoadFontFromMemory$/, source)
    assert_match(/^pub foreign def gen_texture_mipmaps\(inout texture: Texture2D\) -> void = c\.GenTextureMipmaps$/, source)
    assert_match(/^pub foreign def load_font_data\(file_data: const_ptr\[ubyte\], data_size: int, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int, kind: FontType, out glyph_count: int\) -> ptr\[GlyphInfo\] = c\.LoadFontData$/, source)
    assert_match(/^pub foreign def gen_image_font_atlas\(glyphs: const_ptr\[GlyphInfo\], out glyph_recs: ptr\[Rectangle\], glyph_count: int, font_size: int, padding: int, pack_method: int\) -> Image = c\.GenImageFontAtlas$/, source)
    assert_match(/^pub foreign def load_codepoints_ptr\(text: str as cstr, out count: int\) -> ptr\[int\] = c\.LoadCodepoints$/, source)
    assert_match(/^pub foreign def load_fragment_shader\(fs_file_name: str as cstr\) -> Shader = c\.LoadShader\(null, fs_file_name\)$/, source)
    refute_match(/^# extension from /, source)
    refute_match(/^pub struct CodepointList:$/, source)
    refute_match(/^pub def load_codepoints\(text: str\) -> CodepointList:$/, source)
    refute_match(/^pub def file_path_at\(files: FilePathList, index: int\) -> cstr:$/, source)
    refute_match(/^pub def update_texture_from_image\(texture: Texture, image: Image\) -> void:$/, source)
    refute_match(/^pub def set_shader_vec4\(shader: Shader, loc_index: int, value: Vector4\) -> void:$/, source)
  end

  def test_checked_in_rlgl_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("rlgl")

    assert_includes binding.check!, "/std/c/rlgl.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.raylib as raylib$/, source)
    assert_match(/^pub type Matrix = raylib\.Matrix$/, source)
    assert_match(/^pub foreign def matrix_mode\(mode: int\) -> void = c\.rlMatrixMode$/, source)
    assert_match(/^pub foreign def load_vertex_buffer\[T\]\(buffer: ptr\[T\] as const_ptr\[void\], size: int, dynamic: bool\) -> uint = c\.rlLoadVertexBuffer$/, source)
    assert_match(/^pub foreign def load_texture\(data: const_ptr\[void\]\?, width: int, height: int, format: int, mipmap_count: int\) -> uint = c\.rlLoadTexture$/, source)
    assert_match(/^pub foreign def load_texture_cubemap\(data: const_ptr\[void\]\?, size: int, format: int, mipmap_count: int\) -> uint = c\.rlLoadTextureCubemap$/, source)
    assert_match(/^pub foreign def get_proc_address\(proc_name: cstr\) -> ptr\[void\]\? = c\.rlGetProcAddress$/, source)
    assert_match(/^pub foreign def set_uniform\[T\]\(loc_index: int, value: ptr\[T\] as const_ptr\[void\], uniform_type: int, count: int\) -> void = c\.rlSetUniform$/, source)
    assert_match(/^pub foreign def load_shader_buffer\(size: uint, data: const_ptr\[void\]\?, usage_hint: int\) -> uint = c\.rlLoadShaderBuffer$/, source)
    assert_match(/^pub foreign def update_shader_buffer\[T\]\(id: uint, data: ptr\[T\] as const_ptr\[void\], data_size: uint, offset: uint\) -> void = c\.rlUpdateShaderBuffer$/, source)
  end

  def test_checked_in_raygui_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("raygui")

    assert_includes binding.check!, "/std/c/raygui.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.raylib as raylib$/, source)
    assert_match(/^pub type Rectangle = raylib\.Rectangle$/, source)
    assert_match(/^pub type State = c\.GuiState$/, source)
    assert_match(/^pub foreign def set_state\(state: State\) -> void = c\.GuiSetState\(int<-state\)$/, source)
    assert_match(/^pub foreign def get_state\(\) -> State = State<-c\.GuiGetState\(\)$/, source)
    assert_match(/^pub foreign def get_icons\(\) -> span\[uint\] = span\[uint\]\(data = c\.GuiGetIcons\(\), len = 2048\)$/, source)
    assert_match(/^pub foreign def tab_bar\(bounds: Rectangle, text: span\[str\] as span\[ptr\[char\]\], inout active: int\) -> int = c\.GuiTabBar\(bounds, text\.data, int<-text\.len, active\)$/, source)
    assert_match(/^pub foreign def scroll_panel\(bounds: Rectangle, text: str as cstr, content: Rectangle, inout scroll: Vector2, out view: Rectangle\) -> int = c\.GuiScrollPanel$/, source)
    assert_match(/^pub foreign def toggle\(bounds: Rectangle, text: str as cstr, inout active: bool\) -> int = c\.GuiToggle$/, source)
    assert_match(/^pub foreign def list_view_ex\(bounds: Rectangle, text: span\[str\] as span\[ptr\[char\]\], inout scroll_index: int, inout active: int, inout focus: int\) -> int = c\.GuiListViewEx\(bounds, text\.data, int<-text\.len, scroll_index, active, focus\)$/, source)
    assert_match(/^pub foreign def value_box_float\[N\]\(bounds: Rectangle, text: str as cstr, text_value: str_builder\[N\] as ptr\[char\], inout value: float, edit_mode: bool\) -> int = c\.GuiValueBoxFloat\(bounds, text, text_value, value, edit_mode\)$/, source)
    assert_match(/^pub foreign def text_box\[N\]\(bounds: Rectangle, text: str_builder\[N\] as ptr\[char\], edit_mode: bool\) -> int = c\.GuiTextBox\(bounds, text, int<-\(text_public\.capacity\(\) \+ 1\), edit_mode\)$/, source)
    assert_match(/^pub foreign def text_input_box\[N\]\(bounds: Rectangle, title: str as cstr, message: str as cstr, buttons: str as cstr, text: str_builder\[N\] as ptr\[char\], inout secret_view_active: bool\) -> int = c\.GuiTextInputBox\(bounds, title, message, buttons, text, int<-\(text_public\.capacity\(\) \+ 1\), secret_view_active\)$/, source)
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
    assert_match(/^module std\.steamworks$/, source)
    assert_match(/^import std\.c\.steamworks as c$/, source)
    assert_match(/^pub type AppId_t = c\.AppId_t$/, source)
    assert_match(/^pub type Friends = c\.ISteamFriends$/, source)
    assert_match(/^pub type ErrMsg = c\.SteamErrMsg$/, source)
    assert_match(/^pub type EAPIInitResult = c\.ESteamAPIInitResult$/, source)
    assert_match(/^pub const k_flMaxTimelineEventDuration: float = c\.k_flMaxTimelineEventDuration$/, source)
    assert_match(/^pub foreign def restart_app_if_necessary\(un_own_app_id: uint\) -> bool = c\.SteamAPI_RestartAppIfNecessary$/, source)
    assert_match(/^pub foreign def init\(\) -> bool = c\.SteamAPI_Init$/, source)
    assert_match(/^pub foreign def shutdown\(\) -> void = c\.SteamAPI_Shutdown$/, source)
    assert_match(/^pub foreign def friends\(\) -> ptr\[Friends\] = c\.SteamAPI_SteamFriends$/, source)
    assert_match(/^pub foreign def friends_get_persona_name\(self: ptr\[Friends\]\) -> cstr = c\.SteamAPI_ISteamFriends_GetPersonaName$/, source)
    assert_match(/^pub foreign def internal_context_init\(p_context_init_data: ptr\[void\]\) -> ptr\[void\] = c\.SteamInternal_ContextInit$/, source)
    refute_match(/^pub foreign def steam_api_init\(/, source)
    refute_match(/^pub foreign def steam_api_i_steam_friends_get_persona_name\(/, source)
  end

  def test_generate_supports_imports_type_alias_overrides_and_prefix_stripping
    Dir.mktmpdir("milk-tea-imported-binding-overrides") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      shared_path = File.join(dir, "std", "shared.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        extern module std.c.sample:
            struct Matrix:
                m0: float

            enum rlMode: int
                RL_MODE_DEFAULT = 1

            const IDENTITY: Matrix = Matrix(m0 = 1.0)

            extern def rlSetMatrix(matrix: Matrix) -> void
            extern def rlGetMode() -> rlMode
      MT

      File.write(shared_path, <<~MT)
        module std.shared

        import std.c.sample as c

        pub type Matrix = c.Matrix
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
          strip_prefix: "rl",
          overrides: [
            {
              raw: "Matrix",
              mapping: "shared.Matrix",
            },
          ],
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

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json
        module std.sample

        import std.c.sample as c
        import std.shared as shared

        pub type Matrix = shared.Matrix
        pub type Mode = c.rlMode

        pub const IDENTITY: Matrix = c.IDENTITY

        pub foreign def set_matrix(matrix: Matrix) -> void = c.rlSetMatrix
        pub foreign def get_mode() -> Mode = c.rlGetMode
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: [dir])
    end
  end

  def test_generate_supports_shared_from_same_name_type_defaults
    Dir.mktmpdir("milk-tea-imported-binding-shared-types") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      shared_path = File.join(dir, "std", "shared.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        extern module std.c.sample:
            struct Matrix:
                m0: float

            enum rlMode: int
                RL_MODE_DEFAULT = 1

            const IDENTITY: Matrix = Matrix(m0 = 1.0)

            extern def rlSetMatrix(matrix: Matrix) -> void
            extern def rlGetMatrix() -> Matrix
            extern def rlGetMode() -> rlMode
      MT

      File.write(shared_path, <<~MT)
        module std.shared

        import std.c.sample as c

        pub type Matrix = c.Matrix
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

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json
        module std.sample

        import std.c.sample as c
        import std.shared as shared

        pub type Matrix = shared.Matrix
        pub type Mode = c.rlMode

        pub const IDENTITY: Matrix = c.IDENTITY

        pub foreign def set_matrix(matrix: Matrix) -> void = c.rlSetMatrix
        pub foreign def get_matrix() -> Matrix = c.rlGetMatrix
        pub foreign def get_mode() -> Mode = c.rlGetMode
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: [dir])
    end
  end

  def test_generate_supports_include_prefixes_for_filtered_mixed_raw_modules
    Dir.mktmpdir("milk-tea-imported-binding-prefixes") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      shared_path = File.join(dir, "std", "shared.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        extern module std.c.sample:
            struct Color:
                r: ubyte

            enum GuiState: int
                STATE_NORMAL = 0

            enum GuiIconName: int
                ICON_NONE = 0

            const RAYGUI_VERSION_MAJOR: int = 4
            const SCROLLBAR_LEFT_SIDE: int = 0

            extern def InitWindow() -> void
            extern def GuiSetState(state: int) -> void
            extern def GuiDrawIcon(iconId: int, color: Color) -> void
            extern def GuiLabel(text: cstr) -> int
      MT

      File.write(shared_path, <<~MT)
        module std.shared

        import std.c.sample as c

        pub type Color = c.Color
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
          include: ["Color"],
          include_prefixes: ["Gui"],
          shared_from: ["shared"],
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
        module std.sample

        import std.c.sample as c
        import std.shared as shared

        pub type Color = shared.Color
        pub type State = c.GuiState
        pub type IconName = c.GuiIconName

        pub const RAYGUI_VERSION_MAJOR: int = c.RAYGUI_VERSION_MAJOR
        pub const SCROLLBAR_LEFT_SIDE: int = c.SCROLLBAR_LEFT_SIDE

        pub foreign def set_state(state: State) -> void = c.GuiSetState
        pub foreign def draw_icon(icon_id: IconName, color: Color) -> void = c.GuiDrawIcon
        pub foreign def label(text: str as cstr) -> int = c.GuiLabel
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
      refute_match(/^pub foreign def init_window\(/, generated)
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
        extern module std.c.sample:
            opaque ISteamFriends = c"ISteamFriends"
            opaque ISteamNetworkingMessages = c"ISteamNetworkingMessages"

            type SteamErrMsg = int
            flags ESteamAPIInitResult: int
                ESteamAPIInitResult_OK = 0

            const k_flMaxTimelineEventDuration: float = 12.0

            extern def SteamAPI_Init() -> bool
            extern def SteamAPI_SteamFriends() -> ptr[ISteamFriends]
            extern def SteamAPI_ISteamFriends_GetPersonaName(self: ptr[ISteamFriends]) -> cstr
            extern def SteamAPI_SteamNetworkingMessages_SteamAPI_v002() -> ptr[ISteamNetworkingMessages]
            extern def SteamInternal_ContextInit(pContextInitData: ptr[void]) -> ptr[void]
            extern def SteamGameServer_RunCallbacks() -> void
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
        module std.sample

        import std.c.sample as c

        pub type Friends = c.ISteamFriends
        pub type NetworkingMessages = c.ISteamNetworkingMessages
        pub type ErrMsg = c.SteamErrMsg
        pub type EAPIInitResult = c.ESteamAPIInitResult

        pub const k_flMaxTimelineEventDuration: float = c.k_flMaxTimelineEventDuration

        pub foreign def init() -> bool = c.SteamAPI_Init
        pub foreign def friends() -> ptr[Friends] = c.SteamAPI_SteamFriends
        pub foreign def friends_get_persona_name(self: ptr[Friends]) -> cstr = c.SteamAPI_ISteamFriends_GetPersonaName
        pub foreign def networking_messages_v_002() -> ptr[NetworkingMessages] = c.SteamAPI_SteamNetworkingMessages_SteamAPI_v002
        pub foreign def internal_context_init(p_context_init_data: ptr[void]) -> ptr[void] = c.SteamInternal_ContextInit
        pub foreign def steam_game_server_run_callbacks() -> void = c.SteamGameServer_RunCallbacks
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
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
        extern module std.c.sample:
            struct Color:
                r: ubyte
                g: ubyte
                b: ubyte
                a: ubyte

            flags Mode: int
                MODE_DEFAULT = 1

            const WHITE: Color = Color(r = 255, g = 255, b = 255, a = 255)

            extern def CloseWindow() -> void
            extern def SetWindowSize(frameWidth: int, frameHeight: int) -> void
            extern def InitWindow(width: int, height: int, title: cstr) -> void
            extern def LoadData(file_name: cstr, data_size: ptr[int]) -> ptr[ubyte]
            extern def SaveData(file_name: cstr, data: ptr[void], data_size: int) -> bool
            extern def ReleaseData(data: ptr[ubyte]) -> void
            extern def MemAlloc(size: uint) -> ptr[void]
            extern def TraceLog(level: int, text: cstr, ...) -> void
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
        module std.sample

        import std.c.sample as c

        pub type Color = c.Color
        pub type Mode = c.Mode

        pub const WHITE: Color = c.WHITE

        pub foreign def close_window() -> void = c.CloseWindow
        pub foreign def set_window_size(frame_width: int, frame_height: int) -> void = c.SetWindowSize
        pub foreign def init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
        pub foreign def load_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadData
        pub foreign def save_data(file_name: str as cstr, data: span[ubyte]) -> bool = c.SaveData(file_name, data.data, int<-data.len)
        pub foreign def release_data(consuming data: ptr[ubyte]) -> void = c.ReleaseData
        pub foreign def mem_alloc[T](count: ptr_uint) -> ptr[T]? = c.MemAlloc(count * uint<-size_of(T))
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
        extern module std.c.sample:
            extern def TextFormat(text: cstr, ...) -> cstr
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
        module std.sample

        import std.c.sample as c

        pub foreign def text_format_int(format: str as cstr, value: int) -> cstr = c.TextFormat(format, value)
        pub foreign def text_format_int_int(format: str as cstr, first: int, second: int) -> cstr = c.TextFormat(format, first, second)
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
        extern module std.c.sample:
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
