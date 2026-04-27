# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "test_helper"

class MilkTeaImportedBindingsTest < Minitest::Test
  def test_default_registry_exposes_checked_in_imported_bindings
    registry = MilkTea::ImportedBindings.default_registry

    assert_equal ["raylib", "rlgl", "raygui"], registry.map(&:name)
    assert_equal "std.raylib", registry.fetch("raylib").module_name
    assert_equal "std.c.raylib", registry.fetch("raylib").raw_module_name
    assert_includes registry.fetch("raylib").binding_path, "/std/raylib.mt"
    assert_includes registry.fetch("raylib").policy_path, "/std/raylib.binding.json"

    assert_equal "std.rlgl", registry.fetch("rlgl").module_name
    assert_equal "std.c.rlgl", registry.fetch("rlgl").raw_module_name
    assert_includes registry.fetch("rlgl").binding_path, "/std/rlgl.mt"
    assert_includes registry.fetch("rlgl").policy_path, "/std/rlgl.binding.json"

    assert_equal "std.raygui", registry.fetch("raygui").module_name
    assert_equal "std.c.raygui", registry.fetch("raygui").raw_module_name
    assert_includes registry.fetch("raygui").binding_path, "/std/raygui.mt"
    assert_includes registry.fetch("raygui").policy_path, "/std/raygui.binding.json"
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
    assert_match(/^pub foreign def set_shader_value\[T\]\(shader: Shader, loc_index: i32, value: ptr\[T\] as ptr\[void\], uniform_type: i32\) -> void = c\.SetShaderValue$/, source)
    assert_match(/^pub foreign def set_shader_value_v\[T\]\(shader: Shader, loc_index: i32, value: ptr\[T\] as ptr\[void\], uniform_type: i32, count: i32\) -> void = c\.SetShaderValueV$/, source)
    assert_match(/^pub foreign def update_texture\[T\]\(texture: Texture, pixels: ptr\[T\] as ptr\[void\]\) -> void = c\.UpdateTexture$/, source)
    assert_match(/^pub foreign def update_mesh_buffer\[T\]\(mesh: Mesh, index: i32, data: ptr\[T\] as ptr\[void\], data_size: i32, offset: i32\) -> void = c\.UpdateMeshBuffer$/, source)
    assert_match(/^pub foreign def update_audio_stream\[T\]\(stream: AudioStream, data: ptr\[T\] as ptr\[void\], frame_count: i32\) -> void = c\.UpdateAudioStream$/, source)
    assert_match(/^pub foreign def load_font_ex\(file_name: cstr, font_size: i32, codepoints: ptr\[i32\]\?, codepoint_count: i32\) -> Font = c\.LoadFontEx$/, source)
    assert_match(/^pub foreign def load_font_from_memory\(file_type: cstr, file_data: ptr\[u8\], data_size: i32, font_size: i32, codepoints: ptr\[i32\]\?, codepoint_count: i32\) -> Font = c\.LoadFontFromMemory$/, source)
    assert_match(/^pub foreign def load_font_data\(file_data: ptr\[u8\], data_size: i32, font_size: i32, codepoints: ptr\[i32\]\?, codepoint_count: i32, type: i32, glyph_count: ptr\[i32\]\) -> ptr\[GlyphInfo\] = c\.LoadFontData$/, source)
  end

  def test_checked_in_rlgl_binding_matches_policy_and_loads
    binding = MilkTea::ImportedBindings.default_registry.fetch("rlgl")

    assert_includes binding.check!, "/std/c/rlgl.mt"

    source = File.read(binding.binding_path)
    assert_match(/^import std\.raylib as raylib$/, source)
    assert_match(/^pub type Matrix = raylib\.Matrix$/, source)
    assert_match(/^pub foreign def matrix_mode\(mode: i32\) -> void = c\.rlMatrixMode$/, source)
    assert_match(/^pub foreign def load_vertex_buffer\[T\]\(buffer: ptr\[T\] as ptr\[void\], size: i32, dynamic: bool\) -> u32 = c\.rlLoadVertexBuffer$/, source)
    assert_match(/^pub foreign def set_uniform\[T\]\(loc_index: i32, value: ptr\[T\] as ptr\[void\], uniform_type: i32, count: i32\) -> void = c\.rlSetUniform$/, source)
    assert_match(/^pub foreign def load_shader_buffer\[T\]\(size: u32, data: ptr\[T\] as ptr\[void\], usage_hint: i32\) -> u32 = c\.rlLoadShaderBuffer$/, source)
    assert_match(/^pub foreign def update_shader_buffer\[T\]\(id: u32, data: ptr\[T\] as ptr\[void\], data_size: u32, offset: u32\) -> void = c\.rlUpdateShaderBuffer$/, source)
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

  def test_generate_supports_imports_type_alias_overrides_and_prefix_stripping
    Dir.mktmpdir("milk-tea-imported-binding-overrides") do |dir|
      raw_path = File.join(dir, "std", "c", "sample.mt")
      shared_path = File.join(dir, "std", "shared.mt")
      binding_path = File.join(dir, "std", "sample.mt")
      policy_path = File.join(dir, "std", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))

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
      policy_path = File.join(dir, "std", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))

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
      policy_path = File.join(dir, "std", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))

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
      policy_path = File.join(dir, "std", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))

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
      policy_path = File.join(dir, "std", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))

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
      policy_path = File.join(dir, "std", "sample.binding.json")
      FileUtils.mkdir_p(File.dirname(raw_path))

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
