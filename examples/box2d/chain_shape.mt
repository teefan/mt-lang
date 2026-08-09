## Box2D sample port: "Chain Shape" (from box2d-upstream/samples/sample_shapes.cpp).
##
## A looped chain of segments with a custom surface material. A dynamic body
## whose shape can be a circle, capsule, or box is launched down the chain.
## Ported controls (upstream used ImGui):
##   1 / 2 / 3     choose circle / capsule / box and relaunch
##   Space         relaunch the body
##   [ / ]         decrease / increase friction
##   - / =         decrease / increase restitution
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const CHAIN_COUNT: int = 20

const CHAIN_POINTS: array[b2.Vec2, CHAIN_COUNT] = array[b2.Vec2, CHAIN_COUNT](
    b2.Vec2(x = -56.885498, y = 12.8985004),
    b2.Vec2(x = -56.885498, y = 16.2057495),
    b2.Vec2(x = 56.885498, y = 16.2057495),
    b2.Vec2(x = 56.885498, y = -16.2057514),
    b2.Vec2(x = 51.5935059, y = -16.2057514),
    b2.Vec2(x = 43.6559982, y = -10.9139996),
    b2.Vec2(x = 35.7184982, y = -10.9139996),
    b2.Vec2(x = 27.7809982, y = -10.9139996),
    b2.Vec2(x = 21.1664963, y = -14.2212505),
    b2.Vec2(x = 11.9059982, y = -16.2057514),
    b2.Vec2(x = 0.0, y = -16.2057514),
    b2.Vec2(x = -10.5835037, y = -14.8827496),
    b2.Vec2(x = -17.1980019, y = -13.5597477),
    b2.Vec2(x = -21.1665001, y = -12.2370014),
    b2.Vec2(x = -25.1355019, y = -9.5909977),
    b2.Vec2(x = -31.75, y = -3.63799858),
    b2.Vec2(x = -38.3644981, y = 6.2840004),
    b2.Vec2(x = -42.3334999, y = 9.59125137),
    b2.Vec2(x = -47.625, y = 11.5755005),
    b2.Vec2(x = -56.885498, y = 12.8985004)
)

enum ShapeKind:
    circle
    capsule
    box

struct ChainShape implements common.Sample:
    world: b2.WorldId
    ground_id: b2.BodyId
    body_id: b2.BodyId
    chain_id: b2.ChainId
    shape_id: b2.ShapeId
    shape_kind: ShapeKind
    restitution: float
    friction: float

function chain_shape_create(world_id: b2.WorldId) -> ChainShape:
    var sample = ChainShape(
        world = world_id,
        ground_id = b2.b2_nullBodyId,
        body_id = b2.b2_nullBodyId,
        chain_id = b2.b2_nullChainId,
        shape_id = b2.b2_nullShapeId,
        shape_kind = ShapeKind.circle,
        restitution = 0.0,
        friction = 0.2
    )
    sample.create_scene()
    sample.launch()
    return sample

extending ChainShape:
    editable function create_scene() -> void:
        if this.ground_id != b2.b2_nullBodyId:
            b2.destroy_body(this.ground_id)

        var material = b2.default_surface_material()
        material.friction = 0.2
        material.customColor = uint<-b2.HexColor.b2_colorSteelBlue
        material.userMaterialId = 42

        var chain_def = b2.default_chain_def()
        chain_def.points = const_ptr_of(CHAIN_POINTS[0])
        chain_def.count = CHAIN_COUNT
        chain_def.materials = const_ptr_of(material)
        chain_def.materialCount = 1
        chain_def.isLoop = true

        let body_def = b2.default_body_def()
        this.ground_id = b2.create_body(this.world, body_def)
        this.chain_id = b2.create_chain(this.ground_id, chain_def)

    editable function launch() -> void:
        if this.body_id != b2.b2_nullBodyId:
            b2.destroy_body(this.body_id)

        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.position = b2.Vec2(x = -55.0, y = 13.5)
        this.body_id = b2.create_body(this.world, body_def)

        var shape_def = b2.default_shape_def()
        shape_def.density = 1.0
        shape_def.material.friction = this.friction
        shape_def.material.restitution = this.restitution

        match this.shape_kind:
            ShapeKind.circle:
                let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.5)
                this.shape_id = b2.create_circle_shape(this.body_id, shape_def, circle)
            ShapeKind.capsule:
                let capsule = b2.Capsule(
                    center1 = b2.Vec2(x = -0.5, y = 0.0),
                    center2 = b2.Vec2(x = 0.5, y = 0.0),
                    radius = 0.25
                )
                this.shape_id = b2.create_capsule_shape(this.body_id, shape_def, capsule)
            ShapeKind.box:
                let box = b2.make_box(0.5, 0.5)
                this.shape_id = b2.create_polygon_shape(this.body_id, shape_def, box)

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            this.shape_kind = ShapeKind.circle
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            this.shape_kind = ShapeKind.capsule
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            this.shape_kind = ShapeKind.box
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT_BRACKET):
            this.friction = common.max_float(this.friction - 0.1, 0.0)
            b2.shape_set_friction(this.shape_id, this.friction)
            b2.chain_set_friction(this.chain_id, this.friction)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT_BRACKET):
            this.friction = common.min_float(this.friction + 0.1, 1.0)
            b2.shape_set_friction(this.shape_id, this.friction)
            b2.chain_set_friction(this.chain_id, this.friction)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.restitution = common.max_float(this.restitution - 0.1, 0.0)
            b2.shape_set_restitution(this.shape_id, this.restitution)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.restitution = common.min_float(this.restitution + 0.1, 2.0)
            b2.shape_set_restitution(this.shape_id, this.restitution)

        common.draw_world_segment(
            b2.Vec2(x = 0.0, y = 0.0),
            b2.Vec2(x = 0.5, y = 0.0),
            b2.HexColor.b2_colorRed
        )
        common.draw_world_segment(
            b2.Vec2(x = 0.0, y = 0.0),
            b2.Vec2(x = 0.0, y = 0.5),
            b2.HexColor.b2_colorGreen
        )

    function shape_label() -> str:
        return match this.shape_kind:
            ShapeKind.circle: "circle"
            ShapeKind.capsule: "capsule"
            ShapeKind.box: "box"

    function draw_overlay() -> void:
        common.draw_text_line(f"shape = #{this.shape_label()} friction = #{this.friction:.2}")
        common.draw_text_line(f"restitution = #{this.restitution:.2}  controls: 1/2/3 shape  Space launch")
        common.draw_text_line("[ ] friction  - / = restitution")

function main() -> int:
    let world_id = common.create_world()
    var sample = chain_shape_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Chain Shape",
        b2.Vec2(x = 0.0, y = 0.0),
        25.0 * 1.75,
        world_id
    )
