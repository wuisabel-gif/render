// render.zig — CPU port of robopool.slang.
//
// Runs the exact same renderPool() math the compute shader runs, but on the
// CPU, one pixel at a time, and writes the result straight to robopool.png.
// No GPU, no Vulkan, no third-party libraries. The PNG encoder is hand-rolled
// (CRC32 + chunk assembly); deflate compression comes from std.compress.flate.
//
//   zig run render.zig                       (defaults: 1280x800, time 1.5, turbidity 1.0)
//   zig run render.zig -- 1920 1200 2.0 0.3  (width height time turbidity; trailing args optional)
//
// Slang -> Zig mapping: frac->fract, saturate->clamp01, lerp->mix,
// float2/float3 -> Vec2/Vec3. The uv orientation matches the shader:
// uv.y = 0 at the top row (SV_DispatchThreadID.y counts downward).

const std = @import("std");

// ------------------------------------------------------------------ vectors
const Vec2 = struct {
    x: f32,
    y: f32,
    fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }
};

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
    fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    fn mixv(a: Vec3, b: Vec3, t: f32) Vec3 {
        return a.add(b.sub(a).scale(t));
    }
};

// ------------------------------------------------------------------ scalars
fn fract(x: f32) f32 {
    return x - std.math.floor(x);
}
fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}
fn step(edge: f32, x: f32) f32 {
    return if (x < edge) 0.0 else 1.0;
}
fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
fn dist2(a: Vec2, b: Vec2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

// ------------------------------------------------------------------ shader
fn hash(p: Vec2) f32 {
    return fract(@sin(p.x * 127.1 + p.y * 311.7) * 43758.5453);
}

fn caustics(p: Vec2, time: f32) f32 {
    const wave1 = @sin(p.x * 18.0 + time);
    const wave2 = @sin(p.y * 16.0 - time * 1.2);
    const wave3 = @sin((p.x + p.y) * 11.0 + time * 0.7);
    const combined = (wave1 + wave2 + wave3) / 3.0;
    return std.math.pow(f32, clamp01(combined), 4.0);
}

fn rectangleMask(uv: Vec2, mn: Vec2, mx: Vec2) f32 {
    const insideX = step(mn.x, uv.x) * step(uv.x, mx.x);
    const insideY = step(mn.y, uv.y) * step(uv.y, mx.y);
    return insideX * insideY;
}

fn circleMask(uv: Vec2, c: Vec2, r: f32) f32 {
    return 1.0 - step(r, dist2(uv, c));
}

fn renderPool(uv: Vec2, time: f32, turbidity: f32) Vec3 {
    const waterColor = Vec3.init(0.025, 0.23, 0.38);
    const tileColor = Vec3.init(0.54, 0.74, 0.82);
    var color = waterColor;

    // Perspective-like floor region.
    const floorStart: f32 = 0.42;
    const floorMask = step(floorStart, uv.y);
    const floorDepth = clamp01((uv.y - floorStart) / (1.0 - floorStart));

    const tileUV = Vec2.init(
        (uv.x - 0.5) * mix(5.0, 20.0, floorDepth),
        floorDepth * 18.0,
    );
    const gridPos = Vec2.init(
        @abs(fract(tileUV.x) - 0.5),
        @abs(fract(tileUV.y) - 0.5),
    );
    const gridLine = 1.0 - step(0.045, @min(gridPos.x, gridPos.y));
    var floorColor = tileColor.sub(Vec3.init(floorDepth * 0.12, floorDepth * 0.07, floorDepth * 0.03));
    floorColor = floorColor.mixv(Vec3.init(0.08, 0.25, 0.30), gridLine);
    color = color.mixv(floorColor, floorMask);

    // Orange RoboSub gate.
    const leftPole = rectangleMask(uv, Vec2.init(0.30, 0.28), Vec2.init(0.325, 0.72));
    const rightPole = rectangleMask(uv, Vec2.init(0.675, 0.28), Vec2.init(0.70, 0.72));
    const topBar = rectangleMask(uv, Vec2.init(0.30, 0.27), Vec2.init(0.70, 0.305));
    const gateMask = clamp01(leftPole + rightPole + topBar);
    color = color.mixv(Vec3.init(1.0, 0.31, 0.025), gateMask);

    // Yellow buoy.
    const buoyMask = circleMask(uv, Vec2.init(0.80, 0.52), 0.055);
    const buoyHighlight = circleMask(uv, Vec2.init(0.782, 0.50), 0.015);
    const buoyColor = Vec3.init(1.0, 0.76, 0.04).add(Vec3.init(0.28, 0.24, 0.12).scale(buoyHighlight));
    color = color.mixv(buoyColor, buoyMask);

    // Mission bin on the pool floor.
    const binMask = rectangleMask(uv, Vec2.init(0.13, 0.73), Vec2.init(0.28, 0.84));
    const binInner = rectangleMask(uv, Vec2.init(0.15, 0.75), Vec2.init(0.26, 0.815));
    const binColor = Vec3.init(0.12, 0.13, 0.15).mixv(Vec3.init(0.03, 0.04, 0.05), binInner);
    color = color.mixv(binColor, binMask);

    // Animated pool-floor caustics.
    const causticValue = caustics(Vec2.init(tileUV.x * 0.45, tileUV.y * 0.45), time);
    color = color.add(Vec3.init(0.12, 0.19, 0.22).scale(causticValue * floorMask));

    // Floating particles.
    const particleCell = Vec2.init(
        std.math.floor(uv.x * 350.0),
        std.math.floor(uv.y * 220.0),
    );
    const particleNoise = hash(Vec2.init(
        particleCell.x + std.math.floor(time * 2.0),
        particleCell.y + std.math.floor(time * 2.0),
    ));
    const particle = step(0.9975, particleNoise);
    color = color.add(Vec3.init(0.42, 0.60, 0.62).scale(particle));

    // Underwater haze.
    const distanceFog = clamp01(uv.y * turbidity);
    color = color.mixv(Vec3.init(0.015, 0.18, 0.28), distanceFog * 0.48);

    // Camera vignette.
    const cx = uv.x - 0.5;
    const cy = uv.y - 0.5;
    const vignette = clamp01(1.0 - (cx * cx + cy * cy) * 1.5);
    color = color.scale(mix(0.67, 1.0, vignette));

    return color;
}

// -------------------------------------------------------------- PNG encoder
fn crc32(data: []const u8, seed: u32) u32 {
    var crc = seed ^ 0xFFFFFFFF;
    for (data) |b| {
        crc ^= b;
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            const mask = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return crc ^ 0xFFFFFFFF;
}

const Buf = struct {
    data: []u8,
    len: usize = 0,
    fn put(self: *Buf, v: u8) void {
        self.data[self.len] = v;
        self.len += 1;
    }
    fn be32(self: *Buf, v: u32) void {
        self.put(@intCast((v >> 24) & 0xFF));
        self.put(@intCast((v >> 16) & 0xFF));
        self.put(@intCast((v >> 8) & 0xFF));
        self.put(@intCast(v & 0xFF));
    }
    fn bytes(self: *Buf, b: []const u8) void {
        @memcpy(self.data[self.len .. self.len + b.len], b);
        self.len += b.len;
    }
    fn chunk(self: *Buf, tag: []const u8, payload: []const u8) void {
        self.be32(@intCast(payload.len));
        const start = self.len;
        self.bytes(tag);
        self.bytes(payload);
        self.be32(crc32(self.data[start..self.len], 0));
    }
};

fn encodePng(allocator: std.mem.Allocator, pixels: []const u8, w: u32, h: u32) ![]u8 {
    // Raw filtered scanlines: one filter byte (0 = none) per row + RGB data.
    const row_bytes = w * 3;
    const raw_len = h * (1 + row_bytes);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    {
        var y: u32 = 0;
        var o: usize = 0;
        while (y < h) : (y += 1) {
            raw[o] = 0;
            o += 1;
            const src = y * row_bytes;
            @memcpy(raw[o .. o + row_bytes], pixels[src .. src + row_bytes]);
            o += row_bytes;
        }
    }

    // Compress the scanlines into a zlib stream (stdlib deflate).
    var zw: std.Io.Writer.Allocating = try .initCapacity(allocator, raw_len / 2 + 64);
    defer zw.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var comp = try std.compress.flate.Compress.init(&zw.writer, window, .zlib, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();
    const zlib = zw.written();
    const zlib_len = zlib.len;

    // Assemble the full PNG.
    const total = 8 + 25 + (12 + zlib_len) + 12;
    const out = try allocator.alloc(u8, total);
    var b = Buf{ .data = out };
    b.bytes(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    var hb = Buf{ .data = &ihdr };
    hb.be32(w);
    hb.be32(h);
    hb.put(8); // bit depth
    hb.put(2); // color type: truecolor RGB
    hb.put(0); // compression
    hb.put(0); // filter
    hb.put(0); // interlace
    b.chunk("IHDR", &ihdr);
    b.chunk("IDAT", zlib);
    b.chunk("IEND", &[_]u8{});

    return out;
}

fn encodeDepthPng(allocator: std.mem.Allocator, depth: []const f32, w: u32, h: u32) ![]u8 {
    // Raw filtered scanlines: one filter byte plus one big-endian 16-bit
    // grayscale sample per pixel. Depth is already normalized to [0, 1].
    const row_bytes = w * 2;
    const raw_len = h * (1 + row_bytes);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    var y: u32 = 0;
    var o: usize = 0;
    while (y < h) : (y += 1) {
        raw[o] = 0;
        o += 1;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const value = @as(u16, @intFromFloat(clamp01(depth[@as(usize, y) * w + x]) * 65535.0 + 0.5));
            raw[o] = @intCast(value >> 8);
            raw[o + 1] = @intCast(value & 0xff);
            o += 2;
        }
    }

    var zw: std.Io.Writer.Allocating = try .initCapacity(allocator, raw_len / 2 + 64);
    defer zw.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var comp = try std.compress.flate.Compress.init(&zw.writer, window, .zlib, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();
    const zlib = zw.written();

    const total = 8 + 25 + (12 + zlib.len) + 12;
    const out = try allocator.alloc(u8, total);
    var b = Buf{ .data = out };
    b.bytes(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    var hb = Buf{ .data = &ihdr };
    hb.be32(w);
    hb.be32(h);
    hb.put(16); // bit depth
    hb.put(0); // color type: grayscale
    hb.put(0); // compression
    hb.put(0); // filter
    hb.put(0); // interlace
    b.chunk("IHDR", &ihdr);
    b.chunk("IDAT", zlib);
    b.chunk("IEND", &[_]u8{});
    return out;
}

// --------------------------------------------------------------------- main
fn parseDim(s: []const u8, fallback: u32) u32 {
    const v = std.fmt.parseInt(u32, s, 10) catch return fallback;
    return if (v == 0) fallback else v;
}

test "parseDim falls back on junk and zero, parses valid" {
    try std.testing.expectEqual(@as(u32, 1280), parseDim("abc", 1280));
    try std.testing.expectEqual(@as(u32, 1280), parseDim("0", 1280));
    try std.testing.expectEqual(@as(u32, 1920), parseDim("1920", 1280));
}

test "depth AOV uses the normalized procedural floor coordinate" {
    try std.testing.expectEqual(@as(f32, 0.0), proceduralDepth(.{ .x = 0.5, .y = 0.2 }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), proceduralDepth(.{ .x = 0.5, .y = 0.42 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), proceduralDepth(.{ .x = 0.5, .y = 1.0 }), 1e-6);
}

fn proceduralDepth(uv: Vec2) f32 {
    const floorStart: f32 = 0.42;
    return if (uv.y < floorStart) 0.0 else clamp01((uv.y - floorStart) / (1.0 - floorStart));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Defaults are the shader's RenderParameters; CLI args override in order.
    var width: u32 = 1280;
    var height: u32 = 800;
    var time: f32 = 1.5;
    var turbidity: f32 = 1.0;
    var write_depth = false;
    var positional: u8 = 0;

    var it = init.minimal.args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--depth")) {
            write_depth = true;
            continue;
        }
        switch (positional) {
            0 => width = parseDim(arg, width),
            1 => height = parseDim(arg, height),
            2 => time = std.fmt.parseFloat(f32, arg) catch time,
            3 => turbidity = std.fmt.parseFloat(f32, arg) catch turbidity,
            else => {},
        }
        positional += 1;
    }

    std.debug.print(
        \\========================================
        \\ RoboPool — CPU renderer (Zig)
        \\========================================
        \\ {d} x {d}   time={d:.2}   turbidity={d:.2}
        \\
    , .{ width, height, time, turbidity });

    const pixel_count = @as(usize, width) * height;
    const pixels = try allocator.alloc(u8, pixel_count * 3);
    defer allocator.free(pixels);
    const depth = if (write_depth) try allocator.alloc(f32, pixel_count) else null;
    defer if (depth) |values| allocator.free(values);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const uv = Vec2.init(
                (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(width)),
                (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(height)),
            );
            const c = renderPool(uv, time, turbidity);
            if (depth) |values| values[@as(usize, y) * width + x] = proceduralDepth(uv);
            const i = (@as(usize, y) * width + x) * 3;
            pixels[i + 0] = @intFromFloat(clamp01(c.x) * 255.0 + 0.5);
            pixels[i + 1] = @intFromFloat(clamp01(c.y) * 255.0 + 0.5);
            pixels[i + 2] = @intFromFloat(clamp01(c.z) * 255.0 + 0.5);
        }
    }

    const png = try encodePng(allocator, pixels, width, height);
    defer allocator.free(png);

    const file = try std.Io.Dir.cwd().createFile(io, "robopool.png", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, png);

    std.debug.print(
        \\
        \\Wrote robopool.png ({d} bytes).
        \\
    , .{png.len});

    if (depth) |values| {
        const depth_png = try encodeDepthPng(allocator, values, width, height);
        defer allocator.free(depth_png);
        const depth_file = try std.Io.Dir.cwd().createFile(io, "out_depth.png", .{});
        defer depth_file.close(io);
        try depth_file.writeStreamingAll(io, depth_png);

        const depth_bin = try allocator.alloc(u8, values.len * @sizeOf(f32));
        defer allocator.free(depth_bin);
        for (values, 0..) |value, index| {
            std.mem.writeInt(u32, depth_bin[index * 4 ..][0..4], @bitCast(value), .little);
        }
        const bin_file = try std.Io.Dir.cwd().createFile(io, "out_depth.bin", .{});
        defer bin_file.close(io);
        try bin_file.writeStreamingAll(io, depth_bin);

        std.debug.print(
            \\Depth normalization: near=0.000000 far=1.000000 (normalized procedural floor coordinate; not metric distance)
            \\Wrote out_depth.png ({d} bytes) and out_depth.bin ({d} bytes).
        , .{ depth_png.len, depth_bin.len });
    }
}
