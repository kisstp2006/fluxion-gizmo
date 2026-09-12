// SPDX-License-Identifier: BSD-2-Clause

//! Handles for the pointer to drag, drawn with a debugdraw pen. One per
//! view: it keeps what the pointer is over and what it drags from one frame
//! to the next.

const std = @import("std");
const math = @import("fluxion_math");
const debugdraw = @import("fluxion_debugdraw");

const Camera = @import("Camera.zig");
const Pose2D = @import("Pose2D.zig");
const geometry = @import("geometry.zig");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Quat = math.Quat;
const Transform = math.Transform;
const Ray = math.Ray;
const Pen = debugdraw.Pen;
const Color = debugdraw.Color;
const Ring = geometry.Ring;

const Gizmo = @This();

style: Style = .{},

frame: ?Frame = null,
camera: ?Camera = null,
was_down: bool = false,
pressed: bool = false,
/// Where the button went down, in pixels.
press: Vec2 = .zero,
/// What the pointer was over when the last frame ended, or what is dragged.
hot: ?Key = null,
best: ?Candidate = null,
drag: ?Drag = null,
drag_seen: bool = false,

/// Names a gizmo or a handle from one frame to the next.
pub const Id = enum(u64) {
    _,

    /// Any value, hashed: an entity, a name, a tuple of both.
    pub fn of(value: anytype) Id {
        var hasher: std.hash.Wyhash = .init(0);
        std.hash.autoHashStrat(&hasher, value, .Deep);
        return @enumFromInt(hasher.final());
    }
};

pub const Frame = struct {
    /// Draws in the world the camera looks at.
    pen: Pen,
    view_projection: math.Mat4,
    clip: math.Clip,
    /// Pixels.
    width: f32,
    height: f32,
    /// Pixels from the top left of the view.
    pointer: Vec2,
    /// False while the pointer is over something else: nothing new starts,
    /// and a drag already going carries on.
    hover: bool = true,
    /// The button that drags is held.
    down: bool,
    snap: bool = false,
    /// Scale every axis together, and keep a box's proportions.
    uniform: bool = false,
    /// Grow a box about its middle.
    centered: bool = false,
    /// Put back what the drag changed, and stop it.
    cancel: bool = false,
};

pub const Phase = enum {
    idle,
    hovered,
    /// Pressed. The value is still what it was: keep it for undoing.
    started,
    dragging,
    /// Let go: the value stays as it is now.
    finished,
    /// The value is back to what it was when the drag started.
    cancelled,
};

pub const Response = struct {
    phase: Phase = .idle,
    /// The value was written this frame.
    changed: bool = false,
    /// What is hovered or dragged.
    part: ?Part = null,
};

pub const Part = enum {
    move_x,
    move_y,
    move_z,
    /// Across the plane square to x, to y and to z.
    move_yz,
    move_zx,
    move_xy,
    /// Across the plane facing the camera.
    move_view,
    rotate_x,
    rotate_y,
    rotate_z,
    rotate_view,
    scale_x,
    scale_y,
    scale_z,
    scale_all,
    /// A box's sides and corners, as on a screen whose `y` points down.
    left,
    right,
    top,
    bottom,
    top_left,
    top_right,
    bottom_right,
    bottom_left,
    inside,
    /// Just outside a box's corners, where dragging turns it.
    around,
    point,
    slider,
    radius,
};

pub const Tool = enum { move, rotate, scale, all };

/// Whose axes the arrows and rings follow. Scaling always follows the
/// thing's own.
pub const Space = enum { world, local };

/// An axis switched off is neither moved along, turned about, nor scaled
/// along. In 2D, `z` is the turn.
pub const Axes = struct {
    x: bool = true,
    y: bool = true,
    z: bool = true,
};

/// Steps a drag moves in while `Frame.snap` is held, from where it started.
pub const Snap = struct {
    /// World units.
    move: f32 = 1,
    /// Radians.
    rotate: f32 = std.math.pi / 12.0,
    /// A fraction of the scale the drag started at.
    scale: f32 = 0.1,
};

pub const Options = struct {
    tool: Tool = .move,
    space: Space = .world,
    snap: Snap = .{},
    axes: Axes = .{},
};

/// A box in the local space of a pose, before its scale.
pub const Rect = struct {
    min: Vec2,
    max: Vec2,

    pub fn init(min: Vec2, max: Vec2) Rect {
        return .{ .min = min, .max = max };
    }

    /// `size` across and down, with `pivot` - from zero to one each way - on
    /// the origin: a sprite's rectangle.
    pub fn sized(size: Vec2, pivot: Vec2) Rect {
        return .{ .min = size.mul(pivot).neg(), .max = size.mul(Vec2.one.sub(pivot)) };
    }

    pub fn center(self: Rect) Vec2 {
        return self.min.add(self.max).scale(0.5);
    }
};

pub const BoundsOptions = struct {
    snap: Snap = .{},
    /// Turning from just outside a corner.
    rotate: bool = true,
    /// Moving from inside.
    move: bool = true,
};

pub const HandleOptions = struct {
    color: ?Color = null,
    /// World units a snapped drag moves by.
    snap: f32 = 1,
    /// The plane `point` moves in, by its normal. Null faces the camera.
    normal: ?Vec3 = null,
    /// Pixels across.
    size: f32 = 11,
};

pub const Style = struct {
    /// Pixels from the middle of a gizmo to the tips of its arrows.
    size: f32 = 100,
    /// Pixels.
    width: f32 = 3,
    /// Pixels round a handle that still count as on it.
    reach: f32 = 6,
    x: Color = .red,
    y: Color = .green,
    z: Color = .blue,
    view: Color = .hex(0xD8D8D8),
    hot: Color = .yellow,
    handle: Color = .white,
    text: Color = .white,
    /// How much of the rest of a gizmo shows while one part of it is dragged.
    others: f32 = 0.3,
    /// Say beside the pointer what a drag has done.
    readout: bool = true,

    fn axisColor(self: Style, axis: usize) Color {
        return switch (axis) {
            0 => self.x,
            1 => self.y,
            else => self.z,
        };
    }
};

const Key = struct {
    id: Id,
    part: Part,

    fn eql(a: Key, b: Key) bool {
        return a.id == b.id and a.part == b.part;
    }
};

/// Of two handles under the pointer, a small one wins over a line through
/// it, a line over the area it borders, and an area over the zone round a
/// box's corners. Within a rank the nearer wins, then the later drawn.
const Rank = enum { handle, line, area, zone };

const Candidate = struct {
    key: Key,
    rank: Rank,
    distance: f32,
};

const Family = enum { transform, bounds, point, slider, radius };

