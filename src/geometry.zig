// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;
const math = @import("fluxion_math");
const debugdraw = @import("fluxion_debugdraw");

const Camera = @import("Camera.zig");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Ray = math.Ray;
const Pen = debugdraw.Pen;
const Color = debugdraw.Color;

const tau = std.math.tau;

/// How far along the line the ray passes closest to it, or null where the
/// two run parallel.
pub fn closestAlong(origin: Vec3, direction: Vec3, ray: Ray) ?f32 {
    const offset = ray.origin.sub(origin);
    const b = ray.direction.dot(direction);
    const across = 1 - b * b;
    if (across < 1e-6) return null;
    return (direction.dot(offset) - b * ray.direction.dot(offset)) / across;
}

pub fn onPlane(ray: Ray, origin: Vec3, normal: Vec3) ?Vec3 {
    const t = ray.intersectPlane(.fromPointNormal(origin, normal)) orelse return null;
    const hit = ray.at(t);
    return if (hit.isFinite()) hit else null;
}

/// Radians from `from` to `to`, anticlockwise looking down `axis` at them.
pub fn signedAngle(from: Vec3, to: Vec3, axis: Vec3) f32 {
    return std.math.atan2(axis.dot(from.cross(to)), from.dot(to));
}

pub fn toSegment(p: Vec2, a: Vec2, b: Vec2) f32 {
    const along = b.sub(a);
    const length = along.lenSq();
    const t = if (length > 0) std.math.clamp(p.sub(a).dot(along) / length, 0, 1) else 0;
    return p.dist(a.add(along.scale(t)));
}

/// Zero inside a convex polygon, whichever way round it goes; how far
/// outside its edges otherwise.
pub fn toPolygon(p: Vec2, corners: []const Vec2) f32 {
    var nearest = std.math.inf(f32);
    var turn: f32 = 0;
    var inside = true;
    for (corners, 0..) |from, i| {
        const to = corners[(i + 1) % corners.len];
        nearest = @min(nearest, toSegment(p, from, to));
        const side = to.sub(from).crossZ(p.sub(from));
        if (side == 0) continue;
        if (turn == 0) turn = std.math.sign(side) else if (std.math.sign(side) != turn) inside = false;
    }
    return if (inside) 0 else nearest;
}

pub fn stepped(value: f32, snap: bool, step: f32) f32 {
    if (!snap or !(step > 0)) return value;
    return @round(value / step) * step;
}

/// A factor rounded to steps away from one, never through zero.
pub fn steppedFactor(factor: f32, snap: bool, step: f32) f32 {
    if (!snap or !(step > 0)) return factor;
    const rounded = 1 + @round((factor - 1) / step) * step;
    return if (rounded == 0) std.math.copysign(step, factor) else rounded;
}

pub fn smoothstep(low: f32, high: f32, value: f32) f32 {
    const t = std.math.clamp((value - low) / (high - low), 0, 1);
    return t * t * (3 - 2 * t);
}

pub fn faded(color: Color, alpha: f32) Color {
    return color.withAlpha(@as(f32, @floatFromInt(color.a)) / 255 * alpha);
}

/// Lighter the more a face turns towards the camera, so a solid shape
/// shows its shape without a light.
pub fn shaded(color: Color, normal: Vec3, toward: Vec3) Color {
    const light = 0.6 + 0.4 * @abs(normal.dot(toward));
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(color.r)) * light),
        .g = @intFromFloat(@as(f32, @floatFromInt(color.g)) * light),
        .b = @intFromFloat(@as(f32, @floatFromInt(color.b)) * light),
        .a = color.a,
    };
}

/// Two unit vectors at right angles to each other and to `normal`.
pub fn planeOf(normal: Vec3) [2]Vec3 {
    const u = normal.anyPerp();
    return .{ u, normal.cross(u) };
}

