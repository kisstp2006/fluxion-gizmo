// SPDX-License-Identifier: BSD-2-Clause

//! The camera as a gizmo needs it, read from the matrix the renderer draws
//! with: where a point lands in pixels, the ray under a pixel, and how much
//! of the world one pixel covers.

const std = @import("std");
const testing = std.testing;
const math = @import("fluxion_math");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
const Ray = math.Ray;

const Camera = @This();

view_projection: Mat4,
inverse: Mat4,
clip: math.Clip,
/// Pixels.
width: f32,
height: f32,
/// Where a perspective camera stands. Null for an orthographic one.
eye: ?Vec3,
/// Away from the camera, through the middle of the picture.
forward: Vec3,

/// Nearer than this to the plane the camera stands in is behind it.
const nearest_w = 1e-5;

/// Null for a matrix that cannot be undone, or a picture with no pixels.
pub fn init(view_projection: Mat4, clip: math.Clip, width: f32, height: f32) ?Camera {
    if (!(width > 0 and height > 0)) return null;
    const inverse = view_projection.inverse() orelse return null;
    if (!inverse.isFinite()) return null;

    var self: Camera = .{
        .view_projection = view_projection,
        .inverse = inverse,
        .clip = clip,
        .width = width,
        .height = height,
        .eye = null,
        .forward = .zero,
    };
    self.forward = (self.rayThrough(.init(width / 2, height / 2)) orelse return null).direction;

    // The only point with clip-space x, y and w all zero is the eye; for an
    // orthographic camera it is a direction, with no position to divide to.
    const centre = inverse.mulVec4(.init(0, 0, 1, 0));
    if (@abs(centre.w) > 1e-6 * centre.xyz().len()) self.eye = centre.xyz().scale(1 / centre.w);
    return self;
}

/// Pixels from the top left, or null behind the camera.
pub fn pixelOf(self: Camera, at: Vec3) ?Vec2 {
    const clipped = self.view_projection.mulVec4(at.point());
    if (!(clipped.w > nearest_w)) return null;
    return self.pixelOfClip(clipped);
}

pub fn rayThrough(self: Camera, pixel: Vec2) ?Ray {
    return Ray.throughPixel(self.inverse, pixel, self.width, self.height, self.clip);
}

/// A unit vector from `at` towards the camera.
pub fn toCamera(self: Camera, at: Vec3) Vec3 {
    const eye = self.eye orelse return self.forward.neg();
    return eye.sub(at).tryNorm() orelse self.forward.neg();
}

/// World units across one pixel at `at`, or null where `at` is not in front
/// of the camera.
pub fn unitsPerPixel(self: Camera, at: Vec3) ?f32 {
    const clipped = self.view_projection.mulVec4(at.point());
    if (!(clipped.w > nearest_w)) return null;
    const ndc = clipped.xyz().scale(1 / clipped.w);
    const here = self.inverse.project(ndc) orelse return null;
    const across = self.inverse.project(ndc.add(.init(2 / self.width, 0, 0))) orelse return null;
    const down = self.inverse.project(ndc.add(.init(0, 2 / self.height, 0))) orelse return null;
    const units = (across.dist(here) + down.dist(here)) / 2;
    return if (units > 0 and std.math.isFinite(units)) units else null;
}

/// The part of a segment in front of the camera, in pixels.
pub fn segmentOnScreen(self: Camera, from: Vec3, to: Vec3) ?[2]Vec2 {
    var a = self.view_projection.mulVec4(from.point());
    var b = self.view_projection.mulVec4(to.point());
    const a_shows = a.w > nearest_w;
    const b_shows = b.w > nearest_w;
    if (!a_shows and !b_shows) return null;
    if (!a_shows) a = cut(a, b);
    if (!b_shows) b = cut(b, a);
    return .{ self.pixelOfClip(a), self.pixelOfClip(b) };
}

fn cut(behind: Vec4, front: Vec4) Vec4 {
    return behind.lerp(front, (nearest_w - behind.w) / (front.w - behind.w));
}

fn pixelOfClip(self: Camera, clipped: Vec4) Vec2 {
    const x = clipped.x / clipped.w;
    const y = clipped.y / clipped.w;
    const up = if (self.clip.flip_y) -y else y;
    return .init((x + 1) / 2 * self.width, (1 - up) / 2 * self.height);
}

const test_width = 800;
const test_height = 600;

fn perspectiveFrom(eye: Vec3, clip: math.Clip) Mat4 {
    const projection = math.perspective(.{
        .fov_y = math.radians(60),
        .aspect = @as(f32, test_width) / test_height,
        .near = 0.1,
        .far = 100,
        .clip = clip,
    });
    return projection.mul(math.lookAt(eye, .zero, .unit_y, .right));
}

