const std = @import("std");
const ply = @import("ply.zig");

test "round trips deterministic fixture and reordered properties" {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/gaussians.ply", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(data);
    var cloud = try ply.parse(data, std.testing.allocator);
    defer cloud.deinit();
    try std.testing.expectEqual(@as(usize, 200), cloud.gaussians.len);
    try std.testing.expectEqual(@as(u32, 1), cloud.sh_degree);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), cloud.gaussians[0].position[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), cloud.gaussians[0].position[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.4), cloud.gaussians[0].f_dc[1], 1e-6);
    try std.testing.expectEqual(@as(usize, 9), cloud.gaussians[0].f_rest.len);
}

test "malformed property is named" {
    const data = "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float y\nend_header\n";
    try std.testing.expectError(error.InvalidProperty_x, ply.parse(data, std.testing.allocator));
}

test "malformed rest count is named" {
    const header = "ply\nformat binary_little_endian 1.0\nelement vertex 0\nproperty float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\nproperty float f_dc_0\nproperty float f_dc_1\nproperty float f_dc_2\nproperty float opacity\nproperty float scale_0\nproperty float scale_1\nproperty float scale_2\nproperty float rot_0\nproperty float rot_1\nproperty float rot_2\nproperty float rot_3\nproperty float f_rest_0\nend_header\n";
    try std.testing.expectError(error.InvalidProperty_f_rest, ply.parse(header, std.testing.allocator));
}

test "truncated vertex data never panics" {
    const header = "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\nproperty float f_dc_0\nproperty float f_dc_1\nproperty float f_dc_2\nproperty float opacity\nproperty float scale_0\nproperty float scale_1\nproperty float scale_2\nproperty float rot_0\nproperty float rot_1\nproperty float rot_2\nproperty float rot_3\nproperty float f_rest_0\nproperty float f_rest_1\nproperty float f_rest_2\nend_header\n";
    try std.testing.expectError(error.InvalidProperty_f_rest, ply.parse(header, std.testing.allocator));
}
