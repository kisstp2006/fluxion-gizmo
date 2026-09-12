// SPDX-License-Identifier: BSD-2-Clause

//! Crates in space and cards on a plane, moved, turned and scaled with the
//! gizmos, and a lamp, a ring and a fence edited with handles.
//!
//! ```bash
//! zig build example
//! zig build example -- --backend gl
//! zig build example -- --capture plane.png --scene plane --tool box --pointer 700,300
//! ```

const std = @import("std");
const Io = std.Io;

const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const image = @import("fluxion_image");
const platform = @import("fluxion_platform");
const debugdraw = @import("fluxion_debugdraw");
const render = @import("fluxion_debugdraw_rhi");
const gizmos = @import("fluxion_gizmo");

const windowing = @import("window.zig");
const Window = windowing.Window;
const Input = windowing.Input;

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Transform = math.Transform;
const Color = debugdraw.Color;
const Canvas = debugdraw.Canvas;
const Pen = debugdraw.Pen;
const Gizmo = gizmos.Gizmo;
const Camera = gizmos.Camera;
const Pose2D = gizmos.Pose2D;

const background: [4]f32 = .{ 0.07, 0.075, 0.09, 1 };

const Scene = enum { space, plane };
const Tool = enum { move, rotate, scale, all, box };

const space_snap: gizmos.Snap = .{ .move = 0.25, .scale = 0.25 };
const plane_snap: gizmos.Snap = .{ .move = 16, .scale = 0.25 };

const Crate = struct {
    name: []const u8,
    transform: Transform,
    half: Vec3,
    color: Color,

    fn bounds(self: Crate) math.Aabb {
        return .init(self.half.neg(), self.half);
    }
};

const Card = struct {
    name: []const u8,
    pose: Pose2D,
    size: Vec2,
    pivot: Vec2 = .splat(0.5),
    color: Color,

    fn rect(self: Card) gizmos.Rect {
        return .sized(self.size, self.pivot);
    }
};