fn familyOf(part: Part) Family {
    return switch (part) {
        .move_x, .move_y, .move_z, .move_yz, .move_zx, .move_xy, .move_view => .transform,
        .rotate_x, .rotate_y, .rotate_z, .rotate_view => .transform,
        .scale_x, .scale_y, .scale_z, .scale_all => .transform,
        .left, .right, .top, .bottom, .top_left, .top_right, .bottom_right, .bottom_left => .bounds,
        .inside, .around => .bounds,
        .point => .point,
        .slider => .slider,
        .radius => .radius,
    };
}

const Start = union(enum) {
    none,
    transform: Transform,
    pose: Pose2D,
    point: Vec3,
    number: f32,
};

const Change = union(enum) {
    none,
    move: Vec3,
    turn: struct { axis: Vec3, angle: f32 },
    scale: Vec3,
};

const Drag = struct {
    key: Key,
    fresh: bool = true,
    start: Start = .none,
    rig: Rig = undefined,
    rect: Rect = undefined,
    /// The line it slides along, the normal of the plane it slides across,
    /// or what it turns about.
    axis: Vec3 = .zero,
    /// Where the press met that plane.
    grab: Vec3 = .zero,
    /// How far along that line the press was.
    along: f32 = 0,
    /// Radians so far, counted on past a whole turn.
    turned: f32 = 0,
    /// From the middle towards the press, and towards the pointer last frame.
    first: Vec3 = .zero,
    radial: Vec3 = .zero,
    /// Seen edge on: follow the pointer along the screen or a line, not
    /// across a plane that runs away from the camera.
    edge: bool = false,
    tangent: Vec2 = .zero,
    change: Change = .none,
};

/// Start a frame. Everything drawn between this and `end` is drawn with the
/// frame's pen, and answers to its pointer.
pub fn begin(self: *Gizmo, frame: Frame) void {
    self.frame = frame;
    self.camera = Camera.init(frame.view_projection, frame.clip, frame.width, frame.height);
    self.pressed = frame.down and !self.was_down;
    if (self.pressed) self.press = frame.pointer;
    self.best = null;
    self.drag_seen = false;
}

/// Settle what the pointer is over, and start dragging it if it was pressed.
pub fn end(self: *Gizmo) void {
    const frame = self.frame orelse return;
    if (self.drag != null and (!self.drag_seen or !frame.down or frame.cancel)) self.drag = null;
    if (self.pressed and self.drag == null) {
        if (self.best) |best| self.drag = .{ .key = best.key };
    }
    self.hot = if (self.drag) |drag| drag.key else if (self.best) |best| best.key else null;
    self.was_down = frame.down;
    self.frame = null;
    self.camera = null;
}

/// After `end`: the pointer is on a handle, or one is being dragged. A view
/// that also picks with the pointer leaves this frame's press alone.
pub fn wantsPointer(self: *const Gizmo) bool {
    return self.hot != null;
}

pub fn isDragging(self: *const Gizmo) bool {
    return self.drag != null;
}

fn ready(self: *const Gizmo) ?Camera {
    if (self.frame == null) return null;
    return self.camera;
}

fn offer(self: *Gizmo, key: Key, rank: Rank, distance: f32) void {
    const frame = self.frame orelse return;
    if (!frame.hover or self.drag != null or !(distance <= self.style.reach)) return;
    if (self.best) |best| {
        const better = @intFromEnum(rank) < @intFromEnum(best.rank) or
            (rank == best.rank and distance <= best.distance);
        if (!better) return;
    }
    self.best = .{ .key = key, .rank = rank, .distance = distance };
}

fn draggedAs(self: *Gizmo, id: Id, family: Family) ?*Drag {
    if (self.drag) |*drag| {
        if (drag.key.id == id and familyOf(drag.key.part) == family) {
            self.drag_seen = true;
            return drag;
        }
    }
    return null;
}

fn hoverOf(self: *const Gizmo, id: Id, family: Family) Response {
    const hot = self.hot orelse return .{};
    if (self.drag != null or hot.id != id or familyOf(hot.part) != family) return .{};
    return .{ .phase = .hovered, .part = hot.part };
}

/// Where a dragged handle is, once it has done this frame's work.
fn progress(self: *Gizmo, drag: *Drag, changed: bool) Response {
    const frame = self.frame.?;
    const phase: Phase = if (frame.cancel)
        .cancelled
    else if (!frame.down)
        .finished
    else if (drag.fresh)
        .started
    else
        .dragging;
    drag.fresh = false;
    return .{ .phase = phase, .changed = changed, .part = drag.key.part };
}

/// A press that met nothing it could follow, such as a plane seen edge on.
fn abandon(self: *Gizmo) Response {
    self.drag = null;
    return .{};
}

const Look = enum { plain, hot, dragged, other };

fn lookOf(self: *const Gizmo, key: Key) Look {
    if (self.drag) |drag| {
        if (drag.key.eql(key)) return .dragged;
        if (drag.key.id == key.id and familyOf(drag.key.part) == familyOf(key.part)) return .other;
        return .plain;
    }
    if (self.hot) |hot| if (hot.eql(key)) return .hot;
    return .plain;
}

fn colorOf(self: *const Gizmo, key: Key, base: Color, alpha: f32) Color {
    return switch (self.lookOf(key)) {
        .plain => geometry.faded(base, alpha),
        .hot => geometry.faded(self.style.hot, alpha),
        .dragged => self.style.hot,
        .other => geometry.faded(base, alpha * self.style.others),
    };
}

/// The alpha to draw a part with, or null where it is not drawn at all.
fn shown(self: *const Gizmo, key: Key, visibility: f32) ?f32 {
    if (self.lookOf(key) == .dragged) return 1;
    return if (visibility > 0) visibility else null;
}

fn penOf(self: *const Gizmo) Pen {
    var pen = self.frame.?.pen;
    pen.space = .world;
    pen.transform = null;
    return pen.with(.{ .depth = .always, .seconds = 0, .width = self.style.width, .anchor = .top_left, .text_scale = 1 });
}

fn pointer(self: *const Gizmo) Vec2 {
    return self.frame.?.pointer;
}

// -------------------------------------------------------------------------
// Move, rotate and scale
// -------------------------------------------------------------------------

/// Arrows, rings and cubes that move, turn and scale a thing in space.
pub fn transform(self: *Gizmo, id: Id, value: *Transform, options: Options) Response {
    return self.manipulate(id, .{ .space = value }, options);
}

/// The same on a plane, for a pose whose `y` points down the screen.
pub fn transform2d(self: *Gizmo, id: Id, pose: *Pose2D, options: Options) Response {
    return self.manipulate(id, .{ .plane = pose }, options);
}

