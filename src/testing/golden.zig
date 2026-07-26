const std = @import("std");

const Scene = struct { name: []const u8, w: u32, h: u32, time: []const u8, turbidity: []const u8 };
const scenes = [_]Scene{
    .{ .name = "clear", .w = 64, .h = 48, .time = "0.75", .turbidity = "0.30" },
    .{ .name = "murky", .w = 64, .h = 48, .time = "1.50", .turbidity = "1.00" },
};
const Image = struct { w: u32, h: u32, pixels: []u8 };

fn be32(p: []const u8) u32 { return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3]; }
fn crc32(data: []const u8) u32 { var c: u32 = 0xffffffff; for (data) |b| { c ^= b; var i: u8 = 0; while (i < 8) : (i += 1) c = (c >> 1) ^ (0xedb88320 & (@as(u32, 0) -% (c & 1))); } return c ^ 0xffffffff; }

fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], &[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 })) return error.InvalidPng;
    const w = be32(bytes[16..20]); const h = be32(bytes[20..24]);
    if (bytes[24] != 8 or bytes[25] != 2) return error.UnsupportedPng;
    const raw_len = @as(usize, h) * (@as(usize, w) * 3 + 1);
    const raw = try allocator.alloc(u8, raw_len); defer allocator.free(raw);
    var compressed = std.ArrayList(u8).empty; defer compressed.deinit(allocator);
    var at: usize = 8;
    while (at + 12 <= bytes.len) { const n = @as(usize, be32(bytes[at..][0..4])); const tag = bytes[at + 4 .. at + 8]; if (at + 12 + n > bytes.len) return error.InvalidPng; if (std.mem.eql(u8, tag, "IDAT")) try compressed.appendSlice(allocator, bytes[at + 8 .. at + 8 + n]); at += 12 + n; if (std.mem.eql(u8, tag, "IEND")) break; }
    var input = std.Io.Reader.fixed(compressed.items); const window = try allocator.alloc(u8, std.compress.flate.max_window_len); defer allocator.free(window);
    var d = std.compress.flate.Decompress.init(&input, .zlib, window); try d.reader.readSliceAll(raw);
    const pixels = try allocator.alloc(u8, @as(usize, w) * h * 3); var y: u32 = 0; var ro: usize = 0;
    while (y < h) : (y += 1) { if (raw[ro] != 0) return error.UnsupportedFilter; ro += 1; @memcpy(pixels[@as(usize, y) * w * 3 ..][0 .. w * 3], raw[ro .. ro + w * 3]); ro += w * 3; }
    return .{ .w = w, .h = h, .pixels = pixels };
}

fn png(allocator: std.mem.Allocator, pixels: []const u8, w: u32, h: u32) ![]u8 {
    const raw_len = @as(usize, h) * (@as(usize, w) * 3 + 1); const raw = try allocator.alloc(u8, raw_len); defer allocator.free(raw);
    var y: u32 = 0; var o: usize = 0; while (y < h) : (y += 1) { raw[o] = 0; o += 1; const n = @as(usize, w) * 3; @memcpy(raw[o..][0..n], pixels[@as(usize, y) * n ..][0..n]); o += n; }
    var outz: std.Io.Writer.Allocating = try .initCapacity(allocator, raw_len / 2 + 64); defer outz.deinit(); const window = try allocator.alloc(u8, std.compress.flate.max_window_len); defer allocator.free(window);
    var c = try std.compress.flate.Compress.init(&outz.writer, window, .zlib, .default); try c.writer.writeAll(raw); try c.finish();
    const z = outz.written(); const total = 8 + 25 + 12 + z.len + 12; const result = try allocator.alloc(u8, total); var pos: usize = 0;
    const put = struct { fn u32be(b: []u8, p: *usize, v: u32) void { b[p.*] = @intCast((v >> 24) & 0xff); b[p.* + 1] = @intCast((v >> 16) & 0xff); b[p.* + 2] = @intCast((v >> 8) & 0xff); b[p.* + 3] = @intCast(v & 0xff); p.* += 4; } }.u32be;
    @memcpy(result[0..8], &[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 }); pos = 8;
    put(result, &pos, 13); const ih = pos; @memcpy(result[pos..][0..4], "IHDR"); pos += 4; put(result, &pos, w); put(result, &pos, h); @memcpy(result[pos..][0..5], &[_]u8{ 8, 2, 0, 0, 0 }); pos += 5; put(result, &pos, crc32(result[ih..pos]));
    put(result, &pos, @intCast(z.len)); const iz = pos; @memcpy(result[pos..][0..4], "IDAT"); pos += 4; @memcpy(result[pos..][0..z.len], z); pos += z.len; put(result, &pos, crc32(result[iz..pos]));
    put(result, &pos, 0); @memcpy(result[pos..][0..4], "IEND"); pos += 4; put(result, &pos, crc32(result[pos - 4 .. pos])); return result;
}