/// A circle about `axis`, as the part of it that faces the camera: all of
/// it seen face on, a little over half seen edge on.
pub const Ring = struct {
    center: Vec3,
    u: Vec3,
    v: Vec3,
    radius: f32,
    from: f32,
    sweep: f32,

    pub const max_points = 65;

    pub fn facing(center: Vec3, axis: Vec3, radius: f32, toward: Vec3) Ring {
        const plane = planeOf(axis);
        const across = toward.dot(plane[0]);
        const down = toward.dot(plane[1]);
        const seen = @sqrt(across * across + down * down);
        const half = if (seen > 1e-4) std.math.acos(std.math.clamp(-0.1 / seen, -1, 1)) else std.math.pi;
        if (half >= std.math.pi - 1e-4) return whole(center, axis, radius);
        const middle = std.math.atan2(down, across);
        return .{ .center = center, .u = plane[0], .v = plane[1], .radius = radius, .from = middle - half, .sweep = 2 * half };
    }

    pub fn whole(center: Vec3, axis: Vec3, radius: f32) Ring {
        const plane = planeOf(axis);
        return .{ .center = center, .u = plane[0], .v = plane[1], .radius = radius, .from = 0, .sweep = tau };
    }

    pub fn at(self: Ring, angle: f32) Vec3 {
        return self.center.add(self.u.scale(@cos(angle) * self.radius)).add(self.v.scale(@sin(angle) * self.radius));
    }

    pub fn points(self: Ring, buffer: *[max_points]Vec3) []Vec3 {
        const pieces: usize = @intFromFloat(@max(8, @ceil(64 * self.sweep / tau)));
        for (buffer[0 .. pieces + 1], 0..) |*point, i| {
            point.* = self.at(self.from + self.sweep * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pieces)));
        }
        return buffer[0 .. pieces + 1];
    }

    /// Pixels from `pointer` to the ring as drawn, and the point of it
    /// nearest.
    pub fn nearest(self: Ring, camera: Camera, pointer: Vec2) ?struct { distance: f32, point: Vec3 } {
        var buffer: [max_points]Vec3 = undefined;
        const line = self.points(&buffer);
        var best: ?struct { distance: f32, point: Vec3 } = null;
        for (line[0 .. line.len - 1], line[1..]) |a, b| {
            const seen = camera.segmentOnScreen(a, b) orelse continue;
            const distance = toSegment(pointer, seen[0], seen[1]);
            if (best == null or distance < best.?.distance) {
                const along = seen[1].sub(seen[0]);
                const t = if (along.lenSq() > 0) std.math.clamp(pointer.sub(seen[0]).dot(along) / along.lenSq(), 0, 1) else 0;
                best = .{ .distance = distance, .point = a.lerp(b, t) };
            }
        }
        return if (best) |found| .{ .distance = found.distance, .point = found.point } else null;
    }

    pub fn draw(self: Ring, pen: Pen, color: Color) void {
        var buffer: [max_points]Vec3 = undefined;
        pen.polyline(self.points(&buffer), color);
    }
};

/// Filled, with only the faces towards the camera drawn: a gizmo is drawn
/// over everything with no depth test, so a far face would cover a near one.
pub fn cone(pen: Pen, base: Vec3, tip: Vec3, radius: f32, color: Color, toward: Vec3) void {
    const along = tip.sub(base);
    const height = along.len();
    const axis = along.tryNorm() orelse return;
    const plane = planeOf(axis);
    const pieces = 14;
    const slice = tau / @as(f32, pieces);
    var previous = base.add(plane[0].scale(radius));
    for (1..pieces + 1) |i| {
        const angle = slice * @as(f32, @floatFromInt(i));
        const middle = angle - slice / 2;
        const next = base.add(plane[0].scale(@cos(angle) * radius)).add(plane[1].scale(@sin(angle) * radius));
        const out = plane[0].scale(@cos(middle)).add(plane[1].scale(@sin(middle)));
        const normal = out.scale(height).add(axis.scale(radius)).norm();
        if (normal.dot(toward) > 0) pen.solidTriangle(tip, previous, next, shaded(color, normal, toward));
        if (axis.dot(toward) < 0) pen.solidTriangle(base, next, previous, shaded(color, axis, toward));
        previous = next;
    }
}

/// A cone seen from above, for a plane whose camera keeps nothing off it: a
/// 2D camera's depth range can be as thin as the plane.
pub fn flatCone(pen: Pen, base: Vec3, tip: Vec3, radius: f32, color: Color, toward: Vec3) void {
    const side = toward.cross(tip.sub(base)).tryNorm() orelse return;
    pen.solidTriangle(tip, base.add(side.scale(radius)), base.sub(side.scale(radius)), color);
}

