## Projection of `RawBindings.default_bindings`
## (`lib/milk_tea/bindings/raw_bindings/defaults.rb`) used by
## `toolchain doctor` to report the raw-binding header checks.
##
## Only the fields the doctor reads are mirrored: the binding name,
## module, environment override, header label/candidates, and the
## vendored upstream source whose bootstrap provides the header.

public struct RawBinding:
    name: str
    module_name: str
    env_var: str
    header_label: str
    candidates: array[str, 2]
    candidate_count: ptr_uint
    candidates_from_root: bool
    ## Index into `toolchain_cli.source_at`, or -1 when no vendored
    ## source provides this header.
    prepare_source: int


public function binding_count() -> ptr_uint:
    return 34


public function binding_at(index: ptr_uint) -> RawBinding:
    if index == 0:
        return RawBinding(
            name = "raylib",
            module_name = "std.c.raylib",
            env_var = "",
            header_label = "raylib.h",
            candidates = array[str, 2]("third_party/raylib-upstream/src/raylib.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 0,
        )
    if index == 1:
        return RawBinding(
            name = "raymath",
            module_name = "std.c.raymath",
            env_var = "",
            header_label = "raylib.h",
            candidates = array[str, 2]("third_party/raylib-upstream/src/raymath.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 0,
        )
    if index == 2:
        return RawBinding(
            name = "raygui",
            module_name = "std.c.raygui",
            env_var = "",
            header_label = "raygui.h",
            candidates = array[str, 2]("third_party/raygui-upstream/src/raygui.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 13,
        )
    if index == 3:
        return RawBinding(
            name = "rlgl",
            module_name = "std.c.rlgl",
            env_var = "",
            header_label = "rlgl.h",
            candidates = array[str, 2]("third_party/raylib-upstream/src/rlgl.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 0,
        )
    if index == 4:
        return RawBinding(
            name = "libc",
            module_name = "std.c.libc",
            env_var = "LIBC_HEADER",
            header_label = "stdlib.h",
            candidates = array[str, 2]("/usr/include/stdlib.h", "/usr/local/include/stdlib.h"),
            candidate_count = 2,
            candidates_from_root = false,
            prepare_source = -1,
        )
    if index == 5:
        return RawBinding(
            name = "ctype",
            module_name = "std.c.ctype",
            env_var = "",
            header_label = "ctype_bindgen.h",
            candidates = array[str, 2]("std/c/ctype_bindgen.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = -1,
        )
    if index == 6:
        return RawBinding(
            name = "errno",
            module_name = "std.c.errno",
            env_var = "",
            header_label = "errno_bindgen.h",
            candidates = array[str, 2]("std/c/errno_bindgen.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = -1,
        )
    if index == 7:
        return RawBinding(
            name = "math",
            module_name = "std.c.math",
            env_var = "",
            header_label = "math_bindgen.h",
            candidates = array[str, 2]("std/c/math_bindgen.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = -1,
        )
    if index == 8:
        return RawBinding(
            name = "string",
            module_name = "std.c.string",
            env_var = "",
            header_label = "string_bindgen.h",
            candidates = array[str, 2]("std/c/string_bindgen.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = -1,
        )
    if index == 9:
        return RawBinding(
            name = "sdl3",
            module_name = "std.c.sdl3",
            env_var = "",
            header_label = "SDL3/SDL.h",
            candidates = array[str, 2]("third_party/sdl3-upstream/include/SDL3/SDL.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 1,
        )
    if index == 10:
        return RawBinding(
            name = "glfw",
            module_name = "std.c.glfw",
            env_var = "",
            header_label = "GLFW/glfw3.h",
            candidates = array[str, 2]("third_party/glfw-upstream/include/GLFW/glfw3.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 2,
        )
    if index == 11:
        return RawBinding(
            name = "gl",
            module_name = "std.c.gl",
            env_var = "",
            header_label = "gl_registry_helpers.h",
            candidates = array[str, 2]("std/c/gl_registry_helpers.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 3,
        )
    if index == 12:
        return RawBinding(
            name = "box2d",
            module_name = "std.c.box2d",
            env_var = "",
            header_label = "box2d/box2d.h",
            candidates = array[str, 2]("third_party/box2d-upstream/include/box2d/box2d.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 4,
        )
    if index == 13:
        return RawBinding(
            name = "box3d",
            module_name = "std.c.box3d",
            env_var = "",
            header_label = "box3d/box3d.h",
            candidates = array[str, 2]("third_party/box3d-upstream/include/box3d/box3d.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 5,
        )
    if index == 14:
        return RawBinding(
            name = "cjson",
            module_name = "std.c.cjson",
            env_var = "",
            header_label = "cJSON.h",
            candidates = array[str, 2]("third_party/cjson-upstream/cJSON.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 6,
        )
    if index == 15:
        return RawBinding(
            name = "flecs",
            module_name = "std.c.flecs",
            env_var = "",
            header_label = "flecs.h",
            candidates = array[str, 2]("third_party/flecs-upstream/distr/flecs.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 7,
        )
    if index == 16:
        return RawBinding(
            name = "libuv",
            module_name = "std.c.libuv",
            env_var = "",
            header_label = "uv.h",
            candidates = array[str, 2]("third_party/libuv-upstream/include/uv.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 8,
        )
    if index == 17:
        return RawBinding(
            name = "enet",
            module_name = "std.c.enet",
            env_var = "",
            header_label = "enet/enet.h",
            candidates = array[str, 2]("/usr/include/enet/enet.h", "/usr/local/include/enet/enet.h"),
            candidate_count = 2,
            candidates_from_root = false,
            prepare_source = -1,
        )
    if index == 18:
        return RawBinding(
            name = "zstd",
            module_name = "std.c.zstd",
            env_var = "",
            header_label = "zstd.h",
            candidates = array[str, 2]("/usr/include/zstd.h", "/usr/local/include/zstd.h"),
            candidate_count = 2,
            candidates_from_root = false,
            prepare_source = -1,
        )
    if index == 19:
        return RawBinding(
            name = "sqlite3",
            module_name = "std.c.sqlite3",
            env_var = "",
            header_label = "sqlite3.h",
            candidates = array[str, 2]("/usr/include/sqlite3.h", "/usr/local/include/sqlite3.h"),
            candidate_count = 2,
            candidates_from_root = false,
            prepare_source = -1,
        )
    if index == 20:
        return RawBinding(
            name = "curl",
            module_name = "std.c.curl",
            env_var = "",
            header_label = "curl/curl.h",
            candidates = array[str, 2]("/usr/include/curl/curl.h", "/usr/local/include/curl/curl.h"),
            candidate_count = 2,
            candidates_from_root = false,
            prepare_source = -1,
        )
    if index == 21:
        return RawBinding(
            name = "pcre2",
            module_name = "std.c.pcre2",
            env_var = "",
            header_label = "pcre2.h",
            candidates = array[str, 2]("tmp/vendored-pcre2-prefix/include/pcre2.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 9,
        )
    if index == 22:
        return RawBinding(
            name = "steamworks",
            module_name = "std.c.steamworks",
            env_var = "",
            header_label = "steamworks.h",
            candidates = array[str, 2]("std/c/steamworks.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 10,
        )
    if index == 23:
        return RawBinding(
            name = "miniaudio",
            module_name = "std.c.miniaudio",
            env_var = "",
            header_label = "miniaudio.h",
            candidates = array[str, 2]("third_party/miniaudio-upstream/miniaudio.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 11,
        )
    if index == 24:
        return RawBinding(
            name = "tracy",
            module_name = "std.c.tracy",
            env_var = "",
            header_label = "TracyC.h",
            candidates = array[str, 2]("third_party/tracy-upstream/public/tracy/TracyC.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 12,
        )
    if index == 25:
        return RawBinding(
            name = "rres",
            module_name = "std.c.rres",
            env_var = "",
            header_label = "rres.h",
            candidates = array[str, 2]("third_party/rres-upstream/src/rres.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 14,
        )
    if index == 26:
        return RawBinding(
            name = "rpng",
            module_name = "std.c.rpng",
            env_var = "",
            header_label = "rpng.h",
            candidates = array[str, 2]("third_party/rpng-upstream/src/rpng.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 15,
        )
    if index == 27:
        return RawBinding(
            name = "stb_image",
            module_name = "std.c.stb_image",
            env_var = "",
            header_label = "stb_image.h",
            candidates = array[str, 2]("third_party/stb-upstream/stb_image.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 16,
        )
    if index == 28:
        return RawBinding(
            name = "stb_truetype",
            module_name = "std.c.stb_truetype",
            env_var = "",
            header_label = "stb_truetype.h",
            candidates = array[str, 2]("third_party/stb-upstream/stb_truetype.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 16,
        )
    if index == 29:
        return RawBinding(
            name = "stb_image_write",
            module_name = "std.c.stb_image_write",
            env_var = "",
            header_label = "stb_image_write.h",
            candidates = array[str, 2]("third_party/stb-upstream/stb_image_write.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 16,
        )
    if index == 30:
        return RawBinding(
            name = "stb_image_resize2",
            module_name = "std.c.stb_image_resize2",
            env_var = "",
            header_label = "stb_image_resize2.h",
            candidates = array[str, 2]("third_party/stb-upstream/deprecated/stb_image_resize2.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 16,
        )
    if index == 31:
        return RawBinding(
            name = "stb_rect_pack",
            module_name = "std.c.stb_rect_pack",
            env_var = "",
            header_label = "stb_rect_pack.h",
            candidates = array[str, 2]("third_party/stb-upstream/stb_rect_pack.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 16,
        )
    if index == 32:
        return RawBinding(
            name = "stb_vorbis",
            module_name = "std.c.stb_vorbis",
            env_var = "",
            header_label = "stb_vorbis.c",
            candidates = array[str, 2]("third_party/stb-upstream/stb_vorbis.c", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 16,
        )
    if index == 33:
        return RawBinding(
            name = "cgltf",
            module_name = "std.c.cgltf",
            env_var = "",
            header_label = "cgltf.h",
            candidates = array[str, 2]("third_party/cgltf-upstream/cgltf.h", ""),
            candidate_count = 1,
            candidates_from_root = true,
            prepare_source = 17,
        )
    return RawBinding(
        name = "",
        module_name = "",
        env_var = "",
        header_label = "",
        candidates = array[str, 2]("", ""),
        candidate_count = 0,
        candidates_from_root = false,
        prepare_source = -1,
    )