fn write(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void { const f = try std.Io.Dir.cwd().createFile(io, path, .{}); defer f.close(io); try f.writeStreamingAll(io, data); _ = allocator; }
fn render(allocator: std.mem.Allocator, io: std.Io, scene: Scene) ![]u8 {
    var child = try std.process.spawn(io, .{ .argv = &.{ "zig", "run", "render.zig", "-O", "ReleaseFast", "--", "64", "48", scene.time, scene.turbidity }, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit });
    defer child.kill(io); const term = try child.wait(io); if (term != .exited or term.exited != 0) return error.RendererFailed;
    return std.Io.Dir.cwd().readFileAlloc(io, "robopool.png", allocator, .limited(64 * 1024 * 1024));
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa; const io = init.io; var update = false; var threshold: u8 = 0; var max_fraction: f64 = 0.0; var artifact: []const u8 = "ci-artifacts";
    var it = init.minimal.args.iterate(); _ = it.skip(); while (it.next()) |arg| { if (std.mem.eql(u8, arg, "--update-golden")) update = true else if (std.mem.startsWith(u8, arg, "--threshold=")) threshold = std.fmt.parseInt(u8, arg[12..], 10) catch return error.BadArgument else if (std.mem.startsWith(u8, arg, "--max-fraction=")) max_fraction = std.fmt.parseFloat(f64, arg[15..]) catch return error.BadArgument else if (std.mem.startsWith(u8, arg, "--artifact-dir=")) artifact = arg[15..]; }
    var failed = false;
    for (scenes) |scene| {
        const generated_bytes = try render(a, io, scene); defer a.free(generated_bytes); const generated = try decode(a, generated_bytes); defer a.free(generated.pixels);
        const ref_path = try std.fmt.allocPrint(a, "tests/golden/{s}.png", .{scene.name}); defer a.free(ref_path);
        if (update) { try write(a, io, ref_path, generated_bytes); std.debug.print("updated {s}\n", .{ref_path}); continue; }
        const reference_bytes = std.Io.Dir.cwd().readFileAlloc(io, ref_path, a, .limited(64 * 1024 * 1024)) catch |err| { std.debug.print("missing {s}; use --update-golden ({s})\n", .{ ref_path, @errorName(err) }); return err; }; defer a.free(reference_bytes);
        const reference = try decode(a, reference_bytes); defer a.free(reference.pixels); if (reference.w != generated.w or reference.h != generated.h) return error.DimensionMismatch;
        var max: u8 = 0; var over: usize = 0; var worst = [_]usize{ 0, 0 }; var worst_diff = [_]u8{ 0, 0 };
        var pixel: usize = 0; const pixel_count = @as(usize, generated.w) * generated.h;
        while (pixel < pixel_count) : (pixel += 1) { const base = pixel * 3; var pixel_max: u8 = 0; var channel: usize = 0; while (channel < 3) : (channel += 1) { const g = generated.pixels[base + channel]; const r = reference.pixels[base + channel]; const d = if (g > r) g - r else r - g; if (d > pixel_max) pixel_max = d; if (d > max) max = d; } if (pixel_max > threshold) over += 1; if (pixel_max > worst_diff[0]) { worst_diff[1] = worst_diff[0]; worst[1] = worst[0]; worst_diff[0] = pixel_max; worst[0] = pixel; } }
        const fraction = @as(f64, @floatFromInt(over)) / @as(f64, @floatFromInt(@as(usize, generated.w) * generated.h)); std.debug.print("{s}: max-channel-diff={d}, fraction-over-{d}={d:.6}\n", .{ scene.name, max, threshold, fraction });
        if (max != 0 or fraction > max_fraction) { failed = true; std.Io.Dir.cwd().createDirPath(io, artifact) catch {}; const diff_path = try std.fmt.allocPrint(a, "{s}/golden-{s}-diff.png", .{ artifact, scene.name }); defer a.free(diff_path); const diff = try a.alloc(u8, generated.pixels.len); defer a.free(diff); for (diff, 0..) |*v, j| v.* = if (j % 3 == 0) @max(generated.pixels[j], reference.pixels[j]) - @min(generated.pixels[j], reference.pixels[j]) else 0; const db = try png(a, diff, generated.w, generated.h); defer a.free(db); try write(a, io, diff_path, db); std.debug.print("worst pixels: ({d},{d}) diff={d}, ({d},{d}) diff={d}; diff={s}\n", .{ worst[0] % generated.w, worst[0] / generated.w, worst_diff[0], worst[1] % generated.w, worst[1] / generated.w, worst_diff[1], diff_path }); }
    }
    if (failed) return error.GoldenMismatch;
}
