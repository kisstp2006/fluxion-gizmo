// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Gizmo - handles in a picture for the pointer to drag: arrows,
//! rings and boxes that move, turn and scale things, in 2D and in 3D, drawn
//! with Fluxion Debug Draw.
//!
//! ```zig
//! var gizmo: fluxion_gizmo.Gizmo = .{};
//!
//! gizmo.begin(.{
//!     .pen = canvas.pen(),
//!     .view_projection = camera,
//!     .clip = device.clip(),
//!     .width = 1280,
//!     .height = 720,
//!     .pointer = mouse,
//!     .down = left_button,
//! });
//! const turned = gizmo.transform2d(.of(entity), &pose, .{ .tool = .rotate });
//! if (turned.changed) save(pose);
//! gizmo.end();
//! ```

const std = @import("std");

pub const Gizmo = @import("Gizmo.zig");
pub const Camera = @import("Camera.zig");
pub const Pose2D = @import("Pose2D.zig");

pub const Id = Gizmo.Id;
pub const Frame = Gizmo.Frame;
pub const Response = Gizmo.Response;
pub const Phase = Gizmo.Phase;
pub const Part = Gizmo.Part;
pub const Tool = Gizmo.Tool;
pub const Space = Gizmo.Space;
pub const Axes = Gizmo.Axes;
pub const Snap = Gizmo.Snap;
pub const Options = Gizmo.Options;
pub const Rect = Gizmo.Rect;
pub const BoundsOptions = Gizmo.BoundsOptions;
pub const HandleOptions = Gizmo.HandleOptions;
pub const Style = Gizmo.Style;

test {
    _ = Camera;
    _ = Pose2D;
    _ = Gizmo;
    _ = @import("geometry.zig");
    _ = @import("gizmo_test.zig");
}

test "every name this file exports is one that exists" {
    std.testing.refAllDecls(@This());
}
