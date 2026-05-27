# Raylib Examples

This folder holds Milk Tea ports of upstream raylib examples using `std.raylib`.

Current status:

- `audio/` is complete.
- `core/` is complete.
- `shapes/` is complete.
- `text/` is complete.
- `textures/` is complete.
- `models/` is complete.
- `shaders/` is in progress with 10 examples ported: `ascii_rendering`, `color_correction`, `custom_uniform`, `model_shader`, `palette_switch`, `shapes_textures`, `simple_mask`, `texture_rendering`, `texture_tiling`, and `texture_waves`.
- `others/` is still blocked by missing GLFW/OpenGL-facing standard bindings and by the embedded-header asset example.

Shared helpers used by multiple ports:

- `std.raylib.easing` holds the easing helpers used by the raylib easing examples.
- `examples.raylib.text.boxed_text` provides the boxed text wrapping helper shared by `text/rectangle_bounds.mt` and `text/unicode_emojis.mt`.

Assets used by resource-backed ports live under `resources/`.

Because grouped examples build beside their source file, resource-backed ports such as `textures/logo_raylib.mt`, `core/input_gamepad.mt`, and `core/text_file_loading.mt` enter `../resources/` relative to the executable directory by using `std.raylib.runtime.enter_asset_directory("../resources")`.

Porting notes:

- `core/custom_logging.mt` formats app-side logs because `std.raylib` intentionally excludes `va_list` callback surfaces such as `SetTraceLogCallback`. The raw callback API remains available in `std.c.raylib`.
- `core/screen_recording.mt` records PNG frames instead of building GIFs because the upstream GIF helper library is not part of the current bindings.

Example filenames follow the upstream example stem with the group prefix removed, so `core_delta_time.c` becomes `core/delta_time.mt`.
