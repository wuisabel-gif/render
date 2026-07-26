const std = @import("std");

fn put(out: []u8, at: *usize, bytes: []const u8) void { @memcpy(out[at.*..][0..bytes.len], bytes); at.* += bytes.len; }
fn f32le(out: []u8, at: *usize, v: f32) void { var b: [4]u8 = undefined; std.mem.writeInt(u32, &b, @bitCast(v), .little); put(out, at, &b); }

pub fn main(init: std.process.Init) !void {
    var out: [512 * 1024]u8 = undefined; var n: usize = 0;
    const header = "ply\nformat binary_little_endian 1.0\nelement vertex 200\nproperty float z\nproperty float f_dc_1\nproperty float x\nproperty float opacity\nproperty float f_rest_8\nproperty float nx\nproperty float scale_2\nproperty float rot_3\nproperty float f_dc_0\nproperty float y\nproperty float f_rest_0\nproperty float nz\nproperty float rot_0\nproperty float scale_0\nproperty float f_dc_2\nproperty float f_rest_1\nproperty float f_rest_2\nproperty float f_rest_3\nproperty float f_rest_4\nproperty float f_rest_5\nproperty float f_rest_6\nproperty float f_rest_7\nproperty float ny\nproperty float scale_1\nproperty float rot_1\nproperty float rot_2\nend_header\n";
    put(&out, &n, header);
    var i: usize = 0; while (i < 200) : (i += 1) {
        const x = @as(f32, @floatFromInt(i)) / 199.0 - 0.5;
        const y = @sin(@as(f32, @floatFromInt(i)) * 0.17) * 0.5;
        const z = @cos(@as(f32, @floatFromInt(i)) * 0.11) * 0.25;
        const opacity = @as(f32, @floatFromInt((i * 37) % 101)) / 100.0;
        f32le(&out, &n, z); f32le(&out, &n, 0.1 + x); f32le(&out, &n, x); f32le(&out, &n, opacity);
        f32le(&out, &n, 0.001 * @as(f32, @floatFromInt(i + 1))); f32le(&out, &n, 0); f32le(&out, &n, 0.02);
        f32le(&out, &n, 1); f32le(&out, &n, 0.2 + x); f32le(&out, &n, y); f32le(&out, &n, 0.002);
        f32le(&out, &n, 0); f32le(&out, &n, 0); f32le(&out, &n, 0.03); f32le(&out, &n, 0.3);
        f32le(&out, &n, 0.004); f32le(&out, &n, 0.005); f32le(&out, &n, 0.006); f32le(&out, &n, 0.007); f32le(&out, &n, 0.008); f32le(&out, &n, 0.009); f32le(&out, &n, 0.010);
        f32le(&out, &n, 0); f32le(&out, &n, 0.04); f32le(&out, &n, 0); f32le(&out, &n, 0);
    }
    const file = try std.Io.Dir.cwd().createFile(init.io, "fixtures/gaussians.ply", .{}); defer file.close(init.io); try file.writeStreamingAll(init.io, out[0..n]);
}
