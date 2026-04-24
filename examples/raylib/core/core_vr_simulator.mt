module examples.raylib.core.core_vr_simulator

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - vr simulator"
const distortion_shader_path: cstr = c"../../../third_party/raylib-upstream/examples/core/resources/shaders/glsl330/distortion.fs"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var device = rl.VrDeviceInfo(
        hResolution = 2160,
        vResolution = 1200,
        hScreenSize = 0.133793,
        vScreenSize = 0.0669,
        eyeToScreenDistance = 0.041,
        lensSeparationDistance = 0.07,
        interpupillaryDistance = 0.07,
        lensDistortionValues = array[f32, 4](1.0, 0.22, 0.24, 0.0),
        chromaAbCorrection = array[f32, 4](0.996, -0.004, 1.014, 0.0),
    )
    var config = rl.LoadVrStereoConfig(device)
    defer rl.UnloadVrStereoConfig(config)

    var distortion = zero[rl.Shader]()
    unsafe:
        distortion = rl.LoadShader(cast[cstr](null[ptr[char]]), distortion_shader_path)
    defer rl.UnloadShader(distortion)

    unsafe:
        rl.SetShaderValue(distortion, rl.GetShaderLocation(distortion, c"leftLensCenter"), cast[ptr[void]](raw(addr(config.leftLensCenter[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.SetShaderValue(distortion, rl.GetShaderLocation(distortion, c"rightLensCenter"), cast[ptr[void]](raw(addr(config.rightLensCenter[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.SetShaderValue(distortion, rl.GetShaderLocation(distortion, c"leftScreenCenter"), cast[ptr[void]](raw(addr(config.leftScreenCenter[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.SetShaderValue(distortion, rl.GetShaderLocation(distortion, c"rightScreenCenter"), cast[ptr[void]](raw(addr(config.rightScreenCenter[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.SetShaderValue(distortion, rl.GetShaderLocation(distortion, c"scale"), cast[ptr[void]](raw(addr(config.scale[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.SetShaderValue(distortion, rl.GetShaderLocation(distortion, c"scaleIn"), cast[ptr[void]](raw(addr(config.scaleIn[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.SetShaderValue(distortion, rl.GetShaderLocation(distortion, c"deviceWarpParam"), cast[ptr[void]](raw(addr(device.lensDistortionValues[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
        rl.SetShaderValue(distortion, rl.GetShaderLocation(distortion, c"chromaAbParam"), cast[ptr[void]](raw(addr(device.chromaAbCorrection[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    let target = rl.LoadRenderTexture(device.hResolution, device.vResolution)
    defer rl.UnloadRenderTexture(target)

    let source_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = target.texture.width,
        height = -target.texture.height,
    )
    let dest_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = rl.GetScreenWidth(),
        height = rl.GetScreenHeight(),
    )
    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 2.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    let cube_position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_FIRST_PERSON)

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginVrStereoMode(config)
        rl.BeginMode3D(camera)
        rl.DrawCube(cube_position, 2.0, 2.0, 2.0, rl.RED)
        rl.DrawCubeWires(cube_position, 2.0, 2.0, 2.0, rl.MAROON)
        rl.DrawGrid(40, 1.0)
        rl.EndMode3D()
        rl.EndVrStereoMode()
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginShaderMode(distortion)
        rl.DrawTexturePro(target.texture, source_rec, dest_rec, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.EndShaderMode()
        rl.DrawFPS(10, 10)

    return 0
