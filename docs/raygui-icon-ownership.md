# Raygui Icon Ownership

`GuiGetIcons()` and `GuiLoadIcons()` do not have the same ownership model, so they should not share one public abstraction.

`GuiGetIcons()` returns the current internal global icon data pointer. In raygui 4.x that buffer has a fixed layout: `RAYGUI_ICON_MAX_ICONS * (RAYGUI_ICON_SIZE * RAYGUI_ICON_SIZE / 32)` = `256 * 8` = `2048` `u32` entries. That makes it an honest borrowed view, so the curated surface can expose it as `span[u32]` with fixed length `2048`.

`GuiLoadIcons(fileName, loadIconsName)` has two effects:

1. It mutates the same internal global icon data used by `GuiGetIcons()`.
2. When `loadIconsName` is true, it heap-allocates a `char **` plus one heap allocation per icon name, and upstream explicitly says that memory must be manually freed.

That means the remaining gap is not raw pointer syntax. It is ownership expression.

The current language/runtime can already model the borrowed `GuiGetIcons()` buffer, but `GuiLoadIcons()` still needs one of these deeper features before it can move onto the honest curated surface:

1. A way for `foreign def` mappings to discard a raw return value while still exposing a public `void` or side-effect-only API.
2. A declarative consuming foreign collection model that can describe deep release of both the outer `char **` container and each inner `char *` name.

Until one of those exists, `GuiLoadIcons()` should remain excluded from `std.raygui`.
