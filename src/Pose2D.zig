// SPDX-License-Identifier: BSD-2-Clause

//! Where a thing is on a plane, which way it is turned and how big it is.
//! `rotation` turns `+x` towards `+y`: clockwise on a screen whose `y` points
//! down, as in fluxion-engine and fluxion-debugdraw.

const std = @import("std");
const testing = std.testing;
const math = @import("fluxion_math");

const Vec2 = math.Vec2;

const Pose2D = @This();

position: Vec2 = .zero,
/// Radians.
rotation: f32 = 0,
scale: Vec2 = .one,

pub fn init(position: Vec2, rotation: f32, scale: Vec2) Pose2D {
    return .{ .position = position, .rotation = rotation, .scale = scale };
}

/// A point in the pose's own space, in the plane it sits in.
pub fn apply(self: Pose2D, local: Vec2) Vec2 {
    return self.position.add(local.mul(self.scale).rotate(self.rotation));
}

pub fn applyInverse(self: Pose2D, point: Vec2) Vec2 {
    const turned = point.sub(self.position).rotate(-self.rotation);
    return .init(undo(turned.x, self.scale.x), undo(turned.y, self.scale.y));
}

/// The same pose in space, at `z = 0`, turned about `+z`.
pub fn transform(self: Pose2D) math.Transform {
    return .init(self.position.vec3(0), .fromAxisAngle(.unit_z, self.rotation), .init(self.scale.x, self.scale.y, 1));
}

pub fn matrix(self: Pose2D) math.Mat4 {
    return self.transform().toMat4();
}

pub fn eql(a: Pose2D, b: Pose2D) bool {
    return a.position.eql(b.position) and a.rotation == b.rotation and a.scale.eql(b.scale);
}

fn undo(value: f32, scale: f32) f32 {
    return if (scale == 0) 0 else value / scale;
}

test "a pose scales, then turns, then moves" {
    const pose: Pose2D = .init(.init(10, 20), std.math.pi / 2.0, .init(2, 3));
    const moved = pose.apply(.init(1, 0));
    try testing.expectApproxEqAbs(@as(f32, 10), moved.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 22), moved.y, 1e-5);
}

test "applyInverse undoes apply" {
    const pose: Pose2D = .init(.init(-4, 7), 0.8, .init(-1.5, 0.5));
    const local: Vec2 = .init(3, -2);
    const back = pose.applyInverse(pose.apply(local));
    try testing.expectApproxEqAbs(local.x, back.x, 1e-5);
    try testing.expectApproxEqAbs(local.y, back.y, 1e-5);
}

test "in space, a pose is the same turn about z" {
    const pose: Pose2D = .init(.init(5, 6), 0.6, .init(2, 0.5));
    const flat = pose.apply(.init(1, 1));
    const deep = pose.matrix().mulPoint(.init(1, 1, 0));
    try testing.expectApproxEqAbs(flat.x, deep.x, 1e-5);
    try testing.expectApproxEqAbs(flat.y, deep.y, 1e-5);
    try testing.expectEqual(@as(f32, 0), deep.z);
}
