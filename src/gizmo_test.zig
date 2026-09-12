// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;
const math = @import("fluxion_math");
const debugdraw = @import("fluxion_debugdraw");

const Gizmo = @import("Gizmo.zig");
const Camera = @import("Camera.zig");
const Pose2D = @import("Pose2D.zig");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Transform = math.Transform;
const Response = Gizmo.Response;

const width = 800;
const height = 600;
const thing: Gizmo.Id = .of("thing");

const Scene = struct {
    canvas: debugdraw.Canvas,
    gizmo: Gizmo = .{},
    view_projection: math.Mat4,
    clip: math.Clip = .gl,
    pointer: Vec2 = .zero,
    down: bool = false,
    hover: bool = true,
    snap: bool = false,
    uniform: bool = false,
    centered: bool = false,
    cancel: bool = false,

    fn init(view_projection: math.Mat4) Scene {
        return .{ .canvas = .init(testing.allocator), .view_projection = view_projection };
    }

    fn deinit(self: *Scene) void {
        self.canvas.deinit();
    }

    fn camera(self: *const Scene) Camera {
        return Camera.init(self.view_projection, self.clip, width, height).?;
    }

    fn pixelOf(self: *const Scene, at: Vec3) Vec2 {
        return self.camera().pixelOf(at).?;
    }

    fn sizeAt(self: *const Scene, at: Vec3) f32 {
        return self.camera().unitsPerPixel(at).? * self.gizmo.style.size;
    }

    fn frame(self: *Scene, call: anytype) Response {
        self.canvas.clear();
        self.gizmo.begin(.{
            .pen = self.canvas.pen(),
            .view_projection = self.view_projection,
            .clip = self.clip,
            .width = width,
            .height = height,
            .pointer = self.pointer,
            .hover = self.hover,
            .down = self.down,
            .snap = self.snap,
            .uniform = self.uniform,
            .centered = self.centered,
            .cancel = self.cancel,
        });
        defer self.gizmo.end();
        return call.run(&self.gizmo);
    }

    /// Hover, press, hold, move and let go.
    fn drag(self: *Scene, call: anytype, from: Vec2, to: Vec2) [4]Response {
        const pressed = self.press(call, from);
        const started = self.frame(call);
        const dragged = self.move(call, to);
        const finished = self.release(call);
        return .{ pressed, started, dragged, finished };
    }

    fn press(self: *Scene, call: anytype, at: Vec2) Response {
        self.pointer = at;
        self.down = false;
        _ = self.frame(call);
        self.down = true;
        return self.frame(call);
    }

    fn move(self: *Scene, call: anytype, to: Vec2) Response {
        self.pointer = to;
        return self.frame(call);
    }

    fn release(self: *Scene, call: anytype) Response {
        self.down = false;
        return self.frame(call);
    }
};

const Idle = struct {
    fn run(_: Idle, _: *Gizmo) Response {
        return .{};
    }
};

const OnPoint = struct {
    at: *Vec2,
    id: Gizmo.Id = .of("point"),

    fn run(self: OnPoint, gizmo: *Gizmo) Response {
        return gizmo.point2d(self.id, self.at, .{});
    }
};

const OnTwoPoints = struct {
    first: *Vec2,
    second: *Vec2,

    fn run(self: OnTwoPoints, gizmo: *Gizmo) Response {
        _ = gizmo.point2d(.of("first"), self.first, .{});
        return gizmo.point2d(.of("second"), self.second, .{});
    }
};

const OnSlider = struct {
    at: *Vec3,
    direction: Vec3,
    snap: f32 = 1,

    fn run(self: OnSlider, gizmo: *Gizmo) Response {
        return gizmo.slider(.of("slider"), self.at, self.direction, .{ .snap = self.snap });
    }
};

const OnRadius = struct {
    value: *f32,
    center: Vec2 = .zero,

    fn run(self: OnRadius, gizmo: *Gizmo) Response {
        return gizmo.radius2d(.of("radius"), self.value, self.center, .{});
    }
};