const Subject = union(enum) {
    space: *Transform,
    plane: *Pose2D,

    fn flat(self: Subject) bool {
        return self == .plane;
    }

    fn origin(self: Subject) Vec3 {
        return switch (self) {
            .space => |value| value.translation,
            .plane => |pose| pose.position.vec3(0),
        };
    }

    fn rotation(self: Subject) Quat {
        return switch (self) {
            .space => |value| value.rotation,
            .plane => |pose| .fromAxisAngle(.unit_z, pose.rotation),
        };
    }

    fn save(self: Subject) Start {
        return switch (self) {
            .space => |value| .{ .transform = value.* },
            .plane => |pose| .{ .pose = pose.* },
        };
    }

    /// Write `change` over the value the drag started from, and say whether
    /// that moved it.
    fn apply(self: Subject, start: Start, change: Change) bool {
        switch (self) {
            .space => |value| {
                var next = start.transform;
                switch (change) {
                    .none => {},
                    .move => |by| next.translation = next.translation.add(by),
                    .turn => |turned| next.rotation = Quat.fromAxisAngle(turned.axis, turned.angle).mul(next.rotation).norm(),
                    .scale => |by| next.scale = next.scale.mul(by),
                }
                defer value.* = next;
                return !value.eql(next);
            },
            .plane => |pose| {
                var next = start.pose;
                switch (change) {
                    .none => {},
                    .move => |by| next.position = next.position.add(by.xy()),
                    .turn => |turned| next.rotation += if (turned.axis.z < 0) -turned.angle else turned.angle,
                    .scale => |by| next.scale = next.scale.mul(by.xy()),
                }
                defer pose.* = next;
                return !pose.eql(next);
            },
        }
    }
};

/// Where a gizmo is and how it is laid out, this frame.
const Rig = struct {
    origin: Vec3,
    /// What the arrows and the rings follow.
    axes: [3]Vec3,
    /// The thing's own, which scaling follows.
    own: [3]Vec3,
    /// World units across `Style.size` pixels, at the origin.
    size: f32,
    toward: Vec3,
    flat: bool,
    layout: Layout,

    fn of(camera: Camera, subject: Subject, options: Options, pixels: f32) ?Rig {
        const origin = subject.origin();
        const units = camera.unitsPerPixel(origin) orelse return null;
        const spin = subject.rotation();
        const own: [3]Vec3 = .{ spin.rotate(.unit_x).norm(), spin.rotate(.unit_y).norm(), spin.rotate(.unit_z).norm() };
        return .{
            .origin = origin,
            .axes = if (options.space == .local) own else .{ .unit_x, .unit_y, .unit_z },
            .own = own,
            .size = units * pixels,
            .toward = camera.toCamera(origin),
            .flat = subject.flat(),
            .layout = .of(options.tool),
        };
    }
};

/// Where each kind of handle sits, in sizes.
const Layout = struct {
    arrow: f32 = 1,
    ring: f32 = 1,
    view_ring: f32 = 1.2,
    cube: f32 = 1,
    cube_line: bool = true,
    plane_from: f32 = 0.25,
    plane_to: f32 = 0.45,

    fn of(tool: Tool) Layout {
        return switch (tool) {
            .move, .rotate, .scale => .{},
            .all => .{ .arrow = 0.72, .view_ring = 1.32, .cube = 1.16, .cube_line = false, .plane_from = 0.2, .plane_to = 0.34 },
        };
    }
};

const shaft_gap = 0.15;
const head_length = 0.2;
const head_radius = 0.065;
const cube_half = 0.055;
const disc_radius = 0.085;
const square_half = 0.075;
/// Below this share of a ring's plane facing the camera, it is turned by
/// dragging along it on the screen.
const edge_on = 0.2;

/// Back to front: what is drawn later is on top, and wins a tie.
const drawing_order = [_]Part{
    .move_yz,     .move_zx,   .move_xy,
    .rotate_view, .rotate_x,  .rotate_y,
    .rotate_z,    .scale_x,   .scale_y,
    .scale_z,     .move_x,    .move_y,
    .move_z,      .scale_all, .move_view,
};

fn uses(part: Part, options: Options, flat: bool) bool {
    const axes = options.axes;
    const moves = options.tool == .move or options.tool == .all;
    const turns = options.tool == .rotate or options.tool == .all;
    const scales = options.tool == .scale or options.tool == .all;
    const every = axes.x and axes.y and (flat or axes.z);
    return switch (part) {
        .move_x => moves and axes.x,
        .move_y => moves and axes.y,
        .move_z => moves and axes.z and !flat,
        .move_yz => moves and !flat and axes.y and axes.z,
        .move_zx => moves and !flat and axes.z and axes.x,
        .move_xy => moves and !flat and axes.x and axes.y,
        .move_view => moves and every,
        .rotate_x => turns and !flat and axes.x,
        .rotate_y => turns and !flat and axes.y,
        .rotate_z => turns and axes.z,
        .rotate_view => turns and !flat and every,
        .scale_x => scales and axes.x,
        .scale_y => scales and axes.y,
        .scale_z => scales and axes.z and !flat,
        .scale_all => options.tool == .scale and every,
        else => false,
    };
}

fn axisOf(part: Part) usize {
    return switch (part) {
        .move_x, .move_yz, .rotate_x, .scale_x => 0,
        .move_y, .move_zx, .rotate_y, .scale_y => 1,
        else => 2,
    };
}

fn manipulate(self: *Gizmo, id: Id, subject: Subject, options: Options) Response {
    const camera = self.ready() orelse return .{};
    var response = self.hoverOf(id, .transform);
    if (self.draggedAs(id, .transform)) |drag| response = self.dragTransform(drag, camera, subject, options) orelse self.abandon();

    const rig = Rig.of(camera, subject, options, self.style.size) orelse return response;
    for (drawing_order) |part| {
        if (uses(part, options, rig.flat)) self.drawPart(.{ .id = id, .part = part }, rig, camera);
    }
    if (self.draggedAs(id, .transform)) |drag| self.drawGuides(drag.*, subject);
    return response;
}

fn dragTransform(self: *Gizmo, drag: *Drag, camera: Camera, subject: Subject, options: Options) ?Response {
    var changed = false;
    if (drag.fresh) {
        drag.start = subject.save();
        drag.rig = Rig.of(camera, subject, options, self.style.size) orelse return null;
        if (!self.grab(drag, camera)) return null;
    } else if (self.frame.?.cancel) {
        drag.change = .none;
        changed = subject.apply(drag.start, .none);
    } else if (self.follow(drag, camera, options.snap)) |change| {
        drag.change = change;
        changed = subject.apply(drag.start, change);
    }
    return self.progress(drag, changed);
}

