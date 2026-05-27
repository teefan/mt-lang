external

link "raylib"
include "raylib.h"
include "rlgl.h"

external function rlLoadExtensions(loader: fn(proc_name: cstr) -> ptr[void]) -> void