const OnTransform = struct {
    value: *Transform,
    options: Gizmo.Options = .{},

    fn run(self: OnTransform, gizmo: *Gizmo) Response {
        return gizmo.transform(thing, self.value, self.options);
    }
};

const OnPose = struct {
    pose: *Pose2D,
    options: Gizmo.Options = .{},

    fn run(self: OnPose, gizmo: *Gizmo) Response {
        return gizmo.transform2d(thing, self.pose, self.options);
    }
};

const OnBox = struct {
    pose: *Pose2D,
    rect: Gizmo.Rect,
    options: Gizmo.BoundsOptions = .{},

    fn run(self: OnBox, gizmo: *Gizmo) Response {
        return gizmo.bounds2d(thing, self.pose, self.rect, self.options);
    }
};

fn space() math.Mat4 {
    const projection = math.perspective(.{ .fov_y = math.radians(60), .aspect = @as(f32, width) / height, .near = 0.1, .far = 100, .clip = .gl });
    return projection.mul(math.lookAt(.init(4, 3, 8), .zero, .unit_y, .right));
}

fn plane(zoom: f32) math.Mat4 {
    const half_width = width / (2 * zoom);
    const half_height = height / (2 * zoom);
    return math.orthographic(.{ .left = -half_width, .right = half_width, .bottom = half_height, .top = -half_height, .near = -1, .far = 1, .clip = .gl });
}

fn expectNear(expected: Vec3, actual: Vec3) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, 1e-3);
    try testing.expectApproxEqAbs(expected.y, actual.y, 1e-3);
    try testing.expectApproxEqAbs(expected.z, actual.z, 1e-3);
}

test "the pointer over an arrow hovers it, from the next frame on" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value };

    scene.pointer = scene.pixelOf(.init(scene.sizeAt(.zero) * 0.6, 0, 0));
    try testing.expectEqual(Gizmo.Phase.idle, scene.frame(call).phase);
    const hovered = scene.frame(call);
    try testing.expectEqual(Gizmo.Phase.hovered, hovered.phase);
    try testing.expectEqual(Gizmo.Part.move_x, hovered.part.?);
    try testing.expect(scene.gizmo.wantsPointer());
}

test "dragging the x arrow moves along x as far as the pointer went" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const size = scene.sizeAt(.zero);

    const phases = scene.drag(OnTransform{ .value = &value }, scene.pixelOf(.init(size * 0.6, 0, 0)), scene.pixelOf(.init(size * 0.6 + 2, 0, 0)));

    try testing.expectEqual(Gizmo.Phase.hovered, phases[0].phase);
    try testing.expectEqual(Gizmo.Phase.started, phases[1].phase);
    try testing.expect(!phases[1].changed);
    try testing.expectEqual(Gizmo.Phase.dragging, phases[2].phase);
    try testing.expect(phases[2].changed);
    try testing.expectEqual(Gizmo.Phase.finished, phases[3].phase);
    try expectNear(.init(2, 0, 0), value.translation);
    try testing.expect(!scene.gizmo.isDragging());
}

test "the frame a drag starts in changes nothing, however the pointer moved" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value };
    const size = scene.sizeAt(.zero);

    _ = scene.press(call, scene.pixelOf(.init(size * 0.6, 0, 0)));
    const started = scene.move(call, scene.pixelOf(.init(size * 0.6 + 1, 0, 0)));
    try testing.expectEqual(Gizmo.Phase.started, started.phase);
    try testing.expect(!started.changed);
    try expectNear(.zero, value.translation);

    const dragged = scene.frame(call);
    try testing.expect(dragged.changed);
    try expectNear(.init(1, 0, 0), value.translation);
}

test "a click that does not move finishes and changes nothing" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value };

    _ = scene.press(call, scene.pixelOf(.init(scene.sizeAt(.zero) * 0.6, 0, 0)));
    const let_go = scene.release(call);
    try testing.expectEqual(Gizmo.Phase.finished, let_go.phase);
    try testing.expect(!let_go.changed);
    try testing.expect(value.eql(.identity));
}