const Demo = struct {
    scene: Scene = .space,
    tool: Tool = .move,
    space: gizmos.Space = .world,
    gizmo: Gizmo = .{},

    crates: [3]Crate = .{
        .{ .name = "crate", .transform = .fromTranslation(.init(-2.2, 0.5, 0.3)), .half = .splat(0.5), .color = .orange },
        .{ .name = "pillar", .transform = .init(.init(0.3, 0.9, -1.4), .fromAxisAngle(.unit_y, 0.6), .one), .half = .init(0.35, 0.9, 0.35), .color = .cyan },
        .{ .name = "slab", .transform = .init(.init(2.3, 0.2, 1.1), .fromAxisAngle(.unit_y, -0.3), .one), .half = .init(0.9, 0.2, 0.6), .color = .magenta },
    },
    lamp: Vec3 = .init(-2.8, 2.4, -2.8),
    reach: f32 = 1,
    crate_picked: ?usize = 0,
    yaw: f32 = 0.55,
    pitch: f32 = 0.42,
    distance: f32 = 9,

    cards: [3]Card = .{
        .{ .name = "hero", .pose = .{ .position = .init(-150, 20) }, .size = .init(64, 96), .pivot = .init(0.5, 1), .color = .orange },
        .{ .name = "crate", .pose = .{ .position = .init(40, -20), .rotation = 0.35 }, .size = .init(80, 80), .color = .cyan },
        .{ .name = "platform", .pose = .{ .position = .init(190, 120) }, .size = .init(220, 28), .color = .green },
    },
    ring: Vec2 = .init(230, -110),
    ring_radius: f32 = 48,
    fence: [5]Vec2 = .{ .init(-330, 150), .init(-220, 190), .init(-120, 150), .init(-150, 70), .init(-290, 80) },
    card_picked: ?usize = 1,
    look: Vec2 = .zero,
    zoom: f32 = 1.4,

    last: gizmos.Response = .{},
    was_left: bool = false,
    pressed_at: ?Vec2 = null,
    show_pointer: bool = false,
    quit: bool = false,

    /// One frame: the keys, the view, the gizmos, then the scene they moved,
    /// and what the renderer should look through. The gizmos draw on
    /// `overlay`, a canvas drawn after `scene`'s, so nothing covers them.
    fn frame(self: *Demo, scene: Pen, overlay: Pen, input: Input, width: f32, height: f32, clip: math.Clip) Mat4 {
        if (input.pressed(.escape) and !self.gizmo.isDragging()) self.quit = true;
        self.obey(input);
        self.steer(input, width, height);

        const view_projection = self.viewProjection(width, height, clip);
        const camera = Camera.init(view_projection, clip, width, height) orelse return view_projection;
        self.gizmo.begin(.{
            .pen = overlay,
            .view_projection = view_projection,
            .clip = clip,
            .width = width,
            .height = height,
            .pointer = input.pointer,
            .down = input.left,
            .snap = input.ctrl,
            .uniform = input.shift,
            .centered = input.alt,
            .cancel = input.right_pressed or input.pressed(.escape),
        });
        switch (self.scene) {
            .space => self.editSpace(camera),
            .plane => self.editPlane(),
        }
        self.gizmo.end();
        self.pick(input, camera);

        switch (self.scene) {
            .space => self.drawSpace(scene),
            .plane => self.drawPlane(scene),
        }
        self.drawHud(overlay, input);
        return view_projection;
    }

    fn obey(self: *Demo, input: Input) void {
        const tools = [_]struct { Tool, platform.Key, platform.Key }{
            .{ .move, .@"1", .w },
            .{ .rotate, .@"2", .e },
            .{ .scale, .@"3", .r },
            .{ .all, .@"4", .t },
            .{ .box, .@"5", .y },
        };
        for (tools) |choice| {
            if (input.pressed(choice[1]) or input.pressed(choice[2])) self.tool = choice[0];
        }
        if (input.pressed(.tab)) self.scene = if (self.scene == .space) .plane else .space;
        if (input.pressed(.l)) self.space = if (self.space == .world) .local else .world;
    }

    fn steer(self: *Demo, input: Input, width: f32, height: f32) void {
        const turning = input.right or input.middle;
        switch (self.scene) {
            .space => {
                if (turning) {
                    self.yaw -= input.moved.x * 0.008;
                    self.pitch = std.math.clamp(self.pitch + input.moved.y * 0.008, -1.4, 1.4);
                }
                self.distance = std.math.clamp(self.distance * std.math.pow(f32, 0.9, input.wheel), 2, 40);
            },
            .plane => {
                if (turning) self.look = self.look.sub(input.moved.scale(1 / self.zoom));
                if (input.wheel != 0) {
                    const middle: Vec2 = .init(width / 2, height / 2);
                    const before = self.look.add(input.pointer.sub(middle).scale(1 / self.zoom));
                    self.zoom = std.math.clamp(self.zoom * std.math.pow(f32, 1.15, input.wheel), 0.25, 8);
                    const after = self.look.add(input.pointer.sub(middle).scale(1 / self.zoom));
                    self.look = self.look.add(before.sub(after));
                }
            },
        }
    }

    fn viewProjection(self: *const Demo, width: f32, height: f32, clip: math.Clip) Mat4 {
        switch (self.scene) {
            .space => {
                const target: Vec3 = .init(0, 0.6, 0);
                const around: Vec3 = .init(@cos(self.pitch) * @sin(self.yaw), @sin(self.pitch), @cos(self.pitch) * @cos(self.yaw));
                const projection = math.perspective(.{ .fov_y = math.radians(50), .aspect = width / height, .near = 0.1, .far = 200, .clip = clip });
                return projection.mul(math.lookAt(target.add(around.scale(self.distance)), target, .unit_y, .right));
            },
            .plane => {
                const half_width = width / (2 * self.zoom);
                const half_height = height / (2 * self.zoom);
                const projection = math.orthographic(.{
                    .left = -half_width,
                    .right = half_width,
                    .bottom = half_height,
                    .top = -half_height,
                    .near = -1,
                    .far = 1,
                    .clip = clip,
                });
                return projection.mul(.fromTranslation(.init(-self.look.x, -self.look.y, 0)));
            },
        }
    }

    fn options(self: *const Demo, snap: gizmos.Snap) gizmos.Options {
        return .{
            .tool = switch (self.tool) {
                .move => .move,
                .rotate => .rotate,
                .scale => .scale,
                .all, .box => .all,
            },
            .space = self.space,
            .snap = snap,
        };
    }

    fn editSpace(self: *Demo, camera: Camera) void {
        _ = self.gizmo.radius(.of("lamp reach"), &self.reach, self.lamp, camera.toCamera(self.lamp), .{ .color = Color.yellow.withAlpha(0.8), .snap = 0.25 });
        _ = self.gizmo.slider(.of("lamp height"), &self.lamp, .unit_y, .{ .color = .yellow, .snap = 0.25 });
        if (self.crate_picked) |i| {
            self.last = self.gizmo.transform(.of(.{ "crate", @as(u32, @intCast(i)) }), &self.crates[i].transform, self.options(space_snap));
        }
    }

    fn editPlane(self: *Demo) void {
        for (&self.fence, 0..) |*corner, i| {
            _ = self.gizmo.point2d(.of(.{ "fence", @as(u32, @intCast(i)) }), corner, .{ .color = .yellow, .snap = 16 });
        }
        _ = self.gizmo.radius2d(.of("ring"), &self.ring_radius, self.ring, .{ .color = .cyan, .snap = 8 });
        _ = self.gizmo.point2d(.of("ring middle"), &self.ring, .{ .color = .cyan, .snap = 16 });
        if (self.card_picked) |i| {
            const card = &self.cards[i];
            const id: gizmos.Id = .of(.{ "card", @as(u32, @intCast(i)) });
            self.last = if (self.tool == .box)
                self.gizmo.bounds2d(id, &card.pose, card.rect(), .{ .snap = plane_snap })
            else
                self.gizmo.transform2d(id, &card.pose, self.options(plane_snap));
        }
    }

    fn drawSpace(self: *const Demo, pen: Pen) void {
        pen.grid(.zero, .init(1, 0, 0), .init(0, 0, 1), 8, Color.gray.withAlpha(0.3));
        for (&self.crates, 0..) |*crate, i| {
            const picked = self.crate_picked == i;
            const inside = pen.within(crate.transform.toMat4());
            inside.solidBox(crate.bounds(), crate.color.withAlpha(0.2));
            inside.with(.{ .width = if (picked) 2.5 else 1.5 }).box(crate.bounds(), if (picked) .white else crate.color);
            const top = crate.transform.apply(.init(0, crate.half.y, 0));
            pen.with(.{ .anchor = .bottom }).text(top.add(.init(0, 0.2, 0)), crate.name, crate.color);
        }
        pen.sphere(self.lamp, 0.12, .yellow);
        pen.with(.{ .width = 1 }).line(self.lamp, .init(self.lamp.x, 0, self.lamp.z), Color.yellow.withAlpha(0.35));
    }

    fn drawPlane(self: *const Demo, pen: Pen) void {
        pen.grid2d(.zero, 32, 16, Color.gray.withAlpha(0.22));
        pen.cross2d(.zero, 14, Color.gray.withAlpha(0.6));
        for (&self.cards, 0..) |*card, i| {
            const picked = self.card_picked == i;
            const inside = pen.within(card.pose.matrix());
            const rect = card.rect();
            inside.solidRect2d(rect.min, card.size, card.color.withAlpha(0.7));
            inside.with(.{ .width = if (picked) 2 else 1 }).rect2d(rect.min, card.size, if (picked) .white else card.color);
            pen.with(.{ .anchor = .center }).text2d(card.pose.apply(rect.center()), card.name, .black);
        }
        pen.with(.{ .width = 2 }).polygon2d(&self.fence, Color.yellow.withAlpha(0.7));
    }

    /// A click - pressed and let go where no handle is, without moving -
    /// picks what is under it, or nothing.
    fn pick(self: *Demo, input: Input, camera: Camera) void {
        const pressed = input.left and !self.was_left;
        const released = !input.left and self.was_left;
        self.was_left = input.left;
        if (pressed) self.pressed_at = if (self.gizmo.wantsPointer()) null else input.pointer;
        if (!released) return;
        const at = self.pressed_at orelse return;
        self.pressed_at = null;
        if (at.dist(input.pointer) > 4) return;
        const ray = camera.rayThrough(input.pointer) orelse return;
        switch (self.scene) {
            .space => self.crate_picked = crateUnder(&self.crates, ray),
            .plane => self.card_picked = cardUnder(&self.cards, ray),
        }
    }

    fn drawHud(self: *const Demo, pen: Pen, input: Input) void {
        const hud = pen.screen();
        hud.solidRect2d(.init(12, 12), .init(392, 118), Color.black.withAlpha(0.62));
        hud.with(.{ .text_scale = 2 }).text2d(.init(22, 20), "fluxion-gizmo", .white);
        hud.print2d(.init(250, 26), "{t} / {t}", .{ self.scene, self.space }, .gray);

        var x: f32 = 22;
        for (std.enums.values(Tool), 1..) |tool, number| {
            const chosen = tool == self.tool;
            hud.print2d(.init(x, 48), "[{d}] {t}", .{ number, tool }, if (chosen) Color.yellow else Color.gray);
            x += @as(f32, @floatFromInt(6 * (5 + @tagName(tool).len)));
        }
        hud.text2d(.init(22, 66), "left: pick and drag    right: turn the view    wheel: zoom", .gray);
        hud.text2d(.init(22, 80), "hold ctrl: snap   shift: uniform   alt: from the middle", .gray);
        hud.text2d(.init(22, 94), "[tab] space / plane   [L] world / local   [esc] cancel", .gray);
        const part = if (self.last.part) |part| @tagName(part) else "";
        hud.print2d(.init(22, 112), "{t} {s}", .{ self.last.phase, part }, .white);
        if (self.show_pointer) drawPointer(hud, input.pointer);
    }
};

