const std = @import("std");
const ply = @import("ply.zig");

/// A pinhole camera. `forward` points from the camera into the scene, and all
/// three basis vectors are expected to be orthonormal. `focal_x` and
/// `focal_y` are focal lengths in pixels; principal_x/y are pixel coordinates.
/// A point's positive camera-space Z is its view depth in the same units as the
/// PLY positions. The image origin is the top-left and pixel centres are at
/// (x + 0.5, y + 0.5).
pub const Camera = struct {
    position: [3]f32,
    right: [3]f32,
    up: [3]f32,
    forward: [3]f32,
    focal_x: f32,
    focal_y: f32,
    principal_x: f32,
    principal_y: f32,
};

pub const Image = struct { width: usize, height: usize };

/// Caller-owned output storage. RGB is linear, interleaved f32 (three values
/// per pixel), row-major. Depth is expected view depth, in PLY world units,
/// row-major; zero denotes a pixel with no accumulated contribution.
pub const Buffers = struct {
    rgb: []f32,
    depth: []f32,

    pub fn init(allocator: std.mem.Allocator, image: Image) !Buffers {
        if (image.width == 0 or image.height == 0) return error.InvalidImage;
        const pixels = std.math.mul(usize, image.width, image.height) catch return error.InvalidImage;
        const rgb = try allocator.alloc(f32, std.math.mul(usize, pixels, 3) catch return error.InvalidImage);
        errdefer allocator.free(rgb);
        const depth = try allocator.alloc(f32, pixels);
        return .{ .rgb = rgb, .depth = depth };
    }

    pub fn deinit(self: *Buffers, allocator: std.mem.Allocator) void {
        allocator.free(self.rgb);
        allocator.free(self.depth);
        self.* = undefined;
    }

    pub fn clear(self: Buffers) void {
        @memset(self.rgb, 0);
        @memset(self.depth, 0);
    }
};

const Projected = struct {
    x: f32,
    y: f32,
    depth: f32,
    inv00: f32,
    inv01: f32,
    inv11: f32,
    det: f32,
    colour: [3]f32,
    opacity: f32,
};

fn dot(a: [3]f32, b: [3]f32) f32 { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
fn clamp01(v: f32) f32 { return @max(0.0, @min(1.0, v)); }

fn project(g: ply.Gaussian, camera: Camera) ?Projected {
    const d = .{ g.position[0] - camera.position[0], g.position[1] - camera.position[1], g.position[2] - camera.position[2] };
    const cx = dot(d, camera.right);
    const cy = dot(d, camera.up);
    const cz = dot(d, camera.forward);
    if (!(cz > 0.0001) or !std.math.isFinite(cz)) return null;

    const sx = camera.focal_x / cz;
    const sy = camera.focal_y / cz;
    const px = camera.principal_x + sx * cx;
    const py = camera.principal_y + sy * cy;

    // 3DGS stores log-scales and a (w,x,y,z) quaternion. This computes
    // Sigma = R diag(exp(scale)^2) R^T, then J Sigma J^T under perspective.
    const qlen = @sqrt(g.rotation[0] * g.rotation[0] + g.rotation[1] * g.rotation[1] + g.rotation[2] * g.rotation[2] + g.rotation[3] * g.rotation[3]);
    if (!(qlen > 0.000001) or !std.math.isFinite(qlen)) return null;
    const qw = g.rotation[0] / qlen;
    const qx = g.rotation[1] / qlen;
    const qy = g.rotation[2] / qlen;
    const qz = g.rotation[3] / qlen;
    const r = [3][3]f32{
        .{ 1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw) },
        .{ 2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw) },
        .{ 2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy) },
    };
    var var3 = [3]f32{ 0, 0, 0 };
    for (0..3) |axis| var3[axis] = std.math.exp(g.scale[axis] * 2.0);
    var sigma = [3][3]f32{ .{0,0,0}, .{0,0,0}, .{0,0,0} };
    for (0..3) |i| {
        for (0..3) |j| {
            for (0..3) |k| sigma[i][j] += r[i][k] * var3[k] * r[j][k];
        }
    }

    const jx = [3]f32{ sx, 0, -sx * cx / cz };
    const jy = [3]f32{ 0, sy, -sy * cy / cz };
    var c00: f32 = 0; var c01: f32 = 0; var c11: f32 = 0;
    for (0..3) |i| {
        for (0..3) |j| {
            c00 += jx[i] * sigma[i][j] * jx[j];
            c01 += jx[i] * sigma[i][j] * jy[j];
            c11 += jy[i] * sigma[i][j] * jy[j];
        }
    }
    c00 += 0.3; c11 += 0.3; // finite pixel footprint, also stabilises tiny splats
    const det = c00 * c11 - c01 * c01;
    if (!(det > 0) or !std.math.isFinite(det)) return null;
    const dc = [3]f32{ 0.2820947918 * g.f_dc[0] + 0.5, 0.2820947918 * g.f_dc[1] + 0.5, 0.2820947918 * g.f_dc[2] + 0.5 };
    return .{ .x = px, .y = py, .depth = cz, .inv00 = c11 / det, .inv01 = -c01 / det, .inv11 = c00 / det, .det = det, .colour = .{clamp01(dc[0]), clamp01(dc[1]), clamp01(dc[2])}, .opacity = clamp01(1.0 / (1.0 + std.math.exp(-g.opacity))) };
}