test "snapping moves in steps from where the drag began" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .fromTranslation(.init(0.3, 0, 0));
    const call: OnTransform = .{ .value = &value, .options = .{ .snap = .{ .move = 0.5 } } };
    const size = scene.sizeAt(value.translation);
    scene.snap = true;

    _ = scene.drag(call, scene.pixelOf(.init(0.3 + size * 0.6, 0, 0)), scene.pixelOf(.init(0.3 + size * 0.6 + 1.3, 0, 0)));
    try expectNear(.init(1.8, 0, 0), value.translation);
}

test "snapping a plane square moves each way in steps" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const corner = scene.sizeAt(.zero) * 0.35;
    scene.snap = true;

    _ = scene.drag(
        OnTransform{ .value = &value, .options = .{ .snap = .{ .move = 0.5 } } },
        scene.pixelOf(.init(corner, corner, 0)),
        scene.pixelOf(.init(corner + 1.2, corner + 0.7, 0)),
    );
    try expectNear(.init(1, 0.5, 0), value.translation);
}

test "a snapped scale grows in steps" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const size = scene.sizeAt(.zero);
    scene.snap = true;

    _ = scene.drag(
        OnTransform{ .value = &value, .options = .{ .tool = .scale, .snap = .{ .scale = 0.25 } } },
        scene.pixelOf(.init(size, 0, 0)),
        scene.pixelOf(.init(size * 1.37, 0, 0)),
    );
    try expectNear(.init(1.25, 1, 1), value.scale);
}

test "cancelling puts the value back, and the held button starts nothing new" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value };
    const size = scene.sizeAt(.zero);
    const arrow = scene.pixelOf(.init(size * 0.6, 0, 0));

    _ = scene.press(call, arrow);
    _ = scene.frame(call);
    _ = scene.move(call, scene.pixelOf(.init(size * 0.6 + 3, 0, 0)));
    try testing.expect(!value.eql(.identity));

    scene.cancel = true;
    const cancelled = scene.frame(call);
    try testing.expectEqual(Gizmo.Phase.cancelled, cancelled.phase);
    try testing.expect(cancelled.changed);
    try testing.expect(value.eql(.identity));

    scene.cancel = false;
    _ = scene.move(call, arrow);
    _ = scene.move(call, scene.pixelOf(.init(size * 0.6 + 2, 0, 0)));
    try testing.expect(value.eql(.identity));
    try testing.expect(!scene.gizmo.isDragging());
}

test "a press away from every handle starts nothing" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value };

    const pressed = scene.press(call, .init(20, 20));
    try testing.expectEqual(Gizmo.Phase.idle, pressed.phase);
    try testing.expect(!scene.gizmo.wantsPointer());
    _ = scene.move(call, .init(300, 300));
    try testing.expect(value.eql(.identity));
}

test "nothing starts while the pointer is over something else" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value };
    scene.hover = false;

    _ = scene.press(call, scene.pixelOf(.init(scene.sizeAt(.zero) * 0.6, 0, 0)));
    try testing.expect(!scene.gizmo.isDragging());
    try testing.expect(!scene.gizmo.wantsPointer());
}

test "a drag whose handle is no longer drawn lets go" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value };

    _ = scene.press(call, scene.pixelOf(.init(scene.sizeAt(.zero) * 0.6, 0, 0)));
    try testing.expect(scene.gizmo.isDragging());
    _ = scene.frame(Idle{});
    try testing.expect(!scene.gizmo.isDragging());
}

test "a plane square moves across its plane and never off it" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const size = scene.sizeAt(.zero);
    const corner = size * 0.35;

    const phases = scene.drag(OnTransform{ .value = &value }, scene.pixelOf(.init(corner, corner, 0)), scene.pixelOf(.init(corner + 1, corner + 2, 0)));
    try testing.expectEqual(Gizmo.Part.move_xy, phases[0].part.?);
    try expectNear(.init(1, 2, 0), value.translation);
}

