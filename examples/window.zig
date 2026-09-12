// SPDX-License-Identifier: BSD-2-Clause

//! A window, the device on it, and what the pointer and the keys did since
//! the last pump. Not part of the library, which opens no windows.

const std = @import("std");
const builtin = @import("builtin");

const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const platform = @import("fluxion_platform");

const Vec2 = math.Vec2;

pub fn defaultBackend() rhi.Backend {
    return if (builtin.os.tag == .windows) .d3d11 else .gl;
}

pub const Input = struct {
    /// Pixels from the top left of the framebuffer.
    pointer: Vec2 = .zero,
    moved: Vec2 = .zero,
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    right_pressed: bool = false,
    /// Notches, up positive.
    wheel: f32 = 0,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    typed: [16]platform.Key = undefined,
    typed_count: usize = 0,

    pub fn pressed(self: *const Input, key: platform.Key) bool {
        return std.mem.indexOfScalar(platform.Key, self.typed[0..self.typed_count], key) != null;
    }

    pub fn press(self: *Input, key: platform.Key) void {
        if (self.typed_count < self.typed.len) {
            self.typed[self.typed_count] = key;
            self.typed_count += 1;
        }
    }

    /// Forget what happened, and keep what is held.
    pub fn next(self: *Input) void {
        self.moved = .zero;
        self.wheel = 0;
        self.right_pressed = false;
        self.typed_count = 0;
    }

    fn onKey(self: *Input, key: platform.Key, action: platform.Action) void {
        const down = action.down();
        switch (key) {
            .left_control, .right_control => self.ctrl = down,
            .left_shift, .right_shift => self.shift = down,
            .left_alt, .right_alt => self.alt = down,
            else => {},
        }
        if (action == .press) self.press(key);
    }

    fn onButton(self: *Input, button: platform.MouseButton, action: platform.Action) void {
        const down = action.down();
        switch (button) {
            .left => self.left = down,
            .right => {
                if (down and !self.right) self.right_pressed = true;
                self.right = down;
            },
            .middle => self.middle = down,
            else => {},
        }
    }
};

pub const Window = struct {
    inner: *Inner,
    backend: rhi.Backend,
    width: u32,
    height: u32,
    resized: bool = false,
    input: Input = .{},

    /// Boxed: the platform window points at its context and the hooks at
    /// this, so neither may move.
    const Inner = struct {
        ctx: platform.Context,
        win: platform.Window,
    };

    pub const Options = struct {
        backend: rhi.Backend,
        title: []const u8,
        width: u32,
        height: u32,
        visible: bool = true,
    };

    pub fn open(options: Options) platform.Error!Window {
        const gpa = std.heap.smp_allocator;
        const inner = try gpa.create(Inner);
        errdefer gpa.destroy(inner);
        inner.ctx = try platform.Context.init(gpa, .{});
        errdefer inner.ctx.deinit();
        inner.win = try inner.ctx.createWindow(.{
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .visible = options.visible,
            .gl = if (options.backend == .gl) .{ .major = 3, .minor = 3, .profile = .core } else null,
        });
        errdefer inner.win.destroy();

        if (options.backend == .gl) {
            try inner.win.makeContextCurrent();
            inner.win.setSwapInterval(.vsync) catch {};
        }
        const size = inner.win.framebufferSize();
        return .{ .inner = inner, .backend = options.backend, .width = size[0], .height = size[1] };
    }

    pub fn isAbsent(err: anyerror) bool {
        return switch (err) {
            error.Unsupported, error.NoDisplay, error.ConnectionFailed, error.WindowCreationFailed, error.Unavailable, error.NoDevice => true,
            else => false,
        };
    }

    pub fn openDevice(self: *const Window, gpa: std.mem.Allocator) rhi.Error!rhi.Device {
        return rhi.Device.init(gpa, .{
            .backend = switch (self.backend) {
                .gl => .gl,
                .d3d11 => .d3d11,
                .none => .none,
                .webgl => return error.Unsupported,
            },
            .gl = if (self.backend == .gl) .{
                .context = self.inner,
                .get_proc_address = getProcAddress,
                .swap_buffers = swapBuffers,
                .framebuffer_size = framebufferSize,
            } else null,
        });
    }

    pub fn createSurface(self: *const Window, device: *rhi.Device) rhi.Error!rhi.Surface {
        return device.createSurface(.{ .native_window = self.inner.win.native(), .width = self.width, .height = self.height });
    }

    fn getProcAddress(context: *anyopaque, name: [*:0]const u8) ?rhi.GlProc {
        const inner: *Inner = @ptrCast(@alignCast(context));
        return inner.win.getProcAddress(name);
    }

    fn swapBuffers(context: *anyopaque) void {
        const inner: *Inner = @ptrCast(@alignCast(context));
        inner.win.swapBuffers() catch {};
    }

    fn framebufferSize(context: *anyopaque) [2]u32 {
        const inner: *Inner = @ptrCast(@alignCast(context));
        return inner.win.framebufferSize();
    }

    /// Drain the events into `input`, and say whether the window is still
    /// open.
    pub fn pump(self: *Window) bool {
        self.input.next();
        self.inner.ctx.pump() catch return false;
        while (self.inner.ctx.poll()) |event| switch (event) {
            .close => self.inner.win.setShouldClose(true),
            .key => |key| self.input.onKey(key.key, key.action),
            .mouse_button => |button| self.input.onButton(button.button, button.action),
            .cursor => |cursor| {
                const at = Vec2.init(@floatCast(cursor.x), @floatCast(cursor.y)).mul(self.pixelsPerUnit());
                self.input.moved = self.input.moved.add(at.sub(self.input.pointer));
                self.input.pointer = at;
            },
            .scroll => |scroll| self.input.wheel += @floatCast(scroll.y),
            .framebuffer_resize => |size| {
                self.width = size.width;
                self.height = size.height;
                self.resized = true;
            },
            else => {},
        };
        return !self.inner.win.shouldClose();
    }

    pub fn close(self: *Window) void {
        self.inner.win.setShouldClose(true);
    }

    pub fn destroy(self: *Window) void {
        self.inner.win.destroy();
        self.inner.ctx.deinit();
        std.heap.smp_allocator.destroy(self.inner);
        self.* = undefined;
    }

    /// The cursor comes in window units and the picture is in pixels, which
    /// differ on a high-density screen.
    fn pixelsPerUnit(self: *const Window) Vec2 {
        const units = self.inner.win.size();
        const pixels = self.inner.win.framebufferSize();
        if (units[0] == 0 or units[1] == 0) return .one;
        return .init(
            @as(f32, @floatFromInt(pixels[0])) / @as(f32, @floatFromInt(units[0])),
            @as(f32, @floatFromInt(pixels[1])) / @as(f32, @floatFromInt(units[1])),
        );
    }
};