/// Where the press met the handle, which the drag is measured from.
fn grab(self: *Gizmo, drag: *Drag, camera: Camera) bool {
    const rig = drag.rig;
    const ray = camera.rayThrough(self.press) orelse return false;
    const part = drag.key.part;
    switch (part) {
        .move_x, .move_y, .move_z => {
            drag.axis = rig.axes[axisOf(part)];
            drag.along = geometry.closestAlong(rig.origin, drag.axis, ray) orelse return false;
        },
        .move_yz, .move_zx, .move_xy, .move_view => {
            drag.axis = if (part == .move_view) rig.toward else rig.axes[axisOf(part)];
            drag.grab = geometry.onPlane(ray, rig.origin, drag.axis) orelse return false;
        },
        .rotate_x, .rotate_y, .rotate_z, .rotate_view => {
            drag.axis = if (part == .rotate_view) rig.toward else rig.axes[axisOf(part)];
            return self.grabRing(drag, camera, ray);
        },
        .scale_x, .scale_y, .scale_z => {
            drag.axis = rig.own[axisOf(part)];
            drag.along = geometry.closestAlong(rig.origin, drag.axis, ray) orelse return false;
        },
        .scale_all => {},
        else => return false,
    }
    return true;
}

fn grabRing(self: *Gizmo, drag: *Drag, camera: Camera, ray: Ray) bool {
    const rig = drag.rig;
    if (@abs(drag.axis.dot(rig.toward)) > edge_on) {
        const hit = geometry.onPlane(ray, rig.origin, drag.axis) orelse return false;
        drag.first = hit.sub(rig.origin).reject(drag.axis).tryNorm() orelse return false;
        drag.radial = drag.first;
        return true;
    }
    const ring: Ring = .facing(rig.origin, drag.axis, rig.size * rig.layout.ring, rig.toward);
    const near = ring.nearest(camera, self.press) orelse return false;
    const along = drag.axis.cross(near.point.sub(rig.origin)).tryNorm() orelse return false;
    const from = camera.pixelOf(near.point) orelse return false;
    const to = camera.pixelOf(near.point.add(along.scale(rig.size * 0.1))) orelse return false;
    drag.tangent = to.sub(from).tryNorm() orelse return false;
    drag.first = near.point.sub(rig.origin).tryNorm() orelse return false;
    drag.radial = drag.first;
    drag.edge = true;
    return true;
}

/// What the pointer has done to the value since the press.
fn follow(self: *Gizmo, drag: *Drag, camera: Camera, snap: Snap) ?Change {
    const frame = self.frame.?;
    const rig = drag.rig;
    const ray = camera.rayThrough(frame.pointer) orelse return null;
    switch (drag.key.part) {
        .move_x, .move_y, .move_z => {
            const along = geometry.closestAlong(rig.origin, drag.axis, ray) orelse return null;
            return .{ .move = drag.axis.scale(geometry.stepped(along - drag.along, frame.snap, snap.move)) };
        },
        .move_yz, .move_zx, .move_xy, .move_view => {
            const hit = geometry.onPlane(ray, rig.origin, drag.axis) orelse return null;
            var moved = hit.sub(drag.grab);
            if (rig.flat) moved.z = 0;
            if (frame.snap) moved = steppedAlong(moved, rig.axes, rig.flat, snap.move);
            return .{ .move = moved };
        },
        .rotate_x, .rotate_y, .rotate_z, .rotate_view => {
            self.turn(drag, ray);
            return .{ .turn = .{ .axis = drag.axis, .angle = geometry.stepped(drag.turned, frame.snap, snap.rotate) } };
        },
        .scale_x, .scale_y, .scale_z => {
            const along = geometry.closestAlong(rig.origin, drag.axis, ray) orelse return null;
            const reach = @max(@abs(drag.along), 0.2 * rig.size);
            const factor = geometry.steppedFactor(1 + (along - drag.along) / reach, frame.snap, snap.scale);
            return .{ .scale = if (frame.uniform) uniformly(factor, rig.flat) else alongAxis(factor, axisOf(drag.key.part)) };
        },
        .scale_all => {
            const moved = frame.pointer.sub(self.press);
            const factor = geometry.steppedFactor(@exp2((moved.x - moved.y) / self.style.size), frame.snap, snap.scale);
            return .{ .scale = uniformly(factor, rig.flat) };
        },
        else => return null,
    }
}

/// Add up the turn since the last frame, so that going round twice is two
/// turns and not none.
fn turn(self: *Gizmo, drag: *Drag, ray: Ray) void {
    if (drag.edge) {
        drag.turned = self.pointer().sub(self.press).dot(drag.tangent) / self.style.size;
        return;
    }
    const hit = geometry.onPlane(ray, drag.rig.origin, drag.axis) orelse return;
    const radial = hit.sub(drag.rig.origin).reject(drag.axis).tryNorm() orelse return;
    drag.turned += geometry.signedAngle(drag.radial, radial, drag.axis);
    drag.radial = radial;
}

fn steppedAlong(moved: Vec3, axes: [3]Vec3, flat: bool, step: f32) Vec3 {
    var out: Vec3 = .zero;
    for (axes[0..if (flat) 2 else 3]) |axis| out = out.add(axis.scale(geometry.stepped(moved.dot(axis), true, step)));
    return out;
}

fn uniformly(factor: f32, flat: bool) Vec3 {
    return .init(factor, factor, if (flat) 1 else factor);
}

fn alongAxis(factor: f32, axis: usize) Vec3 {
    var out: [3]f32 = .{ 1, 1, 1 };
    out[axis] = factor;
    return .fromArray(out);
}

fn drawPart(self: *Gizmo, key: Key, rig: Rig, camera: Camera) void {
    switch (key.part) {
        .move_x, .move_y, .move_z => self.drawArrow(key, rig, camera),
        .move_yz, .move_zx, .move_xy => self.drawPlane(key, rig, camera),
        .move_view => self.drawDisc(key, rig, camera),
        .rotate_x, .rotate_y, .rotate_z => self.drawRing(key, rig, camera),
        .rotate_view => self.drawViewRing(key, rig, camera),
        .scale_x, .scale_y, .scale_z => self.drawCube(key, rig, camera),
        .scale_all => self.drawSquare(key, rig, camera),
        else => {},
    }
}