test "an arrow pointing at the camera cannot be grabbed" {
    const projection = math.perspective(.{ .fov_y = math.radians(60), .aspect = @as(f32, width) / height, .near = 0.1, .far = 100, .clip = .gl });
    var scene: Scene = .init(projection.mul(math.lookAt(.init(0, 0, 10), .zero, .unit_y, .right)));
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value };

    scene.pointer = scene.pixelOf(.init(0, 0, scene.sizeAt(.zero) * 0.6));
    _ = scene.frame(call);
    const hovered = scene.frame(call);
    try testing.expect(hovered.part != .move_z);

    const only_z: OnTransform = .{ .value = &value, .options = .{ .axes = .{ .x = false, .y = false } } };
    _ = scene.press(only_z, scene.pointer);
    try testing.expect(scene.canvas.isEmpty());
    try testing.expect(!scene.gizmo.isDragging());
}

const OnSharedId = struct {
    pose: *Pose2D,
    at: *Vec2,

    fn run(self: OnSharedId, gizmo: *Gizmo) Response {
        _ = gizmo.transform2d(thing, self.pose, .{});
        return gizmo.point2d(thing, self.at, .{});
    }
};

test "a gizmo and a handle may share an id" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var pose: Pose2D = .{};
    var at: Vec2 = .init(200, 150);

    _ = scene.drag(OnSharedId{ .pose = &pose, .at = &at }, scene.pixelOf(at.vec3(0)), scene.pixelOf(.init(230, 170, 0)));
    try testing.expect(at.approxEql(.init(230, 170)));
    try testing.expect(pose.eql(.{}));
}

test "an axis switched off has no handle" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value, .options = .{ .axes = .{ .x = false } } };

    scene.pointer = scene.pixelOf(.init(scene.sizeAt(.zero) * 0.6, 0, 0));
    _ = scene.frame(call);
    try testing.expect(scene.frame(call).part != .move_x);
}

test "in local space an arrow follows the thing's own axis" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .fromRotation(.fromAxisAngle(.unit_y, std.math.pi / 2.0));
    const own_x = value.right();
    const size = scene.sizeAt(.zero);

    _ = scene.drag(
        OnTransform{ .value = &value, .options = .{ .space = .local } },
        scene.pixelOf(own_x.scale(size * 0.6)),
        scene.pixelOf(own_x.scale(size * 0.6 + 1.5)),
    );
    try expectNear(own_x.scale(1.5), value.translation);
    try expectNear(.init(0, 0, -1.5), value.translation);
}

test "on a plane the y arrow points down the screen" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var pose: Pose2D = .{};
    const call: OnPose = .{ .pose = &pose };

    scene.pointer = .init(width / 2, height / 2 + 60);
    _ = scene.frame(call);
    try testing.expectEqual(Gizmo.Part.move_y, scene.frame(call).part.?);
}

test "the middle of a 2D gizmo moves the pose as far as the pointer, over the zoom" {
    var scene: Scene = .init(plane(2));
    defer scene.deinit();
    var pose: Pose2D = .{};

    const phases = scene.drag(OnPose{ .pose = &pose }, .init(width / 2, height / 2), .init(width / 2 + 40, height / 2 + 20));
    try testing.expectEqual(Gizmo.Part.move_view, phases[0].part.?);
    try testing.expectApproxEqAbs(@as(f32, 20), pose.position.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 10), pose.position.y, 1e-3);
}

test "turning the ring from right to below is a quarter turn clockwise" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var pose: Pose2D = .{};
    const size = scene.sizeAt(.zero);

    const phases = scene.drag(OnPose{ .pose = &pose, .options = .{ .tool = .rotate } }, scene.pixelOf(.init(size, 0, 0)), scene.pixelOf(.init(0, size, 0)));
    try testing.expectEqual(Gizmo.Part.rotate_z, phases[0].part.?);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, pose.rotation, 1e-3);
    try testing.expect(pose.position.eql(.zero));
}