pub fn flatSquare(pen: Pen, center: Vec3, axes: [3]Vec3, half: f32, color: Color) void {
    const u = axes[0].scale(half);
    const v = axes[1].scale(half);
    pen.solidQuad(center.sub(u).sub(v), center.add(u).sub(v), center.add(u).add(v), center.sub(u).add(v), color);
}

pub fn cube(pen: Pen, center: Vec3, axes: [3]Vec3, half: f32, color: Color, toward: Vec3) void {
    for (0..3) |i| {
        const u = axes[(i + 1) % 3].scale(half);
        const v = axes[(i + 2) % 3].scale(half);
        for ([_]f32{ -1, 1 }) |side| {
            const normal = axes[i].scale(side);
            if (normal.dot(toward) <= 0) continue;
            const face = center.add(normal.scale(half));
            pen.solidQuad(face.sub(u).sub(v), face.add(u).sub(v), face.add(u).add(v), face.sub(u).add(v), shaded(color, normal, toward));
        }
    }
}

test "the closest point of a line to a ray across it is where they cross" {
    const ray: Ray = .init(.init(3, 5, 10), .init(0, 0, -1));
    try testing.expectApproxEqAbs(@as(f32, 3), closestAlong(.zero, .unit_x, ray).?, 1e-5);
    try testing.expect(closestAlong(.zero, .unit_z, ray) == null);
}

test "an angle is positive anticlockwise about its axis, and signed past a half turn" {
    try testing.expectApproxEqAbs(std.math.pi / 2.0, signedAngle(.unit_x, .unit_y, .unit_z), 1e-6);
    try testing.expectApproxEqAbs(-std.math.pi / 2.0, signedAngle(.unit_x, .unit_y, Vec3.unit_z.neg()), 1e-6);
    try testing.expectApproxEqAbs(-std.math.pi / 4.0, signedAngle(.unit_x, .init(1, -1, 0), .unit_z), 1e-6);
}

test "a point is inside a polygon going either way round, and its distance outside" {
    const square = [_]Vec2{ .init(0, 0), .init(10, 0), .init(10, 10), .init(0, 10) };
    const backwards = [_]Vec2{ square[3], square[2], square[1], square[0] };
    try testing.expectEqual(@as(f32, 0), toPolygon(.init(5, 5), &square));
    try testing.expectEqual(@as(f32, 0), toPolygon(.init(5, 5), &backwards));
    try testing.expectApproxEqAbs(@as(f32, 3), toPolygon(.init(13, 5), &square), 1e-5);
}

test "steps round to the nearest, and a factor never rounds to nothing" {
    try testing.expectEqual(@as(f32, 1.5), stepped(1.3, true, 0.5));
    try testing.expectEqual(@as(f32, 1.3), stepped(1.3, false, 0.5));
    try testing.expectApproxEqAbs(@as(f32, 1.2), steppedFactor(1.24, true, 0.1), 1e-5);
    try testing.expectEqual(@as(f32, 0.1), steppedFactor(0.04, true, 0.1));
}

test "a ring facing the camera is whole, and one seen edge on is a little over half" {
    const face_on: Ring = .facing(.zero, .unit_z, 1, .unit_z);
    try testing.expectEqual(@as(f32, tau), face_on.sweep);

    const edge_on: Ring = .facing(.zero, .unit_z, 1, .unit_x);
    try testing.expect(edge_on.sweep > std.math.pi and edge_on.sweep < std.math.pi * 1.1);
    try testing.expect(edge_on.at(edge_on.from + edge_on.sweep / 2).approxEql(.unit_x));
}

test "a ring has its share of points, and ends where it starts when whole" {
    var buffer: [Ring.max_points]Vec3 = undefined;
    const round = Ring.whole(.zero, .unit_y, 2).points(&buffer);
    try testing.expectEqual(@as(usize, 65), round.len);
    try testing.expect(round[0].approxEql(round[64]));
    for (round) |point| try testing.expectApproxEqAbs(@as(f32, 2), point.len(), 1e-4);
}