fn crateUnder(crates: []const Crate, ray: math.Ray) ?usize {
    var best: ?usize = null;
    var nearest = std.math.inf(f32);
    for (crates, 0..) |crate, i| {
        const inverse = crate.transform.toMat4().inverse() orelse continue;
        const local: math.Ray = .{ .origin = inverse.mulPoint(ray.origin), .direction = inverse.mulDir(ray.direction) };
        const t = local.intersectAabb(crate.bounds()) orelse continue;
        if (t < nearest) {
            nearest = t;
            best = i;
        }
    }
    return best;
}

fn cardUnder(cards: []const Card, ray: math.Ray) ?usize {
    const t = ray.intersectPlane(.fromPointNormal(.zero, .unit_z)) orelse return null;
    const at = ray.at(t).xy();
    var i = cards.len;
    while (i > 0) {
        i -= 1;
        const local = cards[i].pose.applyInverse(at);
        const rect = cards[i].rect();
        if (local.x >= rect.min.x and local.x <= rect.max.x and local.y >= rect.min.y and local.y <= rect.max.y) return i;
    }
    return null;
}

fn drawPointer(hud: Pen, at: Vec2) void {
    const outline = [_]Vec2{
        at,                        at.add(.init(0, 16)),      at.add(.init(4, 12.3)),
        at.add(.init(7.5, 19)),    at.add(.init(10.5, 17.5)), at.add(.init(7, 11.2)),
        at.add(.init(11.3, 11.3)),
    };
    hud.solidPolygon2d(&.{ outline[0], outline[1], outline[6] }, .white);
    hud.solidPolygon2d(&.{ outline[2], outline[3], outline[4], outline[5] }, .white);
    hud.with(.{ .width = 1 }).polygon2d(&outline, .black);
}