test "a ring keeps counting past a half turn" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var pose: Pose2D = .{};
    const call: OnPose = .{ .pose = &pose, .options = .{ .tool = .rotate } };
    const size = scene.sizeAt(.zero);

    _ = scene.press(call, scene.pixelOf(.init(size, 0, 0)));
    _ = scene.frame(call);
    for (1..10) |step| {
        const angle = std.math.pi / 3.0 * @as(f32, @floatFromInt(step));
        _ = scene.move(call, scene.pixelOf(.init(@cos(angle) * size, @sin(angle) * size, 0)));
    }
    _ = scene.release(call);
    try testing.expectApproxEqAbs(3 * std.math.pi, pose.rotation, 1e-3);
}

test "a ring snaps to its steps" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var pose: Pose2D = .{};
    const size = scene.sizeAt(.zero);
    const angle = math.radians(50);
    scene.snap = true;

    _ = scene.drag(OnPose{ .pose = &pose, .options = .{ .tool = .rotate } }, scene.pixelOf(.init(size, 0, 0)), scene.pixelOf(.init(@cos(angle) * size, @sin(angle) * size, 0)));
    try testing.expectApproxEqAbs(math.radians(45), pose.rotation, 1e-4);
}

test "turning in space turns about the ring's axis" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const size = scene.sizeAt(.zero);
    const from = math.radians(45);
    const to = math.radians(135);

    const phases = scene.drag(
        OnTransform{ .value = &value, .options = .{ .tool = .rotate } },
        scene.pixelOf(.init(0, @cos(from) * size, @sin(from) * size)),
        scene.pixelOf(.init(0, @cos(to) * size, @sin(to) * size)),
    );
    try testing.expectEqual(Gizmo.Part.rotate_x, phases[0].part.?);
    try expectNear(.unit_z, value.rotation.rotate(.unit_y));
}

test "dragging a scale cube twice as far doubles that scale, and with uniform held every scale" {
    for ([_]bool{ false, true }) |uniform| {
        var scene: Scene = .init(space());
        defer scene.deinit();
        var value: Transform = .identity;
        const size = scene.sizeAt(.zero);
        scene.uniform = uniform;

        const phases = scene.drag(OnTransform{ .value = &value, .options = .{ .tool = .scale } }, scene.pixelOf(.init(size, 0, 0)), scene.pixelOf(.init(2 * size, 0, 0)));
        try testing.expectEqual(Gizmo.Part.scale_x, phases[0].part.?);
        try expectNear(if (uniform) .splat(2) else .init(2, 1, 1), value.scale);
        try expectNear(.zero, value.translation);
    }
}

test "the middle square scales everything by how far right it is dragged" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var pose: Pose2D = .{};

    const phases = scene.drag(OnPose{ .pose = &pose, .options = .{ .tool = .scale } }, .init(width / 2, height / 2), .init(width / 2 + 100, height / 2));
    try testing.expectEqual(Gizmo.Part.scale_all, phases[0].part.?);
    try testing.expectApproxEqAbs(@as(f32, 2), pose.scale.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), pose.scale.y, 1e-4);
}

const box: Gizmo.Rect = .sized(.init(40, 20), .splat(0.5));

fn boxScene() Scene {
    var scene: Scene = .init(plane(1));
    scene.view_projection = scene.view_projection.mul(.fromTranslation(.init(-100, -50, 0)));
    return scene;
}

test "a box's right side moves out and its left side stays" {
    var scene = boxScene();
    defer scene.deinit();
    var pose: Pose2D = .{ .position = .init(100, 50) };

    const phases = scene.drag(OnBox{ .pose = &pose, .rect = box }, scene.pixelOf(.init(120, 50, 0)), scene.pixelOf(.init(130, 50, 0)));
    try testing.expectEqual(Gizmo.Part.right, phases[0].part.?);
    try testing.expectApproxEqAbs(@as(f32, 1.25), pose.scale.x, 1e-4);
    try testing.expectEqual(@as(f32, 1), pose.scale.y);
    try testing.expectApproxEqAbs(@as(f32, 80), pose.apply(box.min).x, 1e-3);
}

