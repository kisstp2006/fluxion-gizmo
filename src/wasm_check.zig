// SPDX-License-Identifier: BSD-2-Clause

//! What `zig build test` compiles for `wasm32-freestanding` and never runs,
//! so a browser build that would not compile fails the suite.

const std = @import("std");
const math = @import("fluxion_math");
const debugdraw = @import("fluxion_debugdraw");
const gizmo = @import("fluxion_gizmo");

var heap: [1024 * 1024]u8 = undefined;

export fn fluxion_gizmo_wasm_check(x: f32, y: f32, down: bool) u32 {
    var fba: std.heap.FixedBufferAllocator = .init(&heap);
    var canvas: debugdraw.Canvas = .init(fba.allocator());
    defer canvas.deinit();

    const projection = math.perspective(.{ .fov_y = math.radians(60), .aspect = 4.0 / 3.0, .near = 0.1, .far = 100, .clip = .gl });
    var tools: gizmo.Gizmo = .{};
    var thing: math.Transform = .identity;
    var pose: gizmo.Pose2D = .{};
    var spot: math.Vec2 = .zero;
    var reach: f32 = 1;

    tools.begin(.{
        .pen = canvas.pen(),
        .view_projection = projection.mul(math.lookAt(.init(3, 3, 6), .zero, .unit_y, .right)),
        .clip = .gl,
        .width = 800,
        .height = 600,
        .pointer = .init(x, y),
        .down = down,
    });
    var used: u32 = 0;
    used += @intFromBool(tools.transform(.of("thing"), &thing, .{ .tool = .all }).changed);
    used += @intFromBool(tools.transform2d(.of("pose"), &pose, .{ .tool = .rotate }).changed);
    used += @intFromBool(tools.bounds2d(.of("box"), &pose, .sized(.splat(2), .splat(0.5)), .{}).changed);
    used += @intFromBool(tools.point2d(.of("spot"), &spot, .{}).changed);
    used += @intFromBool(tools.radius2d(.of("reach"), &reach, .zero, .{}).changed);
    tools.end();
    return used + @as(u32, @intCast(canvas.lines.items.len));
}