/// Fades an axis out as it turns to point at the camera, where an arrow
/// along it would be a dot nobody could aim at.
fn axisVisibility(self: *const Gizmo, camera: Camera, rig: Rig, axis: Vec3) f32 {
    const from = camera.pixelOf(rig.origin) orelse return 0;
    const to = camera.pixelOf(rig.origin.add(axis.scale(rig.size))) orelse return 0;
    return geometry.smoothstep(0.15, 0.3, from.dist(to) / self.style.size);
}

fn drawArrow(self: *Gizmo, key: Key, rig: Rig, camera: Camera) void {
    const index = axisOf(key.part);
    const axis = rig.axes[index];
    const alpha = self.shown(key, self.axisVisibility(camera, rig, axis)) orelse return;
    const from = rig.origin.add(axis.scale(rig.size * shaft_gap));
    const tip = rig.origin.add(axis.scale(rig.size * rig.layout.arrow));
    const base = tip.sub(axis.scale(rig.size * head_length));

    if (camera.segmentOnScreen(from, tip)) |shaft| {
        var distance = geometry.toSegment(self.pointer(), shaft[0], shaft[1]) - self.style.width / 2;
        if (camera.segmentOnScreen(base, tip)) |head| {
            distance = @min(distance, geometry.toSegment(self.pointer(), head[0], head[1]) - self.style.size * head_radius);
        }
        self.offer(key, .line, distance);
    }
    const color = self.colorOf(key, self.style.axisColor(index), alpha);
    const pen = self.penOf();
    pen.line(from, base, color);
    if (rig.flat) {
        geometry.flatCone(pen, base, tip, rig.size * head_radius, color, rig.toward);
    } else {
        geometry.cone(pen, base, tip, rig.size * head_radius, color, rig.toward);
    }
}

fn drawPlane(self: *Gizmo, key: Key, rig: Rig, camera: Camera) void {
    const index = axisOf(key.part);
    const normal = rig.axes[index];
    const u = rig.axes[(index + 1) % 3];
    const v = rig.axes[(index + 2) % 3];
    const alpha = self.shown(key, geometry.smoothstep(0.15, 0.35, @abs(normal.dot(rig.toward)))) orelse return;
    const near = rig.size * rig.layout.plane_from;
    const far = rig.size * rig.layout.plane_to;
    const corners = [4]Vec3{
        rig.origin.add(u.scale(near)).add(v.scale(near)),
        rig.origin.add(u.scale(far)).add(v.scale(near)),
        rig.origin.add(u.scale(far)).add(v.scale(far)),
        rig.origin.add(u.scale(near)).add(v.scale(far)),
    };
    var pixels: [4]Vec2 = undefined;
    for (corners, &pixels) |corner, *pixel| pixel.* = camera.pixelOf(corner) orelse return;
    self.offer(key, .area, geometry.toPolygon(self.pointer(), &pixels));

    const color = self.colorOf(key, self.style.axisColor(index), alpha);
    const pen = self.penOf();
    pen.solidQuad(corners[0], corners[1], corners[2], corners[3], geometry.faded(color, 0.35));
    pen.with(.{ .width = 1.5 }).polygon(&corners, color);
}

fn drawDisc(self: *Gizmo, key: Key, rig: Rig, camera: Camera) void {
    const middle = camera.pixelOf(rig.origin) orelse return;
    const across = self.style.size * disc_radius;
    self.offer(key, .handle, @max(0, middle.dist(self.pointer()) - across));
    const color = self.colorOf(key, self.style.view, 1);
    const hud = self.penOf().screen();
    hud.with(.{ .width = 2 }).circle2d(middle, across, color);
    hud.with(.{ .segments = 16 }).solidCircle2d(middle, 2.5, color);
}

fn drawRing(self: *Gizmo, key: Key, rig: Rig, camera: Camera) void {
    const index = axisOf(key.part);
    const axis = rig.axes[index];
    const across = rig.size * rig.layout.ring;
    const ring: Ring = if (self.lookOf(key) == .dragged)
        .whole(rig.origin, axis, across)
    else
        .facing(rig.origin, axis, across, rig.toward);
    if (ring.nearest(camera, self.pointer())) |near| self.offer(key, .line, near.distance - self.style.width / 2);
    ring.draw(self.penOf(), self.colorOf(key, self.style.axisColor(index), 1));
}

fn drawViewRing(self: *Gizmo, key: Key, rig: Rig, camera: Camera) void {
    const middle = camera.pixelOf(rig.origin) orelse return;
    const across = self.style.size * rig.layout.view_ring;
    self.offer(key, .line, @abs(middle.dist(self.pointer()) - across) - self.style.width / 2);
    self.penOf().screen().with(.{ .segments = 72 }).circle2d(middle, across, self.colorOf(key, self.style.view, 1));
}

fn drawCube(self: *Gizmo, key: Key, rig: Rig, camera: Camera) void {
    const index = axisOf(key.part);
    const axis = rig.own[index];
    const alpha = self.shown(key, self.axisVisibility(camera, rig, axis)) orelse return;
    const middle = rig.origin.add(axis.scale(rig.size * rig.layout.cube));
    const half = rig.size * cube_half;
    const from = rig.origin.add(axis.scale(rig.size * shaft_gap));
    const pixel = camera.pixelOf(middle) orelse return;

    var distance = @max(0, pixel.dist(self.pointer()) - self.style.size * cube_half * 1.4);
    if (rig.layout.cube_line) {
        if (camera.segmentOnScreen(from, middle)) |line| {
            distance = @min(distance, geometry.toSegment(self.pointer(), line[0], line[1]) - self.style.width / 2);
        }
    }
    self.offer(key, .handle, distance);

    const color = self.colorOf(key, self.style.axisColor(index), alpha);
    const pen = self.penOf();
    if (rig.layout.cube_line) pen.line(from, middle.sub(axis.scale(half)), color);
    if (rig.flat) {
        geometry.flatSquare(pen, middle, rig.own, half, color);
    } else {
        geometry.cube(pen, middle, rig.own, half, color, rig.toward);
    }
}

fn drawSquare(self: *Gizmo, key: Key, rig: Rig, camera: Camera) void {
    const middle = camera.pixelOf(rig.origin) orelse return;
    const half = self.style.size * square_half;
    const off = self.pointer().sub(middle).abs();
    self.offer(key, .handle, @max(0, @max(off.x, off.y) - half));
    const color = self.colorOf(key, self.style.view, 1);
    const corner = middle.sub(.splat(half));
    const hud = self.penOf().screen();
    hud.solidRect2d(corner, .splat(2 * half), geometry.faded(color, 0.35));
    hud.with(.{ .width = 2 }).rect2d(corner, .splat(2 * half), color);
}

