# frozen_string_literal: true

module MilkTea
  module RawBindings
    class Error < StandardError; end

    class Binding
      attr_reader :name, :module_name, :binding_path, :include_directives, :bindgen_defines, :bindgen_include_directives, :module_imports, :link_libraries, :header_candidates, :tracked_header_paths, :tracked_header_prefixes, :declaration_name_prefixes, :env_var, :clang_args, :compiler_flags, :implementation_defines, :type_overrides, :function_param_type_overrides, :function_return_type_overrides, :field_type_overrides, :vendored_library

      def initialize(name:, module_name:, binding_path:, header_candidates:, tracked_header_paths: [], tracked_header_prefixes: [], declaration_name_prefixes: [], include_directives: nil, bindgen_defines: [], bindgen_include_directives: [], module_imports: [], link_libraries: [], link_flags: [], env_var: nil, clang: nil, clang_args: [], compiler_flags: [], implementation_defines: [], type_overrides: {}, function_param_type_overrides: {}, function_return_type_overrides: {}, field_type_overrides: {}, vendored_library: nil, prepare: nil)
        @name = name.to_s
        @module_name = module_name
        @binding_path = File.expand_path(binding_path.to_s)
        @header_candidates = header_candidates.map { |path| File.expand_path(path) }.freeze
        @tracked_header_paths = tracked_header_paths.map { |path| File.expand_path(path) }.freeze
        @tracked_header_prefixes = tracked_header_prefixes.map { |path| File.expand_path(path) }.freeze
        @declaration_name_prefixes = declaration_name_prefixes.dup.freeze
        @include_directives = include_directives&.dup&.freeze
        @bindgen_defines = bindgen_defines.dup.freeze
        @bindgen_include_directives = bindgen_include_directives.dup.freeze
        @link_libraries = link_libraries.dup.freeze
        @link_flags = link_flags.dup.freeze
        @env_var = env_var
        @clang = clang
        @clang_args = clang_args.dup.freeze
        @compiler_flags = compiler_flags.dup.freeze
        @implementation_defines = implementation_defines.dup.freeze
        @module_imports = module_imports.dup.freeze
        @type_overrides = type_overrides.transform_keys(&:to_s).freeze
        @function_param_type_overrides = normalize_function_param_type_overrides(function_param_type_overrides)
        @function_return_type_overrides = function_return_type_overrides.transform_keys(&:to_s).freeze
        @field_type_overrides = normalize_field_type_overrides(field_type_overrides)
        @vendored_library = vendored_library
        @prepare = prepare
      end

      def task_name
        "bindgen:#{name}"
      end

      def check_task_name
        "bindgen:check:#{name}"
      end

      def legacy_check_task_name
        "bindgen:check_#{name}"
      end

      def header_label
        return include_directives.first if include_directives && !include_directives.empty?
        return File.basename(header_candidates.first) unless header_candidates.empty?

        name
      end

      def link_flags
        flags = []
        flags.concat(vendored_library.link_flags) if vendored_library
        flags.concat(@link_flags)
        flags.uniq
      end

      def header_path(env: ENV)
        candidates = []
        override = env_var && env[env_var]
        candidates << override unless override.nil? || override.empty?
        candidates.concat(header_candidates)

        resolved = candidates.find { |path| File.file?(path) }
        return resolved if resolved

        if env_var
          raise Error, "#{header_label} header not found; set #{env_var} or install #{header_label} headers"
        end

        raise Error, "#{header_label} header not found"
      end

      def generate(env: ENV, header_path: nil)
        resolved_header_path = header_path || self.header_path(env:)

        bindgen_kwargs = {
          module_name:,
          header_path: resolved_header_path,
          link_libraries:,
          include_directives:,
          bindgen_defines:,
          bindgen_include_directives:,
          module_imports:,
          clang: resolved_clang(env),
          clang_args:,
          type_overrides:,
          function_param_type_overrides:,
          function_return_type_overrides:,
          field_type_overrides:,
        }
        bindgen_kwargs[:tracked_header_paths] = tracked_header_paths unless tracked_header_paths.empty?
        bindgen_kwargs[:tracked_header_prefixes] = tracked_header_prefixes unless tracked_header_prefixes.empty?
        bindgen_kwargs[:declaration_name_prefixes] = declaration_name_prefixes unless declaration_name_prefixes.empty?

        MilkTea::Bindgen.generate(**bindgen_kwargs)
      end

      def build_flags(env: ENV, header_path: nil)
        resolved_header_path = header_path || self.header_path(env:)
        include_dir = File.dirname(resolved_header_path)
        flags = []
        flags << "-I#{include_dir}" unless include_dir.nil? || include_dir.empty?
        implementation_defines.each do |define|
          flags << "-D#{define}"
        end
        flags.concat(compiler_flags)
        flags.uniq
      end

      def write!(env: ENV)
        resolved_header_path = header_path(env:)
        File.write(binding_path, generate(env:, header_path: resolved_header_path))
        resolved_header_path
      end

      def check!(env: ENV)
        resolved_header_path = header_path(env:)
        expected = normalized_output(File.read(binding_path))
        actual = normalized_output(generate(env:, header_path: resolved_header_path))

        if expected != actual
          raise Error, <<~MESSAGE
            #{binding_path} is out of date for #{resolved_header_path}
            Run `rake #{task_name}` to regenerate it.
          MESSAGE
        end

        MilkTea::ModuleLoader.check_file(binding_path)
        resolved_header_path
      end

      def prepare!(env: ENV, cc: ENV.fetch("CC", "cc"))
        vendored_library&.prepare!(env:, cc:)
        @prepare&.call(self, env:, cc:)
      end

      private

      def normalize_function_param_type_overrides(overrides)
        overrides.each_with_object({}) do |(function_name, param_overrides), normalized|
          normalized[function_name.to_s] = param_overrides.each_with_object({}) do |(param_name, type), params|
            params[param_name.to_s] = type.to_s
          end.freeze
        end.freeze
      end

      def normalize_field_type_overrides(overrides)
        overrides.each_with_object({}) do |(type_name, field_overrides), normalized|
          normalized[type_name.to_s] = field_overrides.each_with_object({}) do |(field_name, type), fields|
            fields[field_name.to_s] = type.to_s
          end.freeze
        end.freeze
      end

      def resolved_clang(env)
        @clang || env.fetch("CLANG", "clang")
      end

      def normalized_output(source)
        source.sub(/\A# generated by mtc bindgen from .*\n/, "# generated by mtc bindgen from <header>\n")
      end
    end

    class Registry
      include Enumerable

      def initialize(bindings = [])
        @bindings = {}
        @bindings_by_module_name = {}
        bindings.each { |binding| register(binding) }
      end

      def register(binding)
        raise Error, "duplicate raw binding #{binding.name}" if @bindings.key?(binding.name)
        raise Error, "duplicate raw binding module #{binding.module_name}" if @bindings_by_module_name.key?(binding.module_name)

        @bindings[binding.name] = binding
        @bindings_by_module_name[binding.module_name] = binding
      end

      def fetch(name)
        @bindings.fetch(name.to_s)
      rescue KeyError
        raise Error, "unknown raw binding #{name}"
      end

      def each(&block)
        @bindings.each_value(&block)
      end

      def find_by_module_name(module_name)
        @bindings_by_module_name[module_name]
      end

      def task_names
        map(&:task_name)
      end

      def check_task_names
        map(&:check_task_name)
      end
    end

    def self.default_bindings(root: MilkTea.root)
      vendored_raylib = MilkTea::VendoredRaylib.library
      vendored_sdl3 = MilkTea::VendoredSDL3
      vendored_sdl3_library = vendored_sdl3.library
      vendored_box2d = MilkTea::VendoredBox2D
      vendored_cjson = MilkTea::VendoredCJSON

      raylib_field_type_overrides = {
        "Mesh" => { "indices" => "ptr[u16]?" },
      }.freeze

      raylib_function_param_overrides = {
        "LoadAutomationEventList" => { "fileName" => "cstr?" },
        "LoadFontEx" => { "codepoints" => "ptr[i32]?" },
        "LoadFontFromMemory" => { "codepoints" => "ptr[i32]?" },
        "LoadFontData" => { "codepoints" => "ptr[i32]?" },
        "LoadShader" => {
          "vsFileName" => "cstr?",
          "fsFileName" => "cstr?",
        },
        "LoadShaderFromMemory" => {
          "vsCode" => "cstr?",
          "fsCode" => "cstr?",
        },
      }.freeze

      sdl3_function_param_overrides = {
        "SDL_RunApp" => { "reserved" => "ptr[void]?" },
        "SDL_OpenAudioDevice" => { "spec" => "const_ptr[SDL_AudioSpec]?" },
        "SDL_CreateAudioStream" => { "dst_spec" => "const_ptr[SDL_AudioSpec]?" },
        "SDL_OpenAudioDeviceStream" => { "userdata" => "ptr[void]?" },
        "SDL_PutAudioStreamPlanarData" => { "channel_buffers" => "const_ptr[const_ptr[void]?]" },
        "SDL_StepUTF8" => { "pslen" => "ptr[usize]?" },
        "SDL_MapRGB" => { "palette" => "const_ptr[SDL_Palette]?" },
        "SDL_MapRGBA" => { "palette" => "const_ptr[SDL_Palette]?" },
        "SDL_FillSurfaceRect" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_UpdateTexture" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_LockTextureToSurface" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_SetRenderViewport" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_SetRenderClipRect" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_OpenCamera" => { "spec" => "const_ptr[SDL_CameraSpec]?" },
        "SDL_SetRenderTarget" => { "texture" => "ptr[SDL_Texture]?" },
        "SDL_RenderTexture" => {
          "srcrect" => "const_ptr[SDL_FRect]?",
          "dstrect" => "const_ptr[SDL_FRect]?",
        },
        "SDL_RenderTextureRotated" => { "srcrect" => "const_ptr[SDL_FRect]?" },
        "SDL_RenderTextureAffine" => { "srcrect" => "const_ptr[SDL_FRect]?" },
        "SDL_RenderGeometry" => {
          "texture" => "ptr[SDL_Texture]?",
          "indices" => "const_ptr[i32]?",
        },
        "SDL_RenderReadPixels" => { "rect" => "const_ptr[SDL_Rect]?" },
      }.freeze

      sdl3_function_return_overrides = {
        "SDL_LoadPNG" => "ptr[SDL_Surface]?",
        "SDL_ConvertSurface" => "ptr[SDL_Surface]?",
        "SDL_CreateTexture" => "ptr[SDL_Texture]?",
        "SDL_CreateTextureFromSurface" => "ptr[SDL_Texture]?",
        "SDL_CreateAudioStream" => "ptr[SDL_AudioStream]?",
        "SDL_strdup" => "ptr[char]?",
        "SDL_LoadFile" => "ptr[void]?",
        "SDL_strchr" => "ptr[char]?",
        "SDL_GetClipboardText" => "ptr[char]?",
        "SDL_GetPrimarySelectionText" => "ptr[char]?",
        "SDL_GetPreferredLocales" => "ptr[ptr[SDL_Locale]]?",
        "SDL_GetBasePath" => "cstr?",
        "SDL_OpenAudioDeviceStream" => "ptr[SDL_AudioStream]?",
        "SDL_GetCameras" => "ptr[SDL_CameraID]?",
        "SDL_OpenCamera" => "ptr[SDL_Camera]?",
        "SDL_AcquireCameraFrame" => "ptr[SDL_Surface]?",
        "SDL_OpenJoystick" => "ptr[SDL_Joystick]?",
        "SDL_GetJoystickFromID" => "ptr[SDL_Joystick]?",
        "SDL_OpenGamepad" => "ptr[SDL_Gamepad]?",
        "SDL_GetGamepadFromID" => "ptr[SDL_Gamepad]?",
        "SDL_GetGamepadMapping" => "ptr[char]?",
        "SDL_GetGamepadMappingForGUID" => "ptr[char]?",
        "SDL_GetGamepadMappingForID" => "ptr[char]?",
        "SDL_RenderReadPixels" => "ptr[SDL_Surface]?",
      }.freeze

      [
        Binding.new(
          name: "raylib",
          module_name: "std.c.raylib",
          binding_path: root.join("std/c/raylib.mt"),
          include_directives: ["raylib.h"],
          link_libraries: ["raylib"],
          vendored_library: vendored_raylib,
          compiler_flags: ["-DGRAPHICS_API_OPENGL_43"],
          header_candidates: [
            vendored_raylib.source_root.join("raylib.h").to_s,
          ],
          field_type_overrides: raylib_field_type_overrides,
          function_param_type_overrides: raylib_function_param_overrides,
        ),
        Binding.new(
          name: "raygui",
          module_name: "std.c.raygui",
          binding_path: root.join("std/c/raygui.mt"),
          include_directives: ["raygui.h"],
          link_libraries: ["raylib", "m"],
          vendored_library: vendored_raylib,
          compiler_flags: ["-DGRAPHICS_API_OPENGL_43"],
          implementation_defines: ["RAYGUI_IMPLEMENTATION"],
          header_candidates: [
            root.join("third_party/raylib-upstream/examples/shapes/raygui.h").to_s,
          ],
          function_param_type_overrides: raylib_function_param_overrides,
        ),
        Binding.new(
          name: "rlights",
          module_name: "std.c.rlights",
          binding_path: root.join("std/c/rlights.mt"),
          include_directives: ["raylib.h", "rlights.h"],
          module_imports: [{ module_name: "std.c.raylib", alias: "rl" }],
          link_libraries: ["raylib"],
          vendored_library: vendored_raylib,
          clang_args: ["-I#{root.join('third_party/raylib-upstream/src')}", "-include", "raylib.h"],
          compiler_flags: ["-I#{root.join('third_party/raylib-upstream/src')}", "-DGRAPHICS_API_OPENGL_43"],
          implementation_defines: ["RLIGHTS_IMPLEMENTATION"],
          type_overrides: {
            "Vector3" => "rl.Vector3",
            "Color" => "rl.Color",
            "Shader" => "rl.Shader",
          },
          header_candidates: [
            root.join("third_party/raylib-upstream/examples/shaders/rlights.h").to_s,
          ],
        ),
        Binding.new(
          name: "rlgl",
          module_name: "std.c.rlgl",
          binding_path: root.join("std/c/rlgl.mt"),
          include_directives: ["rlgl.h"],
          link_libraries: ["raylib"],
          vendored_library: vendored_raylib,
          compiler_flags: ["-DGRAPHICS_API_OPENGL_43"],
          function_param_type_overrides: {
            "rlLoadTexture" => { "data" => "const_ptr[void]?" },
            "rlLoadTextureCubemap" => { "data" => "const_ptr[void]?" },
            "rlLoadShaderBuffer" => { "data" => "const_ptr[void]?" },
          },
          header_candidates: [
            root.join("third_party/raylib-upstream/src/rlgl.h").to_s,
          ],
        ),
        Binding.new(
          name: "msf_gif",
          module_name: "std.c.msf_gif",
          binding_path: root.join("std/c/msf_gif.mt"),
          include_directives: ["msf_gif.h"],
          implementation_defines: ["MSF_GIF_IMPL"],
          header_candidates: [
            root.join("third_party/raylib-upstream/examples/core/msf_gif.h").to_s,
          ],
        ),
        Binding.new(
          name: "libc",
          module_name: "std.c.libc",
          binding_path: root.join("std/c/libc.mt"),
          include_directives: ["stdlib.h"],
          env_var: "LIBC_HEADER",
          function_param_type_overrides: {
            "strtod" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtof" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtol" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtoul" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtoq" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtouq" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtoll" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtoull" => { "__endptr" => "ptr[ptr[char]]?" },
            "realloc" => { "__ptr" => "ptr[void]?" },
            "reallocarray" => { "__ptr" => "ptr[void]?" },
            "free" => { "__ptr" => "ptr[void]?" },
          },
          function_return_type_overrides: {
            "malloc" => "ptr[void]?",
            "calloc" => "ptr[void]?",
            "realloc" => "ptr[void]?",
            "reallocarray" => "ptr[void]?",
            "aligned_alloc" => "ptr[void]?",
          },
          header_candidates: [
            "/usr/include/stdlib.h",
            "/usr/local/include/stdlib.h",
          ],
        ),
        Binding.new(
          name: "sdl3",
          module_name: "std.c.sdl3",
          binding_path: root.join("std/c/sdl3.mt"),
          include_directives: ["SDL3/SDL.h", "SDL3/SDL_main.h"],
          bindgen_defines: ["SDL_MAIN_HANDLED=1"],
          bindgen_include_directives: ["SDL3/SDL_main.h"],
          link_libraries: ["SDL3"],
          vendored_library: vendored_sdl3_library,
          clang_args: vendored_sdl3.include_flags,
          compiler_flags: ["-DSDL_MAIN_HANDLED=1", *vendored_sdl3.include_flags],
          tracked_header_paths: [
            vendored_sdl3.header_root.join("SDL.h").to_s,
            vendored_sdl3.header_root.join("SDL_main.h").to_s,
          ],
          tracked_header_prefixes: [
            vendored_sdl3.header_root.to_s,
          ],
          declaration_name_prefixes: ["SDL_", "Sint", "Uint"],
          function_param_type_overrides: sdl3_function_param_overrides,
          function_return_type_overrides: sdl3_function_return_overrides,
          header_candidates: [
            vendored_sdl3.header_root.join("SDL.h").to_s,
          ],
        ),
        Binding.new(
          name: "box2d",
          module_name: "std.c.box2d",
          binding_path: root.join("std/c/box2d.mt"),
          include_directives: ["box2d/box2d.h"],
          link_libraries: ["box2d"],
          vendored_library: vendored_box2d.library,
          clang_args: vendored_box2d.include_flags,
          compiler_flags: vendored_box2d.include_flags,
          tracked_header_paths: [
            vendored_box2d.header_root.join("box2d.h").to_s,
          ],
          tracked_header_prefixes: [
            vendored_box2d.header_root.to_s,
          ],
          declaration_name_prefixes: ["b2", "B2_"],
          header_candidates: [
            vendored_box2d.header_root.join("box2d.h").to_s,
          ],
        ),
        Binding.new(
          name: "cjson",
          module_name: "std.c.cjson",
          binding_path: root.join("std/c/cjson.mt"),
          include_directives: ["cJSON.h"],
          link_libraries: ["cjson"],
          vendored_library: vendored_cjson.library,
          declaration_name_prefixes: ["cJSON", "CJSON_"],
          function_return_type_overrides: {
            "cJSON_Parse" => "ptr[cJSON]?",
            "cJSON_ParseWithLength" => "ptr[cJSON]?",
            "cJSON_ParseWithOpts" => "ptr[cJSON]?",
            "cJSON_ParseWithLengthOpts" => "ptr[cJSON]?",
            "cJSON_Print" => "ptr[char]?",
            "cJSON_PrintUnformatted" => "ptr[char]?",
            "cJSON_PrintBuffered" => "ptr[char]?",
            "cJSON_GetErrorPtr" => "cstr?",
            "cJSON_GetStringValue" => "cstr?",
            "cJSON_GetArrayItem" => "ptr[cJSON]?",
            "cJSON_GetObjectItem" => "ptr[cJSON]?",
            "cJSON_GetObjectItemCaseSensitive" => "ptr[cJSON]?",
            "cJSON_DetachItemViaPointer" => "ptr[cJSON]?",
            "cJSON_DetachItemFromArray" => "ptr[cJSON]?",
            "cJSON_DetachItemFromObject" => "ptr[cJSON]?",
            "cJSON_DetachItemFromObjectCaseSensitive" => "ptr[cJSON]?",
            "cJSON_CreateNull" => "ptr[cJSON]?",
            "cJSON_CreateTrue" => "ptr[cJSON]?",
            "cJSON_CreateFalse" => "ptr[cJSON]?",
            "cJSON_CreateBool" => "ptr[cJSON]?",
            "cJSON_CreateNumber" => "ptr[cJSON]?",
            "cJSON_CreateString" => "ptr[cJSON]?",
            "cJSON_CreateRaw" => "ptr[cJSON]?",
            "cJSON_CreateArray" => "ptr[cJSON]?",
            "cJSON_CreateObject" => "ptr[cJSON]?",
            "cJSON_CreateStringReference" => "ptr[cJSON]?",
            "cJSON_CreateObjectReference" => "ptr[cJSON]?",
            "cJSON_CreateArrayReference" => "ptr[cJSON]?",
          },
          header_candidates: [
            vendored_cjson.source_root.join("cJSON.h").to_s,
          ],
        ),
        Binding.new(
          name: "libuv",
          module_name: "std.c.libuv",
          binding_path: root.join("std/c/libuv.mt"),
          include_directives: ["uv.h"],
          module_imports: [{ module_name: "std.c.libuv_system", alias: "sys" }],
          link_libraries: ["uv"],
          compiler_flags: ["-D_GNU_SOURCE"],
          env_var: "LIBUV_HEADER",
          declaration_name_prefixes: ["uv_", "UV_"],
          type_overrides: {
            "DIR" => "sys.DIR",
            "addrinfo" => "sys.addrinfo",
            "pthread_barrier_t" => "sys.pthread_barrier_t",
            "pthread_cond_t" => "sys.pthread_cond_t",
            "pthread_mutex_t" => "sys.pthread_mutex_t",
            "pthread_rwlock_t" => "sys.pthread_rwlock_t",
            "sem_t" => "sys.sem_t",
            "sockaddr" => "sys.sockaddr",
            "sockaddr_in" => "sys.sockaddr_in",
            "sockaddr_in6" => "sys.sockaddr_in6",
            "sockaddr_storage" => "sys.sockaddr_storage",
            "termios" => "sys.termios",
            "uv__io_t" => "uv__io_s",
            "uv__work" => "sys.uv__work",
          },
          header_candidates: [
            "/usr/include/uv.h",
            "/usr/local/include/uv.h",
          ],
        ),
        Binding.new(
          name: "libuv_runtime",
          module_name: "std.c.libuv_runtime",
          binding_path: root.join("std/c/libuv_runtime.mt"),
          include_directives: ["libuv_runtime_helpers.h"],
          bindgen_include_directives: ["uv.h"],
          module_imports: [{ module_name: "std.c.libuv_system", alias: "sys" }],
          link_libraries: ["uv"],
          compiler_flags: ["-D_GNU_SOURCE"],
          implementation_defines: ["MT_LIBUV_RUNTIME_HELPERS_IMPLEMENTATION"],
          declaration_name_prefixes: ["mt_libuv_"],
          type_overrides: {
            "sockaddr_in" => "sys.sockaddr_in",
          },
          header_candidates: [
            root.join("std/c/libuv_runtime_helpers.h").to_s,
          ],
        ),
      ]
    end

    def self.default_registry(root: MilkTea.root)
      Registry.new(default_bindings(root:))
    end
  end
end
