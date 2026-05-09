# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaImportedBindingsTest < Minitest::Test
  def test_default_registry_exposes_checked_in_imported_bindings
    registry = MilkTea::ImportedBindings.default_registry

    assert_equal ["raylib", "rlgl", "raygui", "sdl3", "box2d", "cjson", "steamworks", "libuv", "libc", "libm"], registry.map(&:name)
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
    assert_match(/^public type IntDiv = c\.div_t$/, source)
    assert_match(/^public type PtrIntDiv = c\.ldiv_t$/, source)
    assert_match(/^public type LongDiv = c\.lldiv_t$/, source)
    assert_match(/^public foreign function parse_int\(text: str as cstr\) -> int = c\.atoi$/, source)
    assert_match(/^public foreign function parse_ptr_int\(text: str as cstr\) -> ptr_int = c\.atol$/, source)
    assert_match(/^public foreign function parse_long\(text: str as cstr\) -> long = c\.atoll$/, source)
    assert_match(/^public foreign function parse_double_with_end\(text: str as cstr, end_ptr: ptr\[ptr\[char\]\]\?\) -> double = c\.strtod$/, source)
    assert_match(/^public foreign function get_env\(name: str as cstr\) -> cstr\? = c\.getenv$/, source)
    assert_match(/^public foreign function set_env\(name: str as cstr, value: str as cstr, replace: int\) -> int = c\.setenv$/, source)
    assert_match(/^public foreign function unset_env\(name: str as cstr\) -> int = c\.unsetenv$/, source)
    assert_match(/^public foreign function mkstemp\[N\]\(template: str_builder\[N\] as ptr\[char\]\) -> int = c\.mkstemp$/, source)
    assert_match(/^public foreign function mkstemps\[N\]\(template: str_builder\[N\] as ptr\[char\], suffix_length: int\) -> int = c\.mkstemps$/, source)
    assert_match(/^public foreign function mkdtemp\[N\]\(template: str_builder\[N\] as ptr\[char\]\) -> cstr\? = c\.mkdtemp$/, source)
    assert_match(/^public foreign function realpath\[N\]\(name: str as cstr, resolved: str_builder\[N\] as ptr\[char\]\) -> cstr\? = c\.realpath$/, source)
    refute_match(/^public foreign function atoi\(/, source)
    refute_match(/^public foreign function atol\(/, source)
    refute_match(/^public foreign function atoll\(/, source)
    refute_match(/^public foreign function putenv\(/, source)
    refute_match(/^public foreign function mktemp\(/, source)
    refute_match(/^public foreign function strtoq\(/, source)
    refute_match(/^public foreign function strtouq\(/, source)
    refute_match(/^public foreign function __ctype_get_mb_cur_max\(/, source)
  end

  def test_checked_in_libm_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("libm")

    assert_includes binding.check!, "/std/c/libm.mt"

    source = File.read(binding.binding_path)
    assert_match(/^module std\.libm$/, source)
    assert_match(/^import std\.c\.libm as c$/, source)
    assert_match(/^public const PI: double = c\.M_PI$/, source)
    assert_match(/^public const PI_F: float = c\.M_PI_F$/, source)
    assert_match(/^public foreign function sqrt\(x: double\) -> double = c\.sqrt$/, source)
    assert_match(/^public foreign function sqrtf\(x: float\) -> float = c\.sqrtf$/, source)
    assert_match(/^public foreign function atan2\(y: double, x: double\) -> double = c\.atan2$/, source)
    assert_match(/^public foreign function atan2f\(y: float, x: float\) -> float = c\.atan2f$/, source)
    refute_match(/^public const M_PI:/, source)
    refute_match(/^public foreign function atan_2\(/, source)
  end

  def test_checked_in_libuv_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("libuv")

    assert_includes binding.check!, "/std/c/libuv.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.c\.libuv_system as sys$/, source)
    assert_match(/^public type uv_loop_t = c\.uv_loop_t$/, source)
    assert_match(/^public type uv_run_mode = c\.uv_run_mode$/, source)
    assert_match(/^public type uv_alloc_cb = c\.uv_alloc_cb$/, source)
    assert_match(/^public foreign function version\(\) -> uint = c\.uv_version$/, source)
    assert_match(/^public foreign function version_string\(\) -> cstr = c\.uv_version_string$/, source)
    assert_match(/^public foreign function default_loop\(\) -> ptr\[uv_loop_t\] = c\.uv_default_loop$/, source)
    assert_match(/^public foreign function loop_init\(loop: ptr\[uv_loop_t\]\) -> int = c\.uv_loop_init$/, source)
    assert_match(/^public foreign function loop_close\(loop: ptr\[uv_loop_t\]\) -> int = c\.uv_loop_close$/, source)
    assert_match(/^public foreign function run\(arg_0: ptr\[uv_loop_t\], mode: uv_run_mode\) -> int = c\.uv_run$/, source)
    refute_match(/^public foreign function uv_version\(/, source)
    refute_match(/^public foreign function loop_configure\(/, source)
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
    assert_match(/^public foreign function malloc\(size: ptr_uint\) -> ptr\[void\] = c\.SDL_malloc$/, source)
    assert_match(/^public foreign function create_window\(title: str as cstr, w: int, h: int, flag_bits: ptr_uint\) -> Window\? = c\.SDL_CreateWindow$/, source)
    assert_match(/^public foreign function create_window_and_renderer\(title: str as cstr, width: int, height: int, window_flags: ptr_uint, out window: Window, out renderer: Renderer\) -> bool = c\.SDL_CreateWindowAndRenderer$/, source)
    assert_match(/^public foreign function run_app\(argc: int, argv: ptr\[ptr\[char\]\], main_function: MainFunc\) -> int = c\.SDL_RunApp\(argc, argv, main_function, null\)$/, source)
    assert_match(/^public foreign function set_app_metadata\(app_name: str as cstr, app_version: str as cstr, app_identifier: str as cstr\) -> bool = c\.SDL_SetAppMetadata$/, source)
    assert_match(/^public foreign function init\(flag_bits: InitFlags\) -> bool = c\.SDL_Init$/, source)
    assert_match(/^public foreign function poll_event\(out event: Event\) -> bool = c\.SDL_PollEvent$/, source)
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
    assert_match(/^public foreign function convert_event_to_render_coordinates\(renderer: Renderer, inout event: Event\) -> bool = c\.SDL_ConvertEventToRenderCoordinates$/, source)
    assert_match(/^public foreign function get_current_time\(out ticks: Time\) -> bool = c\.SDL_GetCurrentTime$/, source)
    assert_match(/^public foreign function time_to_date_time\(ticks: Time, out dt: DateTime, local_time: bool\) -> bool = c\.SDL_TimeToDateTime$/, source)
    assert_match(/^public foreign function render_points\(renderer: Renderer, points: span\[FPoint\]\) -> bool = c\.SDL_RenderPoints\(renderer, points\.data, int<-points\.len\)$/, source)
    assert_match(/^public foreign function render_lines\(renderer: Renderer, points: span\[FPoint\]\) -> bool = c\.SDL_RenderLines\(renderer, points\.data, int<-points\.len\)$/, source)
    assert_match(/^public foreign function render_rect\(renderer: Renderer, in rect: FRect as const_ptr\[FRect\]\) -> bool = c\.SDL_RenderRect$/, source)
    assert_match(/^public foreign function render_rects\(renderer: Renderer, rects: span\[FRect\]\) -> bool = c\.SDL_RenderRects\(renderer, rects\.data, int<-rects\.len\)$/, source)
    assert_match(/^public foreign function render_fill_rect\(renderer: Renderer, in rect: FRect as const_ptr\[FRect\]\) -> bool = c\.SDL_RenderFillRect$/, source)
    assert_match(/^public foreign function render_fill_rects\(renderer: Renderer, rects: span\[FRect\]\) -> bool = c\.SDL_RenderFillRects\(renderer, rects\.data, int<-rects\.len\)$/, source)
    assert_match(/^public foreign function render_debug_text\(renderer: Renderer, x: float, y: float, text: str as cstr\) -> bool = c\.SDL_RenderDebugText$/, source)
    assert_match(/^public foreign function load_png\(file_name: str as cstr\) -> ptr\[Surface\]\? = c\.SDL_LoadPNG$/, source)
    assert_match(/^public foreign function gl_get_proc_address\(proc_: cstr\) -> FunctionPointer\? = c\.SDL_GL_GetProcAddress$/, source)
    assert_match(/^public foreign function egl_get_proc_address\(proc_: cstr\) -> FunctionPointer\? = c\.SDL_EGL_GetProcAddress$/, source)
    assert_match(/^public foreign function gl_get_current_window\(\) -> Window\? = c\.SDL_GL_GetCurrentWindow$/, source)
    assert_match(/^public foreign function gl_get_current_context\(\) -> GLContext\? = c\.SDL_GL_GetCurrentContext$/, source)
    assert_match(/^public foreign function load_object\(sofile: cstr\) -> ptr\[SharedObject\]\? = c\.SDL_LoadObject$/, source)
    assert_match(/^public foreign function load_function\(handle: ptr\[SharedObject\], name: cstr\) -> FunctionPointer\? = c\.SDL_LoadFunction$/, source)
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
    assert_match(/^module std\.cjson$/, source)
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

  def test_generate_rejects_extra_source_policy_escape_hatch
    Dir.mktmpdir("milk-tea-imported-binding-extra-source") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external module std.c.sample:
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
        external module std.c.dep:
            opaque Thing = c"Thing"
      MT

      File.write(raw_path, <<~MT)
        external module std.c.sample:
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

    source = File.read(binding.binding_path)
    refute_match(/^public type __va_list_tag = /, source)
    refute_match(/^public type va_list = /, source)
    refute_match(/^public type TraceLogCallback = /, source)
    refute_match(/^public foreign function set_trace_log_callback\(/, source)
    assert_match(/^import std\.bytes as bytes$/, source)
    assert_match(/^import std\.maybe as maybe$/, source)
    assert_match(/^import std\.vec as vec$/, source)
    assert_match(/^import std\.string as string$/, source)
    assert_match(/^import std\.str as text$/, source)
    assert_match(/^public foreign function load_shader\(vs_file_name: cstr\?, fs_file_name: cstr\?\) -> Shader = c\.LoadShader$/, source)
    assert_match(/^public foreign function load_shader_from_memory\(vs_code: cstr\?, fs_code: cstr\?\) -> Shader = c\.LoadShaderFromMemory$/, source)
    assert_match(/^public foreign function set_shader_value\[T\]\(shader: Shader, loc_index: int, in value: T as const_ptr\[void\], uniform_type: int\) -> void = c\.SetShaderValue$/, source)
    assert_match(/^public foreign function set_shader_value_v\[T\]\(shader: Shader, loc_index: int, value: ptr\[T\] as const_ptr\[void\], uniform_type: int, count: int\) -> void = c\.SetShaderValueV$/, source)
    assert_match(/^public foreign function load_image\(file_name: str as cstr\) -> Image = c\.LoadImage$/, source)
    assert_match(/^public foreign function load_image_raw\(file_name: str as cstr, width: int, height: int, format: int, header_size: int\) -> Image = c\.LoadImageRaw$/, source)
    assert_match(/^public foreign function load_image_anim\(file_name: str as cstr, out frames: int\) -> Image = c\.LoadImageAnim$/, source)
    assert_match(/^public foreign function load_image_from_memory\(file_type: str as cstr, file_data: span\[ubyte\]\) -> Image = c\.LoadImageFromMemory\(file_type, file_data\.data, int<-file_data\.len\)$/, source)
    assert_match(/^public foreign function set_window_title\(title: str as cstr\) -> void = c\.SetWindowTitle$/, source)
    assert_match(/^public foreign function get_monitor_name\(monitor: int\) -> str = text\.cstr_as_str\(c\.GetMonitorName\(monitor\)\)$/, source)
    assert_match(/^public foreign function get_clipboard_text\(\) -> str = text\.cstr_as_str\(c\.GetClipboardText\(\)\)$/, source)
    assert_match(/^public foreign function get_working_directory\(\) -> str = text\.cstr_as_str\(c\.GetWorkingDirectory\(\)\)$/, source)
    assert_match(/^public foreign function get_application_directory\(\) -> str = text\.cstr_as_str\(c\.GetApplicationDirectory\(\)\)$/, source)
    assert_match(/^public foreign function get_file_length\(file_name: str as cstr\) -> int = c\.GetFileLength$/, source)
    assert_match(/^public foreign function get_file_mod_time\(file_name: str as cstr\) -> ptr_int = c\.GetFileModTime$/, source)
    assert_match(/^public foreign function get_file_extension\(file_name: str as cstr\) -> str = text\.cstr_as_str\(c\.GetFileExtension\(file_name\)\)$/, source)
    assert_match(/^public foreign function get_file_name\(file_path: str as cstr\) -> str = text\.cstr_as_str\(c\.GetFileName\(file_path\)\)$/, source)
    assert_match(/^public foreign function get_file_name_without_ext\(file_path: str as cstr\) -> str = text\.cstr_as_str\(c\.GetFileNameWithoutExt\(file_path\)\)$/, source)
    assert_match(/^public foreign function get_directory_path\(file_path: str as cstr\) -> str = text\.cstr_as_str\(c\.GetDirectoryPath\(file_path\)\)$/, source)
    assert_match(/^public foreign function get_prev_directory_path\(dir_path: str as cstr\) -> str = text\.cstr_as_str\(c\.GetPrevDirectoryPath\(dir_path\)\)$/, source)
    assert_match(/^public foreign function make_directory\(dir_path: str as cstr\) -> int = c\.MakeDirectory$/, source)
    assert_match(/^public foreign function change_directory\(dir_path: str as cstr\) -> bool = c\.ChangeDirectory$/, source)
    assert_match(/^public foreign function is_path_file\(path: str as cstr\) -> bool = c\.IsPathFile$/, source)
    assert_match(/^public foreign function is_file_name_valid\(file_name: str as cstr\) -> bool = c\.IsFileNameValid$/, source)
    assert_match(/^public foreign function load_directory_files\(dir_path: str as cstr\) -> FilePathList = c\.LoadDirectoryFiles$/, source)
    assert_match(/^public foreign function load_directory_files_ex\(base_path: str as cstr, filter: str as cstr, scan_subdirs: bool\) -> FilePathList = c\.LoadDirectoryFilesEx$/, source)
    assert_match(/^public foreign function get_directory_file_count\(dir_path: str as cstr\) -> uint = c\.GetDirectoryFileCount$/, source)
    assert_match(/^public foreign function get_directory_file_count_ex\(base_path: str as cstr, filter: str as cstr, scan_subdirs: bool\) -> uint = c\.GetDirectoryFileCountEx$/, source)
    assert_match(/^public foreign function get_key_name\(key: int\) -> str = text\.cstr_as_str\(c\.GetKeyName\(key\)\)$/, source)
    assert_match(/^public foreign function get_gamepad_name\(gamepad: int\) -> str = text\.cstr_as_str\(c\.GetGamepadName\(gamepad\)\)$/, source)
    assert_match(/^public foreign function export_image\(image: Image, file_name: str as cstr\) -> bool = c\.ExportImage$/, source)
    assert_match(/^public foreign function update_texture\[T\]\(texture: Texture, pixels: ptr\[T\] as const_ptr\[void\]\) -> void = c\.UpdateTexture$/, source)
    assert_match(/^public foreign function update_mesh_buffer\[T\]\(mesh: Mesh, index: int, data: ptr\[T\] as const_ptr\[void\], data_size: int, offset: int\) -> void = c\.UpdateMeshBuffer$/, source)
    assert_match(/^public foreign function update_audio_stream\[T\]\(stream: AudioStream, data: ptr\[T\] as const_ptr\[void\], frame_count: int\) -> void = c\.UpdateAudioStream$/, source)
    assert_match(/^public foreign function draw_spline_linear_ptr\(points: const_ptr\[Vector2\], point_count: int, thick: float, color: Color\) -> void = c\.DrawSplineLinear$/, source)
    assert_match(/^foreign function mt_raw_load_file_data\(file_name: str as cstr, out data_size: int\) -> ptr\[ubyte\]\? = c\.LoadFileData$/, source)
    assert_match(/^public function load_file_data\(file_name: str\) -> maybe\.Maybe\[bytes\.Buffer\]:$/, source)
    assert_match(/^    c\.UnloadFileData\(ptr\[ubyte\]<-raw_result\)$/, source)
    refute_match(/^public foreign function load_file_data\(file_name: str as cstr, out data_size: int\) -> ptr\[ubyte\]\? = c\.LoadFileData$/, source)
    refute_match(/^public foreign function unload_file_data\(consuming data: ptr\[ubyte\]\) -> void = c\.UnloadFileData$/, source)
    assert_match(/^foreign function mt_raw_load_file_text\(file_name: str as cstr\) -> ptr\[char\]\? = c\.LoadFileText$/, source)
    assert_match(/^public function load_file_text\(file_name: str\) -> maybe\.Maybe\[string\.String\]:$/, source)
    assert_match(/^    c\.UnloadFileText\(ptr\[char\]<-raw_result\)$/, source)
    refute_match(/^public foreign function load_file_text\(file_name: cstr\) -> ptr\[char\]\? = c\.LoadFileText$/, source)
    refute_match(/^public foreign function unload_file_text\(text: ptr\[char\]\) -> void = c\.UnloadFileText$/, source)
    assert_match(/^foreign function mt_raw_load_utf_8\(codepoints: const_ptr\[int\], length: int\) -> ptr\[char\]\? = c\.LoadUTF8$/, source)
    assert_match(/^public function load_utf_8\(codepoints: const_ptr\[int\], length: int\) -> maybe\.Maybe\[string\.String\]:$/, source)
    assert_match(/^    c\.UnloadUTF8\(ptr\[char\]<-raw_result\)$/, source)
    refute_match(/^public foreign function load_utf_8\(codepoints: const_ptr\[int\], length: int\) -> ptr\[char\]\? = c\.LoadUTF8$/, source)
    refute_match(/^public foreign function unload_utf_8\(text: ptr\[char\]\) -> void = c\.UnloadUTF8$/, source)
    assert_match(/^public foreign function text_format_int_int_int\(format: str as cstr, first: int, second: int, third: int\) -> str = text\.cstr_as_str\(c\.TextFormat\(format, first, second, third\)\)$/, source)
    assert_match(/^public foreign function text_format_cstr_float_float\(format: str as cstr, label: str as cstr, first: float, second: float\) -> str = text\.cstr_as_str\(c\.TextFormat\(format, label, first, second\)\)$/, source)
    assert_match(/^public foreign function image_format\(inout image: Image, new_format: int\) -> void = c\.ImageFormat$/, source)
    assert_match(/^public foreign function image_kernel_convolution\(inout image: Image, kernel: span\[float\]\) -> void = c\.ImageKernelConvolution\(image, kernel\.data, int<-kernel\.len\)$/, source)
    assert_match(/^public foreign function image_draw_text_ex\(inout dst: Image, font: Font, text: str as cstr, position: Vector2, font_size: float, spacing: float, tint: Color\) -> void = c\.ImageDrawTextEx$/, source)
    assert_match(/^public foreign function draw_text_ex\(font: Font, text: str as cstr, position: Vector2, font_size: float, spacing: float, tint: Color\) -> void = c\.DrawTextEx$/, source)
    assert_match(/^public foreign function load_font\(file_name: str as cstr\) -> Font = c\.LoadFont$/, source)
    assert_match(/^public foreign function load_font_ex\(file_name: str as cstr, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int\) -> Font = c\.LoadFontEx$/, source)
    assert_match(/^public foreign function load_sound\(file_name: str as cstr\) -> Sound = c\.LoadSound$/, source)
    assert_match(/^public foreign function load_wave_from_memory\(file_type: str as cstr, file_data: span\[ubyte\]\) -> Wave = c\.LoadWaveFromMemory\(file_type, file_data\.data, int<-file_data\.len\)$/, source)
    assert_match(/^public foreign function set_clipboard_text\(text: str as cstr\) -> void = c\.SetClipboardText$/, source)
    assert_match(/^public foreign function load_font_from_memory\(file_type: cstr, file_data: const_ptr\[ubyte\], data_size: int, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int\) -> Font = c\.LoadFontFromMemory$/, source)
    assert_match(/^public foreign function gen_texture_mipmaps\(inout texture: Texture2D\) -> void = c\.GenTextureMipmaps$/, source)
    assert_match(/^public foreign function load_font_data\(file_data: const_ptr\[ubyte\], data_size: int, font_size: int, codepoints: ptr\[int\]\?, codepoint_count: int, kind: FontType, out glyph_count: int\) -> ptr\[GlyphInfo\] = c\.LoadFontData$/, source)
    assert_match(/^public foreign function gen_image_font_atlas\(glyphs: const_ptr\[GlyphInfo\], out glyph_recs: ptr\[Rectangle\], glyph_count: int, font_size: int, padding: int, pack_method: int\) -> Image = c\.GenImageFontAtlas$/, source)
    assert_match(/^foreign function mt_raw_load_codepoints\(text: str as cstr, out count: int\) -> ptr\[int\]\? = c\.LoadCodepoints$/, source)
    assert_match(/^public function load_codepoints\(text: str\) -> maybe\.Maybe\[vec\.Vec\[int\]\]:$/, source)
    assert_match(/^    c\.UnloadCodepoints\(ptr\[int\]<-raw_result\)$/, source)
    refute_match(/^public foreign function load_codepoints_ptr\(text: str as cstr, out count: int\) -> ptr\[int\]\? = c\.LoadCodepoints$/, source)
    refute_match(/^public foreign function unload_codepoints\(codepoints: ptr\[int\]\) -> void = c\.UnloadCodepoints$/, source)
    assert_match(/^public foreign function codepoint_to_utf_8\(codepoint: int, out utf_8_size: int\) -> str = text\.cstr_as_str\(c\.CodepointToUTF8\(codepoint, utf_8_size\)\)$/, source)
    assert_match(/^public foreign function text_subtext\(text: str as cstr, position: int, length: int\) -> str = text\.cstr_as_str\(c\.TextSubtext\(text, position, length\)\)$/, source)
    assert_match(/^public foreign function text_remove_spaces\(text: str as cstr\) -> str = text\.cstr_as_str\(c\.TextRemoveSpaces\(text\)\)$/, source)
    assert_match(/^public foreign function load_fragment_shader\(fs_file_name: str as cstr\) -> Shader = c\.LoadShader\(null, fs_file_name\)$/, source)
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
    assert_match(/^import std\.raylib as raylib$/, source)
    assert_match(/^public type Matrix = raylib\.Matrix$/, source)
    assert_match(/^public foreign function matrix_mode\(mode: int\) -> void = c\.rlMatrixMode$/, source)
    assert_match(/^public foreign function load_vertex_buffer\[T\]\(buffer: ptr\[T\] as const_ptr\[void\], size: int, dynamic: bool\) -> uint = c\.rlLoadVertexBuffer$/, source)
    assert_match(/^public foreign function load_texture\(data: const_ptr\[void\]\?, width: int, height: int, format: int, mipmap_count: int\) -> uint = c\.rlLoadTexture$/, source)
    assert_match(/^public foreign function load_texture_cubemap\(data: const_ptr\[void\]\?, size: int, format: int, mipmap_count: int\) -> uint = c\.rlLoadTextureCubemap$/, source)
    assert_match(/^public foreign function get_proc_address\(proc_name: cstr\) -> ptr\[void\]\? = c\.rlGetProcAddress$/, source)
    assert_match(/^public foreign function set_uniform\[T\]\(loc_index: int, value: ptr\[T\] as const_ptr\[void\], uniform_type: int, count: int\) -> void = c\.rlSetUniform$/, source)
    assert_match(/^public foreign function load_shader_buffer\(size: uint, data: const_ptr\[void\]\?, usage_hint: int\) -> uint = c\.rlLoadShaderBuffer$/, source)
    assert_match(/^public foreign function update_shader_buffer\[T\]\(id: uint, data: ptr\[T\] as const_ptr\[void\], data_size: uint, offset: uint\) -> void = c\.rlUpdateShaderBuffer$/, source)
  end

  def test_checked_in_raygui_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("raygui")

    assert_includes binding.check!, "/std/c/raygui.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.raylib as raylib$/, source)
    assert_match(/^public type Rectangle = raylib\.Rectangle$/, source)
    assert_match(/^public type State = c\.GuiState$/, source)
    assert_match(/^public foreign function set_state\(state: State\) -> void = c\.GuiSetState\(int<-state\)$/, source)
    assert_match(/^public foreign function get_state\(\) -> State = State<-c\.GuiGetState\(\)$/, source)
    assert_match(/^public foreign function get_icons\(\) -> span\[uint\] = span\[uint\]\(data = c\.GuiGetIcons\(\), len = 2048\)$/, source)
    assert_match(/^public foreign function tab_bar\(bounds: Rectangle, text: span\[str\] as span\[ptr\[char\]\], inout active: int\) -> int = c\.GuiTabBar\(bounds, text\.data, int<-text\.len, active\)$/, source)
    assert_match(/^public foreign function scroll_panel\(bounds: Rectangle, text: str as cstr, content: Rectangle, inout scroll: Vector2, out view: Rectangle\) -> int = c\.GuiScrollPanel$/, source)
    assert_match(/^public foreign function toggle\(bounds: Rectangle, text: str as cstr, inout active: bool\) -> int = c\.GuiToggle$/, source)
    assert_match(/^public foreign function list_view_ex\(bounds: Rectangle, text: span\[str\] as span\[ptr\[char\]\], inout scroll_index: int, inout active: int, inout focus: int\) -> int = c\.GuiListViewEx\(bounds, text\.data, int<-text\.len, scroll_index, active, focus\)$/, source)
    assert_match(/^public foreign function value_box_float\[N\]\(bounds: Rectangle, text: str as cstr, text_value: str_builder\[N\] as ptr\[char\], inout value: float, edit_mode: bool\) -> int = c\.GuiValueBoxFloat\(bounds, text, text_value, value, edit_mode\)$/, source)
    assert_match(/^public foreign function text_box\[N\]\(bounds: Rectangle, text: str_builder\[N\] as ptr\[char\], edit_mode: bool\) -> int = c\.GuiTextBox\(bounds, text, int<-\(text_public\.capacity\(\) \+ 1\), edit_mode\)$/, source)
    assert_match(/^public foreign function text_input_box\[N\]\(bounds: Rectangle, title: str as cstr, message: str as cstr, buttons: str as cstr, text: str_builder\[N\] as ptr\[char\], inout secret_view_active: bool\) -> int = c\.GuiTextInputBox\(bounds, title, message, buttons, text, int<-\(text_public\.capacity\(\) \+ 1\), secret_view_active\)$/, source)
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
    assert_match(/^import std\.str as text$/, source)
    assert_match(/^public type AppId_t = c\.AppId_t$/, source)
    assert_match(/^public type Friends = c\.ISteamFriends$/, source)
    assert_match(/^public type ErrMsg = c\.SteamErrMsg$/, source)
    assert_match(/^public type EAPIInitResult = c\.ESteamAPIInitResult$/, source)
    assert_match(/^public const k_flMaxTimelineEventDuration: float = c\.k_flMaxTimelineEventDuration$/, source)
    assert_match(/^public foreign function restart_app_if_necessary\(un_own_app_id: uint\) -> bool = c\.SteamAPI_RestartAppIfNecessary$/, source)
    assert_match(/^public foreign function init\(\) -> bool = c\.SteamAPI_Init$/, source)
    assert_match(/^public foreign function shutdown\(\) -> void = c\.SteamAPI_Shutdown$/, source)
    assert_match(/^public foreign function friends\(\) -> ptr\[Friends\] = c\.SteamAPI_SteamFriends$/, source)
    assert_match(/^public foreign function friends_get_persona_name\(self: ptr\[Friends\]\) -> str = text\.cstr_as_str\(c\.SteamAPI_ISteamFriends_GetPersonaName\(self\)\)$/, source)
    assert_match(/^public foreign function internal_context_init\(p_context_init_data: ptr\[void\]\) -> ptr\[void\] = c\.SteamInternal_ContextInit$/, source)
    refute_match(/^public foreign function steam_api_init\(/, source)
    refute_match(/^public foreign function steam_api_i_steam_friends_get_persona_name\(/, source)
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
        external module std.c.sample:
            struct Matrix:
                m0: float

            enum rlMode: int
                RL_MODE_DEFAULT = 1

            const IDENTITY: Matrix = Matrix(m0 = 1.0)

            external function rlSetMatrix(matrix: Matrix) -> void
            external function rlGetMode() -> rlMode
      MT

      File.write(shared_path, <<~MT)
        module std.shared

        import std.c.sample as c

        public type Matrix = c.Matrix
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

        public type Matrix = shared.Matrix
        public type Mode = c.rlMode

        public const IDENTITY: Matrix = c.IDENTITY

        public foreign function set_matrix(matrix: Matrix) -> void = c.rlSetMatrix
        public foreign function get_mode() -> Mode = c.rlGetMode
      MT

      module_roots = [dir, MilkTea.root]

      generated = binding.generate(module_roots: module_roots)
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: module_roots)
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
        external module std.c.sample:
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
        module std.sample

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

  def test_generate_supports_owned_string_wrappers_for_raw_pointer_results
    Dir.mktmpdir("milk-tea-imported-binding-owned-string-wrapper") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external module std.c.sample:
            external function LoadText(file_name: cstr) -> ptr[char]?
            external function UnloadText(text: ptr[char]) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        imports: [
          {
            module_name: "std.maybe",
            alias: "maybe",
          },
          {
            module_name: "std.str",
            alias: "text",
          },
          {
            module_name: "std.string",
            alias: "string",
          },
        ],
        types: {},
        constants: {},
        functions: {
          include: [],
          overrides: [
            {
              raw: "LoadText",
              name: "load_text",
              params: [
                {
                  name: "file_name",
                  type: "str",
                  boundary_type: "cstr",
                },
              ],
              wrapper: {
                kind: "owned_string",
                maybe_alias: "maybe",
                text_alias: "text",
                string_alias: "string",
                release: "c.UnloadText",
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

      expected = [
        "# generated by mtc imported-bindings from std.c.sample using sample.binding.json",
        "module std.sample",
        "",
        "import std.c.sample as c",
        "import std.maybe as maybe",
        "import std.str as text",
        "import std.string as string",
        "",
        "foreign function mt_raw_load_text(file_name: str as cstr) -> ptr[char]? = c.LoadText",
        "",
        "",
        "public function load_text(file_name: str) -> maybe.Maybe[string.String]:",
        "    let raw_result = mt_raw_load_text(file_name)",
        "    if raw_result == null:",
        "        return maybe.Maybe[string.String].none",
        "",
        "    let value = string.String.from_str(text.chars_as_str(ptr[char]<-raw_result))",
        "    c.UnloadText(ptr[char]<-raw_result)",
        "    return maybe.Maybe[string.String].some(value= value)",
      ].join("\n") + "\n"

      module_roots = [dir, MilkTea.root]

      generated = binding.generate(module_roots: module_roots)
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: module_roots)
    end
  end

  def test_generate_supports_owned_bytes_wrappers_for_pointer_and_count_results
    Dir.mktmpdir("milk-tea-imported-binding-owned-bytes-wrapper") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external module std.c.sample:
            external function LoadData(file_name: cstr, data_size: ptr[int]) -> ptr[ubyte]?
            external function UnloadData(data: ptr[ubyte]) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        imports: [
          {
            module_name: "std.bytes",
            alias: "bytes",
          },
          {
            module_name: "std.maybe",
            alias: "maybe",
          },
        ],
        types: {},
        constants: {},
        functions: {
          include: [],
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
              wrapper: {
                kind: "owned_bytes",
                maybe_alias: "maybe",
                bytes_alias: "bytes",
                release: "c.UnloadData",
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

      expected = [
        "# generated by mtc imported-bindings from std.c.sample using sample.binding.json",
        "module std.sample",
        "",
        "import std.c.sample as c",
        "import std.bytes as bytes",
        "import std.maybe as maybe",
        "",
        "foreign function mt_raw_load_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadData",
        "",
        "",
        "public function load_data(file_name: str) -> maybe.Maybe[bytes.Buffer]:",
        "    var data_size = 0",
        "    let raw_result = mt_raw_load_data(file_name, data_size)",
        "    if raw_result == null:",
        "        return maybe.Maybe[bytes.Buffer].none",
        "",
        "    if data_size < 0:",
        "        c.UnloadData(ptr[ubyte]<-raw_result)",
        "        fatal(c\"imported wrapper load_data returned negative size\")",
        "",
        "    var value = bytes.with_capacity(ptr_uint<-data_size)",
        "    bytes.append(ref_of(value), span[ubyte](data = ptr[ubyte]<-raw_result, len = ptr_uint<-data_size))",
        "    c.UnloadData(ptr[ubyte]<-raw_result)",
        "    return maybe.Maybe[bytes.Buffer].some(value= value)",
      ].join("\n") + "\n"

      module_roots = [dir, MilkTea.root]

      generated = binding.generate(module_roots: module_roots)
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: module_roots)
    end
  end

  def test_generate_supports_owned_vec_wrappers_for_pointer_and_count_results
    Dir.mktmpdir("milk-tea-imported-binding-owned-vec-wrapper") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external module std.c.sample:
            external function LoadItems(text: cstr, count: ptr[int]) -> ptr[int]?
            external function UnloadItems(items: ptr[int]) -> void
      MT

      File.write(policy_path, JSON.pretty_generate({
        module_name: "std.sample",
        raw_module_name: "std.c.sample",
        raw_import_alias: "c",
        imports: [
          {
            module_name: "std.maybe",
            alias: "maybe",
          },
          {
            module_name: "std.vec",
            alias: "vec",
          },
        ],
        types: {},
        constants: {},
        functions: {
          include: [],
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
              wrapper: {
                kind: "owned_vec",
                maybe_alias: "maybe",
                vec_alias: "vec",
                release: "c.UnloadItems",
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

      expected = <<~MT
        # generated by mtc imported-bindings from std.c.sample using sample.binding.json
        module std.sample

        import std.c.sample as c
        import std.maybe as maybe
        import std.vec as vec

        foreign function mt_raw_load_items(text: str as cstr, out count: int) -> ptr[int]? = c.LoadItems


        public function load_items(text: str) -> maybe.Maybe[vec.Vec[int]]:
            var count = 0
            let raw_result = mt_raw_load_items(text, count)
            if count < 0:
                if raw_result != null:
                    c.UnloadItems(ptr[int]<-raw_result)
                fatal(c"imported wrapper load_items returned negative count")

            var value = vec.Vec[int].with_capacity(ptr_uint<-count)
            if count == 0:
                if raw_result != null:
                    c.UnloadItems(ptr[int]<-raw_result)
                return maybe.Maybe[vec.Vec[int]].some(value= value)

            if raw_result == null:
                return maybe.Maybe[vec.Vec[int]].none

            var index: ptr_uint = 0
            while index < ptr_uint<-count:
                unsafe:
                    value.push(read(ptr[int]<-raw_result + index))
                index += 1
            c.UnloadItems(ptr[int]<-raw_result)
            return maybe.Maybe[vec.Vec[int]].some(value= value)
      MT

      module_roots = [dir, MilkTea.root]

      generated = binding.generate(module_roots: module_roots)
      assert_equal expected, generated

      File.write(binding_path, generated)
      assert_equal File.expand_path(raw_path), binding.check!(module_roots: module_roots)
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
        external module std.c.sample:
            struct Matrix:
                m0: float

            enum rlMode: int
                RL_MODE_DEFAULT = 1

            const IDENTITY: Matrix = Matrix(m0 = 1.0)

            external function rlSetMatrix(matrix: Matrix) -> void
            external function rlGetMatrix() -> Matrix
            external function rlGetMode() -> rlMode
      MT

      File.write(shared_path, <<~MT)
        module std.shared

        import std.c.sample as c

        public type Matrix = c.Matrix
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

        public type Matrix = shared.Matrix
        public type Mode = c.rlMode

        public const IDENTITY: Matrix = c.IDENTITY

        public foreign function set_matrix(matrix: Matrix) -> void = c.rlSetMatrix
        public foreign function get_matrix() -> Matrix = c.rlGetMatrix
        public foreign function get_mode() -> Mode = c.rlGetMode
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
        external module std.c.sample:
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

      File.write(shared_path, <<~MT)
        module std.shared

        import std.c.sample as c

        public type Color = c.Color
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

        public type Color = shared.Color
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
        external module std.c.sample:
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
        module std.sample

        import std.c.sample as c

        public type Friends = c.ISteamFriends
        public type NetworkingMessages = c.ISteamNetworkingMessages
        public type ErrMsg = c.SteamErrMsg
        public type EAPIInitResult = c.ESteamAPIInitResult

        public const k_flMaxTimelineEventDuration: float = c.k_flMaxTimelineEventDuration

        public foreign function init() -> bool = c.SteamAPI_Init
        public foreign function friends() -> ptr[Friends] = c.SteamAPI_SteamFriends
        public foreign function friends_get_persona_name(self: ptr[Friends]) -> cstr = c.SteamAPI_ISteamFriends_GetPersonaName
        public foreign function networking_messages_v_002() -> ptr[NetworkingMessages] = c.SteamAPI_SteamNetworkingMessages_SteamAPI_v002
        public foreign function internal_context_init(p_context_init_data: ptr[void]) -> ptr[void] = c.SteamInternal_ContextInit
        public foreign function steam_game_server_run_callbacks() -> void = c.SteamGameServer_RunCallbacks
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
        external module std.c.sample:
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
        module std.sample

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
        external module std.c.sample:
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
        module std.sample

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

  def test_check_reports_binding_drift_with_regeneration_task_name
    Dir.mktmpdir("milk-tea-imported-binding-drift") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "bindings", "imported", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.write(raw_path, <<~MT)
        external module std.c.sample:
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