test "a turned box resizes along its own sides" {
    var scene = boxScene();
    defer scene.deinit();
    var pose: Pose2D = .{ .position = .init(100, 50), .rotation = std.math.pi / 2.0 };

    const phases = scene.drag(OnBox{ .pose = &pose, .rect = box }, scene.pixelOf(.init(100, 70, 0)), scene.pixelOf(.init(100, 80, 0)));
    try testing.expectEqual(Gizmo.Part.right, phases[0].part.?);
    try testing.expectApproxEqAbs(@as(f32, 1.25), pose.scale.x, 1e-4);
    const held = pose.apply(.init(box.min.x, 0));
    try testing.expectApproxEqAbs(@as(f32, 100), held.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 30), held.y, 1e-3);
}

test "a corner with uniform held keeps the box's proportions" {
    var scene = boxScene();
    defer scene.deinit();
    var pose: Pose2D = .{ .position = .init(100, 50) };
    scene.uniform = true;

    _ = scene.drag(OnBox{ .pose = &pose, .rect = box }, scene.pixelOf(.init(120, 60, 0)), scene.pixelOf(.init(130, 62, 0)));
    try testing.expectApproxEqAbs(@as(f32, 1.25), pose.scale.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.25), pose.scale.y, 1e-4);
    const held = pose.apply(box.min);
    try testing.expectApproxEqAbs(@as(f32, 80), held.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 40), held.y, 1e-3);
}

test "centered, a side grows the box about its middle" {
    var scene = boxScene();
    defer scene.deinit();
    var pose: Pose2D = .{ .position = .init(100, 50) };
    scene.centered = true;

    _ = scene.drag(OnBox{ .pose = &pose, .rect = box }, scene.pixelOf(.init(120, 50, 0)), scene.pixelOf(.init(130, 50, 0)));
    try testing.expectApproxEqAbs(@as(f32, 1.5), pose.scale.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), pose.position.x, 1e-3);
}

test "inside a box drags it, and just outside a corner turns it" {
    var scene = boxScene();
    defer scene.deinit();
    var pose: Pose2D = .{ .position = .init(100, 50) };
    const call: OnBox = .{ .pose = &pose, .rect = box };

    const moved = scene.drag(call, scene.pixelOf(.init(95, 50, 0)), scene.pixelOf(.init(100, 47, 0)));
    try testing.expectEqual(Gizmo.Part.inside, moved[0].part.?);
    try testing.expect(pose.position.approxEql(.init(105, 47)));

    const turned = scene.drag(call, scene.pixelOf(.init(135, 25, 0)), scene.pixelOf(.init(105 + 22, 47 + 30, 0)));
    try testing.expectEqual(Gizmo.Part.around, turned[0].part.?);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, pose.rotation, 0.02);
    try testing.expect(pose.position.approxEql(.init(105, 47)));
}

test "a side just inside the box wins over the inside" {
    var scene = boxScene();
    defer scene.deinit();
    var pose: Pose2D = .{ .position = .init(100, 50) };
    const call: OnBox = .{ .pose = &pose, .rect = .sized(.init(200, 100), .splat(0.5)) };

    scene.pointer = scene.pixelOf(.init(198, 20, 0));
    _ = scene.frame(call);
    try testing.expectEqual(Gizmo.Part.right, scene.frame(call).part.?);
}

test "a point handle drags across the plane" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var at: Vec2 = .init(10, 10);

    _ = scene.drag(OnPoint{ .at = &at }, scene.pixelOf(.init(10, 10, 0)), scene.pixelOf(.init(25, 5, 0)));
    try testing.expect(at.approxEql(.init(25, 5)));
}