/// The demo as it is after hovering `pointer` - and with `drag`, after
/// pressing there and dragging to it - drawn into a texture.
/// The scene, and the gizmos drawn over it.
const Canvases = struct {
    scene: Canvas,
    overlay: Canvas,

    fn init(gpa: std.mem.Allocator) Canvases {
        return .{ .scene = .init(gpa), .overlay = .init(gpa) };
    }

    fn deinit(self: *Canvases) void {
        self.scene.deinit();
        self.overlay.deinit();
    }

    fn frame(self: *Canvases, demo: *Demo, input: Input, width: f32, height: f32, clip: math.Clip) Mat4 {
        self.scene.advance(0);
        self.overlay.advance(0);
        return demo.frame(self.scene.pen(), self.overlay.pen(), input, width, height, clip);
    }

    fn all(self: *const Canvases) [2]*const Canvas {
        return .{ &self.scene, &self.overlay };
    }
};

/// The demo as it is after hovering `pointer` - and with `drag`, after
/// pressing there and dragging to it - drawn into a texture.
fn picture(gpa: std.mem.Allocator, device: *rhi.Device, renderer: *render.Renderer, demo: *Demo, width: u32, height: u32, pointer: Vec2, drag: ?Vec2) ![]u8 {
    var canvases: Canvases = .init(gpa);
    defer canvases.deinit();
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);

    var input: Input = .{ .pointer = pointer };
    _ = canvases.frame(demo, input, w, h, device.clip());
    if (drag) |to| {
        input.left = true;
        _ = canvases.frame(demo, input, w, h, device.clip());
        _ = canvases.frame(demo, input, w, h, device.clip());
        input.pointer = to;
    }
    const view_projection = canvases.frame(demo, input, w, h, device.clip());

    const target = try device.createTexture(.{ .width = width, .height = height, .usage = .{ .render_target = true } });
    defer device.destroyTexture(target);
    try renderer.draw(&canvases.all(), .{ .color = .{ .texture = target }, .clear = background }, .{
        .view_projection = view_projection,
        .width = w,
        .height = h,
    });
    return device.readTexture(target, gpa);
}