/// While a part is dragged: the line it moves along, or the turn it has
/// made, and what the drag has done so far beside the pointer.
fn drawGuides(self: *Gizmo, drag: Drag, subject: Subject) void {
    const rig = drag.rig;
    switch (drag.key.part) {
        .move_x, .move_y, .move_z, .scale_x, .scale_y, .scale_z => {
            const reach = drag.axis.scale(rig.size * 60);
            const color = geometry.faded(self.style.axisColor(axisOf(drag.key.part)), 0.6);
            self.penOf().with(.{ .width = 1 }).line(rig.origin.sub(reach), rig.origin.add(reach), color);
        },
        .rotate_x, .rotate_y, .rotate_z, .rotate_view => self.drawSweep(drag),
        else => {},
    }
    if (self.style.readout) self.drawReadout(drag.change, subject.flat());
}

fn drawSweep(self: *Gizmo, drag: Drag) void {
    const angle = switch (drag.change) {
        .turn => |turned| std.math.clamp(turned.angle, -std.math.tau, std.math.tau),
        else => 0,
    };
    const rig = drag.rig;
    const across = rig.size * if (drag.key.part == .rotate_view) rig.layout.view_ring else rig.layout.ring;
    const pen = self.penOf();
    const edge = pen.with(.{ .width = 1.5 });
    const fill = geometry.faded(self.style.hot, 0.25);
    const pieces: usize = @intFromFloat(@max(1, @ceil(@abs(angle) / (std.math.tau / 64.0))));

    var previous = rig.origin.add(drag.first.scale(across));
    edge.line(rig.origin, previous, self.style.hot);
    for (1..pieces + 1) |i| {
        const part = angle * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pieces));
        const next = rig.origin.add(Quat.fromAxisAngle(drag.axis, part).rotate(drag.first).scale(across));
        pen.solidTriangle(rig.origin, previous, next, fill);
        previous = next;
    }
    edge.line(rig.origin, previous, self.style.hot);
}

fn drawReadout(self: *Gizmo, change: Change, flat: bool) void {
    const at = self.pointer().add(.init(18, 10));
    const hud = self.penOf().screen();
    const color = self.style.text;
    switch (change) {
        .none => {},
        .move => |by| if (flat)
            hud.print2d(at, "{d:.2}, {d:.2}", .{ by.x, by.y }, color)
        else
            hud.print2d(at, "{d:.2}, {d:.2}, {d:.2}", .{ by.x, by.y, by.z }, color),
        .turn => |turned| hud.print2d(at, "{d:.1} deg", .{math.degrees(if (turned.axis.z < 0 and flat) -turned.angle else turned.angle)}, color),
        .scale => |by| if (flat)
            hud.print2d(at, "x {d:.2}  y {d:.2}", .{ by.x, by.y }, color)
        else
            hud.print2d(at, "x {d:.2}  y {d:.2}  z {d:.2}", .{ by.x, by.y, by.z }, color),
    }
}

// -------------------------------------------------------------------------
// A box's sides and corners
// -------------------------------------------------------------------------

/// A box round a pose on a plane: a side or a corner resizes it with the
/// opposite side held still, inside moves it, and just outside a corner
/// turns it about the pose's position.
pub fn bounds2d(self: *Gizmo, id: Id, pose: *Pose2D, rect: Rect, options: BoundsOptions) Response {
    const camera = self.ready() orelse return .{};
    var response = self.hoverOf(id, .bounds);
    if (self.draggedAs(id, .bounds)) |drag| response = self.dragBounds(drag, camera, pose, rect, options.snap) orelse self.abandon();

    var corners: [4]Vec3 = undefined;
    var pixels: [4]Vec2 = undefined;
    for (box_corners, &corners, &pixels) |part, *corner, *pixel| {
        corner.* = pose.apply(cornerOf(rect, part)).vec3(0);
        pixel.* = camera.pixelOf(corner.*) orelse return response;
    }
    self.hoverBox(id, pixels, options);
    self.drawBox(id, pose.*, corners, pixels, camera);
    if (self.draggedAs(id, .bounds)) |drag| {
        if (self.style.readout) self.drawBoxReadout(drag.*, pose.*, rect);
    }
    return response;
}

/// Round the box, each side running from its corner to the next.
const box_corners = [4]Part{ .top_left, .top_right, .bottom_right, .bottom_left };
const box_sides = [4]Part{ .top, .right, .bottom, .left };

/// Which way along `x` and along `y` a part pulls the box: towards its low
/// side, its high side, or neither.
fn pullOf(part: Part) [2]f32 {
    return switch (part) {
        .left => .{ -1, 0 },
        .right => .{ 1, 0 },
        .top => .{ 0, -1 },
        .bottom => .{ 0, 1 },
        .top_left => .{ -1, -1 },
        .top_right => .{ 1, -1 },
        .bottom_right => .{ 1, 1 },
        .bottom_left => .{ -1, 1 },
        else => .{ 0, 0 },
    };
}

fn cornerOf(rect: Rect, part: Part) Vec2 {
    const pull = pullOf(part);
    return .init(if (pull[0] < 0) rect.min.x else rect.max.x, if (pull[1] < 0) rect.min.y else rect.max.y);
}

const corner_half = 5;
const side_half = 4;
/// Pixels beyond a corner's square that still turn the box.
const turn_zone = 18;

fn hoverBox(self: *Gizmo, id: Id, pixels: [4]Vec2, options: BoundsOptions) void {
    const at = self.pointer();
    const outside = geometry.toPolygon(at, &pixels) > 0;
    if (options.move and !outside) self.offer(.{ .id = id, .part = .inside }, .area, 0);
    for (box_sides, 0..) |side, k| {
        const from = pixels[k];
        const to = pixels[(k + 1) % 4];
        const key: Key = .{ .id = id, .part = side };
        self.offer(key, .line, geometry.toSegment(at, from, to) - 1);
        self.offer(key, .handle, @max(0, at.dist(from.lerp(to, 0.5)) - side_half));
    }
    for (box_corners, pixels) |corner, pixel| {
        const distance = at.dist(pixel);
        self.offer(.{ .id = id, .part = corner }, .handle, @max(0, distance - corner_half));
        if (options.rotate and outside and distance < corner_half + turn_zone) self.offer(.{ .id = id, .part = .around }, .zone, 0);
    }
}

