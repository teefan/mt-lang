extern module std.c.rlights:
    import std.c.raylib as rl

    link "raylib"
    include "rlights.h"

    const MAX_LIGHTS: i32 = 4

    enum LightType: i32
        LIGHT_DIRECTIONAL = 0
        LIGHT_POINT = 1

    struct Light:
        type: i32
        enabled: bool
        position: rl.Vector3
        target: rl.Vector3
        color: rl.Color
        attenuation: f32
        enabledLoc: i32
        typeLoc: i32
        positionLoc: i32
        targetLoc: i32
        colorLoc: i32
        attenuationLoc: i32

    extern def CreateLight(type: i32, position: rl.Vector3, target: rl.Vector3, color: rl.Color, shader: rl.Shader) -> Light
    extern def UpdateLightValues(shader: rl.Shader, light: Light) -> void