const Options = struct {
    backend: rhi.Backend,
    width: u32 = 1280,
    height: u32 = 720,
    frames: ?u32 = null,
    capture: ?[]const u8 = null,
    scene: Scene = .space,
    tool: Tool = .move,
    space: gizmos.Space = .world,
    pointer: Vec2 = .init(-100, -100),
    drag: ?Vec2 = null,

    fn parse(arguments: []const []const u8) !Options {
        var self: Options = .{ .backend = windowing.defaultBackend() };
        var i: usize = 1;
        while (i + 1 < arguments.len) : (i += 2) {
            const name = arguments[i];
            const value = arguments[i + 1];
            if (std.mem.eql(u8, name, "--backend")) {
                self.backend = std.meta.stringToEnum(rhi.Backend, value) orelse return error.UnknownBackend;
            } else if (std.mem.eql(u8, name, "--width")) {
                self.width = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--height")) {
                self.height = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--frames")) {
                self.frames = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--capture")) {
                self.capture = value;
            } else if (std.mem.eql(u8, name, "--scene")) {
                self.scene = std.meta.stringToEnum(Scene, value) orelse return error.UnknownScene;
            } else if (std.mem.eql(u8, name, "--tool")) {
                self.tool = std.meta.stringToEnum(Tool, value) orelse return error.UnknownTool;
            } else if (std.mem.eql(u8, name, "--space")) {
                self.space = std.meta.stringToEnum(gizmos.Space, value) orelse return error.UnknownSpace;
            } else if (std.mem.eql(u8, name, "--pointer")) {
                self.pointer = try pixelOf(value);
            } else if (std.mem.eql(u8, name, "--drag")) {
                self.drag = try pixelOf(value);
            } else return error.UnknownFlag;
        }
        if (i < arguments.len) return error.MissingValue;
        return self;
    }

    fn pixelOf(text: []const u8) !Vec2 {
        const comma = std.mem.indexOfScalar(u8, text, ',') orelse return error.NotAPixel;
        return .init(try std.fmt.parseFloat(f32, text[0..comma]), try std.fmt.parseFloat(f32, text[comma + 1 ..]));
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    const options = try Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));

    var window: Window = try .open(.{
        .backend = options.backend,
        .title = "Fluxion Gizmo",
        .width = options.width,
        .height = options.height,
        .visible = options.capture == null,
    });
    defer window.destroy();
    var device = try window.openDevice(gpa);
    defer device.deinit();
    var renderer: render.Renderer = try .init(gpa, &device, .{});
    defer renderer.deinit();

    var demo: Demo = .{ .scene = options.scene, .tool = options.tool, .space = options.space };

    if (options.capture) |path| {
        demo.show_pointer = true;
        const pixels = try picture(gpa, &device, &renderer, &demo, options.width, options.height, options.pointer, options.drag);
        defer gpa.free(pixels);
        try image.png.writeFile(gpa, init.io, path, .{
            .width = options.width,
            .height = options.height,
            .pixels = pixels,
            .row_pitch = @as(usize, options.width) * 4,
        }, .{});
        try out.print("wrote {s}: {t} {s}\n", .{ path, demo.last.phase, if (demo.last.part) |part| @tagName(part) else "-" });
        return out.flush();
    }

    const surface = try window.createSurface(&device);
    var canvases: Canvases = .init(gpa);
    defer canvases.deinit();
    var frames: u32 = 0;
    while (window.pump() and !demo.quit) {
        if (window.width == 0 or window.height == 0) continue;
        if (window.resized) {
            window.resized = false;
            try device.resizeSurface(surface, window.width, window.height);
        }
        const w: f32 = @floatFromInt(window.width);
        const h: f32 = @floatFromInt(window.height);
        const view_projection = canvases.frame(&demo, window.input, w, h, device.clip());
        try renderer.draw(&canvases.all(), .{ .color = .{ .surface = surface }, .clear = background }, .{
            .view_projection = view_projection,
            .width = w,
            .height = h,
        });
        try device.present(surface);

        frames += 1;
        if (options.frames) |limit| if (frames >= limit) break;
    }
}