fn drawBox(self: *Gizmo, id: Id, pose: Pose2D, corners: [4]Vec3, pixels: [4]Vec2, camera: Camera) void {
    const pen = self.penOf();
    const hud = pen.screen();
    const inside = self.lookOf(.{ .id = id, .part = .inside });
    if (inside == .hot or inside == .dragged) {
        pen.solidQuad(corners[0], corners[1], corners[2], corners[3], geometry.faded(self.style.hot, 0.12));
    }
    for (box_sides, 0..) |side, k| {
        const color = self.colorOf(.{ .id = id, .part = side }, self.style.handle, 0.9);
        pen.with(.{ .width = 1.5 }).line(corners[k], corners[(k + 1) % 4], color);
        square(hud, pixels[k].lerp(pixels[(k + 1) % 4], 0.5), side_half, color);
    }
    for (box_corners, pixels) |corner, pixel| {
        square(hud, pixel, corner_half, self.colorOf(.{ .id = id, .part = corner }, self.style.handle, 1));
    }
    if (camera.pixelOf(pose.position.vec3(0))) |pivot| hud.with(.{ .width = 1.5, .segments = 16 }).circle2d(pivot, 4, self.style.handle);

    const around = self.lookOf(.{ .id = id, .part = .around });
    if (around == .hot or around == .dragged) {
        const middle = pixels[0].lerp(pixels[2], 0.5);
        var nearest = pixels[0];
        for (pixels[1..]) |pixel| {
            if (pixel.dist(self.pointer()) < nearest.dist(self.pointer())) nearest = pixel;
        }
        const out = nearest.sub(middle).angle();
        hud.with(.{ .width = 2 }).arc2d(nearest, corner_half + 9, out - 1.1, out + 1.1, self.style.hot);
    }
}

fn square(hud: Pen, middle: Vec2, half: f32, color: Color) void {
    const corner = middle.sub(.splat(half));
    hud.solidRect2d(corner, .splat(2 * half), color);
    hud.with(.{ .width = 1 }).rect2d(corner, .splat(2 * half), Color.black.withAlpha(0.6));
}

fn drawBoxReadout(self: *Gizmo, drag: Drag, pose: Pose2D, rect: Rect) void {
    const at = self.pointer().add(.init(18, 10));
    const hud = self.penOf().screen();
    const color = self.style.text;
    switch (drag.key.part) {
        .inside, .around => self.drawReadout(drag.change, true),
        else => {
            const size = rect.max.sub(rect.min).mul(pose.scale).abs();
            hud.print2d(at, "{d:.1} x {d:.1}", .{ size.x, size.y }, color);
        },
    }
}

fn dragBounds(self: *Gizmo, drag: *Drag, camera: Camera, pose: *Pose2D, rect: Rect, snap: Snap) ?Response {
    const frame = self.frame.?;
    var next = pose.*;
    if (drag.fresh) {
        drag.start = .{ .pose = pose.* };
        drag.rect = rect;
        const ray = camera.rayThrough(self.press) orelse return null;
        drag.grab = geometry.onPlane(ray, .zero, .unit_z) orelse return null;
        drag.first = drag.grab.sub(pose.position.vec3(0)).tryNorm() orelse .unit_x;
        drag.radial = drag.first;
    } else if (frame.cancel) {
        next = drag.start.pose;
        drag.change = .none;
    } else if (camera.rayThrough(frame.pointer)) |ray| {
        if (geometry.onPlane(ray, .zero, .unit_z)) |hit| next = self.reshape(drag, hit, snap);
    }
    const changed = !pose.eql(next);
    pose.* = next;
    return self.progress(drag, changed);
}

fn reshape(self: *Gizmo, drag: *Drag, hit: Vec3, snap: Snap) Pose2D {
    const frame = self.frame.?;
    const start = drag.start.pose;
    var next = start;
    switch (drag.key.part) {
        .inside => {
            var moved = hit.sub(drag.grab).xy();
            if (frame.snap) moved = .init(geometry.stepped(moved.x, true, snap.move), geometry.stepped(moved.y, true, snap.move));
            drag.change = .{ .move = moved.vec3(0) };
            next.position = start.position.add(moved);
        },
        .around => {
            if (hit.sub(start.position.vec3(0)).tryNorm()) |radial| {
                drag.turned += geometry.signedAngle(drag.radial, radial, .unit_z);
                drag.radial = radial;
            }
            const angle = geometry.stepped(drag.turned, frame.snap, snap.rotate);
            drag.change = .{ .turn = .{ .axis = .unit_z, .angle = angle } };
            next.rotation = start.rotation + angle;
        },
        else => next = resized(start, drag.rect, pullOf(drag.key.part), hit.sub(drag.grab).xy(), .{
            .snap = frame.snap,
            .uniform = frame.uniform,
            .centered = frame.centered,
            .step = snap.move,
        }),
    }
    return next;
}

const Resize = struct {
    snap: bool = false,
    uniform: bool = false,
    centered: bool = false,
    step: f32 = 1,
};

/// `start`'s box with its pulled sides moved by `moved`, in world units, and
/// the sides opposite them - or the middle - held where they were.
fn resized(start: Pose2D, rect: Rect, pull: [2]f32, moved: Vec2, how: Resize) Pose2D {
    const along = moved.rotate(-start.rotation).array();
    const low = rect.min.array();
    const high = rect.max.array();
    const middle = rect.center().array();
    const first = start.scale.array();
    var scale = first;
    var anchor = middle;
    for (0..2) |k| {
        if (pull[k] == 0) continue;
        const side = if (pull[k] > 0) high[k] else low[k];
        const held = if (how.centered) middle[k] else if (pull[k] > 0) low[k] else high[k];
        anchor[k] = held;
        const span = side - held;
        if (span == 0) continue;
        scale[k] = geometry.stepped(span * first[k] + along[k], how.snap, how.step) / span;
    }
    if (how.uniform) {
        const factor = leading(first, scale, pull);
        scale = .{ first[0] * factor, first[1] * factor };
    }
    const next: Vec2 = .fromArray(scale);
    const pinned = start.apply(.fromArray(anchor));
    return .{
        .position = pinned.sub(Vec2.fromArray(anchor).mul(next).rotate(start.rotation)),
        .rotation = start.rotation,
        .scale = next,
    };
}

/// The factor of whichever pulled axis changed most.
fn leading(first: [2]f32, scale: [2]f32, pull: [2]f32) f32 {
    var best: f32 = 1;
    for (0..2) |k| {
        if (pull[k] == 0 or first[k] == 0) continue;
        const factor = scale[k] / first[k];
        if (@abs(factor - 1) > @abs(best - 1)) best = factor;
    }
    return best;
}

// -------------------------------------------------------------------------
// Handles to make tools from
// -------------------------------------------------------------------------

/// A dot that drags a point across a plane: `options.normal`'s, or else the
/// one facing the camera.
pub fn point(self: *Gizmo, id: Id, at: *Vec3, options: HandleOptions) Response {
    const camera = self.ready() orelse return .{};
    var response = self.hoverOf(id, .point);
    if (self.draggedAs(id, .point)) |drag| response = self.dragPoint(drag, camera, at, options) orelse self.abandon();
    self.drawDot(.{ .id = id, .part = .point }, at.*, camera, options);
    return response;
}

