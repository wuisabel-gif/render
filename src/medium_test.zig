const std = @import("std");
const medium = @import("medium.zig");

fn expectArrayEqual(expected: [3]f32, actual: [3]f32) !void {
    for (0..3) |channel| {
        try std.testing.expectEqual(expected[channel], actual[channel]);
    }
}

test "zero distance returns albedo exactly" {
    const albedo = [3]f32{ 0.125, 0.5, 0.9375 };
    const result = medium.apply(albedo, 0.0, .{
        .beta_d = .{ 0.7, 1.2, 2.0 },
        .beta_b = .{ 0.3, 0.8, 1.5 },
        .b_inf = .{ 0.1, 0.2, 0.3 },
    });

    try expectArrayEqual(albedo, result);
}

test "all-zero coefficients return albedo exactly" {
    const albedo = [3]f32{ 0.2, 0.4, 0.8 };
    const result = medium.apply(albedo, 37.0, .{
        .beta_d = .{ 0.0, 0.0, 0.0 },
        .beta_b = .{ 0.0, 0.0, 0.0 },
        .b_inf = .{ 0.0, 0.0, 0.0 },
    });

    try expectArrayEqual(albedo, result);
}

test "large distance converges to backscatter colour" {
    const backscatter = [3]f32{ 0.15, 0.45, 0.8 };
    const result = medium.apply(.{ 0.9, 0.7, 0.2 }, 100.0, .{
        .beta_d = .{ 0.4, 0.7, 1.1 },
        .beta_b = .{ 0.3, 0.5, 0.8 },
        .b_inf = backscatter,
    });

    for (0..3) |channel| {
        try std.testing.expect(@abs(result[channel] - backscatter[channel]) <= 1e-4);
    }
}

test "transmission is monotonically decreasing" {
    const p = medium.Params{
        .beta_d = .{ 0.4, 0.9, 1.7 },
        .beta_b = .{ 0.0, 0.0, 0.0 },
        .b_inf = .{ 0.0, 0.0, 0.0 },
    };
    var previous = medium.apply(.{ 1.0, 1.0, 1.0 }, 0.0, p);

    for (1..101) |sample| {
        const z = @as(f32, @floatFromInt(sample)) * 0.1;
        const current = medium.apply(.{ 1.0, 1.0, 1.0 }, z, p);
        for (0..3) |channel| {
            try std.testing.expect(current[channel] <= previous[channel]);
        }
        previous = current;
    }
}

test "bounded inputs produce finite non-negative output" {
    const p = medium.Params{
        .beta_d = .{ 0.0, 2.5, 5.0 },
        .beta_b = .{ 5.0, 1.25, 0.0 },
        .b_inf = .{ 0.0, 0.6, 1.0 },
    };

    var sample: usize = 0;
    while (sample <= 1000) : (sample += 1) {
        const z = @as(f32, @floatFromInt(sample));
        const result = medium.apply(.{ 0.0, 0.35, 1.0 }, z, p);
        for (result) |value| {
            try std.testing.expect(std.math.isFinite(value));
            try std.testing.expect(value >= 0.0);
        }
    }
}
