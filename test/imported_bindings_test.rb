# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "test_helper"

class MilkTeaImportedBindingsTest < Minitest::Test
  def test_default_registry_exposes_checked_in_imported_bindings
    registry = MilkTea::ImportedBindings.default_registry

    assert_equal ["raylib", "rlgl", "raygui", "sdl3", "libuv"], registry.map(&:name)
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

    assert_equal "std.libuv", registry.fetch("libuv").module_name
    assert_equal "std.c.libuv", registry.fetch("libuv").raw_module_name
    assert_includes registry.fetch("libuv").binding_path, "/std/libuv.mt"
    assert_includes registry.fetch("libuv").policy_path, "/bindings/imported/libuv.binding.json"
  end

  def test_checked_in_libuv_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("libuv")

    assert_includes binding.check!, "/std/c/libuv.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.c\.libuv_system as sys$/, source)
    assert_match(/^pub type uv_loop_t = c\.uv_loop_t$/, source)
    assert_match(/^pub type uv_run_mode = c\.uv_run_mode$/, source)
    assert_match(/^pub type uv_alloc_cb = c\.uv_alloc_cb$/, source)
    assert_match(/^pub const RUN_DEFAULT: uv_run_mode = c\.UV_RUN_DEFAULT$/, source)
    assert_match(/^pub const RUN_NOWAIT: uv_run_mode = c\.UV_RUN_NOWAIT$/, source)
    assert_match(/^pub foreign def version\(\) -> u32 = c\.uv_version$/, source)
    assert_match(/^pub foreign def version_string\(\) -> cstr = c\.uv_version_string$/, source)
    assert_match(/^pub foreign def default_loop\(\) -> ptr\[uv_loop_t\] = c\.uv_default_loop$/, source)
    assert_match(/^pub foreign def loop_init\(loop: ptr\[uv_loop_t\]\) -> i32 = c\.uv_loop_init$/, source)
    assert_match(/^pub foreign def loop_close\(loop: ptr\[uv_loop_t\]\) -> i32 = c\.uv_loop_close$/, source)
    assert_match(/^pub foreign def run\(arg0: ptr\[uv_loop_t\], mode: uv_run_mode\) -> i32 = c\.uv_run$/, source)
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
    assert_match(/^pub const INIT_VIDEO: u32 = c\.SDL_INIT_VIDEO$/, source)
    assert_match(/^pub foreign def malloc\(size: usize\) -> ptr\[void\] = c\.SDL_malloc$/, source)
    assert_match(/^pub foreign def create_window\(title: str as cstr, w: i32, h: i32, flags: usize\) -> ptr\[Window\] = c\.SDL_CreateWindow$/, source)
    assert_match(/^pub foreign def create_window_and_renderer\(title: str as cstr, width: i32, height: i32, window_flags: usize, out window: ptr\[Window\], out renderer: ptr\[Renderer\]\) -> bool = c\.SDL_CreateWindowAndRenderer$/, source)
    assert_match(/^pub foreign def run_app\(argc: i32, argv: ptr\[ptr\[char\]\], main_function: MainFunc\) -> i32 = c\.SDL_RunApp\(argc, argv, main_function, null\)$/, source)
    assert_match(/^pub foreign def set_app_metadata\(app_name: str as cstr, app_version: str as cstr, app_identifier: str as cstr\) -> bool = c\.SDL_SetAppMetadata$/, source)
    assert_match(/^pub foreign def init\(flags: InitFlags\) -> bool = c\.SDL_Init$/, source)
    assert_match(/^pub foreign def poll_event\(out event: Event\) -> bool = c\.SDL_PollEvent$/, source)
    assert_match(/^pub foreign def set_clipboard_text\(text: str as cstr\) -> bool = c\.SDL_SetClipboardText$/, source)
    assert_match(/^pub foreign def get_window_size\(window: ptr\[Window\], out w: i32, out h: i32\) -> bool = c\.SDL_GetWindowSize$/, source)
    assert_match(/^pub foreign def get_render_output_size\(renderer: ptr\[Renderer\], out w: i32, out h: i32\) -> bool = c\.SDL_GetRenderOutputSize$/, source)
    assert_match(/^pub foreign def get_power_info\(out seconds: i32, out percent: i32\) -> PowerState = c\.SDL_GetPowerInfo$/, source)
    assert_match(/^pub foreign def get_preferred_locales\(out count: i32\) -> ptr\[ptr\[Locale\]\]\? = c\.SDL_GetPreferredLocales$/, source)
    assert_match(/^pub foreign def convert_event_to_render_coordinates\(renderer: ptr\[Renderer\], inout event: Event\) -> bool = c\.SDL_ConvertEventToRenderCoordinates$/, source)
    assert_match(/^pub foreign def get_current_time\(out ticks: Time\) -> bool = c\.SDL_GetCurrentTime$/, source)
    assert_match(/^pub foreign def time_to_date_time\(ticks: Time, out dt: DateTime, local_time: bool\) -> bool = c\.SDL_TimeToDateTime$/, source)
    assert_match(/^pub foreign def render_debug_text\(renderer: ptr\[Renderer\], x: f32, y: f32, text: str as cstr\) -> bool = c\.SDL_RenderDebugText$/, source)
    assert_match(/^pub foreign def load_png\(file_name: str as cstr\) -> ptr\[Surface\]\? = c\.SDL_LoadPNG$/, source)
    refute_match(/^pub def cstr_as_str\(text: cstr\) -> str:$/, source)
    refute_match(/^pub def free_chars\(text: ptr\[char\]\?\) -> void:$/, source)
    refute_match(/^pub def preferred_locale_at\(locales: ptr\[ptr\[Locale\]\], index: i32\) -> ptr\[Locale\]\?:$/, source)
    refute_match(/^pub def free_preferred_locales\(locales: ptr\[ptr\[Locale\]\]\?\) -> void:$/, source)
    refute_match(/^pub def preferred_locale_string\(locale: ptr\[Locale\]\) -> string\.String:$/, source)
    refute_match(/^pub def render_debug_text_str\(renderer: ptr\[Renderer\], x: f32, y: f32, text: str\) -> bool:$/, source)
    assert_match(/^pub foreign def quit\(\) -> void = c\.SDL_Quit$/, source)
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
    assert_match(/^pub foreign def set_shader_value\[T\]\(shader: Shader, loc_index: i32, in value: T as const_ptr\[void\], uniform_type: i32\) -> void = c\.SetShaderValue$/, source)
    assert_match(/^pub foreign def set_shader_value_v\[T\]\(shader: Shader, loc_index: i32, value: ptr\[T\] as const_ptr\[void\], uniform_type: i32, count: i32\) -> void = c\.SetShaderValueV$/, source)
    assert_match(/^pub foreign def load_image\(file_name: str as cstr\) -> Image = c\.LoadImage$/, source)
    assert_match(/^pub foreign def load_image_raw\(file_name: str as cstr, width: i32, height: i32, format: i32, header_size: i32\) -> Image = c\.LoadImageRaw$/, source)
    assert_match(/^pub foreign def load_image_anim\(file_name: str as cstr, out frames: i32\) -> Image = c\.LoadImageAnim$/, source)
    assert_match(/^pub foreign def export_image\(image: Image, file_name: str as cstr\) -> bool = c\.ExportImage$/, source)
    assert_match(/^pub foreign def update_texture\[T\]\(texture: Texture, pixels: ptr\[T\] as const_ptr\[void\]\) -> void = c\.UpdateTexture$/, source)
    assert_match(/^pub foreign def update_mesh_buffer\[T\]\(mesh: Mesh, index: i32, data: ptr\[T\] as const_ptr\[void\], data_size: i32, offset: i32\) -> void = c\.UpdateMeshBuffer$/, source)
    assert_match(/^pub foreign def update_audio_stream\[T\]\(stream: AudioStream, data: ptr\[T\] as const_ptr\[void\], frame_count: i32\) -> void = c\.UpdateAudioStream$/, source)
    assert_match(/^pub foreign def draw_spline_linear_ptr\(points: const_ptr\[Vector2\], point_count: i32, thick: f32, color: Color\) -> void = c\.DrawSplineLinear$/, source)
    assert_match(/^pub foreign def text_format_i32_i32_i32\(format: str as cstr, first: i32, second: i32, third: i32\) -> cstr = c\.TextFormat\(format, first, second, third\)$/, source)
    assert_match(/^pub foreign def text_format_cstr_f32_f32\(format: str as cstr, label: str as cstr, first: f32, second: f32\) -> cstr = c\.TextFormat\(format, label, first, second\)$/, source)
    assert_match(/^pub foreign def image_format\(inout image: Image, new_format: i32\) -> void = c\.ImageFormat$/, source)
    assert_match(/^pub foreign def image_draw_text_ex\(inout dst: Image, font: Font, text: str as cstr, position: Vector2, font_size: f32, spacing: f32, tint: Color\) -> void = c\.ImageDrawTextEx$/, source)
    assert_match(/^pub foreign def draw_text_ex\(font: Font, text: str as cstr, position: Vector2, font_size: f32, spacing: f32, tint: Color\) -> void = c\.DrawTextEx$/, source)
    assert_match(/^pub foreign def load_font\(file_name: str as cstr\) -> Font = c\.LoadFont$/, source)
    assert_match(/^pub foreign def load_font_ex\(file_name: str as cstr, font_size: i32, codepoints: ptr\[i32\]\?, codepoint_count: i32\) -> Font = c\.LoadFontEx$/, source)
    assert_match(/^pub foreign def load_sound\(file_name: str as cstr\) -> Sound = c\.LoadSound$/, source)
    assert_match(/^pub foreign def load_font_from_memory\(file_type: cstr, file_data: const_ptr\[u8\], data_size: i32, font_size: i32, codepoints: ptr\[i32\]\?, codepoint_count: i32\) -> Font = c\.LoadFontFromMemory$/, source)
    assert_match(/^pub foreign def gen_texture_mipmaps\(inout texture: Texture2D\) -> void = c\.GenTextureMipmaps$/, source)
    assert_match(/^pub foreign def load_font_data\(file_data: const_ptr\[u8\], data_size: i32, font_size: i32, codepoints: ptr\[i32\]\?, codepoint_count: i32, type: FontType, out glyph_count: i32\) -> ptr\[GlyphInfo\] = c\.LoadFontData$/, source)
    assert_match(/^pub foreign def gen_image_font_atlas\(glyphs: const_ptr\[GlyphInfo\], out glyph_recs: ptr\[Rectangle\], glyph_count: i32, font_size: i32, padding: i32, pack_method: i32\) -> Image = c\.GenImageFontAtlas$/, source)
    assert_match(/^pub foreign def load_codepoints_ptr\(text: str as cstr, out count: i32\) -> ptr\[i32\] = c\.LoadCodepoints$/, source)
    assert_match(/^pub foreign def load_fragment_shader\(fs_file_name: str as cstr\) -> Shader = c\.LoadShader\(null, fs_file_name\)$/, source)
    refute_match(/^# extension from /, source)
    refute_match(/^pub struct CodepointList:$/, source)
    refute_match(/^pub def load_codepoints\(text: str\) -> CodepointList:$/, source)
    refute_match(/^pub def file_path_at\(files: FilePathList, index: i32\) -> cstr:$/, source)
    refute_match(/^pub def update_texture_from_image\(texture: Texture, image: Image\) -> void:$/, source)
    refute_match(/^pub def set_shader_vec4\(shader: Shader, loc_index: i32, value: Vector4\) -> void:$/, source)
  end

  def test_checked_in_rlgl_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("rlgl")

    assert_includes binding.check!, "/std/c/rlgl.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.raylib as raylib$/, source)
    assert_match(/^pub type Matrix = raylib\.Matrix$/, source)
    assert_match(/^pub foreign def matrix_mode\(mode: i32\) -> void = c\.rlMatrixMode$/, source)
    assert_match(/^pub foreign def load_vertex_buffer\[T\]\(buffer: ptr\[T\] as const_ptr\[void\], size: i32, dynamic: bool\) -> u32 = c\.rlLoadVertexBuffer$/, source)
    assert_match(/^pub foreign def load_texture\(data: const_ptr\[void\]\?, width: i32, height: i32, format: i32, mipmap_count: i32\) -> u32 = c\.rlLoadTexture$/, source)
    assert_match(/^pub foreign def load_texture_cubemap\(data: const_ptr\[void\]\?, size: i32, format: i32, mipmap_count: i32\) -> u32 = c\.rlLoadTextureCubemap$/, source)
    assert_match(/^pub foreign def set_uniform\[T\]\(loc_index: i32, value: ptr\[T\] as const_ptr\[void\], uniform_type: i32, count: i32\) -> void = c\.rlSetUniform$/, source)
    assert_match(/^pub foreign def load_shader_buffer\(size: u32, data: const_ptr\[void\]\?, usage_hint: i32\) -> u32 = c\.rlLoadShaderBuffer$/, source)
    assert_match(/^pub foreign def update_shader_buffer\[T\]\(id: u32, data: ptr\[T\] as const_ptr\[void\], data_size: u32, offset: u32\) -> void = c\.rlUpdateShaderBuffer$/, source)
  end

  def test_checked_in_raygui_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("raygui")

    assert_includes binding.check!, "/std/c/raygui.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.raylib as raylib$/, source)
    assert_match(/^pub type Rectangle = raylib\.Rectangle$/, source)
    assert_match(/^pub type State = c\.GuiState$/, source)
    assert_match(/^pub foreign def set_state\(state: State\) -> void = c\.GuiSetState\(cast\[i32\]\(state\)\)$/, source)
    assert_match(/^pub foreign def get_state\(\) -> State = cast\[State\]\(c\.GuiGetState\(\)\)$/, source)
    assert_match(/^pub foreign def get_icons\(\) -> span\[u32\] = span\[u32\]\(data = c\.GuiGetIcons\(\), len = 2048\)$/, source)
    assert_match(/^pub foreign def tab_bar\(bounds: Rectangle, text: span\[str\] as span\[ptr\[char\]\], inout active: i32\) -> i32 = c\.GuiTabBar\(bounds, text\.data, cast\[i32\]\(text\.len\), active\)$/, source)
    assert_match(/^pub foreign def scroll_panel\(bounds: Rectangle, text: str as cstr, content: Rectangle, inout scroll: Vector2, out view: Rectangle\) -> i32 = c\.GuiScrollPanel$/, source)
    assert_match(/^pub foreign def toggle\(bounds: Rectangle, text: str as cstr, inout active: bool\) -> i32 = c\.GuiToggle$/, source)
    assert_match(/^pub foreign def list_view_ex\(bounds: Rectangle, text: span\[str\] as span\[ptr\[char\]\], inout scroll_index: i32, inout active: i32, inout focus: i32\) -> i32 = c\.GuiListViewEx\(bounds, text\.data, cast\[i32\]\(text\.len\), scroll_index, active, focus\)$/, source)
    assert_match(/^pub foreign def value_box_float\[N\]\(bounds: Rectangle, text: str as cstr, text_value: str_builder\[N\] as ptr\[char\], inout value: f32, edit_mode: bool\) -> i32 = c\.GuiValueBoxFloat\(bounds, text, text_value, value, edit_mode\)$/, source)
    assert_match(/^pub foreign def text_box\[N\]\(bounds: Rectangle, text: str_builder\[N\] as ptr\[char\], edit_mode: bool\) -> i32 = c\.GuiTextBox\(bounds, text, cast\[i32\]\(text_public\.capacity\(\) \+ 1\), edit_mode\)$/, source)
    assert_match(/^pub foreign def text_input_box\[N\]\(bounds: Rectangle, title: str as cstr, message: str as cstr, buttons: str as cstr, text: str_builder\[N\] as ptr\[char\], inout secret_view_active: bool\) -> i32 = c\.GuiTextInputBox\(bounds, title, message, buttons, text, cast\[i32\]\(text_public\.capacity\(\) \+ 1\), secret_view_active\)$/, source)
  end

  def test_imported_bindings_outside_raylib_and_rlgl_do_not_expose_raw_ptr_void
    offending_bindings = MilkTea::ImportedBindings.default_registry.reject do |binding|
      %w[raylib rlgl sdl3 libuv].include?(binding.name)
    end.filter_map do |binding|
      binding.name if File.read(binding.binding_path).match?(/\bptr\[void\]\b/)
    end

    assert_empty offending_bindings, "unexpected raw ptr[void] surfaces in imported bindings: #{offending_bindings.join(", ")}"
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
                m0: f32

            enum rlMode: i32
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
                m0: f32

            enum rlMode: i32
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
                r: u8

            enum GuiState: i32
                STATE_NORMAL = 0

            enum GuiIconName: i32
                ICON_NONE = 0

            const RAYGUI_VERSION_MAJOR: i32 = 4
            const SCROLLBAR_LEFT_SIDE: i32 = 0

            extern def InitWindow() -> void
            extern def GuiSetState(state: i32) -> void
            extern def GuiDrawIcon(iconId: i32, color: Color) -> void
            extern def GuiLabel(text: cstr) -> i32
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

        pub const RAYGUI_VERSION_MAJOR: i32 = c.RAYGUI_VERSION_MAJOR
        pub const SCROLLBAR_LEFT_SIDE: i32 = c.SCROLLBAR_LEFT_SIDE

        pub foreign def set_state(state: State) -> void = c.GuiSetState
        pub foreign def draw_icon(icon_id: IconName, color: Color) -> void = c.GuiDrawIcon
        pub foreign def label(text: str as cstr) -> i32 = c.GuiLabel
      MT

      generated = binding.generate(module_roots: [dir])
      assert_equal expected, generated
      refute_match(/^pub foreign def init_window\(/, generated)
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
                r: u8
                g: u8
                b: u8
                a: u8

            flags Mode: i32
                MODE_DEFAULT = 1

            const WHITE: Color = Color(r = 255, g = 255, b = 255, a = 255)

            extern def CloseWindow() -> void
            extern def SetWindowSize(frameWidth: i32, frameHeight: i32) -> void
            extern def InitWindow(width: i32, height: i32, title: cstr) -> void
            extern def LoadData(file_name: cstr, data_size: ptr[i32]) -> ptr[u8]
            extern def SaveData(file_name: cstr, data: ptr[void], data_size: i32) -> bool
            extern def ReleaseData(data: ptr[u8]) -> void
            extern def MemAlloc(size: u32) -> ptr[void]
            extern def TraceLog(level: i32, text: cstr, ...) -> void
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
                { name: "width", type: "i32" },
                { name: "height", type: "i32" },
                { name: "title", type: "str", boundary_type: "cstr" },
              ],
            },
            {
              raw: "LoadData",
              params: [
                { name: "file_name", type: "str", boundary_type: "cstr" },
                { name: "data_size", type: "i32", mode: "out" },
              ],
              return_type: "ptr[u8]?",
            },
            {
              raw: "SaveData",
              params: [
                { name: "file_name", type: "str", boundary_type: "cstr" },
                { name: "data", type: "span[u8]" },
              ],
              mapping: "c.SaveData(file_name, data.data, cast[i32](data.len))",
            },
            {
              raw: "ReleaseData",
              params: [
                { name: "data", type: "ptr[u8]", mode: "consuming" },
              ],
            },
            {
              raw: "MemAlloc",
              type_params: ["T"],
              params: [
                { name: "count", type: "usize" },
              ],
              return_type: "ptr[T]?",
              mapping: "c.MemAlloc(count * cast[u32](sizeof(T)))",
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
        pub foreign def set_window_size(frame_width: i32, frame_height: i32) -> void = c.SetWindowSize
        pub foreign def init_window(width: i32, height: i32, title: str as cstr) -> void = c.InitWindow
        pub foreign def load_data(file_name: str as cstr, out data_size: i32) -> ptr[u8]? = c.LoadData
        pub foreign def save_data(file_name: str as cstr, data: span[u8]) -> bool = c.SaveData(file_name, data.data, cast[i32](data.len))
        pub foreign def release_data(consuming data: ptr[u8]) -> void = c.ReleaseData
        pub foreign def mem_alloc[T](count: usize) -> ptr[T]? = c.MemAlloc(count * cast[u32](sizeof(T)))
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
              name: "text_format_i32",
              params: [
                { name: "format", type: "str", boundary_type: "cstr" },
                { name: "value", type: "i32" },
              ],
              return_type: "cstr",
              mapping: "c.TextFormat(format, value)",
            },
            {
              raw: "TextFormat",
              name: "text_format_i32_i32",
              params: [
                { name: "format", type: "str", boundary_type: "cstr" },
                { name: "first", type: "i32" },
                { name: "second", type: "i32" },
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

        pub foreign def text_format_i32(format: str as cstr, value: i32) -> cstr = c.TextFormat(format, value)
        pub foreign def text_format_i32_i32(format: str as cstr, first: i32, second: i32) -> cstr = c.TextFormat(format, first, second)
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
                r: u8
                g: u8
                b: u8
                a: u8

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
