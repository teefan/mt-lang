## Steering behaviors — Craig Reynolds' autonomous motion.
##
## Pure-function steering forces for autonomous agents.
## Seek, flee, arrive, pursuit, evade, wander, and flocking
## (separation, alignment, cohesion). All return steering
## force vectors to be accumulated and applied by the caller.
##
##   import std.steering as steer
##   var force = steer.Steer.seek(pos, vel, target, max_speed)
##   force = force + steer.Steer.separation(pos, neighbors, r, max_speed)

import std.linear_algebra as la
import std.math as math


# ── internal helpers ──

function set_magnitude(v: vec2, magnitude: float) -> vec2:
    let len = v.length()
    if len <= 0.0:
        return v
    return v * (magnitude / len)


function limit_force(steering: vec2, max_force: float) -> vec2:
    let mag = steering.length()
    if mag > max_force:
        return steering * (max_force / mag)
    return steering


# ── public API ──

extending vec2:
    public static function seek(position: vec2, velocity: vec2, target: vec2, max_speed: float) -> vec2:
        let desired = target - position
        let desired_vel = set_magnitude(desired, max_speed)
        return desired_vel - velocity


    public static function flee(position: vec2, velocity: vec2, threat: vec2, max_speed: float) -> vec2:
        let desired = position - threat
        let desired_vel = set_magnitude(desired, max_speed)
        return desired_vel - velocity


    public static function arrive(position: vec2, velocity: vec2, target: vec2, max_speed: float, slowing_distance: float) -> vec2:
        let offset = target - position
        let distance = offset.length()
        if distance < 0.001:
            return zero[vec2]
        let speed = if distance < slowing_distance: max_speed * distance / slowing_distance else: max_speed
        let desired_vel = offset * (speed / distance)
        return desired_vel - velocity


    public static function pursuit(position: vec2, velocity: vec2, target_pos: vec2, target_vel: vec2, max_speed: float) -> vec2:
        let offset = target_pos - position
        let distance = offset.length()
        let my_speed = velocity.length()
        var look_ahead: float = distance / (max_speed + 0.001)
        if my_speed > 0.001:
            look_ahead = distance / my_speed
        let future = target_pos + target_vel * look_ahead
        return vec2.seek(position, velocity, future, max_speed)


    public static function evade(position: vec2, velocity: vec2, threat_pos: vec2, threat_vel: vec2, max_speed: float) -> vec2:
        let offset = threat_pos - position
        let distance = offset.length()
        let my_speed = velocity.length()
        var look_ahead: float = distance / (max_speed + 0.001)
        if my_speed > 0.001:
            look_ahead = distance / my_speed
        let future = threat_pos + threat_vel * look_ahead
        return vec2.flee(position, velocity, future, max_speed)


    public static function wander(velocity: vec2, wander_angle: float, wander_distance: float, wander_radius: float) -> vec2:
        if velocity.length() < 0.001:
            return zero[vec2]
        let forward = set_magnitude(velocity, 1.0)
        let circle_center = forward * wander_distance
        let wx = circle_center.x + wander_radius * float<-math.cos(double<-wander_angle)
        let wy = circle_center.y + wander_radius * float<-math.sin(double<-wander_angle)
        let displacement = vec2(x = wx, y = wy)
        return displacement


    public static function separation(position: vec2, neighbors: span[vec2], desired_separation: float) -> vec2:
        var steer: vec2 = zero[vec2]
        var count: ptr_uint = 0
        for n in neighbors:
            let d = position - n
            let distance = d.length()
            if distance > 0.0 and distance < desired_separation:
                let repulsion = d * (1.0 / distance)
                steer = steer + repulsion
                count += 1
        if count > 0:
            steer = steer / float<-count
        return steer


    public static function alignment(velocity: vec2, neighbor_velocities: span[vec2]) -> vec2:
        var sum: vec2 = zero[vec2]
        var count: ptr_uint = 0
        for nv in neighbor_velocities:
            sum = sum + nv
            count += 1
        if count > 0:
            let avg = sum / float<-count
            return avg - velocity
        return zero[vec2]


    public static function cohesion(position: vec2, neighbor_positions: span[vec2], radius: float) -> vec2:
        var sum: vec2 = zero[vec2]
        var count: ptr_uint = 0
        for np in neighbor_positions:
            let d = position - np
            if d.length() < radius:
                sum = sum + np
                count += 1
        if count > 0:
            let center = sum / float<-count
            return center - position
        return zero[vec2]


    public static function limit(steering: vec2, max_force: float) -> vec2:
        return limit_force(steering, max_force)