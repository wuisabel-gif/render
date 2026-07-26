const std = @import("std");

pub const Gaussian = struct {
    position: [3]f32,
    normal: [3]f32,
    f_dc: [3]f32,
    f_rest: []f32,
    opacity: f32,
    scale: [3]f32,
    rotation: [4]f32,
};

pub const Cloud = struct {
    gaussians: []Gaussian,
    sh_degree: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Cloud) void {
        for (self.gaussians) |g| self.allocator.free(g.f_rest);
        self.allocator.free(self.gaussians);
    }
};

// Error names deliberately identify the PLY property that made the input invalid.
pub const ParseError = error{
    InvalidHeader,
    UnsupportedFormat,
    MissingVertexElement,
    InvalidVertexCount,
    DuplicateProperty,
    InvalidProperty_x, InvalidProperty_y, InvalidProperty_z,
    InvalidProperty_nx, InvalidProperty_ny, InvalidProperty_nz,
    InvalidProperty_f_dc, InvalidProperty_f_rest,
    InvalidProperty_opacity, InvalidProperty_scale, InvalidProperty_rot,
    TruncatedVertexData,
};

const Property = enum { x, y, z, nx, ny, nz, dc0, dc1, dc2, opacity, scale0, scale1, scale2, rot0, rot1, rot2, rot3, rest };
const PropInfo = struct { property: Property, offset: usize };

fn propertyFor(name: []const u8) ?Property {
    if (std.mem.eql(u8, name, "x")) return .x;
    if (std.mem.eql(u8, name, "y")) return .y;
    if (std.mem.eql(u8, name, "z")) return .z;
    if (std.mem.eql(u8, name, "nx")) return .nx;
    if (std.mem.eql(u8, name, "ny")) return .ny;
    if (std.mem.eql(u8, name, "nz")) return .nz;
    if (std.mem.eql(u8, name, "f_dc_0")) return .dc0;
    if (std.mem.eql(u8, name, "f_dc_1")) return .dc1;
    if (std.mem.eql(u8, name, "f_dc_2")) return .dc2;
    if (std.mem.eql(u8, name, "opacity")) return .opacity;
    if (std.mem.eql(u8, name, "scale_0")) return .scale0;
    if (std.mem.eql(u8, name, "scale_1")) return .scale1;
    if (std.mem.eql(u8, name, "scale_2")) return .scale2;
    if (std.mem.eql(u8, name, "rot_0")) return .rot0;
    if (std.mem.eql(u8, name, "rot_1")) return .rot1;
    if (std.mem.eql(u8, name, "rot_2")) return .rot2;
    if (std.mem.eql(u8, name, "rot_3")) return .rot3;
    if (std.mem.startsWith(u8, name, "f_rest_")) return .rest;
    return null;
}
fn errorFor(p: Property) ParseError {
    return switch (p) {
        .x => error.InvalidProperty_x, .y => error.InvalidProperty_y, .z => error.InvalidProperty_z,
        .nx => error.InvalidProperty_nx, .ny => error.InvalidProperty_ny, .nz => error.InvalidProperty_nz,
        .dc0, .dc1, .dc2 => error.InvalidProperty_f_dc, .rest => error.InvalidProperty_f_rest,
        .opacity => error.InvalidProperty_opacity, .scale0, .scale1, .scale2 => error.InvalidProperty_scale,
        .rot0, .rot1, .rot2, .rot3 => error.InvalidProperty_rot,
    };
}
fn required(p: Property, seen: u32) ParseError!void {
    if ((seen & (@as(u32, 1) << @intFromEnum(p))) == 0) return errorFor(p);
}
fn readF32(bytes: []const u8, at: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little));
}