/// A dot that drags a point about a plane.
pub fn point2d(self: *Gizmo, id: Id, at: *Vec2, options: HandleOptions) Response {
    var deep = at.vec3(0);
    var flat = options;
    flat.normal = .unit_z;
    defer at.* = deep.xy();
    return self.point(id, &deep, flat);
}

/// A dot that drags a point along a line through it.
pub fn slider(self: *Gizmo, id: Id, at: *Vec3, direction: Vec3, options: HandleOptions) Response {
    const camera = self.ready() orelse return .{};
    const axis = direction.tryNorm() orelse return .{};
    const key: Key = .{ .id = id, .part = .slider };
    var response = self.hoverOf(id, .slider);
    if (self.draggedAs(id, .slider)) |drag| response = self.dragSlider(drag, camera, at, axis, options) orelse self.abandon();

    const look = self.lookOf(key);
    if (look == .hot or look == .dragged) {
        if (camera.unitsPerPixel(at.*)) |units| {
            const reach = axis.scale(units * self.style.size);
            self.penOf().with(.{ .width = 1 }).line(at.sub(reach), at.add(reach), geometry.faded(self.style.hot, 0.6));
        }
    }
    self.drawDot(key, at.*, camera, options);
    return response;
}

/// A ring about `center` that drags its radius.
pub fn radius(self: *Gizmo, id: Id, value: *f32, center: Vec3, normal: Vec3, options: HandleOptions) Response {
    const camera = self.ready() orelse return .{};
    const axis = normal.tryNorm() orelse return .{};
    const key: Key = .{ .id = id, .part = .radius };
    var response = self.hoverOf(id, .radius);
    if (self.draggedAs(id, .radius)) |drag| response = self.dragRadius(drag, camera, value, center, axis, options) orelse self.abandon();

    const ring: Ring = .whole(center, axis, value.*);
    if (ring.nearest(camera, self.pointer())) |near| self.offer(key, .line, near.distance - self.style.width / 2);
    ring.draw(self.penOf().with(.{ .width = 2 }), self.colorOf(key, options.color orelse self.style.handle, 1));
    return response;
}

pub fn radius2d(self: *Gizmo, id: Id, value: *f32, center: Vec2, options: HandleOptions) Response {
    return self.radius(id, value, center.vec3(0), .unit_z, options);
}

fn dragPoint(self: *Gizmo, drag: *Drag, camera: Camera, at: *Vec3, options: HandleOptions) ?Response {
    const frame = self.frame.?;
    var next = at.*;
    if (drag.fresh) {
        drag.start = .{ .point = at.* };
        drag.axis = if (options.normal) |normal| normal.tryNorm() orelse return null else camera.toCamera(at.*);
        const ray = camera.rayThrough(self.press) orelse return null;
        drag.grab = geometry.onPlane(ray, at.*, drag.axis) orelse return null;
    } else if (frame.cancel) {
        next = drag.start.point;
    } else if (camera.rayThrough(frame.pointer)) |ray| {
        if (geometry.onPlane(ray, drag.start.point, drag.axis)) |hit| {
            next = drag.start.point.add(steppedEach(hit.sub(drag.grab), frame.snap, options.snap));
        }
    }
    const changed = !at.eql(next);
    at.* = next;
    return self.progress(drag, changed);
}

fn dragSlider(self: *Gizmo, drag: *Drag, camera: Camera, at: *Vec3, axis: Vec3, options: HandleOptions) ?Response {
    const frame = self.frame.?;
    var next = at.*;
    if (drag.fresh) {
        drag.start = .{ .point = at.* };
        drag.axis = axis;
        const ray = camera.rayThrough(self.press) orelse return null;
        drag.along = geometry.closestAlong(at.*, axis, ray) orelse return null;
    } else if (frame.cancel) {
        next = drag.start.point;
    } else if (camera.rayThrough(frame.pointer)) |ray| {
        if (geometry.closestAlong(drag.start.point, drag.axis, ray)) |along| {
            next = drag.start.point.add(drag.axis.scale(geometry.stepped(along - drag.along, frame.snap, options.snap)));
        }
    }
    const changed = !at.eql(next);
    at.* = next;
    return self.progress(drag, changed);
}

fn dragRadius(self: *Gizmo, drag: *Drag, camera: Camera, value: *f32, center: Vec3, axis: Vec3, options: HandleOptions) ?Response {
    const frame = self.frame.?;
    var next = value.*;
    if (drag.fresh) {
        drag.start = .{ .number = value.* };
        const ray = camera.rayThrough(self.press) orelse return null;
        drag.edge = @abs(axis.dot(camera.toCamera(center))) <= edge_on;
        if (drag.edge) {
            const near = Ring.whole(center, axis, value.*).nearest(camera, self.press) orelse return null;
            drag.first = near.point.sub(center).tryNorm() orelse return null;
            drag.along = geometry.closestAlong(center, drag.first, ray) orelse return null;
        } else {
            drag.along = (geometry.onPlane(ray, center, axis) orelse return null).dist(center);
        }
    } else if (frame.cancel) {
        next = drag.start.number;
    } else if (camera.rayThrough(frame.pointer)) |ray| {
        const out: ?f32 = if (drag.edge)
            geometry.closestAlong(center, drag.first, ray)
        else if (geometry.onPlane(ray, center, axis)) |hit| hit.dist(center) else null;
        if (out) |reach| next = @max(0, drag.start.number + geometry.stepped(reach - drag.along, frame.snap, options.snap));
    }
    const changed = next != value.*;
    value.* = next;
    return self.progress(drag, changed);
}

fn steppedEach(moved: Vec3, snap: bool, step: f32) Vec3 {
    return .init(geometry.stepped(moved.x, snap, step), geometry.stepped(moved.y, snap, step), geometry.stepped(moved.z, snap, step));
}

fn drawDot(self: *Gizmo, key: Key, at: Vec3, camera: Camera, options: HandleOptions) void {
    const pixel = camera.pixelOf(at) orelse return;
    const across = options.size / 2;
    self.offer(key, .handle, @max(0, pixel.dist(self.pointer()) - across));
    const hud = self.penOf().screen().with(.{ .segments = 20 });
    hud.solidCircle2d(pixel, across, self.colorOf(key, options.color orelse self.style.handle, 1));
    hud.with(.{ .width = 1.5 }).circle2d(pixel, across, Color.black.withAlpha(0.6));
}
