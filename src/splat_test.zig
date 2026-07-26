const std = @import("std");
const ply = @import("ply.zig");
const splat = @import("splat.zig");

fn gaussian(z: f32, colour: [3]f32, opacity: f32) ply.Gaussian {
    const c = 0.2820947918;
    return .{
        .position = .{ 0, 0, z }, .normal = .{ 0, 0, 1 },
        .f_dc = .{ (colour[0] - 0.5) / c, (colour[1] - 0.5) / c, (colour[2] - 0.5) / c },
        .f_rest = &.{}, .opacity = opacity, .scale = .{ @log(0.2), @log(0.2), @log(0.2) },
        .rotation = .{ 1, 0, 0, 0 },
    };
}

fn camera() splat.Camera {
    return .{ .position = .{0, 0, 0}, .right = .{1, 0, 0}, .up = .{0, 1, 0}, .forward = .{0, 0, 1}, .focal_x = 4, .focal_y = 4, .principal_x = 1.5, .principal_y = 1.5 };
}

test "projects a centred gaussian into the image" {
    var gs = [_]ply.Gaussian{gaussian(2, .{1, 0, 0}, 0)};
    const cloud = ply.Cloud{ .gaussians = &gs, .sh_degree = 0, .allocator = std.testing.allocator };
    var buffers = try splat.Buffers.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer buffers.deinit(std.testing.allocator);
    try splat.renderInto(std.testing.allocator, cloud, camera(), .{ .width = 3, .height = 3 }, buffers);
    try std.testing.expect(buffers.rgb[4 * 3] > 0.49);
    try std.testing.expect(buffers.rgb[4 * 3 + 1] < 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), buffers.depth[4], 1e-5);
}

test "front to back compositing and expected depth use view order" {
    var gs = [_]ply.Gaussian{ gaussian(1, .{1, 0, 0}, 0), gaussian(3, .{0, 0, 1}, 0) };
    const cloud = ply.Cloud{ .gaussians = &gs, .sh_degree = 0, .allocator = std.testing.allocator };
    var buffers = try splat.Buffers.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer buffers.deinit(std.testing.allocator);
    try splat.renderInto(std.testing.allocator, cloud, camera(), .{ .width = 3, .height = 3 }, buffers);
    const center = buffers.rgb[4 * 3 ..][0..3];
    try std.testing.expect(center[0] > center[2]);
    try std.testing.expect(buffers.depth[4] < 2.0);
}

test "medium transformation uses expected splat depth" {
    var gs = [_]ply.Gaussian{gaussian(2, .{1, 1, 1}, 0)};
    const cloud = ply.Cloud{ .gaussians = &gs, .sh_degree = 0, .allocator = std.testing.allocator };
    var buffers = try splat.Buffers.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer buffers.deinit(std.testing.allocator);
    try splat.renderIntoWithMedium(std.testing.allocator, cloud, camera(), .{ .width = 3, .height = 3 }, buffers, .{
        .beta_d = .{ 1, 1, 1 },
        .beta_b = .{ 0, 0, 0 },
        .b_inf = .{ 0, 0, 0 },
    });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5) * @exp(-2.0), buffers.rgb[4 * 3], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 2), buffers.depth[4], 1e-5);
    try splat.renderIntoWithMediumScale(std.testing.allocator, cloud, camera(), .{ .width = 3, .height = 3 }, buffers, .{
        .beta_d = .{ 1, 1, 1 },
        .beta_b = .{ 0, 0, 0 },
        .b_inf = .{ 0, 0, 0 },
    }, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buffers.rgb[4 * 3], 1e-3);
}
test "ignores rest coefficients and rejects invalid output dimensions" {
    var g = gaussian(2, .{0, 1, 0}, 0);
    var rest = [_]f32{1000, -1000, 1000};
    g.f_rest = &rest;
    var gs = [_]ply.Gaussian{g};
    const cloud = ply.Cloud{ .gaussians = &gs, .sh_degree = 1, .allocator = std.testing.allocator };
    var buffers = try splat.Buffers.init(std.testing.allocator, .{ .width = 1, .height = 1 });
    defer buffers.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidImage, splat.renderInto(std.testing.allocator, cloud, camera(), .{ .width = 0, .height = 1 }, buffers));
}

test "behind-camera and zero quaternion gaussians are skipped" {
    var gs = [_]ply.Gaussian{ gaussian(-1, .{1, 0, 0}, 0), gaussian(2, .{0, 1, 0}, 0) };
    gs[1].rotation = .{0, 0, 0, 0};
    const cloud = ply.Cloud{ .gaussians = &gs, .sh_degree = 0, .allocator = std.testing.allocator };
    var buffers = try splat.Buffers.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer buffers.deinit(std.testing.allocator);
    try splat.renderInto(std.testing.allocator, cloud, camera(), .{ .width = 3, .height = 3 }, buffers);
    for (buffers.rgb) |value| try std.testing.expectEqual(@as(f32, 0), value);
    for (buffers.depth) |value| try std.testing.expectEqual(@as(f32, 0), value);
}