fn plane(x: f32, y: f32, zoom: f32, clip: math.Clip) Mat4 {
    const half_width = test_width / (2 * zoom);
    const half_height = test_height / (2 * zoom);
    const projection = math.orthographic(.{
        .left = -half_width,
        .right = half_width,
        .bottom = half_height,
        .top = -half_height,
        .near = -1,
        .far = 1,
        .clip = clip,
    });
    return projection.mul(.fromTranslation(.init(-x, -y, 0)));
}

fn expectNear(expected: Vec2, actual: Vec2) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, 0.01);
    try testing.expectApproxEqAbs(expected.y, actual.y, 0.01);
}

test "a point lands on the pixel whose ray passes through it" {
    for ([_]math.Clip{ .gl, .d3d, .vulkan }) |clip| {
        for ([_]Mat4{ perspectiveFrom(.init(3, 4, 9), clip), plane(20, -5, 2, clip) }) |matrix| {
            const camera = Camera.init(matrix, clip, test_width, test_height).?;
            for ([_]Vec2{ .init(0, 0), .init(400, 300), .init(123.5, 555), .init(799, 17) }) |pixel| {
                const ray = camera.rayThrough(pixel).?;
                try expectNear(pixel, camera.pixelOf(ray.at(0.5)).?);
            }
        }
    }
}

test "the top of the picture is up in space and down the plane" {
    const space = Camera.init(perspectiveFrom(.init(0, 0, 10), .gl), .gl, test_width, test_height).?;
    try testing.expect(space.pixelOf(.init(0, 1, 0)).?.y < test_height / 2);

    const flat = Camera.init(plane(0, 0, 1, .gl), .gl, test_width, test_height).?;
    try expectNear(.init(test_width / 2 + 10, test_height / 2 + 20), flat.pixelOf(.init(10, 20, 0)).?);
}

test "nothing behind the camera has a pixel" {
    const camera = Camera.init(perspectiveFrom(.init(0, 0, 10), .gl), .gl, test_width, test_height).?;
    try testing.expect(camera.pixelOf(.init(0, 0, 11)) == null);
    try testing.expect(camera.unitsPerPixel(.init(0, 0, 20)) == null);
}

test "a pixel on the plane is one over the zoom" {
    const camera = Camera.init(plane(50, 50, 4, .d3d), .d3d, test_width, test_height).?;
    try testing.expectApproxEqRel(@as(f32, 0.25), camera.unitsPerPixel(.init(80, 10, 0)).?, 1e-4);
}

test "in perspective a pixel covers more the further away it is" {
    const camera = Camera.init(perspectiveFrom(.init(0, 0, 10), .gl), .gl, test_width, test_height).?;
    const expected = 2 * 10 * @tan(math.radians(30)) / test_height;
    try testing.expectApproxEqRel(expected, camera.unitsPerPixel(.zero).?, 1e-3);
    try testing.expectApproxEqRel(expected * 1.5, camera.unitsPerPixel(.init(0, 0, -5)).?, 1e-3);
}

test "towards the camera is towards its eye, or back along its view" {
    const space = Camera.init(perspectiveFrom(.init(0, 6, 8), .gl), .gl, test_width, test_height).?;
    try testing.expect(space.eye.?.approxEql(.init(0, 6, 8)));
    try testing.expect(space.toCamera(.zero).approxEql(Vec3.init(0, 6, 8).norm()));

    const flat = Camera.init(plane(0, 0, 1, .gl), .gl, test_width, test_height).?;
    try testing.expect(flat.eye == null);
    try testing.expect(flat.toCamera(.init(5, 5, 0)).approxEql(.unit_z));
}

test "a segment that runs behind the camera is cut where it leaves" {
    const camera = Camera.init(perspectiveFrom(.init(0, 0, 10), .gl), .gl, test_width, test_height).?;
    const seen = camera.segmentOnScreen(.init(1, 0, 0), .init(1, 0, 30)).?;
    try expectNear(camera.pixelOf(.init(1, 0, 0)).?, seen[0]);
    try testing.expect(std.math.isFinite(seen[1].x) and @abs(seen[1].x) > test_width);
    try testing.expect(camera.segmentOnScreen(.init(0, 0, 20), .init(1, 0, 30)) == null);
}

test "a matrix that cannot be undone is no camera" {
    try testing.expect(Camera.init(.zero, .gl, test_width, test_height) == null);
    try testing.expect(Camera.init(.identity, .gl, 0, test_height) == null);
}
