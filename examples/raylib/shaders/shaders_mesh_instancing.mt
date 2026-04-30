module examples.raylib.shaders.shaders_mesh_instancing

import std.c.raylib as rl
import std.c.rlights as lights
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const max_instances: i32 = 10000
const shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/lighting_instancing.vs"
const shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/lighting.fs"
const view_pos_uniform_name: cstr = c"viewPos"
const mvp_uniform_name: cstr = c"mvp"
const ambient_uniform_name: cstr = c"ambient"
const window_title: cstr = c"raylib [shaders] example - mesh instancing"

def alloc_transforms(count: i32) -> ptr[rl.Matrix]:
    unsafe:
        return ptr[rl.Matrix]<-rl.MemAlloc(u32<-count * u32<-sizeof(rl.Matrix))

def free_transforms(transforms: ptr[rl.Matrix]) -> void:
    unsafe:
        rl.MemFree(ptr[void]<-transforms)

def set_transform(transforms: ptr[rl.Matrix], index: i32, transform: rl.Matrix) -> void:
    unsafe:
        read(transforms + usize<-index) = transform

def set_material_color(material: ptr[rl.Material], map_index: i32, color: rl.Color) -> void:
    unsafe:
        material.maps[map_index].color = color

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = -125.0, y = 125.0, z = -125.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let cube = rl.GenMeshCube(1.0, 1.0, 1.0)
    let transforms = alloc_transforms(max_instances)
    defer free_transforms(transforms)

    for index in range(0, max_instances):
        let translation = rm.Matrix.translate(
            f32<-rl.GetRandomValue(-50, 50),
            f32<-rl.GetRandomValue(-50, 50),
            f32<-rl.GetRandomValue(-50, 50),
        )
        let axis = rl.Vector3(
            x = f32<-rl.GetRandomValue(0, 360),
            y = f32<-rl.GetRandomValue(0, 360),
            z = f32<-rl.GetRandomValue(0, 360),
        ).normalize()
        let angle = f32<-rl.GetRandomValue(0, 180) * rm.deg2rad
        let rotation = rm.Quaternion.from_axis_angle(axis, angle).to_matrix()
        set_transform(transforms, index, rotation.multiply(translation))

    var shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(shader)

    let mvp_loc = rl.GetShaderLocation(shader, mvp_uniform_name)
    let view_loc = rl.GetShaderLocation(shader, view_pos_uniform_name)
    unsafe:
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_MATRIX_MVP] = mvp_loc
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = view_loc

    let ambient_loc = rl.GetShaderLocation(shader, ambient_uniform_name)
    var ambient = array[f32, 4](0.2, 0.2, 0.2, 1.0)
    rl.SetShaderValue(shader, ambient_loc, ptr_of(ref_of(ambient[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    lights.CreateLight(i32<-lights.LightType.LIGHT_DIRECTIONAL, rl.Vector3(x = 50.0, y = 50.0, z = 0.0), rm.Vector3.zero(), rl.WHITE, shader)

    var mat_instances = rl.LoadMaterialDefault()
    mat_instances.shader = shader
    set_material_color(ptr_of(ref_of(mat_instances)), i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, rl.RED)

    var mat_default = rl.LoadMaterialDefault()
    set_material_color(ptr_of(ref_of(mat_default)), i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, rl.BLUE)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.SetShaderValue(shader, view_loc, ptr_of(ref_of(camera_pos[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawMesh(cube, mat_default, rm.Matrix.translate(-10.0, 0.0, 0.0))
        rl.DrawMeshInstanced(cube, mat_instances, transforms, max_instances)
        rl.DrawMesh(cube, mat_default, rm.Matrix.translate(10.0, 0.0, 0.0))
        rl.EndMode3D()

        rl.DrawFPS(10, 10)

    return 0