pub fn parse(data: []const u8, allocator: std.mem.Allocator) ParseError!Cloud {
    const marker = "end_header\n";
    const end = std.mem.indexOf(u8, data, marker) orelse return error.InvalidHeader;
    const header = data[0 .. end + marker.len];
    var lines = std.mem.splitScalar(u8, header, '\n');
    var vertex_count: usize = 0;
    var have_vertex = false;
    var props: [256]PropInfo = undefined;
    var prop_count: usize = 0;
    var stride: usize = 0;
    var rest_count: usize = 0;
    var seen: u32 = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const first = words.next() orelse continue;
        if (std.mem.eql(u8, first, "format")) {
            const fmt = words.next() orelse return error.InvalidHeader;
            if (!std.mem.eql(u8, fmt, "binary_little_endian")) return error.UnsupportedFormat;
        } else if (std.mem.eql(u8, first, "element")) {
            const kind = words.next() orelse return error.InvalidHeader;
            const count = words.next() orelse return error.InvalidVertexCount;
            if (std.mem.eql(u8, kind, "vertex")) { vertex_count = std.fmt.parseInt(usize, count, 10) catch return error.InvalidVertexCount; have_vertex = true; }
        } else if (std.mem.eql(u8, first, "property")) {
            const typ = words.next() orelse return error.InvalidHeader;
            const name = words.next() orelse return error.InvalidHeader;
            if (!std.mem.eql(u8, typ, "float") and !std.mem.eql(u8, typ, "float32")) if (propertyFor(name)) |p| return errorFor(p) else return error.InvalidHeader;
            const p = propertyFor(name) orelse continue; // permitted unknown properties are skipped below
            const bit = @as(u32, 1) << @intFromEnum(p);
            if (p != .rest and seen & bit != 0) return error.DuplicateProperty;
            if (p == .rest) {
                rest_count += 1;
            } else {
                seen |= bit;
            }
            if (prop_count == props.len) return error.InvalidHeader;
            props[prop_count] = .{ .property = p, .offset = stride }; prop_count += 1; stride += 4;
        }
    }
    if (!have_vertex) return error.MissingVertexElement;
    inline for ([_]Property{ .x, .y, .z, .nx, .ny, .nz, .dc0, .dc1, .dc2, .opacity, .scale0, .scale1, .scale2, .rot0, .rot1, .rot2, .rot3 }) |p| try required(p, seen);
    if (rest_count % 3 != 0) return error.InvalidProperty_f_rest;
    const total_coeff = 3 + rest_count;
    var degree: u32 = 0; while (3 * (degree + 1) * (degree + 1) < total_coeff) degree += 1;
    if (3 * (degree + 1) * (degree + 1) != total_coeff) return error.InvalidProperty_f_rest;
    const payload = data.len - (end + marker.len);
    if (payload < vertex_count * stride) {
        const available = payload / stride;
        const row = @min(available, vertex_count - 1);
        const row_bytes = if (available < vertex_count) payload - row * stride else 0;
        for (props[0..prop_count]) |pi| if (row_bytes <= pi.offset) return errorFor(pi.property);
        return error.TruncatedVertexData;
    }
    const gs = allocator.alloc(Gaussian, vertex_count) catch return error.TruncatedVertexData;
    errdefer allocator.free(gs);
    for (gs) |*g| g.* = .{ .position = .{0,0,0}, .normal = .{0,0,0}, .f_dc = .{0,0,0}, .f_rest = &.{}, .opacity = 0, .scale = .{0,0,0}, .rotation = .{0,0,0,0} };
    for (gs, 0..) |*g, i| {
        const rest = allocator.alloc(f32, rest_count) catch return error.TruncatedVertexData; errdefer allocator.free(rest);
        g.f_rest = rest;
        for (props[0..prop_count]) |pi| { const v = readF32(data, end + marker.len + i * stride + pi.offset); switch (pi.property) {
            .x => g.position[0]=v, .y => g.position[1]=v, .z => g.position[2]=v, .nx => g.normal[0]=v, .ny => g.normal[1]=v, .nz => g.normal[2]=v,
            .dc0 => g.f_dc[0]=v, .dc1 => g.f_dc[1]=v, .dc2 => g.f_dc[2]=v, .opacity => g.opacity=v,
            .scale0 => g.scale[0]=v, .scale1 => g.scale[1]=v, .scale2 => g.scale[2]=v, .rot0 => g.rotation[0]=v, .rot1 => g.rotation[1]=v, .rot2 => g.rotation[2]=v, .rot3 => g.rotation[3]=v,
            .rest => {}, } }
        var ri: usize = 0; for (props[0..prop_count]) |pi| if (pi.property == .rest) { g.f_rest[ri] = readF32(data, end + marker.len + i * stride + pi.offset); ri += 1; };
    }
    return .{ .gaussians = gs, .sh_degree = degree, .allocator = allocator };
}

pub fn inspect(cloud: Cloud) void {
    var mn = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) }; var mx = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) }; var hist = [_]usize{0} ** 10;
    for (cloud.gaussians) |g| { for (0..3) |j| { mn[j]=@min(mn[j],g.position[j]); mx[j]=@max(mx[j],g.position[j]); } const b: usize = if (g.opacity <= 0) 0 else if (g.opacity >= 1) 9 else @intFromFloat(g.opacity * 10); hist[b] += 1; }
    std.debug.print("gaussians: {d}\nAABB: [{d}, {d}] [{d}, {d}] [{d}, {d}]\nopacity histogram (10 buckets):", .{cloud.gaussians.len,mn[0],mx[0],mn[1],mx[1],mn[2],mx[2]}); for (hist) |n| std.debug.print(" {d}", .{n}); std.debug.print("\ninferred SH degree: {d}\n", .{cloud.sh_degree});
}

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate(); _ = it.skip();
    const flag = it.next() orelse return error.InvalidHeader;
    if (!std.mem.eql(u8, flag, "--inspect")) return error.InvalidHeader;
    const path = it.next() orelse return error.InvalidHeader;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(256 * 1024 * 1024)); defer init.gpa.free(data);
    var cloud = try parse(data, init.gpa); defer cloud.deinit(); inspect(cloud);
}