fn nearer(_: void, a: Projected, b: Projected) bool { return a.depth < b.depth; }

/// Rasterise DC-only Gaussian splats into caller-provided buffers. Existing
/// buffer contents are replaced. Gaussians are sorted nearest-first and each
/// pixel is composited front-to-back; f_rest is intentionally not evaluated.
pub fn renderInto(allocator: std.mem.Allocator, cloud: ply.Cloud, camera: Camera, image: Image, buffers: Buffers) !void {
    const pixels = std.math.mul(usize, image.width, image.height) catch return error.InvalidImage;
    if (image.width == 0 or image.height == 0 or buffers.rgb.len != pixels * 3 or buffers.depth.len != pixels) return error.InvalidImage;
    buffers.clear();
    const transmittance = try allocator.alloc(f32, pixels);
    defer allocator.free(transmittance);
    @memset(transmittance, 1.0);
    var projected = std.ArrayList(Projected).empty;
    defer projected.deinit(allocator);
    for (cloud.gaussians) |g| if (project(g, camera)) |p| try projected.append(allocator, p);
    std.mem.sortUnstable(Projected, projected.items, {}, nearer);
    for (projected.items) |p| {
        const radius_x = 3.0 * @sqrt(p.det / p.inv11);
        const radius_y = 3.0 * @sqrt(p.det / p.inv00);
        const min_x: isize = @max(0, @as(isize, @intFromFloat(@floor(p.x - radius_x))));
        const max_x: isize = @min(@as(isize, @intCast(image.width)) - 1, @as(isize, @intFromFloat(@ceil(p.x + radius_x))));
        const min_y: isize = @max(0, @as(isize, @intFromFloat(@floor(p.y - radius_y))));
        const max_y: isize = @min(@as(isize, @intCast(image.height)) - 1, @as(isize, @intFromFloat(@ceil(p.y + radius_y))));
        if (min_x > max_x or min_y > max_y) continue;
        for (@as(usize, @intCast(min_y))..@as(usize, @intCast(max_y + 1))) |y| {
            for (@as(usize, @intCast(min_x))..@as(usize, @intCast(max_x + 1))) |x| {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - p.x;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - p.y;
            const exponent = -0.5 * (p.inv00 * dx * dx + 2.0 * p.inv01 * dx * dy + p.inv11 * dy * dy);
            if (exponent < -4.5) continue;
            const alpha = p.opacity * std.math.exp(exponent);
            const index = y * image.width + x;
            const contribution = transmittance[index] * alpha;
            for (0..3) |channel| buffers.rgb[index * 3 + channel] += contribution * p.colour[channel];
            buffers.depth[index] += contribution * p.depth;
            transmittance[index] *= 1.0 - alpha;
            }
        }
    }
    for (0..pixels) |index| {
        const accumulated = 1.0 - transmittance[index];
        if (accumulated > 0.0) buffers.depth[index] /= accumulated;
    }
}
