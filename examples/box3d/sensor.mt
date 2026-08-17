## Box3D sample port: "Sensor Visit" (from box3d-upstream/samples/sample_events.cpp).
##
## A dynamic box drops through a kinematic sensor box. The moment the box's
## shape begins touching the sensor, the box is destroyed, demonstrating sensor
## begin-touch events.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import examples.box3d.common as common

struct Sensor implements common.Sample:
    world: b3.WorldId
    sensor_shape: b3.ShapeId
    visitor: b3.BodyId
    destroyed: bool

function sensor_create(world_id: b3.WorldId) -> Sensor:
    common.add_ground_box(10.0)
    # visitor: dynamic box dropping from above
    let dynamic_box = b3.make_box_hull(0.5, 0.5, 0.5)
    var visitor_def = b3.default_body_def()
    visitor_def.type = b3.BodyType.b3_dynamicBody
    visitor_def.position = b3.Vec3(x = 0.0, y = 12.5, z = 0.0)
    let visitor = b3.create_body(world_id, visitor_def)
    common.track_body(visitor)
    var visitor_shape = b3.default_shape_def()
    visitor_shape.enableSensorEvents = true
    b3.create_hull_shape(visitor, visitor_shape, dynamic_box.base)
    # sensor: kinematic box that destroys visitors
    let sensor_box = b3.make_box_hull(2.0, 2.0, 2.0)
    var sensor_def = b3.default_body_def()
    sensor_def.type = b3.BodyType.b3_kinematicBody
    sensor_def.position = b3.Vec3(x = 0.0, y = 2.0, z = 0.0)
    let sensor_body = b3.create_body(world_id, sensor_def)
    common.track_body(sensor_body)
    var sensor_shape = b3.default_shape_def()
    sensor_shape.isSensor = true
    sensor_shape.enableSensorEvents = true
    let sensor_shape_id = b3.create_hull_shape(sensor_body, sensor_shape, sensor_box.base)
    return Sensor(world = world_id, sensor_shape = sensor_shape_id, visitor = visitor, destroyed = false)

extending Sensor:
    editable function on_step() -> void:
        if this.destroyed:
            return
        let events = b3.world_get_sensor_events(this.world)
        var index = 0
        while index < events.beginCount:
            unsafe:
                let sensor_event = read(events.beginEvents + ptr_uint<-index)
                if sensor_event.sensorShapeId == this.sensor_shape:
                    let visitor_body = b3.shape_get_body(sensor_event.visitorShapeId)
                    if b3.body_is_valid(visitor_body):
                        b3.destroy_body(visitor_body)
                        this.destroyed = true
            index += 1

    editable function draw_overlay() -> void:
        if this.destroyed:
            common.draw_text_line("visitor destroyed on sensor touch")
        else:
            common.draw_text_line("sensor: visitor drops through the box")

function main() -> int:
    let world_id = common.create_world()
    var sample = sensor_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Sensor", b3.Vec3(x = 0.0, y = 5.0, z = 0.0), 18.0)
