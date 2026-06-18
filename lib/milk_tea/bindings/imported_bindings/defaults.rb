# frozen_string_literal: true

module MilkTea
  module ImportedBindings
    def self.default_bindings(root: MilkTea.root)
      [
        Binding.new(
          name: "raymath",
          module_name: "std.raymath",
          binding_path: root.join("std/raymath.mt"),
          raw_module_name: "std.c.raymath",
          policy_path: root.join("bindings/imported/raymath.binding.json"),
        ),
        Binding.new(
          name: "raylib",
          module_name: "std.raylib",
          binding_path: root.join("std/raylib.mt"),
          raw_module_name: "std.c.raylib",
          policy_path: root.join("bindings/imported/raylib.binding.json"),
        ),
        Binding.new(
          name: "rlgl",
          module_name: "std.rlgl",
          binding_path: root.join("std/rlgl.mt"),
          raw_module_name: "std.c.rlgl",
          policy_path: root.join("bindings/imported/rlgl.binding.json"),
        ),
        Binding.new(
          name: "raygui",
          module_name: "std.raygui",
          binding_path: root.join("std/raygui.mt"),
          raw_module_name: "std.c.raygui",
          policy_path: root.join("bindings/imported/raygui.binding.json"),
        ),
        Binding.new(
          name: "sdl3",
          module_name: "std.sdl3",
          binding_path: root.join("std/sdl3.mt"),
          raw_module_name: "std.c.sdl3",
          policy_path: root.join("bindings/imported/sdl3.binding.json"),
        ),
        Binding.new(
          name: "gl",
          module_name: "std.gl",
          binding_path: root.join("std/gl.mt"),
          raw_module_name: "std.c.gl",
          policy_path: root.join("bindings/imported/gl.binding.json"),
        ),
        Binding.new(
          name: "glfw",
          module_name: "std.glfw",
          binding_path: root.join("std/glfw.mt"),
          raw_module_name: "std.c.glfw",
          policy_path: root.join("bindings/imported/glfw.binding.json"),
        ),
        Binding.new(
          name: "box2d",
          module_name: "std.box2d",
          binding_path: root.join("std/box2d.mt"),
          raw_module_name: "std.c.box2d",
          policy_path: root.join("bindings/imported/box2d.binding.json"),
        ),
        Binding.new(
          name: "cjson",
          module_name: "std.cjson",
          binding_path: root.join("std/cjson.mt"),
          raw_module_name: "std.c.cjson",
          policy_path: root.join("bindings/imported/cjson.binding.json"),
        ),
        Binding.new(
          name: "flecs",
          module_name: "std.flecs",
          binding_path: root.join("std/flecs.mt"),
          raw_module_name: "std.c.flecs",
          policy_path: root.join("bindings/imported/flecs.binding.json"),
        ),
        Binding.new(
          name: "libuv",
          module_name: "std.libuv",
          binding_path: root.join("std/libuv.mt"),
          raw_module_name: "std.c.libuv",
          policy_path: root.join("bindings/imported/libuv.binding.json"),
        ),
        Binding.new(
          name: "enet",
          module_name: "std.enet",
          binding_path: root.join("std/enet.mt"),
          raw_module_name: "std.c.enet",
          policy_path: root.join("bindings/imported/enet.binding.json"),
        ),
        Binding.new(
          name: "zstd",
          module_name: "std.zstd",
          binding_path: root.join("std/zstd.mt"),
          raw_module_name: "std.c.zstd",
          policy_path: root.join("bindings/imported/zstd.binding.json"),
        ),
        Binding.new(
          name: "sqlite3",
          module_name: "std.sqlite3",
          binding_path: root.join("std/sqlite3.mt"),
          raw_module_name: "std.c.sqlite3",
          policy_path: root.join("bindings/imported/sqlite3.binding.json"),
        ),
        Binding.new(
          name: "curl",
          module_name: "std.curl",
          binding_path: root.join("std/curl.mt"),
          raw_module_name: "std.c.curl",
          policy_path: root.join("bindings/imported/curl.binding.json"),
        ),
        Binding.new(
          name: "pcre2",
          module_name: "std.pcre2",
          binding_path: root.join("std/pcre2.mt"),
          raw_module_name: "std.c.pcre2",
          policy_path: root.join("bindings/imported/pcre2.binding.json"),
        ),
        Binding.new(
          name: "steamworks",
          module_name: "std.steamworks",
          binding_path: root.join("std/steamworks.mt"),
          raw_module_name: "std.c.steamworks",
          policy_path: root.join("bindings/imported/steamworks.binding.json"),
        ),
        Binding.new(
          name: "miniaudio",
          module_name: "std.miniaudio",
          binding_path: root.join("std/miniaudio.mt"),
          raw_module_name: "std.c.miniaudio",
          policy_path: root.join("bindings/imported/miniaudio.binding.json"),
        ),
        Binding.new(
          name: "tracy",
          module_name: "std.tracy",
          binding_path: root.join("std/tracy.mt"),
          raw_module_name: "std.c.tracy",
          policy_path: root.join("bindings/imported/tracy.binding.json"),
        ),
        Binding.new(
          name: "rres",
          module_name: "std.rres",
          binding_path: root.join("std/rres.mt"),
          raw_module_name: "std.c.rres",
          policy_path: root.join("bindings/imported/rres.binding.json"),
        ),
        Binding.new(
          name: "rpng",
          module_name: "std.rpng",
          binding_path: root.join("std/rpng.mt"),
          raw_module_name: "std.c.rpng",
          policy_path: root.join("bindings/imported/rpng.binding.json"),
        ),
      ]
    end

    def self.default_registry(root: MilkTea.root)
      Registry.new(default_bindings(root:))
    end
  end
end