test "of two handles under the pointer, the nearer wins" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var first: Vec2 = .init(0, 0);
    var second: Vec2 = .init(10, 0);

    _ = scene.drag(OnTwoPoints{ .first = &first, .second = &second }, scene.pixelOf(.init(3, 0, 0)), scene.pixelOf(.init(3, 20, 0)));
    try testing.expect(first.approxEql(.init(0, 20)));
    try testing.expect(second.approxEql(.init(10, 0)));
}

test "a slider moves only along its line, in steps when snapping" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var at: Vec3 = .init(1, 0, 0);
    scene.snap = true;

    _ = scene.drag(OnSlider{ .at = &at, .direction = .unit_y, .snap = 0.25 }, scene.pixelOf(at), scene.pixelOf(.init(1.4, 1.1, 0.3)));
    try expectNear(.init(1, 1, 0), at);
}

test "a radius is dragged outwards and never below nothing" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var value: f32 = 50;

    _ = scene.drag(OnRadius{ .value = &value }, scene.pixelOf(.init(50, 0, 0)), scene.pixelOf(.init(80, 0, 0)));
    try testing.expectApproxEqAbs(@as(f32, 80), value, 1e-3);

    _ = scene.drag(OnRadius{ .value = &value }, scene.pixelOf(.init(0, 84, 0)), scene.pixelOf(.init(0, 1, 0)));
    try testing.expectEqual(@as(f32, 0), value);
}

test "a gizmo is drawn over everything, and not at all without a camera" {
    var scene: Scene = .init(space());
    defer scene.deinit();
    var value: Transform = .identity;
    const call: OnTransform = .{ .value = &value, .options = .{ .tool = .all } };

    _ = scene.frame(call);
    try testing.expect(scene.canvas.count(.world).lines > 0);
    try testing.expect(scene.canvas.count(.world).triangles > 0);
    for (scene.canvas.runs.items) |run| try testing.expectEqual(debugdraw.Depth.always, run.depth);

    scene.view_projection = .zero;
    try testing.expectEqual(Gizmo.Phase.idle, scene.frame(call).phase);
    try testing.expect(scene.canvas.isEmpty());
}

test "on a plane, nothing a gizmo draws leaves the plane" {
    var scene: Scene = .init(plane(1));
    defer scene.deinit();
    var pose: Pose2D = .{ .position = .init(30, -20), .rotation = 0.4 };

    for (std.enums.values(Gizmo.Tool)) |tool| {
        _ = scene.frame(OnPose{ .pose = &pose, .options = .{ .tool = tool } });
        for (scene.canvas.lines.items) |line| {
            try testing.expectEqual(@as(f32, 0), line.start[2]);
            try testing.expectEqual(@as(f32, 0), line.end[2]);
        }
        for (scene.canvas.vertices.items) |corner| try testing.expectEqual(@as(f32, 0), corner.position[2]);
    }
}

test "while dragging, what the drag has done is written beside the pointer" {
    var readouts: [2]u32 = undefined;
    for ([_]bool{ true, false }, &readouts) |readout, *drawn| {
        var scene: Scene = .init(space());
        defer scene.deinit();
        scene.gizmo.style.readout = readout;
        var value: Transform = .identity;
        const call: OnTransform = .{ .value = &value };
        const size = scene.sizeAt(.zero);

        _ = scene.press(call, scene.pixelOf(.init(size * 0.6, 0, 0)));
        _ = scene.frame(call);
        _ = scene.move(call, scene.pixelOf(.init(size * 0.6 + 1, 0, 0)));
        drawn.* = scene.canvas.count(.screen).triangles;
    }
    try testing.expect(readouts[0] > readouts[1]);
}

test "an id is the same for the same value and different for another" {
    try testing.expectEqual(Gizmo.Id.of("crate"), Gizmo.Id.of("crate"));
    try testing.expect(Gizmo.Id.of("crate") != Gizmo.Id.of("barrel"));
    try testing.expect(Gizmo.Id.of(.{ @as(u32, 7), @as(u32, 1) }) != Gizmo.Id.of(.{ @as(u32, 7), @as(u32, 2) }));
}