const testing = std.testing;

fn step(demo: *Demo, canvases: *Canvases, input: Input) void {
    _ = canvases.frame(demo, input, 1280, 720, .gl);
}

test "the demo draws both scenes, every tool, with no GPU" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var renderer: render.Renderer = try .init(testing.allocator, &device, .{});
    defer renderer.deinit();

    for (std.enums.values(Scene)) |scene| {
        for (std.enums.values(Tool)) |tool| {
            var demo: Demo = .{ .scene = scene, .tool = tool };
            const pixels = try picture(testing.allocator, &device, &renderer, &demo, 320, 200, .init(160, 100), null);
            defer testing.allocator.free(pixels);
            try testing.expect(renderer.stats.lines > 100);
            try testing.expect(renderer.stats.triangles > 50);
        }
    }
}

test "dragging the picked crate's x arrow moves it along x" {
    var canvases: Canvases = .init(testing.allocator);
    defer canvases.deinit();
    var demo: Demo = .{};
    const start = demo.crates[0].transform.translation;
    const camera = Camera.init(demo.viewProjection(1280, 720, .gl), .gl, 1280, 720).?;
    const size = camera.unitsPerPixel(start).? * demo.gizmo.style.size;
    const grab = camera.pixelOf(start.add(.init(size * 0.6, 0, 0))).?;
    const there = camera.pixelOf(start.add(.init(size * 0.6 + 1, 0, 0))).?;

    step(&demo, &canvases, .{ .pointer = grab });
    step(&demo, &canvases, .{ .pointer = grab, .left = true });
    step(&demo, &canvases, .{ .pointer = grab, .left = true });
    step(&demo, &canvases, .{ .pointer = there, .left = true });
    step(&demo, &canvases, .{ .pointer = there });

    const moved = demo.crates[0].transform.translation.sub(start);
    try testing.expectApproxEqAbs(@as(f32, 1), moved.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), moved.y, 1e-3);
    try testing.expectEqual(@as(?usize, 0), demo.crate_picked);
}

test "a click on a card picks it, and a click on nothing picks nothing" {
    var canvases: Canvases = .init(testing.allocator);
    defer canvases.deinit();
    var demo: Demo = .{ .scene = .plane };
    const camera = Camera.init(demo.viewProjection(1280, 720, .gl), .gl, 1280, 720).?;
    const platform_card = camera.pixelOf(demo.cards[2].pose.position.vec3(0).add(.init(80, 0, 0))).?;

    step(&demo, &canvases, .{ .pointer = platform_card });
    step(&demo, &canvases, .{ .pointer = platform_card, .left = true });
    step(&demo, &canvases, .{ .pointer = platform_card });
    try testing.expectEqual(@as(?usize, 2), demo.card_picked);

    step(&demo, &canvases, .{ .pointer = .init(640, 700) });
    step(&demo, &canvases, .{ .pointer = .init(640, 700), .left = true });
    step(&demo, &canvases, .{ .pointer = .init(640, 700) });
    try testing.expectEqual(@as(?usize, null), demo.card_picked);
}
