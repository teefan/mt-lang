## Imported bindings registry — maps library names to policy, raw module,
## and output paths.  Mirrors the Ruby defaults.rb binding list.

import std.string as string

public struct BindingEntry:
    name: str
    module_name: str
    binding_path: str
    raw_module_name: str
    policy_path: str


public const ALL: array[BindingEntry, 28] = array[BindingEntry, 28](
    BindingEntry(
        name = "raymath", module_name = "std.raymath",
        binding_path = "std/raymath.mt", raw_module_name = "std.c.raymath",
        policy_path = "bindings/imported/raymath.binding.json"),
    BindingEntry(
        name = "raylib", module_name = "std.raylib",
        binding_path = "std/raylib.mt", raw_module_name = "std.c.raylib",
        policy_path = "bindings/imported/raylib.binding.json"),
    BindingEntry(
        name = "rlgl", module_name = "std.rlgl",
        binding_path = "std/rlgl.mt", raw_module_name = "std.c.rlgl",
        policy_path = "bindings/imported/rlgl.binding.json"),
    BindingEntry(
        name = "raygui", module_name = "std.raygui",
        binding_path = "std/raygui.mt", raw_module_name = "std.c.raygui",
        policy_path = "bindings/imported/raygui.binding.json"),
    BindingEntry(
        name = "sdl3", module_name = "std.sdl3",
        binding_path = "std/sdl3.mt", raw_module_name = "std.c.sdl3",
        policy_path = "bindings/imported/sdl3.binding.json"),
    BindingEntry(
        name = "gl", module_name = "std.gl",
        binding_path = "std/gl.mt", raw_module_name = "std.c.gl",
        policy_path = "bindings/imported/gl.binding.json"),
    BindingEntry(
        name = "glfw", module_name = "std.glfw",
        binding_path = "std/glfw.mt", raw_module_name = "std.c.glfw",
        policy_path = "bindings/imported/glfw.binding.json"),
    BindingEntry(
        name = "box2d", module_name = "std.box2d",
        binding_path = "std/box2d.mt", raw_module_name = "std.c.box2d",
        policy_path = "bindings/imported/box2d.binding.json"),
    BindingEntry(
        name = "cjson", module_name = "std.cjson",
        binding_path = "std/cjson.mt", raw_module_name = "std.c.cjson",
        policy_path = "bindings/imported/cjson.binding.json"),
    BindingEntry(
        name = "flecs", module_name = "std.flecs",
        binding_path = "std/flecs.mt", raw_module_name = "std.c.flecs",
        policy_path = "bindings/imported/flecs.binding.json"),
    BindingEntry(
        name = "libuv", module_name = "std.libuv",
        binding_path = "std/libuv.mt", raw_module_name = "std.c.libuv",
        policy_path = "bindings/imported/libuv.binding.json"),
    BindingEntry(
        name = "enet", module_name = "std.enet",
        binding_path = "std/enet.mt", raw_module_name = "std.c.enet",
        policy_path = "bindings/imported/enet.binding.json"),
    BindingEntry(
        name = "zstd", module_name = "std.zstd",
        binding_path = "std/zstd.mt", raw_module_name = "std.c.zstd",
        policy_path = "bindings/imported/zstd.binding.json"),
    BindingEntry(
        name = "sqlite3", module_name = "std.sqlite3",
        binding_path = "std/sqlite3.mt", raw_module_name = "std.c.sqlite3",
        policy_path = "bindings/imported/sqlite3.binding.json"),
    BindingEntry(
        name = "curl", module_name = "std.curl",
        binding_path = "std/curl.mt", raw_module_name = "std.c.curl",
        policy_path = "bindings/imported/curl.binding.json"),
    BindingEntry(
        name = "pcre2", module_name = "std.pcre2",
        binding_path = "std/pcre2.mt", raw_module_name = "std.c.pcre2",
        policy_path = "bindings/imported/pcre2.binding.json"),
    BindingEntry(
        name = "steamworks", module_name = "std.steamworks",
        binding_path = "std/steamworks.mt", raw_module_name = "std.c.steamworks",
        policy_path = "bindings/imported/steamworks.binding.json"),
    BindingEntry(
        name = "miniaudio", module_name = "std.miniaudio",
        binding_path = "std/miniaudio.mt", raw_module_name = "std.c.miniaudio",
        policy_path = "bindings/imported/miniaudio.binding.json"),
    BindingEntry(
        name = "tracy", module_name = "std.tracy",
        binding_path = "std/tracy.mt", raw_module_name = "std.c.tracy",
        policy_path = "bindings/imported/tracy.binding.json"),
    BindingEntry(
        name = "rres", module_name = "std.rres",
        binding_path = "std/rres.mt", raw_module_name = "std.c.rres",
        policy_path = "bindings/imported/rres.binding.json"),
    BindingEntry(
        name = "rpng", module_name = "std.rpng",
        binding_path = "std/rpng.mt", raw_module_name = "std.c.rpng",
        policy_path = "bindings/imported/rpng.binding.json"),
    BindingEntry(
        name = "stb_image", module_name = "std.stb_image",
        binding_path = "std/stb_image.mt", raw_module_name = "std.c.stb_image",
        policy_path = "bindings/imported/stb_image.binding.json"),
    BindingEntry(
        name = "stb_truetype", module_name = "std.stb_truetype",
        binding_path = "std/stb_truetype.mt", raw_module_name = "std.c.stb_truetype",
        policy_path = "bindings/imported/stb_truetype.binding.json"),
    BindingEntry(
        name = "stb_image_write", module_name = "std.stb_image_write",
        binding_path = "std/stb_image_write.mt", raw_module_name = "std.c.stb_image_write",
        policy_path = "bindings/imported/stb_image_write.binding.json"),
    BindingEntry(
        name = "stb_image_resize2", module_name = "std.stb_image_resize2",
        binding_path = "std/stb_image_resize2.mt", raw_module_name = "std.c.stb_image_resize2",
        policy_path = "bindings/imported/stb_image_resize2.binding.json"),
    BindingEntry(
        name = "stb_rect_pack", module_name = "std.stb_rect_pack",
        binding_path = "std/stb_rect_pack.mt", raw_module_name = "std.c.stb_rect_pack",
        policy_path = "bindings/imported/stb_rect_pack.binding.json"),
    BindingEntry(
        name = "stb_vorbis", module_name = "std.stb_vorbis",
        binding_path = "std/stb_vorbis.mt", raw_module_name = "std.c.stb_vorbis",
        policy_path = "bindings/imported/stb_vorbis.binding.json"),
    BindingEntry(
        name = "cgltf", module_name = "std.cgltf",
        binding_path = "std/cgltf.mt", raw_module_name = "std.c.cgltf",
        policy_path = "bindings/imported/cgltf.binding.json"),
)
